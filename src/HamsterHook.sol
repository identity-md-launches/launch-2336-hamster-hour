// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {IHamsterVault} from "./interfaces/IHamsterVault.sol";
import {HookFlags} from "./HookFlags.sol";

/// @notice Immutable HAMSTER/IMD swap fees, one-shot launch tax, and permissionless credit delivery.
/// @dev Buy percentages apply to gross IMD actually paid; sell percentages to gross IMD output.
/// Specified-currency fees use a reverting PoolManager simulation to handle partial fills exactly.
/// The simulation cannot persist a hook-skipping swap. See docs/ACCOUNTING.md for the derivation.
contract HamsterHook is IUnlockCallback {
    using SafeERC20 for IERC20;

    address public constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address public constant VAULT = 0x1DCeb78b36b5F18Ac4a130F1FFc76ebA0E73D183;
    uint24 public constant LP_FEE = 12_500;
    int24 public constant TICK_SPACING = 60;
    uint256 public constant BPS = 10_000;
    uint256 public constant HOOK_FEE_BPS = 110;
    uint256 public constant INITIAL_TAX_BPS = 9_500;
    uint256 public constant TAX_STEP_BPS = 200;
    uint256 public constant TAX_MINUTES = 48;
    uint256 public constant MAX_FLUSH_AMOUNT = uint256(uint128(type(int128).max));
    uint160 public constant REQUIRED_FLAGS = HookFlags.HAMSTER;

    IPoolManager public immutable poolManager;
    address public immutable token;
    address public immutable factory;
    address public immutable TEAM;
    bool public immutable imdIsCurrency0;
    PoolId public immutable poolId;

    bool public initialized;
    uint256 public startedAt;

    enum Bucket {
        Rewards,
        Drip,
        Jackpot,
        Oracle,
        Team
    }

    mapping(Bucket => uint256) public credits;
    uint256 public totalCredits;
    bool private _flushing;
    uint256 private _redeeming;

    error InvalidAddress();
    error OnlyPoolManager();
    error OnlySelf();
    error WrongPool();
    error OnlyFactory();
    error AlreadyInitialized();
    error NotInitialized();
    error AmountTooLarge();
    error UnexpectedDelta();
    error SimulationResult(int128 imdDelta);
    error SimulationDidNotRevert();
    error InvalidSimulationResult();
    error Reentrancy();
    error UnexpectedUnlock();
    error TransferMismatch();
    error VaultUnavailable();

    event PoolStarted(PoolId indexed id, uint256 timestamp);
    event FeesAccrued(bool indexed buy, uint256 grossImd, uint256 poolImd, uint256 permanentFee, uint256 antiSnipeTax);
    event CreditFlushed(Bucket indexed bucket, uint256 amount);
    event FlushFailed(Bucket indexed bucket, uint256 amount, bytes reason);

    /// @param manager_ Launch parameter $poolManager.
    /// @param token_ Launch parameter $token, deployed immediately before this hook.
    /// @param factory_ Launch parameter $factory; only it may initialize the single pool.
    /// @param team_ Launch parameter $owner, a fixed payment recipient with no administrative powers.
    constructor(IPoolManager manager_, address token_, address factory_, address team_) {
        if (
            address(manager_) == address(0) || token_ == address(0) || token_ == IMD || factory_ == address(0)
                || team_ == address(0) || team_ == address(this)
        ) revert InvalidAddress();
        poolManager = manager_;
        token = token_;
        factory = factory_;
        TEAM = team_;
        imdIsCurrency0 = IMD < token_;
        poolId = poolKey().toId();
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    modifier onlySelf() {
        if (msg.sender != address(this)) revert OnlySelf();
        _;
    }

    modifier flushGuard() {
        if (_flushing) revert Reentrancy();
        _flushing = true;
        _;
        _flushing = false;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    function poolKey() public view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(imdIsCurrency0 ? IMD : token),
            currency1: Currency.wrap(imdIsCurrency0 ? token : IMD),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(this))
        });
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160) external onlyPoolManager returns (bytes4) {
        _checkPool(key);
        if (sender != factory) revert OnlyFactory();
        if (initialized) revert AlreadyInitialized();
        initialized = true;
        startedAt = block.timestamp;
        emit PoolStarted(poolId, block.timestamp);
        return IHooks.beforeInitialize.selector;
    }

    /// @notice 95%, 93%, ... 1% in minute 47; zero from minute 48 permanently.
    function taxBps() public view returns (uint256) {
        if (!initialized) return 0;
        uint256 minutesElapsed = (block.timestamp - startedAt) / 1 minutes;
        return minutesElapsed >= TAX_MINUTES ? 0 : INITIAL_TAX_BPS - TAX_STEP_BPS * minutesElapsed;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _checkSwap(key, params);
        bool buy = params.zeroForOne == imdIsCurrency0;
        bool exactInput = params.amountSpecified < 0;
        // IMD is unspecified in these modes: afterSwap can charge the observed delta directly.
        if (buy != exactInput) return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);

        SwapParams memory simulated = params;
        uint256 fee;
        if (buy) {
            uint256 grossBudget = uint256(-params.amountSpecified);
            uint256 rate = HOOK_FEE_BPS + taxBps();
            uint256 budgetFee = grossBudget * rate / BPS;
            simulated.amountSpecified = -int256(grossBudget - budgetFee);
            uint256 poolInput = _absoluteImd(_simulate(simulated), true);
            // A full fill uses the user's whole budget. A partial fill pays only for actual input.
            uint256 gross = poolInput == grossBudget - budgetFee ? grossBudget : _grossUp(poolInput, rate);
            fee = gross - poolInput;
        } else {
            // Exact-output sells specify NET IMD. Ask the pool for enough gross output to cover fees.
            simulated.amountSpecified = int256(_grossUp(uint256(params.amountSpecified), HOOK_FEE_BPS));
            _bounded(uint256(simulated.amountSpecified));
            uint256 poolOutput = _absoluteImd(_simulate(simulated), false);
            fee = poolOutput * HOOK_FEE_BPS / BPS;
        }
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(_bounded(fee), 0), 0);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        _checkSwap(key, params);
        bool buy = params.zeroForOne == imdIsCurrency0;
        uint256 poolImd = _absoluteImd(imdIsCurrency0 ? delta.amount0() : delta.amount1(), buy);
        uint256 rate = HOOK_FEE_BPS + (buy ? taxBps() : 0);
        uint256 gross;
        if (buy) {
            if (params.amountSpecified < 0) {
                uint256 budget = uint256(-params.amountSpecified);
                uint256 budgetFee = budget * rate / BPS;
                gross = poolImd == budget - budgetFee ? budget : _grossUp(poolImd, rate);
            } else {
                gross = _grossUp(poolImd, rate);
            }
        } else {
            gross = poolImd;
        }
        _bounded(gross);
        uint256 fee = gross * rate / BPS;
        if (fee != 0) _accrue(buy, gross, poolImd, fee);
        // The specified-currency fee was already returned by beforeSwap.
        bool imdSpecified = buy == (params.amountSpecified < 0);
        return (IHooks.afterSwap.selector, imdSpecified ? int128(0) : _bounded(fee));
    }

    /// @dev Only a self-call can simulate; it ALWAYS reverts, rolling back all PoolManager state.
    /// v4 skips the hook for this self-initiated simulation, which avoids recursion.
    function simulateSwap(SwapParams calldata params) external onlySelf {
        BalanceDelta delta = poolManager.swap(poolKey(), params, "");
        revert SimulationResult(imdIsCurrency0 ? delta.amount0() : delta.amount1());
    }

    function _simulate(SwapParams memory params) private returns (int128 amount) {
        try this.simulateSwap(params) {
            revert SimulationDidNotRevert();
        } catch (bytes memory reason) {
            if (bytes4(reason) != SimulationResult.selector) {
                assembly ("memory-safe") {
                    revert(add(reason, 32), mload(reason))
                }
            }
            if (reason.length != 36) revert InvalidSimulationResult();
            assembly ("memory-safe") {
                amount := mload(add(reason, 36))
            }
        }
    }

    /// @dev Smallest gross g for which g - floor(g * rate / BPS) == net.
    /// Since rate < BPS this map increases by at most one, so every net is representable.
    function _grossUp(uint256 net, uint256 rate) private pure returns (uint256) {
        return net == 0 ? 0 : (net - 1) * BPS / (BPS - rate) + 1;
    }

    function _absoluteImd(int128 amount, bool buy) private pure returns (uint256) {
        if (buy ? amount > 0 : amount < 0) revert UnexpectedDelta();
        return uint256(buy ? -int256(amount) : int256(amount));
    }

    function _bounded(uint256 amount) private pure returns (int128) {
        if (amount > uint256(uint128(type(int128).max))) revert AmountTooLarge();
        return int128(uint128(amount));
    }

    function _checkPool(PoolKey calldata key) private view {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert WrongPool();
    }

    function _checkSwap(PoolKey calldata key, SwapParams calldata params) private view {
        _checkPool(key);
        if (!initialized) revert NotInitialized();
        if (params.amountSpecified > int256(type(int128).max) || params.amountSpecified < -int256(type(int128).max)) {
            revert AmountTooLarge();
        }
    }

    function _accrue(bool buy, uint256 gross, uint256 poolImd, uint256 totalFee) private {
        uint256 permanentFee = gross * HOOK_FEE_BPS / BPS;
        uint256 tax = totalFee - permanentFee;
        uint256 rewards = gross * 50 / BPS;
        uint256 jackpot = rewards;
        uint256 drip = tax * 80 / 100;
        uint256 taxOracle = tax / 10;
        credits[Bucket.Rewards] += rewards;
        credits[Bucket.Jackpot] += jackpot;
        credits[Bucket.Drip] += drip;
        credits[Bucket.Oracle] += permanentFee - rewards - jackpot + taxOracle;
        credits[Bucket.Team] += tax - drip - taxOracle;
        totalCredits += totalFee;
        // No token or vault call: claims require no pre-existing IMD balance in the manager.
        poolManager.mint(address(this), uint256(uint160(IMD)), totalFee);
        emit FeesAccrued(buy, gross, poolImd, permanentFee, tax);
    }

    /// @notice Retry a single bucket. A failed redemption/transfer/vault call leaves all credits intact.
    /// @param maxAmount Upper limit, in IMD minor units, for this attempt (zero is a no-op).
    function flush(Bucket bucket, uint256 maxAmount) external flushGuard returns (bool success, uint256 amount) {
        return _tryFlush(bucket, maxAmount);
    }

    /// @notice Try each bucket independently, so a broken vault method cannot hold up other recipients.
    function flushAll(uint256 maxPerBucket) external flushGuard returns (uint256 delivered) {
        for (uint256 i; i < 5; ++i) {
            (bool ok, uint256 amount) = _tryFlush(Bucket(i), maxPerBucket);
            if (ok) delivered += amount;
        }
    }

    function _tryFlush(Bucket bucket, uint256 maximum) private returns (bool success, uint256 amount) {
        amount = credits[bucket];
        if (amount > maximum) amount = maximum;
        // Manager burn/take use signed int128 deltas, stricter than the vault's uint128 limit.
        if (amount > MAX_FLUSH_AMOUNT) amount = MAX_FLUSH_AMOUNT;
        if (amount == 0) return (true, 0);
        try this.deliverCredit(bucket, amount) {
            emit CreditFlushed(bucket, amount);
            return (true, amount);
        } catch (bytes memory reason) {
            emit FlushFailed(bucket, amount, reason);
            return (false, 0);
        }
    }

    /// @dev Isolates an entire flush in a revertible subcall, including claim burn and approvals.
    function deliverCredit(Bucket bucket, uint256 amount) external onlySelf {
        if (!_flushing) revert UnexpectedUnlock();
        credits[bucket] -= amount;
        totalCredits -= amount;
        _redeeming = amount;
        poolManager.unlock(abi.encode(amount));
        _redeeming = 0;

        IERC20 imd = IERC20(IMD);
        uint256 beforeBalance = imd.balanceOf(address(this));
        if (bucket == Bucket.Team) {
            uint256 recipientBefore = imd.balanceOf(TEAM);
            imd.safeTransfer(TEAM, amount);
            if (imd.balanceOf(TEAM) != recipientBefore + amount) revert TransferMismatch();
        } else {
            if (VAULT.code.length == 0) revert VaultUnavailable();
            imd.forceApprove(VAULT, amount);
            IHamsterVault vault = IHamsterVault(VAULT);
            if (bucket == Bucket.Rewards) vault.depositRewards(amount);
            else if (bucket == Bucket.Drip) vault.depositDrip(amount);
            else if (bucket == Bucket.Jackpot) vault.forwardJackpot(amount);
            else vault.forwardOracle(amount);
            imd.forceApprove(VAULT, 0);
        }
        if (imd.balanceOf(address(this)) + amount != beforeBalance) revert TransferMismatch();
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        uint256 amount = abi.decode(data, (uint256));
        if (!_flushing || amount == 0 || amount != _redeeming) revert UnexpectedUnlock();
        _redeeming = 0;
        IERC20 imd = IERC20(IMD);
        uint256 beforeBalance = imd.balanceOf(address(this));
        poolManager.burn(address(this), uint256(uint160(IMD)), amount);
        poolManager.take(Currency.wrap(IMD), address(this), amount);
        if (imd.balanceOf(address(this)) != beforeBalance + amount) revert TransferMismatch();
        return "";
    }
}

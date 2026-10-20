// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {HamsterHook} from "../src/HamsterHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockVault} from "./mocks/MockVault.sol";
import {TestRouter} from "./mocks/TestRouter.sol";

/// @dev The test contract is the launch factory: it initializes the pool and seeds its liquidity itself.
abstract contract HookTestBase is Test, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant VAULT = 0x1DCeb78b36b5F18Ac4a130F1FFc76ebA0E73D183;
    address internal constant TEAM = 0x6CBA4751742F6989fA224B2dC5d5d52fCef98a34;
    // Deterministic mock locations exercise both currency orderings; never production parameters.
    address internal constant LOW_TOKEN = address(0x100000);
    address internal constant HIGH_TOKEN = address(uint160(type(uint160).max - 100));
    uint160 internal constant Q96 = 79228162514264337593543950336;
    uint256 internal constant START = 1_800_000_000;
    uint256 internal constant LIQUIDITY = 1_000_000 ether;
    bytes32 internal constant SWAP_EVENT =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    IPoolManager internal manager;
    HamsterHook internal hook;
    MockERC20 internal imd;
    MockERC20 internal hamster;
    MockVault internal vault;
    TestRouter internal router;
    PoolKey internal key;

    function setUp() public virtual {
        _setup(false, false);
    }

    function _setup(bool imdFirst, bool oneSided) internal {
        vm.warp(START);
        manager = IPoolManager(address(new PoolManager(address(this))));
        address tokenAt = imdFirst ? HIGH_TOKEN : LOW_TOKEN;
        vm.etch(IMD, address(new MockERC20("IMD test double", "IMD", 0)).code);
        vm.etch(tokenAt, address(new MockERC20("HAMSTER test double", "HAMSTER", 0)).code);
        vm.etch(VAULT, address(new MockVault()).code);
        imd = MockERC20(IMD);
        hamster = MockERC20(tokenAt);
        vault = MockVault(VAULT);
        hook = _deployHook(manager, tokenAt, address(this), TEAM);
        key = hook.poolKey();
        manager.initialize(key, oneSided ? TickMath.getSqrtPriceAtTick(imdFirst ? int24(60) : int24(-60)) : Q96);
        router = new TestRouter(manager);
        imd.mint(address(router), 1e35);
        hamster.mint(address(router), 1e35);
        imd.mint(address(this), 1e35);
        hamster.mint(address(this), 1e35);
        _modifyAsFactory(
            ModifyLiquidityParams({
                tickLower: oneSided ? int24(-60) : int24(-600),
                tickUpper: oneSided ? int24(60) : int24(600),
                liquidityDelta: int256(LIQUIDITY),
                salt: bytes32(0)
            })
        );
    }

    /// @dev Modifies the factory's own position in `key` and settles from the factory's balances.
    function _modifyAsFactory(ModifyLiquidityParams memory params) internal returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(params)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (BalanceDelta delta,) = manager.modifyLiquidity(key, abi.decode(data, (ModifyLiquidityParams)), "");
        _settleFactory(key.currency0, delta.amount0());
        _settleFactory(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _settleFactory(Currency currency, int128 amount) private {
        if (amount < 0) {
            manager.sync(currency);
            require(IERC20(Currency.unwrap(currency)).transfer(address(manager), uint256(-int256(amount))));
            manager.settle();
        } else if (amount > 0) {
            manager.take(currency, address(this), uint256(int256(amount)));
        }
    }

    function _deployHook(IPoolManager pm, address t, address f, address team) internal returns (HamsterHook result) {
        bytes memory code = abi.encodePacked(type(HamsterHook).creationCode, abi.encode(pm, t, f, team));
        bytes32 hash = keccak256(code);
        // One 85-byte CREATE2 preimage buffer, rewritten in place: the search never grows memory.
        bytes memory preimage = abi.encodePacked(bytes1(0xff), address(this), bytes32(0), hash);
        for (uint256 i; i < 1_000_000; ++i) {
            address predicted;
            assembly ("memory-safe") {
                mstore(add(preimage, 53), i)
                predicted := and(keccak256(add(preimage, 32), 85), 0xffffffffffffffffffffffffffffffffffffffff)
            }
            if (HookFlags.matches(predicted, HookFlags.HAMSTER) && predicted.code.length == 0) {
                result = new HamsterHook{salt: bytes32(i)}(pm, t, f, team);
                assertEq(address(result), predicted);
                return result;
            }
        }
        revert("salt not found");
    }

    function _params(bool buy, bool exactInput, uint256 amount, bool limited)
        internal
        view
        returns (SwapParams memory)
    {
        bool direction = buy == hook.imdIsCurrency0();
        uint160 limit;
        if (limited) {
            (, int24 tick,,) = manager.getSlot0(key.toId());
            limit = TickMath.getSqrtPriceAtTick(direction ? tick - 1 : tick + 1);
        } else {
            limit = direction ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        }
        return SwapParams(direction, exactInput ? -int256(amount) : int256(amount), limit);
    }

    struct Observation {
        uint256 gross;
        uint256 poolImd;
        uint256 fee;
        uint256 tax;
        uint256 permanent;
        uint256 hamsterAmount;
        uint256 userImd;
    }

    function _trade(bool buy, bool exactInput, uint256 amount, bool limited) internal returns (Observation memory o) {
        uint256 beforeCredits = hook.totalCredits();
        uint256 beforeImd = imd.balanceOf(address(router));
        uint256[5] memory beforeBuckets;
        for (uint256 i; i < 5; ++i) {
            beforeBuckets[i] = hook.credits(HamsterHook.Bucket(i));
        }
        vm.recordLogs();
        BalanceDelta delta = router.swap(key, _params(buy, exactInput, amount, limited), "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundSwap;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(manager) || logs[i].topics[0] != SWAP_EVENT) continue;
            // The last Swap event is the real execution (a reverted simulation cannot persist logs).
            (int128 a0, int128 a1,,,,) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            int128 actual = hook.imdIsCurrency0() ? a0 : a1;
            o.poolImd = uint256(buy ? -int256(actual) : int256(actual));
            foundSwap = true;
        }
        assertTrue(foundSwap, "actual PoolManager swap missing");
        o.fee = hook.totalCredits() - beforeCredits;
        o.userImd = buy ? beforeImd - imd.balanceOf(address(router)) : imd.balanceOf(address(router)) - beforeImd;
        o.gross = buy ? o.userImd : o.poolImd;
        o.permanent = o.gross * 110 / 10_000;
        uint256 rate = buy ? hook.taxBps() : 0;
        o.tax = o.gross * (110 + rate) / 10_000 - o.permanent;
        int128 h = hook.imdIsCurrency0() ? delta.amount1() : delta.amount0();
        o.hamsterAmount = uint256(buy ? int256(h) : -int256(h));

        assertEq(o.fee, o.permanent + o.tax, "fee not based on actual IMD leg");
        assertEq(buy ? o.userImd : o.poolImd, (buy ? o.poolImd : o.userImd) + o.fee, "delta conservation");
        assertEq(hook.credits(HamsterHook.Bucket.Rewards) - beforeBuckets[0], o.gross * 50 / 10_000);
        assertEq(hook.credits(HamsterHook.Bucket.Drip) - beforeBuckets[1], o.tax * 80 / 100);
        assertEq(hook.credits(HamsterHook.Bucket.Jackpot) - beforeBuckets[2], o.gross * 50 / 10_000);
        assertEq(
            hook.credits(HamsterHook.Bucket.Oracle) - beforeBuckets[3],
            o.permanent - 2 * (o.gross * 50 / 10_000) + o.tax / 10
        );
        assertEq(hook.credits(HamsterHook.Bucket.Team) - beforeBuckets[4], o.tax - o.tax * 80 / 100 - o.tax / 10);
        assertLe(o.fee, o.gross);
        _assertSolvent();
    }

    function _assertSolvent() internal view {
        uint256 sum;
        for (uint256 i; i < 5; ++i) {
            sum += hook.credits(HamsterHook.Bucket(i));
        }
        assertEq(sum, hook.totalCredits(), "bucket conservation");
        assertEq(manager.balanceOf(address(hook), uint256(uint160(IMD))), sum, "all credits backed by claims");
        assertEq(manager.currencyDelta(address(hook), key.currency0), 0, "hook unsettled currency0");
        assertEq(manager.currencyDelta(address(hook), key.currency1), 0, "hook unsettled currency1");
        assertEq(manager.currencyDelta(address(router), key.currency0), 0, "router unsettled currency0");
        assertEq(manager.currencyDelta(address(router), key.currency1), 0, "router unsettled currency1");
        assertEq(manager.getNonzeroDeltaCount(), 0, "nonzero manager deltas");
    }
}

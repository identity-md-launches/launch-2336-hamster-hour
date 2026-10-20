// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {HookTestBase} from "./HookTestBase.sol";
import {HamsterHook} from "../src/HamsterHook.sol";
import {IHamsterVault} from "../src/interfaces/IHamsterVault.sol";
import {TestRouter} from "./mocks/TestRouter.sol";
import {MockVault} from "./mocks/MockVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract HamsterHandler is Test {
    HamsterHook public immutable hook;
    TestRouter public immutable router;
    MockVault public immutable vault;
    MockERC20 public immutable imd;
    uint256 public accrued;
    uint256 public delivered;
    uint256 public swaps;
    uint256 public failedFlushes;

    constructor(HamsterHook hook_, TestRouter router_) {
        hook = hook_;
        router = router_;
        vault = MockVault(hook_.VAULT());
        imd = MockERC20(hook_.IMD());
    }

    function trade(uint80 rawAmount, bool buy, bool exactInput) external {
        uint256 amount = bound(rawAmount, 1, 1 ether);
        bool direction = buy == hook.imdIsCurrency0();
        uint256 creditsBefore = hook.totalCredits();
        uint256 dripBefore = hook.credits(HamsterHook.Bucket.Drip);
        uint256 teamBefore = hook.credits(HamsterHook.Bucket.Team);
        uint256 imdBefore = imd.balanceOf(address(router));
        router.swap(
            hook.poolKey(),
            SwapParams(
                direction,
                exactInput ? -int256(amount) : int256(amount),
                direction ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            abi.encode(msg.sender)
        );
        uint256 fee = hook.totalCredits() - creditsBefore;
        uint256 gross =
            buy ? imdBefore - imd.balanceOf(address(router)) : imd.balanceOf(address(router)) - imdBefore + fee;
        assertEq(fee, gross * (110 + (buy ? hook.taxBps() : 0)) / 10_000);
        if (!buy) {
            assertEq(hook.credits(HamsterHook.Bucket.Drip), dripBefore);
            assertEq(hook.credits(HamsterHook.Bucket.Team), teamBefore);
        }
        accrued += fee;
        ++swaps;
    }

    function advanceTime(uint16 secondsForward) external {
        uint256 oldTax = hook.taxBps();
        vm.warp(block.timestamp + secondsForward);
        assertLe(hook.taxBps(), oldTax);
    }

    function vaultBehavior(uint8 rawBucket, uint8 rawMode) external {
        uint256 bucket = uint256(rawBucket) % 4;
        bytes4[4] memory selectors = [
            IHamsterVault.depositRewards.selector,
            IHamsterVault.depositDrip.selector,
            IHamsterVault.forwardJackpot.selector,
            IHamsterVault.forwardOracle.selector
        ];
        vault.setMode(selectors[bucket], uint256(rawMode) % 5);
    }

    function flushCredit(uint8 rawBucket, uint80 rawMaximum) external {
        HamsterHook.Bucket bucket = HamsterHook.Bucket(uint256(rawBucket) % 5);
        uint256 beforeCredits = hook.totalCredits();
        (bool ok, uint256 amount) = hook.flush(bucket, rawMaximum);
        if (ok) {
            delivered += amount;
        } else {
            ++failedFlushes;
            assertEq(hook.totalCredits(), beforeCredits);
        }
    }

    function flushAll(uint80 maximum) external {
        delivered += hook.flushAll(maximum);
    }
}

contract HamsterInvariantTest is StdInvariant, HookTestBase {
    HamsterHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new HamsterHandler(hook, router);
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = HamsterHandler.trade.selector;
        selectors[1] = HamsterHandler.advanceTime.selector;
        selectors[2] = HamsterHandler.vaultBehavior.selector;
        selectors[3] = HamsterHandler.flushCredit.selector;
        selectors[4] = HamsterHandler.flushAll.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_allLiabilitiesRemainBackedAndDeltasSettle() public view {
        _assertSolvent();
        assertEq(handler.accrued(), hook.totalCredits() + handler.delivered());
        assertEq(handler.delivered(), imd.balanceOf(VAULT) + imd.balanceOf(TEAM));
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(imd.allowance(address(hook), VAULT), 0);
        assertEq(hook.startedAt(), START);
        assertFalse(vault.reentrySucceeded());
    }
}

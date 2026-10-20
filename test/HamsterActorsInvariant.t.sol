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
import {UnlockedFlusher} from "./HamsterAdversarial.t.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/// @dev Several independent routers trade every mode (full and price-limited fills) while time moves,
/// vault methods break and recover, IMD transfers fail, and keepers flush, including from inside an
/// unlocked PoolManager. Ghosts track what each bucket earned and was paid.
contract ActorsHandler is Test {
    using StateLibrary for IPoolManager;

    IPoolManager public immutable manager;
    HamsterHook public immutable hook;
    MockVault public immutable vault;
    MockERC20 public immutable imd;
    UnlockedFlusher public immutable unlockedFlusher;
    TestRouter[3] public routers;
    uint256 public immutable startedAt;

    uint256[5] public accrued;
    uint256[5] public delivered;
    uint256 public buys;
    uint256 public sells;
    uint256 public taxedBuys;
    uint256 public lastTax;
    uint256 public userImdIn;
    uint256 public userImdOut;

    constructor(IPoolManager manager_, HamsterHook hook_, UnlockedFlusher flusher_) {
        manager = manager_;
        hook = hook_;
        unlockedFlusher = flusher_;
        vault = MockVault(hook_.VAULT());
        imd = MockERC20(hook_.IMD());
        startedAt = hook_.startedAt();
        lastTax = hook_.taxBps();
        for (uint256 i; i < 3; ++i) {
            routers[i] = new TestRouter(manager_);
            imd.mint(address(routers[i]), 1e30);
            MockERC20(hook_.token()).mint(address(routers[i]), 1e30);
        }
    }

    function accruedOf(uint256 i) external view returns (uint256) {
        return accrued[i];
    }

    function deliveredOf(uint256 i) external view returns (uint256) {
        return delivered[i];
    }

    function trade(uint8 actor, uint96 rawAmount, bool buy, bool exactInput, bool limited) external {
        TestRouter router = routers[actor % 3];
        // Pool holds ~29k of each asset in range; depth * 50 stays well inside it.
        uint256 amount = bound(rawAmount, 1, 50 ether);
        uint256[5] memory before;
        for (uint256 i; i < 5; ++i) {
            before[i] = hook.credits(HamsterHook.Bucket(i));
        }
        uint256 totalBefore = hook.totalCredits();
        uint256 imdBefore = imd.balanceOf(address(router));
        uint256 rate = 110 + (buy ? hook.taxBps() : 0);

        _swap(router, buy, exactInput, amount, limited);

        uint256 fee = hook.totalCredits() - totalBefore;
        uint256 userImd = buy ? imdBefore - imd.balanceOf(address(router)) : imd.balanceOf(address(router)) - imdBefore;
        assertEq(fee, (buy ? userImd : userImd + fee) * rate / 10_000, "fee is not rate x actual IMD leg");
        if (buy) userImdIn += userImd;
        else userImdOut += userImd;
        _record(before, buy && rate > 110);
        if (buy) {
            ++buys;
            if (rate > 110 && fee > 0) ++taxedBuys;
        } else {
            ++sells;
        }
    }

    function _swap(TestRouter router, bool buy, bool exactInput, uint256 amount, bool limited) private {
        bool direction = buy == hook.imdIsCurrency0();
        uint160 limit;
        if (limited) {
            // Derived from the price, not slot0's tick: after crossing a boundary exactly, the tick can sit
            // one below the price, so a tick-based limit may equal the current price and revert in v4.
            (uint160 price,,,) = manager.getSlot0(hook.poolId());
            limit = direction ? price - price / 4000 : price + price / 4000;
        } else {
            limit = direction ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        }
        // A broken IMD transfer would also break the test router's own settlement, so lift it for the
        // trade only: the property under test is that the hook never needs a working transfer to swap.
        bool failing = imd.failTransfers();
        imd.setFailTransfers(false);
        router.swap(hook.poolKey(), SwapParams(direction, exactInput ? -int256(amount) : int256(amount), limit), "");
        imd.setFailTransfers(failing);
    }

    function _record(uint256[5] memory before, bool taxed) private {
        for (uint256 i; i < 5; ++i) {
            uint256 got = hook.credits(HamsterHook.Bucket(i)) - before[i];
            accrued[i] += got;
            if (!taxed && (i == uint256(HamsterHook.Bucket.Drip) || i == uint256(HamsterHook.Bucket.Team))) {
                assertEq(got, 0, "untaxed trade paid a tax bucket");
            }
        }
    }

    function advanceTime(uint16 rawSeconds) external {
        vm.warp(block.timestamp + bound(rawSeconds, 0, 10 minutes));
        uint256 tax = hook.taxBps();
        assertLe(tax, lastTax, "tax increased");
        lastTax = tax;
    }

    function breakVault(uint8 rawBucket, uint8 rawMode) external {
        bytes4[4] memory selectors = [
            IHamsterVault.depositRewards.selector,
            IHamsterVault.depositDrip.selector,
            IHamsterVault.forwardJackpot.selector,
            IHamsterVault.forwardOracle.selector
        ];
        vault.setMode(selectors[rawBucket % 4], rawMode % 5);
    }

    function toggleImdTransfers(bool fail) external {
        imd.setFailTransfers(fail);
    }

    function flush(uint8 rawBucket, uint96 maximum, uint8 keeper) external {
        uint256 b = rawBucket % 5;
        uint256 creditBefore = hook.credits(HamsterHook.Bucket(b));
        vm.prank(address(uint160(0xC0FFEE + keeper)));
        (bool ok, uint256 amount) = hook.flush(HamsterHook.Bucket(b), maximum);
        uint256 creditAfter = hook.credits(HamsterHook.Bucket(b));
        if (ok) {
            assertEq(creditBefore - creditAfter, amount);
            assertLe(amount, maximum);
            delivered[b] += amount;
        } else {
            assertEq(creditAfter, creditBefore, "failed flush lost credit");
        }
    }

    function flushAll(uint96 maximum) external {
        uint256[5] memory before;
        for (uint256 i; i < 5; ++i) {
            before[i] = hook.credits(HamsterHook.Bucket(i));
        }
        uint256 sent = hook.flushAll(maximum);
        uint256 sum;
        for (uint256 i; i < 5; ++i) {
            uint256 paid = before[i] - hook.credits(HamsterHook.Bucket(i));
            assertLe(paid, maximum);
            delivered[i] += paid;
            sum += paid;
        }
        assertEq(sum, sent);
    }

    function flushInsideUnlock(uint8 rawBucket) external {
        uint256 total = hook.totalCredits();
        unlockedFlusher.run(HamsterHook.Bucket(rawBucket % 5));
        assertEq(hook.totalCredits(), total, "flush inside unlock moved credits");
        if (unlockedFlusher.lastAmount() != 0) assertTrue(false, "flush inside unlock delivered");
    }
}

contract HamsterActorsInvariantTest is StdInvariant, HookTestBase {
    ActorsHandler internal handler;
    uint256 internal imdSupply;

    function setUp() public override {
        super.setUp();
        UnlockedFlusher flusher = new UnlockedFlusher(manager, hook);
        handler = new ActorsHandler(manager, hook, flusher);
        imdSupply = imd.totalSupply();
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = ActorsHandler.trade.selector;
        selectors[1] = ActorsHandler.advanceTime.selector;
        selectors[2] = ActorsHandler.breakVault.selector;
        selectors[3] = ActorsHandler.toggleImdTransfers.selector;
        selectors[4] = ActorsHandler.flush.selector;
        selectors[5] = ActorsHandler.flushAll.selector;
        selectors[6] = ActorsHandler.flushInsideUnlock.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 80
    function invariant_eachBucketEarnedEqualsOwedPlusPaid() public view {
        uint256 sum;
        for (uint256 i; i < 5; ++i) {
            uint256 owed = hook.credits(HamsterHook.Bucket(i));
            assertEq(handler.accruedOf(i), owed + handler.deliveredOf(i), "bucket ledger broken");
            sum += owed;
        }
        assertEq(sum, hook.totalCredits());
        assertEq(manager.balanceOf(address(hook), uint256(uint160(IMD))), sum, "claims != credits");
        assertGe(imd.balanceOf(address(manager)), sum, "claims not backed by manager IMD");
    }

    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 80
    function invariant_paymentsLandAtFixedRecipientsOnly() public view {
        assertEq(vault.received(IHamsterVault.depositRewards.selector), handler.deliveredOf(0));
        assertEq(vault.received(IHamsterVault.depositDrip.selector), handler.deliveredOf(1));
        assertEq(vault.received(IHamsterVault.forwardJackpot.selector), handler.deliveredOf(2));
        assertEq(vault.received(IHamsterVault.forwardOracle.selector), handler.deliveredOf(3));
        assertEq(imd.balanceOf(TEAM), handler.deliveredOf(4));
        assertEq(imd.balanceOf(address(hook)), 0, "hook kept IMD");
        assertEq(imd.allowance(address(hook), VAULT), 0, "dangling vault approval");
        assertEq(imd.totalSupply(), imdSupply, "IMD supply changed");
        assertFalse(vault.reentrySucceeded());
    }

    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 80
    function invariant_launchStateNeverReopens() public view {
        assertTrue(hook.initialized());
        assertEq(hook.startedAt(), START);
        if (block.timestamp >= START + 48 minutes) assertEq(hook.taxBps(), 0);
        _assertSolvent();
    }
}

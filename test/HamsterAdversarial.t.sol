// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookTestBase} from "./HookTestBase.sol";
import {HamsterHook} from "../src/HamsterHook.sol";
import {IHamsterVault} from "../src/interfaces/IHamsterVault.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/// @dev Calls the hook's public flush while the PoolManager is already unlocked (as a router or a
/// malicious hookData consumer could during a swap).
contract UnlockedFlusher is IUnlockCallback {
    IPoolManager public immutable manager;
    HamsterHook public immutable hook;
    bool public lastOk;
    uint256 public lastAmount;

    constructor(IPoolManager manager_, HamsterHook hook_) {
        manager = manager_;
        hook = hook_;
    }

    function run(HamsterHook.Bucket bucket) external {
        manager.unlock(abi.encode(bucket));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        HamsterHook.Bucket bucket = abi.decode(data, (HamsterHook.Bucket));
        (lastOk, lastAmount) = hook.flush(bucket, type(uint256).max);
        return "";
    }
}

/// @dev Vault whose drip entry point burns all forwarded gas; the others pull normally.
contract GasBurningVault is IHamsterVault {
    address private constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;

    function depositRewards(uint256 amount) external {
        _pull(amount);
    }

    function depositDrip(uint256) external pure {
        while (true) {}
    }

    function forwardJackpot(uint256 amount) external {
        _pull(amount);
    }

    function forwardOracle(uint256 amount) external {
        _pull(amount);
    }

    function _pull(uint256 amount) private {
        (bool ok, bytes memory ret) = IMD.call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", msg.sender, address(this), amount)
        );
        require(ok && abi.decode(ret, (bool)), "pull failed");
    }
}

contract HamsterAdversarialTest is HookTestBase {
    using StateLibrary for IPoolManager;

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_taxScheduleMatchesBriefAndNeverIncreases(uint256 rawElapsed, uint256 rawLater) public {
        uint256 elapsed = bound(rawElapsed, 0, 30 days);
        uint256 later = bound(rawLater, elapsed, 30 days + 1);
        vm.warp(START + elapsed);
        uint256 minute = elapsed / 60;
        // Brief: 95% in minute 0, minus 2 points per FULL minute, 0 from minute 48.
        uint256 expected = minute >= 48 ? 0 : 9500 - 200 * minute;
        uint256 rate = hook.taxBps();
        assertEq(rate, expected);
        assertLe(rate + hook.HOOK_FEE_BPS() + hook.LP_FEE() / 100, 10_000, "fees above 100%");
        vm.warp(START + later);
        assertLe(hook.taxBps(), rate, "tax re-armed or increased");
    }

    function test_taxBoundarySecondsAroundEveryMinute() public {
        assertEq(hook.taxBps(), 9500);
        vm.warp(START + 59);
        assertEq(hook.taxBps(), 9500);
        vm.warp(START + 60);
        assertEq(hook.taxBps(), 9300);
        vm.warp(START + 47 minutes);
        assertEq(hook.taxBps(), 100);
        vm.warp(START + 48 minutes - 1);
        assertEq(hook.taxBps(), 100);
        vm.warp(START + 48 minutes);
        assertEq(hook.taxBps(), 0);
        vm.warp(type(uint64).max);
        assertEq(hook.taxBps(), 0);
    }

    function test_sellsAtMinuteZeroPayOnlyPermanentFeeAndNoTaxBuckets() public {
        // Buy first so the sell must move price back through the same range.
        _trade(true, true, 50 ether, false);
        uint256 drip = hook.credits(HamsterHook.Bucket.Drip);
        uint256 team = hook.credits(HamsterHook.Bucket.Team);
        assertEq(hook.taxBps(), 9500);
        for (uint256 i; i < 2; ++i) {
            Observation memory o = _trade(false, i == 0, 10 ether, false);
            assertEq(o.tax, 0);
            assertEq(o.fee, o.poolImd * 110 / 10_000, "sell fee is not 1.1% of gross IMD output");
            assertEq(o.userImd + o.fee, o.poolImd);
        }
        assertEq(hook.credits(HamsterHook.Bucket.Drip), drip, "sell fed drip");
        assertEq(hook.credits(HamsterHook.Bucket.Team), team, "sell paid team");
    }

    function test_buyAfterWindowPaysOnlyPermanentFeeAndNoTaxBuckets() public {
        vm.warp(START + 48 minutes);
        Observation memory o = _trade(true, true, 100 ether, false);
        assertEq(o.fee, 1.1 ether);
        assertEq(hook.credits(HamsterHook.Bucket.Drip), 0);
        assertEq(hook.credits(HamsterHook.Bucket.Team), 0);
        assertEq(hook.credits(HamsterHook.Bucket.Rewards), 0.5 ether);
        assertEq(hook.credits(HamsterHook.Bucket.Jackpot), 0.5 ether);
        assertEq(hook.credits(HamsterHook.Bucket.Oracle), 0.1 ether);
    }

    function test_exactSplitsAtMinute47() public {
        vm.warp(START + 47 minutes + 30);
        Observation memory o = _trade(true, true, 1000 ether, false);
        // 1.1% permanent + 1% tax.
        assertEq(o.fee, 21 ether);
        assertEq(hook.credits(HamsterHook.Bucket.Rewards), 5 ether);
        assertEq(hook.credits(HamsterHook.Bucket.Jackpot), 5 ether);
        assertEq(hook.credits(HamsterHook.Bucket.Drip), 8 ether);
        assertEq(hook.credits(HamsterHook.Bucket.Oracle), 1 ether + 1 ether);
        assertEq(hook.credits(HamsterHook.Bucket.Team), 1 ether);
    }

    function test_exactOutputBuyAtMinuteZeroChargesGrossNotPoolInput() public {
        Observation memory o = _trade(true, false, 1 ether, false);
        assertEq(o.hamsterAmount, 1 ether);
        // Pool receives 3.9% of what the buyer pays; 96.1% of the gross IMD is fee.
        assertEq(o.fee, o.userImd * 9610 / 10_000);
        assertEq(o.userImd - o.fee, o.poolImd);
        assertGt(o.userImd, o.poolImd * 25);
    }

    function test_flushWhileManagerUnlockedFailsWithoutLosingCredits() public {
        _trade(true, true, 100 ether, false);
        uint256 owed = hook.totalCredits();
        UnlockedFlusher flusher = new UnlockedFlusher(manager, hook);
        for (uint256 i; i < 5; ++i) {
            flusher.run(HamsterHook.Bucket(i));
            assertFalse(flusher.lastOk());
            assertEq(flusher.lastAmount(), 0);
        }
        assertEq(hook.totalCredits(), owed);
        assertEq(imd.balanceOf(VAULT), 0);
        assertEq(imd.balanceOf(TEAM), 0);
        _assertSolvent();
        assertEq(hook.flushAll(type(uint256).max), owed);
    }

    function test_outOfRangeBucketReverts() public {
        _trade(true, true, 100 ether, false);
        (bool ok,) = address(hook).call(abi.encodeWithSelector(HamsterHook.flush.selector, uint256(5), 1 ether));
        assertFalse(ok);
        (ok,) = address(hook).call(abi.encodeWithSignature("credits(uint8)", uint256(7)));
        assertFalse(ok);
        assertEq(hook.totalCredits(), 96.1 ether);
        _assertSolvent();
    }

    function test_flushWithNothingOwedIsNoOpForEveryBucket() public {
        for (uint256 i; i < 5; ++i) {
            (bool ok, uint256 amount) = hook.flush(HamsterHook.Bucket(i), type(uint256).max);
            assertTrue(ok);
            assertEq(amount, 0);
        }
        assertEq(hook.flushAll(type(uint256).max), 0);
        assertEq(vault.received(IHamsterVault.depositRewards.selector), 0);
    }

    function test_secondFlushOfSameBucketDeliversNothingMore() public {
        _trade(true, true, 100 ether, false);
        (bool ok, uint256 amount) = hook.flush(HamsterHook.Bucket.Drip, type(uint256).max);
        assertTrue(ok);
        assertEq(amount, 76 ether);
        (ok, amount) = hook.flush(HamsterHook.Bucket.Drip, type(uint256).max);
        assertTrue(ok);
        assertEq(amount, 0);
        assertEq(vault.received(IHamsterVault.depositDrip.selector), 76 ether);
        _assertSolvent();
    }

    function test_gasBurningVaultMethodNeverTouchesSwapsAndOtherBucketsStillFlush() public {
        vm.etch(VAULT, address(new GasBurningVault()).code);
        // Every swap mode still succeeds: no vault call on the swap path.
        _trade(true, true, 100 ether, false);
        _trade(true, false, 1 ether, false);
        _trade(false, true, 1 ether, false);
        _trade(false, false, 1 ether, false);
        uint256 drip = hook.credits(HamsterHook.Bucket.Drip);
        (bool ok,) = hook.flush{gas: 5_000_000}(HamsterHook.Bucket.Drip, type(uint256).max);
        assertFalse(ok);
        assertEq(hook.credits(HamsterHook.Bucket.Drip), drip);
        for (uint256 i; i < 5; ++i) {
            if (i == uint256(HamsterHook.Bucket.Drip)) continue;
            (ok,) = hook.flush(HamsterHook.Bucket(i), type(uint256).max);
            assertTrue(ok);
            assertEq(hook.credits(HamsterHook.Bucket(i)), 0);
        }
        assertEq(hook.totalCredits(), drip);
        _assertSolvent();
    }

    function test_singleRevertingVaultMethodIsIsolatedPerBucket() public {
        bytes4[4] memory selectors = [
            IHamsterVault.depositRewards.selector,
            IHamsterVault.depositDrip.selector,
            IHamsterVault.forwardJackpot.selector,
            IHamsterVault.forwardOracle.selector
        ];
        for (uint256 broken; broken < 4; ++broken) {
            _trade(true, true, 100 ether, false);
            for (uint256 j; j < 4; ++j) {
                vault.setMode(selectors[j], j == broken ? 1 : 0);
            }
            uint256 stuck = hook.credits(HamsterHook.Bucket(broken));
            uint256 delivered = hook.flushAll(type(uint256).max);
            assertEq(hook.totalCredits(), stuck, "only the broken bucket may remain");
            assertGt(delivered, 0);
            vault.setMode(selectors[broken], 0);
            assertEq(hook.flushAll(type(uint256).max), stuck);
            assertEq(hook.totalCredits(), 0);
            _assertSolvent();
        }
    }

    function test_hookRefusesEthAndHoldsNoTokensAfterSwaps() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(hook).call{value: 1}("");
        assertFalse(ok);
        _trade(true, true, 10 ether, false);
        _trade(false, false, 1 ether, false);
        assertEq(address(hook).balance, 0);
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(hamster.balanceOf(address(hook)), 0);
        assertEq(manager.balanceOf(address(hook), uint256(uint160(address(hamster)))), 0, "fee taken in HAMSTER");
    }

    function test_poolManagerRefusesForeignInitializerOtherKeysAndRepeatInit() public {
        HamsterHook fresh = _deployHook(manager, address(hamster), address(this), TEAM);
        PoolKey memory freshKey = fresh.poolKey();
        // A stranger front-running the factory cannot start the anti-snipe clock.
        vm.prank(makeAddr("sniper"));
        vm.expectRevert();
        manager.initialize(freshKey, Q96);
        assertFalse(fresh.initialized());
        assertEq(fresh.taxBps(), 0);
        // The factory cannot open a second pool on this hook with another fee or spacing.
        PoolKey memory other = fresh.poolKey();
        other.fee = 3000;
        vm.expectRevert();
        manager.initialize(other, Q96);
        other = fresh.poolKey();
        other.tickSpacing = 10;
        vm.expectRevert();
        manager.initialize(other, Q96);
        assertFalse(fresh.initialized());
        // Swapping before initialization is impossible.
        vm.expectRevert();
        router.swap(freshKey, SwapParams(true, -1 ether, 4295128740), "");
        vm.warp(START + 5 minutes);
        manager.initialize(freshKey, Q96);
        assertEq(fresh.startedAt(), START + 5 minutes);
        assertEq(fresh.taxBps(), 9500);
        vm.warp(START + 60 minutes);
        vm.expectRevert();
        manager.initialize(freshKey, Q96);
        assertEq(fresh.startedAt(), START + 5 minutes);
        assertEq(fresh.taxBps(), 0);
    }

    function test_splittingABuyIntoManySmallBuysSavesAtMostRoundingDust() public {
        vm.warp(START + 48 minutes);
        uint256 snapshot = vm.snapshotState();
        uint256 single = _trade(true, true, 1 ether, false).fee;
        assertTrue(vm.revertToState(snapshot));
        uint256 split;
        for (uint256 i; i < 10; ++i) {
            split += _trade(true, true, 0.1 ether, false).fee;
        }
        assertLe(single - split, 10, "splitting saved more than rounding");
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_userNeverPaysMoreThanBudgetNorGetsLessThanAskedOnFullFills(
        uint96 rawAmount,
        uint8 rawMinute,
        uint8 mode
    ) public {
        uint256 amount = bound(rawAmount, 1, 500 ether);
        vm.warp(START + bound(rawMinute, 0, 60) * 60);
        bool buy = mode % 2 == 0;
        bool exactInput = (mode >> 1) % 2 == 0;
        Observation memory o = _trade(buy, exactInput, amount, false);
        if (buy && exactInput) assertEq(o.userImd, amount, "exact-input buy did not spend exact budget");
        if (buy && !exactInput) assertEq(o.hamsterAmount, amount, "exact-output buy short");
        if (!buy && exactInput) assertEq(o.hamsterAmount, amount, "exact-input sell did not spend exact HAMSTER");
        if (!buy && !exactInput) assertEq(o.userImd, amount, "exact-output sell net IMD short");
        uint256 rate = 110 + (buy ? hook.taxBps() : 0);
        assertEq(o.fee, o.gross * rate / 10_000);
    }
}

/// @dev Same checks with IMD sorted as currency0, the other half of the address space.
contract HamsterImdFirstTest is HookTestBase {
    function setUp() public override {
        _setup(true, false);
    }

    function test_orderingIsImdFirst() public view {
        assertTrue(hook.imdIsCurrency0());
    }

    function test_everyTaxMinuteAllModesImdFirst() public {
        for (uint256 minute; minute <= 48; ++minute) {
            vm.warp(START + minute * 60 + 30);
            uint256 expected = minute < 48 ? 9500 - 200 * minute : 0;
            Observation memory a = _trade(true, true, 1 ether, false);
            assertEq(a.userImd, 1 ether);
            assertEq(a.fee, 1 ether * (110 + expected) / 10_000);
            Observation memory b = _trade(true, false, 0.01 ether, false);
            assertEq(b.hamsterAmount, 0.01 ether);
            assertEq(b.fee, b.userImd * (110 + expected) / 10_000);
            assertEq(_trade(false, true, 0.01 ether, false).tax, 0);
            assertEq(_trade(false, false, 0.01 ether, false).tax, 0);
        }
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_realDeltasImdFirst(uint96 rawAmount, uint8 rawMinute, uint8 mode, bool limited) public {
        uint256 amount = bound(rawAmount, 1, 1000 ether);
        vm.warp(START + bound(rawMinute, 0, 60) * 60);
        bool buy = mode % 2 == 0;
        bool exactInput = (mode >> 1) % 2 == 0;
        Observation memory o = _trade(buy, exactInput, amount, limited);
        if (!buy) assertEq(o.tax, 0);
        assertLe(o.fee + o.gross * 125 / 10_000, o.gross);
    }

    function test_revertingVaultAllModesImdFirst() public {
        vault.setMode(IHamsterVault.depositRewards.selector, 1);
        vault.setMode(IHamsterVault.depositDrip.selector, 1);
        vault.setMode(IHamsterVault.forwardJackpot.selector, 1);
        vault.setMode(IHamsterVault.forwardOracle.selector, 1);
        for (uint256 mode; mode < 4; ++mode) {
            _trade(mode < 2, mode % 2 == 0, 5 ether, false);
            hook.flushAll(type(uint256).max);
        }
        assertEq(
            hook.totalCredits(),
            hook.credits(HamsterHook.Bucket.Rewards) + hook.credits(HamsterHook.Bucket.Drip)
                + hook.credits(HamsterHook.Bucket.Jackpot) + hook.credits(HamsterHook.Bucket.Oracle)
        );
        assertEq(hook.credits(HamsterHook.Bucket.Team), 0);
        assertGt(imd.balanceOf(TEAM), 0);
        _assertSolvent();
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookTestBase} from "./HookTestBase.sol";
import {HamsterHook} from "../src/HamsterHook.sol";
import {IHamsterVault} from "../src/interfaces/IHamsterVault.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

contract HamsterHookTest is HookTestBase {
    using StateLibrary for IPoolManager;

    function test_initializationPermissionsAndNoRearm() public {
        assertTrue(hook.initialized());
        assertEq(hook.startedAt(), START);
        assertEq(hook.taxBps(), 9500);
        assertEq(HookFlags.flagsOf(address(hook)), HookFlags.HAMSTER);
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize && p.beforeAddLiquidity && p.beforeSwap && p.afterSwap);
        assertTrue(p.beforeSwapReturnDelta && p.afterSwapReturnDelta);
        assertFalse(p.beforeRemoveLiquidity || p.afterRemoveLiquidity || p.afterAddLiquidity);
        assertFalse(p.afterInitialize || p.beforeDonate || p.afterDonate);
        assertFalse(p.afterAddLiquidityReturnDelta || p.afterRemoveLiquidityReturnDelta);
        assertEq(uint256(HookFlags.HAMSTER), 0x28cc);
        vm.warp(START + 100 days);
        vm.prank(address(manager));
        vm.expectRevert(HamsterHook.AlreadyInitialized.selector);
        hook.beforeInitialize(address(this), key, Q96);
        assertEq(hook.startedAt(), START);
        assertEq(hook.taxBps(), 0);
    }

    function test_allCallbacksRejectUnauthorizedCallers() public {
        vm.expectRevert(HamsterHook.OnlyPoolManager.selector);
        hook.beforeInitialize(address(this), key, Q96);
        SwapParams memory params = _params(true, true, 1 ether, false);
        vm.expectRevert(HamsterHook.OnlyPoolManager.selector);
        hook.beforeSwap(address(this), key, params, "");
        vm.expectRevert(HamsterHook.OnlyPoolManager.selector);
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");
        vm.expectRevert(HamsterHook.OnlyPoolManager.selector);
        hook.beforeAddLiquidity(address(this), key, ModifyLiquidityParams(-600, 600, 1, bytes32(0)), "");
        vm.expectRevert(HamsterHook.OnlyPoolManager.selector);
        hook.unlockCallback(abi.encode(1));
        vm.expectRevert(HamsterHook.OnlySelf.selector);
        hook.simulateSwap(params);
        vm.expectRevert(HamsterHook.OnlySelf.selector);
        hook.deliverCredit(HamsterHook.Bucket.Team, 1);
        vm.prank(address(manager));
        vm.expectRevert(HamsterHook.UnexpectedUnlock.selector);
        hook.unlockCallback(abi.encode(1));
    }

    function test_wrongPoolAndWrongInitializerRejected() public {
        HamsterHook fresh = _deployHook(manager, address(hamster), address(this), TEAM);
        PoolKey memory freshKey = fresh.poolKey();
        SwapParams memory params = _params(true, true, 1 ether, false);
        vm.prank(address(manager));
        vm.expectRevert(HamsterHook.OnlyFactory.selector);
        fresh.beforeInitialize(TEAM, freshKey, Q96);
        vm.prank(address(manager));
        vm.expectRevert(HamsterHook.NotInitialized.selector);
        fresh.beforeSwap(address(router), freshKey, params, "");
        PoolKey memory bad = key;
        bad.fee = 3000;
        vm.prank(address(manager));
        vm.expectRevert(HamsterHook.WrongPool.selector);
        hook.beforeInitialize(address(this), bad, Q96);
        vm.prank(address(manager));
        vm.expectRevert(HamsterHook.WrongPool.selector);
        hook.beforeSwap(address(router), bad, params, "");
        vm.prank(address(manager));
        vm.expectRevert(HamsterHook.WrongPool.selector);
        hook.afterSwap(address(router), bad, params, BalanceDelta.wrap(0), "");
        vm.prank(address(manager));
        vm.expectRevert(HamsterHook.WrongPool.selector);
        hook.beforeAddLiquidity(address(this), bad, ModifyLiquidityParams(-600, 600, 1, bytes32(0)), "");
        vm.prank(address(manager));
        vm.expectRevert(HamsterHook.NotInitialized.selector);
        fresh.beforeAddLiquidity(address(this), freshKey, ModifyLiquidityParams(-600, 600, 1, bytes32(0)), "");
    }

    function test_everyMinuteBothBuyModesAndUntaxedSells() public {
        for (uint256 minute; minute <= 49; ++minute) {
            vm.warp(START + minute * 60);
            uint256 expected = minute < 48 ? 9500 - 200 * minute : 0;
            assertEq(hook.taxBps(), expected);
            Observation memory exactInBuy = _trade(true, true, 1 ether, false);
            assertEq(exactInBuy.userImd, 1 ether);
            assertEq(exactInBuy.tax, 1 ether * expected / 10_000);
            Observation memory exactOutBuy = _trade(true, false, 0.01 ether, false);
            assertEq(exactOutBuy.hamsterAmount, 0.01 ether);
            Observation memory exactInSell = _trade(false, true, 0.01 ether, false);
            assertEq(exactInSell.hamsterAmount, 0.01 ether);
            assertEq(exactInSell.tax, 0);
            Observation memory exactOutSell = _trade(false, false, 0.01 ether, false);
            assertEq(exactOutSell.userImd, 0.01 ether);
            assertEq(exactOutSell.tax, 0);
            vm.warp(START + minute * 60 + 59);
            assertEq(hook.taxBps(), expected, "tax changed before full minute");
        }
    }

    function test_fullAndPartialFillsAllModesBothCurrencyOrderings() public {
        for (uint256 ordering; ordering < 2; ++ordering) {
            if (ordering == 1) _setup(true, false);
            for (uint256 minute; minute < 2; ++minute) {
                vm.warp(START + minute * 48 minutes);
                for (uint256 mode; mode < 4; ++mode) {
                    bool buy = mode < 2;
                    bool exactInput = mode % 2 == 0;
                    Observation memory full = _trade(buy, exactInput, 1 ether, false);
                    if (exactInput) assertEq(buy ? full.userImd : full.hamsterAmount, 1 ether);
                    else assertEq(buy ? full.hamsterAmount : full.userImd, 1 ether);
                    Observation memory limited = _trade(buy, exactInput, 10_000 ether, true);
                    assertGt(limited.userImd, 0);
                    assertGt(limited.hamsterAmount, 0);
                    assertLt(
                        exactInput
                            ? (buy ? limited.userImd : limited.hamsterAmount)
                            : (buy ? limited.hamsterAmount : limited.userImd),
                        10_000 ether
                    );
                }
            }
        }
    }

    function test_buyOnFreshManagerWithOnlyHamsterLiquidity() public {
        for (uint256 ordering; ordering < 2; ++ordering) {
            _setup(ordering == 1, true);
            assertEq(imd.balanceOf(address(manager)), 0, "test must begin with no IMD reserve");
            uint256 vaultBefore = imd.balanceOf(VAULT);
            Observation memory o = _trade(true, true, 100 ether, false);
            assertEq(o.userImd, 100 ether);
            assertEq(o.fee, 96.1 ether);
            assertEq(imd.balanceOf(address(hook)), 0);
            assertEq(imd.balanceOf(VAULT), vaultBefore);
            assertEq(hook.flushAll(type(uint128).max), o.fee);
            _assertSolvent();
        }
    }

    function test_exactSplitsAndPermissionlessFlush() public {
        Observation memory o = _trade(true, true, 100 ether, false);
        assertEq(o.fee, 96.1 ether);
        assertEq(hook.credits(HamsterHook.Bucket.Rewards), 0.5 ether);
        assertEq(hook.credits(HamsterHook.Bucket.Jackpot), 0.5 ether);
        assertEq(hook.credits(HamsterHook.Bucket.Drip), 76 ether);
        assertEq(hook.credits(HamsterHook.Bucket.Oracle), 9.6 ether);
        assertEq(hook.credits(HamsterHook.Bucket.Team), 9.5 ether);
        vm.prank(makeAddr("unrelated keeper"));
        assertEq(hook.flushAll(type(uint256).max), 96.1 ether);
        assertEq(vault.received(IHamsterVault.depositRewards.selector), 0.5 ether);
        assertEq(vault.received(IHamsterVault.depositDrip.selector), 76 ether);
        assertEq(vault.received(IHamsterVault.forwardJackpot.selector), 0.5 ether);
        assertEq(vault.received(IHamsterVault.forwardOracle.selector), 9.6 ether);
        assertEq(imd.balanceOf(TEAM), 9.5 ether);
        assertEq(imd.allowance(address(hook), VAULT), 0);
        assertEq(imd.balanceOf(address(hook)), 0);
        _assertSolvent();
    }

    function test_revertingVaultNeverStopsAnySwapAndRetryPreservesCredits() public {
        vault.setMode(IHamsterVault.depositRewards.selector, 1);
        vault.setMode(IHamsterVault.depositDrip.selector, 1);
        vault.setMode(IHamsterVault.forwardJackpot.selector, 1);
        vault.setMode(IHamsterVault.forwardOracle.selector, 1);
        _trade(true, true, 100 ether, false);
        _trade(true, false, 1 ether, false);
        _trade(false, true, 1 ether, false);
        _trade(false, false, 1 ether, false);
        uint256 owed = hook.totalCredits();
        uint256 team = hook.credits(HamsterHook.Bucket.Team);
        assertEq(hook.flushAll(type(uint256).max), team);
        assertEq(hook.totalCredits(), owed - team);
        assertEq(imd.balanceOf(VAULT), 0);
        assertEq(imd.allowance(address(hook), VAULT), 0);
        _assertSolvent();
        vault.setMode(IHamsterVault.depositRewards.selector, 0);
        vault.setMode(IHamsterVault.depositDrip.selector, 0);
        vault.setMode(IHamsterVault.forwardJackpot.selector, 0);
        vault.setMode(IHamsterVault.forwardOracle.selector, 0);
        assertEq(hook.flushAll(type(uint256).max), owed - team);
        assertEq(hook.totalCredits(), 0);
        _assertSolvent();
    }

    function test_missingVaultNoPullShortPullAndReentry() public {
        _trade(true, true, 100 ether, false);
        uint256 owed = hook.credits(HamsterHook.Bucket.Rewards);
        for (uint256 mode = 2; mode <= 3; ++mode) {
            vault.setMode(IHamsterVault.depositRewards.selector, mode);
            (bool ok, uint256 sent) = hook.flush(HamsterHook.Bucket.Rewards, type(uint256).max);
            assertFalse(ok);
            assertEq(sent, 0);
            assertEq(hook.credits(HamsterHook.Bucket.Rewards), owed);
            assertEq(vault.received(IHamsterVault.depositRewards.selector), 0);
            assertEq(imd.allowance(address(hook), VAULT), 0);
            _assertSolvent();
        }
        bytes memory code = VAULT.code;
        vm.etch(VAULT, "");
        (bool missing,) = hook.flush(HamsterHook.Bucket.Rewards, type(uint256).max);
        assertFalse(missing);
        _assertSolvent();
        vm.etch(VAULT, code);
        vault.setMode(IHamsterVault.depositRewards.selector, 4);
        (bool success,) = hook.flush(HamsterHook.Bucket.Rewards, owed);
        assertTrue(success);
        assertFalse(vault.reentrySucceeded());
        assertEq(hook.credits(HamsterHook.Bucket.Rewards), 0);
        assertEq(vault.received(IHamsterVault.depositRewards.selector), owed);
        _assertSolvent();
    }

    function test_failedTokenTransferDoesNotDestroyCredits() public {
        _trade(true, true, 100 ether, false);
        uint256 owed = hook.totalCredits();
        imd.setFailTransfers(true);
        assertEq(hook.flushAll(type(uint256).max), 0);
        assertEq(hook.totalCredits(), owed);
        _assertSolvent();
        imd.setFailTransfers(false);
        assertEq(hook.flushAll(type(uint256).max), owed);
        _assertSolvent();
    }

    function test_chunkedFlushAndZeroNoOp() public {
        _trade(true, true, 100 ether, false);
        (bool ok, uint256 sent) = hook.flush(HamsterHook.Bucket.Drip, 0);
        assertTrue(ok);
        assertEq(sent, 0);
        (ok, sent) = hook.flush(HamsterHook.Bucket.Drip, 1 ether);
        assertTrue(ok);
        assertEq(sent, 1 ether);
        assertEq(hook.credits(HamsterHook.Bucket.Drip), 75 ether);
        _assertSolvent();
    }

    function test_flushLimitBelowFloorIsRaisedSoCreditsAreNotDeliveredAsDust() public {
        _trade(true, true, 100 ether, false);
        assertEq(hook.MIN_FLUSH_AMOUNT(), 1 ether);
        // A caller-chosen 1 wei limit on a 76 IMD bucket delivers a whole 1 IMD piece, not 1 wei.
        vm.prank(makeAddr("griefer"));
        (bool ok, uint256 sent) = hook.flush(HamsterHook.Bucket.Drip, 1);
        assertTrue(ok);
        assertEq(sent, 1 ether);
        assertEq(vault.received(IHamsterVault.depositDrip.selector), 1 ether);
        // A bucket below the floor is delivered whole in one call, never split.
        assertEq(hook.credits(HamsterHook.Bucket.Rewards), 0.5 ether);
        vm.prank(makeAddr("griefer"));
        (ok, sent) = hook.flush(HamsterHook.Bucket.Rewards, 1);
        assertTrue(ok);
        assertEq(sent, 0.5 ether);
        assertEq(vault.received(IHamsterVault.depositRewards.selector), 0.5 ether);
        assertEq(hook.credits(HamsterHook.Bucket.Rewards), 0);
        // flushAll applies the same floor per bucket; a limit at the floor is honored exactly.
        uint256 remaining = hook.totalCredits();
        assertEq(hook.flushAll(1 ether - 1), 1 ether + 0.5 ether + 1 ether + 1 ether);
        assertEq(hook.totalCredits(), remaining - 3.5 ether);
        _assertSolvent();
    }

    function test_noHookDataBypassAndFactoryCanCollectFees() public {
        uint256 beforeCredits = hook.totalCredits();
        router.swap(key, _params(true, true, 100 ether, false), abi.encode(true, TEAM, address(hook)));
        assertEq(hook.totalCredits() - beforeCredits, 96.1 ether);
        uint256 owed = hook.totalCredits();
        BalanceDelta fees = _modifyAsFactory(ModifyLiquidityParams(-600, 600, 0, bytes32(0)));
        assertGe(fees.amount0(), 0);
        assertGe(fees.amount1(), 0);
        assertTrue(fees.amount0() > 0 || fees.amount1() > 0);
        assertEq(hook.totalCredits(), owed, "liquidity collection must not pay hook fees");
    }

    function test_dustTradesAllModes() public {
        for (uint256 amount = 1; amount <= 30; ++amount) {
            _trade(true, true, amount, false);
            _trade(true, false, amount, false);
            _trade(false, true, amount, false);
            _trade(false, false, amount, false);
        }
    }

    function testFuzz_realDeltasAndFeeConservation(
        uint96 rawAmount,
        uint8 rawMinute,
        bool buy,
        bool exactInput,
        bool limited
    ) public {
        uint256 amount = bound(rawAmount, 1, 1000 ether);
        uint256 minute = bound(rawMinute, 0, 100);
        vm.warp(START + minute * 60);
        Observation memory o = _trade(buy, exactInput, amount, limited);
        if (!buy) assertEq(o.tax, 0);
        // Even adding the full 1.25% LP rate to the same gross basis cannot exceed 100%.
        assertLe(o.fee + o.gross * 125 / 10_000, o.gross);
        uint256 specified = exactInput ? (buy ? o.userImd : o.hamsterAmount) : (buy ? o.hamsterAmount : o.userImd);
        assertLe(specified, amount, "overfilled specified amount");
    }
}

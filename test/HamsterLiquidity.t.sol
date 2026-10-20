// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookTestBase} from "./HookTestBase.sol";
import {HamsterHook} from "../src/HamsterHook.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TestRouter} from "./mocks/TestRouter.sol";

/// @notice Liquidity added by anyone but the factory may not hold IMD while the anti-snipe tax is live,
/// because an IMD-side position is a resting bid that untaxed sells fill without any hook fee or tax.
contract HamsterLiquidityTest is HookTestBase {
    using StateLibrary for IPoolManager;

    function _expectTaxedLiquidityRevert() internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(HamsterHook.ImdLiquidityDuringTax.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    /// @dev Ranges relative to the current tick: IMD-only, two-sided, and HAMSTER-only.
    function _ranges(int24 tick) internal view returns (int24[2][3] memory r) {
        bool imdFirst = hook.imdIsCurrency0();
        // IMD is currency0 when it sorts first, so an IMD-only range sits above the tick; else below.
        r[0] = imdFirst ? [tick + 60, tick + 660] : [tick - 660, tick - 60];
        r[1] = [tick - 600, tick + 600];
        r[2] = imdFirst ? [tick - 600, tick] : [tick + 60, tick + 660];
    }

    function test_rangeOrderCannotAcquireHamsterDuringTaxInEitherOrdering() public {
        for (uint256 ordering; ordering < 2; ++ordering) {
            _setup(ordering == 1, false);
            TestRouter sniper = new TestRouter(manager);
            imd.mint(address(sniper), 1e30);
            hamster.mint(address(sniper), 1e30);
            int24[2][3] memory r = _ranges(0);
            for (uint256 minute; minute < 48; minute += 47) {
                vm.warp(START + minute * 60);
                assertGt(hook.taxBps(), 0);
                _expectTaxedLiquidityRevert();
                sniper.modify(key, ModifyLiquidityParams(r[0][0], r[0][1], int256(LIQUIDITY), bytes32(0)));
                _expectTaxedLiquidityRevert();
                sniper.modify(key, ModifyLiquidityParams(r[1][0], r[1][1], int256(LIQUIDITY), bytes32(0)));
            }
            assertEq(hamster.balanceOf(address(sniper)), 1e30, "sniper acquired HAMSTER through liquidity");
            assertEq(imd.balanceOf(address(sniper)), 1e30);
            // From minute 48 the tax is gone and any position is welcome.
            vm.warp(START + 48 minutes);
            assertEq(hook.taxBps(), 0);
            uint256 creditsBefore = hook.totalCredits();
            sniper.modify(key, ModifyLiquidityParams(r[0][0], r[0][1], int256(LIQUIDITY), bytes32(0)));
            sniper.modify(key, ModifyLiquidityParams(r[1][0], r[1][1], int256(LIQUIDITY), bytes32(0)));
            assertEq(hook.totalCredits(), creditsBefore, "liquidity never pays hook fees");
            uint256 hamsterAfterAdds = hamster.balanceOf(address(sniper));
            // An untaxed sell crosses the whole IMD-only range, filling the resting bid.
            _trade(false, true, 100_000 ether, false);
            sniper.modify(key, ModifyLiquidityParams(r[0][0], r[0][1], -int256(LIQUIDITY), bytes32(0)));
            assertGt(hamster.balanceOf(address(sniper)), hamsterAfterAdds, "range order fills after the tax");
            _assertSolvent();
        }
    }

    function test_hamsterOnlyPositionsCollectAndRemoveFreelyDuringTax() public {
        for (uint256 ordering; ordering < 2; ++ordering) {
            _setup(ordering == 1, false);
            TestRouter lp = new TestRouter(manager);
            hamster.mint(address(lp), 1e30);
            int24[2][3] memory r = _ranges(0);
            uint256 creditsBefore = hook.totalCredits();
            lp.modify(key, ModifyLiquidityParams(r[2][0], r[2][1], int256(LIQUIDITY), bytes32(0)));
            assertEq(imd.balanceOf(address(lp)), 0, "position was funded with HAMSTER only");
            assertLt(hamster.balanceOf(address(lp)), 1e30);
            assertEq(hook.totalCredits(), creditsBefore);
            // A taxed buy moves the price into the position; collecting and removing stay open to the LP.
            Observation memory o = _trade(true, true, 1_000_000 ether, false);
            assertEq(o.fee, 961_000 ether);
            BalanceDelta fees = lp.modify(key, ModifyLiquidityParams(r[2][0], r[2][1], 0, bytes32(0)));
            assertTrue(fees.amount0() > 0 || fees.amount1() > 0, "fee collection with zero delta");
            lp.modify(key, ModifyLiquidityParams(r[2][0], r[2][1], -int256(LIQUIDITY), bytes32(0)));
            assertGt(imd.balanceOf(address(lp)), 0, "the LP sold HAMSTER to a taxed buyer");
            assertEq(hook.totalCredits() - creditsBefore, o.fee, "liquidity operations accrued nothing");
            _assertSolvent();
        }
    }

    function test_factoryMayAddAnyLiquidityDuringTaxAndTopUpLater() public {
        for (uint256 ordering; ordering < 2; ++ordering) {
            _setup(ordering == 1, false);
            int24[2][3] memory r = _ranges(0);
            assertEq(hook.taxBps(), 9500);
            for (uint256 i; i < 3; ++i) {
                _modifyAsFactory(ModifyLiquidityParams(r[i][0], r[i][1], int256(LIQUIDITY), bytes32(uint256(1))));
            }
            _trade(true, true, 100 ether, false);
            _trade(false, true, 100 ether, false);
            BalanceDelta fees = _modifyAsFactory(ModifyLiquidityParams(-600, 600, 0, bytes32(0)));
            assertTrue(fees.amount0() > 0 || fees.amount1() > 0, "factory fee collection with zero delta");
            _assertSolvent();
        }
    }

    function test_boundaryTicksAreClassifiedExactlyAsThePoolDoes() public {
        for (uint256 ordering; ordering < 2; ++ordering) {
            _setup(ordering == 1, false);
            (, int24 tick,,) = manager.getSlot0(key.toId());
            assertEq(tick, 0);
            TestRouter lp = new TestRouter(manager);
            imd.mint(address(lp), 1e30);
            hamster.mint(address(lp), 1e30);
            bool imdFirst = hook.imdIsCurrency0();
            // Pool.modifyLiquidity: tick < tickLower holds currency0 only, tick >= tickUpper holds
            // currency1 only, anything else is in range. [0, 60] at tick 0 is in range, so it is
            // refused even though the price may sit exactly on its lower edge.
            int24[2][3] memory ranges = [[int24(-60), int24(0)], [int24(0), int24(60)], [int24(60), int24(120)]];
            bool[3] memory allowed = [imdFirst, false, !imdFirst];
            for (uint256 i; i < 3; ++i) {
                uint256 imdBefore = imd.balanceOf(address(lp));
                if (!allowed[i]) _expectTaxedLiquidityRevert();
                lp.modify(key, ModifyLiquidityParams(ranges[i][0], ranges[i][1], int256(LIQUIDITY), bytes32(0)));
                assertEq(imd.balanceOf(address(lp)), imdBefore, "boundary position took no IMD");
            }
        }
    }

    function test_beforeAddLiquidityDirectCallsFollowTheSameRule() public {
        ModifyLiquidityParams memory imdSide = ModifyLiquidityParams(60, 660, 1, bytes32(0));
        ModifyLiquidityParams memory hamsterSide = ModifyLiquidityParams(-660, -60, 1, bytes32(0));
        if (!hook.imdIsCurrency0()) (imdSide, hamsterSide) = (hamsterSide, imdSide);
        vm.prank(address(manager));
        vm.expectRevert(HamsterHook.ImdLiquidityDuringTax.selector);
        hook.beforeAddLiquidity(address(router), key, imdSide, "");
        vm.prank(address(manager));
        assertEq(hook.beforeAddLiquidity(address(router), key, hamsterSide, ""), IHooks.beforeAddLiquidity.selector);
        vm.prank(address(manager));
        assertEq(hook.beforeAddLiquidity(address(this), key, imdSide, ""), IHooks.beforeAddLiquidity.selector);
        vm.warp(START + 48 minutes);
        vm.prank(address(manager));
        assertEq(hook.beforeAddLiquidity(address(router), key, imdSide, ""), IHooks.beforeAddLiquidity.selector);
    }

    function testFuzz_noNonFactoryPositionHoldsImdWhileTaxed(int24 rawLower, int24 rawWidth, uint8 rawMinute) public {
        int24 lower = int24(bound(rawLower, -6000, 6000) / 60 * 60);
        int24 upper = lower + int24(bound(rawWidth, 1, 100)) * 60;
        vm.warp(START + bound(rawMinute, 0, 47) * 60);
        TestRouter lp = new TestRouter(manager);
        imd.mint(address(lp), 1e30);
        hamster.mint(address(lp), 1e30);
        (, int24 tick,,) = manager.getSlot0(key.toId());
        bool hamsterOnly = hook.imdIsCurrency0() ? tick >= upper : tick < lower;
        if (!hamsterOnly) _expectTaxedLiquidityRevert();
        lp.modify(key, ModifyLiquidityParams(lower, upper, int256(LIQUIDITY), bytes32(0)));
        assertEq(imd.balanceOf(address(lp)), 1e30, "no IMD entered the pool through liquidity");
    }
}

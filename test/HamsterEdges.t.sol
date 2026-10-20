// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookTestBase} from "./HookTestBase.sol";
import {HamsterHook} from "../src/HamsterHook.sol";
import {HamsterToken} from "../src/HamsterToken.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TestRouter} from "./mocks/TestRouter.sol";

contract HamsterEdgesTest is HookTestBase {
    using StateLibrary for IPoolManager;

    function test_constructorRejectsMissingParametersAndWrongAddressBits() public {
        vm.expectRevert(HamsterHook.InvalidAddress.selector);
        new HamsterHook(IPoolManager(address(0)), address(hamster), address(this), TEAM);
        vm.expectRevert(HamsterHook.InvalidAddress.selector);
        new HamsterHook(manager, address(0), address(this), TEAM);
        vm.expectRevert(HamsterHook.InvalidAddress.selector);
        new HamsterHook(manager, IMD, address(this), TEAM);
        vm.expectRevert(HamsterHook.InvalidAddress.selector);
        new HamsterHook(manager, address(hamster), address(0), TEAM);
        vm.expectRevert(HamsterHook.InvalidAddress.selector);
        new HamsterHook(manager, address(hamster), address(this), address(0));
        address wrongFlags = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        assertFalse(HookFlags.matches(wrongFlags, HookFlags.HAMSTER));
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, wrongFlags));
        new HamsterHook(manager, address(hamster), address(this), TEAM);
    }

    function test_predictedPoolCannotInitializeBeforeHookHasCode() public {
        PoolKey memory unbuilt = key;
        unbuilt.hooks = IHooks(address(uint160(HookFlags.HAMSTER)));
        vm.expectRevert();
        manager.initialize(unbuilt, Q96);
    }

    function test_immutableKeyRejectsAllOtherComponents() public {
        SwapParams memory params = _params(true, true, 1 ether, false);
        for (uint256 i; i < 5; ++i) {
            PoolKey memory wrong = hook.poolKey();
            if (i == 0) wrong.currency0 = Currency.wrap(makeAddr("other currency0"));
            if (i == 1) wrong.currency1 = Currency.wrap(makeAddr("other currency1"));
            if (i == 2) wrong.tickSpacing = 10;
            if (i == 3) wrong.fee = 0x800000;
            if (i == 4) wrong.hooks = IHooks(makeAddr("other hook"));
            vm.prank(address(manager));
            vm.expectRevert(HamsterHook.WrongPool.selector);
            hook.beforeSwap(address(router), wrong, params, "");
        }
    }

    function test_zeroLiquidityDoesNotPayFeesInAnyMode() public {
        _modifyAsFactory(ModifyLiquidityParams(-600, 600, -int256(LIQUIDITY), bytes32(0)));
        uint256 snapshot = vm.snapshotState();
        for (uint256 mode; mode < 4; ++mode) {
            if (mode != 0) assertTrue(vm.revertToState(snapshot));
            Observation memory o = _trade(mode < 2, mode % 2 == 0, 100 ether, false);
            assertEq(o.fee, 0);
            assertEq(o.userImd, 0);
            assertEq(o.hamsterAmount, 0);
        }
    }

    function test_invalidLimitAndOversizeRevertWithoutCreditsOrPriceChanges() public {
        SwapParams memory params = _params(true, true, 1 ether, false);
        params.sqrtPriceLimitX96 = Q96;
        vm.expectRevert();
        router.swap(key, params, "");
        (uint160 price,,,) = manager.getSlot0(key.toId());
        assertEq(price, Q96);
        assertEq(hook.totalCredits(), 0);
        params = _params(true, true, uint256(uint128(type(int128).max)) + 1, false);
        vm.prank(address(manager));
        vm.expectRevert(HamsterHook.AmountTooLarge.selector);
        hook.beforeSwap(address(router), key, params, "");
        params.amountSpecified = type(int256).min;
        vm.prank(address(manager));
        vm.expectRevert(HamsterHook.AmountTooLarge.selector);
        hook.beforeSwap(address(router), key, params, "");
        _assertSolvent();
    }

    function test_simulationCannotCommitStateOrBecomeFreeSwap() public {
        SwapParams memory params = _params(true, true, 100 ether, false);
        // Even a test impersonating the hook cannot commit the simulator; a locked manager also refuses it.
        vm.prank(address(hook));
        vm.expectRevert();
        hook.simulateSwap(params);
        (uint160 price,,,) = manager.getSlot0(key.toId());
        assertEq(price, Q96);
        assertEq(hook.totalCredits(), 0);
        _assertSolvent();
        _trade(true, true, 100 ether, false);
        assertEq(hook.totalCredits(), 96.1 ether);
    }

    function test_zeroTimestampInitializationStillCannotRearm() public {
        vm.warp(0);
        HamsterHook zeroStart = _deployHook(manager, address(hamster), address(this), TEAM);
        PoolKey memory zeroKey = zeroStart.poolKey();
        manager.initialize(zeroKey, Q96);
        assertTrue(zeroStart.initialized());
        assertEq(zeroStart.startedAt(), 0);
        assertEq(zeroStart.taxBps(), 9500);
        vm.warp(48 minutes);
        assertEq(zeroStart.taxBps(), 0);
        vm.prank(address(manager));
        vm.expectRevert(HamsterHook.AlreadyInitialized.selector);
        zeroStart.beforeInitialize(address(this), zeroKey, Q96);
    }

    function test_newRouterAndVaultIdentityHaveNoExemption() public {
        TestRouter secondRouter = new TestRouter(manager);
        imd.mint(address(secondRouter), 100 ether);
        secondRouter.swap(key, _params(true, true, 100 ether, false), abi.encode(VAULT, TEAM, address(this)));
        assertEq(hook.totalCredits(), 96.1 ether);
        assertEq(imd.balanceOf(address(secondRouter)), 0);
    }

    function test_launchScalePricesInBothCurrencyOrderings() public {
        for (uint256 ordering; ordering < 2; ++ordering) {
            if (ordering == 1) _setup(true, false);
            hook = _deployHook(manager, address(hamster), address(this), TEAM);
            key = hook.poolKey();
            // Approximately 2500 IMD / 1B HAMSTER, inverted when IMD sorts first.
            int24 openingTick = hook.imdIsCurrency0() ? int24(129000) : int24(-129000);
            manager.initialize(key, TickMath.getSqrtPriceAtTick(openingTick));
            router = new TestRouter(manager);
            imd.mint(address(router), 1e35);
            hamster.mint(address(router), 1e35);
            _modifyAsFactory(ModifyLiquidityParams(openingTick - 600, openingTick + 600, int256(LIQUIDITY), bytes32(0)));
            assertEq(_trade(true, true, 1 ether, false).userImd, 1 ether);
            assertEq(_trade(true, false, 1000 ether, false).hamsterAmount, 1000 ether);
            assertEq(_trade(false, true, 1000 ether, false).hamsterAmount, 1000 ether);
            assertEq(_trade(false, false, 1 ether, false).userImd, 1 ether);
        }
    }

    function test_protocolFeeDoesNotBreakRealDeltaAccounting() public {
        manager.setProtocolFeeController(address(this));
        manager.setProtocolFee(key, uint24(1000 | (1000 << 12)));
        assertEq(_trade(true, true, 100 ether, false).fee, 96.1 ether);
        _trade(true, false, 1 ether, false);
        _trade(false, true, 1 ether, false);
        _trade(false, false, 1 ether, false);
        _trade(true, true, 10_000 ether, true);
        _trade(false, false, 10_000 ether, true);
    }

    function test_fixedPolicyRatesAndNoAdministrativeSelectors() public {
        assertEq(hook.HOOK_FEE_BPS(), 110);
        assertEq(hook.INITIAL_TAX_BPS(), 9500);
        assertEq(hook.LP_FEE(), 12_500);
        assertLe(hook.HOOK_FEE_BPS() + hook.INITIAL_TAX_BPS() + hook.LP_FEE() / 100, 10_000);
        string[8] memory signatures = [
            "owner()",
            "pause()",
            "unpause()",
            "upgradeTo(address)",
            "setFee(uint256)",
            "setTax(uint256)",
            "setVault(address)",
            "resetStart()"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            (bool ok,) = address(hook).call(abi.encodeWithSignature(signatures[i], TEAM, 1));
            assertFalse(ok);
        }
    }

    function test_runtimeSizesAndNoEscapeHatchOpcodes() public {
        HamsterToken token = new HamsterToken();
        _checkRuntime(address(hook).code);
        _checkRuntime(address(token).code);
    }

    function _checkRuntime(bytes memory code) internal pure {
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        bool reachable = true;
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op == 0x5b) reachable = true;
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            if (reachable) assertTrue(op != 0xff && op != 0xf4 && op != 0xf2);
            if (op == 0x00 || op == 0x56 || op == 0xf3 || op == 0xfd || op == 0xfe || op == 0xff) reachable = false;
        }
    }
}

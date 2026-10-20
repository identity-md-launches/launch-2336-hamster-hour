// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HookTestBase} from "../test/HookTestBase.sol";
import {HamsterToken} from "../src/HamsterToken.sol";
import {HamsterHook} from "../src/HamsterHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TestRouter} from "../test/mocks/TestRouter.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

interface VaultRead {
    function TEAM() external view returns (address);
    function token() external view returns (address);
    function jackpotPending() external view returns (uint256);
    function oraclePending() external view returns (uint256);
}

contract MainnetIntegrationTest is HookTestBase {
    function setUp() public override {
        require(block.chainid == 1 && IMD.code.length != 0 && VAULT.code.length != 0, "run on pinned Ethereum fork");
        vm.warp(START);
        manager = IPoolManager(address(new PoolManager(address(this))));
        HamsterToken deployed = new HamsterToken();
        hamster = MockERC20(address(deployed));
        imd = MockERC20(IMD);
        hook = _deployHook(manager, address(deployed), address(this), TEAM);
        key = hook.poolKey();
        manager.initialize(key, Q96);
        router = new TestRouter(manager);
        deal(IMD, address(router), 1_000_000 ether);
        deployed.transfer(address(router), 1_000_000 ether);
        router.modify(key, ModifyLiquidityParams(-600, 600, int256(LIQUIDITY), bytes32(0)));
    }

    function test_mainnetImdAndVaultAllModesAndFlush() public {
        assertEq(VaultRead(VAULT).TEAM(), TEAM);
        uint256 jackpotBefore = VaultRead(VAULT).jackpotPending();
        uint256 oracleBefore = VaultRead(VAULT).oraclePending();
        uint256 vaultBefore = imd.balanceOf(VAULT);
        uint256 teamBefore = imd.balanceOf(TEAM);
        _trade(true, true, 100 ether, false);
        _trade(true, false, 1 ether, false);
        _trade(false, true, 1 ether, false);
        _trade(false, false, 1 ether, false);
        _trade(true, true, 10000 ether, true);
        _trade(false, false, 10000 ether, true);
        uint256 owed = hook.totalCredits();
        uint256 teamOwed = hook.credits(HamsterHook.Bucket.Team);
        uint256 jackpotOwed = hook.credits(HamsterHook.Bucket.Jackpot);
        uint256 oracleOwed = hook.credits(HamsterHook.Bucket.Oracle);
        assertEq(hook.flushAll(type(uint128).max), owed);
        assertEq(imd.balanceOf(VAULT) - vaultBefore, owed - teamOwed);
        assertEq(imd.balanceOf(TEAM) - teamBefore, teamOwed);
        assertEq(VaultRead(VAULT).jackpotPending() - jackpotBefore, jackpotOwed);
        assertEq(VaultRead(VAULT).oraclePending() - oracleBefore, oracleOwed);
        assertEq(imd.allowance(address(hook), VAULT), 0);
        _assertSolvent();
    }
}

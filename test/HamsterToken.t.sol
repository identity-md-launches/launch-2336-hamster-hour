// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HamsterToken} from "../src/HamsterToken.sol";

contract HamsterTokenTest is Test {
    HamsterToken internal token;

    function setUp() public {
        token = new HamsterToken();
    }

    function test_plainFixedSupplyAndLaunchDistribution() public {
        assertEq(token.name(), "Hamster Hour");
        assertEq(token.symbol(), "HAMSTER");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
        address distributor = makeAddr("distributor");
        address manager = makeAddr("manager");
        address remainder = makeAddr("payer");
        token.transfer(distributor, 100_000_000 ether);
        token.transfer(manager, 100_000_000 ether);
        token.transfer(remainder, 800_000_000 ether);
        assertEq(token.balanceOf(remainder), 800_000_000 ether);
        vm.prank(remainder);
        token.transfer(0x1DCeb78b36b5F18Ac4a130F1FFc76ebA0E73D183, 800_000_000 ether);
        assertEq(token.balanceOf(0x1DCeb78b36b5F18Ac4a130F1FFc76ebA0E73D183), 800_000_000 ether);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function test_transferFromNeedsAllowanceAndMovesExactly() public {
        address spender = makeAddr("spender");
        address recipient = makeAddr("recipient");
        vm.prank(spender);
        vm.expectRevert();
        token.transferFrom(address(this), recipient, 1 ether);
        token.approve(spender, 2 ether);
        vm.prank(spender);
        token.transferFrom(address(this), recipient, 1 ether);
        assertEq(token.balanceOf(recipient), 1 ether);
        assertEq(token.allowance(address(this), spender), 1 ether);
        assertEq(token.balanceOf(address(this)), 1_000_000_000 ether - 1 ether);
        vm.expectRevert();
        token.transfer(address(0), 1);
    }

    function test_noMintBurnAdminOrUpgradeSelectors() public {
        string[9] memory signatures = [
            "mint(address,uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "owner()",
            "pause()",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "setFee(uint256)",
            "blacklist(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            (bool success,) = address(token).call(abi.encodeWithSignature(signatures[i], address(this), 1));
            assertFalse(success, signatures[i]);
        }
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }
}

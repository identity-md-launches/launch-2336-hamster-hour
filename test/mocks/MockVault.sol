// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHamsterVault} from "../../src/interfaces/IHamsterVault.sol";
import {HamsterHook} from "../../src/HamsterHook.sol";

contract MockVault is IHamsterVault {
    address private constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    mapping(bytes4 => uint256) public received;
    mapping(bytes4 => uint256) public mode;
    bool public reentrySucceeded;

    function setMode(bytes4 selector, uint256 value) external {
        mode[selector] = value;
    }

    function depositRewards(uint256 amount) external {
        _deposit(amount, msg.sig);
    }

    function depositDrip(uint256 amount) external {
        _deposit(amount, msg.sig);
    }

    function forwardJackpot(uint256 amount) external {
        _deposit(amount, msg.sig);
    }

    function forwardOracle(uint256 amount) external {
        _deposit(amount, msg.sig);
    }

    function _deposit(uint256 amount, bytes4 selector) private {
        uint256 behavior = mode[selector];
        if (behavior == 1) revert("vault unavailable");
        if (behavior == 2) return;
        if (behavior == 3) --amount;
        require(IERC20(IMD).allowance(msg.sender, address(this)) >= amount, "no exact approval");
        require(IERC20(IMD).transferFrom(msg.sender, address(this), amount), "pull failed");
        received[selector] += amount;
        if (behavior == 4) {
            (reentrySucceeded,) = msg.sender.call(abi.encodeCall(HamsterHook.flushAll, (type(uint256).max)));
        }
    }
}

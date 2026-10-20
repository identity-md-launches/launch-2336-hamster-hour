// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Fixed supply, plain ERC-20. The deploying launch factory distributes the entire supply.
contract HamsterToken is ERC20 {
    constructor() ERC20("Hamster Hour", "HAMSTER") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}

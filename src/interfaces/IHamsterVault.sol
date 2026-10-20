// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Each entry point pulls exactly `amount` IMD from its caller using transferFrom.
interface IHamsterVault {
    function depositRewards(uint256 amount) external;
    function depositDrip(uint256 amount) external;
    function forwardJackpot(uint256 amount) external;
    function forwardOracle(uint256 amount) external;
}

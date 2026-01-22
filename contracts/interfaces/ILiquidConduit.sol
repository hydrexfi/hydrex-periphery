// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Interface for liquid conduit snapshot (frozen or live)
interface ILiquidConduit {
    function cumulativeOptionsClaimed(address user) external view returns (uint256);
}

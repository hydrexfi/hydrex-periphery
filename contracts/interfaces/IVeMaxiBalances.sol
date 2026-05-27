// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal view interface for VeMaxi-style flex/protocol locked balances
/// @dev Implemented by both live VeMaxiTokenConduit and frozen snapshots
interface IVeMaxiBalances {
    function totalFlexLocked(address user) external view returns (uint256);

    function totalProtocolLocked(address user) external view returns (uint256);
}

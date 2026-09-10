// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @notice Minimal views on an Algebra Integral pool needed by the fee splitter module.
 * @dev `communityVault` is the address the pool pushes accumulated community fees to. It is
 *      settable by an Algebra pools administrator via `setCommunityVault`, and the pool flushes
 *      pending fees to it roughly every 8 hours during swaps.
 */
interface IAlgebraPool {
    function token0() external view returns (address);

    function token1() external view returns (address);

    function factory() external view returns (address);

    function communityVault() external view returns (address);

    function getCommunityFeePending() external view returns (uint128 pending0, uint128 pending1);
}

/**
 * @notice Minimal view on a Hydrex gauge needed by the fee splitter module.
 * @dev `claimFees` is permissionless and sweeps the gauge's fee balances into the internal bribe.
 */
interface IHydrexGauge {
    function stakeToken() external view returns (address);

    function claimFees() external returns (uint256 claimed0, uint256 claimed1);
}

/// @notice Subset of the Hydrex voter used to resolve gauges and enumerate pools.
interface IHydrexVoter {
    function length() external view returns (uint256);

    function pools(uint256 index) external view returns (address);

    function gauges(address pool) external view returns (address);

    function poolForGauge(address gauge) external view returns (address);

    function isGauge(address gauge) external view returns (bool);

    function isAlive(address gauge) external view returns (bool);
}

/// @notice Config surface the factory exposes to its splitters and the outside world.
interface IHydrexFeeSplitterFactory {
    function owner() external view returns (address);

    /// @notice Voter used to resolve a pool's current gauge
    function voter() external view returns (address);

    /// @return secondaryRecipient Default secondary (Algebra) recipient
    /// @return secondaryShareBps Default secondary share in basis points
    /// @return fallbackPrimaryRecipient Primary recipient used while a pool has no gauge
    function defaults()
        external
        view
        returns (address secondaryRecipient, uint16 secondaryShareBps, address fallbackPrimaryRecipient);
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ILiquidConduit} from "../interfaces/ILiquidConduit.sol";

/*
    __  __          __                 _____
   / / / /_  ______/ /_______  _  __  / __(_)
  / /_/ / / / / __  / ___/ _ \| |/_/ / /_/ /
 / __  / /_/ / /_/ / /  /  __/>  <_ / __/ /
/_/ /_/\__, /\__,_/_/   \___/_/|_(_)_/ /_/
      /____/

*/

/**
 * @title AnchorClubSeason3Snapshot
 * @notice Frozen snapshot of summed `cumulativeOptionsClaimed` across the live liquid conduits at Season 3 end
 * @dev There is no Season 4. This snapshot is installed *into* AnchorClubSeason3 as its only liquid
 *      conduit, replacing the three live conduits. Season 3 then computes
 *      `multiplier * (thisSnapshot - season2Snapshot)`, which is constant forever, so accrual stops
 *      while redemption stays open indefinitely.
 *
 *      Implements ILiquidConduit so it slots directly into `AnchorClubSeason3.addLiquidConduits`.
 *
 *      Values stored here are the *summed live totals* at the freeze block (same units and semantics
 *      as AnchorClubSeason2Snapshot), not the Season 3 delta — Season 3 subtracts the Season 2
 *      baseline itself.
 *
 *      Once the snapshot has been reconciled against the freeze block, call `freeze()` to make the
 *      values permanently immutable.
 */
contract AnchorClubSeason3Snapshot is ILiquidConduit, AccessControl {
    /// @notice Stores frozen summed cumulative options claimed per user at end of Season 3
    mapping(address => uint256) private _cumulativeOptionsClaimed;

    /// @notice Once true, snapshot values can never be changed again
    bool public frozen;

    /// @notice Emitted when a single user's snapshot is set
    event SnapshotSet(address indexed user, uint256 amount);

    /// @notice Emitted when a batch of snapshots is set
    event BatchSnapshotSet(uint256 count);

    /// @notice Emitted when the snapshot is permanently sealed
    event Frozen();

    /// @notice Thrown when array lengths don't match in batch operations
    error InvalidLength();

    /// @notice Thrown when a zero address is provided
    error InvalidAddress();

    /// @notice Thrown when a write is attempted after the snapshot has been frozen
    error AlreadyFrozen();

    /**
     * @notice Initialize the snapshot contract
     * @param _admin Address to grant admin role
     */
    constructor(address _admin) {
        if (_admin == address(0)) revert InvalidAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    /**
     * @notice Returns the frozen cumulative options claimed for a user at end of Season 3
     * @param user Address to query
     * @return Frozen summed amount from end of Season 3
     */
    function cumulativeOptionsClaimed(address user) external view returns (uint256) {
        return _cumulativeOptionsClaimed[user];
    }

    /**
     * @notice Set snapshot for a single user
     * @param user User address
     * @param amount Cumulative options claimed across all liquid conduits at Season 3 end
     */
    function setSnapshot(address user, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (frozen) revert AlreadyFrozen();
        if (user == address(0)) revert InvalidAddress();
        _cumulativeOptionsClaimed[user] = amount;
        emit SnapshotSet(user, amount);
    }

    /**
     * @notice Batch set snapshots for multiple users
     * @param users Array of user addresses
     * @param amounts Array of cumulative options claimed (1:1 with users)
     */
    function batchSetSnapshot(
        address[] calldata users,
        uint256[] calldata amounts
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (frozen) revert AlreadyFrozen();
        if (users.length != amounts.length) revert InvalidLength();
        for (uint256 i = 0; i < users.length; i++) {
            if (users[i] == address(0)) revert InvalidAddress();
            _cumulativeOptionsClaimed[users[i]] = amounts[i];
        }
        emit BatchSnapshotSet(users.length);
    }

    /**
     * @notice Permanently seal the snapshot so no value can ever be changed again
     * @dev Irreversible. Call only after reconciling against the freeze block.
     */
    function freeze() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (frozen) revert AlreadyFrozen();
        frozen = true;
        emit Frozen();
    }
}

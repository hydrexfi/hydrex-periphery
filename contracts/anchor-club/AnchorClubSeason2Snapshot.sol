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
 * @title AnchorClubSeason2Snapshot
 * @notice Frozen snapshot of summed `cumulativeOptionsClaimed` across the live liquid conduits at Season 2 end
 * @dev Used as the baseline subtracted by AnchorClubSeason3 so Season 2 earnings are not double-rewarded.
 *      Implements ILiquidConduit so it slots into the same code path as the Season 1 snapshot.
 */
contract AnchorClubSeason2Snapshot is ILiquidConduit, AccessControl {
    /// @notice Stores frozen summed cumulative options claimed per user at end of Season 2
    mapping(address => uint256) private _cumulativeOptionsClaimed;

    /// @notice Emitted when a single user's snapshot is set
    event SnapshotSet(address indexed user, uint256 amount);

    /// @notice Emitted when a batch of snapshots is set
    event BatchSnapshotSet(uint256 count);

    /// @notice Thrown when array lengths don't match in batch operations
    error InvalidLength();

    /// @notice Thrown when a zero address is provided
    error InvalidAddress();

    /**
     * @notice Initialize the snapshot contract
     * @param _admin Address to grant admin role
     */
    constructor(address _admin) {
        if (_admin == address(0)) revert InvalidAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    /**
     * @notice Returns the frozen cumulative options claimed for a user at end of Season 2
     * @param user Address to query
     * @return Frozen amount from end of Season 2
     */
    function cumulativeOptionsClaimed(address user) external view returns (uint256) {
        return _cumulativeOptionsClaimed[user];
    }

    /**
     * @notice Set snapshot for a single user
     * @param user User address
     * @param amount Cumulative options claimed across all liquid conduits at Season 2 end
     */
    function setSnapshot(address user, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
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
        if (users.length != amounts.length) revert InvalidLength();
        for (uint256 i = 0; i < users.length; i++) {
            if (users[i] == address(0)) revert InvalidAddress();
            _cumulativeOptionsClaimed[users[i]] = amounts[i];
        }
        emit BatchSnapshotSet(users.length);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IVeMaxiBalances} from "../interfaces/IVeMaxiBalances.sol";

/*
    __  __          __                 _____ 
   / / / /_  ______/ /_______  _  __  / __(_)
  / /_/ / / / / __  / ___/ _ \| |/_/ / /_/ / 
 / __  / /_/ / /_/ / /  /  __/>  <_ / __/ /  
/_/ /_/\__, /\__,_/_/   \___/_/|_(_)_/ /_/   
      /____/                                 

*/

/**
 * @title AnchorClubSeason2VeMaxiSnapshot
 * @notice Frozen snapshot of `totalFlexLocked` and `totalProtocolLocked` for each user at Season 2 end
 * @dev Used as the baseline subtracted by AnchorClubSeason3 so VeMaxi locks established during
 *      Season 2 are not double-rewarded under Season 3's multiplier.
 *      Implements IVeMaxiBalances so live and frozen sources share the same call surface.
 */
contract AnchorClubSeason2VeMaxiSnapshot is IVeMaxiBalances, AccessControl {
    /// @notice Frozen flex-locked HYDX per user at end of Season 2
    mapping(address => uint256) private _flexLockedSnapshot;

    /// @notice Frozen protocol-locked HYDX per user at end of Season 2
    mapping(address => uint256) private _protocolLockedSnapshot;

    /// @notice Emitted when a single user's snapshot is set
    event SnapshotSet(address indexed user, uint256 flexLocked, uint256 protocolLocked);

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

    /// @inheritdoc IVeMaxiBalances
    function totalFlexLocked(address user) external view returns (uint256) {
        return _flexLockedSnapshot[user];
    }

    /// @inheritdoc IVeMaxiBalances
    function totalProtocolLocked(address user) external view returns (uint256) {
        return _protocolLockedSnapshot[user];
    }

    /**
     * @notice Set snapshot for a single user
     * @param user User address
     * @param flexLocked Frozen flex-locked HYDX at Season 2 end
     * @param protocolLocked Frozen protocol-locked HYDX at Season 2 end
     */
    function setSnapshot(
        address user,
        uint256 flexLocked,
        uint256 protocolLocked
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (user == address(0)) revert InvalidAddress();
        _flexLockedSnapshot[user] = flexLocked;
        _protocolLockedSnapshot[user] = protocolLocked;
        emit SnapshotSet(user, flexLocked, protocolLocked);
    }

    /**
     * @notice Batch set snapshots for multiple users
     * @param users Array of user addresses
     * @param flexLockedAmounts Array of flex-locked amounts (1:1 with users)
     * @param protocolLockedAmounts Array of protocol-locked amounts (1:1 with users)
     */
    function batchSetSnapshot(
        address[] calldata users,
        uint256[] calldata flexLockedAmounts,
        uint256[] calldata protocolLockedAmounts
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (users.length != flexLockedAmounts.length || users.length != protocolLockedAmounts.length) {
            revert InvalidLength();
        }
        for (uint256 i = 0; i < users.length; i++) {
            if (users[i] == address(0)) revert InvalidAddress();
            _flexLockedSnapshot[users[i]] = flexLockedAmounts[i];
            _protocolLockedSnapshot[users[i]] = protocolLockedAmounts[i];
        }
        emit BatchSnapshotSet(users.length);
    }
}

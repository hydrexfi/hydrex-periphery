// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/*
    __  __          __                 _____ 
   / / / /_  ______/ /_______  _  __  / __(_)
  / /_/ / / / / __  / ___/ _ \| |/_/ / /_/ / 
 / __  / /_/ / /_/ / /  /  __/>  <_ / __/ /  
/_/ /_/\__, /\__,_/_/   \___/_/|_(_)_/ /_/   
      /____/                                 

*/

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

interface IVotes {
    function getPastVotes(address account, uint256 timepoint) external view returns (uint256);
}

/**
 * @title EarningPowerSnapshotsLens
 * @notice Stores historical earning power snapshots that can be queried by address and timestamp
 * @dev Acts as a read-only lens with admin-only write access for posting snapshots
 */
contract EarningPowerSnapshotsLens is AccessControl {
    /// @notice Mapping of timestamp => address => earning power
    mapping(uint256 => mapping(address => uint256)) public snapshots;

    /// @notice Default timestamp used when querying without specifying a timestamp
    uint256 public defaultTimestamp;

    /// @notice HydrexVoteEscrowNFT contract for fallback queries
    IVotes public immutable veNFT;

    event SnapshotPosted(uint256 indexed timestamp, address indexed account, uint256 power);
    event BatchSnapshotPosted(uint256 indexed timestamp, uint256 accountCount);
    event DefaultTimestampUpdated(uint256 oldTimestamp, uint256 newTimestamp);

    constructor(address _admin, address _veNFT) {
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        veNFT = IVotes(_veNFT);
    }

    /**
     * @notice Post a single snapshot for one account
     * @param _timestamp The timestamp for this snapshot
     * @param _account The account address
     * @param _power The earning power value
     */
    function postSnapshot(uint256 _timestamp, address _account, uint256 _power) external onlyRole(DEFAULT_ADMIN_ROLE) {
        snapshots[_timestamp][_account] = _power;
        emit SnapshotPosted(_timestamp, _account, _power);
    }

    /**
     * @notice Post multiple snapshots for the same timestamp (batch operation)
     * @param _timestamp The timestamp for these snapshots
     * @param _accounts Array of account addresses
     * @param _powers Array of earning power values (must match accounts length)
     */
    function postBatchSnapshot(
        uint256 _timestamp,
        address[] calldata _accounts,
        uint256[] calldata _powers
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_accounts.length == _powers.length, "Length mismatch");
        require(_accounts.length > 0, "Empty arrays");

        for (uint256 i = 0; i < _accounts.length; i++) {
            snapshots[_timestamp][_accounts[i]] = _powers[i];
        }

        emit BatchSnapshotPosted(_timestamp, _accounts.length);
    }

    /**
     * @notice Update the default timestamp used for queries
     * @param _newTimestamp The new default timestamp
     */
    function setDefaultTimestamp(uint256 _newTimestamp) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 oldTimestamp = defaultTimestamp;
        defaultTimestamp = _newTimestamp;
        emit DefaultTimestampUpdated(oldTimestamp, _newTimestamp);
    }

    /**
     * @notice Get earning power for an account using the default timestamp
     * @param _account The account address to query
     * @return The earning power at the default timestamp (falls back to veNFT if snapshot is 0)
     */
    function getPower(address _account) external view returns (uint256) {
        uint256 power = snapshots[defaultTimestamp][_account];
        if (power == 0) {
            return veNFT.getPastVotes(_account, defaultTimestamp);
        }
        return power;
    }

    /**
     * @notice Get earning power for an account at a specific timestamp
     * @param _account The account address to query
     * @param _timestamp The timestamp to query
     * @return The earning power at that timestamp (falls back to veNFT if snapshot is 0)
     */
    function getPowerAt(address _account, uint256 _timestamp) external view returns (uint256) {
        uint256 power = snapshots[_timestamp][_account];
        if (power == 0) {
            return veNFT.getPastVotes(_account, _timestamp);
        }
        return power;
    }

    /**
     * @notice Get earning power for multiple accounts using the default timestamp
     * @param _accounts Array of account addresses to query
     * @return Array of earning powers for each account at the default timestamp (falls back to veNFT if snapshot is 0)
     */
    function getBatchPower(address[] calldata _accounts) external view returns (uint256[] memory) {
        uint256[] memory powers = new uint256[](_accounts.length);
        for (uint256 i = 0; i < _accounts.length; i++) {
            powers[i] = snapshots[defaultTimestamp][_accounts[i]];
            if (powers[i] == 0) {
                powers[i] = veNFT.getPastVotes(_accounts[i], defaultTimestamp);
            }
        }
        return powers;
    }

    /**
     * @notice Get earning power for multiple accounts at a specific timestamp
     * @param _accounts Array of account addresses to query
     * @param _timestamp The timestamp to query
     * @return Array of earning powers for each account (falls back to veNFT if snapshot is 0)
     */
    function getBatchPowerAt(
        address[] calldata _accounts,
        uint256 _timestamp
    ) external view returns (uint256[] memory) {
        uint256[] memory powers = new uint256[](_accounts.length);
        for (uint256 i = 0; i < _accounts.length; i++) {
            powers[i] = snapshots[_timestamp][_accounts[i]];
            if (powers[i] == 0) {
                powers[i] = veNFT.getPastVotes(_accounts[i], _timestamp);
            }
        }
        return powers;
    }
}

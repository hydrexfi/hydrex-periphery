// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IHydrexVotingEscrow} from "../interfaces/IHydrexVotingEscrow.sol";
import {IOptionsToken} from "../interfaces/IOptionsToken.sol";

/*
    __  __          __                 _____ 
   / / / /_  ______/ /_______  _  __  / __(_)
  / /_/ / / / / __  / ___/ _ \| |/_/ / /_/ / 
 / __  / /_/ / /_/ / /  /  __/>  <_ / __/ /  
/_/ /_/\__, /\__,_/_/   \___/_/|_(_)_/ /_/   
      /____/                                 

*/

/**
 * @title AnchorClubFlexAccounts
 * @notice Manages time-based bonus distributions for registered Flex Account holders
 * @dev Uses off-chain validation for lock maintenance verification to prevent gaming
 */
contract AnchorClubFlexAccounts is AccessControl, ReentrancyGuard {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    IHydrexVotingEscrow public veToken;
    IOptionsToken public optionsToken;

    /*
     * Enums
     */

    enum TierStatus {
        NOT_ELIGIBLE, // Time hasn't passed yet
        PENDING_APPROVAL, // Time passed, awaiting admin approval
        APPROVED, // Approved and ready to claim
        CLAIMED // Already claimed
    }

    /*
     * Structs
     */

    /// @notice Tier configuration for lockup duration and bonus
    struct Tier {
        uint256 duration;
        uint256 bonusPercentage;
    }

    /// @notice Registration data for a flex account
    struct Registration {
        uint256 timestamp;
        uint256 snapshotAmount;
        address owner;
    }

    /// @notice Complete status information for a tier
    struct TierStatusInfo {
        uint8 tierId;
        TierStatus status;
        uint256 timeRemaining; // Seconds remaining until eligible (0 if eligible)
        uint256 bonusAmount; // Expected bonus amount
        uint256 unlockTimestamp; // When this tier becomes eligible
    }

    /*
     * State Variables
     */

    /// @notice Tracks registration for each NFT ID
    mapping(uint256 => Registration) public registrations;

    /// @notice Tracks which tiers have been approved for each NFT (nftId => tierId => approved)
    mapping(uint256 => mapping(uint8 => bool)) public tierApprovals;

    /// @notice Tracks which tiers have been claimed for each NFT (nftId => tierId => claimed)
    mapping(uint256 => mapping(uint8 => bool)) public tierClaims;

    /// @notice Tracks total claimed credits per user address
    mapping(address => uint256) public totalCredits;

    /// @notice Tier configurations (tierId => Tier)
    mapping(uint8 => Tier) public tiers;

    /// @notice Total number of active tiers
    uint8 public tierCount;

    /// @notice Whether registrations are currently allowed
    bool public registrationsAllowed;

    /*
     * Events
     */

    event Registered(address indexed user, uint256 indexed nftId, uint256 timestamp, uint256 snapshotAmount);
    event TierApproved(uint256 indexed nftId, uint8 indexed tierId, uint256 bonusAmount);
    event TierClaimed(address indexed user, uint256 indexed nftId, uint8 tierId, uint256 bonusAmount, uint256 newNftId);
    event RegistrationsAllowedChanged(bool allowed);

    /*
     * Errors
     */

    error InvalidAmount();
    error InvalidAddress();
    error InvalidNftId();
    error InvalidTier();
    error NotFlexAccount();
    error AlreadyRegistered();
    error NotRegistered();
    error NotNftOwner();
    error NotApproved();
    error AlreadyClaimed();
    error BalanceDecreased();
    error LockTypeChanged();
    error RegistrationsNotAllowed();

    /*
     * Constructor
     */

    constructor(IHydrexVotingEscrow _veToken, IOptionsToken _optionsToken, address _admin) {
        veToken = _veToken;
        optionsToken = _optionsToken;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _admin);

        tiers[1] = Tier({duration: 2 weeks, bonusPercentage: 2500});
        tiers[2] = Tier({duration: 4 weeks, bonusPercentage: 5000});
        tiers[3] = Tier({duration: 12 weeks, bonusPercentage: 7500});
        tiers[4] = Tier({duration: 26 weeks, bonusPercentage: 10000});
        tiers[5] = Tier({duration: 52 weeks, bonusPercentage: 15000});
        tierCount = 5;

        registrationsAllowed = true;
    }

    /*
     * View Functions
     */

    /// @notice Calculates bonus for a specific tier and amount
    /// @param amount The lock amount
    /// @param tierId The tier ID
    /// @return bonusAmount The bonus amount
    function calculateBonus(uint256 amount, uint8 tierId) public view returns (uint256 bonusAmount) {
        if (tierId == 0 || tierId > tierCount) return 0;
        return (amount * tiers[tierId].bonusPercentage * 13000) / 100000000;
    }

    /// @notice Get the status of a specific tier for an NFT
    /// @param nftId The NFT ID
    /// @param tierId The tier ID
    /// @return status The current status of the tier
    function getTierStatus(uint256 nftId, uint8 tierId) public view returns (TierStatus status) {
        Registration memory reg = registrations[nftId];

        // Not registered
        if (reg.timestamp == 0) return TierStatus.NOT_ELIGIBLE;

        // Check if claimed
        if (tierClaims[nftId][tierId]) return TierStatus.CLAIMED;

        // Check if approved
        if (tierApprovals[nftId][tierId]) return TierStatus.APPROVED;

        // Check if time has passed
        Tier memory tier = tiers[tierId];
        uint256 timeElapsed = block.timestamp - reg.timestamp;

        if (timeElapsed >= tier.duration) {
            return TierStatus.PENDING_APPROVAL;
        } else {
            return TierStatus.NOT_ELIGIBLE;
        }
    }

    /// @notice Get comprehensive status for all tiers for an NFT
    /// @param nftId The NFT ID
    /// @return tierStatuses Array of status info for all tiers
    function getAllTierStatuses(uint256 nftId) external view returns (TierStatusInfo[] memory tierStatuses) {
        Registration memory reg = registrations[nftId];
        tierStatuses = new TierStatusInfo[](tierCount);

        for (uint8 i = 1; i <= tierCount; i++) {
            Tier memory tier = tiers[i];
            TierStatus status = getTierStatus(nftId, i);

            uint256 timeRemaining = 0;
            uint256 unlockTimestamp = 0;

            if (reg.timestamp != 0) {
                unlockTimestamp = reg.timestamp + tier.duration;

                if (status == TierStatus.NOT_ELIGIBLE) {
                    if (block.timestamp < unlockTimestamp) {
                        timeRemaining = unlockTimestamp - block.timestamp;
                    }
                }
            }

            uint256 bonusAmount = calculateBonus(reg.snapshotAmount, i);

            tierStatuses[i - 1] = TierStatusInfo({
                tierId: i,
                status: status,
                timeRemaining: timeRemaining,
                bonusAmount: bonusAmount,
                unlockTimestamp: unlockTimestamp
            });
        }

        return tierStatuses;
    }

    /// @notice Get total claimed bonus credits for a user
    /// @param user Address of the user to check
    /// @return Total claimed bonus amount for the user
    function getTotalClaimedCredits(address user) external view returns (uint256) {
        return totalCredits[user];
    }

    /// @notice Get total claimed bonus credits for a user
    /// @param user Address of the user to check
    /// @return Total claimed bonus amount for the user
    function calculateTotalCredits(address user) external view returns (uint256) {
        return totalCredits[user];
    }

    /*
     * User Functions
     */

    /// @notice Register a flex account to start earning bonuses
    /// @dev The NFT must be a ROLLING lock type (flex account)
    /// @param nftId The veNFT ID to register
    function register(uint256 nftId) external nonReentrant {
        if (!registrationsAllowed) revert RegistrationsNotAllowed();
        if (nftId == 0) revert InvalidNftId();

        // Check caller owns the NFT
        address owner = IERC721(address(veToken)).ownerOf(nftId);
        if (owner != msg.sender) revert NotNftOwner();

        // Check not already registered
        if (registrations[nftId].timestamp != 0) revert AlreadyRegistered();

        // Get lock details and verify it's a flex account
        IHydrexVotingEscrow.LockDetails memory lockDetails = veToken._lockDetails(nftId);

        // Verify ROLLING lock type
        if (lockDetails.lockType != IHydrexVotingEscrow.LockType.ROLLING) revert NotFlexAccount();

        // Verify balance exists
        if (lockDetails.amount == 0) revert InvalidAmount();

        // Save registration
        registrations[nftId] = Registration({
            timestamp: block.timestamp,
            snapshotAmount: lockDetails.amount,
            owner: msg.sender
        });

        emit Registered(msg.sender, nftId, block.timestamp, lockDetails.amount);
    }

    /// @notice Claim an approved tier bonus
    /// @param nftId The registered NFT ID
    /// @param tierId The tier to claim
    function claim(uint256 nftId, uint8 tierId) external nonReentrant {
        Registration memory reg = registrations[nftId];

        if (reg.timestamp == 0) revert NotRegistered();
        if (tierId == 0 || tierId > tierCount) revert InvalidTier();
        if (!tierApprovals[nftId][tierId]) revert NotApproved();
        if (tierClaims[nftId][tierId]) revert AlreadyClaimed();

        // Check caller owns the NFT
        address currentOwner = IERC721(address(veToken)).ownerOf(nftId);
        if (currentOwner != msg.sender) revert NotNftOwner();

        // Verify lock details haven't changed
        IHydrexVotingEscrow.LockDetails memory currentLock = veToken._lockDetails(nftId);
        if (currentLock.amount < reg.snapshotAmount) revert BalanceDecreased();
        if (currentLock.lockType != IHydrexVotingEscrow.LockType.ROLLING) revert LockTypeChanged();

        // Calculate bonus
        uint256 bonusAmount = calculateBonus(reg.snapshotAmount, tierId);

        // Mark as claimed
        tierClaims[nftId][tierId] = true;

        // Update total credits for user
        totalCredits[msg.sender] += bonusAmount;

        // Exercise options to create veNFT for user
        uint256 newNftId = optionsToken.exerciseVe(bonusAmount, msg.sender);

        emit TierClaimed(msg.sender, nftId, tierId, bonusAmount, newNftId);
    }

    /*
     * Operator Functions
     */

    /// @notice Approve a tier for an NFT after off-chain validation
    /// @param nftId The NFT ID
    /// @param tierId The tier to approve
    function approveTier(uint256 nftId, uint8 tierId) external onlyRole(OPERATOR_ROLE) {
        if (!_approveTierInternal(nftId, tierId)) revert NotApproved();
    }

    /// @notice Batch approve tiers for multiple NFTs
    /// @param nftIds Array of NFT IDs
    /// @param tierIds Array of corresponding tier IDs
    function batchApproveTiers(uint256[] calldata nftIds, uint8[] calldata tierIds) external onlyRole(OPERATOR_ROLE) {
        if (nftIds.length != tierIds.length) revert InvalidAmount();
        for (uint256 i = 0; i < nftIds.length; i++) {
            _approveTierInternal(nftIds[i], tierIds[i]);
        }
    }

    /*
     * Internal Functions
     */

    /// @notice Internal function to validate and approve a tier
    /// @param nftId The NFT ID
    /// @param tierId The tier to approve
    /// @return success True if approved, false if validation failed
    function _approveTierInternal(uint256 nftId, uint8 tierId) internal returns (bool) {
        Registration memory reg = registrations[nftId];
        if (reg.timestamp == 0) return false;
        if (tierId == 0 || tierId > tierCount) return false;
        if (tierClaims[nftId][tierId]) return false;

        Tier memory tier = tiers[tierId];
        uint256 timeElapsed = block.timestamp - reg.timestamp;
        if (timeElapsed < tier.duration) return false;

        tierApprovals[nftId][tierId] = true;
        uint256 bonusAmount = calculateBonus(reg.snapshotAmount, tierId);
        emit TierApproved(nftId, tierId, bonusAmount);

        return true;
    }

    /*
     * Admin Functions
     */

    /// @notice Enable or disable new registrations
    /// @param allowed Whether registrations should be allowed
    function setRegistrationsAllowed(bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        registrationsAllowed = allowed;
        emit RegistrationsAllowedChanged(allowed);
    }

    /// @notice Override snapshot amount for an NFT (emergency use)
    /// @dev Allows admin to correct registration amounts if needed
    /// @param nftId The NFT ID
    /// @param newSnapshotAmount The new snapshot amount
    function overrideSnapshotAmount(uint256 nftId, uint256 newSnapshotAmount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (registrations[nftId].timestamp == 0) revert NotRegistered();
        if (newSnapshotAmount == 0) revert InvalidAmount();

        registrations[nftId].snapshotAmount = newSnapshotAmount;
    }

    /// @notice Emergency function to recover any stuck tokens
    /// @param token Token address to recover
    /// @param amount Amount to recover
    /// @param recipient Address to send recovered tokens to
    function emergencyRecover(address token, uint256 amount, address recipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0) || recipient == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();

        IERC20(token).transfer(recipient, amount);
    }
}

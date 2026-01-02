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

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/**
 * @title FlexAccountClaims
 * @notice Allows admin to allocate token amounts to veNFT holders with vesting schedules
 * @dev Tokens vest linearly over a specified duration and can be claimed by the current NFT holder
 */
contract FlexAccountClaims is AccessControl {
    using SafeERC20 for IERC20;

    /// @notice The veNFT contract address (hardcoded)
    address public constant VENFT = 0x25B2ED7149fb8A05f6eF9407d9c8F878f59cd1e1;

    /// @notice The oHYDX options token address (hardcoded)
    address public constant OHYDX = 0xA1136031150E50B015b41f1ca6B2e99e49D8cB78;

    struct Allocation {
        uint256 totalAmount; // Total amount allocated
        uint256 claimed; // Amount already claimed
        uint256 startTimestamp; // When vesting starts
        uint256 vestingSeconds; // Duration in seconds
    }

    /// @notice Mapping from NFT tokenId to allocation ID to allocation details
    mapping(uint256 => mapping(uint256 => Allocation)) public allocations;

    /// @notice Counter for allocation IDs per NFT
    mapping(uint256 => uint256) public nextAllocationId;

    /// @notice Tracks unique allocation hashes to prevent duplicates
    mapping(bytes32 => bool) public allocationExists;

    /// @notice Tracks which tokenIds have allocations at specific timestamps: timestamp => tokenId => hasAllocation
    mapping(uint256 => mapping(uint256 => bool)) public hasAllocationAtTimestamp;

    /// @notice Tracks whether a timestamp has been marked as completed by admin
    mapping(uint256 => bool) public hasCompletedTimestamp;

    event AllocationCreated(
        uint256 indexed tokenId,
        uint256 indexed allocationId,
        uint256 totalAmount,
        uint256 vestingSeconds,
        uint256 startTimestamp
    );

    event DuplicateAllocation(
        uint256 indexed tokenId,
        uint256 totalAmount,
        uint256 vestingSeconds,
        uint256 startTimestamp
    );

    event Claimed(uint256 indexed tokenId, uint256 indexed allocationId, address claimer, uint256 amount);

    event TimestampCompletionSet(uint256 indexed timestamp, bool completed);

    error NotNFTHolder();
    error InvalidAmount();
    error InvalidDuration();
    error NoClaimableAmount();
    error InvalidAddress();

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /*
     * View Functions
     */

    /**
     * @notice Get allocation details for a specific NFT and allocation ID
     * @param tokenId The veNFT token ID
     * @param allocationId The allocation ID
     * @return The allocation struct
     */
    function getAllocation(uint256 tokenId, uint256 allocationId) external view returns (Allocation memory) {
        return allocations[tokenId][allocationId];
    }

    /**
     * @notice Get all allocations for a specific NFT
     * @param tokenId The veNFT token ID
     * @return allocationData Array of all allocations for the NFT
     */
    function getAllocations(uint256 tokenId) external view returns (Allocation[] memory allocationData) {
        uint256 count = nextAllocationId[tokenId];
        allocationData = new Allocation[](count);

        for (uint256 i = 0; i < count; i++) {
            allocationData[i] = allocations[tokenId][i];
        }

        return allocationData;
    }

    /**
     * @notice Calculate the currently claimable amount for an allocation
     * @param tokenId The veNFT token ID
     * @param allocationId The allocation ID
     * @return claimable The amount that can be claimed right now
     */
    function getClaimableAmount(uint256 tokenId, uint256 allocationId) public view returns (uint256 claimable) {
        Allocation memory allocation = allocations[tokenId][allocationId];

        if (allocation.totalAmount == 0) {
            return 0;
        }

        // If vesting hasn't started, nothing is claimable yet
        if (block.timestamp < allocation.startTimestamp) {
            return 0;
        }

        uint256 elapsed = block.timestamp - allocation.startTimestamp;

        // Calculate total vested amount
        uint256 vested;
        if (elapsed >= allocation.vestingSeconds) {
            // Fully vested
            vested = allocation.totalAmount;
        } else {
            // Partially vested - linear vesting
            vested = (allocation.totalAmount * elapsed) / allocation.vestingSeconds;
        }

        // Subtract what's already been claimed
        claimable = vested - allocation.claimed;
    }

    /**
     * @notice Get total claimable amount across all allocations for an NFT
     * @param tokenId The veNFT token ID
     * @return total Total claimable amount across all allocations
     */
    function getTotalClaimable(uint256 tokenId) external view returns (uint256 total) {
        uint256 count = nextAllocationId[tokenId];

        for (uint256 i = 0; i < count; i++) {
            total += getClaimableAmount(tokenId, i);
        }

        return total;
    }

    /**
     * @notice Generate allocation hash for duplicate detection
     * @param tokenId The veNFT token ID
     * @param totalAmount Total amount allocated
     * @param vestingSeconds Vesting duration in seconds
     * @param startTimestamp Start timestamp
     * @return Hash of the allocation parameters
     */
    function getAllocationHash(
        uint256 tokenId,
        uint256 totalAmount,
        uint256 vestingSeconds,
        uint256 startTimestamp
    ) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(tokenId, totalAmount, vestingSeconds, startTimestamp));
    }

    /**
     * @notice Get total amounts issued and claimed for a specific NFT
     * @param tokenId The veNFT token ID
     * @return totalIssued Total amount allocated across all allocations
     * @return totalClaimed Total amount claimed across all allocations
     */
    function getTotalIssuedAndClaimed(
        uint256 tokenId
    ) external view returns (uint256 totalIssued, uint256 totalClaimed) {
        uint256 count = nextAllocationId[tokenId];

        for (uint256 i = 0; i < count; i++) {
            Allocation memory allocation = allocations[tokenId][i];
            totalIssued += allocation.totalAmount;
            totalClaimed += allocation.claimed;
        }

        return (totalIssued, totalClaimed);
    }

    /**
     * @notice Get global totals across all NFTs and allocations
     * @param tokenIds Array of token IDs to check
     * @return totalIssued Total amount allocated across all specified NFTs
     * @return totalClaimed Total amount claimed across all specified NFTs
     */
    function getGlobalIssuedAndClaimed(
        uint256[] calldata tokenIds
    ) external view returns (uint256 totalIssued, uint256 totalClaimed) {
        for (uint256 j = 0; j < tokenIds.length; j++) {
            uint256 count = nextAllocationId[tokenIds[j]];

            for (uint256 i = 0; i < count; i++) {
                Allocation memory allocation = allocations[tokenIds[j]][i];
                totalIssued += allocation.totalAmount;
                totalClaimed += allocation.claimed;
            }
        }

        return (totalIssued, totalClaimed);
    }

    /*
     * External Functions
     */

    /**
     * @notice Claim vested tokens for a specific allocation
     * @param tokenId The veNFT token ID
     * @param allocationId The allocation ID to claim from
     */
    function claim(uint256 tokenId, uint256 allocationId) external {
        // Verify caller is the current NFT holder
        if (IERC721(VENFT).ownerOf(tokenId) != msg.sender) {
            revert NotNFTHolder();
        }

        uint256 claimable = getClaimableAmount(tokenId, allocationId);
        if (claimable == 0) {
            revert NoClaimableAmount();
        }

        Allocation storage allocation = allocations[tokenId][allocationId];
        allocation.claimed += claimable;

        // Transfer oHYDX tokens to the NFT holder
        IERC20(OHYDX).safeTransfer(msg.sender, claimable);

        emit Claimed(tokenId, allocationId, msg.sender, claimable);
    }

    /**
     * @notice Claim all vested tokens across all allocations for an NFT
     * @param tokenId The veNFT token ID
     */
    function claimAll(uint256 tokenId) external {
        // Verify caller is the current NFT holder
        if (IERC721(VENFT).ownerOf(tokenId) != msg.sender) {
            revert NotNFTHolder();
        }

        uint256 count = nextAllocationId[tokenId];
        uint256 totalClaimable;

        for (uint256 i = 0; i < count; i++) {
            uint256 claimable = getClaimableAmount(tokenId, i);

            if (claimable > 0) {
                Allocation storage allocation = allocations[tokenId][i];
                allocation.claimed += claimable;
                totalClaimable += claimable;

                emit Claimed(tokenId, i, msg.sender, claimable);
            }
        }

        if (totalClaimable == 0) {
            revert NoClaimableAmount();
        }

        IERC20(OHYDX).safeTransfer(msg.sender, totalClaimable);
    }

    /*
     * Admin Functions
     */

    /**
     * @notice Create multiple allocations in one transaction
     * @dev Contract must hold sufficient oHYDX balance to cover allocations
     * @param tokenIds Array of veNFT token IDs
     * @param totalAmounts Array of total amounts
     * @param vestingSeconds Array of vesting durations in seconds
     * @param startTimestamps Array of start timestamps
     */
    function createAllocationBatch(
        uint256[] calldata tokenIds,
        uint256[] calldata totalAmounts,
        uint256[] calldata vestingSeconds,
        uint256[] calldata startTimestamps
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 len = tokenIds.length;
        require(
            totalAmounts.length == len && vestingSeconds.length == len && startTimestamps.length == len,
            "Length mismatch"
        );

        for (uint256 i = 0; i < len; i++) {
            if (totalAmounts[i] == 0) revert InvalidAmount();
            if (vestingSeconds[i] == 0) revert InvalidDuration();

            bytes32 allocationHash = getAllocationHash(
                tokenIds[i],
                totalAmounts[i],
                vestingSeconds[i],
                startTimestamps[i]
            );

            if (allocationExists[allocationHash]) {
                emit DuplicateAllocation(tokenIds[i], totalAmounts[i], vestingSeconds[i], startTimestamps[i]);
                continue;
            }

            uint256 allocationId = nextAllocationId[tokenIds[i]]++;

            allocations[tokenIds[i]][allocationId] = Allocation({
                totalAmount: totalAmounts[i],
                claimed: 0,
                startTimestamp: startTimestamps[i],
                vestingSeconds: vestingSeconds[i]
            });

            allocationExists[allocationHash] = true;
            hasAllocationAtTimestamp[startTimestamps[i]][tokenIds[i]] = true;

            emit AllocationCreated(tokenIds[i], allocationId, totalAmounts[i], vestingSeconds[i], startTimestamps[i]);
        }
    }

    /**
     * @notice Set whether a timestamp has been completed
     * @param timestamp The timestamp to mark
     * @param completed Whether the timestamp is completed
     */
    function setTimestampCompletion(uint256 timestamp, bool completed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        hasCompletedTimestamp[timestamp] = completed;
        emit TimestampCompletionSet(timestamp, completed);
    }

    /**
     * @notice Emergency function to recover any stuck tokens
     * @param token Token address to recover
     * @param amount Amount to recover
     * @param recipient Address to send recovered tokens to
     */
    function emergencyRecover(address token, uint256 amount, address recipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0) || recipient == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();

        IERC20(token).safeTransfer(recipient, amount);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IOptionsToken} from "../interfaces/IOptionsToken.sol";
import {ILiquidConduit} from "../interfaces/ILiquidConduit.sol";
import {VeMaxiTokenConduit} from "../conduits/VeMaxiTokenConduit.sol";
import {LiquidAccountConduitSimple} from "../conduits/LiquidAccountConduitSimple.sol";

/*
    __  __          __                 _____ 
   / / / /_  ______/ /_______  _  __  / __(_)
  / /_/ / / / / __  / ___/ _ \| |/_/ / /_/ / 
 / __  / /_/ / /_/ / /  /  __/>  <_ / __/ /  
/_/ /_/\__, /\__,_/_/   \___/_/|_(_)_/ /_/   
      /____/                                 

*/

/**
 * @title AnchorClubSeason2
 * @notice Season 2 rewards system with liquid conduit and veMaxi claiming
 * @dev Combines two credit sources:
 *      1. Liquid conduit credits: multiplier * (current total - season 1 snapshot)
 *      2. VeMaxi credits: multiplier * (totalFlexLocked + totalProtocolLocked)
 */
contract AnchorClubSeason2 is AccessControl, ReentrancyGuard {
    /// @notice Options token used for exercising credits into veNFTs
    IOptionsToken public optionsToken;

    /*
     * Liquid Conduit State
     */

    /// @notice Season 1 snapshot contract (frozen baseline)
    ILiquidConduit public season1Snapshot;

    /// @notice Array of current live liquid conduits
    ILiquidConduit[] public liquidConduits;

    /// @notice Quick lookup for valid liquid conduits
    mapping(address => bool) public isLiquidConduit;

    /// @notice Liquid account multiplier in basis points (15000 = 1.5x)
    uint256 public liquidAccountMultiplier;

    /// @notice Tracks liquid credits spent per user
    mapping(address => uint256) public liquidSpentCredits;

    /*
     * VeMaxi Conduit State
     */

    /// @notice VeMaxi conduit contract
    VeMaxiTokenConduit public veMaxiConduit;

    /// @notice Tracks veMaxi credits spent per user
    mapping(address => uint256) public veMaxiSpentCredits;

    /// @notice VeMaxi multiplier in basis points (40000 = 4.0x)
    uint256 public veMaxiMultiplier;

    /*
     * Events
     */

    /// @notice Emitted when liquid conduit credits are redeemed
    event LiquidConduitCreditsRedeemed(address indexed user, uint256 creditsSpent, uint256 nftId);

    /// @notice Emitted when liquid account multiplier is updated
    event LiquidAccountMultiplierUpdated(uint256 oldMultiplier, uint256 newMultiplier);

    /// @notice Emitted when Season 1 snapshot is updated
    event Season1SnapshotUpdated(address indexed oldSnapshot, address indexed newSnapshot);

    /// @notice Emitted when a liquid conduit is added
    event LiquidConduitAdded(address indexed conduit);

    /// @notice Emitted when a liquid conduit is removed
    event LiquidConduitRemoved(address indexed conduit);

    /// @notice Emitted when veMaxi credits are redeemed
    event VeMaxiCreditsRedeemed(address indexed user, uint256 creditsSpent, uint256 nftId);

    /// @notice Emitted when veMaxi multiplier is updated
    event VeMaxiMultiplierUpdated(uint256 oldMultiplier, uint256 newMultiplier);

    /// @notice Emitted when veMaxi conduit is updated
    event VeMaxiConduitUpdated(address indexed oldConduit, address indexed newConduit);

    /*
     * Errors
     */

    /// @notice Thrown when amount is zero
    error InvalidAmount();

    /// @notice Thrown when address is zero
    error InvalidAddress();

    /// @notice Thrown when user has insufficient credits
    error InsufficientCredits();

    /// @notice Thrown when trying to add a duplicate conduit
    error DuplicateConduit();

    /// @notice Thrown when conduit is not found
    error ConduitNotFound();

    /*
     * Constructor
     */

    /**
     * @notice Initialize Season 2 contract
     * @param _optionsToken Options token for exercising credits
     * @param _season1Snapshot Season 1 snapshot contract
     * @param _veMaxiConduit VeMaxi conduit contract
     * @param _admin Admin address
     */
    constructor(
        IOptionsToken _optionsToken,
        ILiquidConduit _season1Snapshot,
        VeMaxiTokenConduit _veMaxiConduit,
        address _admin
    ) {
        if (address(_optionsToken) == address(0)) revert InvalidAddress();
        if (address(_season1Snapshot) == address(0)) revert InvalidAddress();
        if (address(_veMaxiConduit) == address(0)) revert InvalidAddress();
        if (_admin == address(0)) revert InvalidAddress();

        optionsToken = _optionsToken;
        season1Snapshot = _season1Snapshot;
        veMaxiConduit = _veMaxiConduit;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);

        liquidAccountMultiplier = 15000; // 1.50x
        veMaxiMultiplier = 40000; // 4.0x
    }

    /*
     * View Functions
     */

    /**
     * @notice Get all liquid conduits
     * @return Array of liquid conduit addresses
     */
    function getLiquidConduits() external view returns (ILiquidConduit[] memory) {
        return liquidConduits;
    }

    /**
     * @notice Calculate Season 2 liquid credits for a user
     * @dev Credits = multiplier * (current total - season 1 snapshot)
     * @param user User address
     * @return Season 2 liquid credits earned
     */
    function calculateSeason2LiquidCredits(address user) public view returns (uint256) {
        uint256 currentTotal = 0;
        for (uint256 i = 0; i < liquidConduits.length; i++) {
            currentTotal += liquidConduits[i].cumulativeOptionsClaimed(user);
        }
        uint256 season1Amount = season1Snapshot.cumulativeOptionsClaimed(user);
        uint256 newClaims = currentTotal > season1Amount ? currentTotal - season1Amount : 0;
        return (newClaims * liquidAccountMultiplier) / 10000;
    }

    /**
     * @notice Calculate remaining Season 2 liquid credits for a user
     * @param user User address
     * @return Remaining Season 2 liquid credits available
     */
    function calculateSeason2LiquidRemainingCredits(address user) public view returns (uint256) {
        return calculateSeason2LiquidCredits(user) - liquidSpentCredits[user];
    }

    /**
     * @notice Calculate total veMaxi credits for a user
     * @dev Credits = multiplier * (totalFlexLocked + totalProtocolLocked)
     * @param user User address
     * @return Total veMaxi credits earned
     */
    function calculateVeMaxiCredits(address user) public view returns (uint256) {
        uint256 flexLocked = veMaxiConduit.totalFlexLocked(user);
        uint256 protocolLocked = veMaxiConduit.totalProtocolLocked(user);
        return ((flexLocked + protocolLocked) * veMaxiMultiplier) / 10000;
    }

    /**
     * @notice Calculate remaining veMaxi credits for a user
     * @param user User address
     * @return Remaining veMaxi credits available
     */
    function calculateVeMaxiRemainingCredits(address user) public view returns (uint256) {
        return calculateVeMaxiCredits(user) - veMaxiSpentCredits[user];
    }

    /**
     * @notice Calculate total credits across all sources
     * @param user User address
     * @return Total credits from Season 2 liquid + veMaxi
     */
    function calculateTotalCredits(address user) external view returns (uint256) {
        return calculateSeason2LiquidCredits(user) + calculateVeMaxiCredits(user);
    }

    /**
     * @notice Calculate total remaining credits across all sources
     * @param user User address
     * @return Total remaining credits available
     */
    function calculateTotalRemainingCredits(address user) external view returns (uint256) {
        return calculateSeason2LiquidRemainingCredits(user) + calculateVeMaxiRemainingCredits(user);
    }

    /*
     * User Functions
     */

    /**
     * @notice Redeem Season 2 liquid conduit credits for a permanent veNFT
     * @param amount Amount of credits to redeem
     */
    function redeemLiquidCredits(uint256 amount) external nonReentrant {
        _redeemLiquidCredits(amount);
    }

    /**
     * @notice Redeem veMaxi credits for a permanent veNFT
     * @param amount Amount of credits to redeem
     */
    function redeemVeMaxiCredits(uint256 amount) external nonReentrant {
        _redeemVeMaxiCredits(amount);
    }

    /**
     * @notice Redeem both Season 2 liquid and veMaxi credits in a single transaction
     * @param liquidAmount Amount of liquid credits to redeem (0 to skip)
     * @param veMaxiAmount Amount of veMaxi credits to redeem (0 to skip)
     */
    function redeemCombinedCredits(uint256 liquidAmount, uint256 veMaxiAmount) external nonReentrant {
        if (liquidAmount == 0 && veMaxiAmount == 0) revert InvalidAmount();

        if (liquidAmount > 0) {
            _redeemLiquidCredits(liquidAmount);
        }

        if (veMaxiAmount > 0) {
            _redeemVeMaxiCredits(veMaxiAmount);
        }
    }

    /*
     * Internal Functions
     */

    /**
     * @notice Internal function to redeem liquid credits
     * @param amount Amount of credits to redeem
     */
    function _redeemLiquidCredits(uint256 amount) internal {
        if (amount == 0) revert InvalidAmount();
        if (calculateSeason2LiquidRemainingCredits(msg.sender) < amount) revert InsufficientCredits();

        liquidSpentCredits[msg.sender] += amount;
        uint256 nftId = optionsToken.exerciseVe(amount, msg.sender);

        emit LiquidConduitCreditsRedeemed(msg.sender, amount, nftId);
    }

    /**
     * @notice Internal function to redeem veMaxi credits
     * @param amount Amount of credits to redeem
     */
    function _redeemVeMaxiCredits(uint256 amount) internal {
        if (amount == 0) revert InvalidAmount();
        if (calculateVeMaxiRemainingCredits(msg.sender) < amount) revert InsufficientCredits();

        veMaxiSpentCredits[msg.sender] += amount;
        uint256 nftId = optionsToken.exerciseVe(amount, msg.sender);

        emit VeMaxiCreditsRedeemed(msg.sender, amount, nftId);
    }

    /*
     * Admin Functions
     */

    /**
     * @notice Update liquid account multiplier
     * @param _newMultiplier New multiplier in basis points
     */
    function setLiquidAccountMultiplier(uint256 _newMultiplier) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 oldMultiplier = liquidAccountMultiplier;
        liquidAccountMultiplier = _newMultiplier;
        emit LiquidAccountMultiplierUpdated(oldMultiplier, _newMultiplier);
    }

    /**
     * @notice Update Season 1 snapshot contract
     * @param _newSnapshot New snapshot contract address
     */
    function setSeason1Snapshot(ILiquidConduit _newSnapshot) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(_newSnapshot) == address(0)) revert InvalidAddress();
        address oldSnapshot = address(season1Snapshot);
        season1Snapshot = _newSnapshot;
        emit Season1SnapshotUpdated(oldSnapshot, address(_newSnapshot));
    }

    /**
     * @notice Add new liquid conduits
     * @param _conduits Array of conduit addresses to add
     */
    function addLiquidConduits(ILiquidConduit[] calldata _conduits) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i = 0; i < _conduits.length; i++) {
            address conduitAddr = address(_conduits[i]);
            if (conduitAddr == address(0)) revert InvalidAddress();
            if (isLiquidConduit[conduitAddr]) revert DuplicateConduit();
            isLiquidConduit[conduitAddr] = true;
            liquidConduits.push(_conduits[i]);
            emit LiquidConduitAdded(conduitAddr);
        }
    }

    /**
     * @notice Remove existing liquid conduits
     * @dev Order is not preserved
     * @param _conduits Array of conduit addresses to remove
     */
    function removeLiquidConduits(ILiquidConduit[] calldata _conduits) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i = 0; i < _conduits.length; i++) {
            address conduitAddr = address(_conduits[i]);
            if (!isLiquidConduit[conduitAddr]) revert ConduitNotFound();

            // Find index
            uint256 indexToRemove = type(uint256).max;
            for (uint256 j = 0; j < liquidConduits.length; j++) {
                if (address(liquidConduits[j]) == conduitAddr) {
                    indexToRemove = j;
                    break;
                }
            }
            if (indexToRemove == type(uint256).max) revert ConduitNotFound();

            // Swap and pop
            uint256 lastIdx = liquidConduits.length - 1;
            if (indexToRemove != lastIdx) {
                liquidConduits[indexToRemove] = liquidConduits[lastIdx];
            }
            liquidConduits.pop();
            isLiquidConduit[conduitAddr] = false;
            emit LiquidConduitRemoved(conduitAddr);
        }
    }

    /**
     * @notice Update veMaxi multiplier
     * @param _newMultiplier New multiplier in basis points
     */
    function setVeMaxiMultiplier(uint256 _newMultiplier) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 oldMultiplier = veMaxiMultiplier;
        veMaxiMultiplier = _newMultiplier;
        emit VeMaxiMultiplierUpdated(oldMultiplier, _newMultiplier);
    }

    /**
     * @notice Update veMaxi conduit
     * @param _newConduit New veMaxi conduit address
     */
    function setVeMaxiConduit(VeMaxiTokenConduit _newConduit) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(_newConduit) == address(0)) revert InvalidAddress();
        address oldConduit = address(veMaxiConduit);
        veMaxiConduit = _newConduit;
        emit VeMaxiConduitUpdated(oldConduit, address(_newConduit));
    }

    /**
     * @notice Emergency function to recover stuck tokens
     * @param token Token address to recover
     * @param amount Amount to recover
     * @param recipient Address to send recovered tokens to
     */
    function emergencyRecover(address token, uint256 amount, address recipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0) || recipient == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();
        IERC20(token).transfer(recipient, amount);
    }
}

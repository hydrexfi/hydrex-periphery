// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IOptionsToken} from "../interfaces/IOptionsToken.sol";
import {ILiquidConduit} from "../interfaces/ILiquidConduit.sol";
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
 * @title AnchorClubSeason3
 * @notice Season 3 rewards system with reduced multipliers
 * @dev Same architecture as Season 2, shifted up by one season:
 *      1. Liquid conduit credits: multiplier * (current total across live conduits - Season 2 snapshot)
 *      2. VeMaxi credits: multiplier * ((flexLive + protocolLive) - (flexSnapshot + protocolSnapshot))
 *
 *      Season 2 baselines must be populated before deposits/locks resume so Season 2 earnings
 *      are not rewarded again at Season 3's rate.
 */
contract AnchorClubSeason3 is AccessControl, ReentrancyGuard {
    /// @notice Options token used for exercising credits into veNFTs
    IOptionsToken public optionsToken;

    /*
     * Liquid Conduit State
     */

    /// @notice Season 2 snapshot contract (frozen baseline of summed live cumulativeOptionsClaimed)
    ILiquidConduit public season2Snapshot;

    /// @notice Array of current live liquid conduits (continue to accrue during Season 3)
    ILiquidConduit[] public liquidConduits;

    /// @notice Quick lookup for valid liquid conduits
    mapping(address => bool) public isLiquidConduit;

    /// @notice Liquid account multiplier in basis points (7500 = 0.75x)
    uint256 public liquidAccountMultiplier;

    /// @notice Tracks liquid credits spent per user
    mapping(address => uint256) public liquidSpentCredits;

    /*
     * VeMaxi Conduit State
     */

    /// @notice Live VeMaxi conduit (totalFlexLocked / totalProtocolLocked keep growing)
    IVeMaxiBalances public veMaxiConduit;

    /// @notice Season 2 VeMaxi snapshot (frozen flex+protocol locked baselines)
    IVeMaxiBalances public veMaxiSeason2Snapshot;

    /// @notice Tracks veMaxi credits spent per user
    mapping(address => uint256) public veMaxiSpentCredits;

    /// @notice VeMaxi multiplier in basis points (20000 = 2.0x)
    uint256 public veMaxiMultiplier;

    /*
     * Events
     */

    /// @notice Emitted when liquid conduit credits are redeemed
    event LiquidConduitCreditsRedeemed(address indexed user, uint256 creditsSpent, uint256 nftId);

    /// @notice Emitted when liquid account multiplier is updated
    event LiquidAccountMultiplierUpdated(uint256 oldMultiplier, uint256 newMultiplier);

    /// @notice Emitted when Season 2 snapshot is updated
    event Season2SnapshotUpdated(address indexed oldSnapshot, address indexed newSnapshot);

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

    /// @notice Emitted when veMaxi Season 2 snapshot is updated
    event VeMaxiSeason2SnapshotUpdated(address indexed oldSnapshot, address indexed newSnapshot);

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
     * @notice Initialize Season 3 contract
     * @param _optionsToken Options token for exercising credits
     * @param _season2Snapshot Season 2 snapshot contract (liquid baseline)
     * @param _veMaxiConduit Live VeMaxi conduit
     * @param _veMaxiSeason2Snapshot Season 2 VeMaxi snapshot (flex+protocol baseline)
     * @param _admin Admin address
     */
    constructor(
        IOptionsToken _optionsToken,
        ILiquidConduit _season2Snapshot,
        IVeMaxiBalances _veMaxiConduit,
        IVeMaxiBalances _veMaxiSeason2Snapshot,
        address _admin
    ) {
        if (address(_optionsToken) == address(0)) revert InvalidAddress();
        if (address(_season2Snapshot) == address(0)) revert InvalidAddress();
        if (address(_veMaxiConduit) == address(0)) revert InvalidAddress();
        if (address(_veMaxiSeason2Snapshot) == address(0)) revert InvalidAddress();
        if (_admin == address(0)) revert InvalidAddress();

        optionsToken = _optionsToken;
        season2Snapshot = _season2Snapshot;
        veMaxiConduit = _veMaxiConduit;
        veMaxiSeason2Snapshot = _veMaxiSeason2Snapshot;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);

        liquidAccountMultiplier = 7500; // 0.75x
        veMaxiMultiplier = 20000; // 2.0x
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
     * @notice Calculate Season 3 liquid credits for a user
     * @dev Credits = multiplier * (current total - Season 2 snapshot)
     * @param user User address
     * @return Season 3 liquid credits earned
     */
    function calculateSeason3LiquidCredits(address user) public view returns (uint256) {
        uint256 currentTotal = 0;
        for (uint256 i = 0; i < liquidConduits.length; i++) {
            currentTotal += liquidConduits[i].cumulativeOptionsClaimed(user);
        }
        uint256 season2Amount = season2Snapshot.cumulativeOptionsClaimed(user);
        uint256 newClaims = currentTotal > season2Amount ? currentTotal - season2Amount : 0;
        return (newClaims * liquidAccountMultiplier) / 10000;
    }

    /**
     * @notice Calculate remaining Season 3 liquid credits for a user
     * @param user User address
     * @return Remaining Season 3 liquid credits available
     */
    function calculateSeason3LiquidRemainingCredits(address user) public view returns (uint256) {
        uint256 earned = calculateSeason3LiquidCredits(user);
        uint256 spent = liquidSpentCredits[user];
        return earned > spent ? earned - spent : 0;
    }

    /**
     * @notice Calculate Season 3 veMaxi credits for a user
     * @dev Credits = multiplier * ((flexLive + protocolLive) - (flexSnapshot + protocolSnapshot))
     * @param user User address
     * @return Season 3 veMaxi credits earned
     */
    function calculateVeMaxiCredits(address user) public view returns (uint256) {
        uint256 liveTotal = veMaxiConduit.totalFlexLocked(user) + veMaxiConduit.totalProtocolLocked(user);
        uint256 snapshotTotal = veMaxiSeason2Snapshot.totalFlexLocked(user) +
            veMaxiSeason2Snapshot.totalProtocolLocked(user);
        uint256 newLocked = liveTotal > snapshotTotal ? liveTotal - snapshotTotal : 0;
        return (newLocked * veMaxiMultiplier) / 10000;
    }

    /**
     * @notice Calculate remaining veMaxi credits for a user
     * @param user User address
     * @return Remaining veMaxi credits available
     */
    function calculateVeMaxiRemainingCredits(address user) public view returns (uint256) {
        uint256 earned = calculateVeMaxiCredits(user);
        uint256 spent = veMaxiSpentCredits[user];
        return earned > spent ? earned - spent : 0;
    }

    /**
     * @notice Calculate total credits across all sources
     * @param user User address
     * @return Total credits from Season 3 liquid + veMaxi
     */
    function calculateTotalCredits(address user) external view returns (uint256) {
        return calculateSeason3LiquidCredits(user) + calculateVeMaxiCredits(user);
    }

    /**
     * @notice Calculate total remaining credits across all sources
     * @param user User address
     * @return Total remaining credits available
     */
    function calculateTotalRemainingCredits(address user) external view returns (uint256) {
        return calculateSeason3LiquidRemainingCredits(user) + calculateVeMaxiRemainingCredits(user);
    }

    /*
     * User Functions
     */

    /**
     * @notice Redeem Season 3 liquid conduit credits for a permanent veNFT
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
     * @notice Redeem both Season 3 liquid and veMaxi credits in a single transaction
     * @dev Mints a single combined veNFT for the sum of both amounts
     * @param liquidAmount Amount of liquid credits to redeem (0 to skip)
     * @param veMaxiAmount Amount of veMaxi credits to redeem (0 to skip)
     */
    function redeemCombinedCredits(uint256 liquidAmount, uint256 veMaxiAmount) external nonReentrant {
        if (liquidAmount == 0 && veMaxiAmount == 0) revert InvalidAmount();

        if (liquidAmount > 0 && calculateSeason3LiquidRemainingCredits(msg.sender) < liquidAmount) {
            revert InsufficientCredits();
        }
        if (veMaxiAmount > 0 && calculateVeMaxiRemainingCredits(msg.sender) < veMaxiAmount) {
            revert InsufficientCredits();
        }

        liquidSpentCredits[msg.sender] += liquidAmount;
        veMaxiSpentCredits[msg.sender] += veMaxiAmount;

        uint256 nftId = optionsToken.exerciseVe(liquidAmount + veMaxiAmount, msg.sender);

        if (liquidAmount > 0) {
            emit LiquidConduitCreditsRedeemed(msg.sender, liquidAmount, nftId);
        }
        if (veMaxiAmount > 0) {
            emit VeMaxiCreditsRedeemed(msg.sender, veMaxiAmount, nftId);
        }
    }

    /*
     * Internal Functions
     */

    function _redeemLiquidCredits(uint256 amount) internal {
        if (amount == 0) revert InvalidAmount();
        if (calculateSeason3LiquidRemainingCredits(msg.sender) < amount) revert InsufficientCredits();

        liquidSpentCredits[msg.sender] += amount;
        uint256 nftId = optionsToken.exerciseVe(amount, msg.sender);

        emit LiquidConduitCreditsRedeemed(msg.sender, amount, nftId);
    }

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
     * @notice Update Season 2 snapshot contract
     * @param _newSnapshot New snapshot contract address
     */
    function setSeason2Snapshot(ILiquidConduit _newSnapshot) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(_newSnapshot) == address(0)) revert InvalidAddress();
        address oldSnapshot = address(season2Snapshot);
        season2Snapshot = _newSnapshot;
        emit Season2SnapshotUpdated(oldSnapshot, address(_newSnapshot));
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

            uint256 indexToRemove = type(uint256).max;
            for (uint256 j = 0; j < liquidConduits.length; j++) {
                if (address(liquidConduits[j]) == conduitAddr) {
                    indexToRemove = j;
                    break;
                }
            }
            if (indexToRemove == type(uint256).max) revert ConduitNotFound();

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
    function setVeMaxiConduit(IVeMaxiBalances _newConduit) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(_newConduit) == address(0)) revert InvalidAddress();
        address oldConduit = address(veMaxiConduit);
        veMaxiConduit = _newConduit;
        emit VeMaxiConduitUpdated(oldConduit, address(_newConduit));
    }

    /**
     * @notice Update veMaxi Season 2 snapshot
     * @param _newSnapshot New snapshot address
     */
    function setVeMaxiSeason2Snapshot(IVeMaxiBalances _newSnapshot) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(_newSnapshot) == address(0)) revert InvalidAddress();
        address oldSnapshot = address(veMaxiSeason2Snapshot);
        veMaxiSeason2Snapshot = _newSnapshot;
        emit VeMaxiSeason2SnapshotUpdated(oldSnapshot, address(_newSnapshot));
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

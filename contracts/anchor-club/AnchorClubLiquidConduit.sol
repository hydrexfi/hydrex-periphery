// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LiquidAccountConduitSimple} from "../conduits/LiquidAccountConduitSimple.sol";
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
 * @title AnchorClubLiquidConduit
 * @notice Manages Anchor Club Credits earned through Liquid Account Automations
 * @dev Users earn a bonus on all oHYDX claimed through the liquid conduit
 *      Credits are redeemable 1:1 for earning power via permanent veNFT creation
 */
contract AnchorClubLiquidConduit is AccessControl, ReentrancyGuard {
    /// @notice List of Liquid Account conduits contributing to credit accrual
    LiquidAccountConduitSimple[] public liquidConduits;

    /// @notice Quick lookup to verify an address is an approved liquid conduit
    mapping(address => bool) public isLiquidConduit;

    IOptionsToken public optionsToken;

    /// @notice Liquid Account bonus multiplier (250% = 2.5x in basis points)
    uint256 public liquidAccountMultiplier;

    /// @notice Tracks credits spent by each user
    mapping(address => uint256) public spentCredits;

    /*
     * Events
     */

    event LiquidConduitAnchorClubCreditsRedeemed(address indexed user, uint256 creditsSpent, uint256 nftId);
    event LiquidConduitAdded(address indexed conduit);
    event LiquidConduitRemoved(address indexed conduit);
    event LiquidAccountMultiplierUpdated(uint256 oldMultiplier, uint256 newMultiplier);

    /*
     * Errors
     */

    error InsufficientCredits();
    error InvalidAmount();
    error InvalidAddress();
    error DuplicateConduit();
    error ConduitNotFound();

    /*
     * Constructor
     */

    constructor(LiquidAccountConduitSimple _liquidConduit, IOptionsToken _optionsToken, address _admin) {
        if (address(_liquidConduit) == address(0) || address(_optionsToken) == address(0) || _admin == address(0)) {
            revert InvalidAddress();
        }
        optionsToken = _optionsToken;
        liquidAccountMultiplier = 25000; // 250% bonus (2.5x)
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);

        // Seed initial conduit
        address conduitAddr = address(_liquidConduit);
        if (isLiquidConduit[conduitAddr]) revert DuplicateConduit();
        isLiquidConduit[conduitAddr] = true;
        liquidConduits.push(_liquidConduit);
        emit LiquidConduitAdded(conduitAddr);
    }

    /*
     * View Functions
     */

    /// @notice Returns the full list of liquid conduits
    function getLiquidConduits() external view returns (LiquidAccountConduitSimple[] memory) {
        return liquidConduits;
    }

    /// @notice Calculates total credits earned by a user from liquid conduit (with bonus)
    /// @param user The user address to check
    /// @return Total credits earned (includes multiplier bonus)
    function calculateTotalCredits(address user) public view returns (uint256) {
        uint256 cumulativeClaimed = 0;
        for (uint256 i = 0; i < liquidConduits.length; i++) {
            cumulativeClaimed += liquidConduits[i].cumulativeOptionsClaimed(user);
        }
        return (cumulativeClaimed * liquidAccountMultiplier) / 10000;
    }

    /// @notice Calculates remaining credits available for a user to spend
    /// @param user The user address to check
    /// @return Remaining credits available
    function calculateRemainingCredits(address user) public view returns (uint256) {
        return calculateTotalCredits(user) - spentCredits[user];
    }

    /*
     * User Functions
     */

    /// @notice Redeem liquid conduit credits to create a protocol account (permanent veNFT)
    /// @dev Burns option tokens held by this contract and creates a permanent lock for the user
    /// @param amount The amount of credits to redeem (in oHYDX equivalent)
    function redeemCredits(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();

        // Check for sufficient credits
        uint256 remainingCredits = calculateRemainingCredits(msg.sender);
        if (remainingCredits < amount) revert InsufficientCredits();

        // Update spent credits
        spentCredits[msg.sender] += amount;

        // Exercise options to create permanent veNFT for user
        uint256 nftId = optionsToken.exerciseVe(amount, msg.sender);

        emit LiquidConduitAnchorClubCreditsRedeemed(msg.sender, amount, nftId);
    }

    /*
     * Admin Functions
     */

    /// @notice Add new liquid conduits
    /// @param _conduits Array of conduits to add
    function addLiquidConduits(LiquidAccountConduitSimple[] calldata _conduits) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i = 0; i < _conduits.length; i++) {
            address conduitAddr = address(_conduits[i]);
            if (conduitAddr == address(0)) revert InvalidAddress();
            if (isLiquidConduit[conduitAddr]) revert DuplicateConduit();
            isLiquidConduit[conduitAddr] = true;
            liquidConduits.push(_conduits[i]);
            emit LiquidConduitAdded(conduitAddr);
        }
    }

    /// @notice Remove existing liquid conduits
    /// @dev Order of `liquidConduits` is not preserved
    /// @param _conduits Array of conduits to remove
    function removeLiquidConduits(
        LiquidAccountConduitSimple[] calldata _conduits
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
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

    /// @notice Update the liquid account multiplier
    /// @param _newMultiplier New multiplier value in basis points
    function setLiquidAccountMultiplier(uint256 _newMultiplier) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 oldMultiplier = liquidAccountMultiplier;
        liquidAccountMultiplier = _newMultiplier;
        emit LiquidAccountMultiplierUpdated(oldMultiplier, _newMultiplier);
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

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
 * @dev Users earn 250% bonus (2.5x multiplier) on all oHYDX claimed through the liquid conduit
 *      Credits are redeemable 1:1 for earning power via permanent veNFT creation
 */
contract AnchorClubLiquidConduit is AccessControl, ReentrancyGuard {
    LiquidAccountConduitSimple public liquidConduit;
    IOptionsToken public optionsToken;

    /// @notice Liquid Account bonus multiplier (250% = 2.5x in basis points)
    uint256 public constant LIQUID_ACCOUNT_MULTIPLIER = 25000;

    /// @notice Tracks credits spent by each user
    mapping(address => uint256) public spentCredits;

    /*
     * Events
     */

    event LiquidConduitAnchorClubCreditsRedeemed(address indexed user, uint256 creditsSpent, uint256 nftId);

    /*
     * Errors
     */

    error InsufficientCredits();
    error InvalidAmount();
    error InvalidAddress();

    /*
     * Constructor
     */

    constructor(LiquidAccountConduitSimple _liquidConduit, IOptionsToken _optionsToken, address _admin) {
        if (address(_liquidConduit) == address(0) || address(_optionsToken) == address(0) || _admin == address(0)) {
            revert InvalidAddress();
        }

        liquidConduit = _liquidConduit;
        optionsToken = _optionsToken;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    /*
     * View Functions
     */

    /// @notice Calculates total credits earned by a user from liquid conduit (with 250% bonus)
    /// @param user The user address to check
    /// @return Total credits earned (includes 250% bonus)
    function calculateTotalCredits(address user) public view returns (uint256) {
        uint256 cumulativeClaimed = liquidConduit.cumulativeOptionsClaimed(user);
        return (cumulativeClaimed * LIQUID_ACCOUNT_MULTIPLIER) / 10000;
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

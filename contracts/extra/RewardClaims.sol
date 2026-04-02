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

/**
 * @title RewardClaims
 * @notice Admin configures per-address token reward allocations; recipients claim at any time.
 * @dev Any ERC-20 token is supported. Contract must hold sufficient token balance before claims.
 */
contract RewardClaims is AccessControl {
    using SafeERC20 for IERC20;

    /// @notice Remaining claimable amount per recipient per token
    mapping(address => mapping(address => uint256)) public claimable;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event AllocationSet(address indexed recipient, address indexed token, uint256 amount);
    event Claimed(address indexed recipient, address indexed token, uint256 amount);
    event EmergencyRecovered(address indexed token, address indexed recipient, uint256 amount);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error ZeroAmount();
    error ZeroAddress();
    error NothingToClaim();
    error LengthMismatch();

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // -------------------------------------------------------------------------
    // View Functions
    // -------------------------------------------------------------------------

    /**
     * @notice How much `recipient` can still claim of `token`.
     */
    function getClaimable(address recipient, address token) external view returns (uint256) {
        return claimable[recipient][token];
    }

    /**
     * @notice Batch read: returns claimable amounts for multiple (recipient, token) pairs.
     * @param recipients Array of recipient addresses
     * @param tokens     Array of token addresses (1-to-1 with recipients)
     */
    function getClaimableBatch(
        address[] calldata recipients,
        address[] calldata tokens
    ) external view returns (uint256[] memory amounts) {
        if (recipients.length != tokens.length) revert LengthMismatch();
        amounts = new uint256[](recipients.length);
        for (uint256 i = 0; i < recipients.length; i++) {
            amounts[i] = claimable[recipients[i]][tokens[i]];
        }
    }

    // -------------------------------------------------------------------------
    // Claim
    // -------------------------------------------------------------------------

    /**
     * @notice Claim the caller's full allocation of `token`.
     * @param token ERC-20 token to claim
     */
    function claim(address token) external {
        uint256 amount = claimable[msg.sender][token];
        if (amount == 0) revert NothingToClaim();

        claimable[msg.sender][token] = 0;
        IERC20(token).safeTransfer(msg.sender, amount);

        emit Claimed(msg.sender, token, amount);
    }

    // -------------------------------------------------------------------------
    // Admin Functions
    // -------------------------------------------------------------------------

    /**
     * @notice Set (or overwrite) the claimable allocation for a single recipient.
     * @dev Setting to 0 effectively removes the allocation.
     * @param recipient Address that can claim
     * @param token     ERC-20 token
     * @param amount    Amount the recipient may claim (replaces any existing value)
     */
    function setAllocation(address recipient, address token, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (recipient == address(0) || token == address(0)) revert ZeroAddress();
        claimable[recipient][token] = amount;
        emit AllocationSet(recipient, token, amount);
    }

    /**
     * @notice Batch-set allocations for a single token across many recipients.
     * @param token      ERC-20 token address
     * @param recipients Array of recipient addresses
     * @param amounts    Array of claimable amounts (1-to-1 with recipients)
     */
    function setAllocations(
        address token,
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        uint256 len = recipients.length;
        if (amounts.length != len) revert LengthMismatch();

        for (uint256 i = 0; i < len; i++) {
            if (recipients[i] == address(0)) revert ZeroAddress();
            claimable[recipients[i]][token] = amounts[i];
            emit AllocationSet(recipients[i], token, amounts[i]);
        }
    }

    /**
     * @notice Recover any tokens from the contract (e.g. excess deposits or wrong tokens).
     * @param token     Token to recover
     * @param recipient Destination address
     * @param amount    Amount to transfer
     */
    function emergencyRecover(
        address token,
        address recipient,
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0) || recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        IERC20(token).safeTransfer(recipient, amount);
        emit EmergencyRecovered(token, recipient, amount);
    }
}

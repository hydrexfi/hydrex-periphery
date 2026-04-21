// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/*
  ______   ________  __    __  _______  
 /      \ |        \|  \  |  \|       \ 
|  $$$$$$\| $$$$$$$$| $$\ | $$| $$$$$$$\
| $$___\$$| $$__    | $$$\| $$| $$  | $$
 \$$    \ | $$  \   | $$$$\ $$| $$  | $$
 _\$$$$$$\| $$$$$   | $$\$$ $$| $$  | $$
|  \__| $$| $$_____ | $$ \$$$$| $$__/ $$
 \$$    $$| $$     \| $$  \$$$| $$    $$
  \$$$$$$  \$$$$$$$$ \$$   \$$ \$$$$$$$        
*/

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title SendReferralClaims
 * @notice USDC referral rewards pool for Send. Operators push cumulative
 *         lifetime allocations; referrers claim the unclaimed delta at any time.
 * @dev Accounting uses two monotonic counters per user:
 *        - `totalAllocated` — lifetime USDC owed, set by the operator
 *        - `totalClaimed`   — lifetime USDC paid out, grows only on claim
 */
contract SendReferralClaims is AccessControl {
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    address public constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @notice USDC token this contract pays out (Base mainnet)
    IERC20 public constant usdc = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);

    /// @notice Lifetime USDC allocated per user (only ever grows)
    mapping(address => uint256) public totalAllocated;
    /// @notice Lifetime USDC claimed per user (only ever grows)
    mapping(address => uint256) public totalClaimed;

    event AllocationUpdated(address indexed recipient, uint256 delta, uint256 newTotalAllocated);
    event AllocationReset(address indexed recipient, uint256 priorTotalAllocated, uint256 priorTotalClaimed);
    event Claimed(address indexed recipient, uint256 amount);
    event TokenRecovered(address indexed token, uint256 amount, address indexed to);

    error ZeroAddress();
    error ZeroAmount();
    error NothingToClaim();
    error LengthMismatch();
    error AllocationDecrease(address recipient, uint256 current, uint256 proposed);
    error ETHTransferFailed();

    constructor(address _admin) {
        if (_admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _admin);
    }

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice USDC still owed to `user` (totalAllocated - totalClaimed).
     */
    function pendingClaimAmount(address user) public view returns (uint256) {
        return totalAllocated[user] - totalClaimed[user];
    }

    /**
     * @notice Batch version of {pendingClaimAmount}.
     * @param users Addresses to look up
     */
    function pendingClaimAmountBatch(address[] calldata users) external view returns (uint256[] memory out) {
        out = new uint256[](users.length);
        for (uint256 i = 0; i < users.length; i++) {
            out[i] = totalAllocated[users[i]] - totalClaimed[users[i]];
        }
    }

    /**
     * @notice Returns full accounting for a user in one call.
     * @return pending   Currently claimable USDC
     * @return allocated Lifetime USDC allocated
     * @return claimed   Lifetime USDC claimed
     */
    function getStats(address user) external view returns (uint256 pending, uint256 allocated, uint256 claimed) {
        allocated = totalAllocated[user];
        claimed = totalClaimed[user];
        pending = allocated - claimed;
    }

    /*//////////////////////////////////////////////////////////////
                                CLAIM
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Claim the caller's full USDC balance.
     * @return amount USDC transferred to the caller
     */
    function claim() external returns (uint256 amount) {
        amount = _claim(msg.sender);
    }

    /**
     * @notice Operator-triggered claim on a user's behalf. USDC is always sent
     *         to `recipient`; the operator cannot redirect funds elsewhere.
     * @param recipient User whose balance is being claimed
     */
    function claimFor(address recipient) external onlyRole(OPERATOR_ROLE) returns (uint256 amount) {
        if (recipient == address(0)) revert ZeroAddress();
        amount = _claim(recipient);
    }

    /**
     * @notice Batch operator-triggered claims. Skips users with nothing to
     *         claim instead of reverting so a single empty entry doesn't nuke
     *         the tx.
     * @param recipients Users to claim on behalf of
     * @return totalAmount Sum of USDC distributed
     */
    function claimForBatch(
        address[] calldata recipients
    ) external onlyRole(OPERATOR_ROLE) returns (uint256 totalAmount) {
        for (uint256 i = 0; i < recipients.length; i++) {
            address recipient = recipients[i];
            if (recipient == address(0)) revert ZeroAddress();
            if (totalAllocated[recipient] == totalClaimed[recipient]) continue;

            totalAmount += _claim(recipient);
        }
    }

    function _claim(address recipient) internal returns (uint256 amount) {
        amount = totalAllocated[recipient] - totalClaimed[recipient];
        if (amount == 0) revert NothingToClaim();

        totalClaimed[recipient] += amount;
        usdc.safeTransfer(recipient, amount);

        emit Claimed(recipient, amount);
    }

    /*//////////////////////////////////////////////////////////////
                              ALLOCATOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set a referrer's cumulative lifetime allocation.
     * @dev `newTotal` is the full amount the user has ever earned — not a
     *      delta. Must be >= current `totalAllocated` (monotonic). Equal
     *      values are no-ops so retries are safe. Reverts with
     *      {AllocationDecrease} if `newTotal` is lower than current.
     * @param recipient Referrer whose allocation is being set
     * @param newTotal  New cumulative lifetime allocation in USDC
     */
    function setAllocation(address recipient, uint256 newTotal) external onlyRole(OPERATOR_ROLE) {
        _setAllocation(recipient, newTotal);
    }

    /**
     * @notice Batch version of {setAllocation}. Typical use: daily settlement
     *         after the Send referral TokenJar sweep funds this contract.
     * @param recipients Parallel array of referrers
     * @param newTotals  Parallel array of cumulative lifetime allocations
     */
    function setAllocations(
        address[] calldata recipients,
        uint256[] calldata newTotals
    ) external onlyRole(OPERATOR_ROLE) {
        uint256 len = recipients.length;
        if (newTotals.length != len) revert LengthMismatch();
        for (uint256 i = 0; i < len; i++) {
            _setAllocation(recipients[i], newTotals[i]);
        }
    }

    function _setAllocation(address recipient, uint256 newTotal) internal {
        if (recipient == address(0)) revert ZeroAddress();

        uint256 current = totalAllocated[recipient];
        if (newTotal == current) return;
        if (newTotal < current) revert AllocationDecrease(recipient, current, newTotal);

        totalAllocated[recipient] = newTotal;
        emit AllocationUpdated(recipient, newTotal - current, newTotal);
    }

    /*//////////////////////////////////////////////////////////////
                                ADMIN
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Wipe a user's accounting back to zero.
     * @dev Resets both `totalAllocated` and `totalClaimed` so the user starts
     *      fresh — any unclaimed pending balance is forfeited. Intended for
     *      blacklisting bad actors or correcting a bad push; the operator can
     *      re-credit via {setAllocation} afterward if needed. Admin-only
     *      (distinct from OPERATOR_ROLE) because this is destructive.
     * @param recipient User to reset
     */
    function resetAllocation(address recipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _resetAllocation(recipient);
    }

    /**
     * @notice Batch version of {resetAllocation}.
     * @param recipients Users to reset
     */
    function resetAllocations(address[] calldata recipients) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i = 0; i < recipients.length; i++) {
            _resetAllocation(recipients[i]);
        }
    }

    function _resetAllocation(address recipient) internal {
        if (recipient == address(0)) revert ZeroAddress();

        uint256 priorAllocated = totalAllocated[recipient];
        uint256 priorClaimed = totalClaimed[recipient];
        if (priorAllocated == 0 && priorClaimed == 0) return;

        totalAllocated[recipient] = 0;
        totalClaimed[recipient] = 0;
        emit AllocationReset(recipient, priorAllocated, priorClaimed);
    }

    /**
     * @notice Recover stuck tokens or native ETH.
     * @dev Does not adjust accounting — admin is responsible for only pulling
     *      unassigned funds. Pass {ETH_ADDRESS} as `token` to recover ETH.
     * @param token  ERC20 address, or ETH_ADDRESS for native ETH
     * @param amount Exact amount to recover
     * @param to     Destination address
     */
    function recoverToken(address token, uint256 amount, address to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (token == ETH_ADDRESS) {
            (bool ok, ) = payable(to).call{value: amount}("");
            if (!ok) revert ETHTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
        emit TokenRecovered(token, amount, to);
    }

    receive() external payable {}
}

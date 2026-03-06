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

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title HydrexMultiRouter
 * @notice Batched swap router that executes multiple independent swaps in a single transaction,
 *         routing through whitelisted external DEX routers with a configurable protocol fee.
 */
contract HydrexMultiRouter is AccessControlUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    /// @notice Sentinel address used to represent native ETH in swap operations
    address public constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    /// @notice Maximum allowed protocol fee in basis points (5%)
    uint256 public constant MAX_FEE_BPS = 500;
    /// @notice Maximum allowed referral fee in basis points (1%)
    uint256 public constant MAX_REFERRAL_FEE_BPS = 100;
    /// @notice Basis points denominator for fee calculations (10000 = 100%)
    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// @notice Mapping of DEX router addresses approved to execute swaps
    mapping(address => bool) public whitelistedRouters;

    /// @notice Address that receives protocol fees from swaps
    address public feeRecipient;
    /// @notice Protocol fee charged on swap outputs, in basis points
    uint256 public feeBps;

    /// @dev Storage gap for future upgrades
    uint256[50] private __gap;

    /**
     * @notice Parameters for a single swap operation
     * @param router Address of the whitelisted DEX router to execute the swap
     * @param inputAsset Address of the token being sold (or ETH_ADDRESS for native ETH)
     * @param outputAsset Address of the token being bought (or ETH_ADDRESS for native ETH)
     * @param inputAmount Amount of inputAsset to swap
     * @param minOutputAmount Minimum amount of outputAsset to receive (after all fees)
     * @param callData Encoded function call to execute on the router
     * @param recipient Address to receive the output tokens (after fees)
     * @param origin String identifier for tracking swap origin/source
     * @param referral Optional address to receive the referral fee (address(0) to disable)
     * @param referralFeeBps Referral fee in basis points, max 100 (1%). Ignored if referral is address(0)
     */
    struct SwapData {
        address router;
        address inputAsset;
        address outputAsset;
        uint256 inputAmount;
        uint256 minOutputAmount;
        bytes callData;
        address recipient;
        string origin;
        address referral;
        uint256 referralFeeBps;
    }

    /**
     * @notice Emitted when a swap is successfully executed
     * @param router Address of the DEX router that executed the swap
     * @param caller Address that called executeSwaps (msg.sender)
     * @param inputAsset Address of the token sold
     * @param outputAsset Address of the token bought
     * @param inputAmount Amount of inputAsset swapped
     * @param outputAmount Amount of outputAsset received by recipient (after all fees)
     * @param feeAmount Protocol fee deducted from the swap output
     * @param referral Address that received the referral fee (address(0) if none)
     * @param referralFeeAmount Referral fee deducted from the swap output
     * @param recipient Address that received the output tokens
     * @param origin String identifier for tracking swap origin
     */
    event SwapExecuted(
        address indexed router,
        address indexed inputAsset,
        address indexed recipient,
        address caller,
        address outputAsset,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 feeAmount,
        address referral,
        uint256 referralFeeAmount,
        string origin
    );

    /// @notice Emitted when a DEX router is added to the whitelist
    event RouterAdded(address indexed router);
    /// @notice Emitted when a DEX router is removed from the whitelist
    event RouterRemoved(address indexed router);
    /// @notice Emitted when the protocol fee is updated
    event FeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    /// @notice Emitted when the fee recipient address is changed
    event FeeRecipientUpdated(address oldRecipient, address newRecipient);
    /// @notice Emitted when tokens are recovered by admin in an emergency
    event EmergencyRecovery(address indexed token, uint256 amount, address indexed recipient);

    /// @notice Thrown when an address parameter is zero or invalid
    error InvalidAddress();
    /// @notice Thrown when an amount parameter is zero or invalid
    error InvalidAmount();
    /// @notice Thrown when attempting to route through a non-whitelisted router
    error RouterNotWhitelisted();
    /// @notice Thrown when attempting to set a fee higher than MAX_FEE_BPS
    error FeeTooHigh();
    /// @notice Thrown when a referral fee exceeds MAX_REFERRAL_FEE_BPS (1%)
    error ReferralFeeTooHigh();
    /// @notice Thrown when a swap call to the DEX router fails
    error SwapFailed();
    /// @notice Thrown when a swap produces zero output tokens
    error InsufficientOutput();
    /// @notice Thrown when an ETH transfer fails
    error ETHTransferFailed();
    /// @notice Thrown when msg.value doesn't match the sum of ETH input amounts
    error InvalidETHAmount();
    /// @notice Thrown when the transaction is executed after the deadline
    error DeadlineExpired();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the contract with admin and fee recipient
     * @dev Can only be called once due to initializer modifier. Sets default fee to 10 bps (0.1%)
     * @param _admin Address to receive DEFAULT_ADMIN_ROLE
     * @param _feeRecipient Address to receive protocol fees
     */
    function initialize(address _admin, address _feeRecipient) external initializer {
        if (_admin == address(0) || _feeRecipient == address(0)) revert InvalidAddress();

        __AccessControl_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        feeRecipient = _feeRecipient;
        feeBps = 10;
    }

    /*//////////////////////////////////////////////////////////////
                            CORE EXECUTION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Execute multiple independent swaps in a single transaction.
     * @dev Pulls input tokens from msg.sender, routes through whitelisted DEX routers,
     *      deducts protocol fee from output, and sends results to specified recipients.
     *      msg.value must exactly equal the sum of inputAmount for all ETH-input swaps.
     * @param swaps Array of swap parameters to execute
     * @param deadline Unix timestamp after which the transaction will revert
     */
    function executeSwaps(SwapData[] calldata swaps, uint256 deadline) external payable nonReentrant {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (swaps.length == 0) revert InvalidAmount();

        uint256 totalETHInput;
        for (uint256 i = 0; i < swaps.length; i++) {
            if (swaps[i].inputAsset == ETH_ADDRESS) {
                totalETHInput += swaps[i].inputAmount;
            }
        }
        if (totalETHInput != msg.value) revert InvalidETHAmount();

        for (uint256 i = 0; i < swaps.length; i++) {
            _executeSwap(swaps[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                             INTERNALS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Execute a single swap operation
     * @param swap Swap parameters including router, assets, amounts, and recipient
     */
    function _executeSwap(SwapData calldata swap) internal {
        if (swap.router == address(0) || swap.recipient == address(0)) revert InvalidAddress();
        if (swap.recipient == address(this)) revert InvalidAddress();
        if (swap.inputAsset == address(0) || swap.outputAsset == address(0)) revert InvalidAddress();
        if (swap.inputAsset == swap.outputAsset) revert InvalidAddress();
        if (swap.inputAmount == 0) revert InvalidAmount();
        if (!whitelistedRouters[swap.router]) revert RouterNotWhitelisted();

        bool hasReferral = swap.referral != address(0);
        if (hasReferral && swap.referralFeeBps > MAX_REFERRAL_FEE_BPS) revert ReferralFeeTooHigh();

        bool inputIsETH = swap.inputAsset == ETH_ADDRESS;

        // Pull ERC20 input from caller and approve the DEX router
        if (!inputIsETH) {
            IERC20(swap.inputAsset).safeTransferFrom(msg.sender, address(this), swap.inputAmount);
            IERC20(swap.inputAsset).forceApprove(swap.router, swap.inputAmount);
        }

        uint256 outputBefore = _getBalance(swap.outputAsset);

        // Execute the swap
        (bool success, ) = swap.router.call{value: inputIsETH ? swap.inputAmount : 0}(swap.callData);

        // Always clear token approval after the swap attempt
        if (!inputIsETH) {
            IERC20(swap.inputAsset).forceApprove(swap.router, 0);
        }

        if (!success) revert SwapFailed();

        uint256 outputAmount = _getBalance(swap.outputAsset) - outputBefore;
        if (outputAmount == 0) revert InsufficientOutput();

        // Deduct protocol fee and optional referral fee
        uint256 feeAmount = (outputAmount * feeBps) / BPS_DENOMINATOR;
        uint256 referralFeeAmount = hasReferral ? (outputAmount * swap.referralFeeBps) / BPS_DENOMINATOR : 0;
        uint256 recipientAmount = outputAmount - feeAmount - referralFeeAmount;
        if (recipientAmount < swap.minOutputAmount) revert InsufficientOutput();

        // Distribute output
        _transferAsset(swap.outputAsset, swap.recipient, recipientAmount);
        _transferAsset(swap.outputAsset, feeRecipient, feeAmount);
        if (referralFeeAmount > 0) {
            _transferAsset(swap.outputAsset, swap.referral, referralFeeAmount);
        }

        emit SwapExecuted(
            swap.router,
            swap.inputAsset,
            swap.recipient,
            msg.sender,
            swap.outputAsset,
            swap.inputAmount,
            recipientAmount,
            feeAmount,
            swap.referral,
            referralFeeAmount,
            swap.origin
        );
    }

    /**
     * @dev Get the balance of an asset held by this contract
     * @param asset Address of the token (or ETH_ADDRESS for native ETH)
     * @return Balance of the asset
     */
    function _getBalance(address asset) internal view returns (uint256) {
        return asset == ETH_ADDRESS ? address(this).balance : IERC20(asset).balanceOf(address(this));
    }

    /**
     * @dev Transfer an asset to a recipient
     * @param token Address of the token (or ETH_ADDRESS for native ETH)
     * @param to Recipient address
     * @param amount Amount to transfer
     */
    function _transferAsset(address token, address to, uint256 amount) internal {
        if (token == ETH_ADDRESS) {
            (bool success, ) = payable(to).call{value: amount}("");
            if (!success) revert ETHTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                ADMIN 
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Add multiple DEX routers to the whitelist
     * @dev Only callable by DEFAULT_ADMIN_ROLE
     * @param routers Array of router addresses to whitelist
     */
    function addRouters(address[] calldata routers) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i = 0; i < routers.length; i++) {
            if (routers[i] == address(0)) revert InvalidAddress();
            if (whitelistedRouters[routers[i]]) continue;
            whitelistedRouters[routers[i]] = true;
            emit RouterAdded(routers[i]);
        }
    }

    /**
     * @notice Remove multiple DEX routers from the whitelist
     * @dev Only callable by DEFAULT_ADMIN_ROLE
     * @param routers Array of router addresses to remove
     */
    function removeRouters(address[] calldata routers) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i = 0; i < routers.length; i++) {
            if (routers[i] == address(0)) revert InvalidAddress();
            if (!whitelistedRouters[routers[i]]) continue;
            whitelistedRouters[routers[i]] = false;
            emit RouterRemoved(routers[i]);
        }
    }

    /**
     * @notice Update the protocol fee charged on swaps
     * @dev Only callable by DEFAULT_ADMIN_ROLE. Fee cannot exceed MAX_FEE_BPS (5%)
     * @param _feeBps New fee in basis points
     */
    function setFeeBps(uint256 _feeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        if (_feeBps == feeBps) revert InvalidAmount();
        uint256 oldFeeBps = feeBps;
        feeBps = _feeBps;
        emit FeeUpdated(oldFeeBps, _feeBps);
    }

    /**
     * @notice Update the address that receives protocol fees
     * @dev Only callable by DEFAULT_ADMIN_ROLE
     * @param _feeRecipient New fee recipient address
     */
    function setFeeRecipient(address _feeRecipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_feeRecipient == address(0)) revert InvalidAddress();
        if (_feeRecipient == feeRecipient) revert InvalidAddress();
        address oldRecipient = feeRecipient;
        feeRecipient = _feeRecipient;
        emit FeeRecipientUpdated(oldRecipient, _feeRecipient);
    }

    /**
     * @notice Emergency function to recover tokens stuck in the contract
     * @dev Only callable by DEFAULT_ADMIN_ROLE
     * @param token Address of the token to recover (or ETH_ADDRESS for native ETH)
     * @param amount Amount to recover
     * @param recipient Address to receive the recovered tokens
     */
    function emergencyRecover(address token, uint256 amount, address recipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert InvalidAddress();
        if (recipient == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();

        _transferAsset(token, recipient, amount);

        emit EmergencyRecovery(token, amount, recipient);
    }

    /// @notice Allow contract to receive ETH directly
    receive() external payable {}
}

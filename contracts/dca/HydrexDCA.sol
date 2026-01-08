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
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/**
 * @title HydrexDCA
 * @notice Dollar Cost Averaging (DCA) protocol for automated token swaps
 * @dev Custodial protocol that holds user funds and executes DCA orders
 */
contract HydrexDCA is AccessControlUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;
    using Address for address;

    /// @notice Role identifier for authorized operators
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    /// @notice Mapping of whitelisted swap routers
    mapping(address => bool) public whitelistedRouters;

    /// @notice Counter for generating unique order IDs
    uint256 public orderCounter;

    /// @notice Mapping from order ID to order details
    mapping(uint256 => Order) public orders;

    /// @notice Mapping from user to their order IDs
    mapping(address => uint256[]) public userOrders;

    /// @notice Minimum interval between swaps (default 1 minute)
    uint256 public minimumInterval;

    /// @notice Protocol fee in basis points (default 50 = 0.5%)
    uint256 public protocolFeeBps;

    /// @notice Fee recipient address
    address public feeRecipient;

    /// @notice Maximum fee in basis points (10% cap)
    uint256 public constant MAX_FEE_BPS = 1000;

    /// @notice Maximum number of swaps per order (default 100)
    uint256 public maxSwaps;

    /*
     * Structs
     */

    /// @notice Status of a DCA order
    enum OrderStatus {
        Active,
        Completed,
        Cancelled
    }

    /// @notice DCA order stored onchain
    struct Order {
        address user;
        address tokenIn;
        address tokenOut;
        uint256 totalAmount;
        uint256 remainingAmount;
        uint256 numberOfSwaps;
        uint256 swapsExecuted;
        uint256 amountPerSwap;
        uint256 interval;
        uint256 lastExecutionTime;
        uint256 minAmountOut;
        uint256 createdAt;
        OrderStatus status;
    }

    /// @notice Parameters for a single DCA swap execution
    struct SwapData {
        uint256 orderId;
        uint256 amountIn;
        uint256 minAmountOut;
        address router;
        bytes routerCalldata;
        address feeRecipient;
    }

    /*
     * Events
     */

    /// @notice Emitted when a new DCA order is created
    event OrderCreated(
        uint256 indexed orderId,
        address indexed user,
        address tokenIn,
        address tokenOut,
        uint256 totalAmount,
        uint256 numberOfSwaps,
        uint256 amountPerSwap,
        uint256 interval
    );

    /// @notice Emitted when a DCA swap is successfully executed
    event DCASwapExecuted(
        uint256 indexed orderId,
        address indexed user,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 feeAmount
    );

    /// @notice Emitted when a DCA swap fails
    event DCASwapFailed(uint256 indexed orderId, address indexed user, string reason);

    /// @notice Emitted when an order is cancelled
    event OrderCancelled(uint256 indexed orderId, address indexed user, uint256 refundAmount);

    /// @notice Emitted when an order is completed
    event OrderCompleted(uint256 indexed orderId, address indexed user);

    /// @notice Emitted when a router is whitelisted
    event RouterWhitelisted(address indexed router);

    /// @notice Emitted when a router is removed from whitelist
    event RouterRemoved(address indexed router);

    /// @notice Emitted when minimum interval is updated
    event MinimumIntervalUpdated(uint256 oldInterval, uint256 newInterval);

    /// @notice Emitted when protocol fee is updated
    event ProtocolFeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);

    /// @notice Emitted when fee recipient is updated
    event FeeRecipientUpdated(address oldRecipient, address newRecipient);

    /// @notice Emitted when max swaps is updated
    event MaxSwapsUpdated(uint256 oldMaxSwaps, uint256 newMaxSwaps);

    /*
     * Errors
     */

    error RouterNotWhitelisted();
    error InvalidAmounts();
    error InsufficientBalance();
    error InsufficientAllowance();
    error SwapFailed();
    error InsufficientReturnAmount();
    error InvalidAddress();
    error OrderNotFound();
    error OrderNotActive();
    error UnauthorizedCancellation();
    error IntervalNotMet();
    error InvalidOrderParameters();
    error IntervalTooShort();
    error FeeTooHigh();
    error InvalidFeeRecipient();

    /*
     * Constructor
     */

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /*
     * Initializer
     */

    /**
     * @notice Initialize the HydrexDCA contract
     * @param _admin Address granted `DEFAULT_ADMIN_ROLE`
     * @param _operator Address granted `OPERATOR_ROLE`
     * @param _feeRecipient Address to receive protocol fees
     */
    function initialize(address _admin, address _operator, address _feeRecipient) public initializer {
        if (_admin == address(0) || _operator == address(0)) revert InvalidAddress();
        if (_feeRecipient == address(0)) revert InvalidFeeRecipient();

        __AccessControl_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _operator);
        feeRecipient = _feeRecipient;
        
        // Initialize default values
        minimumInterval = 1 minutes;
        protocolFeeBps = 50;
        maxSwaps = 100;
    }

    /*
     * User Functions
     */

    /**
     * @notice Create a new DCA order (supports both ERC20 and native ETH)
     * @param tokenIn Input token address (use 0xEeee...eEeE for native ETH)
     * @param tokenOut Output token address
     * @param totalAmount Total amount of input tokens to DCA
     * @param numberOfSwaps Number of times to execute swaps
     * @param interval Minimum time between swaps (in seconds)
     * @param minAmountOut Minimum output amount per swap (slippage protection)
     */
    function createOrder(
        address tokenIn,
        address tokenOut,
        uint256 totalAmount,
        uint256 numberOfSwaps,
        uint256 interval,
        uint256 minAmountOut
    ) external payable nonReentrant returns (uint256 orderId) {
        if (tokenOut == address(0)) revert InvalidAddress();
        if (numberOfSwaps < 2 || numberOfSwaps > maxSwaps) revert InvalidAmounts();

        bool isETH = tokenIn == 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

        if (isETH) {
            // Native ETH order
            if (msg.value == 0) revert InvalidAmounts();
            if (totalAmount == 0) revert InvalidAmounts();
            if (totalAmount != msg.value) revert InvalidAmounts();
        } else {
            // ERC20 order
            if (tokenIn == address(0)) revert InvalidOrderParameters();
            if (totalAmount == 0) revert InvalidAmounts();
            if (msg.value > 0) revert InvalidOrderParameters();

            // Measure actual amount received and validate it matches expected
            uint256 balanceBefore = IERC20(tokenIn).balanceOf(address(this));
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), totalAmount);
            uint256 balanceAfter = IERC20(tokenIn).balanceOf(address(this));
            uint256 actualReceived = balanceAfter - balanceBefore;

            // Validate we received exactly what was expected
            if (actualReceived != totalAmount) revert InvalidAmounts();
        }

        // Create order
        orderId = _createOrder(msg.sender, tokenIn, tokenOut, totalAmount, numberOfSwaps, interval, minAmountOut);
    }

    /**
     * @notice Cancel an active order and refund remaining tokens
     * @param orderId ID of the order to cancel
     */
    function cancelOrder(uint256 orderId) external nonReentrant {
        Order storage order = orders[orderId];

        if (order.user == address(0)) revert OrderNotFound();
        if (order.user != msg.sender) revert UnauthorizedCancellation();
        if (order.status != OrderStatus.Active) revert OrderNotActive();

        uint256 refundAmount = order.remainingAmount;
        order.status = OrderStatus.Cancelled;
        order.remainingAmount = 0;

        // Refund remaining tokens
        if (refundAmount > 0) {
            _transfer(order.tokenIn, order.user, refundAmount);
        }

        emit OrderCancelled(orderId, order.user, refundAmount);
    }

    /*
     * Operator Functions
     */

    /**
     * @notice Execute a batch of DCA swaps
     * @dev Only callable by addresses with OPERATOR_ROLE
     * @param swaps Array of swap data to execute
     */
    function batchSwap(SwapData[] calldata swaps) external onlyRole(OPERATOR_ROLE) nonReentrant {
        for (uint256 i = 0; i < swaps.length; i++) {
            _executeSwap(swaps[i]);
        }
    }

    /*
     * Internal Functions
     */

    /**
     * @dev Create a new order
     */
    function _createOrder(
        address user,
        address tokenIn,
        address tokenOut,
        uint256 totalAmount,
        uint256 numberOfSwaps,
        uint256 interval,
        uint256 minAmountOut
    ) internal returns (uint256 orderId) {
        // Validate interval meets minimum
        if (interval < minimumInterval) revert IntervalTooShort();

        // Calculate amount per swap
        uint256 amountPerSwap = totalAmount / numberOfSwaps;

        orderId = orderCounter++;

        orders[orderId] = Order({
            user: user,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            totalAmount: totalAmount,
            remainingAmount: totalAmount,
            numberOfSwaps: numberOfSwaps,
            swapsExecuted: 0,
            amountPerSwap: amountPerSwap,
            interval: interval,
            lastExecutionTime: 0,
            minAmountOut: minAmountOut,
            createdAt: block.timestamp,
            status: OrderStatus.Active
        });

        userOrders[user].push(orderId);

        emit OrderCreated(orderId, user, tokenIn, tokenOut, totalAmount, numberOfSwaps, amountPerSwap, interval);
    }

    /**
     * @dev Execute a single DCA swap
     * @param swap Swap data containing all parameters
     */
    function _executeSwap(SwapData calldata swap) internal {
        Order storage order = orders[swap.orderId];

        // Validate order exists and is active
        if (order.user == address(0)) {
            emit DCASwapFailed(swap.orderId, address(0), "Order not found");
            return;
        }

        if (order.status != OrderStatus.Active) {
            emit DCASwapFailed(swap.orderId, order.user, "Order not active");
            return;
        }

        // Check interval
        if (order.lastExecutionTime != 0 && block.timestamp < order.lastExecutionTime + order.interval) {
            emit DCASwapFailed(swap.orderId, order.user, "Interval not met");
            return;
        }

        // Validate router is whitelisted
        if (!whitelistedRouters[swap.router]) {
            emit DCASwapFailed(swap.orderId, order.user, "Router not whitelisted");
            return;
        }

        // Validate amounts
        if (swap.amountIn == 0 || swap.amountIn > order.remainingAmount) {
            emit DCASwapFailed(swap.orderId, order.user, "Invalid amount");
            return;
        }

        // Handle ETH or ERC20 input
        bool isETH = order.tokenIn == 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

        if (!isETH) {
            // Approve swap router
            IERC20(order.tokenIn).forceApprove(swap.router, swap.amountIn);
        }

        // Record balance before swap
        uint256 balanceBefore = _getBalance(order.tokenOut);

        // Execute swap with router calldata
        (bool success, bytes memory returnData) = swap.router.call{value: isETH ? swap.amountIn : 0}(
            swap.routerCalldata
        );

        if (!success) {
            // Clear approval on failure
            if (!isETH) {
                IERC20(order.tokenIn).forceApprove(swap.router, 0);
            }
            emit DCASwapFailed(swap.orderId, order.user, _getRevertMsg(returnData));
            return;
        }

        // Clear approval
        if (!isETH) {
            IERC20(order.tokenIn).forceApprove(swap.router, 0);
        }

        // Calculate actual return amount
        uint256 balanceAfter = _getBalance(order.tokenOut);
        uint256 returnAmount = balanceAfter - balanceBefore;

        // Validate minimum return amount
        if (swap.minAmountOut != 0 && returnAmount < swap.minAmountOut) {
            emit DCASwapFailed(swap.orderId, order.user, "Insufficient return amount");
            return;
        }

        // Update order state
        order.remainingAmount -= swap.amountIn;
        order.swapsExecuted += 1;
        order.lastExecutionTime = block.timestamp;

        // Calculate protocol fee
        uint256 protocolFee = (returnAmount * protocolFeeBps) / 10000;
        uint256 userAmount = returnAmount - protocolFee;

        // Transfer to user
        if (userAmount > 0) {
            _transfer(order.tokenOut, order.user, userAmount);
        }

        // Transfer protocol fee
        uint256 feeAmount = protocolFee;
        if (feeAmount > 0) {
            _transfer(order.tokenOut, feeRecipient, feeAmount);
        }

        // Check if order is completed (all swaps executed or no remaining amount)
        if (order.swapsExecuted >= order.numberOfSwaps || order.remainingAmount == 0) {
            order.status = OrderStatus.Completed;
            emit OrderCompleted(swap.orderId, order.user);
        }

        emit DCASwapExecuted(
            swap.orderId,
            order.user,
            order.tokenIn,
            order.tokenOut,
            swap.amountIn,
            returnAmount,
            feeAmount
        );
    }

    /**
     * @dev Get balance of a token (handles ETH and ERC20)
     * @param token Token address (address(0) or 0xEeee...eEeE for ETH)
     * @return Balance of the token
     */
    function _getBalance(address token) internal view returns (uint256) {
        if (token == address(0) || token == 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE) {
            return address(this).balance;
        }
        return IERC20(token).balanceOf(address(this));
    }

    /**
     * @dev Transfer tokens (handles ETH and ERC20)
     * @param token Token address (address(0) or 0xEeee...eEeE for ETH)
     * @param to Recipient address
     * @param amount Amount to transfer
     */
    function _transfer(address token, address to, uint256 amount) internal {
        if (amount == 0) return;

        if (token == address(0) || token == 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE) {
            (bool success, ) = payable(to).call{value: amount}("");
            require(success, "ETH transfer failed");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    /**
     * @dev Extract revert message from failed call
     * @param returnData Return data from failed call
     * @return Revert message string
     */
    function _getRevertMsg(bytes memory returnData) internal pure returns (string memory) {
        if (returnData.length < 68) return "Swap failed";

        assembly {
            returnData := add(returnData, 0x04)
        }
        return abi.decode(returnData, (string));
    }

    /*
     * Admin Functions
     */

    /**
     * @notice Add routers to the whitelist
     * @param routers Array of router addresses to whitelist
     */
    function whitelistRouters(address[] calldata routers) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i = 0; i < routers.length; i++) {
            if (routers[i] == address(0)) revert InvalidAddress();
            whitelistedRouters[routers[i]] = true;
            emit RouterWhitelisted(routers[i]);
        }
    }

    /**
     * @notice Remove routers from the whitelist
     * @param routers Array of router addresses to remove
     */
    function removeRouters(address[] calldata routers) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i = 0; i < routers.length; i++) {
            whitelistedRouters[routers[i]] = false;
            emit RouterRemoved(routers[i]);
        }
    }

    /**
     * @notice Get all order IDs for a user
     * @param user User address
     * @return Array of order IDs
     */
    function getUserOrders(address user) external view returns (uint256[] memory) {
        return userOrders[user];
    }

    /**
     * @notice Get paginated orders with full details for a user
     * @param user User address
     * @param offset Starting index
     * @param limit Maximum number of orders to return
     * @return userOrdersData Array of full order details
     * @return total Total number of orders for the user
     */
    function getUserOrdersPaginated(
        address user,
        uint256 offset,
        uint256 limit
    ) external view returns (Order[] memory userOrdersData, uint256 total) {
        uint256[] storage allOrderIds = userOrders[user];
        total = allOrderIds.length;

        if (offset >= total) {
            return (new Order[](0), total);
        }

        uint256 end = offset + limit;
        if (end > total) {
            end = total;
        }

        uint256 resultLength = end - offset;
        userOrdersData = new Order[](resultLength);

        for (uint256 i = 0; i < resultLength; i++) {
            userOrdersData[i] = orders[allOrderIds[offset + i]];
        }
    }

    /**
     * @notice Get order details
     * @param orderId Order ID
     * @return Order details
     */
    function getOrder(uint256 orderId) external view returns (Order memory) {
        return orders[orderId];
    }

    /**
     * @notice Set minimum interval between swaps
     * @param newMinimumInterval New minimum interval in seconds
     */
    function setMinimumInterval(uint256 newMinimumInterval) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 oldInterval = minimumInterval;
        minimumInterval = newMinimumInterval;
        emit MinimumIntervalUpdated(oldInterval, newMinimumInterval);
    }

    /**
     * @notice Set protocol fee in basis points
     * @param newFeeBps New fee in basis points (max 1000 = 10%)
     */
    function setProtocolFee(uint256 newFeeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
        uint256 oldFeeBps = protocolFeeBps;
        protocolFeeBps = newFeeBps;
        emit ProtocolFeeUpdated(oldFeeBps, newFeeBps);
    }

    /**
     * @notice Set fee recipient address
     * @param newFeeRecipient New fee recipient address
     */
    function setFeeRecipient(address newFeeRecipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newFeeRecipient == address(0)) revert InvalidFeeRecipient();
        address oldRecipient = feeRecipient;
        feeRecipient = newFeeRecipient;
        emit FeeRecipientUpdated(oldRecipient, newFeeRecipient);
    }

    /**
     * @notice Set maximum number of swaps per order
     * @param newMaxSwaps New maximum number of swaps (must be >= 2)
     */
    function setMaxSwaps(uint256 newMaxSwaps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newMaxSwaps < 2) revert InvalidAmounts();
        uint256 oldMaxSwaps = maxSwaps;
        maxSwaps = newMaxSwaps;
        emit MaxSwapsUpdated(oldMaxSwaps, newMaxSwaps);
    }

    /**
     * @notice Emergency function to recover stuck tokens (only non-custodial funds)
     * @param token Token address to recover
     * @param amount Amount to recover
     * @param recipient Address to send recovered tokens to
     */
    function emergencyRecover(address token, uint256 amount, address recipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (recipient == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmounts();

        _transfer(token, recipient, amount);
    }

    /**
     * @notice Allow the contract to receive ETH
     */
    receive() external payable {}

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[50] private __gap;
}

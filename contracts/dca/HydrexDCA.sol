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

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/**
 * @title HydrexDCA
 * @notice Dollar Cost Averaging (DCA) protocol for automated token swaps
 * @dev Custodial protocol that holds user funds and executes DCA orders
 */
contract HydrexDCA is AccessControl, ReentrancyGuard {
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
    uint256 public minimumInterval = 1 minutes;

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
        uint256 amountPerSwap;
        uint256 interval;
        uint256 lastExecutionTime;
        uint256 minAmountOut;
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

    /*
     * Constructor
     */

    /**
     * @notice Initialize the HydrexDCA contract
     * @param _admin Address granted `DEFAULT_ADMIN_ROLE`
     * @param _operator Address granted `OPERATOR_ROLE`
     */
    constructor(address _admin, address _operator) {
        if (_admin == address(0) || _operator == address(0)) revert InvalidAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _operator);
    }

    /*
     * User Functions
     */

    /**
     * @notice Create a new DCA order (supports both ERC20 and native ETH)
     * @param tokenIn Input token address (use 0xEeee...eEeE for native ETH)
     * @param tokenOut Output token address
     * @param totalAmount Total amount of input tokens to DCA (ignored for ETH, uses msg.value)
     * @param amountPerSwap Amount to swap per execution
     * @param interval Minimum time between swaps (in seconds)
     * @param minAmountOut Minimum output amount per swap (slippage protection)
     */
    function createOrder(
        address tokenIn,
        address tokenOut,
        uint256 totalAmount,
        uint256 amountPerSwap,
        uint256 interval,
        uint256 minAmountOut
    ) external payable nonReentrant returns (uint256 orderId) {
        if (tokenOut == address(0)) revert InvalidAddress();
        if (amountPerSwap == 0) revert InvalidAmounts();

        bool isETH = tokenIn == 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
        uint256 actualAmount;

        if (isETH) {
            // Native ETH order
            if (msg.value == 0) revert InvalidAmounts();
            if (totalAmount != 0 && totalAmount != msg.value) revert InvalidAmounts();
            if (amountPerSwap > msg.value) revert InvalidAmounts();
            actualAmount = msg.value;
        } else {
            // ERC20 order
            if (tokenIn == address(0)) revert InvalidOrderParameters();
            if (totalAmount == 0) revert InvalidAmounts();
            if (msg.value > 0) revert InvalidOrderParameters();

            // Measure actual amount received (handles tax/reflect tokens)
            uint256 balanceBefore = IERC20(tokenIn).balanceOf(address(this));
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), totalAmount);
            uint256 balanceAfter = IERC20(tokenIn).balanceOf(address(this));
            actualAmount = balanceAfter - balanceBefore;

            // Validate we received something and amountPerSwap is reasonable
            if (actualAmount == 0) revert InvalidAmounts();
            if (amountPerSwap > actualAmount) revert InvalidAmounts();
        }

        // Create order
        orderId = _createOrder(msg.sender, tokenIn, tokenOut, actualAmount, amountPerSwap, interval, minAmountOut);
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
        uint256 amountPerSwap,
        uint256 interval,
        uint256 minAmountOut
    ) internal returns (uint256 orderId) {
        // Validate interval meets minimum
        if (interval < minimumInterval) revert IntervalTooShort();

        orderId = orderCounter++;

        orders[orderId] = Order({
            user: user,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            totalAmount: totalAmount,
            remainingAmount: totalAmount,
            amountPerSwap: amountPerSwap,
            interval: interval,
            lastExecutionTime: 0,
            minAmountOut: minAmountOut,
            status: OrderStatus.Active
        });

        userOrders[user].push(orderId);

        emit OrderCreated(orderId, user, tokenIn, tokenOut, totalAmount, amountPerSwap, interval);
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
        order.lastExecutionTime = block.timestamp;

        // Transfer minimum amount to user
        _transfer(order.tokenOut, order.user, swap.minAmountOut);

        // Calculate and transfer fee
        uint256 feeAmount = returnAmount - swap.minAmountOut;
        address feeDestination = swap.feeRecipient == address(0) ? _msgSender() : swap.feeRecipient;

        if (feeAmount > 0) {
            _transfer(order.tokenOut, feeDestination, feeAmount);
        }

        // Check if order is completed
        if (order.remainingAmount == 0) {
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
     * @notice Get paginated order IDs for a user
     * @param user User address
     * @param offset Starting index
     * @param limit Maximum number of orders to return
     * @return orderIds Array of order IDs
     * @return total Total number of orders for the user
     */
    function getUserOrdersPaginated(
        address user,
        uint256 offset,
        uint256 limit
    ) external view returns (uint256[] memory orderIds, uint256 total) {
        uint256[] storage allOrders = userOrders[user];
        total = allOrders.length;

        if (offset >= total) {
            return (new uint256[](0), total);
        }

        uint256 end = offset + limit;
        if (end > total) {
            end = total;
        }

        uint256 resultLength = end - offset;
        orderIds = new uint256[](resultLength);

        for (uint256 i = 0; i < resultLength; i++) {
            orderIds[i] = allOrders[offset + i];
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
}

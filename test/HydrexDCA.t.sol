// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {HydrexDCA} from "../contracts/dca/HydrexDCA.sol";
import {HydrexDCAProxy} from "../contracts/dca/HydrexDCAProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract ERC20Mock is ERC20 {
    constructor() ERC20("Mock Token", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockRouter {
    bool public shouldFail;
    uint256 public outputAmount;

    function setShouldFail(bool _shouldFail) external {
        shouldFail = _shouldFail;
    }

    function setOutputAmount(uint256 _amount) external {
        outputAmount = _amount;
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 /* minAmountOut */) external payable {
        require(!shouldFail, "Mock swap failed");

        // Handle ETH input
        if (msg.value > 0) {
            require(msg.value == amountIn, "ETH amount mismatch");
        } else {
            // Transfer tokens from sender
            IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        }

        // Send output tokens
        if (tokenOut == 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE) {
            payable(msg.sender).transfer(outputAmount);
        } else {
            IERC20(tokenOut).transfer(msg.sender, outputAmount);
        }
    }

    receive() external payable {}
}

contract HydrexDCATest is Test {
    HydrexDCA public dca;
    ERC20Mock public tokenIn;
    ERC20Mock public tokenOut;
    MockRouter public router;

    address public admin = address(0x1);
    address public operator = address(0x2);
    address public user = address(0x3);
    address public feeRecipient = address(0x4);

    function setUp() public {
        // Deploy implementation
        HydrexDCA implementation = new HydrexDCA();
        
        // Prepare initialization data
        bytes memory initData = abi.encodeWithSelector(
            HydrexDCA.initialize.selector,
            admin,
            operator,
            feeRecipient
        );
        
        // Deploy proxy
        HydrexDCAProxy proxy = new HydrexDCAProxy(
            address(implementation),
            admin,
            initData
        );
        
        // Get proxied instance
        dca = HydrexDCA(payable(address(proxy)));
        
        tokenIn = new ERC20Mock();
        tokenOut = new ERC20Mock();
        router = new MockRouter();

        // Whitelist router
        vm.prank(admin);
        address[] memory routers = new address[](1);
        routers[0] = address(router);
        dca.whitelistRouters(routers);

        // Setup tokens
        tokenIn.mint(user, 1000 ether);
        tokenOut.mint(address(router), 10000 ether);

        // Fund router with ETH
        vm.deal(address(router), 100 ether);
    }

    /*
     * Order Creation Tests
     */

    function test_CreateOrderERC20() public {
        uint256 totalAmount = 100 ether;
        uint256 numberOfSwaps = 10;
        uint256 interval = 1 days;
        uint256 minAmountOut = 9 ether;

        vm.startPrank(user);
        tokenIn.approve(address(dca), totalAmount);

        uint256 orderId = dca.createOrder(
            address(tokenIn),
            address(tokenOut),
            totalAmount,
            numberOfSwaps,
            interval,
            minAmountOut
        );
        vm.stopPrank();

        // Verify order
        HydrexDCA.Order memory order = dca.getOrder(orderId);
        assertEq(order.user, user);
        assertEq(order.tokenIn, address(tokenIn));
        assertEq(order.tokenOut, address(tokenOut));
        assertEq(order.totalAmount, totalAmount);
        assertEq(order.remainingAmount, totalAmount);
        assertEq(order.numberOfSwaps, numberOfSwaps);
        assertEq(order.swapsExecuted, 0);
        assertEq(order.amountPerSwap, 10 ether); // 100 / 10
        assertEq(order.interval, interval);
        assertEq(order.minAmountOut, minAmountOut);
        assertEq(uint256(order.status), uint256(HydrexDCA.OrderStatus.Active));

        // Verify balance transferred
        assertEq(tokenIn.balanceOf(address(dca)), totalAmount);
        assertEq(tokenIn.balanceOf(user), 900 ether);
    }

    function test_CreateOrderETH() public {
        uint256 totalAmount = 1 ether;
        uint256 numberOfSwaps = 10;
        uint256 interval = 1 hours;
        uint256 minAmountOut = 100 ether;

        vm.deal(user, 10 ether);

        vm.prank(user);
        uint256 orderId = dca.createOrder{value: totalAmount}(
            0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE,
            address(tokenOut),
            totalAmount,
            numberOfSwaps,
            interval,
            minAmountOut
        );

        // Verify order
        HydrexDCA.Order memory order = dca.getOrder(orderId);
        assertEq(order.user, user);
        assertEq(order.tokenIn, 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
        assertEq(order.totalAmount, totalAmount);
        assertEq(order.numberOfSwaps, numberOfSwaps);
        assertEq(order.amountPerSwap, 0.1 ether); // 1 / 10
        assertEq(address(dca).balance, totalAmount);
        assertEq(user.balance, 9 ether);
    }

    function test_RevertWhen_CreateOrderETHWithZeroTotalAmount() public {
        uint256 numberOfSwaps = 10;
        uint256 interval = 1 hours;
        uint256 minAmountOut = 100 ether;

        vm.deal(user, 10 ether);

        vm.prank(user);
        vm.expectRevert(HydrexDCA.InvalidAmounts.selector);
        dca.createOrder{value: 1 ether}(
            0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE,
            address(tokenOut),
            0, // totalAmount = 0, should revert
            numberOfSwaps,
            interval,
            minAmountOut
        );
    }

    function test_RevertWhen_CreateOrderWithInvalidAmounts() public {
        vm.startPrank(user);
        tokenIn.approve(address(dca), 100 ether);

        vm.expectRevert(HydrexDCA.InvalidAmounts.selector);
        dca.createOrder(address(tokenIn), address(tokenOut), 0, 10, 1 days, 9 ether);

        vm.expectRevert(HydrexDCA.InvalidAmounts.selector);
        dca.createOrder(address(tokenIn), address(tokenOut), 100 ether, 0, 1 days, 9 ether);

        vm.expectRevert(HydrexDCA.InvalidAmounts.selector);
        dca.createOrder(address(tokenIn), address(tokenOut), 100 ether, 1, 1 days, 9 ether);

        vm.stopPrank();
    }

    function test_RevertWhen_CreateOrderETHWithMismatchedAmount() public {
        vm.deal(user, 10 ether);

        vm.prank(user);
        vm.expectRevert(HydrexDCA.InvalidAmounts.selector);
        dca.createOrder{value: 1 ether}(
            0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE,
            address(tokenOut),
            2 ether, // Mismatch with msg.value
            10,
            1 hours,
            100 ether
        );
    }

    function test_CreateOrderERC20RejectsETH() public {
        vm.startPrank(user);
        tokenIn.approve(address(dca), 100 ether);

        // Should revert with InvalidOrderParameters when sending ETH with ERC20 order
        (bool success, ) = address(dca).call{value: 1 ether}(
            abi.encodeWithSelector(
                HydrexDCA.createOrder.selector,
                address(tokenIn),
                address(tokenOut),
                100 ether,
                10,
                1 days,
                9 ether
            )
        );

        assertFalse(success);

        vm.stopPrank();
    }

    /*
     * Swap Execution Tests
     */

    function test_ExecuteSwap() public {
        // Create order
        uint256 totalAmount = 100 ether;
        uint256 numberOfSwaps = 10;
        uint256 minAmountOut = 9 ether;

        vm.startPrank(user);
        tokenIn.approve(address(dca), totalAmount);
        uint256 orderId = dca.createOrder(
            address(tokenIn),
            address(tokenOut),
            totalAmount,
            numberOfSwaps,
            1 days,
            minAmountOut
        );
        vm.stopPrank();

        uint256 amountPerSwap = 10 ether; // 100 / 10

        // Setup router to return 10 ether
        router.setOutputAmount(10 ether);

        // Prepare swap
        bytes memory swapCalldata = abi.encodeWithSelector(
            MockRouter.swap.selector,
            address(tokenIn),
            address(tokenOut),
            amountPerSwap,
            minAmountOut
        );

        HydrexDCA.SwapData[] memory swaps = new HydrexDCA.SwapData[](1);
        swaps[0] = HydrexDCA.SwapData({
            orderId: orderId,
            amountIn: amountPerSwap,
            minAmountOut: minAmountOut,
            router: address(router),
            routerCalldata: swapCalldata,
            feeRecipient: feeRecipient
        });

        // Execute swap
        vm.prank(operator);
        dca.batchSwap(swaps);

        // Verify order state
        HydrexDCA.Order memory order = dca.getOrder(orderId);
        assertEq(order.remainingAmount, 90 ether);
        assertEq(order.lastExecutionTime, block.timestamp);
        assertEq(uint256(order.status), uint256(HydrexDCA.OrderStatus.Active));

        // Verify balances
        // Router returned 10 ether, protocol fee = 10 * 50 / 10000 = 0.05 ether
        // User gets 9.95 ether, fee recipient gets 0.05 ether
        assertEq(tokenOut.balanceOf(user), 9.95 ether);
        assertEq(tokenOut.balanceOf(feeRecipient), 0.05 ether);
    }

    function test_ExecuteSwapETH() public {
        // Create ETH order
        uint256 totalAmount = 1 ether;
        uint256 numberOfSwaps = 10;
        uint256 minAmountOut = 100 ether;

        vm.deal(user, 10 ether);
        vm.prank(user);
        uint256 orderId = dca.createOrder{value: totalAmount}(
            0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE,
            address(tokenOut),
            totalAmount,
            numberOfSwaps,
            1 hours,
            minAmountOut
        );

        uint256 amountPerSwap = 0.1 ether; // 1 / 10

        // Setup router
        router.setOutputAmount(110 ether);

        bytes memory swapCalldata = abi.encodeWithSelector(
            MockRouter.swap.selector,
            0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE,
            address(tokenOut),
            amountPerSwap,
            minAmountOut
        );

        HydrexDCA.SwapData[] memory swaps = new HydrexDCA.SwapData[](1);
        swaps[0] = HydrexDCA.SwapData({
            orderId: orderId,
            amountIn: amountPerSwap,
            minAmountOut: minAmountOut,
            router: address(router),
            routerCalldata: swapCalldata,
            feeRecipient: feeRecipient
        });

        vm.prank(operator);
        dca.batchSwap(swaps);

        // Verify
        HydrexDCA.Order memory order = dca.getOrder(orderId);
        assertEq(order.remainingAmount, 0.9 ether);
        // Router returned 110 ether, protocol fee = 110 * 50 / 10000 = 0.55 ether
        // User gets 109.45 ether, fee recipient gets 0.55 ether
        assertEq(tokenOut.balanceOf(user), 109.45 ether);
        assertEq(tokenOut.balanceOf(feeRecipient), 0.55 ether);
    }

    function test_ExecuteSwapCompletesOrder() public {
        // Create order with two swaps
        uint256 totalAmount = 10 ether;
        uint256 minAmountOut = 4 ether;
        uint256 amountPerSwap = 5 ether; // 10 / 2

        vm.startPrank(user);
        tokenIn.approve(address(dca), totalAmount);
        uint256 orderId = dca.createOrder(
            address(tokenIn),
            address(tokenOut),
            totalAmount,
            2, // numberOfSwaps
            1 days,
            minAmountOut
        );
        vm.stopPrank();

        router.setOutputAmount(5 ether);

        bytes memory swapCalldata = abi.encodeWithSelector(
            MockRouter.swap.selector,
            address(tokenIn),
            address(tokenOut),
            amountPerSwap,
            minAmountOut
        );

        HydrexDCA.SwapData[] memory swaps = new HydrexDCA.SwapData[](1);
        swaps[0] = HydrexDCA.SwapData({
            orderId: orderId,
            amountIn: amountPerSwap,
            minAmountOut: minAmountOut,
            router: address(router),
            routerCalldata: swapCalldata,
            feeRecipient: feeRecipient
        });

        // Execute first swap
        vm.prank(operator);
        dca.batchSwap(swaps);

        HydrexDCA.Order memory order = dca.getOrder(orderId);
        assertEq(order.remainingAmount, 5 ether);
        assertEq(order.swapsExecuted, 1);
        assertEq(uint256(order.status), uint256(HydrexDCA.OrderStatus.Active));

        // Warp time and execute second swap
        vm.warp(block.timestamp + 1 days);
        vm.prank(operator);
        dca.batchSwap(swaps);

        // Verify order completed
        order = dca.getOrder(orderId);
        assertEq(order.remainingAmount, 0);
        assertEq(order.swapsExecuted, 2);
        assertEq(uint256(order.status), uint256(HydrexDCA.OrderStatus.Completed));
    }

    function test_RevertWhen_SwapBeforeInterval() public {
        // Create order
        vm.startPrank(user);
        tokenIn.approve(address(dca), 100 ether);
        uint256 orderId = dca.createOrder(address(tokenIn), address(tokenOut), 100 ether, 10, 1 days, 9 ether);
        vm.stopPrank();

        router.setOutputAmount(10 ether);

        bytes memory swapCalldata = abi.encodeWithSelector(
            MockRouter.swap.selector,
            address(tokenIn),
            address(tokenOut),
            10 ether,
            9 ether
        );

        HydrexDCA.SwapData[] memory swaps = new HydrexDCA.SwapData[](1);
        swaps[0] = HydrexDCA.SwapData({
            orderId: orderId,
            amountIn: 10 ether,
            minAmountOut: 9 ether,
            router: address(router),
            routerCalldata: swapCalldata,
            feeRecipient: feeRecipient
        });

        // First swap succeeds
        vm.prank(operator);
        dca.batchSwap(swaps);

        // Second swap immediately fails (emits event, doesn't revert)
        vm.prank(operator);
        vm.expectEmit(true, true, false, true);
        emit HydrexDCA.DCASwapFailed(orderId, user, "Interval not met");
        dca.batchSwap(swaps);

        // Warp time forward
        vm.warp(block.timestamp + 1 days);

        // Now it succeeds
        vm.prank(operator);
        dca.batchSwap(swaps);
    }

    function test_SwapFailsGracefully() public {
        // Create order
        vm.startPrank(user);
        tokenIn.approve(address(dca), 100 ether);
        uint256 orderId = dca.createOrder(address(tokenIn), address(tokenOut), 100 ether, 10, 1 days, 9 ether);
        vm.stopPrank();

        // Make router fail
        router.setShouldFail(true);

        bytes memory swapCalldata = abi.encodeWithSelector(
            MockRouter.swap.selector,
            address(tokenIn),
            address(tokenOut),
            10 ether,
            9 ether
        );

        HydrexDCA.SwapData[] memory swaps = new HydrexDCA.SwapData[](1);
        swaps[0] = HydrexDCA.SwapData({
            orderId: orderId,
            amountIn: 10 ether,
            minAmountOut: 9 ether,
            router: address(router),
            routerCalldata: swapCalldata,
            feeRecipient: feeRecipient
        });

        // Swap fails but doesn't revert
        vm.prank(operator);
        vm.expectEmit(true, true, false, false);
        emit HydrexDCA.DCASwapFailed(orderId, user, "");
        dca.batchSwap(swaps);

        // Order state unchanged
        HydrexDCA.Order memory order = dca.getOrder(orderId);
        assertEq(order.remainingAmount, 100 ether);
        assertEq(order.lastExecutionTime, 0);
    }

    /*
     * Cancellation Tests
     */

    function test_CancelOrder() public {
        // Create order
        vm.startPrank(user);
        tokenIn.approve(address(dca), 100 ether);
        uint256 orderId = dca.createOrder(address(tokenIn), address(tokenOut), 100 ether, 10, 1 days, 9 ether);
        vm.stopPrank();

        uint256 userBalanceBefore = tokenIn.balanceOf(user);

        // Cancel order
        vm.prank(user);
        dca.cancelOrder(orderId);

        // Verify order cancelled
        HydrexDCA.Order memory order = dca.getOrder(orderId);
        assertEq(order.remainingAmount, 0);
        assertEq(uint256(order.status), uint256(HydrexDCA.OrderStatus.Cancelled));

        // Verify refund
        assertEq(tokenIn.balanceOf(user), userBalanceBefore + 100 ether);
        assertEq(tokenIn.balanceOf(address(dca)), 0);
    }

    function test_CancelOrderETH() public {
        // Create ETH order
        vm.deal(user, 10 ether);
        vm.prank(user);
        uint256 orderId = dca.createOrder{value: 1 ether}(
            0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE,
            address(tokenOut),
            1 ether,
            10, // numberOfSwaps
            1 hours,
            100 ether
        );

        uint256 userBalanceBefore = user.balance;

        // Cancel
        vm.prank(user);
        dca.cancelOrder(orderId);

        // Verify refund
        assertEq(user.balance, userBalanceBefore + 1 ether);
        assertEq(address(dca).balance, 0);
    }

    function test_CancelPartiallyExecutedOrder() public {
        // Create and execute one swap
        vm.startPrank(user);
        tokenIn.approve(address(dca), 100 ether);
        uint256 orderId = dca.createOrder(address(tokenIn), address(tokenOut), 100 ether, 10, 1 days, 9 ether);
        vm.stopPrank();

        router.setOutputAmount(10 ether);

        bytes memory swapCalldata = abi.encodeWithSelector(
            MockRouter.swap.selector,
            address(tokenIn),
            address(tokenOut),
            10 ether,
            9 ether
        );

        HydrexDCA.SwapData[] memory swaps = new HydrexDCA.SwapData[](1);
        swaps[0] = HydrexDCA.SwapData({
            orderId: orderId,
            amountIn: 10 ether,
            minAmountOut: 9 ether,
            router: address(router),
            routerCalldata: swapCalldata,
            feeRecipient: feeRecipient
        });

        vm.prank(operator);
        dca.batchSwap(swaps);

        // Cancel remaining
        uint256 userBalanceBefore = tokenIn.balanceOf(user);

        vm.prank(user);
        dca.cancelOrder(orderId);

        // Verify refund of remaining 90 ether
        assertEq(tokenIn.balanceOf(user), userBalanceBefore + 90 ether);
    }

    function test_RevertWhen_UnauthorizedCancellation() public {
        vm.startPrank(user);
        tokenIn.approve(address(dca), 100 ether);
        uint256 orderId = dca.createOrder(address(tokenIn), address(tokenOut), 100 ether, 10, 1 days, 9 ether);
        vm.stopPrank();

        vm.prank(address(0x999));
        vm.expectRevert(HydrexDCA.UnauthorizedCancellation.selector);
        dca.cancelOrder(orderId);
    }

    function test_RevertWhen_CancelNonActiveOrder() public {
        vm.startPrank(user);
        tokenIn.approve(address(dca), 100 ether);
        uint256 orderId = dca.createOrder(address(tokenIn), address(tokenOut), 100 ether, 10, 1 days, 9 ether);
        dca.cancelOrder(orderId);

        vm.expectRevert(HydrexDCA.OrderNotActive.selector);
        dca.cancelOrder(orderId);
        vm.stopPrank();
    }

    /*
     * View Function Tests
     */

    function test_GetUserOrders() public {
        vm.startPrank(user);
        tokenIn.approve(address(dca), 300 ether);

        uint256 orderId1 = dca.createOrder(address(tokenIn), address(tokenOut), 100 ether, 10, 1 days, 9 ether);
        uint256 orderId2 = dca.createOrder(address(tokenIn), address(tokenOut), 100 ether, 10, 1 days, 9 ether);
        uint256 orderId3 = dca.createOrder(address(tokenIn), address(tokenOut), 100 ether, 10, 1 days, 9 ether);
        vm.stopPrank();

        uint256[] memory userOrders = dca.getUserOrders(user);
        assertEq(userOrders.length, 3);
        assertEq(userOrders[0], orderId1);
        assertEq(userOrders[1], orderId2);
        assertEq(userOrders[2], orderId3);
    }

    /*
     * Admin Tests
     */

    function test_WhitelistRouter() public {
        address newRouter = address(0x999);

        vm.prank(admin);
        address[] memory routers = new address[](1);
        routers[0] = newRouter;
        dca.whitelistRouters(routers);

        assertTrue(dca.whitelistedRouters(newRouter));
    }

    function test_RemoveRouter() public {
        vm.prank(admin);
        address[] memory routers = new address[](1);
        routers[0] = address(router);
        dca.removeRouters(routers);

        assertFalse(dca.whitelistedRouters(address(router)));
    }

    function test_EmergencyRecover() public {
        // Send some tokens to contract
        tokenIn.mint(address(dca), 100 ether);

        vm.prank(admin);
        dca.emergencyRecover(address(tokenIn), 100 ether, admin);

        assertEq(tokenIn.balanceOf(admin), 100 ether);
        assertEq(tokenIn.balanceOf(address(dca)), 0);
    }
}

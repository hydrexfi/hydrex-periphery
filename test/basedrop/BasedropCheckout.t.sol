// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {BasedropCheckout} from "../../contracts/basedrop/BasedropCheckout.sol";
import {Hydropoints} from "../../contracts/basedrop/Hydropoints.sol";
import {IHydrexVotingEscrow} from "../../contracts/interfaces/IHydrexVotingEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Mock contracts for testing
contract MockHydrexToken is ERC20 {
    constructor() ERC20("Hydrex Token", "HYDX") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {
        // USDC has 6 decimals
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockVotingEscrow {
    struct Lock {
        address user;
        uint256 amount;
        uint256 duration;
        uint8 lockType;
    }

    mapping(address => Lock[]) public userLocks;
    mapping(address => uint256) public balanceRequired;

    function setRequiredBalance(address token, uint256 amount) external {
        balanceRequired[token] = amount;
    }

    function createLockFor(uint256 _value, uint256 _lockDuration, address _to, uint8 _lockType) external {
        // Simulate requiring HYDX tokens from the caller (BasedropCheckout contract)
        address hydrexToken = address(0x123); // This would be set properly in tests
        if (balanceRequired[hydrexToken] > 0) {
            require(IERC20(hydrexToken).balanceOf(msg.sender) >= _value, "Insufficient HYDX balance");
            // In a real implementation, this would transfer tokens from the caller
        }
        
        userLocks[_to].push(Lock({
            user: _to,
            amount: _value,
            duration: _lockDuration,
            lockType: _lockType
        }));
    }

    function getUserLocks(address user) external view returns (Lock[] memory) {
        return userLocks[user];
    }

    function getLastLock(address user) external view returns (Lock memory) {
        require(userLocks[user].length > 0, "No locks found");
        return userLocks[user][userLocks[user].length - 1];
    }
}

contract BasedropCheckoutTest is Test {
    BasedropCheckout public checkout;
    Hydropoints public hydropoints;
    MockHydrexToken public hydrexToken;
    MockUSDC public usdcToken;
    MockVotingEscrow public votingEscrow;

    address public owner;
    address public admin;
    address public user1;
    address public user2;

    // Test constants
    uint256 public constant HYDROPOINTS_AMOUNT = 1000 * 10**18;
    uint256 public constant HYDX_AMOUNT = 100 * 10**18; // 10:1 ratio
    uint256 public constant USDC_AMOUNT = 1000000; // 1 USDC in 6 decimals (1000 hydropoints = 1 USDC)

    function setUp() public {
        // Create addresses
        owner = makeAddr("owner");
        admin = makeAddr("admin");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        // Deploy mock contracts
        hydrexToken = new MockHydrexToken();
        usdcToken = new MockUSDC();
        votingEscrow = new MockVotingEscrow();

        // Deploy Hydropoints with owner as admin
        vm.prank(owner);
        hydropoints = new Hydropoints(owner);

        // Deploy BasedropCheckout
        checkout = new BasedropCheckout(
            address(hydrexToken),
            address(hydropoints),
            address(usdcToken),
            address(votingEscrow),
            admin
        );

        // Setup roles
        vm.startPrank(owner);
        hydropoints.grantRole(hydropoints.MINTER_ROLE(), owner);
        hydropoints.grantRole(hydropoints.REDEEMER_ROLE(), address(checkout));
        vm.stopPrank();

        // Fund checkout contract with HYDX tokens for lock creation
        hydrexToken.mint(address(checkout), 1000000 * 10**18);
    }

    /* Constructor tests */
    
    function testConstructor() public view {
        assertEq(address(checkout.hydrexToken()), address(hydrexToken));
        assertEq(address(checkout.hydropointsToken()), address(hydropoints));
        assertEq(address(checkout.usdc()), address(usdcToken));
        assertEq(address(checkout.votingEscrow()), address(votingEscrow));
        assertTrue(checkout.hasRole(checkout.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_RevertWhen_ConstructorWithZeroAddresses() public {
        vm.expectRevert("Invalid HYDX token address");
        new BasedropCheckout(address(0), address(hydropoints), address(usdcToken), address(votingEscrow), admin);

        vm.expectRevert("Invalid hydropoints token address");
        new BasedropCheckout(address(hydrexToken), address(0), address(usdcToken), address(votingEscrow), admin);

        vm.expectRevert("Invalid USDC token address");
        new BasedropCheckout(address(hydrexToken), address(hydropoints), address(0), address(votingEscrow), admin);

        vm.expectRevert("Invalid voting escrow address");
        new BasedropCheckout(address(hydrexToken), address(hydropoints), address(usdcToken), address(0), admin);

        vm.expectRevert("Invalid admin address");
        new BasedropCheckout(address(hydrexToken), address(hydropoints), address(usdcToken), address(votingEscrow), address(0));
    }

    /* View function tests */

    function testCalculateHydrexEquivalent() public view {
        assertEq(checkout.calculateHydrexEquivalent(1000 * 10**18), 100 * 10**18);
        assertEq(checkout.calculateHydrexEquivalent(100 * 10**18), 10 * 10**18);
        assertEq(checkout.calculateHydrexEquivalent(9 * 10**18), 9 * 10**17); // 9/10 = 0.9
        assertEq(checkout.calculateHydrexEquivalent(0), 0);
    }

    function testCalculateUsdcRequired() public view {
        // With USDC_CONVERSION_RATE = 10000, 10 hydropoints = 0.01 USDC
        assertEq(checkout.calculateUsdcRequired(10 * 10**18), 10000); // 0.01 USDC in 6 decimals
        assertEq(checkout.calculateUsdcRequired(100 * 10**18), 100000); // 0.1 USDC
        assertEq(checkout.calculateUsdcRequired(1000 * 10**18), 1000000); // 1 USDC
        assertEq(checkout.calculateUsdcRequired(0), 0);
    }

    /* Permanent lock tests */

    function testRedeemHydropointsPermalock() public {
        // Setup: mint hydropoints to user
        vm.prank(owner);
        hydropoints.mint(user1, HYDROPOINTS_AMOUNT);

        // Test permanent lock redemption
        vm.prank(user1);
        checkout.redeemHydropoints(HYDROPOINTS_AMOUNT, true);

        // Verify hydropoints were burned
        assertEq(hydropoints.balanceOf(user1), 0);

        // Verify lock was created with correct parameters
        MockVotingEscrow.Lock memory lock = votingEscrow.getLastLock(user1);
        assertEq(lock.user, user1);
        assertEq(lock.amount, HYDX_AMOUNT);
        assertEq(lock.duration, 0); // Permanent lock
        assertEq(lock.lockType, 2); // LOCK_TYPE_PERMANENT
    }

    function testRedeemHydropointsPermalockEmitsEvent() public {
        vm.prank(owner);
        hydropoints.mint(user1, HYDROPOINTS_AMOUNT);

        vm.expectEmit(true, false, false, true);
        emit BasedropCheckout.HydropointsRedeemed(user1, HYDROPOINTS_AMOUNT, HYDX_AMOUNT, true);

        vm.prank(user1);
        checkout.redeemHydropoints(HYDROPOINTS_AMOUNT, true);
    }

    /* Temporary lock tests */

    function testRedeemHydropointsTemporaryLock() public {
        // Setup: mint hydropoints and USDC to user
        vm.prank(owner);
        hydropoints.mint(user1, HYDROPOINTS_AMOUNT);
        usdcToken.mint(user1, USDC_AMOUNT);

        // User approves checkout to spend USDC
        vm.prank(user1);
        usdcToken.approve(address(checkout), USDC_AMOUNT);

        // Test temporary lock redemption
        vm.prank(user1);
        checkout.redeemHydropoints(HYDROPOINTS_AMOUNT, false);

        // Verify hydropoints were burned
        assertEq(hydropoints.balanceOf(user1), 0);
        
        // Verify USDC was transferred to checkout contract
        assertEq(usdcToken.balanceOf(user1), 0);
        assertEq(usdcToken.balanceOf(address(checkout)), USDC_AMOUNT);

        // Verify lock was created with correct parameters
        MockVotingEscrow.Lock memory lock = votingEscrow.getLastLock(user1);
        assertEq(lock.user, user1);
        assertEq(lock.amount, HYDX_AMOUNT);
        assertEq(lock.duration, 0);
        assertEq(lock.lockType, 1); // LOCK_TYPE_TEMPORARY
    }

    function testRedeemHydropointsTemporaryLockEmitsEvent() public {
        vm.prank(owner);
        hydropoints.mint(user1, HYDROPOINTS_AMOUNT);
        usdcToken.mint(user1, USDC_AMOUNT);

        vm.prank(user1);
        usdcToken.approve(address(checkout), USDC_AMOUNT);

        vm.expectEmit(true, false, false, true);
        emit BasedropCheckout.HydropointsRedeemed(user1, HYDROPOINTS_AMOUNT, HYDX_AMOUNT, false);

        vm.prank(user1);
        checkout.redeemHydropoints(HYDROPOINTS_AMOUNT, false);
    }

    /* Edge cases and revert tests */

    function test_RevertWhen_RedeemZeroAmount() public {
        vm.prank(user1);
        vm.expectRevert("Amount must be greater than 0");
        checkout.redeemHydropoints(0, true);
    }

    function test_RevertWhen_InsufficientHydropointsForMinimumLock() public {
        // 9 hydropoints = 0 HYDX (due to integer division)
        vm.prank(owner);
        hydropoints.mint(user1, 9);

        vm.prank(user1);
        vm.expectRevert("Insufficient hydropoints for minimum lock");
        checkout.redeemHydropoints(9, true);
    }

    function test_RevertWhen_InsufficientUsdcApproval() public {
        vm.prank(owner);
        hydropoints.mint(user1, HYDROPOINTS_AMOUNT);
        usdcToken.mint(user1, USDC_AMOUNT);

        // Don't approve USDC spending
        vm.prank(user1);
        vm.expectRevert();
        checkout.redeemHydropoints(HYDROPOINTS_AMOUNT, false);
    }

    function test_RevertWhen_InsufficientUsdcBalance() public {
        vm.prank(owner);
        hydropoints.mint(user1, HYDROPOINTS_AMOUNT);
        // Don't mint USDC to user

        vm.prank(user1);
        usdcToken.approve(address(checkout), USDC_AMOUNT);

        vm.prank(user1);
        vm.expectRevert();
        checkout.redeemHydropoints(HYDROPOINTS_AMOUNT, false);
    }

    function test_RevertWhen_InsufficientHydropoints() public {
        // User doesn't have any hydropoints
        vm.prank(user1);
        vm.expectRevert();
        checkout.redeemHydropoints(HYDROPOINTS_AMOUNT, true);
    }

    /* Admin function tests */

    function testWithdrawTokens() public {
        // Fund contract with some tokens
        usdcToken.mint(address(checkout), USDC_AMOUNT);

        uint256 initialBalance = usdcToken.balanceOf(admin);

        vm.prank(admin);
        checkout.withdrawTokens(address(usdcToken), admin, USDC_AMOUNT);

        assertEq(usdcToken.balanceOf(address(checkout)), 0);
        assertEq(usdcToken.balanceOf(admin), initialBalance + USDC_AMOUNT);
    }

    function test_RevertWhen_NonAdminWithdraws() public {
        usdcToken.mint(address(checkout), USDC_AMOUNT);

        vm.prank(user1);
        vm.expectRevert();
        checkout.withdrawTokens(address(usdcToken), user1, USDC_AMOUNT);
    }

    function test_RevertWhen_WithdrawInvalidToken() public {
        vm.prank(admin);
        vm.expectRevert("Invalid token address");
        checkout.withdrawTokens(address(0), admin, 100);
    }

    function test_RevertWhen_WithdrawInvalidRecipient() public {
        vm.prank(admin);
        vm.expectRevert("Invalid recipient address");
        checkout.withdrawTokens(address(usdcToken), address(0), 100);
    }

    function test_RevertWhen_WithdrawZeroAmount() public {
        vm.prank(admin);
        vm.expectRevert("Amount must be greater than 0");
        checkout.withdrawTokens(address(usdcToken), admin, 0);
    }

    function test_RevertWhen_WithdrawExceedsBalance() public {
        vm.prank(admin);
        vm.expectRevert("Insufficient balance");
        checkout.withdrawTokens(address(usdcToken), admin, 100);
    }

    /* Integration tests */

    function testMultipleUsersRedemption() public {
        // Setup both users with hydropoints
        vm.startPrank(owner);
        hydropoints.mint(user1, HYDROPOINTS_AMOUNT);
        hydropoints.mint(user2, HYDROPOINTS_AMOUNT * 2);
        vm.stopPrank();

        // User1 creates permanent lock
        vm.prank(user1);
        checkout.redeemHydropoints(HYDROPOINTS_AMOUNT, true);

        // User2 creates temporary lock with USDC
        usdcToken.mint(user2, USDC_AMOUNT * 2);
        vm.prank(user2);
        usdcToken.approve(address(checkout), USDC_AMOUNT * 2);
        vm.prank(user2);
        checkout.redeemHydropoints(HYDROPOINTS_AMOUNT * 2, false);

        // Verify individual locks
        MockVotingEscrow.Lock memory lock1 = votingEscrow.getLastLock(user1);
        assertEq(lock1.lockType, 2); // Permanent

        MockVotingEscrow.Lock memory lock2 = votingEscrow.getLastLock(user2);
        assertEq(lock2.lockType, 1); // Temporary
        assertEq(lock2.amount, HYDX_AMOUNT * 2);
    }

    function testFuzzRedemption(uint256 hydropointsAmount) public {
        // Bound to reasonable range and ensure minimum conversion
        hydropointsAmount = bound(hydropointsAmount, 10 * 10**18, 10000 * 10**18);
        
        vm.prank(owner);
        hydropoints.mint(user1, hydropointsAmount);

        uint256 expectedHydx = checkout.calculateHydrexEquivalent(hydropointsAmount);
        vm.assume(expectedHydx > 0); // Skip if would result in 0 HYDX

        vm.prank(user1);
        checkout.redeemHydropoints(hydropointsAmount, true);

        MockVotingEscrow.Lock memory lock = votingEscrow.getLastLock(user1);
        assertEq(lock.amount, expectedHydx);
    }

    /* Badge allocation tests */

    function testSetBadgeAllocation() public {
        uint256 allocation = 50 * 10**18; // 50 HYDX
        
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        users[0] = user1;
        amounts[0] = allocation;
        
        vm.prank(admin);
        checkout.setBadgeAllocations(users, amounts);
        
        assertEq(checkout.getBadgeAllocation(user1), allocation);
        assertEq(checkout.veHydxFromBadges(user1), allocation);
        assertFalse(checkout.hasClaimed(user1));
        assertTrue(checkout.canClaim(user1));
    }

    function testSetBadgeAllocationsMultiple() public {
        address[] memory users = new address[](3);
        uint256[] memory amounts = new uint256[](3);
        
        users[0] = user1;
        users[1] = user2;
        users[2] = makeAddr("user3");
        
        amounts[0] = 50 * 10**18;
        amounts[1] = 100 * 10**18;
        amounts[2] = 25 * 10**18;
        
        vm.prank(admin);
        checkout.setBadgeAllocations(users, amounts);
        
        assertEq(checkout.getBadgeAllocation(user1), 50 * 10**18);
        assertEq(checkout.getBadgeAllocation(user2), 100 * 10**18);
        assertEq(checkout.getBadgeAllocation(makeAddr("user3")), 25 * 10**18);
    }

    function test_RevertWhen_SetBadgeAllocationsArrayMismatch() public {
        address[] memory users = new address[](2);
        uint256[] memory amounts = new uint256[](1);
        
        users[0] = user1;
        users[1] = user2;
        amounts[0] = 50 * 10**18;
        
        vm.prank(admin);
        vm.expectRevert("Arrays length mismatch");
        checkout.setBadgeAllocations(users, amounts);
    }

    function test_RevertWhen_SetBadgeAllocationsInvalidAddress() public {
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        
        users[0] = address(0);
        amounts[0] = 50 * 10**18;
        
        vm.prank(admin);
        vm.expectRevert("Invalid user address");
        checkout.setBadgeAllocations(users, amounts);
    }

    function test_RevertWhen_NonAdminSetsBadgeAllocations() public {
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        users[0] = user1;
        amounts[0] = 50 * 10**18;
        
        vm.prank(user1);
        vm.expectRevert();
        checkout.setBadgeAllocations(users, amounts);
    }

    function testClaimBadgeAllocation() public {
        uint256 allocation = 75 * 10**18; // 75 HYDX
        
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        users[0] = user1;
        amounts[0] = allocation;
        
        // Set allocation
        vm.prank(admin);
        checkout.setBadgeAllocations(users, amounts);
        
        // Claim allocation
        vm.prank(user1);
        checkout.claimBadgeAllocation();
        
        // Verify allocation is marked as claimed
        assertTrue(checkout.hasClaimed(user1));
        assertFalse(checkout.canClaim(user1));
        
        // Verify lock was created
        MockVotingEscrow.Lock memory lock = votingEscrow.getLastLock(user1);
        assertEq(lock.user, user1);
        assertEq(lock.amount, allocation);
        assertEq(lock.duration, 0); // Permanent lock
        assertEq(lock.lockType, 2); // LOCK_TYPE_PERMANENT
    }

    function testClaimBadgeAllocationEmitsEvent() public {
        uint256 allocation = 75 * 10**18;
        
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        users[0] = user1;
        amounts[0] = allocation;
        
        vm.prank(admin);
        checkout.setBadgeAllocations(users, amounts);
        
        vm.expectEmit(true, false, false, true);
        emit BasedropCheckout.BadgeAllocationClaimed(user1, allocation);
        
        vm.prank(user1);
        checkout.claimBadgeAllocation();
    }

    function test_RevertWhen_ClaimWithNoAllocation() public {
        vm.prank(user1);
        vm.expectRevert("No badge allocation available");
        checkout.claimBadgeAllocation();
    }

    function test_RevertWhen_ClaimAlreadyClaimed() public {
        uint256 allocation = 50 * 10**18;
        
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        users[0] = user1;
        amounts[0] = allocation;
        
        // Set and claim allocation
        vm.prank(admin);
        checkout.setBadgeAllocations(users, amounts);
        
        vm.prank(user1);
        checkout.claimBadgeAllocation();
        
        // Try to claim again
        vm.prank(user1);
        vm.expectRevert("Badge allocation already claimed");
        checkout.claimBadgeAllocation();
    }

    function testGetBadgeAllocationZero() public view {
        assertEq(checkout.getBadgeAllocation(user1), 0);
        assertFalse(checkout.hasClaimed(user1));
        assertFalse(checkout.canClaim(user1));
    }

    function testCanClaimLogic() public {
        uint256 allocation = 30 * 10**18;
        
        // Initially can't claim (no allocation)
        assertFalse(checkout.canClaim(user1));
        
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        users[0] = user1;
        amounts[0] = allocation;
        
        // Set allocation - now can claim
        vm.prank(admin);
        checkout.setBadgeAllocations(users, amounts);
        assertTrue(checkout.canClaim(user1));
        
        // Claim - now can't claim again
        vm.prank(user1);
        checkout.claimBadgeAllocation();
        assertFalse(checkout.canClaim(user1));
    }

    function testMultipleUsersBadgeAllocations() public {
        uint256 allocation1 = 40 * 10**18;
        uint256 allocation2 = 60 * 10**18;
        
        // Set allocations for both users
        address[] memory users = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        users[0] = user1;
        users[1] = user2;
        amounts[0] = allocation1;
        amounts[1] = allocation2;
        
        vm.prank(admin);
        checkout.setBadgeAllocations(users, amounts);
        
        // User1 claims
        vm.prank(user1);
        checkout.claimBadgeAllocation();
        
        // Verify user1 claimed but user2 hasn't
        assertTrue(checkout.hasClaimed(user1));
        assertFalse(checkout.hasClaimed(user2));
        assertTrue(checkout.canClaim(user2));
        
        // User2 claims
        vm.prank(user2);
        checkout.claimBadgeAllocation();
        
        // Verify both claimed
        assertTrue(checkout.hasClaimed(user1));
        assertTrue(checkout.hasClaimed(user2));
        assertFalse(checkout.canClaim(user1));
        assertFalse(checkout.canClaim(user2));
        
        // Verify locks
        MockVotingEscrow.Lock memory lock1 = votingEscrow.getLastLock(user1);
        MockVotingEscrow.Lock memory lock2 = votingEscrow.getLastLock(user2);
        
        assertEq(lock1.amount, allocation1);
        assertEq(lock2.amount, allocation2);
        assertEq(lock1.lockType, 2); // Both permanent
        assertEq(lock2.lockType, 2);
    }

    function testUpdateBadgeAllocation() public {
        uint256 originalAllocation = 50 * 10**18;
        uint256 updatedAllocation = 80 * 10**18;
        
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        users[0] = user1;
        amounts[0] = originalAllocation;
        
        // Set initial allocation
        vm.prank(admin);
        checkout.setBadgeAllocations(users, amounts);
        assertEq(checkout.getBadgeAllocation(user1), originalAllocation);
        
        // Update allocation (before claim)
        amounts[0] = updatedAllocation;
        vm.prank(admin);
        checkout.setBadgeAllocations(users, amounts);
        assertEq(checkout.getBadgeAllocation(user1), updatedAllocation);
        
        // Claim updated amount
        vm.prank(user1);
        checkout.claimBadgeAllocation();
        
        MockVotingEscrow.Lock memory lock = votingEscrow.getLastLock(user1);
        assertEq(lock.amount, updatedAllocation);
    }
}

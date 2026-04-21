// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SendReferralClaims} from "../contracts/send/SendReferralClaims.sol";

// ---------------------------------------------------------------------------
// Mock ERC20 (USDC-shaped, 6 decimals) + a generic 18-dec token for recovery tests
// ---------------------------------------------------------------------------

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract MockToken18 is ERC20 {
    constructor() ERC20("Mock", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// ---------------------------------------------------------------------------
// Test contract
// ---------------------------------------------------------------------------

contract SendReferralClaimsTest is Test {
    SendReferralClaims internal claims;

    // Must match the hardcoded constant in SendReferralClaims
    address internal constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    MockUSDC internal usdc;
    MockToken18 internal randomToken;

    address internal admin;
    address internal operator;
    address internal alice;
    address internal bob;
    address internal carol;
    address internal stranger;

    bytes32 internal ADMIN_ROLE;
    bytes32 internal OPERATOR_ROLE;

    uint256 internal constant ONE = 1e6; // USDC has 6 decimals

    function setUp() public {
        admin = address(this);
        operator = makeAddr("operator");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
        stranger = makeAddr("stranger");

        // Deploy a MockUSDC implementation, then etch its runtime code at the
        // Base mainnet USDC address so `usdc` inside the contract works.
        MockUSDC impl = new MockUSDC();
        vm.etch(BASE_USDC, address(impl).code);
        usdc = MockUSDC(BASE_USDC);

        claims = new SendReferralClaims(admin);
        ADMIN_ROLE = claims.DEFAULT_ADMIN_ROLE();
        OPERATOR_ROLE = claims.OPERATOR_ROLE();
        claims.grantRole(OPERATOR_ROLE, operator);

        // Pre-fund the claims contract so USDC transfers don't revert.
        usdc.mint(address(claims), 10_000_000 * ONE);

        randomToken = new MockToken18();
    }

    // =========================================================================
    // Initial state
    // =========================================================================

    function test_InitialState() public view {
        assertTrue(claims.hasRole(claims.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(claims.hasRole(claims.OPERATOR_ROLE(), admin));
        assertTrue(claims.hasRole(claims.OPERATOR_ROLE(), operator));
        assertEq(address(claims.usdc()), BASE_USDC);
        assertEq(claims.pendingClaimAmount(alice), 0);
        assertEq(claims.totalAllocated(alice), 0);
        assertEq(claims.totalClaimed(alice), 0);
    }

    function test_RevertWhen_Constructor_ZeroAdmin() public {
        vm.expectRevert(SendReferralClaims.ZeroAddress.selector);
        new SendReferralClaims(address(0));
    }

    // =========================================================================
    // setAllocation — cumulative semantics
    // =========================================================================

    function test_SetAllocation_FirstPush() public {
        vm.expectEmit(true, false, false, true);
        emit SendReferralClaims.AllocationUpdated(alice, 100 * ONE, 100 * ONE);

        vm.prank(operator);
        claims.setAllocation(alice, 100 * ONE);

        assertEq(claims.totalAllocated(alice), 100 * ONE);
        assertEq(claims.totalClaimed(alice), 0);
        assertEq(claims.pendingClaimAmount(alice), 100 * ONE);
    }

    function test_SetAllocation_CumulativeIncrement() public {
        vm.startPrank(operator);
        claims.setAllocation(alice, 10 * ONE);
        claims.setAllocation(alice, 100 * ONE); // total, not delta
        vm.stopPrank();

        assertEq(claims.totalAllocated(alice), 100 * ONE);
        assertEq(claims.pendingClaimAmount(alice), 100 * ONE);
    }

    function test_SetAllocation_EmitsDelta() public {
        vm.prank(operator);
        claims.setAllocation(alice, 10 * ONE);

        vm.expectEmit(true, false, false, true);
        emit SendReferralClaims.AllocationUpdated(alice, 90 * ONE, 100 * ONE);

        vm.prank(operator);
        claims.setAllocation(alice, 100 * ONE);
    }

    function test_SetAllocation_EqualIsNoOp() public {
        vm.prank(operator);
        claims.setAllocation(alice, 50 * ONE);

        // Re-pushing the same cumulative value must be silent (no event)
        vm.recordLogs();
        vm.prank(operator);
        claims.setAllocation(alice, 50 * ONE);
        assertEq(vm.getRecordedLogs().length, 0);

        assertEq(claims.totalAllocated(alice), 50 * ONE);
    }

    function test_RevertWhen_SetAllocation_Decrease() public {
        vm.prank(operator);
        claims.setAllocation(alice, 100 * ONE);

        vm.expectRevert(
            abi.encodeWithSelector(SendReferralClaims.AllocationDecrease.selector, alice, 100 * ONE, 99 * ONE)
        );
        vm.prank(operator);
        claims.setAllocation(alice, 99 * ONE);
    }

    function test_RevertWhen_SetAllocation_ZeroRecipient() public {
        vm.expectRevert(SendReferralClaims.ZeroAddress.selector);
        vm.prank(operator);
        claims.setAllocation(address(0), 10 * ONE);
    }

    function test_RevertWhen_SetAllocation_NotOperator() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, OPERATOR_ROLE)
        );
        vm.prank(stranger);
        claims.setAllocation(alice, 10 * ONE);
    }

    // =========================================================================
    // setAllocations — batch
    // =========================================================================

    function test_SetAllocations_Batch() public {
        address[] memory r = new address[](3);
        r[0] = alice;
        r[1] = bob;
        r[2] = carol;

        uint256[] memory a = new uint256[](3);
        a[0] = 10 * ONE;
        a[1] = 20 * ONE;
        a[2] = 30 * ONE;

        vm.prank(operator);
        claims.setAllocations(r, a);

        assertEq(claims.pendingClaimAmount(alice), 10 * ONE);
        assertEq(claims.pendingClaimAmount(bob), 20 * ONE);
        assertEq(claims.pendingClaimAmount(carol), 30 * ONE);
    }

    function test_RevertWhen_SetAllocations_LengthMismatch() public {
        address[] memory r = new address[](2);
        r[0] = alice;
        r[1] = bob;
        uint256[] memory a = new uint256[](1);
        a[0] = 1;

        vm.expectRevert(SendReferralClaims.LengthMismatch.selector);
        vm.prank(operator);
        claims.setAllocations(r, a);
    }

    // =========================================================================
    // claim — the core "delta" flow
    // =========================================================================

    function test_Claim_FullStory_Day1Day2() public {
        // Day 1: operator credits 10 USDC lifetime
        vm.prank(operator);
        claims.setAllocation(alice, 10 * ONE);
        assertEq(claims.pendingClaimAmount(alice), 10 * ONE);

        // Alice claims the 10
        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 got = claims.claim();
        assertEq(got, 10 * ONE);
        assertEq(usdc.balanceOf(alice) - balBefore, 10 * ONE);
        assertEq(claims.pendingClaimAmount(alice), 0);
        assertEq(claims.totalClaimed(alice), 10 * ONE);

        // Day 2: operator pushes cumulative 100
        vm.prank(operator);
        claims.setAllocation(alice, 100 * ONE);

        // Alice is owed only the 90 delta
        assertEq(claims.pendingClaimAmount(alice), 90 * ONE);

        vm.prank(alice);
        got = claims.claim();
        assertEq(got, 90 * ONE);
        assertEq(usdc.balanceOf(alice) - balBefore, 100 * ONE);
        assertEq(claims.totalClaimed(alice), 100 * ONE);
        assertEq(claims.pendingClaimAmount(alice), 0);
    }

    function test_Claim_DoesNotAffectOtherUsers() public {
        vm.startPrank(operator);
        claims.setAllocation(alice, 50 * ONE);
        claims.setAllocation(bob, 75 * ONE);
        vm.stopPrank();

        vm.prank(alice);
        claims.claim();

        assertEq(claims.pendingClaimAmount(bob), 75 * ONE);
    }

    function test_RevertWhen_Claim_NothingOwed() public {
        vm.expectRevert(SendReferralClaims.NothingToClaim.selector);
        vm.prank(alice);
        claims.claim();
    }

    function test_RevertWhen_Claim_Twice() public {
        vm.prank(operator);
        claims.setAllocation(alice, 10 * ONE);

        vm.prank(alice);
        claims.claim();

        vm.expectRevert(SendReferralClaims.NothingToClaim.selector);
        vm.prank(alice);
        claims.claim();
    }

    function test_Claim_EmitsEvent() public {
        vm.prank(operator);
        claims.setAllocation(alice, 42 * ONE);

        vm.expectEmit(true, false, false, true);
        emit SendReferralClaims.Claimed(alice, 42 * ONE);

        vm.prank(alice);
        claims.claim();
    }

    // =========================================================================
    // claimFor / claimForBatch
    // =========================================================================

    function test_ClaimFor_SendsToUserNotCaller() public {
        vm.prank(operator);
        claims.setAllocation(alice, 100 * ONE);

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 opBefore = usdc.balanceOf(operator);

        vm.prank(operator);
        uint256 got = claims.claimFor(alice);

        assertEq(got, 100 * ONE);
        assertEq(usdc.balanceOf(alice) - aliceBefore, 100 * ONE);
        assertEq(usdc.balanceOf(operator), opBefore, "operator must not receive funds");
    }

    function test_RevertWhen_ClaimFor_NotOperator() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, OPERATOR_ROLE)
        );
        vm.prank(stranger);
        claims.claimFor(alice);
    }

    function test_RevertWhen_ClaimFor_ZeroRecipient() public {
        vm.expectRevert(SendReferralClaims.ZeroAddress.selector);
        vm.prank(operator);
        claims.claimFor(address(0));
    }

    function test_ClaimForBatch_SkipsEmpty() public {
        vm.startPrank(operator);
        claims.setAllocation(alice, 10 * ONE);
        // bob has nothing
        claims.setAllocation(carol, 30 * ONE);
        vm.stopPrank();

        address[] memory r = new address[](3);
        r[0] = alice;
        r[1] = bob;
        r[2] = carol;

        vm.prank(operator);
        uint256 total = claims.claimForBatch(r);

        assertEq(total, 40 * ONE);
        assertEq(usdc.balanceOf(alice), 10 * ONE);
        assertEq(usdc.balanceOf(bob), 0);
        assertEq(usdc.balanceOf(carol), 30 * ONE);
    }

    function test_RevertWhen_ClaimForBatch_ZeroInBatch() public {
        address[] memory r = new address[](2);
        r[0] = alice;
        r[1] = address(0);

        vm.expectRevert(SendReferralClaims.ZeroAddress.selector);
        vm.prank(operator);
        claims.claimForBatch(r);
    }

    // =========================================================================
    // pendingClaimAmountBatch / getStats
    // =========================================================================

    function test_PendingClaimAmountBatch() public {
        vm.startPrank(operator);
        claims.setAllocation(alice, 10 * ONE);
        claims.setAllocation(bob, 20 * ONE);
        vm.stopPrank();

        vm.prank(alice);
        claims.claim(); // alice pending = 0 now

        address[] memory r = new address[](3);
        r[0] = alice;
        r[1] = bob;
        r[2] = carol;

        uint256[] memory pending = claims.pendingClaimAmountBatch(r);
        assertEq(pending[0], 0);
        assertEq(pending[1], 20 * ONE);
        assertEq(pending[2], 0);
    }

    function test_GetStats() public {
        vm.prank(operator);
        claims.setAllocation(alice, 100 * ONE);

        vm.prank(alice);
        claims.claim();

        vm.prank(operator);
        claims.setAllocation(alice, 150 * ONE);

        (uint256 pending, uint256 allocated, uint256 claimed) = claims.getStats(alice);
        assertEq(pending, 50 * ONE);
        assertEq(allocated, 150 * ONE);
        assertEq(claimed, 100 * ONE);
    }

    // =========================================================================
    // resetAllocation / resetAllocations
    // =========================================================================

    function test_Reset_WipesBothCounters() public {
        vm.prank(operator);
        claims.setAllocation(alice, 100 * ONE);

        vm.prank(alice);
        claims.claim(); // totalClaimed = 100

        vm.prank(operator);
        claims.setAllocation(alice, 500 * ONE); // pending = 400

        vm.expectEmit(true, false, false, true);
        emit SendReferralClaims.AllocationReset(alice, 500 * ONE, 100 * ONE);
        claims.resetAllocation(alice);

        assertEq(claims.totalAllocated(alice), 0);
        assertEq(claims.totalClaimed(alice), 0);
        assertEq(claims.pendingClaimAmount(alice), 0);
    }

    function test_Reset_ForfeitsPending() public {
        vm.prank(operator);
        claims.setAllocation(alice, 100 * ONE);

        uint256 balBefore = usdc.balanceOf(alice);
        claims.resetAllocation(alice);

        // No transfer happened
        assertEq(usdc.balanceOf(alice), balBefore);
        assertEq(claims.pendingClaimAmount(alice), 0);
    }

    function test_Reset_ThenReallocateWorksFresh() public {
        vm.prank(operator);
        claims.setAllocation(alice, 100 * ONE);

        vm.prank(alice);
        claims.claim();

        claims.resetAllocation(alice);

        // After reset, setting to a value that was previously below `100`
        // must succeed — monotonic check is based on post-reset state.
        vm.prank(operator);
        claims.setAllocation(alice, 10 * ONE);
        assertEq(claims.pendingClaimAmount(alice), 10 * ONE);
    }

    function test_Reset_IdempotentOnFreshUser() public {
        vm.recordLogs();
        claims.resetAllocation(alice);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_ResetBatch() public {
        vm.startPrank(operator);
        claims.setAllocation(alice, 10 * ONE);
        claims.setAllocation(bob, 20 * ONE);
        vm.stopPrank();

        address[] memory r = new address[](2);
        r[0] = alice;
        r[1] = bob;
        claims.resetAllocations(r);

        assertEq(claims.totalAllocated(alice), 0);
        assertEq(claims.totalAllocated(bob), 0);
    }

    function test_RevertWhen_Reset_NotAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, operator, ADMIN_ROLE)
        );
        vm.prank(operator);
        claims.resetAllocation(alice);
    }

    function test_RevertWhen_Reset_ZeroRecipient() public {
        vm.expectRevert(SendReferralClaims.ZeroAddress.selector);
        claims.resetAllocation(address(0));
    }

    // =========================================================================
    // recoverToken — ERC20 path
    // =========================================================================

    function test_RecoverToken_ERC20() public {
        randomToken.mint(address(claims), 500 ether);

        vm.expectEmit(true, true, false, true);
        emit SendReferralClaims.TokenRecovered(address(randomToken), 500 ether, stranger);

        claims.recoverToken(address(randomToken), 500 ether, stranger);

        assertEq(randomToken.balanceOf(stranger), 500 ether);
        assertEq(randomToken.balanceOf(address(claims)), 0);
    }

    function test_RecoverToken_USDC_PullsFromContract() public {
        // Admin pulls unallocated USDC (e.g. excess funding).
        uint256 before = usdc.balanceOf(address(claims));

        claims.recoverToken(BASE_USDC, 1_000 * ONE, stranger);

        assertEq(usdc.balanceOf(stranger), 1_000 * ONE);
        assertEq(usdc.balanceOf(address(claims)), before - 1_000 * ONE);
    }

    function test_RevertWhen_RecoverToken_NotAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, operator, ADMIN_ROLE)
        );
        vm.prank(operator);
        claims.recoverToken(address(randomToken), 1, stranger);
    }

    function test_RevertWhen_RecoverToken_ZeroTo() public {
        vm.expectRevert(SendReferralClaims.ZeroAddress.selector);
        claims.recoverToken(address(randomToken), 1, address(0));
    }

    function test_RevertWhen_RecoverToken_ZeroAmount() public {
        vm.expectRevert(SendReferralClaims.ZeroAmount.selector);
        claims.recoverToken(address(randomToken), 0, stranger);
    }

    // =========================================================================
    // recoverToken — native ETH path
    // =========================================================================

    function test_RecoverETH_ViaReceive() public {
        // Fund via normal transfer — receive() accepts it
        vm.deal(address(this), 5 ether);
        (bool ok, ) = address(claims).call{value: 3 ether}("");
        assertTrue(ok);
        assertEq(address(claims).balance, 3 ether);

        uint256 strangerBefore = stranger.balance;

        vm.expectEmit(true, true, false, true);
        emit SendReferralClaims.TokenRecovered(ETH_ADDRESS, 2 ether, stranger);

        claims.recoverToken(ETH_ADDRESS, 2 ether, stranger);

        assertEq(stranger.balance - strangerBefore, 2 ether);
        assertEq(address(claims).balance, 1 ether);
    }

    function test_RecoverETH_FailsWhenRecipientRejects() public {
        vm.deal(address(claims), 1 ether);
        // Deploy a contract that rejects ETH via a non-payable fallback
        RejectEth rejector = new RejectEth();

        vm.expectRevert(SendReferralClaims.ETHTransferFailed.selector);
        claims.recoverToken(ETH_ADDRESS, 1 ether, address(rejector));
    }

    function test_RevertWhen_RecoverETH_ZeroTo() public {
        vm.deal(address(claims), 1 ether);
        vm.expectRevert(SendReferralClaims.ZeroAddress.selector);
        claims.recoverToken(ETH_ADDRESS, 1 ether, address(0));
    }

    function test_RevertWhen_RecoverETH_ZeroAmount() public {
        vm.expectRevert(SendReferralClaims.ZeroAmount.selector);
        claims.recoverToken(ETH_ADDRESS, 0, stranger);
    }

    function test_Receive_AcceptsETH() public {
        vm.deal(address(this), 10 ether);
        (bool ok, ) = address(claims).call{value: 7 ether}("");
        assertTrue(ok);
        assertEq(address(claims).balance, 7 ether);
    }

    // =========================================================================
    // Fuzz — cumulative push/claim/push/claim stays consistent
    // =========================================================================

    function testFuzz_CumulativeSequence(uint128 day1, uint128 day2, uint128 day3) public {
        // Ensure monotonically non-decreasing. uint128 caps the sum under uint256.
        vm.assume(day1 > 0);
        uint256 t1 = uint256(day1);
        uint256 t2 = t1 + uint256(day2);
        uint256 t3 = t2 + uint256(day3);

        // Make sure the jar is solvent
        usdc.mint(address(claims), t3);

        vm.prank(operator);
        claims.setAllocation(alice, t1);
        vm.prank(alice);
        claims.claim();
        assertEq(usdc.balanceOf(alice), t1);

        vm.prank(operator);
        claims.setAllocation(alice, t2);
        if (t2 > t1) {
            vm.prank(alice);
            claims.claim();
            assertEq(usdc.balanceOf(alice), t2);
        }

        vm.prank(operator);
        claims.setAllocation(alice, t3);
        if (t3 > t2) {
            vm.prank(alice);
            claims.claim();
            assertEq(usdc.balanceOf(alice), t3);
        }

        assertEq(claims.totalClaimed(alice), claims.totalAllocated(alice));
        assertEq(claims.pendingClaimAmount(alice), 0);
    }

    function testFuzz_NoDecreaseAllowed(uint128 high, uint128 low) public {
        vm.assume(high > low);
        vm.prank(operator);
        claims.setAllocation(alice, uint256(high));

        vm.expectRevert(
            abi.encodeWithSelector(
                SendReferralClaims.AllocationDecrease.selector,
                alice,
                uint256(high),
                uint256(low)
            )
        );
        vm.prank(operator);
        claims.setAllocation(alice, uint256(low));
    }
}

// ---------------------------------------------------------------------------
// Helper: contract that rejects ETH (no receive/fallback)
// ---------------------------------------------------------------------------

contract RejectEth {}

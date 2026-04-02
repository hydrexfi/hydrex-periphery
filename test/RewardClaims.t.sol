// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {RewardClaims} from "../contracts/extra/RewardClaims.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ---------------------------------------------------------------------------
// Mock tokens
// ---------------------------------------------------------------------------

contract MockToken18 is ERC20 {
    constructor() ERC20("Token 18", "TK18") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 18;
    }
}

contract MockToken6 is ERC20 {
    constructor() ERC20("Token 6", "TK6") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

// ---------------------------------------------------------------------------
// Test contract
// ---------------------------------------------------------------------------

contract RewardClaimsTest is Test {
    RewardClaims public claims;
    MockToken18 public token18;
    MockToken6 public token6;

    address public admin;
    address public alice;
    address public bob;
    address public carol;
    address public stranger;

    // Shorthand unit helpers
    uint256 constant ONE_18 = 1e18;
    uint256 constant ONE_6 = 1e6;

    function setUp() public {
        admin = address(this);
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
        stranger = makeAddr("stranger");

        claims = new RewardClaims();
        token18 = new MockToken18();
        token6 = new MockToken6();

        // Pre-fund the contract so transfers don't revert during claim tests
        token18.mint(address(claims), 1_000_000 * ONE_18);
        token6.mint(address(claims), 1_000_000 * ONE_6);
    }

    // =========================================================================
    // Initial state
    // =========================================================================

    function test_InitialState() public view {
        assertTrue(claims.hasRole(claims.DEFAULT_ADMIN_ROLE(), admin));
        assertEq(claims.getClaimable(alice, address(token18)), 0);
        assertEq(claims.getClaimable(alice, address(token6)), 0);
    }

    // =========================================================================
    // setAllocation — single
    // =========================================================================

    function test_SetAllocation_18Dec() public {
        uint256 amount = 500 * ONE_18;
        vm.expectEmit(true, true, false, true);
        emit RewardClaims.AllocationSet(alice, address(token18), amount);

        claims.setAllocation(alice, address(token18), amount);

        assertEq(claims.claimable(alice, address(token18)), amount);
        assertEq(claims.getClaimable(alice, address(token18)), amount);
    }

    function test_SetAllocation_6Dec() public {
        uint256 amount = 500 * ONE_6;
        vm.expectEmit(true, true, false, true);
        emit RewardClaims.AllocationSet(alice, address(token6), amount);

        claims.setAllocation(alice, address(token6), amount);

        assertEq(claims.getClaimable(alice, address(token6)), amount);
    }

    function test_SetAllocation_OverwritesPreviousValue() public {
        claims.setAllocation(alice, address(token18), 100 * ONE_18);
        claims.setAllocation(alice, address(token18), 250 * ONE_18);

        assertEq(claims.getClaimable(alice, address(token18)), 250 * ONE_18);
    }

    function test_SetAllocation_ZeroEffectivelyRemoves() public {
        claims.setAllocation(alice, address(token18), 100 * ONE_18);
        claims.setAllocation(alice, address(token18), 0);

        assertEq(claims.getClaimable(alice, address(token18)), 0);
    }

    function test_RevertWhen_SetAllocation_ZeroRecipient() public {
        vm.expectRevert(RewardClaims.ZeroAddress.selector);
        claims.setAllocation(address(0), address(token18), 100 * ONE_18);
    }

    function test_RevertWhen_SetAllocation_ZeroToken() public {
        vm.expectRevert(RewardClaims.ZeroAddress.selector);
        claims.setAllocation(alice, address(0), 100 * ONE_18);
    }

    function test_RevertWhen_SetAllocation_NotAdmin() public {
        vm.prank(stranger);
        vm.expectRevert();
        claims.setAllocation(alice, address(token18), 100 * ONE_18);
    }

    // =========================================================================
    // setAllocations — batch per token
    // =========================================================================

    function test_SetAllocations_18Dec() public {
        address[] memory recipients = new address[](3);
        recipients[0] = alice;
        recipients[1] = bob;
        recipients[2] = carol;

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 100 * ONE_18;
        amounts[1] = 200 * ONE_18;
        amounts[2] = 300 * ONE_18;

        claims.setAllocations(address(token18), recipients, amounts);

        assertEq(claims.getClaimable(alice, address(token18)), 100 * ONE_18);
        assertEq(claims.getClaimable(bob, address(token18)), 200 * ONE_18);
        assertEq(claims.getClaimable(carol, address(token18)), 300 * ONE_18);
    }

    function test_SetAllocations_6Dec() public {
        address[] memory recipients = new address[](2);
        recipients[0] = alice;
        recipients[1] = bob;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 50 * ONE_6;
        amounts[1] = 75 * ONE_6;

        claims.setAllocations(address(token6), recipients, amounts);

        assertEq(claims.getClaimable(alice, address(token6)), 50 * ONE_6);
        assertEq(claims.getClaimable(bob, address(token6)), 75 * ONE_6);
    }

    function test_SetAllocations_EmitsEventPerRecipient() public {
        address[] memory recipients = new address[](2);
        recipients[0] = alice;
        recipients[1] = bob;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 10 * ONE_18;
        amounts[1] = 20 * ONE_18;

        vm.expectEmit(true, true, false, true);
        emit RewardClaims.AllocationSet(alice, address(token18), 10 * ONE_18);
        vm.expectEmit(true, true, false, true);
        emit RewardClaims.AllocationSet(bob, address(token18), 20 * ONE_18);

        claims.setAllocations(address(token18), recipients, amounts);
    }

    function test_RevertWhen_SetAllocations_LengthMismatch() public {
        address[] memory recipients = new address[](2);
        recipients[0] = alice;
        recipients[1] = bob;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10 * ONE_18;

        vm.expectRevert(RewardClaims.LengthMismatch.selector);
        claims.setAllocations(address(token18), recipients, amounts);
    }

    function test_RevertWhen_SetAllocations_ZeroToken() public {
        address[] memory recipients = new address[](1);
        recipients[0] = alice;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10 * ONE_18;

        vm.expectRevert(RewardClaims.ZeroAddress.selector);
        claims.setAllocations(address(0), recipients, amounts);
    }

    function test_RevertWhen_SetAllocations_ZeroRecipientInBatch() public {
        address[] memory recipients = new address[](2);
        recipients[0] = alice;
        recipients[1] = address(0);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 10 * ONE_18;
        amounts[1] = 20 * ONE_18;

        vm.expectRevert(RewardClaims.ZeroAddress.selector);
        claims.setAllocations(address(token18), recipients, amounts);
    }

    function test_RevertWhen_SetAllocations_NotAdmin() public {
        address[] memory recipients = new address[](1);
        recipients[0] = alice;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10 * ONE_18;

        vm.prank(stranger);
        vm.expectRevert();
        claims.setAllocations(address(token18), recipients, amounts);
    }

    // =========================================================================
    // claim
    // =========================================================================

    function test_Claim_18Dec() public {
        uint256 amount = 1_000 * ONE_18;
        claims.setAllocation(alice, address(token18), amount);

        uint256 balBefore = token18.balanceOf(alice);

        vm.expectEmit(true, true, false, true);
        emit RewardClaims.Claimed(alice, address(token18), amount);

        vm.prank(alice);
        claims.claim(address(token18));

        assertEq(token18.balanceOf(alice) - balBefore, amount);
        assertEq(claims.getClaimable(alice, address(token18)), 0);
    }

    function test_Claim_6Dec() public {
        uint256 amount = 1_000 * ONE_6;
        claims.setAllocation(alice, address(token6), amount);

        uint256 balBefore = token6.balanceOf(alice);

        vm.prank(alice);
        claims.claim(address(token6));

        assertEq(token6.balanceOf(alice) - balBefore, amount);
        assertEq(claims.getClaimable(alice, address(token6)), 0);
    }

    function test_Claim_ZeroedAfterClaim() public {
        claims.setAllocation(alice, address(token18), 100 * ONE_18);

        vm.prank(alice);
        claims.claim(address(token18));

        // Second claim must revert
        vm.prank(alice);
        vm.expectRevert(RewardClaims.NothingToClaim.selector);
        claims.claim(address(token18));
    }

    function test_Claim_DoesNotAffectOtherRecipient() public {
        claims.setAllocation(alice, address(token18), 100 * ONE_18);
        claims.setAllocation(bob, address(token18), 200 * ONE_18);

        vm.prank(alice);
        claims.claim(address(token18));

        // Bob's allocation unchanged
        assertEq(claims.getClaimable(bob, address(token18)), 200 * ONE_18);
    }

    function test_Claim_DoesNotAffectOtherToken() public {
        claims.setAllocation(alice, address(token18), 100 * ONE_18);
        claims.setAllocation(alice, address(token6), 50 * ONE_6);

        vm.prank(alice);
        claims.claim(address(token18));

        // token6 allocation untouched
        assertEq(claims.getClaimable(alice, address(token6)), 50 * ONE_6);
    }

    function test_Claim_BothTokensSameUser() public {
        claims.setAllocation(alice, address(token18), 100 * ONE_18);
        claims.setAllocation(alice, address(token6), 50 * ONE_6);

        vm.startPrank(alice);
        claims.claim(address(token18));
        claims.claim(address(token6));
        vm.stopPrank();

        assertEq(token18.balanceOf(alice), 100 * ONE_18);
        assertEq(token6.balanceOf(alice), 50 * ONE_6);
        assertEq(claims.getClaimable(alice, address(token18)), 0);
        assertEq(claims.getClaimable(alice, address(token6)), 0);
    }

    function test_RevertWhen_Claim_NothingAllocated() public {
        vm.prank(alice);
        vm.expectRevert(RewardClaims.NothingToClaim.selector);
        claims.claim(address(token18));
    }

    // =========================================================================
    // getClaimableBatch
    // =========================================================================

    function test_GetClaimableBatch() public {
        claims.setAllocation(alice, address(token18), 100 * ONE_18);
        claims.setAllocation(bob, address(token6), 50 * ONE_6);

        address[] memory recipients = new address[](3);
        recipients[0] = alice;
        recipients[1] = bob;
        recipients[2] = carol; // nothing set

        address[] memory tokens = new address[](3);
        tokens[0] = address(token18);
        tokens[1] = address(token6);
        tokens[2] = address(token18);

        uint256[] memory results = claims.getClaimableBatch(recipients, tokens);

        assertEq(results[0], 100 * ONE_18);
        assertEq(results[1], 50 * ONE_6);
        assertEq(results[2], 0);
    }

    function test_RevertWhen_GetClaimableBatch_LengthMismatch() public {
        address[] memory recipients = new address[](2);
        recipients[0] = alice;
        recipients[1] = bob;
        address[] memory tokens = new address[](1);
        tokens[0] = address(token18);

        vm.expectRevert(RewardClaims.LengthMismatch.selector);
        claims.getClaimableBatch(recipients, tokens);
    }

    // =========================================================================
    // emergencyRecover
    // =========================================================================

    function test_EmergencyRecover() public {
        uint256 extra = 999 * ONE_18;
        token18.mint(address(claims), extra);

        uint256 balBefore = token18.balanceOf(stranger);

        vm.expectEmit(true, true, false, true);
        emit RewardClaims.EmergencyRecovered(address(token18), stranger, extra);

        claims.emergencyRecover(address(token18), stranger, extra);

        assertEq(token18.balanceOf(stranger) - balBefore, extra);
    }

    function test_RevertWhen_EmergencyRecover_ZeroToken() public {
        vm.expectRevert(RewardClaims.ZeroAddress.selector);
        claims.emergencyRecover(address(0), stranger, 1);
    }

    function test_RevertWhen_EmergencyRecover_ZeroRecipient() public {
        vm.expectRevert(RewardClaims.ZeroAddress.selector);
        claims.emergencyRecover(address(token18), address(0), 1);
    }

    function test_RevertWhen_EmergencyRecover_ZeroAmount() public {
        vm.expectRevert(RewardClaims.ZeroAmount.selector);
        claims.emergencyRecover(address(token18), stranger, 0);
    }

    function test_RevertWhen_EmergencyRecover_NotAdmin() public {
        vm.prank(stranger);
        vm.expectRevert();
        claims.emergencyRecover(address(token18), stranger, 1);
    }

    // =========================================================================
    // Fuzz
    // =========================================================================

    function testFuzz_SetAndClaim_18Dec(uint128 amount) public {
        vm.assume(amount > 0);
        token18.mint(address(claims), amount);

        claims.setAllocation(alice, address(token18), amount);

        uint256 balBefore = token18.balanceOf(alice);
        vm.prank(alice);
        claims.claim(address(token18));

        assertEq(token18.balanceOf(alice) - balBefore, amount);
        assertEq(claims.getClaimable(alice, address(token18)), 0);
    }

    function testFuzz_SetAndClaim_6Dec(uint64 amount) public {
        vm.assume(amount > 0);
        token6.mint(address(claims), amount);

        claims.setAllocation(alice, address(token6), amount);

        uint256 balBefore = token6.balanceOf(alice);
        vm.prank(alice);
        claims.claim(address(token6));

        assertEq(token6.balanceOf(alice) - balBefore, amount);
        assertEq(claims.getClaimable(alice, address(token6)), 0);
    }
}

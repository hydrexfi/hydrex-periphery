// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {AnchorClubFlexAccounts} from "../../contracts/anchor-club/AnchorClubFlexAccounts.sol";
import {IHydrexVotingEscrow} from "../../contracts/interfaces/IHydrexVotingEscrow.sol";
import {IOptionsToken} from "../../contracts/interfaces/IOptionsToken.sol";

contract MockVotingEscrow {
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => IHydrexVotingEscrow.LockDetails) public lockDetails;

    function setOwner(uint256 nftId, address owner) external {
        ownerOf[nftId] = owner;
    }

    function setLockDetails(
        uint256 nftId,
        uint256 amount,
        uint256 startTime,
        uint256 endTime,
        IHydrexVotingEscrow.LockType lockType
    ) external {
        lockDetails[nftId] = IHydrexVotingEscrow.LockDetails({
            amount: amount,
            startTime: startTime,
            endTime: endTime,
            lockType: lockType
        });
    }

    function _lockDetails(uint256 nftId) external view returns (IHydrexVotingEscrow.LockDetails memory) {
        return lockDetails[nftId];
    }
}

contract MockOptionsToken {
    uint256 private nftIdCounter = 1000;

    function exerciseVe(uint256 /* _amount */, address /* _recipient */) external returns (uint256 nftId) {
        return nftIdCounter++;
    }
}

contract AnchorClubFlexAccountsTest is Test {
    AnchorClubFlexAccounts public anchorClub;
    MockVotingEscrow public veToken;
    MockOptionsToken public optionsToken;

    address public admin;
    address public operator;
    address public user1;
    address public user2;

    uint256 constant NFT_ID_1 = 1;
    uint256 constant NFT_ID_2 = 2;
    uint256 constant LOCK_AMOUNT = 1000 ether;

    function setUp() public {
        admin = makeAddr("admin");
        operator = makeAddr("operator");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        // Deploy mocks
        veToken = new MockVotingEscrow();
        optionsToken = new MockOptionsToken();

        // Deploy AnchorClub
        vm.prank(admin);
        anchorClub = new AnchorClubFlexAccounts(
            IHydrexVotingEscrow(address(veToken)),
            IOptionsToken(address(optionsToken)),
            admin
        );

        // Setup NFTs for testing
        veToken.setOwner(NFT_ID_1, user1);
        veToken.setLockDetails(
            NFT_ID_1,
            LOCK_AMOUNT,
            block.timestamp,
            block.timestamp + 365 days,
            IHydrexVotingEscrow.LockType.ROLLING
        );

        veToken.setOwner(NFT_ID_2, user2);
        veToken.setLockDetails(
            NFT_ID_2,
            LOCK_AMOUNT,
            block.timestamp,
            block.timestamp + 365 days,
            IHydrexVotingEscrow.LockType.ROLLING
        );
    }

    function testInitialState() public view {
        assertEq(anchorClub.tierCount(), 5);
        assertTrue(anchorClub.registrationsAllowed());
        assertTrue(anchorClub.hasRole(anchorClub.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(anchorClub.hasRole(anchorClub.OPERATOR_ROLE(), admin));
    }

    function testTierConfiguration() public view {
        (uint256 duration1, uint256 bonus1) = anchorClub.tiers(1);
        assertEq(duration1, 2 weeks);
        assertEq(bonus1, 2500); // 25%

        (uint256 duration5, uint256 bonus5) = anchorClub.tiers(5);
        assertEq(duration5, 52 weeks);
        assertEq(bonus5, 15000); // 150%
    }

    function testCalculateBonus() public view {
        // Tier 1: 25% bonus
        uint256 bonus1 = anchorClub.calculateBonus(LOCK_AMOUNT, 1);
        // (1000 ether * 2500 * 13000) / 100000000 = 325 ether
        assertEq(bonus1, 325 ether);

        // Tier 5: 150% bonus
        uint256 bonus5 = anchorClub.calculateBonus(LOCK_AMOUNT, 5);
        // (1000 ether * 15000 * 13000) / 100000000 = 1950 ether
        assertEq(bonus5, 1950 ether);
    }

    function testRegister() public {
        vm.prank(user1);
        anchorClub.register(NFT_ID_1);

        (uint256 timestamp, uint256 snapshotAmount, address owner) = anchorClub.registrations(NFT_ID_1);
        assertEq(timestamp, block.timestamp);
        assertEq(snapshotAmount, LOCK_AMOUNT);
        assertEq(owner, user1);
    }

    function test_RevertWhen_RegisterNotOwner() public {
        vm.prank(user2);
        vm.expectRevert(AnchorClubFlexAccounts.NotNftOwner.selector);
        anchorClub.register(NFT_ID_1);
    }

    function test_RevertWhen_RegisterTwice() public {
        vm.startPrank(user1);
        anchorClub.register(NFT_ID_1);
        
        vm.expectRevert(AnchorClubFlexAccounts.AlreadyRegistered.selector);
        anchorClub.register(NFT_ID_1);
        vm.stopPrank();
    }

    function test_RevertWhen_RegisterNonFlexAccount() public {
        uint256 permanentNftId = 3;
        veToken.setOwner(permanentNftId, user1);
        veToken.setLockDetails(
            permanentNftId,
            LOCK_AMOUNT,
            block.timestamp,
            block.timestamp + 365 days,
            IHydrexVotingEscrow.LockType.PERMANENT
        );

        vm.prank(user1);
        vm.expectRevert(AnchorClubFlexAccounts.NotFlexAccount.selector);
        anchorClub.register(permanentNftId);
    }

    function test_RevertWhen_RegistrationsDisabled() public {
        vm.prank(admin);
        anchorClub.setRegistrationsAllowed(false);

        vm.prank(user1);
        vm.expectRevert(AnchorClubFlexAccounts.RegistrationsNotAllowed.selector);
        anchorClub.register(NFT_ID_1);
    }

    function testGetTierStatusNotEligible() public {
        vm.prank(user1);
        anchorClub.register(NFT_ID_1);

        // Right after registration, should be NOT_ELIGIBLE
        AnchorClubFlexAccounts.TierStatus status = anchorClub.getTierStatus(NFT_ID_1, 1);
        assertEq(uint8(status), uint8(AnchorClubFlexAccounts.TierStatus.NOT_ELIGIBLE));
    }

    function testGetTierStatusPendingApproval() public {
        vm.prank(user1);
        anchorClub.register(NFT_ID_1);

        // Advance time past tier 1 duration (2 weeks)
        vm.warp(block.timestamp + 2 weeks + 1);

        AnchorClubFlexAccounts.TierStatus status = anchorClub.getTierStatus(NFT_ID_1, 1);
        assertEq(uint8(status), uint8(AnchorClubFlexAccounts.TierStatus.PENDING_APPROVAL));
    }

    function testApproveTier() public {
        vm.prank(user1);
        anchorClub.register(NFT_ID_1);

        // Advance time
        vm.warp(block.timestamp + 2 weeks + 1);

        // Approve tier
        vm.prank(admin);
        anchorClub.approveTier(NFT_ID_1, 1);

        assertTrue(anchorClub.tierApprovals(NFT_ID_1, 1));

        AnchorClubFlexAccounts.TierStatus status = anchorClub.getTierStatus(NFT_ID_1, 1);
        assertEq(uint8(status), uint8(AnchorClubFlexAccounts.TierStatus.APPROVED));
    }

    function testBatchApproveTiers() public {
        vm.prank(user1);
        anchorClub.register(NFT_ID_1);
        vm.prank(user2);
        anchorClub.register(NFT_ID_2);

        // Advance time
        vm.warp(block.timestamp + 2 weeks + 1);

        // Batch approve
        uint256[] memory nftIds = new uint256[](2);
        nftIds[0] = NFT_ID_1;
        nftIds[1] = NFT_ID_2;

        uint8[] memory tierIds = new uint8[](2);
        tierIds[0] = 1;
        tierIds[1] = 1;

        vm.prank(admin);
        anchorClub.batchApproveTiers(nftIds, tierIds);

        assertTrue(anchorClub.tierApprovals(NFT_ID_1, 1));
        assertTrue(anchorClub.tierApprovals(NFT_ID_2, 1));
    }

    function testClaim() public {
        // Register
        vm.prank(user1);
        anchorClub.register(NFT_ID_1);

        // Advance time and approve
        vm.warp(block.timestamp + 2 weeks + 1);
        vm.prank(admin);
        anchorClub.approveTier(NFT_ID_1, 1);

        // Claim
        vm.prank(user1);
        anchorClub.claim(NFT_ID_1, 1);

        assertTrue(anchorClub.tierClaims(NFT_ID_1, 1));
        
        uint256 expectedBonus = anchorClub.calculateBonus(LOCK_AMOUNT, 1);
        assertEq(anchorClub.totalCredits(user1), expectedBonus);

        AnchorClubFlexAccounts.TierStatus status = anchorClub.getTierStatus(NFT_ID_1, 1);
        assertEq(uint8(status), uint8(AnchorClubFlexAccounts.TierStatus.CLAIMED));
    }

    function test_RevertWhen_ClaimNotRegistered() public {
        vm.prank(user1);
        vm.expectRevert(AnchorClubFlexAccounts.NotRegistered.selector);
        anchorClub.claim(NFT_ID_1, 1);
    }

    function test_RevertWhen_ClaimNotApproved() public {
        vm.prank(user1);
        anchorClub.register(NFT_ID_1);

        vm.warp(block.timestamp + 2 weeks + 1);

        vm.prank(user1);
        vm.expectRevert(AnchorClubFlexAccounts.NotApproved.selector);
        anchorClub.claim(NFT_ID_1, 1);
    }

    function test_RevertWhen_ClaimTwice() public {
        vm.prank(user1);
        anchorClub.register(NFT_ID_1);

        vm.warp(block.timestamp + 2 weeks + 1);
        vm.prank(admin);
        anchorClub.approveTier(NFT_ID_1, 1);

        vm.startPrank(user1);
        anchorClub.claim(NFT_ID_1, 1);
        
        vm.expectRevert(AnchorClubFlexAccounts.AlreadyClaimed.selector);
        anchorClub.claim(NFT_ID_1, 1);
        vm.stopPrank();
    }

    function test_RevertWhen_ClaimNotOwner() public {
        vm.prank(user1);
        anchorClub.register(NFT_ID_1);

        vm.warp(block.timestamp + 2 weeks + 1);
        vm.prank(admin);
        anchorClub.approveTier(NFT_ID_1, 1);

        vm.prank(user2);
        vm.expectRevert(AnchorClubFlexAccounts.NotNftOwner.selector);
        anchorClub.claim(NFT_ID_1, 1);
    }

    function test_RevertWhen_BalanceDecreased() public {
        vm.prank(user1);
        anchorClub.register(NFT_ID_1);

        // Decrease balance
        veToken.setLockDetails(
            NFT_ID_1,
            LOCK_AMOUNT / 2,
            block.timestamp,
            block.timestamp + 365 days,
            IHydrexVotingEscrow.LockType.ROLLING
        );

        vm.warp(block.timestamp + 2 weeks + 1);
        vm.prank(admin);
        anchorClub.approveTier(NFT_ID_1, 1);

        vm.prank(user1);
        vm.expectRevert(AnchorClubFlexAccounts.BalanceDecreased.selector);
        anchorClub.claim(NFT_ID_1, 1);
    }

    function test_RevertWhen_LockTypeChanged() public {
        vm.prank(user1);
        anchorClub.register(NFT_ID_1);

        // Change lock type
        veToken.setLockDetails(
            NFT_ID_1,
            LOCK_AMOUNT,
            block.timestamp,
            block.timestamp + 365 days,
            IHydrexVotingEscrow.LockType.PERMANENT
        );

        vm.warp(block.timestamp + 2 weeks + 1);
        vm.prank(admin);
        anchorClub.approveTier(NFT_ID_1, 1);

        vm.prank(user1);
        vm.expectRevert(AnchorClubFlexAccounts.LockTypeChanged.selector);
        anchorClub.claim(NFT_ID_1, 1);
    }

    function testGetAllTierStatuses() public {
        vm.prank(user1);
        anchorClub.register(NFT_ID_1);

        AnchorClubFlexAccounts.TierStatusInfo[] memory statuses = anchorClub.getAllTierStatuses(NFT_ID_1);
        
        assertEq(statuses.length, 5);
        assertEq(statuses[0].tierId, 1);
        assertEq(uint8(statuses[0].status), uint8(AnchorClubFlexAccounts.TierStatus.NOT_ELIGIBLE));
        assertGt(statuses[0].timeRemaining, 0);
        assertGt(statuses[0].bonusAmount, 0);
    }

    function testOverrideSnapshotAmount() public {
        vm.prank(user1);
        anchorClub.register(NFT_ID_1);

        uint256 newAmount = 2000 ether;
        vm.prank(admin);
        anchorClub.overrideSnapshotAmount(NFT_ID_1, newAmount);

        (, uint256 snapshotAmount, ) = anchorClub.registrations(NFT_ID_1);
        assertEq(snapshotAmount, newAmount);
    }

    function testGetTotalClaimedCredits() public {
        vm.prank(user1);
        anchorClub.register(NFT_ID_1);

        vm.warp(block.timestamp + 2 weeks + 1);
        vm.prank(admin);
        anchorClub.approveTier(NFT_ID_1, 1);

        vm.prank(user1);
        anchorClub.claim(NFT_ID_1, 1);

        uint256 totalClaimed = anchorClub.getTotalClaimedCredits(user1);
        assertGt(totalClaimed, 0);
        assertEq(totalClaimed, anchorClub.calculateTotalCredits(user1));
    }

    function testMultipleTierClaims() public {
        vm.prank(user1);
        anchorClub.register(NFT_ID_1);

        // Claim tier 1
        vm.warp(block.timestamp + 2 weeks + 1);
        vm.prank(admin);
        anchorClub.approveTier(NFT_ID_1, 1);
        vm.prank(user1);
        anchorClub.claim(NFT_ID_1, 1);

        uint256 tier1Credits = anchorClub.totalCredits(user1);

        // Claim tier 2
        vm.warp(block.timestamp + 4 weeks);
        vm.prank(admin);
        anchorClub.approveTier(NFT_ID_1, 2);
        vm.prank(user1);
        anchorClub.claim(NFT_ID_1, 2);

        uint256 tier2Credits = anchorClub.totalCredits(user1);
        assertGt(tier2Credits, tier1Credits);
    }
}


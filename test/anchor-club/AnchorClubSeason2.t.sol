// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {AnchorClubSeason2} from "../../contracts/anchor-club/AnchorClubSeason2.sol";
import {IOptionsToken} from "../../contracts/interfaces/IOptionsToken.sol";
import {ILiquidConduit} from "../../contracts/interfaces/ILiquidConduit.sol";
import {VeMaxiTokenConduit} from "../../contracts/conduits/VeMaxiTokenConduit.sol";

contract MockOptionsToken {
    uint256 private nftIdCounter = 1;

    function exerciseVe(uint256 /* _amount */, address /* _recipient */) external returns (uint256 nftId) {
        return nftIdCounter++;
    }
}

contract MockERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockLiquidConduit {
    mapping(address => uint256) public cumulativeOptionsClaimed;

    function setCumulativeOptionsClaimed(address user, uint256 amount) external {
        cumulativeOptionsClaimed[user] = amount;
    }
}

contract MockVeMaxiConduit {
    mapping(address => uint256) public totalFlexLocked;
    mapping(address => uint256) public totalProtocolLocked;

    function setTotalFlexLocked(address user, uint256 amount) external {
        totalFlexLocked[user] = amount;
    }

    function setTotalProtocolLocked(address user, uint256 amount) external {
        totalProtocolLocked[user] = amount;
    }
}

contract AnchorClubSeason2Test is Test {
    AnchorClubSeason2 public season2;
    MockOptionsToken public optionsToken;
    MockLiquidConduit public season1Snapshot;
    MockLiquidConduit public liquidConduit1;
    MockLiquidConduit public liquidConduit2;
    MockVeMaxiConduit public veMaxiConduit;

    address public admin;
    address public user1;
    address public user2;
    address public user3;

    function setUp() public {
        admin = makeAddr("admin");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        // Deploy mocks
        optionsToken = new MockOptionsToken();
        season1Snapshot = new MockLiquidConduit();
        liquidConduit1 = new MockLiquidConduit();
        liquidConduit2 = new MockLiquidConduit();
        veMaxiConduit = new MockVeMaxiConduit();

        // Deploy Season 2
        vm.prank(admin);
        season2 = new AnchorClubSeason2(
            IOptionsToken(address(optionsToken)),
            ILiquidConduit(address(season1Snapshot)),
            VeMaxiTokenConduit(payable(address(veMaxiConduit))),
            admin
        );

        // Add liquid conduits
        ILiquidConduit[] memory conduits = new ILiquidConduit[](2);
        conduits[0] = ILiquidConduit(address(liquidConduit1));
        conduits[1] = ILiquidConduit(address(liquidConduit2));

        vm.prank(admin);
        season2.addLiquidConduits(conduits);
    }

    /*
     * Initial State Tests
     */

    function testInitialState() public view {
        assertEq(season2.liquidAccountMultiplier(), 15000); // 1.5x
        assertEq(season2.veMaxiMultiplier(), 40000); // 4.0x
        assertTrue(season2.hasRole(season2.DEFAULT_ADMIN_ROLE(), admin));
        assertEq(address(season2.optionsToken()), address(optionsToken));
        assertEq(address(season2.season1Snapshot()), address(season1Snapshot));
        assertEq(address(season2.veMaxiConduit()), address(veMaxiConduit));
    }

    function testLiquidConduitsAdded() public view {
        assertTrue(season2.isLiquidConduit(address(liquidConduit1)));
        assertTrue(season2.isLiquidConduit(address(liquidConduit2)));
        ILiquidConduit[] memory conduits = season2.getLiquidConduits();
        assertEq(conduits.length, 2);
    }

    /*
     * Liquid Credits Tests
     */

    function testCalculateSeason2LiquidCredits_NoSeason1Claims() public {
        // User has 1000 in current conduits, 0 in season 1
        liquidConduit1.setCumulativeOptionsClaimed(user1, 600 ether);
        liquidConduit2.setCumulativeOptionsClaimed(user1, 400 ether);

        // Credits = (1000 - 0) * 15000 / 10000 = 1500
        uint256 credits = season2.calculateSeason2LiquidCredits(user1);
        assertEq(credits, 1500 ether);
    }

    function testCalculateSeason2LiquidCredits_WithSeason1Claims() public {
        // Season 1: user had 500 total
        season1Snapshot.setCumulativeOptionsClaimed(user1, 500 ether);

        // Current: user has 1200 total
        liquidConduit1.setCumulativeOptionsClaimed(user1, 700 ether);
        liquidConduit2.setCumulativeOptionsClaimed(user1, 500 ether);

        // Season 2 credits = (1200 - 500) * 15000 / 10000 = 1050
        uint256 credits = season2.calculateSeason2LiquidCredits(user1);
        assertEq(credits, 1050 ether);
    }

    function testCalculateSeason2LiquidCredits_CurrentLessThanSeason1() public {
        // Edge case: current claims less than season 1 (shouldn't happen but handle gracefully)
        season1Snapshot.setCumulativeOptionsClaimed(user1, 1000 ether);
        liquidConduit1.setCumulativeOptionsClaimed(user1, 500 ether);

        // Should return 0, not underflow
        uint256 credits = season2.calculateSeason2LiquidCredits(user1);
        assertEq(credits, 0);
    }

    function testCalculateSeason2LiquidRemainingCredits() public {
        liquidConduit1.setCumulativeOptionsClaimed(user1, 1000 ether);

        // Total credits = 1500
        uint256 totalCredits = season2.calculateSeason2LiquidCredits(user1);
        assertEq(totalCredits, 1500 ether);

        // Spend 500
        vm.prank(user1);
        season2.redeemLiquidCredits(500 ether);

        // Remaining = 1000
        uint256 remaining = season2.calculateSeason2LiquidRemainingCredits(user1);
        assertEq(remaining, 1000 ether);
        assertEq(season2.liquidSpentCredits(user1), 500 ether);
    }

    /*
     * VeMaxi Credits Tests
     */

    function testCalculateVeMaxiCredits_FlexOnly() public {
        veMaxiConduit.setTotalFlexLocked(user1, 1000 ether);

        // Credits = 1000 * 40000 / 10000 = 4000
        uint256 credits = season2.calculateVeMaxiCredits(user1);
        assertEq(credits, 4000 ether);
    }

    function testCalculateVeMaxiCredits_ProtocolOnly() public {
        veMaxiConduit.setTotalProtocolLocked(user1, 500 ether);

        // Credits = 500 * 40000 / 10000 = 2000
        uint256 credits = season2.calculateVeMaxiCredits(user1);
        assertEq(credits, 2000 ether);
    }

    function testCalculateVeMaxiCredits_Both() public {
        veMaxiConduit.setTotalFlexLocked(user1, 1000 ether);
        veMaxiConduit.setTotalProtocolLocked(user1, 500 ether);

        // Credits = (1000 + 500) * 40000 / 10000 = 6000
        uint256 credits = season2.calculateVeMaxiCredits(user1);
        assertEq(credits, 6000 ether);
    }

    function testCalculateVeMaxiRemainingCredits() public {
        veMaxiConduit.setTotalFlexLocked(user1, 1000 ether);
        veMaxiConduit.setTotalProtocolLocked(user1, 500 ether);

        // Total = 6000
        uint256 totalCredits = season2.calculateVeMaxiCredits(user1);
        assertEq(totalCredits, 6000 ether);

        // Spend 2000
        vm.prank(user1);
        season2.redeemVeMaxiCredits(2000 ether);

        // Remaining = 4000
        uint256 remaining = season2.calculateVeMaxiRemainingCredits(user1);
        assertEq(remaining, 4000 ether);
        assertEq(season2.veMaxiSpentCredits(user1), 2000 ether);
    }

    /*
     * Combined Credits Tests
     */

    function testCalculateTotalCredits() public {
        // Liquid: 1000 current, 200 season 1 = 800 new * 1.5 = 1200
        season1Snapshot.setCumulativeOptionsClaimed(user1, 200 ether);
        liquidConduit1.setCumulativeOptionsClaimed(user1, 600 ether);
        liquidConduit2.setCumulativeOptionsClaimed(user1, 400 ether);

        // VeMaxi: 500 flex + 300 protocol = 800 * 4 = 3200
        veMaxiConduit.setTotalFlexLocked(user1, 500 ether);
        veMaxiConduit.setTotalProtocolLocked(user1, 300 ether);

        // Total = 1200 + 3200 = 4400
        uint256 totalCredits = season2.calculateTotalCredits(user1);
        assertEq(totalCredits, 4400 ether);
    }

    function testCalculateTotalRemainingCredits() public {
        liquidConduit1.setCumulativeOptionsClaimed(user1, 1000 ether); // 1500 credits
        veMaxiConduit.setTotalFlexLocked(user1, 1000 ether); // 4000 credits

        // Total = 5500
        uint256 totalCredits = season2.calculateTotalCredits(user1);
        assertEq(totalCredits, 5500 ether);

        // Spend 1000 liquid, 2000 veMaxi
        vm.startPrank(user1);
        season2.redeemLiquidCredits(1000 ether);
        season2.redeemVeMaxiCredits(2000 ether);
        vm.stopPrank();

        // Remaining = (1500 - 1000) + (4000 - 2000) = 2500
        uint256 remaining = season2.calculateTotalRemainingCredits(user1);
        assertEq(remaining, 2500 ether);
    }

    /*
     * Redemption Tests
     */

    function testRedeemLiquidCredits() public {
        liquidConduit1.setCumulativeOptionsClaimed(user1, 1000 ether);

        vm.expectEmit(true, false, false, true);
        emit AnchorClubSeason2.LiquidConduitCreditsRedeemed(user1, 500 ether, 1);

        vm.prank(user1);
        season2.redeemLiquidCredits(500 ether);

        assertEq(season2.liquidSpentCredits(user1), 500 ether);
    }

    function test_RevertWhen_RedeemLiquidCredits_InsufficientCredits() public {
        liquidConduit1.setCumulativeOptionsClaimed(user1, 100 ether); // 150 credits

        vm.prank(user1);
        vm.expectRevert(AnchorClubSeason2.InsufficientCredits.selector);
        season2.redeemLiquidCredits(200 ether);
    }

    function test_RevertWhen_RedeemLiquidCredits_ZeroAmount() public {
        vm.prank(user1);
        vm.expectRevert(AnchorClubSeason2.InvalidAmount.selector);
        season2.redeemLiquidCredits(0);
    }

    function testRedeemVeMaxiCredits() public {
        veMaxiConduit.setTotalFlexLocked(user1, 1000 ether);

        vm.expectEmit(true, false, false, true);
        emit AnchorClubSeason2.VeMaxiCreditsRedeemed(user1, 2000 ether, 1);

        vm.prank(user1);
        season2.redeemVeMaxiCredits(2000 ether);

        assertEq(season2.veMaxiSpentCredits(user1), 2000 ether);
    }

    function test_RevertWhen_RedeemVeMaxiCredits_InsufficientCredits() public {
        veMaxiConduit.setTotalFlexLocked(user1, 100 ether); // 400 credits

        vm.prank(user1);
        vm.expectRevert(AnchorClubSeason2.InsufficientCredits.selector);
        season2.redeemVeMaxiCredits(500 ether);
    }

    function test_RevertWhen_RedeemVeMaxiCredits_ZeroAmount() public {
        vm.prank(user1);
        vm.expectRevert(AnchorClubSeason2.InvalidAmount.selector);
        season2.redeemVeMaxiCredits(0);
    }

    function testRedeemCombinedCredits() public {
        liquidConduit1.setCumulativeOptionsClaimed(user1, 1000 ether); // 1500 credits
        veMaxiConduit.setTotalFlexLocked(user1, 1000 ether); // 4000 credits

        vm.expectEmit(true, false, false, true);
        emit AnchorClubSeason2.LiquidConduitCreditsRedeemed(user1, 500 ether, 1);
        vm.expectEmit(true, false, false, true);
        emit AnchorClubSeason2.VeMaxiCreditsRedeemed(user1, 1000 ether, 2);

        vm.prank(user1);
        season2.redeemCombinedCredits(500 ether, 1000 ether);

        assertEq(season2.liquidSpentCredits(user1), 500 ether);
        assertEq(season2.veMaxiSpentCredits(user1), 1000 ether);
    }

    function testRedeemCombinedCredits_LiquidOnly() public {
        liquidConduit1.setCumulativeOptionsClaimed(user1, 1000 ether);

        vm.prank(user1);
        season2.redeemCombinedCredits(500 ether, 0);

        assertEq(season2.liquidSpentCredits(user1), 500 ether);
        assertEq(season2.veMaxiSpentCredits(user1), 0);
    }

    function testRedeemCombinedCredits_VeMaxiOnly() public {
        veMaxiConduit.setTotalFlexLocked(user1, 1000 ether);

        vm.prank(user1);
        season2.redeemCombinedCredits(0, 1000 ether);

        assertEq(season2.liquidSpentCredits(user1), 0);
        assertEq(season2.veMaxiSpentCredits(user1), 1000 ether);
    }

    function test_RevertWhen_RedeemCombinedCredits_BothZero() public {
        vm.prank(user1);
        vm.expectRevert(AnchorClubSeason2.InvalidAmount.selector);
        season2.redeemCombinedCredits(0, 0);
    }

    /*
     * Admin Functions Tests
     */

    function testSetLiquidAccountMultiplier() public {
        vm.expectEmit(false, false, false, true);
        emit AnchorClubSeason2.LiquidAccountMultiplierUpdated(15000, 20000);

        vm.prank(admin);
        season2.setLiquidAccountMultiplier(20000);

        assertEq(season2.liquidAccountMultiplier(), 20000);
    }

    function testSetSeason1Snapshot() public {
        MockLiquidConduit newSnapshot = new MockLiquidConduit();

        vm.expectEmit(true, true, false, false);
        emit AnchorClubSeason2.Season1SnapshotUpdated(address(season1Snapshot), address(newSnapshot));

        vm.prank(admin);
        season2.setSeason1Snapshot(ILiquidConduit(address(newSnapshot)));

        assertEq(address(season2.season1Snapshot()), address(newSnapshot));
    }

    function test_RevertWhen_SetSeason1Snapshot_ZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(AnchorClubSeason2.InvalidAddress.selector);
        season2.setSeason1Snapshot(ILiquidConduit(address(0)));
    }

    function testAddLiquidConduits() public {
        MockLiquidConduit newConduit = new MockLiquidConduit();

        ILiquidConduit[] memory conduits = new ILiquidConduit[](1);
        conduits[0] = ILiquidConduit(address(newConduit));

        vm.expectEmit(true, false, false, false);
        emit AnchorClubSeason2.LiquidConduitAdded(address(newConduit));

        vm.prank(admin);
        season2.addLiquidConduits(conduits);

        assertTrue(season2.isLiquidConduit(address(newConduit)));
    }

    function test_RevertWhen_AddLiquidConduits_Duplicate() public {
        ILiquidConduit[] memory conduits = new ILiquidConduit[](1);
        conduits[0] = ILiquidConduit(address(liquidConduit1));

        vm.prank(admin);
        vm.expectRevert(AnchorClubSeason2.DuplicateConduit.selector);
        season2.addLiquidConduits(conduits);
    }

    function test_RevertWhen_AddLiquidConduits_ZeroAddress() public {
        ILiquidConduit[] memory conduits = new ILiquidConduit[](1);
        conduits[0] = ILiquidConduit(address(0));

        vm.prank(admin);
        vm.expectRevert(AnchorClubSeason2.InvalidAddress.selector);
        season2.addLiquidConduits(conduits);
    }

    function testRemoveLiquidConduits() public {
        ILiquidConduit[] memory conduits = new ILiquidConduit[](1);
        conduits[0] = ILiquidConduit(address(liquidConduit1));

        vm.expectEmit(true, false, false, false);
        emit AnchorClubSeason2.LiquidConduitRemoved(address(liquidConduit1));

        vm.prank(admin);
        season2.removeLiquidConduits(conduits);

        assertFalse(season2.isLiquidConduit(address(liquidConduit1)));
    }

    function test_RevertWhen_RemoveLiquidConduits_NotFound() public {
        MockLiquidConduit nonExistent = new MockLiquidConduit();

        ILiquidConduit[] memory conduits = new ILiquidConduit[](1);
        conduits[0] = ILiquidConduit(address(nonExistent));

        vm.prank(admin);
        vm.expectRevert(AnchorClubSeason2.ConduitNotFound.selector);
        season2.removeLiquidConduits(conduits);
    }

    function testSetVeMaxiMultiplier() public {
        vm.expectEmit(false, false, false, true);
        emit AnchorClubSeason2.VeMaxiMultiplierUpdated(40000, 50000);

        vm.prank(admin);
        season2.setVeMaxiMultiplier(50000);

        assertEq(season2.veMaxiMultiplier(), 50000);
    }

    function testSetVeMaxiConduit() public {
        MockVeMaxiConduit newConduit = new MockVeMaxiConduit();

        vm.expectEmit(true, true, false, false);
        emit AnchorClubSeason2.VeMaxiConduitUpdated(address(veMaxiConduit), address(newConduit));

        vm.prank(admin);
        season2.setVeMaxiConduit(VeMaxiTokenConduit(payable(address(newConduit))));

        assertEq(address(season2.veMaxiConduit()), address(newConduit));
    }

    function test_RevertWhen_SetVeMaxiConduit_ZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(AnchorClubSeason2.InvalidAddress.selector);
        season2.setVeMaxiConduit(VeMaxiTokenConduit(payable(address(0))));
    }

    function testEmergencyRecover() public {
        MockERC20 token = new MockERC20();
        
        // Fund the Season 2 contract with tokens
        token.mint(address(season2), 1000 ether);
        assertEq(token.balanceOf(address(season2)), 1000 ether);
        assertEq(token.balanceOf(user1), 0);

        // Admin recovers tokens to user1
        vm.prank(admin);
        season2.emergencyRecover(address(token), 500 ether, user1);

        // Verify transfer
        assertEq(token.balanceOf(address(season2)), 500 ether);
        assertEq(token.balanceOf(user1), 500 ether);
    }

    function test_RevertWhen_EmergencyRecover_ZeroToken() public {
        vm.prank(admin);
        vm.expectRevert(AnchorClubSeason2.InvalidAddress.selector);
        season2.emergencyRecover(address(0), 100 ether, user1);
    }

    function test_RevertWhen_EmergencyRecover_ZeroRecipient() public {
        vm.prank(admin);
        vm.expectRevert(AnchorClubSeason2.InvalidAddress.selector);
        season2.emergencyRecover(address(optionsToken), 100 ether, address(0));
    }

    function test_RevertWhen_EmergencyRecover_ZeroAmount() public {
        vm.prank(admin);
        vm.expectRevert(AnchorClubSeason2.InvalidAmount.selector);
        season2.emergencyRecover(address(optionsToken), 0, user1);
    }

    /*
     * Access Control Tests
     */

    function test_RevertWhen_NonAdmin_SetLiquidAccountMultiplier() public {
        vm.prank(user1);
        vm.expectRevert();
        season2.setLiquidAccountMultiplier(20000);
    }

    function test_RevertWhen_NonAdmin_AddLiquidConduits() public {
        ILiquidConduit[] memory conduits = new ILiquidConduit[](0);

        vm.prank(user1);
        vm.expectRevert();
        season2.addLiquidConduits(conduits);
    }

    function test_RevertWhen_NonAdmin_RemoveLiquidConduits() public {
        ILiquidConduit[] memory conduits = new ILiquidConduit[](0);

        vm.prank(user1);
        vm.expectRevert();
        season2.removeLiquidConduits(conduits);
    }

    function test_RevertWhen_NonAdmin_SetVeMaxiMultiplier() public {
        vm.prank(user1);
        vm.expectRevert();
        season2.setVeMaxiMultiplier(50000);
    }

    function test_RevertWhen_NonAdmin_SetVeMaxiConduit() public {
        vm.prank(user1);
        vm.expectRevert();
        season2.setVeMaxiConduit(VeMaxiTokenConduit(payable(address(veMaxiConduit))));
    }

    function test_RevertWhen_NonAdmin_EmergencyRecover() public {
        vm.prank(user1);
        vm.expectRevert();
        season2.emergencyRecover(address(optionsToken), 100 ether, user1);
    }

    /*
     * Integration Tests
     */

    function testMultipleUsersMultipleRedemptions() public {
        // Setup user1
        liquidConduit1.setCumulativeOptionsClaimed(user1, 1000 ether);
        veMaxiConduit.setTotalFlexLocked(user1, 500 ether);

        // Setup user2
        liquidConduit2.setCumulativeOptionsClaimed(user2, 2000 ether);
        veMaxiConduit.setTotalProtocolLocked(user2, 1000 ether);

        // User1 redeems
        vm.prank(user1);
        season2.redeemCombinedCredits(500 ether, 1000 ether);

        // User2 redeems
        vm.prank(user2);
        season2.redeemCombinedCredits(1000 ether, 2000 ether);

        // Verify user1
        assertEq(season2.liquidSpentCredits(user1), 500 ether);
        assertEq(season2.veMaxiSpentCredits(user1), 1000 ether);

        // Verify user2
        assertEq(season2.liquidSpentCredits(user2), 1000 ether);
        assertEq(season2.veMaxiSpentCredits(user2), 2000 ether);
    }

    function testMultiplierChangesAffectCredits() public {
        liquidConduit1.setCumulativeOptionsClaimed(user1, 1000 ether);

        // Initial: 1000 * 15000 / 10000 = 1500
        uint256 creditsBefore = season2.calculateSeason2LiquidCredits(user1);
        assertEq(creditsBefore, 1500 ether);

        // Change multiplier to 2x
        vm.prank(admin);
        season2.setLiquidAccountMultiplier(20000);

        // New: 1000 * 20000 / 10000 = 2000
        uint256 creditsAfter = season2.calculateSeason2LiquidCredits(user1);
        assertEq(creditsAfter, 2000 ether);
    }
}

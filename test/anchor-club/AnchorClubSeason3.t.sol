// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {AnchorClubSeason3} from "../../contracts/anchor-club/AnchorClubSeason3.sol";
import {AnchorClubSeason2Snapshot} from "../../contracts/anchor-club/AnchorClubSeason2Snapshot.sol";
import {AnchorClubSeason2VeMaxiSnapshot} from "../../contracts/anchor-club/AnchorClubSeason2VeMaxiSnapshot.sol";
import {IOptionsToken} from "../../contracts/interfaces/IOptionsToken.sol";
import {ILiquidConduit} from "../../contracts/interfaces/ILiquidConduit.sol";
import {IVeMaxiBalances} from "../../contracts/interfaces/IVeMaxiBalances.sol";

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

contract AnchorClubSeason3Test is Test {
    AnchorClubSeason3 public season3;
    MockOptionsToken public optionsToken;
    MockLiquidConduit public season2Snapshot;
    MockLiquidConduit public liquidConduit1;
    MockLiquidConduit public liquidConduit2;
    MockVeMaxiConduit public veMaxiConduit;
    MockVeMaxiConduit public veMaxiSeason2Snapshot;

    address public admin;
    address public user1;
    address public user2;
    address public user3;

    function setUp() public {
        admin = makeAddr("admin");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        optionsToken = new MockOptionsToken();
        season2Snapshot = new MockLiquidConduit();
        liquidConduit1 = new MockLiquidConduit();
        liquidConduit2 = new MockLiquidConduit();
        veMaxiConduit = new MockVeMaxiConduit();
        veMaxiSeason2Snapshot = new MockVeMaxiConduit();

        vm.prank(admin);
        season3 = new AnchorClubSeason3(
            IOptionsToken(address(optionsToken)),
            ILiquidConduit(address(season2Snapshot)),
            IVeMaxiBalances(address(veMaxiConduit)),
            IVeMaxiBalances(address(veMaxiSeason2Snapshot)),
            admin
        );

        ILiquidConduit[] memory conduits = new ILiquidConduit[](2);
        conduits[0] = ILiquidConduit(address(liquidConduit1));
        conduits[1] = ILiquidConduit(address(liquidConduit2));

        vm.prank(admin);
        season3.addLiquidConduits(conduits);
    }

    /*
     * Initial State Tests
     */

    function testInitialState() public view {
        assertEq(season3.liquidAccountMultiplier(), 7500); // 0.75x
        assertEq(season3.veMaxiMultiplier(), 20000); // 2.0x
        assertTrue(season3.hasRole(season3.DEFAULT_ADMIN_ROLE(), admin));
        assertEq(address(season3.optionsToken()), address(optionsToken));
        assertEq(address(season3.season2Snapshot()), address(season2Snapshot));
        assertEq(address(season3.veMaxiConduit()), address(veMaxiConduit));
        assertEq(address(season3.veMaxiSeason2Snapshot()), address(veMaxiSeason2Snapshot));
    }

    function testLiquidConduitsAdded() public view {
        assertTrue(season3.isLiquidConduit(address(liquidConduit1)));
        assertTrue(season3.isLiquidConduit(address(liquidConduit2)));
        ILiquidConduit[] memory conduits = season3.getLiquidConduits();
        assertEq(conduits.length, 2);
    }

    function test_RevertWhen_Constructor_ZeroOptionsToken() public {
        vm.expectRevert(AnchorClubSeason3.InvalidAddress.selector);
        new AnchorClubSeason3(
            IOptionsToken(address(0)),
            ILiquidConduit(address(season2Snapshot)),
            IVeMaxiBalances(address(veMaxiConduit)),
            IVeMaxiBalances(address(veMaxiSeason2Snapshot)),
            admin
        );
    }

    function test_RevertWhen_Constructor_ZeroSeason2Snapshot() public {
        vm.expectRevert(AnchorClubSeason3.InvalidAddress.selector);
        new AnchorClubSeason3(
            IOptionsToken(address(optionsToken)),
            ILiquidConduit(address(0)),
            IVeMaxiBalances(address(veMaxiConduit)),
            IVeMaxiBalances(address(veMaxiSeason2Snapshot)),
            admin
        );
    }

    function test_RevertWhen_Constructor_ZeroVeMaxiConduit() public {
        vm.expectRevert(AnchorClubSeason3.InvalidAddress.selector);
        new AnchorClubSeason3(
            IOptionsToken(address(optionsToken)),
            ILiquidConduit(address(season2Snapshot)),
            IVeMaxiBalances(address(0)),
            IVeMaxiBalances(address(veMaxiSeason2Snapshot)),
            admin
        );
    }

    function test_RevertWhen_Constructor_ZeroVeMaxiSnapshot() public {
        vm.expectRevert(AnchorClubSeason3.InvalidAddress.selector);
        new AnchorClubSeason3(
            IOptionsToken(address(optionsToken)),
            ILiquidConduit(address(season2Snapshot)),
            IVeMaxiBalances(address(veMaxiConduit)),
            IVeMaxiBalances(address(0)),
            admin
        );
    }

    function test_RevertWhen_Constructor_ZeroAdmin() public {
        vm.expectRevert(AnchorClubSeason3.InvalidAddress.selector);
        new AnchorClubSeason3(
            IOptionsToken(address(optionsToken)),
            ILiquidConduit(address(season2Snapshot)),
            IVeMaxiBalances(address(veMaxiConduit)),
            IVeMaxiBalances(address(veMaxiSeason2Snapshot)),
            address(0)
        );
    }

    /*
     * Liquid Credits Tests
     */

    function testCalculateSeason3LiquidCredits_NoSeason2Claims() public {
        // User has 1000 in current conduits, 0 in Season 2 snapshot
        liquidConduit1.setCumulativeOptionsClaimed(user1, 600 ether);
        liquidConduit2.setCumulativeOptionsClaimed(user1, 400 ether);

        // Credits = (1000 - 0) * 7500 / 10000 = 750
        uint256 credits = season3.calculateSeason3LiquidCredits(user1);
        assertEq(credits, 750 ether);
    }

    function testCalculateSeason3LiquidCredits_WithSeason2Claims() public {
        // Season 2 end: user had 500 total
        season2Snapshot.setCumulativeOptionsClaimed(user1, 500 ether);

        // Current: user has 1200 total
        liquidConduit1.setCumulativeOptionsClaimed(user1, 700 ether);
        liquidConduit2.setCumulativeOptionsClaimed(user1, 500 ether);

        // Season 3 credits = (1200 - 500) * 7500 / 10000 = 525
        uint256 credits = season3.calculateSeason3LiquidCredits(user1);
        assertEq(credits, 525 ether);
    }

    function testCalculateSeason3LiquidCredits_CurrentLessThanSeason2() public {
        // Edge case: shouldn't happen but handle gracefully
        season2Snapshot.setCumulativeOptionsClaimed(user1, 1000 ether);
        liquidConduit1.setCumulativeOptionsClaimed(user1, 500 ether);

        uint256 credits = season3.calculateSeason3LiquidCredits(user1);
        assertEq(credits, 0);
    }

    function testCalculateSeason3LiquidRemainingCredits() public {
        liquidConduit1.setCumulativeOptionsClaimed(user1, 1000 ether);

        // Total credits = 750
        uint256 totalCredits = season3.calculateSeason3LiquidCredits(user1);
        assertEq(totalCredits, 750 ether);

        // Spend 250
        vm.prank(user1);
        season3.redeemLiquidCredits(250 ether);

        // Remaining = 500
        uint256 remaining = season3.calculateSeason3LiquidRemainingCredits(user1);
        assertEq(remaining, 500 ether);
        assertEq(season3.liquidSpentCredits(user1), 250 ether);
    }

    /*
     * VeMaxi Credits Tests
     */

    function testCalculateVeMaxiCredits_NoBaseline_FlexOnly() public {
        veMaxiConduit.setTotalFlexLocked(user1, 1000 ether);

        // Credits = (1000 - 0) * 20000 / 10000 = 2000
        uint256 credits = season3.calculateVeMaxiCredits(user1);
        assertEq(credits, 2000 ether);
    }

    function testCalculateVeMaxiCredits_NoBaseline_ProtocolOnly() public {
        veMaxiConduit.setTotalProtocolLocked(user1, 500 ether);

        // Credits = (500 - 0) * 20000 / 10000 = 1000
        uint256 credits = season3.calculateVeMaxiCredits(user1);
        assertEq(credits, 1000 ether);
    }

    function testCalculateVeMaxiCredits_WithBaseline() public {
        // Season 2 baseline: 400 flex + 200 protocol = 600
        veMaxiSeason2Snapshot.setTotalFlexLocked(user1, 400 ether);
        veMaxiSeason2Snapshot.setTotalProtocolLocked(user1, 200 ether);

        // Live: 1000 flex + 500 protocol = 1500
        veMaxiConduit.setTotalFlexLocked(user1, 1000 ether);
        veMaxiConduit.setTotalProtocolLocked(user1, 500 ether);

        // Credits = (1500 - 600) * 20000 / 10000 = 1800
        uint256 credits = season3.calculateVeMaxiCredits(user1);
        assertEq(credits, 1800 ether);
    }

    function testCalculateVeMaxiCredits_LiveLessThanBaseline() public {
        // Edge case: shouldn't happen but handle gracefully (live counters only ever grow)
        veMaxiSeason2Snapshot.setTotalFlexLocked(user1, 1000 ether);
        veMaxiConduit.setTotalFlexLocked(user1, 500 ether);

        uint256 credits = season3.calculateVeMaxiCredits(user1);
        assertEq(credits, 0);
    }

    function testCalculateVeMaxiRemainingCredits() public {
        veMaxiSeason2Snapshot.setTotalFlexLocked(user1, 200 ether);
        veMaxiConduit.setTotalFlexLocked(user1, 1000 ether);
        veMaxiConduit.setTotalProtocolLocked(user1, 500 ether);

        // Earned = (1500 - 200) * 2 = 2600
        uint256 totalCredits = season3.calculateVeMaxiCredits(user1);
        assertEq(totalCredits, 2600 ether);

        vm.prank(user1);
        season3.redeemVeMaxiCredits(1000 ether);

        // Remaining = 2600 - 1000 = 1600
        uint256 remaining = season3.calculateVeMaxiRemainingCredits(user1);
        assertEq(remaining, 1600 ether);
        assertEq(season3.veMaxiSpentCredits(user1), 1000 ether);
    }

    /*
     * Combined Credits Tests
     */

    function testCalculateTotalCredits() public {
        // Liquid: 1000 current, 200 Season 2 = 800 new * 0.75 = 600
        season2Snapshot.setCumulativeOptionsClaimed(user1, 200 ether);
        liquidConduit1.setCumulativeOptionsClaimed(user1, 600 ether);
        liquidConduit2.setCumulativeOptionsClaimed(user1, 400 ether);

        // VeMaxi: live 500 flex + 300 protocol = 800; baseline 100 flex + 100 protocol = 200
        // (800 - 200) * 2 = 1200
        veMaxiSeason2Snapshot.setTotalFlexLocked(user1, 100 ether);
        veMaxiSeason2Snapshot.setTotalProtocolLocked(user1, 100 ether);
        veMaxiConduit.setTotalFlexLocked(user1, 500 ether);
        veMaxiConduit.setTotalProtocolLocked(user1, 300 ether);

        // Total = 600 + 1200 = 1800
        uint256 totalCredits = season3.calculateTotalCredits(user1);
        assertEq(totalCredits, 1800 ether);
    }

    function testCalculateTotalRemainingCredits() public {
        liquidConduit1.setCumulativeOptionsClaimed(user1, 1000 ether); // 750 credits
        veMaxiConduit.setTotalFlexLocked(user1, 1000 ether); // 2000 credits

        // Total = 2750
        uint256 totalCredits = season3.calculateTotalCredits(user1);
        assertEq(totalCredits, 2750 ether);

        vm.startPrank(user1);
        season3.redeemLiquidCredits(500 ether);
        season3.redeemVeMaxiCredits(1000 ether);
        vm.stopPrank();

        // Remaining = (750 - 500) + (2000 - 1000) = 1250
        uint256 remaining = season3.calculateTotalRemainingCredits(user1);
        assertEq(remaining, 1250 ether);
    }

    /*
     * Redemption Tests
     */

    function testRedeemLiquidCredits() public {
        liquidConduit1.setCumulativeOptionsClaimed(user1, 1000 ether);

        vm.expectEmit(true, false, false, true);
        emit AnchorClubSeason3.LiquidConduitCreditsRedeemed(user1, 500 ether, 1);

        vm.prank(user1);
        season3.redeemLiquidCredits(500 ether);

        assertEq(season3.liquidSpentCredits(user1), 500 ether);
    }

    function test_RevertWhen_RedeemLiquidCredits_InsufficientCredits() public {
        liquidConduit1.setCumulativeOptionsClaimed(user1, 100 ether); // 75 credits

        vm.prank(user1);
        vm.expectRevert(AnchorClubSeason3.InsufficientCredits.selector);
        season3.redeemLiquidCredits(100 ether);
    }

    function test_RevertWhen_RedeemLiquidCredits_ZeroAmount() public {
        vm.prank(user1);
        vm.expectRevert(AnchorClubSeason3.InvalidAmount.selector);
        season3.redeemLiquidCredits(0);
    }

    function testRedeemVeMaxiCredits() public {
        veMaxiConduit.setTotalFlexLocked(user1, 1000 ether);

        vm.expectEmit(true, false, false, true);
        emit AnchorClubSeason3.VeMaxiCreditsRedeemed(user1, 1000 ether, 1);

        vm.prank(user1);
        season3.redeemVeMaxiCredits(1000 ether);

        assertEq(season3.veMaxiSpentCredits(user1), 1000 ether);
    }

    function test_RevertWhen_RedeemVeMaxiCredits_InsufficientCredits() public {
        veMaxiConduit.setTotalFlexLocked(user1, 100 ether); // 200 credits

        vm.prank(user1);
        vm.expectRevert(AnchorClubSeason3.InsufficientCredits.selector);
        season3.redeemVeMaxiCredits(500 ether);
    }

    function test_RevertWhen_RedeemVeMaxiCredits_ZeroAmount() public {
        vm.prank(user1);
        vm.expectRevert(AnchorClubSeason3.InvalidAmount.selector);
        season3.redeemVeMaxiCredits(0);
    }

    function testRedeemCombinedCredits() public {
        liquidConduit1.setCumulativeOptionsClaimed(user1, 1000 ether); // 750 credits
        veMaxiConduit.setTotalFlexLocked(user1, 1000 ether); // 2000 credits

        // Both events should reference the same nftId — one combined veNFT
        vm.expectEmit(true, false, false, true);
        emit AnchorClubSeason3.LiquidConduitCreditsRedeemed(user1, 250 ether, 1);
        vm.expectEmit(true, false, false, true);
        emit AnchorClubSeason3.VeMaxiCreditsRedeemed(user1, 500 ether, 1);

        vm.prank(user1);
        season3.redeemCombinedCredits(250 ether, 500 ether);

        assertEq(season3.liquidSpentCredits(user1), 250 ether);
        assertEq(season3.veMaxiSpentCredits(user1), 500 ether);
    }

    function testRedeemCombinedCredits_LiquidOnly() public {
        liquidConduit1.setCumulativeOptionsClaimed(user1, 1000 ether);

        vm.prank(user1);
        season3.redeemCombinedCredits(250 ether, 0);

        assertEq(season3.liquidSpentCredits(user1), 250 ether);
        assertEq(season3.veMaxiSpentCredits(user1), 0);
    }

    function testRedeemCombinedCredits_VeMaxiOnly() public {
        veMaxiConduit.setTotalFlexLocked(user1, 1000 ether);

        vm.prank(user1);
        season3.redeemCombinedCredits(0, 500 ether);

        assertEq(season3.liquidSpentCredits(user1), 0);
        assertEq(season3.veMaxiSpentCredits(user1), 500 ether);
    }

    function test_RevertWhen_RedeemCombinedCredits_BothZero() public {
        vm.prank(user1);
        vm.expectRevert(AnchorClubSeason3.InvalidAmount.selector);
        season3.redeemCombinedCredits(0, 0);
    }

    /*
     * Admin Functions Tests
     */

    function testSetLiquidAccountMultiplier() public {
        vm.expectEmit(false, false, false, true);
        emit AnchorClubSeason3.LiquidAccountMultiplierUpdated(7500, 10000);

        vm.prank(admin);
        season3.setLiquidAccountMultiplier(10000);

        assertEq(season3.liquidAccountMultiplier(), 10000);
    }

    function testSetSeason2Snapshot() public {
        MockLiquidConduit newSnapshot = new MockLiquidConduit();

        vm.expectEmit(true, true, false, false);
        emit AnchorClubSeason3.Season2SnapshotUpdated(address(season2Snapshot), address(newSnapshot));

        vm.prank(admin);
        season3.setSeason2Snapshot(ILiquidConduit(address(newSnapshot)));

        assertEq(address(season3.season2Snapshot()), address(newSnapshot));
    }

    function test_RevertWhen_SetSeason2Snapshot_ZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(AnchorClubSeason3.InvalidAddress.selector);
        season3.setSeason2Snapshot(ILiquidConduit(address(0)));
    }

    function testAddLiquidConduits() public {
        MockLiquidConduit newConduit = new MockLiquidConduit();

        ILiquidConduit[] memory conduits = new ILiquidConduit[](1);
        conduits[0] = ILiquidConduit(address(newConduit));

        vm.expectEmit(true, false, false, false);
        emit AnchorClubSeason3.LiquidConduitAdded(address(newConduit));

        vm.prank(admin);
        season3.addLiquidConduits(conduits);

        assertTrue(season3.isLiquidConduit(address(newConduit)));
    }

    function test_RevertWhen_AddLiquidConduits_Duplicate() public {
        ILiquidConduit[] memory conduits = new ILiquidConduit[](1);
        conduits[0] = ILiquidConduit(address(liquidConduit1));

        vm.prank(admin);
        vm.expectRevert(AnchorClubSeason3.DuplicateConduit.selector);
        season3.addLiquidConduits(conduits);
    }

    function test_RevertWhen_AddLiquidConduits_ZeroAddress() public {
        ILiquidConduit[] memory conduits = new ILiquidConduit[](1);
        conduits[0] = ILiquidConduit(address(0));

        vm.prank(admin);
        vm.expectRevert(AnchorClubSeason3.InvalidAddress.selector);
        season3.addLiquidConduits(conduits);
    }

    function testRemoveLiquidConduits() public {
        ILiquidConduit[] memory conduits = new ILiquidConduit[](1);
        conduits[0] = ILiquidConduit(address(liquidConduit1));

        vm.expectEmit(true, false, false, false);
        emit AnchorClubSeason3.LiquidConduitRemoved(address(liquidConduit1));

        vm.prank(admin);
        season3.removeLiquidConduits(conduits);

        assertFalse(season3.isLiquidConduit(address(liquidConduit1)));
    }

    function test_RevertWhen_RemoveLiquidConduits_NotFound() public {
        MockLiquidConduit nonExistent = new MockLiquidConduit();

        ILiquidConduit[] memory conduits = new ILiquidConduit[](1);
        conduits[0] = ILiquidConduit(address(nonExistent));

        vm.prank(admin);
        vm.expectRevert(AnchorClubSeason3.ConduitNotFound.selector);
        season3.removeLiquidConduits(conduits);
    }

    function testSetVeMaxiMultiplier() public {
        vm.expectEmit(false, false, false, true);
        emit AnchorClubSeason3.VeMaxiMultiplierUpdated(20000, 25000);

        vm.prank(admin);
        season3.setVeMaxiMultiplier(25000);

        assertEq(season3.veMaxiMultiplier(), 25000);
    }

    function testSetVeMaxiConduit() public {
        MockVeMaxiConduit newConduit = new MockVeMaxiConduit();

        vm.expectEmit(true, true, false, false);
        emit AnchorClubSeason3.VeMaxiConduitUpdated(address(veMaxiConduit), address(newConduit));

        vm.prank(admin);
        season3.setVeMaxiConduit(IVeMaxiBalances(address(newConduit)));

        assertEq(address(season3.veMaxiConduit()), address(newConduit));
    }

    function test_RevertWhen_SetVeMaxiConduit_ZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(AnchorClubSeason3.InvalidAddress.selector);
        season3.setVeMaxiConduit(IVeMaxiBalances(address(0)));
    }

    function testSetVeMaxiSeason2Snapshot() public {
        MockVeMaxiConduit newSnapshot = new MockVeMaxiConduit();

        vm.expectEmit(true, true, false, false);
        emit AnchorClubSeason3.VeMaxiSeason2SnapshotUpdated(address(veMaxiSeason2Snapshot), address(newSnapshot));

        vm.prank(admin);
        season3.setVeMaxiSeason2Snapshot(IVeMaxiBalances(address(newSnapshot)));

        assertEq(address(season3.veMaxiSeason2Snapshot()), address(newSnapshot));
    }

    function test_RevertWhen_SetVeMaxiSeason2Snapshot_ZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(AnchorClubSeason3.InvalidAddress.selector);
        season3.setVeMaxiSeason2Snapshot(IVeMaxiBalances(address(0)));
    }

    function testEmergencyRecover() public {
        MockERC20 token = new MockERC20();

        token.mint(address(season3), 1000 ether);
        assertEq(token.balanceOf(address(season3)), 1000 ether);
        assertEq(token.balanceOf(user1), 0);

        vm.prank(admin);
        season3.emergencyRecover(address(token), 500 ether, user1);

        assertEq(token.balanceOf(address(season3)), 500 ether);
        assertEq(token.balanceOf(user1), 500 ether);
    }

    function test_RevertWhen_EmergencyRecover_ZeroToken() public {
        vm.prank(admin);
        vm.expectRevert(AnchorClubSeason3.InvalidAddress.selector);
        season3.emergencyRecover(address(0), 100 ether, user1);
    }

    function test_RevertWhen_EmergencyRecover_ZeroRecipient() public {
        vm.prank(admin);
        vm.expectRevert(AnchorClubSeason3.InvalidAddress.selector);
        season3.emergencyRecover(address(optionsToken), 100 ether, address(0));
    }

    function test_RevertWhen_EmergencyRecover_ZeroAmount() public {
        vm.prank(admin);
        vm.expectRevert(AnchorClubSeason3.InvalidAmount.selector);
        season3.emergencyRecover(address(optionsToken), 0, user1);
    }

    /*
     * Access Control Tests
     */

    function test_RevertWhen_NonAdmin_SetLiquidAccountMultiplier() public {
        vm.prank(user1);
        vm.expectRevert();
        season3.setLiquidAccountMultiplier(10000);
    }

    function test_RevertWhen_NonAdmin_AddLiquidConduits() public {
        ILiquidConduit[] memory conduits = new ILiquidConduit[](0);

        vm.prank(user1);
        vm.expectRevert();
        season3.addLiquidConduits(conduits);
    }

    function test_RevertWhen_NonAdmin_RemoveLiquidConduits() public {
        ILiquidConduit[] memory conduits = new ILiquidConduit[](0);

        vm.prank(user1);
        vm.expectRevert();
        season3.removeLiquidConduits(conduits);
    }

    function test_RevertWhen_NonAdmin_SetVeMaxiMultiplier() public {
        vm.prank(user1);
        vm.expectRevert();
        season3.setVeMaxiMultiplier(25000);
    }

    function test_RevertWhen_NonAdmin_SetVeMaxiConduit() public {
        vm.prank(user1);
        vm.expectRevert();
        season3.setVeMaxiConduit(IVeMaxiBalances(address(veMaxiConduit)));
    }

    function test_RevertWhen_NonAdmin_SetVeMaxiSeason2Snapshot() public {
        vm.prank(user1);
        vm.expectRevert();
        season3.setVeMaxiSeason2Snapshot(IVeMaxiBalances(address(veMaxiSeason2Snapshot)));
    }

    function test_RevertWhen_NonAdmin_EmergencyRecover() public {
        vm.prank(user1);
        vm.expectRevert();
        season3.emergencyRecover(address(optionsToken), 100 ether, user1);
    }

    /*
     * Integration Tests
     */

    function testMultipleUsersMultipleRedemptions() public {
        // User1: liquid 1000, baseline 0 -> 750 credits; flex 500, baseline 0 -> 1000 credits
        liquidConduit1.setCumulativeOptionsClaimed(user1, 1000 ether);
        veMaxiConduit.setTotalFlexLocked(user1, 500 ether);

        // User2: liquid 2000, baseline 500 -> 1500*0.75 = 1125; protocol 1000, baseline 200 -> 800*2 = 1600
        season2Snapshot.setCumulativeOptionsClaimed(user2, 500 ether);
        liquidConduit2.setCumulativeOptionsClaimed(user2, 2000 ether);
        veMaxiSeason2Snapshot.setTotalProtocolLocked(user2, 200 ether);
        veMaxiConduit.setTotalProtocolLocked(user2, 1000 ether);

        vm.prank(user1);
        season3.redeemCombinedCredits(250 ether, 500 ether);

        vm.prank(user2);
        season3.redeemCombinedCredits(500 ether, 1000 ether);

        assertEq(season3.liquidSpentCredits(user1), 250 ether);
        assertEq(season3.veMaxiSpentCredits(user1), 500 ether);
        assertEq(season3.liquidSpentCredits(user2), 500 ether);
        assertEq(season3.veMaxiSpentCredits(user2), 1000 ether);
    }

    function testMultiplierChangesAffectCredits() public {
        liquidConduit1.setCumulativeOptionsClaimed(user1, 1000 ether);

        // Initial: 1000 * 7500 / 10000 = 750
        uint256 creditsBefore = season3.calculateSeason3LiquidCredits(user1);
        assertEq(creditsBefore, 750 ether);

        vm.prank(admin);
        season3.setLiquidAccountMultiplier(10000);

        // After: 1000 * 10000 / 10000 = 1000
        uint256 creditsAfter = season3.calculateSeason3LiquidCredits(user1);
        assertEq(creditsAfter, 1000 ether);
    }

    /// @dev Confirms the underflow-safety upgrade: lowering the multiplier after a user has
    ///      already redeemed must not brick the view functions or downstream redemptions.
    function testRemainingCredits_SafeAfterMultiplierDecrease() public {
        liquidConduit1.setCumulativeOptionsClaimed(user1, 1000 ether);

        // Redeem 600 at 0.75x (earned = 750)
        vm.prank(user1);
        season3.redeemLiquidCredits(600 ether);
        assertEq(season3.liquidSpentCredits(user1), 600 ether);

        // Admin slashes multiplier to 0.5x -> earned drops to 500, but spent is 600
        vm.prank(admin);
        season3.setLiquidAccountMultiplier(5000);

        // Remaining clamps to 0 instead of underflowing
        uint256 remaining = season3.calculateSeason3LiquidRemainingCredits(user1);
        assertEq(remaining, 0);

        // Total remaining view also stays callable
        uint256 totalRemaining = season3.calculateTotalRemainingCredits(user1);
        assertEq(totalRemaining, 0);

        // Further redemption attempts revert cleanly with InsufficientCredits, not arithmetic panic
        vm.prank(user1);
        vm.expectRevert(AnchorClubSeason3.InsufficientCredits.selector);
        season3.redeemLiquidCredits(1);
    }

    function testRemainingCredits_SafeAfterVeMaxiMultiplierDecrease() public {
        veMaxiConduit.setTotalFlexLocked(user1, 1000 ether);

        // Earned at 2.0x = 2000, redeem 1500
        vm.prank(user1);
        season3.redeemVeMaxiCredits(1500 ether);

        // Slash multiplier to 1.0x -> earned drops to 1000
        vm.prank(admin);
        season3.setVeMaxiMultiplier(10000);

        uint256 remaining = season3.calculateVeMaxiRemainingCredits(user1);
        assertEq(remaining, 0);

        vm.prank(user1);
        vm.expectRevert(AnchorClubSeason3.InsufficientCredits.selector);
        season3.redeemVeMaxiCredits(1);
    }
}

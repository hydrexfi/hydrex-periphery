// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AnchorClubSeason3} from "../../contracts/anchor-club/AnchorClubSeason3.sol";
import {AnchorClubSeason3Snapshot} from "../../contracts/anchor-club/AnchorClubSeason3Snapshot.sol";
import {AnchorClubSeason3VeMaxiSnapshot} from "../../contracts/anchor-club/AnchorClubSeason3VeMaxiSnapshot.sol";
import {IOptionsToken} from "../../contracts/interfaces/IOptionsToken.sol";
import {ILiquidConduit} from "../../contracts/interfaces/ILiquidConduit.sol";
import {IVeMaxiBalances} from "../../contracts/interfaces/IVeMaxiBalances.sol";

contract FreezeMockOptionsToken {
    uint256 private nftIdCounter = 1;

    function exerciseVe(uint256, address) external returns (uint256 nftId) {
        return nftIdCounter++;
    }
}

contract FreezeMockLiquidConduit {
    mapping(address => uint256) public cumulativeOptionsClaimed;

    function setCumulativeOptionsClaimed(address user, uint256 amount) external {
        cumulativeOptionsClaimed[user] = amount;
    }
}

contract FreezeMockVeMaxiConduit {
    mapping(address => uint256) public totalFlexLocked;
    mapping(address => uint256) public totalProtocolLocked;

    function setLocked(address user, uint256 flex, uint256 protocolLocked) external {
        totalFlexLocked[user] = flex;
        totalProtocolLocked[user] = protocolLocked;
    }
}

/// @notice Covers winding Season 3 down: snapshot the live sources, repoint Season 3 at them, and
///         verify accrual stops while redemption stays open forever.
contract AnchorClubSeason3FreezeTest is Test {
    AnchorClubSeason3 internal season3;
    FreezeMockOptionsToken internal optionsToken;

    FreezeMockLiquidConduit internal liquid1;
    FreezeMockLiquidConduit internal liquid2;
    FreezeMockLiquidConduit internal liquid3;
    FreezeMockLiquidConduit internal season2Liquid;

    FreezeMockVeMaxiConduit internal veMaxiLive;
    FreezeMockVeMaxiConduit internal season2VeMaxi;

    AnchorClubSeason3Snapshot internal s3Liquid;
    AnchorClubSeason3VeMaxiSnapshot internal s3VeMaxi;

    address internal admin;
    address internal user1;
    address internal user2;

    function setUp() public {
        admin = makeAddr("admin");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        optionsToken = new FreezeMockOptionsToken();
        liquid1 = new FreezeMockLiquidConduit();
        liquid2 = new FreezeMockLiquidConduit();
        liquid3 = new FreezeMockLiquidConduit();
        season2Liquid = new FreezeMockLiquidConduit();
        veMaxiLive = new FreezeMockVeMaxiConduit();
        season2VeMaxi = new FreezeMockVeMaxiConduit();

        season3 = new AnchorClubSeason3(
            IOptionsToken(address(optionsToken)),
            ILiquidConduit(address(season2Liquid)),
            IVeMaxiBalances(address(veMaxiLive)),
            IVeMaxiBalances(address(season2VeMaxi)),
            admin
        );

        ILiquidConduit[] memory live = new ILiquidConduit[](3);
        live[0] = ILiquidConduit(address(liquid1));
        live[1] = ILiquidConduit(address(liquid2));
        live[2] = ILiquidConduit(address(liquid3));
        vm.prank(admin);
        season3.addLiquidConduits(live);

        s3Liquid = new AnchorClubSeason3Snapshot(admin);
        s3VeMaxi = new AnchorClubSeason3VeMaxiSnapshot(admin);

        // Season 2 baselines already frozen on-chain.
        season2Liquid.setCumulativeOptionsClaimed(user1, 400e18);
        season2VeMaxi.setLocked(user1, 100e18, 50e18);

        // Season 3 accrual on top of those baselines.
        liquid1.setCumulativeOptionsClaimed(user1, 500e18);
        liquid2.setCumulativeOptionsClaimed(user1, 300e18);
        liquid3.setCumulativeOptionsClaimed(user1, 200e18);
        veMaxiLive.setLocked(user1, 400e18, 150e18);
    }

    /*
     * Helpers
     */

    function _liveConduits() internal view returns (ILiquidConduit[] memory conduits) {
        conduits = new ILiquidConduit[](3);
        conduits[0] = ILiquidConduit(address(liquid1));
        conduits[1] = ILiquidConduit(address(liquid2));
        conduits[2] = ILiquidConduit(address(liquid3));
    }

    /// @dev Stands in for the off-chain query script: reads the live sources for a set of users.
    function _readLive(
        address[] memory users
    ) internal view returns (uint256[] memory liquid, uint256[] memory flex, uint256[] memory protocolLocked) {
        liquid = new uint256[](users.length);
        flex = new uint256[](users.length);
        protocolLocked = new uint256[](users.length);
        for (uint256 i = 0; i < users.length; i++) {
            liquid[i] =
                liquid1.cumulativeOptionsClaimed(users[i]) +
                liquid2.cumulativeOptionsClaimed(users[i]) +
                liquid3.cumulativeOptionsClaimed(users[i]);
            flex[i] = veMaxiLive.totalFlexLocked(users[i]);
            protocolLocked[i] = veMaxiLive.totalProtocolLocked(users[i]);
        }
    }

    /// @dev Mirrors the on-chain freeze: snapshot the live values, then repoint Season 3.
    function _snapshotAndFreeze(address[] memory users) internal {
        (uint256[] memory liquid, uint256[] memory flex, uint256[] memory protocolLocked) = _readLive(users);

        vm.startPrank(admin);
        s3Liquid.batchSetSnapshot(users, liquid);
        s3VeMaxi.batchSetSnapshot(users, flex, protocolLocked);

        season3.setVeMaxiConduit(IVeMaxiBalances(address(s3VeMaxi)));

        season3.removeLiquidConduits(_liveConduits());
        ILiquidConduit[] memory frozenSource = new ILiquidConduit[](1);
        frozenSource[0] = ILiquidConduit(address(s3Liquid));
        season3.addLiquidConduits(frozenSource);
        vm.stopPrank();
    }

    function _users() internal view returns (address[] memory users) {
        users = new address[](2);
        users[0] = user1;
        users[1] = user2;
    }

    /*
     * Tests
     */

    function test_creditsUnchangedImmediatelyAfterFreeze() public {
        uint256 liquidBefore = season3.calculateSeason3LiquidCredits(user1);
        uint256 veMaxiBefore = season3.calculateVeMaxiCredits(user1);

        // 1000 total - 400 season 2 = 600 new, at 0.75x
        assertEq(liquidBefore, 450e18);
        // (400+150) - (100+50) = 400 new, at 2.0x
        assertEq(veMaxiBefore, 800e18);

        _snapshotAndFreeze(_users());

        assertEq(season3.calculateSeason3LiquidCredits(user1), liquidBefore);
        assertEq(season3.calculateVeMaxiCredits(user1), veMaxiBefore);
    }

    function test_furtherActivityDoesNotAccrue() public {
        _snapshotAndFreeze(_users());
        uint256 liquidAtFreeze = season3.calculateSeason3LiquidCredits(user1);
        uint256 veMaxiAtFreeze = season3.calculateVeMaxiCredits(user1);

        // Live systems keep running; Season 3 no longer reads them.
        liquid1.setCumulativeOptionsClaimed(user1, 5_000e18);
        liquid2.setCumulativeOptionsClaimed(user1, 5_000e18);
        veMaxiLive.setLocked(user1, 9_000e18, 9_000e18);

        assertEq(season3.calculateSeason3LiquidCredits(user1), liquidAtFreeze);
        assertEq(season3.calculateVeMaxiCredits(user1), veMaxiAtFreeze);
    }

    function test_newParticipantsEarnNothingAfterFreeze() public {
        _snapshotAndFreeze(_users());

        liquid1.setCumulativeOptionsClaimed(user2, 1_000e18);
        veMaxiLive.setLocked(user2, 1_000e18, 1_000e18);

        assertEq(season3.calculateTotalCredits(user2), 0);
        assertEq(season3.calculateTotalRemainingCredits(user2), 0);
    }

    function test_redemptionStaysOpenAfterFreeze() public {
        _snapshotAndFreeze(_users());
        uint256 remaining = season3.calculateTotalRemainingCredits(user1);
        assertEq(remaining, 1250e18);

        vm.prank(user1);
        season3.redeemCombinedCredits(450e18, 800e18);

        assertEq(season3.liquidSpentCredits(user1), 450e18);
        assertEq(season3.veMaxiSpentCredits(user1), 800e18);
        assertEq(season3.calculateTotalRemainingCredits(user1), 0);

        vm.prank(user1);
        vm.expectRevert(AnchorClubSeason3.InsufficientCredits.selector);
        season3.redeemLiquidCredits(1);
    }

    function test_spentCreditsSurviveTheFreeze() public {
        vm.prank(user1);
        season3.redeemLiquidCredits(200e18);

        _snapshotAndFreeze(_users());

        assertEq(season3.liquidSpentCredits(user1), 200e18);
        assertEq(season3.calculateSeason3LiquidRemainingCredits(user1), 250e18);

        vm.prank(user1);
        season3.redeemLiquidCredits(250e18);
        assertEq(season3.calculateSeason3LiquidRemainingCredits(user1), 0);
    }

    function test_unlockingVeMaxiAfterFreezeDoesNotBurnEarnedCredits() public {
        _snapshotAndFreeze(_users());
        uint256 earned = season3.calculateVeMaxiCredits(user1);

        // Before the freeze this would have zeroed the user's veMaxi credits.
        veMaxiLive.setLocked(user1, 0, 0);

        assertEq(season3.calculateVeMaxiCredits(user1), earned);
        vm.prank(user1);
        season3.redeemVeMaxiCredits(earned);
        assertEq(season3.veMaxiSpentCredits(user1), earned);
    }

    /// @dev Documents why FreezeAnchorClubSeason3 removes before it adds: the opposite order sums the
    ///      live conduits and the snapshot together and roughly doubles redeemable credits.
    function test_removeBeforeAddIsFailSafe() public {
        address[] memory users = _users();
        (uint256[] memory liquid, , ) = _readLive(users);
        vm.prank(admin);
        s3Liquid.batchSetSnapshot(users, liquid);

        ILiquidConduit[] memory frozenSource = new ILiquidConduit[](1);
        frozenSource[0] = ILiquidConduit(address(s3Liquid));

        uint256 snapshotState = vm.snapshotState();

        // Wrong order: snapshot double-counts against the still-registered live conduits.
        vm.prank(admin);
        season3.addLiquidConduits(frozenSource);
        assertEq(season3.calculateSeason3LiquidCredits(user1), 1200e18); // (2000 - 400) * 0.75

        vm.revertToState(snapshotState);

        // Right order: credits read 0 in the window, so redemptions revert instead of over-paying.
        vm.prank(admin);
        season3.removeLiquidConduits(_liveConduits());
        assertEq(season3.calculateSeason3LiquidCredits(user1), 0);

        vm.prank(user1);
        vm.expectRevert(AnchorClubSeason3.InsufficientCredits.selector);
        season3.redeemLiquidCredits(1);

        vm.prank(admin);
        season3.addLiquidConduits(frozenSource);
        assertEq(season3.calculateSeason3LiquidCredits(user1), 450e18);
    }

    /// @dev The reconcile pass: accrual between the snapshot read and the freeze is patched up before sealing.
    function test_reconcileBeforeSealing() public {
        address[] memory users = _users();
        (uint256[] memory liquid, uint256[] memory flex, uint256[] memory protocolLocked) = _readLive(users);
        vm.startPrank(admin);
        s3Liquid.batchSetSnapshot(users, liquid);
        s3VeMaxi.batchSetSnapshot(users, flex, protocolLocked);
        vm.stopPrank();

        // User keeps claiming between the snapshot read and the swap.
        liquid1.setCumulativeOptionsClaimed(user1, 600e18);

        vm.startPrank(admin);
        season3.setVeMaxiConduit(IVeMaxiBalances(address(s3VeMaxi)));
        season3.removeLiquidConduits(_liveConduits());
        ILiquidConduit[] memory frozenSource = new ILiquidConduit[](1);
        frozenSource[0] = ILiquidConduit(address(s3Liquid));
        season3.addLiquidConduits(frozenSource);
        vm.stopPrank();

        // Stale: the extra 100e18 of claims is missing.
        assertEq(season3.calculateSeason3LiquidCredits(user1), 450e18);

        (uint256[] memory reconciled, , ) = _readLive(users);
        vm.startPrank(admin);
        s3Liquid.batchSetSnapshot(users, reconciled);
        s3Liquid.freeze();
        s3VeMaxi.freeze();
        vm.stopPrank();

        assertEq(season3.calculateSeason3LiquidCredits(user1), 525e18); // (1100 - 400) * 0.75
    }

    function test_freezeSealsSnapshotsPermanently() public {
        address[] memory users = _users();
        uint256[] memory amounts = new uint256[](2);

        vm.startPrank(admin);
        s3Liquid.freeze();
        s3VeMaxi.freeze();

        vm.expectRevert(AnchorClubSeason3Snapshot.AlreadyFrozen.selector);
        s3Liquid.setSnapshot(user1, 1);
        vm.expectRevert(AnchorClubSeason3Snapshot.AlreadyFrozen.selector);
        s3Liquid.batchSetSnapshot(users, amounts);
        vm.expectRevert(AnchorClubSeason3Snapshot.AlreadyFrozen.selector);
        s3Liquid.freeze();

        vm.expectRevert(AnchorClubSeason3VeMaxiSnapshot.AlreadyFrozen.selector);
        s3VeMaxi.setSnapshot(user1, 1, 1);
        vm.expectRevert(AnchorClubSeason3VeMaxiSnapshot.AlreadyFrozen.selector);
        s3VeMaxi.batchSetSnapshot(users, amounts, amounts);
        vm.stopPrank();

        assertTrue(s3Liquid.frozen());
        assertTrue(s3VeMaxi.frozen());
    }

    function test_snapshotWritesAreAdminOnly() public {
        address[] memory users = _users();
        uint256[] memory amounts = new uint256[](2);

        vm.startPrank(user1);
        vm.expectRevert();
        s3Liquid.batchSetSnapshot(users, amounts);
        vm.expectRevert();
        s3VeMaxi.batchSetSnapshot(users, amounts, amounts);
        vm.expectRevert();
        s3Liquid.freeze();
        vm.stopPrank();
    }

    function test_seasonReadsOnlyFrozenSourcesAfterFreeze() public {
        _snapshotAndFreeze(_users());

        ILiquidConduit[] memory conduits = season3.getLiquidConduits();
        assertEq(conduits.length, 1);
        assertEq(address(conduits[0]), address(s3Liquid));
        assertEq(address(season3.veMaxiConduit()), address(s3VeMaxi));

        // Season 2 baselines are untouched and still subtracted.
        assertEq(address(season3.season2Snapshot()), address(season2Liquid));
        assertEq(address(season3.veMaxiSeason2Snapshot()), address(season2VeMaxi));
    }
}

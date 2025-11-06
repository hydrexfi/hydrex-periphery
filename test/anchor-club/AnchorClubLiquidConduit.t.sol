// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {AnchorClubLiquidConduit} from "../../contracts/anchor-club/AnchorClubLiquidConduit.sol";
import {LiquidAccountConduitSimple} from "../../contracts/conduits/LiquidAccountConduitSimple.sol";
import {IOptionsToken} from "../../contracts/interfaces/IOptionsToken.sol";

contract MockOptionsToken {
    uint256 private nftIdCounter = 1;

    function exerciseVe(uint256 /* _amount */, address /* _recipient */) external returns (uint256 nftId) {
        return nftIdCounter++;
    }
}

contract MockLiquidConduit {
    mapping(address => uint256) public cumulativeOptionsClaimed;

    function setCumulativeOptionsClaimed(address user, uint256 amount) external {
        cumulativeOptionsClaimed[user] = amount;
    }
}

contract AnchorClubLiquidConduitTest is Test {
    AnchorClubLiquidConduit public anchorClub;
    MockOptionsToken public optionsToken;
    MockLiquidConduit public liquidConduit;

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
        liquidConduit = new MockLiquidConduit();

        // Deploy AnchorClub
        vm.prank(admin);
        anchorClub = new AnchorClubLiquidConduit(
            LiquidAccountConduitSimple(payable(address(liquidConduit))),
            IOptionsToken(address(optionsToken)),
            admin
        );
    }

    function testInitialState() public view {
        assertEq(anchorClub.liquidAccountMultiplier(), 25000); // 250%
        assertEq(anchorClub.referrerBonusBps(), 1000); // 10%
        assertEq(anchorClub.refereeBonusBps(), 1000); // 10%
        assertEq(anchorClub.bonusCreditsCap(), 10000 ether);
        assertEq(anchorClub.maxCreditsToSetReferral(), 100 ether);
        assertTrue(anchorClub.referralsEnabled());
        assertTrue(anchorClub.hasRole(anchorClub.DEFAULT_ADMIN_ROLE(), admin));
    }

    function testCalculateBaseCredits() public {
        // User has claimed 1000 oHYDX
        liquidConduit.setCumulativeOptionsClaimed(user1, 1000 ether);

        // Base credits = 1000 * 25000 / 10000 = 2500
        uint256 baseCredits = anchorClub.calculateBaseCredits(user1);
        assertEq(baseCredits, 2500 ether);
    }

    function testSetReferrer() public {
        vm.prank(user1);
        anchorClub.setReferrer(user2);

        assertEq(anchorClub.referredBy(user1), user2);

        address[] memory referees = anchorClub.getReferees(user2);
        assertEq(referees.length, 1);
        assertEq(referees[0], user1);
    }

    function test_RevertWhen_SetReferrerTwice() public {
        vm.startPrank(user1);
        anchorClub.setReferrer(user2);

        vm.expectRevert(AnchorClubLiquidConduit.AlreadyHasReferrer.selector);
        anchorClub.setReferrer(user3);
        vm.stopPrank();
    }

    function test_RevertWhen_ReferSelf() public {
        vm.prank(user1);
        vm.expectRevert(AnchorClubLiquidConduit.CannotReferSelf.selector);
        anchorClub.setReferrer(user1);
    }

    function test_RevertWhen_TooManyCreditsToSetReferrer() public {
        // Give user1 too many credits
        liquidConduit.setCumulativeOptionsClaimed(user1, 100 ether);

        vm.prank(user1);
        vm.expectRevert(AnchorClubLiquidConduit.TooManyCreditsToSetReferrer.selector);
        anchorClub.setReferrer(user2);
    }

    function testCalculateBonusCredits() public {
        // User1 refers user2
        vm.prank(user2);
        anchorClub.setReferrer(user1);

        // User2 claims 1000 oHYDX -> 2500 base credits
        liquidConduit.setCumulativeOptionsClaimed(user2, 1000 ether);

        // User2's bonus = 2500 * 1000 / 10000 = 250
        uint256 bonusCredits = anchorClub.calculateBonusCredits(user2);
        assertEq(bonusCredits, 250 ether);
    }

    function testCalculateReferredCredits() public {
        // User1 refers user2
        vm.prank(user2);
        anchorClub.setReferrer(user1);

        // User2 claims 1000 oHYDX -> 2500 base credits
        liquidConduit.setCumulativeOptionsClaimed(user2, 1000 ether);

        // User1's referral bonus = 2500 * 1000 / 10000 = 250
        uint256 referredCredits = anchorClub.calculateReferredCredits(user1);
        assertEq(referredCredits, 250 ether);
    }

    function testCalculateTotalCredits() public {
        // Setup: user1 refers user2 and user3
        vm.prank(user2);
        anchorClub.setReferrer(user1);
        vm.prank(user3);
        anchorClub.setReferrer(user1);

        // User1 claims 1000 -> base = 2500
        liquidConduit.setCumulativeOptionsClaimed(user1, 1000 ether);

        // User2 claims 500 -> base = 1250, bonus = 125
        liquidConduit.setCumulativeOptionsClaimed(user2, 500 ether);

        // User3 claims 500 -> base = 1250
        liquidConduit.setCumulativeOptionsClaimed(user3, 500 ether);

        // User1 total = 2500 (base) + 250 (from user2 + user3 referrals)
        uint256 user1Total = anchorClub.calculateTotalCredits(user1);
        assertEq(user1Total, 2750 ether);

        // User2 total = 1250 (base) + 125 (bonus) = 1375
        uint256 user2Total = anchorClub.calculateTotalCredits(user2);
        assertEq(user2Total, 1375 ether);
    }

    function testRedeemCredits() public {
        // Give user1 some credits
        liquidConduit.setCumulativeOptionsClaimed(user1, 1000 ether);
        uint256 totalCredits = anchorClub.calculateTotalCredits(user1);

        vm.prank(user1);
        anchorClub.redeemCredits(1000 ether);

        assertEq(anchorClub.spentCredits(user1), 1000 ether);
        assertEq(anchorClub.calculateRemainingCredits(user1), totalCredits - 1000 ether);
    }

    function test_RevertWhen_RedeemInsufficientCredits() public {
        liquidConduit.setCumulativeOptionsClaimed(user1, 100 ether); // 250 base credits

        vm.prank(user1);
        vm.expectRevert(AnchorClubLiquidConduit.InsufficientCredits.selector);
        anchorClub.redeemCredits(1000 ether);
    }

    function testAddLiquidConduit() public {
        MockLiquidConduit newConduit = new MockLiquidConduit();

        LiquidAccountConduitSimple[] memory conduits = new LiquidAccountConduitSimple[](1);
        conduits[0] = LiquidAccountConduitSimple(payable(address(newConduit)));

        vm.prank(admin);
        anchorClub.addLiquidConduits(conduits);

        assertTrue(anchorClub.isLiquidConduit(address(newConduit)));
    }

    function testRemoveLiquidConduit() public {
        LiquidAccountConduitSimple[] memory conduits = new LiquidAccountConduitSimple[](1);
        conduits[0] = LiquidAccountConduitSimple(payable(address(liquidConduit)));

        vm.prank(admin);
        anchorClub.removeLiquidConduits(conduits);

        assertFalse(anchorClub.isLiquidConduit(address(liquidConduit)));
    }

    function testSetLiquidAccountMultiplier() public {
        vm.prank(admin);
        anchorClub.setLiquidAccountMultiplier(30000); // 300%

        assertEq(anchorClub.liquidAccountMultiplier(), 30000);
    }

    function testSetReferralBonuses() public {
        vm.prank(admin);
        anchorClub.setReferralBonuses(1500, 1500, 20000 ether);

        assertEq(anchorClub.referrerBonusBps(), 1500);
        assertEq(anchorClub.refereeBonusBps(), 1500);
        assertEq(anchorClub.bonusCreditsCap(), 20000 ether);
    }

    function testSetReferralsEnabled() public {
        vm.prank(admin);
        anchorClub.setReferralsEnabled(false);

        assertFalse(anchorClub.referralsEnabled());

        vm.prank(user1);
        vm.expectRevert(AnchorClubLiquidConduit.ReferralsDisabled.selector);
        anchorClub.setReferrer(user2);
    }

    function testSetMaxCreditsToSetReferral() public {
        vm.prank(admin);
        anchorClub.setMaxCreditsToSetReferral(200 ether);

        assertEq(anchorClub.maxCreditsToSetReferral(), 200 ether);
    }

    function testBonusCreditsCap() public {
        // User1 sets referrer first (before accumulating credits)
        vm.prank(user1);
        anchorClub.setReferrer(user2);

        // Then user1 accumulates very high claims
        // 50000 ether -> 125000 base credits -> 12500 bonus uncapped, but capped at 10000
        liquidConduit.setCumulativeOptionsClaimed(user1, 50000 ether);

        // Bonus should be capped at bonusCreditsCap (10000 ether)
        uint256 bonusCredits = anchorClub.calculateBonusCredits(user1);
        assertEq(bonusCredits, 10000 ether);

        // Verify the uncapped bonus would be higher
        uint256 baseCredits = anchorClub.calculateBaseCredits(user1);
        assertEq(baseCredits, 125000 ether);
        uint256 uncappedBonus = (baseCredits * 1000) / 10000;
        assertEq(uncappedBonus, 12500 ether);
        assertGt(uncappedBonus, 10000 ether);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {VeBoostLens} from "../contracts/governance/VeBoostLens.sol";

// Mock veNFT contract implementing getVotes
contract MockVeNFT {
    mapping(address => uint256) public votes;

    function setVotes(address account, uint256 amount) external {
        votes[account] = amount;
    }

    function getVotes(address account) external view returns (uint256) {
        return votes[account];
    }
}

// Mock that reverts, to prove the lens does not swallow escrow failures
contract RevertingVeNFT {
    error EscrowFailure();

    function getVotes(address) external pure returns (uint256) {
        revert EscrowFailure();
    }
}

contract VeBoostLensTest is Test {
    VeBoostLens public lens;
    MockVeNFT public veNFT;

    address public user1;
    address public user2;
    address public user3;

    function setUp() public {
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        veNFT = new MockVeNFT();
        lens = new VeBoostLens(address(veNFT));
    }

    /*
     * Initial State Tests
     */

    function testInitialState() public view {
        assertEq(address(lens.veNFT()), address(veNFT));
        assertEq(lens.BOOST_BPS(), 13_000);
        assertEq(lens.BPS_DENOMINATOR(), 10_000);
    }

    function testConstructorRevertsOnZeroAddress() public {
        vm.expectRevert(VeBoostLens.ZeroAddress.selector);
        new VeBoostLens(address(0));
    }

    /*
     * Boost Application Tests
     */

    function testGetEarningPowerAppliesMultiplier() public {
        veNFT.setVotes(user1, 1000 ether);

        // 1000 * 13000 / 10000 == 1300
        assertEq(lens.getEarningPower(user1), 1300 ether);
    }

    function testGetEarningPowerReturnsZeroWhenAccountHasNoVotes() public view {
        assertEq(lens.getEarningPower(user1), 0);
    }

    function testRawVotesReturnsUnboostedValue() public {
        veNFT.setVotes(user1, 1000 ether);

        assertEq(lens.rawVotes(user1), 1000 ether);
        assertEq(lens.getEarningPower(user1), 1300 ether);
    }

    function testGetEarningPowerTracksEscrowChanges() public {
        veNFT.setVotes(user1, 500 ether);
        assertEq(lens.getEarningPower(user1), 650 ether);

        veNFT.setVotes(user1, 100 ether);
        assertEq(lens.getEarningPower(user1), 130 ether);

        veNFT.setVotes(user1, 0);
        assertEq(lens.getEarningPower(user1), 0);
    }

    function testGetEarningPowerBubblesUpEscrowRevert() public {
        VeBoostLens revertingLens = new VeBoostLens(address(new RevertingVeNFT()));

        vm.expectRevert(RevertingVeNFT.EscrowFailure.selector);
        revertingLens.getEarningPower(user1);
    }

    /*
     * Rounding Boundary Tests
     */

    function testGetEarningPowerRoundsDownAtOneWei() public {
        // 1 * 13000 / 10000 == 1.3 -> 1
        veNFT.setVotes(user1, 1);
        assertEq(lens.getEarningPower(user1), 1);
    }

    function testGetEarningPowerRoundsDownOnFractionalResult() public {
        // 7 * 13000 / 10000 == 9.1 -> 9
        veNFT.setVotes(user1, 7);
        assertEq(lens.getEarningPower(user1), 9);
    }

    function testGetEarningPowerIsExactOnMultiplesOfTen() public {
        // 10 * 13000 / 10000 == 13 exactly, no truncation
        veNFT.setVotes(user1, 10);
        assertEq(lens.getEarningPower(user1), 13);
    }

    /*
     * Batch Tests
     */

    function testGetBatchEarningPower() public {
        veNFT.setVotes(user1, 1000 ether);
        veNFT.setVotes(user2, 0);
        veNFT.setVotes(user3, 7);

        address[] memory accounts = new address[](3);
        accounts[0] = user1;
        accounts[1] = user2;
        accounts[2] = user3;

        uint256[] memory powers = lens.getBatchEarningPower(accounts);

        assertEq(powers.length, 3);
        assertEq(powers[0], 1300 ether);
        assertEq(powers[1], 0);
        assertEq(powers[2], 9);
    }

    function testGetBatchEarningPowerOnEmptyArray() public view {
        address[] memory accounts = new address[](0);
        uint256[] memory powers = lens.getBatchEarningPower(accounts);
        assertEq(powers.length, 0);
    }

    function testGetBatchEarningPowerMatchesSingleGetter() public {
        veNFT.setVotes(user1, 123_456_789);
        veNFT.setVotes(user2, 987_654_321);

        address[] memory accounts = new address[](2);
        accounts[0] = user1;
        accounts[1] = user2;

        uint256[] memory powers = lens.getBatchEarningPower(accounts);

        assertEq(powers[0], lens.getEarningPower(user1));
        assertEq(powers[1], lens.getEarningPower(user2));
    }

    /*
     * Fuzz Tests
     */

    // Invariant: getEarningPower(a) == rawVotes(a) * BOOST_BPS / BPS_DENOMINATOR
    function testFuzz_GetEarningPowerMatchesFormula(uint256 raw) public {
        raw = bound(raw, 0, 1e30);
        veNFT.setVotes(user1, raw);

        assertEq(lens.getEarningPower(user1), (raw * 13_000) / 10_000);
    }

    // Invariant: getEarningPower(a) >= rawVotes(a), since BOOST_BPS >= BPS_DENOMINATOR
    function testFuzz_GetEarningPowerNeverBelowRaw(uint256 raw) public {
        raw = bound(raw, 0, 1e30);
        veNFT.setVotes(user1, raw);

        assertGe(lens.getEarningPower(user1), lens.rawVotes(user1));
    }

    // Truncation is bounded by one wei: the divisor is 10_000 and the numerator is a
    // multiple of 13_000, so the discarded remainder is always < 1.
    function testFuzz_BoostLossIsAtMostOneWei(uint256 raw) public {
        raw = bound(raw, 0, 1e30);
        veNFT.setVotes(user1, raw);

        uint256 exactScaledByBps = raw * 13_000;
        uint256 actualScaledByBps = lens.getEarningPower(user1) * 10_000;

        assertLe(exactScaledByBps - actualScaledByBps, 10_000);
    }
}

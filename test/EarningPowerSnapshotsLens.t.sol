// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {EarningPowerSnapshotsLens} from "../contracts/governance/EarningPowerSnapshotsLens.sol";

// Mock veNFT contract implementing getPastVotes
contract MockVeNFT {
    mapping(uint256 => mapping(address => uint256)) public pastVotes;

    function setPastVotes(address account, uint256 timepoint, uint256 votes) external {
        pastVotes[timepoint][account] = votes;
    }

    function getPastVotes(address account, uint256 timepoint) external view returns (uint256) {
        return pastVotes[timepoint][account];
    }
}

contract EarningPowerSnapshotsLensTest is Test {
    EarningPowerSnapshotsLens public lens;
    MockVeNFT public veNFT;

    address public admin;
    address public user1;
    address public user2;
    address public user3;

    uint256 public constant DEFAULT_TIMESTAMP = 1234567890;

    function setUp() public {
        admin = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        veNFT = new MockVeNFT();
        lens = new EarningPowerSnapshotsLens(admin, address(veNFT));
    }

    /*
     * Initial State Tests
     */

    function testInitialState() public view {
        assertEq(lens.defaultTimestamp(), 0);
        assertTrue(lens.hasRole(lens.DEFAULT_ADMIN_ROLE(), admin));
        assertEq(address(lens.veNFT()), address(veNFT));
    }

    /*
     * Snapshot Posting Tests
     */

    function testPostSnapshot() public {
        uint256 timestamp = 1000;
        uint256 power = 5000 * 10 ** 18;

        vm.expectEmit(true, true, false, true);
        emit EarningPowerSnapshotsLens.SnapshotPosted(timestamp, user1, power);

        lens.postSnapshot(timestamp, user1, power);

        assertEq(lens.snapshots(timestamp, user1), power);
    }

    function testPostBatchSnapshot() public {
        uint256 timestamp = 2000;
        address[] memory accounts = new address[](3);
        accounts[0] = user1;
        accounts[1] = user2;
        accounts[2] = user3;

        uint256[] memory powers = new uint256[](3);
        powers[0] = 1000 * 10 ** 18;
        powers[1] = 2000 * 10 ** 18;
        powers[2] = 3000 * 10 ** 18;

        vm.expectEmit(true, false, false, true);
        emit EarningPowerSnapshotsLens.BatchSnapshotPosted(timestamp, 3);

        lens.postBatchSnapshot(timestamp, accounts, powers);

        assertEq(lens.snapshots(timestamp, user1), powers[0]);
        assertEq(lens.snapshots(timestamp, user2), powers[1]);
        assertEq(lens.snapshots(timestamp, user3), powers[2]);
    }

    function test_RevertWhen_PostBatchSnapshotWithLengthMismatch() public {
        address[] memory accounts = new address[](2);
        accounts[0] = user1;
        accounts[1] = user2;

        uint256[] memory powers = new uint256[](1);
        powers[0] = 1000 * 10 ** 18;

        vm.expectRevert("Length mismatch");
        lens.postBatchSnapshot(1000, accounts, powers);
    }

    function test_RevertWhen_PostBatchSnapshotWithEmptyArrays() public {
        address[] memory accounts = new address[](0);
        uint256[] memory powers = new uint256[](0);

        vm.expectRevert("Empty arrays");
        lens.postBatchSnapshot(1000, accounts, powers);
    }

    function test_RevertWhen_NonAdminPostsSnapshot() public {
        vm.prank(user1);
        vm.expectRevert();
        lens.postSnapshot(1000, user2, 5000);
    }

    /*
     * Default Timestamp Tests
     */

    function testSetDefaultTimestamp() public {
        uint256 newTimestamp = DEFAULT_TIMESTAMP;

        vm.expectEmit(false, false, false, true);
        emit EarningPowerSnapshotsLens.DefaultTimestampUpdated(0, newTimestamp);

        lens.setDefaultTimestamp(newTimestamp);

        assertEq(lens.defaultTimestamp(), newTimestamp);
    }

    function test_RevertWhen_NonAdminSetsDefaultTimestamp() public {
        vm.prank(user1);
        vm.expectRevert();
        lens.setDefaultTimestamp(DEFAULT_TIMESTAMP);
    }

    /*
     * Query Tests - Without Fallback
     */

    function testGetPowerWithSnapshot() public {
        lens.setDefaultTimestamp(DEFAULT_TIMESTAMP);
        lens.postSnapshot(DEFAULT_TIMESTAMP, user1, 5000 * 10 ** 18);

        uint256 power = lens.getPower(user1);
        assertEq(power, 5000 * 10 ** 18);
    }

    function testGetPowerAtWithSnapshot() public {
        uint256 timestamp = 1000;
        lens.postSnapshot(timestamp, user1, 3000 * 10 ** 18);

        uint256 power = lens.getPowerAt(user1, timestamp);
        assertEq(power, 3000 * 10 ** 18);
    }

    function testGetBatchPowerWithSnapshots() public {
        lens.setDefaultTimestamp(DEFAULT_TIMESTAMP);

        lens.postSnapshot(DEFAULT_TIMESTAMP, user1, 1000 * 10 ** 18);
        lens.postSnapshot(DEFAULT_TIMESTAMP, user2, 2000 * 10 ** 18);
        lens.postSnapshot(DEFAULT_TIMESTAMP, user3, 3000 * 10 ** 18);

        address[] memory accounts = new address[](3);
        accounts[0] = user1;
        accounts[1] = user2;
        accounts[2] = user3;

        uint256[] memory powers = lens.getBatchPower(accounts);
        assertEq(powers[0], 1000 * 10 ** 18);
        assertEq(powers[1], 2000 * 10 ** 18);
        assertEq(powers[2], 3000 * 10 ** 18);
    }

    function testGetBatchPowerAtWithSnapshots() public {
        uint256 timestamp = 5000;

        lens.postSnapshot(timestamp, user1, 1500 * 10 ** 18);
        lens.postSnapshot(timestamp, user2, 2500 * 10 ** 18);

        address[] memory accounts = new address[](2);
        accounts[0] = user1;
        accounts[1] = user2;

        uint256[] memory powers = lens.getBatchPowerAt(accounts, timestamp);
        assertEq(powers[0], 1500 * 10 ** 18);
        assertEq(powers[1], 2500 * 10 ** 18);
    }

    /*
     * Query Tests - With veNFT Fallback
     */

    function testGetPowerFallbackToVeNFT() public {
        lens.setDefaultTimestamp(DEFAULT_TIMESTAMP);
        
        // Set up veNFT vote data
        veNFT.setPastVotes(user1, DEFAULT_TIMESTAMP, 7000 * 10 ** 18);

        // No snapshot posted, should fallback to veNFT
        uint256 power = lens.getPower(user1);
        assertEq(power, 7000 * 10 ** 18);
    }

    function testGetPowerAtFallbackToVeNFT() public {
        uint256 timestamp = 2000;
        
        // Set up veNFT vote data
        veNFT.setPastVotes(user1, timestamp, 4000 * 10 ** 18);

        // No snapshot posted, should fallback to veNFT
        uint256 power = lens.getPowerAt(user1, timestamp);
        assertEq(power, 4000 * 10 ** 18);
    }

    function testGetBatchPowerMixedFallback() public {
        lens.setDefaultTimestamp(DEFAULT_TIMESTAMP);

        // Post snapshot for user1 only
        lens.postSnapshot(DEFAULT_TIMESTAMP, user1, 1000 * 10 ** 18);

        // Set veNFT data for user2 and user3
        veNFT.setPastVotes(user2, DEFAULT_TIMESTAMP, 2000 * 10 ** 18);
        veNFT.setPastVotes(user3, DEFAULT_TIMESTAMP, 3000 * 10 ** 18);

        address[] memory accounts = new address[](3);
        accounts[0] = user1;
        accounts[1] = user2;
        accounts[2] = user3;

        uint256[] memory powers = lens.getBatchPower(accounts);
        
        // user1 should come from snapshot
        assertEq(powers[0], 1000 * 10 ** 18);
        // user2 and user3 should fallback to veNFT
        assertEq(powers[1], 2000 * 10 ** 18);
        assertEq(powers[2], 3000 * 10 ** 18);
    }

    function testGetBatchPowerAtMixedFallback() public {
        uint256 timestamp = 3000;

        // Post snapshots for some users
        lens.postSnapshot(timestamp, user1, 1500 * 10 ** 18);

        // Set veNFT data for other users
        veNFT.setPastVotes(user2, timestamp, 2500 * 10 ** 18);
        veNFT.setPastVotes(user3, timestamp, 3500 * 10 ** 18);

        address[] memory accounts = new address[](3);
        accounts[0] = user1;
        accounts[1] = user2;
        accounts[2] = user3;

        uint256[] memory powers = lens.getBatchPowerAt(accounts, timestamp);
        
        assertEq(powers[0], 1500 * 10 ** 18);
        assertEq(powers[1], 2500 * 10 ** 18);
        assertEq(powers[2], 3500 * 10 ** 18);
    }

    function testSnapshotOverridesVeNFT() public {
        lens.setDefaultTimestamp(DEFAULT_TIMESTAMP);

        // Set veNFT data
        veNFT.setPastVotes(user1, DEFAULT_TIMESTAMP, 5000 * 10 ** 18);

        // Post snapshot with different value
        lens.postSnapshot(DEFAULT_TIMESTAMP, user1, 8000 * 10 ** 18);

        // Should use snapshot value, not veNFT value
        uint256 power = lens.getPower(user1);
        assertEq(power, 8000 * 10 ** 18);
    }

    function testGetPowerReturnsZeroWhenNeitherExists() public {
        lens.setDefaultTimestamp(DEFAULT_TIMESTAMP);

        // No snapshot and no veNFT data
        uint256 power = lens.getPower(user1);
        assertEq(power, 0);
    }

    /*
     * Complex Scenarios
     */

    function testUpdateSnapshot() public {
        uint256 timestamp = 1000;
        
        // Post initial snapshot
        lens.postSnapshot(timestamp, user1, 3000 * 10 ** 18);
        assertEq(lens.snapshots(timestamp, user1), 3000 * 10 ** 18);

        // Update snapshot
        lens.postSnapshot(timestamp, user1, 5000 * 10 ** 18);
        assertEq(lens.snapshots(timestamp, user1), 5000 * 10 ** 18);
    }

    function testMultipleTimestamps() public {
        uint256 timestamp1 = 1000;
        uint256 timestamp2 = 2000;
        uint256 timestamp3 = 3000;

        lens.postSnapshot(timestamp1, user1, 1000 * 10 ** 18);
        lens.postSnapshot(timestamp2, user1, 2000 * 10 ** 18);
        lens.postSnapshot(timestamp3, user1, 3000 * 10 ** 18);

        assertEq(lens.getPowerAt(user1, timestamp1), 1000 * 10 ** 18);
        assertEq(lens.getPowerAt(user1, timestamp2), 2000 * 10 ** 18);
        assertEq(lens.getPowerAt(user1, timestamp3), 3000 * 10 ** 18);
    }

    function testBatchSnapshotOverwritesExisting() public {
        uint256 timestamp = 4000;

        // Post initial snapshot
        lens.postSnapshot(timestamp, user1, 1000 * 10 ** 18);

        // Post batch that includes user1 with different value
        address[] memory accounts = new address[](2);
        accounts[0] = user1;
        accounts[1] = user2;

        uint256[] memory powers = new uint256[](2);
        powers[0] = 5000 * 10 ** 18;
        powers[1] = 6000 * 10 ** 18;

        lens.postBatchSnapshot(timestamp, accounts, powers);

        // Should have new values
        assertEq(lens.snapshots(timestamp, user1), 5000 * 10 ** 18);
        assertEq(lens.snapshots(timestamp, user2), 6000 * 10 ** 18);
    }
}


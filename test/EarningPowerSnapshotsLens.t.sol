// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {EarningPowerSnapshotsLens} from "../contracts/governance/EarningPowerSnapshotsLens.sol";

contract EarningPowerSnapshotsLensTest is Test {
    EarningPowerSnapshotsLens public lens;
    
    address public admin = address(0x1);
    address public user1 = address(0x2);
    address public user2 = address(0x3);
    address public user3 = address(0x4);
    
    uint256 public constant TIMESTAMP_1 = 1700000000;
    uint256 public constant TIMESTAMP_2 = 1700086400;
    uint256 public constant TIMESTAMP_3 = 1700172800;

    function setUp() public {
        lens = new EarningPowerSnapshotsLens(admin);
    }

    function test_PostSingleSnapshot() public {
        vm.prank(admin);
        lens.postSnapshot(TIMESTAMP_1, user1, 1000);
        
        assertEq(lens.getPowerAt(user1, TIMESTAMP_1), 1000);
    }

    function test_PostBatchSnapshot() public {
        address[] memory accounts = new address[](3);
        accounts[0] = user1;
        accounts[1] = user2;
        accounts[2] = user3;
        
        uint256[] memory powers = new uint256[](3);
        powers[0] = 1000;
        powers[1] = 2000;
        powers[2] = 3000;
        
        vm.prank(admin);
        lens.postBatchSnapshot(TIMESTAMP_1, accounts, powers);
        
        assertEq(lens.getPowerAt(user1, TIMESTAMP_1), 1000);
        assertEq(lens.getPowerAt(user2, TIMESTAMP_1), 2000);
        assertEq(lens.getPowerAt(user3, TIMESTAMP_1), 3000);
    }

    function test_MultipleTimestamps() public {
        // Post snapshot for TIMESTAMP_1
        vm.prank(admin);
        lens.postSnapshot(TIMESTAMP_1, user1, 1000);
        
        // Post snapshot for TIMESTAMP_2
        vm.prank(admin);
        lens.postSnapshot(TIMESTAMP_2, user1, 1500);
        
        // Post snapshot for TIMESTAMP_3
        vm.prank(admin);
        lens.postSnapshot(TIMESTAMP_3, user1, 2000);
        
        assertEq(lens.getPowerAt(user1, TIMESTAMP_1), 1000);
        assertEq(lens.getPowerAt(user1, TIMESTAMP_2), 1500);
        assertEq(lens.getPowerAt(user1, TIMESTAMP_3), 2000);
    }

    function test_GetBatchPowerAt() public {
        address[] memory accounts = new address[](3);
        accounts[0] = user1;
        accounts[1] = user2;
        accounts[2] = user3;
        
        uint256[] memory powers = new uint256[](3);
        powers[0] = 1000;
        powers[1] = 2000;
        powers[2] = 3000;
        
        vm.prank(admin);
        lens.postBatchSnapshot(TIMESTAMP_1, accounts, powers);
        
        uint256[] memory retrievedPowers = lens.getBatchPowerAt(accounts, TIMESTAMP_1);
        
        assertEq(retrievedPowers[0], 1000);
        assertEq(retrievedPowers[1], 2000);
        assertEq(retrievedPowers[2], 3000);
    }

    function test_MultipleAccountsSameTimestamp() public {
        vm.startPrank(admin);
        lens.postSnapshot(TIMESTAMP_1, user1, 1000);
        lens.postSnapshot(TIMESTAMP_1, user2, 1500);
        lens.postSnapshot(TIMESTAMP_1, user3, 2000);
        vm.stopPrank();
        
        assertEq(lens.getPowerAt(user1, TIMESTAMP_1), 1000);
        assertEq(lens.getPowerAt(user2, TIMESTAMP_1), 1500);
        assertEq(lens.getPowerAt(user3, TIMESTAMP_1), 2000);
    }

    function test_NonExistentSnapshot() public view {
        uint256 power = lens.getPowerAt(user1, TIMESTAMP_1);
        assertEq(power, 0);
    }

    function test_OverwriteSnapshot() public {
        vm.startPrank(admin);
        lens.postSnapshot(TIMESTAMP_1, user1, 1000);
        lens.postSnapshot(TIMESTAMP_1, user1, 2000);
        vm.stopPrank();
        
        assertEq(lens.getPowerAt(user1, TIMESTAMP_1), 2000);
    }

    function testRevert_NonAdminCannotPost() public {
        vm.prank(user1);
        vm.expectRevert();
        lens.postSnapshot(TIMESTAMP_1, user1, 1000);
    }

    function testRevert_BatchLengthMismatch() public {
        address[] memory accounts = new address[](3);
        uint256[] memory powers = new uint256[](2);
        
        vm.prank(admin);
        vm.expectRevert("Length mismatch");
        lens.postBatchSnapshot(TIMESTAMP_1, accounts, powers);
    }

    function testRevert_EmptyBatch() public {
        address[] memory accounts = new address[](0);
        uint256[] memory powers = new uint256[](0);
        
        vm.prank(admin);
        vm.expectRevert("Empty arrays");
        lens.postBatchSnapshot(TIMESTAMP_1, accounts, powers);
    }
}


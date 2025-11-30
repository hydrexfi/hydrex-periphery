// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {BribeBatches} from "../contracts/extra/BribeBatches.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Mock bribe contract
contract MockBribe {
    address public lastRewardToken;
    uint256 public lastRewardAmount;
    uint256 public totalRewardsReceived;

    function notifyRewardAmount(address _rewardsToken, uint256 reward) external {
        lastRewardToken = _rewardsToken;
        lastRewardAmount = reward;
        totalRewardsReceived += reward;
    }
}

// Mock ERC20 token
contract MockToken is ERC20 {
    constructor() ERC20("Mock Token", "MOCK") {
        _mint(msg.sender, 1_000_000 * 10 ** 18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract BribeBatchesTest is Test {
    BribeBatches public bribeBatches;
    MockToken public rewardToken;
    MockBribe public bribeContract;

    address public owner;
    address public operator;
    address public depositor;
    address public user1;

    uint256 public constant EPOCH_START = 1757548800;
    uint256 public constant EPOCH_DURATION = 1 weeks;

    function setUp() public {
        // Create addresses
        owner = address(this); // Use test contract as owner initially
        operator = makeAddr("operator");
        depositor = makeAddr("depositor");
        user1 = makeAddr("user1");

        // Deploy contracts
        bribeBatches = new BribeBatches();
        rewardToken = new MockToken();
        bribeContract = new MockBribe();

        // Grant operator role
        bribeBatches.grantRole(bribeBatches.OPERATOR_ROLE(), operator);

        // Fund depositor with tokens
        rewardToken.mint(depositor, 1_000_000 * 10 ** 18);
    }

    // Helper function to create single bribe config
    function _singleBribeConfig(address bribe) internal pure returns (address[] memory, uint256[] memory) {
        address[] memory bribes = new address[](1);
        bribes[0] = bribe;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 10000;
        return (bribes, weights);
    }

    /*
     * Initial State Tests
     */

    function testInitialState() public view {
        assertEq(bribeBatches.EPOCH_START(), EPOCH_START);
        assertEq(bribeBatches.EPOCH_DURATION(), EPOCH_DURATION);
        assertEq(bribeBatches.BASIS_POINTS(), 10000);
        assertEq(bribeBatches.nextBatchId(), 0);
        assertTrue(bribeBatches.hasRole(bribeBatches.DEFAULT_ADMIN_ROLE(), owner));
        assertTrue(bribeBatches.hasRole(bribeBatches.OPERATOR_ROLE(), owner));
        assertTrue(bribeBatches.hasRole(bribeBatches.OPERATOR_ROLE(), operator));
    }

    function testGetCurrentEpoch() public {
        // Before epoch start
        vm.warp(EPOCH_START - 1);
        assertEq(bribeBatches.getCurrentEpoch(), 0);

        // At epoch start
        vm.warp(EPOCH_START);
        assertEq(bribeBatches.getCurrentEpoch(), 0);

        // One week after epoch start
        vm.warp(EPOCH_START + EPOCH_DURATION);
        assertEq(bribeBatches.getCurrentEpoch(), 1);

        // Two weeks after epoch start
        vm.warp(EPOCH_START + EPOCH_DURATION * 2);
        assertEq(bribeBatches.getCurrentEpoch(), 2);
    }

    /*
     * Batch Creation Tests
     */

    function testCreateBatchWithExistingBribeContract() public {
        vm.warp(EPOCH_START);
        uint256 totalAmount = 10_000 * 10 ** 18;
        uint256 totalWeeks = 10;

        vm.startPrank(depositor);
        rewardToken.approve(address(bribeBatches), totalAmount);

        (address[] memory bribes, uint256[] memory weights) = _singleBribeConfig(address(bribeContract));

        uint256 batchId = bribeBatches.createBatchWithExistingBribeContract(
            address(rewardToken), totalAmount, totalWeeks, bribes, weights
        );
        vm.stopPrank();

        BribeBatches.BribeBatch memory batch = bribeBatches.getBatch(batchId);

        assertEq(batch.batchId, 0);
        assertEq(batch.depositor, depositor);
        assertEq(batch.rewardToken, address(rewardToken));
        assertEq(batch.totalAmount, totalAmount);
        assertEq(batch.totalWeeks, totalWeeks);
        assertEq(batch.weeksExecuted, 1); // First bribe executed immediately
        assertEq(uint256(batch.status), uint256(BribeBatches.BatchStatus.Active));
        assertEq(batch.bribeConfig.bribeContracts.length, 1);
        assertEq(batch.bribeConfig.bribeContracts[0], address(bribeContract));
        assertEq(batch.bribeConfig.weights[0], 10000);

        // Verify first bribe was sent
        assertEq(bribeContract.totalRewardsReceived(), totalAmount / totalWeeks);
    }

    function testCreateBatchWithMultipleBribeContracts() public {
        vm.warp(EPOCH_START);
        uint256 totalAmount = 10_000 * 10 ** 18;
        uint256 totalWeeks = 10;

        MockBribe bribe1 = new MockBribe();
        MockBribe bribe2 = new MockBribe();
        MockBribe bribe3 = new MockBribe();

        address[] memory bribes = new address[](3);
        bribes[0] = address(bribe1);
        bribes[1] = address(bribe2);
        bribes[2] = address(bribe3);

        uint256[] memory weights = new uint256[](3);
        weights[0] = 5000; // 50%
        weights[1] = 3000; // 30%
        weights[2] = 2000; // 20%

        vm.startPrank(depositor);
        rewardToken.approve(address(bribeBatches), totalAmount);

        uint256 batchId = bribeBatches.createBatchWithExistingBribeContract(
            address(rewardToken), totalAmount, totalWeeks, bribes, weights
        );
        vm.stopPrank();

        BribeBatches.BribeBatch memory batch = bribeBatches.getBatch(batchId);
        assertEq(batch.bribeConfig.bribeContracts.length, 3);
        
        uint256 weeklyAmount = totalAmount / totalWeeks;
        // Verify distribution (50%, 30%, 20%)
        assertEq(bribe1.totalRewardsReceived(), weeklyAmount * 50 / 100);
        assertEq(bribe2.totalRewardsReceived(), weeklyAmount * 30 / 100);
        assertEq(bribe3.totalRewardsReceived(), weeklyAmount * 20 / 100);
    }

    function testCreateBatchWithoutBribeContract() public {
        vm.warp(EPOCH_START);
        uint256 totalAmount = 10_000 * 10 ** 18;
        uint256 totalWeeks = 10;

        vm.startPrank(depositor);
        rewardToken.approve(address(bribeBatches), totalAmount);

        uint256 batchId = bribeBatches.createBatchWithoutBribeContract(address(rewardToken), totalAmount, totalWeeks);
        vm.stopPrank();

        BribeBatches.BribeBatch memory batch = bribeBatches.getBatch(batchId);

        assertEq(batch.batchId, 0);
        assertEq(batch.depositor, depositor);
        assertEq(batch.rewardToken, address(rewardToken));
        assertEq(batch.totalAmount, totalAmount);
        assertEq(batch.totalWeeks, totalWeeks);
        assertEq(batch.weeksExecuted, 0); // No bribes executed yet
        assertEq(uint256(batch.status), uint256(BribeBatches.BatchStatus.PendingBribeContract));
        assertEq(batch.bribeConfig.bribeContracts.length, 0);
    }

    function test_RevertWhen_CreateBatchWithZeroWeeks() public {
        vm.warp(EPOCH_START);
        uint256 totalAmount = 10_000 * 10 ** 18;

        vm.startPrank(depositor);
        rewardToken.approve(address(bribeBatches), totalAmount);

        (address[] memory bribes, uint256[] memory weights) = _singleBribeConfig(address(bribeContract));

        vm.expectRevert(BribeBatches.InvalidWeeks.selector);
        bribeBatches.createBatchWithExistingBribeContract(address(rewardToken), totalAmount, 0, bribes, weights);
        vm.stopPrank();
    }

    function test_RevertWhen_CreateBatchWithZeroAmount() public {
        vm.warp(EPOCH_START);

        vm.startPrank(depositor);
        rewardToken.approve(address(bribeBatches), 0);

        (address[] memory bribes, uint256[] memory weights) = _singleBribeConfig(address(bribeContract));

        vm.expectRevert(BribeBatches.InvalidAmount.selector);
        bribeBatches.createBatchWithExistingBribeContract(address(rewardToken), 0, 10, bribes, weights);
        vm.stopPrank();
    }

    function test_RevertWhen_CreateBatchWithInsufficientAmountPerWeek() public {
        vm.warp(EPOCH_START);
        uint256 totalAmount = 5; // Too small to divide by 10 weeks

        vm.startPrank(depositor);
        rewardToken.approve(address(bribeBatches), totalAmount);

        (address[] memory bribes, uint256[] memory weights) = _singleBribeConfig(address(bribeContract));

        vm.expectRevert(BribeBatches.InvalidAmount.selector);
        bribeBatches.createBatchWithExistingBribeContract(address(rewardToken), totalAmount, 10, bribes, weights);
        vm.stopPrank();
    }

    function test_RevertWhen_CreateBatchWithInvalidWeights() public {
        vm.warp(EPOCH_START);
        uint256 totalAmount = 10_000 * 10 ** 18;

        address[] memory bribes = new address[](2);
        bribes[0] = address(bribeContract);
        bribes[1] = address(new MockBribe());

        uint256[] memory weights = new uint256[](2);
        weights[0] = 5000;
        weights[1] = 4000; // Only sums to 9000, not 10000

        vm.startPrank(depositor);
        rewardToken.approve(address(bribeBatches), totalAmount);

        vm.expectRevert(BribeBatches.InvalidWeights.selector);
        bribeBatches.createBatchWithExistingBribeContract(address(rewardToken), totalAmount, 10, bribes, weights);
        vm.stopPrank();
    }

    function test_RevertWhen_CreateBatchWithMismatchedArrays() public {
        vm.warp(EPOCH_START);
        uint256 totalAmount = 10_000 * 10 ** 18;

        address[] memory bribes = new address[](2);
        bribes[0] = address(bribeContract);
        bribes[1] = address(new MockBribe());

        uint256[] memory weights = new uint256[](1);
        weights[0] = 10000;

        vm.startPrank(depositor);
        rewardToken.approve(address(bribeBatches), totalAmount);

        vm.expectRevert(BribeBatches.InvalidBribeConfig.selector);
        bribeBatches.createBatchWithExistingBribeContract(address(rewardToken), totalAmount, 10, bribes, weights);
        vm.stopPrank();
    }

    /*
     * Batch Execution Tests
     */

    function testExecuteBatchesMultipleWeeks() public {
        vm.warp(EPOCH_START);
        uint256 totalAmount = 10_000 * 10 ** 18;
        uint256 totalWeeks = 5;

        vm.startPrank(depositor);
        rewardToken.approve(address(bribeBatches), totalAmount);
        (address[] memory bribes, uint256[] memory weights) = _singleBribeConfig(address(bribeContract));
        uint256 batchId =
            bribeBatches.createBatchWithExistingBribeContract(address(rewardToken), totalAmount, totalWeeks, bribes, weights);
        vm.stopPrank();

        // Execute remaining weeks
        uint256[] memory batchIds = new uint256[](1);
        batchIds[0] = batchId;

        for (uint256 i = 2; i <= totalWeeks; i++) {
            vm.warp(EPOCH_START + EPOCH_DURATION * i);

            vm.prank(operator);
            bribeBatches.executeBatches(batchIds);

            BribeBatches.BribeBatch memory batch = bribeBatches.getBatch(batchId);
            assertEq(batch.weeksExecuted, i);

            if (i < totalWeeks) {
                assertEq(uint256(batch.status), uint256(BribeBatches.BatchStatus.Active));
            } else {
                assertEq(uint256(batch.status), uint256(BribeBatches.BatchStatus.Finished));
            }
        }

        // Verify total rewards received (accounting for potential dust)
        assertApproxEqAbs(bribeContract.totalRewardsReceived(), totalAmount, 1);
    }

    function testExecuteBatchHandlesDust() public {
        vm.warp(EPOCH_START);
        uint256 totalAmount = 1000; // Amount that doesn't divide evenly by 3
        uint256 totalWeeks = 3;

        vm.startPrank(depositor);
        rewardToken.approve(address(bribeBatches), totalAmount);
        (address[] memory bribes, uint256[] memory weights) = _singleBribeConfig(address(bribeContract));
        uint256 batchId =
            bribeBatches.createBatchWithExistingBribeContract(address(rewardToken), totalAmount, totalWeeks, bribes, weights);
        vm.stopPrank();

        uint256[] memory batchIds = new uint256[](1);
        batchIds[0] = batchId;

        // Execute remaining weeks
        for (uint256 i = 2; i <= totalWeeks; i++) {
            vm.warp(EPOCH_START + EPOCH_DURATION * i);
            vm.prank(operator);
            bribeBatches.executeBatches(batchIds);
        }

        // Last week should include dust, so total should be exact
        assertEq(bribeContract.totalRewardsReceived(), totalAmount);
    }

    function test_RevertWhen_ExecuteTooEarly() public {
        vm.warp(EPOCH_START);
        uint256 totalAmount = 10_000 * 10 ** 18;

        vm.startPrank(depositor);
        rewardToken.approve(address(bribeBatches), totalAmount);
        (address[] memory bribes, uint256[] memory weights) = _singleBribeConfig(address(bribeContract));
        uint256 batchId = bribeBatches.createBatchWithExistingBribeContract(address(rewardToken), totalAmount, 10, bribes, weights);
        vm.stopPrank();

        // Try to execute again in the same epoch
        uint256[] memory batchIds = new uint256[](1);
        batchIds[0] = batchId;

        vm.prank(operator);
        vm.expectRevert(BribeBatches.TooEarlyToExecute.selector);
        bribeBatches.executeBatches(batchIds);
    }

    function test_RevertWhen_ExecuteFinishedBatch() public {
        vm.warp(EPOCH_START);
        uint256 totalAmount = 10_000 * 10 ** 18;
        uint256 totalWeeks = 2;

        vm.startPrank(depositor);
        rewardToken.approve(address(bribeBatches), totalAmount);
        (address[] memory bribes, uint256[] memory weights) = _singleBribeConfig(address(bribeContract));
        uint256 batchId =
            bribeBatches.createBatchWithExistingBribeContract(address(rewardToken), totalAmount, totalWeeks, bribes, weights);
        vm.stopPrank();

        // Execute last week
        uint256[] memory batchIds = new uint256[](1);
        batchIds[0] = batchId;

        vm.warp(EPOCH_START + EPOCH_DURATION * 2);
        vm.prank(operator);
        bribeBatches.executeBatches(batchIds);

        // Try to execute again after finished
        vm.warp(EPOCH_START + EPOCH_DURATION * 3);
        vm.prank(operator);
        vm.expectRevert(BribeBatches.BatchCompleted.selector);
        bribeBatches.executeBatches(batchIds);
    }

    /*
     * Populate Bribe Contract Tests
     */

    function testPopulateBribeContract() public {
        vm.warp(EPOCH_START);
        uint256 totalAmount = 10_000 * 10 ** 18;
        uint256 totalWeeks = 10;

        vm.startPrank(depositor);
        rewardToken.approve(address(bribeBatches), totalAmount);
        uint256 batchId = bribeBatches.createBatchWithoutBribeContract(address(rewardToken), totalAmount, totalWeeks);
        vm.stopPrank();

        // Populate bribe contract
        (address[] memory bribes, uint256[] memory weights) = _singleBribeConfig(address(bribeContract));
        vm.prank(operator);
        bribeBatches.populateBribeContract(batchId, bribes, weights, true);

        BribeBatches.BribeBatch memory batch = bribeBatches.getBatch(batchId);

        assertEq(batch.bribeConfig.bribeContracts[0], address(bribeContract));
        assertEq(batch.weeksExecuted, 1); // First bribe executed immediately
        assertEq(uint256(batch.status), uint256(BribeBatches.BatchStatus.Active));

        // Verify first bribe was sent
        assertEq(bribeContract.totalRewardsReceived(), totalAmount / totalWeeks);
    }

    function test_RevertWhen_PopulateWithInvalidConfig() public {
        vm.warp(EPOCH_START);
        uint256 totalAmount = 10_000 * 10 ** 18;

        vm.startPrank(depositor);
        rewardToken.approve(address(bribeBatches), totalAmount);
        uint256 batchId = bribeBatches.createBatchWithoutBribeContract(address(rewardToken), totalAmount, 10);
        vm.stopPrank();

        address[] memory bribes = new address[](0); // Empty
        uint256[] memory weights = new uint256[](0);

        vm.prank(operator);
        vm.expectRevert(BribeBatches.InvalidBribeConfig.selector);
        bribeBatches.populateBribeContract(batchId, bribes, weights, true);
    }

    function testUpdateBribeContractForActiveBatch() public {
        vm.warp(EPOCH_START);
        uint256 totalAmount = 10_000 * 10 ** 18;

        vm.startPrank(depositor);
        rewardToken.approve(address(bribeBatches), totalAmount);
        (address[] memory bribes, uint256[] memory weights) = _singleBribeConfig(address(bribeContract));
        uint256 batchId = bribeBatches.createBatchWithExistingBribeContract(address(rewardToken), totalAmount, 10, bribes, weights);
        vm.stopPrank();

        MockBribe newBribe = new MockBribe();

        // Should be able to update active batch without executing
        (address[] memory newBribes, uint256[] memory newWeights) = _singleBribeConfig(address(newBribe));
        vm.prank(operator);
        bribeBatches.populateBribeContract(batchId, newBribes, newWeights, false);

        BribeBatches.BribeBatch memory batch = bribeBatches.getBatch(batchId);
        assertEq(batch.bribeConfig.bribeContracts[0], address(newBribe));
        assertEq(batch.weeksExecuted, 1); // Only first bribe was executed, not the second
    }

    function testUpdateBribeContractWithExecution() public {
        vm.warp(EPOCH_START);
        uint256 totalAmount = 10_000 * 10 ** 18;

        vm.startPrank(depositor);
        rewardToken.approve(address(bribeBatches), totalAmount);
        (address[] memory bribes, uint256[] memory weights) = _singleBribeConfig(address(bribeContract));
        uint256 batchId = bribeBatches.createBatchWithExistingBribeContract(address(rewardToken), totalAmount, 10, bribes, weights);
        vm.stopPrank();

        MockBribe newBribe = new MockBribe();

        // Move to next epoch and update with execution
        vm.warp(EPOCH_START + EPOCH_DURATION);
        (address[] memory newBribes, uint256[] memory newWeights) = _singleBribeConfig(address(newBribe));
        vm.prank(operator);
        bribeBatches.populateBribeContract(batchId, newBribes, newWeights, true);

        BribeBatches.BribeBatch memory batch = bribeBatches.getBatch(batchId);
        assertEq(batch.bribeConfig.bribeContracts[0], address(newBribe));
        assertEq(batch.weeksExecuted, 2); // Should have executed second bribe

        // Verify new bribe received funds
        assertEq(newBribe.totalRewardsReceived(), totalAmount / 10);
    }

    function test_RevertWhen_PopulateNonExistentBatch() public {
        (address[] memory bribes, uint256[] memory weights) = _singleBribeConfig(address(bribeContract));
        vm.prank(operator);
        vm.expectRevert(BribeBatches.BatchNotFound.selector);
        bribeBatches.populateBribeContract(999, bribes, weights, true);
    }

    function test_RevertWhen_PopulateFinishedBatch() public {
        vm.warp(EPOCH_START);
        uint256 totalAmount = 10_000 * 10 ** 18;

        vm.startPrank(depositor);
        rewardToken.approve(address(bribeBatches), totalAmount);
        (address[] memory bribes, uint256[] memory weights) = _singleBribeConfig(address(bribeContract));
        uint256 batchId = bribeBatches.createBatchWithExistingBribeContract(address(rewardToken), totalAmount, 1, bribes, weights);
        vm.stopPrank();

        // Batch is finished after creation (only 1 week)
        MockBribe newBribe = new MockBribe();
        (address[] memory newBribes, uint256[] memory newWeights) = _singleBribeConfig(address(newBribe));
        vm.prank(operator);
        vm.expectRevert(BribeBatches.BatchCompleted.selector);
        bribeBatches.populateBribeContract(batchId, newBribes, newWeights, false);
    }

    function test_RevertWhen_PopulateStoppedBatch() public {
        vm.warp(EPOCH_START);
        uint256 totalAmount = 10_000 * 10 ** 18;

        vm.startPrank(depositor);
        rewardToken.approve(address(bribeBatches), totalAmount);
        (address[] memory bribes, uint256[] memory weights) = _singleBribeConfig(address(bribeContract));
        uint256 batchId = bribeBatches.createBatchWithExistingBribeContract(address(rewardToken), totalAmount, 10, bribes, weights);
        vm.stopPrank();

        // Stop the batch
        vm.prank(owner);
        bribeBatches.stopBatch(batchId);

        // Try to update stopped batch
        MockBribe newBribe = new MockBribe();
        (address[] memory newBribes, uint256[] memory newWeights) = _singleBribeConfig(address(newBribe));
        vm.prank(operator);
        vm.expectRevert(BribeBatches.BatchAlreadyStopped.selector);
        bribeBatches.populateBribeContract(batchId, newBribes, newWeights, false);
    }

    /*
     * Stop Batch Tests
     */

    function testStopBatch() public {
        vm.warp(EPOCH_START);
        uint256 totalAmount = 10_000 * 10 ** 18;
        uint256 totalWeeks = 10;

        vm.startPrank(depositor);
        rewardToken.approve(address(bribeBatches), totalAmount);
        (address[] memory bribes, uint256[] memory weights) = _singleBribeConfig(address(bribeContract));
        uint256 batchId = bribeBatches.createBatchWithExistingBribeContract(address(rewardToken), totalAmount, totalWeeks, bribes, weights);
        vm.stopPrank();

        // Stop the batch
        vm.prank(owner);
        bribeBatches.stopBatch(batchId);

        BribeBatches.BribeBatch memory batch = bribeBatches.getBatch(batchId);
        assertEq(uint256(batch.status), uint256(BribeBatches.BatchStatus.Stopped));

        // Verify it's removed from active batches
        BribeBatches.BribeBatch[] memory activeBatches = bribeBatches.getActiveBatches();
        assertEq(activeBatches.length, 0);
    }

    function test_RevertWhen_StopFinishedBatch() public {
        vm.warp(EPOCH_START);
        uint256 totalAmount = 10_000 * 10 ** 18;
        uint256 totalWeeks = 1;

        vm.startPrank(depositor);
        rewardToken.approve(address(bribeBatches), totalAmount);
        (address[] memory bribes, uint256[] memory weights) = _singleBribeConfig(address(bribeContract));
        uint256 batchId =
            bribeBatches.createBatchWithExistingBribeContract(address(rewardToken), totalAmount, totalWeeks, bribes, weights);
        vm.stopPrank();

        // Batch is already finished after creation (only 1 week)
        vm.prank(owner);
        vm.expectRevert(BribeBatches.BatchCompleted.selector);
        bribeBatches.stopBatch(batchId);
    }

    function test_RevertWhen_StopAlreadyStoppedBatch() public {
        vm.warp(EPOCH_START);
        uint256 totalAmount = 10_000 * 10 ** 18;

        vm.startPrank(depositor);
        rewardToken.approve(address(bribeBatches), totalAmount);
        (address[] memory bribes, uint256[] memory weights) = _singleBribeConfig(address(bribeContract));
        uint256 batchId = bribeBatches.createBatchWithExistingBribeContract(address(rewardToken), totalAmount, 10, bribes, weights);
        vm.stopPrank();

        // Stop once
        vm.prank(owner);
        bribeBatches.stopBatch(batchId);

        // Try to stop again
        vm.prank(owner);
        vm.expectRevert(BribeBatches.BatchCompleted.selector);
        bribeBatches.stopBatch(batchId);
    }

    function test_RevertWhen_ExecuteStoppedBatch() public {
        vm.warp(EPOCH_START);
        uint256 totalAmount = 10_000 * 10 ** 18;

        vm.startPrank(depositor);
        rewardToken.approve(address(bribeBatches), totalAmount);
        (address[] memory bribes, uint256[] memory weights) = _singleBribeConfig(address(bribeContract));
        uint256 batchId = bribeBatches.createBatchWithExistingBribeContract(address(rewardToken), totalAmount, 10, bribes, weights);
        vm.stopPrank();

        // Stop the batch
        vm.prank(owner);
        bribeBatches.stopBatch(batchId);

        // Try to execute stopped batch
        uint256[] memory batchIds = new uint256[](1);
        batchIds[0] = batchId;

        vm.warp(EPOCH_START + EPOCH_DURATION * 2);
        vm.prank(operator);
        vm.expectRevert(BribeBatches.BatchAlreadyStopped.selector);
        bribeBatches.executeBatches(batchIds);
    }

    /*
     * Active Batches Tests
     */

    function testGetActiveBatches() public {
        vm.warp(EPOCH_START);
        uint256 totalAmount = 10_000 * 10 ** 18;

        // Create multiple batches
        vm.startPrank(depositor);
        rewardToken.approve(address(bribeBatches), totalAmount * 3);

        (address[] memory bribes, uint256[] memory weights) = _singleBribeConfig(address(bribeContract));

        uint256 batchId1 = bribeBatches.createBatchWithExistingBribeContract(address(rewardToken), totalAmount, 10, bribes, weights);
        uint256 batchId2 = bribeBatches.createBatchWithoutBribeContract(address(rewardToken), totalAmount, 10);
        uint256 batchId3 = bribeBatches.createBatchWithExistingBribeContract(address(rewardToken), totalAmount, 10, bribes, weights);
        vm.stopPrank();

        BribeBatches.BribeBatch[] memory activeBatches = bribeBatches.getActiveBatches();
        assertEq(activeBatches.length, 3);

        // Verify batch IDs
        assertEq(activeBatches[0].batchId, batchId1);
        assertEq(activeBatches[1].batchId, batchId2);
        assertEq(activeBatches[2].batchId, batchId3);
    }

    function testActiveBatchesAfterCompletion() public {
        vm.warp(EPOCH_START);
        uint256 totalAmount = 10_000 * 10 ** 18;
        uint256 totalWeeks = 2;

        vm.startPrank(depositor);
        rewardToken.approve(address(bribeBatches), totalAmount);
        (address[] memory bribes, uint256[] memory weights) = _singleBribeConfig(address(bribeContract));
        uint256 batchId =
            bribeBatches.createBatchWithExistingBribeContract(address(rewardToken), totalAmount, totalWeeks, bribes, weights);
        vm.stopPrank();

        // Initially active
        BribeBatches.BribeBatch[] memory activeBatches = bribeBatches.getActiveBatches();
        assertEq(activeBatches.length, 1);

        // Complete the batch
        uint256[] memory batchIds = new uint256[](1);
        batchIds[0] = batchId;

        vm.warp(EPOCH_START + EPOCH_DURATION * 2);
        vm.prank(operator);
        bribeBatches.executeBatches(batchIds);

        // Should be removed from active
        activeBatches = bribeBatches.getActiveBatches();
        assertEq(activeBatches.length, 0);
    }

    function testGetActiveBatchesPaginated() public {
        vm.warp(EPOCH_START);
        uint256 totalAmount = 10_000 * 10 ** 18;

        // Create 10 batches
        vm.startPrank(depositor);
        rewardToken.approve(address(bribeBatches), totalAmount * 10);

        (address[] memory bribes, uint256[] memory weights) = _singleBribeConfig(address(bribeContract));

        for (uint256 i = 0; i < 10; i++) {
            bribeBatches.createBatchWithExistingBribeContract(address(rewardToken), totalAmount, 10, bribes, weights);
        }
        vm.stopPrank();

        // Test pagination
        (BribeBatches.BribeBatch[] memory page1, uint256 total1) = bribeBatches.getActiveBatchesPaginated(0, 3);
        assertEq(total1, 10);
        assertEq(page1.length, 3);
        assertEq(page1[0].batchId, 0);
        assertEq(page1[1].batchId, 1);
        assertEq(page1[2].batchId, 2);

        // Get next page
        (BribeBatches.BribeBatch[] memory page2, uint256 total2) = bribeBatches.getActiveBatchesPaginated(3, 3);
        assertEq(total2, 10);
        assertEq(page2.length, 3);
        assertEq(page2[0].batchId, 3);
        assertEq(page2[1].batchId, 4);
        assertEq(page2[2].batchId, 5);

        // Get last page (partial)
        (BribeBatches.BribeBatch[] memory page3, uint256 total3) = bribeBatches.getActiveBatchesPaginated(8, 5);
        assertEq(total3, 10);
        assertEq(page3.length, 2); // Only 2 remaining
        assertEq(page3[0].batchId, 8);
        assertEq(page3[1].batchId, 9);

        // Test offset beyond range
        (BribeBatches.BribeBatch[] memory page4, uint256 total4) = bribeBatches.getActiveBatchesPaginated(20, 5);
        assertEq(total4, 10);
        assertEq(page4.length, 0);
    }

    function testGetActiveBatchCount() public {
        vm.warp(EPOCH_START);
        uint256 totalAmount = 10_000 * 10 ** 18;

        assertEq(bribeBatches.getActiveBatchCount(), 0);

        vm.startPrank(depositor);
        rewardToken.approve(address(bribeBatches), totalAmount * 5);

        (address[] memory bribes, uint256[] memory weights) = _singleBribeConfig(address(bribeContract));

        for (uint256 i = 0; i < 5; i++) {
            bribeBatches.createBatchWithExistingBribeContract(address(rewardToken), totalAmount, 10, bribes, weights);
        }
        vm.stopPrank();

        assertEq(bribeBatches.getActiveBatchCount(), 5);
    }

    /*
     * Emergency Recovery Tests
     */

    function testEmergencyRecover() public {
        // Send some tokens to the contract
        uint256 recoverAmount = 5000 * 10 ** 18;
        rewardToken.transfer(address(bribeBatches), recoverAmount);

        uint256 recipientBalanceBefore = rewardToken.balanceOf(user1);

        vm.prank(owner);
        bribeBatches.emergencyRecover(address(rewardToken), recoverAmount, user1);

        uint256 recipientBalanceAfter = rewardToken.balanceOf(user1);
        assertEq(recipientBalanceAfter - recipientBalanceBefore, recoverAmount);
    }

    function test_RevertWhen_EmergencyRecoverZeroToken() public {
        vm.prank(owner);
        vm.expectRevert(BribeBatches.InvalidAddress.selector);
        bribeBatches.emergencyRecover(address(0), 1000, user1);
    }

    function test_RevertWhen_EmergencyRecoverZeroRecipient() public {
        vm.prank(owner);
        vm.expectRevert(BribeBatches.InvalidAddress.selector);
        bribeBatches.emergencyRecover(address(rewardToken), 1000, address(0));
    }

    function test_RevertWhen_EmergencyRecoverZeroAmount() public {
        vm.prank(owner);
        vm.expectRevert(BribeBatches.InvalidAmount.selector);
        bribeBatches.emergencyRecover(address(rewardToken), 0, user1);
    }

    /*
     * Access Control Tests
     */

    function test_RevertWhen_NonOperatorExecutesBatches() public {
        vm.warp(EPOCH_START);
        uint256 totalAmount = 10_000 * 10 ** 18;

        vm.startPrank(depositor);
        rewardToken.approve(address(bribeBatches), totalAmount);
        (address[] memory bribes, uint256[] memory weights) = _singleBribeConfig(address(bribeContract));
        uint256 batchId = bribeBatches.createBatchWithExistingBribeContract(address(rewardToken), totalAmount, 10, bribes, weights);
        vm.stopPrank();

        uint256[] memory batchIds = new uint256[](1);
        batchIds[0] = batchId;

        vm.warp(EPOCH_START + EPOCH_DURATION * 2);
        vm.prank(user1);
        vm.expectRevert();
        bribeBatches.executeBatches(batchIds);
    }

    function test_RevertWhen_NonOperatorPopulatesBribeContract() public {
        vm.warp(EPOCH_START);
        uint256 totalAmount = 10_000 * 10 ** 18;

        vm.startPrank(depositor);
        rewardToken.approve(address(bribeBatches), totalAmount);
        uint256 batchId = bribeBatches.createBatchWithoutBribeContract(address(rewardToken), totalAmount, 10);
        vm.stopPrank();

        (address[] memory bribes, uint256[] memory weights) = _singleBribeConfig(address(bribeContract));

        vm.prank(user1);
        vm.expectRevert();
        bribeBatches.populateBribeContract(batchId, bribes, weights, true);
    }

    function test_RevertWhen_NonAdminStopsBatch() public {
        vm.warp(EPOCH_START);
        uint256 totalAmount = 10_000 * 10 ** 18;

        vm.startPrank(depositor);
        rewardToken.approve(address(bribeBatches), totalAmount);
        (address[] memory bribes, uint256[] memory weights) = _singleBribeConfig(address(bribeContract));
        uint256 batchId = bribeBatches.createBatchWithExistingBribeContract(address(rewardToken), totalAmount, 10, bribes, weights);
        vm.stopPrank();

        vm.prank(user1);
        vm.expectRevert();
        bribeBatches.stopBatch(batchId);
    }

    function test_RevertWhen_NonAdminRecoversTokens() public {
        vm.prank(user1);
        vm.expectRevert();
        bribeBatches.emergencyRecover(address(rewardToken), 1000, user1);
    }

    /*
     * Complex Scenario Tests
     */

    function testMultipleBatchesSameToken() public {
        vm.warp(EPOCH_START);
        uint256 totalAmount = 10_000 * 10 ** 18;

        MockBribe bribe1 = new MockBribe();
        MockBribe bribe2 = new MockBribe();

        vm.startPrank(depositor);
        rewardToken.approve(address(bribeBatches), totalAmount * 2);

        (address[] memory bribes1, uint256[] memory weights1) = _singleBribeConfig(address(bribe1));
        (address[] memory bribes2, uint256[] memory weights2) = _singleBribeConfig(address(bribe2));

        uint256 batchId1 = bribeBatches.createBatchWithExistingBribeContract(address(rewardToken), totalAmount, 5, bribes1, weights1);
        uint256 batchId2 = bribeBatches.createBatchWithExistingBribeContract(address(rewardToken), totalAmount, 10, bribes2, weights2);
        vm.stopPrank();

        uint256[] memory batchIds = new uint256[](2);
        batchIds[0] = batchId1;
        batchIds[1] = batchId2;

        // Execute both batches over multiple weeks
        for (uint256 i = 2; i <= 5; i++) {
            vm.warp(EPOCH_START + EPOCH_DURATION * i);
            vm.prank(operator);
            bribeBatches.executeBatches(batchIds);
        }

        // Batch 1 should be finished
        BribeBatches.BribeBatch memory batch1 = bribeBatches.getBatch(batchId1);
        assertEq(uint256(batch1.status), uint256(BribeBatches.BatchStatus.Finished));
        assertEq(batch1.weeksExecuted, 5);

        // Batch 2 should still be active
        BribeBatches.BribeBatch memory batch2 = bribeBatches.getBatch(batchId2);
        assertEq(uint256(batch2.status), uint256(BribeBatches.BatchStatus.Active));
        assertEq(batch2.weeksExecuted, 5);

        // Active batches should only have batch 2
        BribeBatches.BribeBatch[] memory activeBatches = bribeBatches.getActiveBatches();
        assertEq(activeBatches.length, 1);
        assertEq(activeBatches[0].batchId, batchId2);
    }

    function testBatchCreationIncrementsId() public {
        vm.warp(EPOCH_START);
        uint256 totalAmount = 10_000 * 10 ** 18;

        vm.startPrank(depositor);
        rewardToken.approve(address(bribeBatches), totalAmount * 3);

        (address[] memory bribes, uint256[] memory weights) = _singleBribeConfig(address(bribeContract));

        uint256 batchId1 = bribeBatches.createBatchWithExistingBribeContract(address(rewardToken), totalAmount, 10, bribes, weights);
        uint256 batchId2 = bribeBatches.createBatchWithoutBribeContract(address(rewardToken), totalAmount, 10);
        uint256 batchId3 = bribeBatches.createBatchWithExistingBribeContract(address(rewardToken), totalAmount, 10, bribes, weights);
        vm.stopPrank();

        assertEq(batchId1, 0);
        assertEq(batchId2, 1);
        assertEq(batchId3, 2);
        assertEq(bribeBatches.nextBatchId(), 3);
    }
}


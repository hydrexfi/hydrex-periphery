// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/*
    __  __          __                 _____ 
   / / / /_  ______/ /_______  _  __  / __(_)
  / /_/ / / / / __  / ___/ _ \| |/_/ / /_/ / 
 / __  / /_/ / /_/ / /  /  __/>  <_ / __/ /  
/_/ /_/\__, /\__,_/_/   \___/_/|_(_)_/ /_/   
      /____/                                 

*/

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

interface IBribe {
    function notifyRewardAmount(address _rewardsToken, uint256 reward) external;
}

/**
 * @title BribeBatches
 * @notice Utility contract for partners to deposit incentives and spread them over multiple weeks
 * @dev Supports both existing gauges (bribes immediately) and pending gauges (operator populates later)
 *      Uses epoch-based timing - bribes can only be executed once per epoch (no two bribes in same epoch)
 */
contract BribeBatches is AccessControl {
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    /// @notice Timestamp of epoch 0
    uint256 public constant EPOCH_START = 1757548800;

    /// @notice Duration of each epoch (1 week)
    uint256 public constant EPOCH_DURATION = 1 weeks;

    enum BatchStatus {
        PendingBribeContract, // Awaiting bribe contract - no bribe contract address set yet
        Active, // Bribe contract set AND first bribe has been placed
        Finished, // All weekly bribes completed
        Stopped // Manually stopped by admin
    }

    struct BribeBatch {
        uint256 batchId; // ID of this batch
        address depositor; // Address who deposited the batch
        address rewardToken; // Token to be used for bribes
        uint256 totalAmount; // Total amount of tokens
        uint256 totalWeeks; // Total number of weeks to spread over
        uint256 weeksExecuted; // Number of weeks already executed
        uint256 startTime; // Timestamp when batch was created
        uint256 lastExecutedEpoch; // Last epoch when bribe was executed (0 = never executed)
        BatchStatus status; // Current status of the batch
        address bribeContract; // Bribe contract address (set when populated)
    }

    /// @notice Mapping from batch ID to batch info
    mapping(uint256 => BribeBatch) public batches;

    /// @notice Counter for batch IDs
    uint256 public nextBatchId;

    /// @notice Array of all batch IDs that are still active
    uint256[] private activeBatchIds;

    /// @notice Mapping to track batch ID index in activeBatchIds array
    mapping(uint256 => uint256) private batchIdToIndex;

    /// @notice Mapping to track if a batch is in the active array
    mapping(uint256 => bool) private isBatchActive;

    event BatchCreated(
        uint256 indexed batchId,
        address indexed depositor,
        address rewardToken,
        uint256 totalAmount,
        uint256 totalWeeks,
        BatchStatus status,
        address bribeContract
    );
    event BatchExecuted(
        uint256 indexed batchId,
        address indexed depositor,
        address indexed bribeContract,
        address rewardToken,
        uint256 weekNumber,
        uint256 totalWeeks,
        uint256 amount
    );
    event BribeContractPopulated(uint256 indexed batchId, address bribeContract);
    event BatchStopped(uint256 indexed batchId, uint256 remainingAmount);

    error InvalidWeeks();
    error InvalidAmount();
    error BatchNotFound();
    error BatchCompleted();
    error BatchNotPendingBribeContract();
    error BatchNotActive();
    error BatchAlreadyStopped();
    error TooEarlyToExecute();
    error InvalidBribeAddress();
    error InvalidAddress();

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
    }

    /*
     * View Functions
     */

    /**
     * @notice Get the current epoch number
     */
    function getCurrentEpoch() public view returns (uint256) {
        if (block.timestamp < EPOCH_START) return 0;
        return (block.timestamp - EPOCH_START) / EPOCH_DURATION;
    }

    /**
     * @notice Get batch information
     * @param batchId ID of the batch
     */
    function getBatch(uint256 batchId) external view returns (BribeBatch memory) {
        return batches[batchId];
    }

    /**
     * @notice Get all active batches (pending or executing)
     * @return batchData Array of batch data (each includes its batchId)
     */
    function getActiveBatches() external view returns (BribeBatch[] memory batchData) {
        uint256 activeCount = activeBatchIds.length;
        batchData = new BribeBatch[](activeCount);

        for (uint256 i = 0; i < activeCount; i++) {
            batchData[i] = batches[activeBatchIds[i]];
        }

        return batchData;
    }

    /*
     * External Functions
     */

    /**
     * @notice Create a new bribe batch with an existing bribe contract
     * @dev IMPORTANT: First bribe is ALWAYS triggered immediately when bribe contract is set
     *      This ensures we never set a bribe contract without an initial bribe placement
     * @param rewardToken Token to be used for bribes
     * @param totalAmount Total amount to distribute
     * @param totalWeeks Number of weeks to spread over
     * @param bribeContract Address of the bribe contract
     */
    function createBatchWithExistingBribeContract(
        address rewardToken,
        uint256 totalAmount,
        uint256 totalWeeks,
        address bribeContract
    ) external returns (uint256 batchId) {
        if (bribeContract == address(0)) revert InvalidBribeAddress();
        batchId = _createBatch(rewardToken, totalAmount, totalWeeks, bribeContract, BatchStatus.PendingBribeContract);
        // MUST trigger first bribe to transition to Active status
        _executeBribe(batchId);
    }

    /**
     * @notice Create a new bribe batch without bribe contract (will be set later)
     * @param rewardToken Token to be used for bribes
     * @param totalAmount Total amount to distribute
     * @param totalWeeks Number of weeks to spread over
     */
    function createBatchWithoutBribeContract(
        address rewardToken,
        uint256 totalAmount,
        uint256 totalWeeks
    ) external returns (uint256 batchId) {
        batchId = _createBatch(rewardToken, totalAmount, totalWeeks, address(0), BatchStatus.PendingBribeContract);
    }

    /*
     * Internal Functions
     */

    /**
     * @notice Internal function to create a batch
     */
    function _createBatch(
        address rewardToken,
        uint256 totalAmount,
        uint256 totalWeeks,
        address bribeContract,
        BatchStatus status
    ) internal returns (uint256 batchId) {
        if (totalWeeks == 0) revert InvalidWeeks();
        if (totalAmount == 0 || totalAmount / totalWeeks == 0) revert InvalidAmount();

        batchId = nextBatchId++;
        IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), totalAmount);

        batches[batchId] = BribeBatch({
            batchId: batchId,
            depositor: msg.sender,
            rewardToken: rewardToken,
            totalAmount: totalAmount,
            totalWeeks: totalWeeks,
            weeksExecuted: 0,
            startTime: block.timestamp,
            lastExecutedEpoch: 0,
            status: status,
            bribeContract: bribeContract
        });

        // Track in active batches
        isBatchActive[batchId] = true;
        batchIdToIndex[batchId] = activeBatchIds.length;
        activeBatchIds.push(batchId);

        emit BatchCreated(batchId, msg.sender, rewardToken, totalAmount, totalWeeks, status, bribeContract);
    }

    /**
     * @notice Internal function to execute a bribe
     * @dev Transitions batch from PendingBribeContract -> Active on first bribe, and Active -> Finished on completion
     *      Enforces that bribes can only happen once per epoch (no two bribes in same epoch)
     * @param batchId ID of the batch to execute
     */
    function _executeBribe(uint256 batchId) internal {
        BribeBatch storage batch = batches[batchId];

        if (batch.totalAmount == 0) revert BatchNotFound();
        if (batch.status == BatchStatus.Stopped) revert BatchAlreadyStopped();
        if (batch.status == BatchStatus.Finished) revert BatchCompleted();
        if (batch.weeksExecuted >= batch.totalWeeks) revert BatchCompleted();

        uint256 currentEpoch = getCurrentEpoch();

        // Check epoch timing: can't execute twice in the same epoch
        if (batch.status == BatchStatus.Active) {
            if (currentEpoch <= batch.lastExecutedEpoch) {
                revert TooEarlyToExecute();
            }
        }

        // Transition to Active on first bribe (bribe address must be set)
        if (batch.status == BatchStatus.PendingBribeContract) {
            if (batch.bribeContract == address(0)) revert BatchNotActive();
            batch.status = BatchStatus.Active;
        }

        // Update last executed epoch
        batch.lastExecutedEpoch = currentEpoch;

        // Calculate amount - handle dust on last week
        uint256 weeklyAmount = batch.totalAmount / batch.totalWeeks;
        uint256 amount = (batch.weeksExecuted == batch.totalWeeks - 1)
            ? batch.totalAmount - (weeklyAmount * batch.weeksExecuted)
            : weeklyAmount;

        uint256 weekNumber = ++batch.weeksExecuted;

        // Transition to Finished and remove from active tracking if completed
        if (batch.weeksExecuted >= batch.totalWeeks) {
            batch.status = BatchStatus.Finished;
            _removeBatchFromActive(batchId);
        }

        IERC20(batch.rewardToken).approve(batch.bribeContract, amount);
        IBribe(batch.bribeContract).notifyRewardAmount(batch.rewardToken, amount);

        emit BatchExecuted(
            batchId,
            batch.depositor,
            batch.bribeContract,
            batch.rewardToken,
            weekNumber,
            batch.totalWeeks,
            amount
        );
    }

    /**
     * @notice Remove a batch from active tracking
     */
    function _removeBatchFromActive(uint256 batchId) internal {
        if (!isBatchActive[batchId]) return;

        uint256 index = batchIdToIndex[batchId];
        uint256 lastIndex = activeBatchIds.length - 1;

        // Swap with last element and pop
        if (index != lastIndex) {
            uint256 lastBatchId = activeBatchIds[lastIndex];
            activeBatchIds[index] = lastBatchId;
            batchIdToIndex[lastBatchId] = index;
        }

        activeBatchIds.pop();
        delete batchIdToIndex[batchId];
        delete isBatchActive[batchId];
    }

    /*
     * Admin Functions
     */

    /**
     * @notice Execute multiple batches in a single transaction
     * @param batchIds Array of batch IDs to execute
     */
    function executeBatches(uint256[] calldata batchIds) external onlyRole(OPERATOR_ROLE) {
        uint256 len = batchIds.length;
        for (uint256 i = 0; i < len; i++) {
            _executeBribe(batchIds[i]);
        }
    }

    /**
     * @notice Populate a pending batch with bribe contract address
     * @dev IMPORTANT: First bribe is ALWAYS triggered when bribe contract is populated
     *      This ensures we never set a bribe contract without an initial bribe placement
     * @param batchId ID of the batch to populate
     * @param bribeContract Address of the bribe contract
     */
    function populateBribeContract(uint256 batchId, address bribeContract) external onlyRole(OPERATOR_ROLE) {
        BribeBatch storage batch = batches[batchId];
        if (batch.totalAmount == 0) revert BatchNotFound();
        if (batch.status != BatchStatus.PendingBribeContract) revert BatchNotPendingBribeContract();
        if (bribeContract == address(0)) revert InvalidBribeAddress();

        batch.bribeContract = bribeContract;

        emit BribeContractPopulated(batchId, bribeContract);

        // MUST trigger first bribe to transition to Active status
        _executeBribe(batchId);
    }

    /**
     * @notice Manually stop a batch
     * @dev Funds remain in contract and can be recovered via emergencyRecover if needed
     * @param batchId ID of the batch to stop
     */
    function stopBatch(uint256 batchId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        BribeBatch storage batch = batches[batchId];
        if (batch.totalAmount == 0) revert BatchNotFound();
        if (batch.status == BatchStatus.Finished || batch.status == BatchStatus.Stopped) revert BatchCompleted();

        // Calculate remaining amount for event
        uint256 weeklyAmount = batch.totalAmount / batch.totalWeeks;
        uint256 alreadyDistributed = weeklyAmount * batch.weeksExecuted;
        uint256 remainingAmount = batch.totalAmount - alreadyDistributed;

        // Update status
        batch.status = BatchStatus.Stopped;

        // Remove from active tracking
        _removeBatchFromActive(batchId);

        emit BatchStopped(batchId, remainingAmount);
    }

    /**
     * @notice Emergency function to recover any stuck tokens
     * @param token Token address to recover
     * @param amount Amount to recover
     * @param recipient Address to send recovered tokens to
     */
    function emergencyRecover(address token, uint256 amount, address recipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0) || recipient == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();

        IERC20(token).transfer(recipient, amount);
    }
}

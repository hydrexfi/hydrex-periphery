// SPDX-License-Identifier: BUSL-1.1
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
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title HydrexMultichainAuctionRouter
 * @notice Cross-chain intent escrow with Dutch auction pricing.
 *
 * Users lock an input token (e.g. USDC) and specify the output token they want
 * (e.g. a Solana token bridged to Base). The required output starts at `desiredOutput`
 * and decays linearly to `minOutput` over `auctionSeconds`, incentivising solvers to
 * fill quickly. The first solver to settle wins the input tokens.
 *
 * Bridge flow (Solana → Base):
 *   Solver sets bridge tx with `to = address(this)` and calldata = fill(...).
 *   The bridge mints output tokens to this contract then executes fill() atomically.
 *
 * Base-native flow:
 *   Solver calls fillWithTransfer(), which pulls tokens and settles in one transaction.
 *
 * Rebasing tokens are not supported.
 */
contract HydrexMultichainAuctionRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Constants ────────────────────────────────────────────────────────────

    /// @notice Maximum auction duration.
    uint64 public constant MAX_AUCTION_SECONDS = 15 minutes;

    /// @notice Grace period after the auction price window closes during which fill() still succeeds.
    /// Protects solvers against bridge relay delays: a bridge tx submitted near auction end has
    /// this window to finalize on Base. During the buffer the price is locked at minOutput.
    /// Cancel is delayed by the same amount so an in-flight bridge tx cannot race a cancellation.
    uint64 public constant FILL_BUFFER = 10 seconds;

    // ─── Types ────────────────────────────────────────────────────────────────

    enum IntentStatus {
        Active,
        Filled,
        Cancelled
    }

    struct Intent {
        address user;
        address inputToken;
        uint256 inputAmount;
        address outputToken;
        uint256 desiredOutput;
        uint256 minOutput;
        uint64 auctionSeconds;
        uint64 startTime;
        address recipient;
        IntentStatus status;
    }

    // ─── State ────────────────────────────────────────────────────────────────

    address public immutable owner;

    mapping(bytes32 => Intent) public intents;
    mapping(address => uint256) private _nonces;
    mapping(address => uint256) private _reservedInput;

    // ─── Events ───────────────────────────────────────────────────────────────

    event IntentCreated(
        bytes32 indexed intentId,
        address indexed user,
        address inputToken,
        uint256 inputAmount,
        address outputToken,
        uint256 desiredOutput,
        uint256 minOutput,
        uint64 auctionSeconds,
        address recipient,
        uint64 startTime
    );

    event IntentFilled(
        bytes32 indexed intentId,
        address indexed filler,
        uint256 outputAmount,
        uint256 requiredAtFill,
        address inputRecipient
    );

    event IntentCancelled(bytes32 indexed intentId);

    // ─── Errors ───────────────────────────────────────────────────────────────

    error Unauthorized();
    error InvalidAuctionParams();
    error InvalidAmount();
    error InvalidAddress();
    error IntentNotActive();
    error AuctionExpired();
    error AuctionNotExpired();
    error InsufficientOutput();
    error OutputTokensNotReceived();
    error RescueExceedsAvailable();

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor() {
        owner = msg.sender;
    }

    // ─── User ─────────────────────────────────────────────────────────────────

    /**
     * @notice Lock `inputToken` and open a Dutch-auction fill request.
     *
     * The auction price starts at `desiredOutput` and falls linearly to `minOutput`
     * over `auctionSeconds`. After that window the intent expires and can be cancelled.
     *
     * @param inputToken     Token to lock (e.g. USDC). Must be approved first.
     * @param inputAmount    Amount to lock. Stored as the amount actually received,
     *                       so fee-on-transfer tokens are handled correctly.
     * @param outputToken    Token the solver must deliver (e.g. wrapped Solana token).
     * @param desiredOutput  Starting required output — highest price, asked at t=0.
     * @param minOutput      Floor required output — reached at expiry.
     * @param auctionSeconds Auction duration in seconds. Max: MAX_AUCTION_SECONDS.
     * @param recipient      Address to receive output tokens. Defaults to msg.sender if zero.
     * @return intentId      Identifier for this intent. Pass to solvers off-chain.
     */
    function createIntent(
        address inputToken,
        uint256 inputAmount,
        address outputToken,
        uint256 desiredOutput,
        uint256 minOutput,
        uint64 auctionSeconds,
        address recipient
    ) external nonReentrant returns (bytes32 intentId) {
        if (auctionSeconds == 0 || auctionSeconds > MAX_AUCTION_SECONDS) revert InvalidAuctionParams();
        if (desiredOutput == 0 || minOutput == 0) revert InvalidAmount();
        if (desiredOutput < minOutput) revert InvalidAuctionParams();
        if (inputAmount == 0) revert InvalidAmount();
        if (inputToken == address(0) || outputToken == address(0)) revert InvalidAddress();

        intentId = keccak256(abi.encode(msg.sender, _nonces[msg.sender]++));

        address to = recipient == address(0) ? msg.sender : recipient;
        uint64 startTime = uint64(block.timestamp);

        uint256 balanceBefore = IERC20(inputToken).balanceOf(address(this));
        IERC20(inputToken).safeTransferFrom(msg.sender, address(this), inputAmount);
        uint256 received = IERC20(inputToken).balanceOf(address(this)) - balanceBefore;

        if (received == 0) revert InvalidAmount();

        intents[intentId] = Intent({
            user: msg.sender,
            inputToken: inputToken,
            inputAmount: received,
            outputToken: outputToken,
            desiredOutput: desiredOutput,
            minOutput: minOutput,
            auctionSeconds: auctionSeconds,
            startTime: startTime,
            recipient: to,
            status: IntentStatus.Active
        });

        _reservedInput[inputToken] += received;

        emit IntentCreated(
            intentId,
            msg.sender,
            inputToken,
            received,
            outputToken,
            desiredOutput,
            minOutput,
            auctionSeconds,
            to,
            startTime
        );
    }

    /**
     * @notice Cancel an expired intent and return locked tokens to the user.
     *
     * Callable by anyone once `auctionSeconds + FILL_BUFFER` have elapsed — not just the
     * intent creator. The extra FILL_BUFFER delay ensures an in-flight bridge tx submitted
     * near auction end has time to land before the intent can be cancelled.
     * Tokens always return to the original user regardless of who triggers the cancel.
     */
    function cancel(bytes32 intentId) external nonReentrant {
        Intent storage intent = intents[intentId];

        if (intent.status != IntentStatus.Active) revert IntentNotActive();
        if (block.timestamp < uint256(intent.startTime) + uint256(intent.auctionSeconds) + uint256(FILL_BUFFER))
            revert AuctionNotExpired();

        intent.status = IntentStatus.Cancelled;
        _reservedInput[intent.inputToken] -= intent.inputAmount;

        IERC20(intent.inputToken).safeTransfer(intent.user, intent.inputAmount);

        emit IntentCancelled(intentId);
    }

    // ─── Solver ───────────────────────────────────────────────────────────────

    /**
     * @notice Settle an intent. Output tokens must already be in this contract.
     *
     * Used with the Solana bridge: set the bridge destination to `address(this)` and
     * attach `fill(intentId, outputAmount, inputRecipient)` as calldata. The bridge
     * mints tokens here then executes fill() atomically.
     *
     * Fill is accepted for `auctionSeconds + FILL_BUFFER` from intent creation.
     * After `auctionSeconds` the price locks at `minOutput` for the remainder of the buffer.
     *
     * @param intentId       Intent to settle.
     * @param outputAmount   Amount of outputToken deposited to this contract.
     * @param inputRecipient Address to receive the locked input tokens.
     */
    function fill(bytes32 intentId, uint256 outputAmount, address inputRecipient) external nonReentrant {
        _fill(intentId, outputAmount, inputRecipient);
    }

    /**
     * @notice Settle an intent, pulling output tokens from the caller in the same transaction.
     *
     * For Base-native solvers. Approve this contract for `outputAmount` of the intent's
     * outputToken before calling. Combines the token transfer and settlement atomically
     * to prevent front-running.
     *
     * @param intentId       Intent to settle.
     * @param outputAmount   Amount of outputToken to pull from caller.
     * @param inputRecipient Address to receive the locked input tokens.
     */
    function fillWithTransfer(bytes32 intentId, uint256 outputAmount, address inputRecipient) external nonReentrant {
        IERC20(intents[intentId].outputToken).safeTransferFrom(msg.sender, address(this), outputAmount);
        _fill(intentId, outputAmount, inputRecipient);
    }

    // ─── Owner ────────────────────────────────────────────────────────────────

    /**
     * @notice Recover tokens that are not reserved for user intents.
     *
     * Covers stuck output tokens from failed fills and surplus left after settlement.
     * Cannot touch input tokens locked in active intents — those are always user-owned.
     */
    function rescue(address token, address to, uint256 amount) external {
        if (msg.sender != owner) revert Unauthorized();

        uint256 available = IERC20(token).balanceOf(address(this));
        uint256 reserved = _reservedInput[token];
        if (amount > (available > reserved ? available - reserved : 0)) revert RescueExceedsAvailable();

        IERC20(token).safeTransfer(to, amount);
    }

    // ─── Views ────────────────────────────────────────────────────────────────

    /// @notice Returns the full intent struct for a given intentId.
    function getIntent(bytes32 intentId) external view returns (Intent memory) {
        return intents[intentId];
    }

    /// @notice Current auction price for an intent.
    /// Returns minOutput during the FILL_BUFFER grace period. Returns 0 if fully expired or not active.
    function currentRequiredOutput(bytes32 intentId) external view returns (uint256) {
        Intent storage intent = intents[intentId];
        if (intent.status != IntentStatus.Active) return 0;
        if (block.timestamp >= uint256(intent.startTime) + uint256(intent.auctionSeconds) + uint256(FILL_BUFFER))
            return 0;
        return _currentRequiredOutput(intent);
    }

    /// @notice Total input tokens currently locked across all active intents for a token.
    function reservedInput(address token) external view returns (uint256) {
        return _reservedInput[token];
    }

    /// @notice Unallocated token balance available for settlement or rescue.
    function freeBalance(address token) external view returns (uint256) {
        uint256 total = IERC20(token).balanceOf(address(this));
        uint256 reserved = _reservedInput[token];
        return total > reserved ? total - reserved : 0;
    }

    /// @notice Current nonce for a user, useful for pre-computing an intentId off-chain.
    function nonce(address user) external view returns (uint256) {
        return _nonces[user];
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    function _fill(bytes32 intentId, uint256 outputAmount, address inputRecipient) internal {
        Intent storage intent = intents[intentId];

        if (intent.status != IntentStatus.Active) revert IntentNotActive();
        if (block.timestamp >= uint256(intent.startTime) + uint256(intent.auctionSeconds) + uint256(FILL_BUFFER))
            revert AuctionExpired();
        if (inputRecipient == address(0)) revert InvalidAddress();

        uint256 required = _currentRequiredOutput(intent);
        if (outputAmount < required) revert InsufficientOutput();

        uint256 totalBalance = IERC20(intent.outputToken).balanceOf(address(this));
        uint256 reservedAsInput = _reservedInput[intent.outputToken];
        uint256 availableBalance = totalBalance > reservedAsInput ? totalBalance - reservedAsInput : 0;

        if (availableBalance < outputAmount) revert OutputTokensNotReceived();

        intent.status = IntentStatus.Filled;
        _reservedInput[intent.inputToken] -= intent.inputAmount;

        IERC20(intent.outputToken).safeTransfer(intent.recipient, outputAmount);
        IERC20(intent.inputToken).safeTransfer(inputRecipient, intent.inputAmount);

        emit IntentFilled(intentId, msg.sender, outputAmount, required, inputRecipient);
    }

    function _currentRequiredOutput(Intent storage intent) internal view returns (uint256) {
        uint256 elapsed = block.timestamp - uint256(intent.startTime);
        uint256 duration = uint256(intent.auctionSeconds);

        if (elapsed >= duration) return intent.minOutput;

        uint256 spread = intent.desiredOutput - intent.minOutput;
        uint256 decay = (spread * elapsed) / duration;
        return intent.desiredOutput - decay;
    }
}

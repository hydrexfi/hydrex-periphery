// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {HydrexMultichainAuctionRouter} from "../../contracts/bridge/HydrexMultichainAuctionRouter.sol";

// ─── Mocks ────────────────────────────────────────────────────────────────────

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Burns a fixed fee on every transfer to simulate fee-on-transfer tokens.
contract FeeOnTransferERC20 is ERC20 {
    uint256 public immutable feeBps; // basis points burned per transfer

    constructor(uint256 _feeBps) ERC20("Fee Token", "FEE") {
        feeBps = _feeBps;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = (amount * feeBps) / 10_000;
            super._update(from, address(0), fee); // burn fee
            super._update(from, to, amount - fee);
        } else {
            super._update(from, to, amount);
        }
    }
}

// ─── Tests ────────────────────────────────────────────────────────────────────

contract HydrexMultichainAuctionRouterTest is Test {
    HydrexMultichainAuctionRouter public router;
    MockERC20 public usdc;
    MockERC20 public wMeme;

    address public owner = address(this);
    address public user = address(0xA1);
    address public solver = address(0xB2);
    address public solverRecipient = address(0xC3);
    address public userRecipient = address(0xD4);

    // Default auction params
    uint256 constant INPUT_AMOUNT = 1000e6; // 1000 USDC
    uint256 constant DESIRED_OUTPUT = 1000e18; // 1000 wMEME at start
    uint256 constant MIN_OUTPUT = 500e18; // 500 wMEME at floor
    uint64 constant AUCTION_SECONDS = 300; // 5 minutes

    function setUp() public {
        router = new HydrexMultichainAuctionRouter();
        usdc = new MockERC20("USD Coin", "USDC");
        wMeme = new MockERC20("Wrapped MEME", "wMEME");

        usdc.mint(user, 10_000e6);
        wMeme.mint(solver, 10_000e18);

        vm.prank(user);
        usdc.approve(address(router), type(uint256).max);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    function _createIntent() internal returns (bytes32 intentId) {
        vm.prank(user);
        intentId = router.createIntent(
            address(usdc),
            INPUT_AMOUNT,
            address(wMeme),
            DESIRED_OUTPUT,
            MIN_OUTPUT,
            AUCTION_SECONDS,
            userRecipient
        );
    }

    function _solverFill(bytes32 intentId, uint256 outputAmount) internal {
        vm.prank(solver);
        wMeme.transfer(address(router), outputAmount);
        vm.prank(solver);
        router.fill(intentId, outputAmount, solverRecipient);
    }

    // ─── createIntent ─────────────────────────────────────────────────────────

    function test_createIntent_basic() public {
        bytes32 intentId = _createIntent();

        HydrexMultichainAuctionRouter.Intent memory intent = router.getIntent(intentId);

        assertEq(intent.user, user);
        assertEq(intent.inputToken, address(usdc));
        assertEq(intent.inputAmount, INPUT_AMOUNT);
        assertEq(intent.outputToken, address(wMeme));
        assertEq(intent.desiredOutput, DESIRED_OUTPUT);
        assertEq(intent.minOutput, MIN_OUTPUT);
        assertEq(intent.auctionSeconds, AUCTION_SECONDS);
        assertEq(intent.recipient, userRecipient);
        assertEq(uint8(intent.status), uint8(HydrexMultichainAuctionRouter.IntentStatus.Active));

        assertEq(usdc.balanceOf(address(router)), INPUT_AMOUNT);
        assertEq(router.reservedInput(address(usdc)), INPUT_AMOUNT);
    }

    function test_createIntent_defaultsRecipientToSender() public {
        vm.prank(user);
        bytes32 intentId = router.createIntent(
            address(usdc), INPUT_AMOUNT, address(wMeme), DESIRED_OUTPUT, MIN_OUTPUT, AUCTION_SECONDS,
            address(0)
        );

        assertEq(router.getIntent(intentId).recipient, user);
    }

    function test_createIntent_multipleIntents_nonceIncrement() public {
        bytes32 id1 = _createIntent();
        usdc.mint(user, INPUT_AMOUNT);
        bytes32 id2 = _createIntent();

        assertTrue(id1 != id2);
        assertEq(router.nonce(user), 2);
    }

    function test_createIntent_reverts_zeroAuctionSeconds() public {
        vm.prank(user);
        vm.expectRevert(HydrexMultichainAuctionRouter.InvalidAuctionParams.selector);
        router.createIntent(address(usdc), INPUT_AMOUNT, address(wMeme), DESIRED_OUTPUT, MIN_OUTPUT, 0, userRecipient);
    }

    // Fix #3: auction seconds exceeding MAX_AUCTION_SECONDS reverts
    function test_createIntent_reverts_auctionSecondsTooLong() public {
        uint64 tooLong = router.MAX_AUCTION_SECONDS() + 1;
        vm.prank(user);
        vm.expectRevert(HydrexMultichainAuctionRouter.InvalidAuctionParams.selector);
        router.createIntent(address(usdc), INPUT_AMOUNT, address(wMeme), DESIRED_OUTPUT, MIN_OUTPUT, tooLong, userRecipient);
    }

    function test_createIntent_atMaxAuctionSeconds_succeeds() public {
        uint64 maxSeconds = router.MAX_AUCTION_SECONDS();
        vm.prank(user);
        bytes32 intentId = router.createIntent(
            address(usdc), INPUT_AMOUNT, address(wMeme), DESIRED_OUTPUT, MIN_OUTPUT, maxSeconds, userRecipient
        );
        assertEq(router.getIntent(intentId).auctionSeconds, maxSeconds);
    }

    function test_createIntent_reverts_desiredBelowMin() public {
        vm.prank(user);
        vm.expectRevert(HydrexMultichainAuctionRouter.InvalidAuctionParams.selector);
        router.createIntent(
            address(usdc), INPUT_AMOUNT, address(wMeme),
            MIN_OUTPUT - 1,
            MIN_OUTPUT, AUCTION_SECONDS, userRecipient
        );
    }

    function test_createIntent_reverts_zeroAmounts() public {
        vm.prank(user);
        vm.expectRevert(HydrexMultichainAuctionRouter.InvalidAmount.selector);
        router.createIntent(address(usdc), 0, address(wMeme), DESIRED_OUTPUT, MIN_OUTPUT, AUCTION_SECONDS, userRecipient);

        vm.prank(user);
        vm.expectRevert(HydrexMultichainAuctionRouter.InvalidAmount.selector);
        router.createIntent(address(usdc), INPUT_AMOUNT, address(wMeme), 0, MIN_OUTPUT, AUCTION_SECONDS, userRecipient);

        vm.prank(user);
        vm.expectRevert(HydrexMultichainAuctionRouter.InvalidAmount.selector);
        router.createIntent(address(usdc), INPUT_AMOUNT, address(wMeme), DESIRED_OUTPUT, 0, AUCTION_SECONDS, userRecipient);
    }

    function test_createIntent_reverts_zeroAddresses() public {
        vm.prank(user);
        vm.expectRevert(HydrexMultichainAuctionRouter.InvalidAddress.selector);
        router.createIntent(address(0), INPUT_AMOUNT, address(wMeme), DESIRED_OUTPUT, MIN_OUTPUT, AUCTION_SECONDS, userRecipient);

        vm.prank(user);
        vm.expectRevert(HydrexMultichainAuctionRouter.InvalidAddress.selector);
        router.createIntent(address(usdc), INPUT_AMOUNT, address(0), DESIRED_OUTPUT, MIN_OUTPUT, AUCTION_SECONDS, userRecipient);
    }

    // Fix #2: fee-on-transfer token — stored inputAmount is the received delta, not the requested amount
    function test_createIntent_feeOnTransfer_storesReceivedAmount() public {
        uint256 feeBps = 100; // 1% fee
        FeeOnTransferERC20 feeToken = new FeeOnTransferERC20(feeBps);

        feeToken.mint(user, 10_000e18);
        vm.prank(user);
        feeToken.approve(address(router), type(uint256).max);

        uint256 requestedAmount = 1000e18;
        uint256 expectedReceived = requestedAmount - (requestedAmount * feeBps / 10_000); // 990e18

        vm.prank(user);
        bytes32 intentId = router.createIntent(
            address(feeToken), requestedAmount, address(wMeme),
            DESIRED_OUTPUT, MIN_OUTPUT, AUCTION_SECONDS, userRecipient
        );

        HydrexMultichainAuctionRouter.Intent memory intent = router.getIntent(intentId);
        assertEq(intent.inputAmount, expectedReceived, "inputAmount should be actual received amount");
        assertEq(router.reservedInput(address(feeToken)), expectedReceived);
        assertEq(feeToken.balanceOf(address(router)), expectedReceived);
    }

    // Fix #2: solver receives the actual deposited amount, not more
    function test_fill_feeOnTransfer_solverReceivesCorrectAmount() public {
        uint256 feeBps = 100; // 1%
        FeeOnTransferERC20 feeToken = new FeeOnTransferERC20(feeBps);
        feeToken.mint(user, 10_000e18);
        vm.prank(user);
        feeToken.approve(address(router), type(uint256).max);

        uint256 requestedAmount = 1000e18;
        uint256 expectedReceived = requestedAmount - (requestedAmount * feeBps / 10_000);

        vm.prank(user);
        bytes32 intentId = router.createIntent(
            address(feeToken), requestedAmount, address(wMeme),
            DESIRED_OUTPUT, MIN_OUTPUT, AUCTION_SECONDS, userRecipient
        );

        // Solver fills
        vm.prank(solver);
        wMeme.transfer(address(router), DESIRED_OUTPUT);
        vm.prank(solver);
        router.fill(intentId, DESIRED_OUTPUT, solverRecipient);

        // Solver's feeToken recipient gets the actual received amount (post-fee)
        // Note: another fee is taken on the transfer out, so solver gets expectedReceived minus fee
        uint256 solverReceivedAfterSecondFee = expectedReceived - (expectedReceived * feeBps / 10_000);
        assertEq(feeToken.balanceOf(solverRecipient), solverReceivedAfterSecondFee);
    }

    // ─── Dutch auction price curve ─────────────────────────────────────────────

    function test_currentRequiredOutput_atStart() public {
        bytes32 intentId = _createIntent();
        assertEq(router.currentRequiredOutput(intentId), DESIRED_OUTPUT);
    }

    function test_currentRequiredOutput_halfwayThrough() public {
        bytes32 intentId = _createIntent();
        vm.warp(block.timestamp + AUCTION_SECONDS / 2);
        uint256 expected = (DESIRED_OUTPUT + MIN_OUTPUT) / 2;
        assertEq(router.currentRequiredOutput(intentId), expected);
    }

    function test_currentRequiredOutput_atAuctionEnd_returnsMinOutput() public {
        bytes32 intentId = _createIntent();
        vm.warp(block.timestamp + AUCTION_SECONDS);
        // Price decay window closed but still inside FILL_BUFFER → price locked at minOutput
        assertEq(router.currentRequiredOutput(intentId), MIN_OUTPUT);
    }

    function test_currentRequiredOutput_afterFillBuffer_returnsZero() public {
        bytes32 intentId = _createIntent();
        vm.warp(block.timestamp + AUCTION_SECONDS + router.FILL_BUFFER());
        assertEq(router.currentRequiredOutput(intentId), 0);
    }

    function test_currentRequiredOutput_oneSecondBeforeExpiry() public {
        bytes32 intentId = _createIntent();
        vm.warp(block.timestamp + AUCTION_SECONDS - 1);

        uint256 spread = DESIRED_OUTPUT - MIN_OUTPUT;
        uint256 decay = (spread * (AUCTION_SECONDS - 1)) / AUCTION_SECONDS;
        uint256 expected = DESIRED_OUTPUT - decay;

        assertEq(router.currentRequiredOutput(intentId), expected);
    }

    function test_currentRequiredOutput_returnsZero_afterFilled() public {
        bytes32 intentId = _createIntent();
        _solverFill(intentId, DESIRED_OUTPUT);
        assertEq(router.currentRequiredOutput(intentId), 0);
    }

    // ─── fill ─────────────────────────────────────────────────────────────────

    function test_fill_atDesiredOutput() public {
        bytes32 intentId = _createIntent();

        uint256 solverWMemeBefore = wMeme.balanceOf(solver);
        uint256 solverUsdcBefore = usdc.balanceOf(solverRecipient);
        uint256 userWMemeBefore = wMeme.balanceOf(userRecipient);

        _solverFill(intentId, DESIRED_OUTPUT);

        assertEq(wMeme.balanceOf(userRecipient), userWMemeBefore + DESIRED_OUTPUT);
        assertEq(usdc.balanceOf(solverRecipient), solverUsdcBefore + INPUT_AMOUNT);
        assertEq(wMeme.balanceOf(solver), solverWMemeBefore - DESIRED_OUTPUT);

        assertEq(uint8(router.getIntent(intentId).status), uint8(HydrexMultichainAuctionRouter.IntentStatus.Filled));
        assertEq(router.reservedInput(address(usdc)), 0);
    }

    function test_fill_atMidAuction_lowerPrice() public {
        bytes32 intentId = _createIntent();
        vm.warp(block.timestamp + AUCTION_SECONDS / 2);

        uint256 midPrice = (DESIRED_OUTPUT + MIN_OUTPUT) / 2;

        vm.prank(solver);
        wMeme.transfer(address(router), midPrice);
        vm.prank(solver);
        router.fill(intentId, midPrice, solverRecipient);

        assertEq(wMeme.balanceOf(userRecipient), midPrice);
        assertEq(usdc.balanceOf(solverRecipient), INPUT_AMOUNT);
    }

    // Fix #1: surplus stays in contract, not forwarded to user
    function test_fill_surplus_staysInContract() public {
        bytes32 intentId = _createIntent();

        uint256 surplus = 50e18;
        uint256 delivered = DESIRED_OUTPUT + surplus;

        vm.prank(solver);
        wMeme.transfer(address(router), delivered);
        vm.prank(solver);
        router.fill(intentId, delivered, solverRecipient);

        // User gets exactly outputAmount, not delivered + surplus pool
        assertEq(wMeme.balanceOf(userRecipient), delivered);
        // No surplus left in this case since outputAmount == delivered
        assertEq(wMeme.balanceOf(address(router)), 0);
    }

    // Fix #1: concurrent fills for the same outputToken don't collide
    function test_fill_concurrentSameOutputToken_noCollision() public {
        // Setup two intents both wanting wMEME
        usdc.mint(user, INPUT_AMOUNT);

        bytes32 id1 = _createIntent();
        bytes32 id2 = _createIntent();

        // Both solvers deposit before either fill is called
        vm.prank(solver);
        wMeme.transfer(address(router), DESIRED_OUTPUT); // for intent 1
        vm.prank(solver);
        wMeme.transfer(address(router), DESIRED_OUTPUT); // for intent 2

        // Both fills should succeed independently
        vm.prank(solver);
        router.fill(id1, DESIRED_OUTPUT, solverRecipient);

        vm.prank(solver);
        router.fill(id2, DESIRED_OUTPUT, solverRecipient);

        // Each user recipient gets exactly DESIRED_OUTPUT, not 2x
        assertEq(wMeme.balanceOf(userRecipient), DESIRED_OUTPUT * 2); // both go to same recipient in test
        assertEq(wMeme.balanceOf(address(router)), 0);
    }

    // Fix #1: solver deposits more than required; exact amount goes to user, surplus rescuable
    function test_fill_surplusAboveFill_isRescuable() public {
        bytes32 intentId = _createIntent();

        uint256 required = DESIRED_OUTPUT;
        uint256 extra = 100e18;

        vm.prank(solver);
        wMeme.transfer(address(router), required + extra);
        vm.prank(solver);
        router.fill(intentId, required, solverRecipient);

        // User gets exactly `required`
        assertEq(wMeme.balanceOf(userRecipient), required);
        // Extra stays in contract
        assertEq(wMeme.balanceOf(address(router)), extra);
        // Owner can rescue the extra
        router.rescue(address(wMeme), address(this), extra);
        assertEq(wMeme.balanceOf(address(this)), extra);
    }

    // fillWithTransfer: Base-native solver pulls tokens atomically
    function test_fillWithTransfer_basic() public {
        bytes32 intentId = _createIntent();

        vm.prank(solver);
        wMeme.approve(address(router), DESIRED_OUTPUT);
        vm.prank(solver);
        router.fillWithTransfer(intentId, DESIRED_OUTPUT, solverRecipient);

        assertEq(wMeme.balanceOf(userRecipient), DESIRED_OUTPUT);
        assertEq(usdc.balanceOf(solverRecipient), INPUT_AMOUNT);
        assertEq(uint8(router.getIntent(intentId).status), uint8(HydrexMultichainAuctionRouter.IntentStatus.Filled));
    }

    function test_fillWithTransfer_reverts_insufficientApproval() public {
        bytes32 intentId = _createIntent();

        vm.prank(solver);
        wMeme.approve(address(router), DESIRED_OUTPUT - 1);
        vm.prank(solver);
        vm.expectRevert(); // ERC20 insufficient allowance
        router.fillWithTransfer(intentId, DESIRED_OUTPUT, solverRecipient);
    }

    // Fill at minOutput still works inside the FILL_BUFFER grace period
    function test_fill_succeedsInBuffer_atMinOutput() public {
        bytes32 intentId = _createIntent();
        vm.warp(block.timestamp + AUCTION_SECONDS + 1); // past auction, inside buffer

        vm.prank(solver);
        wMeme.transfer(address(router), MIN_OUTPUT);
        vm.prank(solver);
        router.fill(intentId, MIN_OUTPUT, solverRecipient);

        assertEq(wMeme.balanceOf(userRecipient), MIN_OUTPUT);
        assertEq(usdc.balanceOf(solverRecipient), INPUT_AMOUNT);
    }

    function test_fill_reverts_afterFillBuffer() public {
        bytes32 intentId = _createIntent();
        vm.warp(block.timestamp + AUCTION_SECONDS + router.FILL_BUFFER());

        vm.prank(solver);
        wMeme.transfer(address(router), MIN_OUTPUT);
        vm.prank(solver);
        vm.expectRevert(HydrexMultichainAuctionRouter.AuctionExpired.selector);
        router.fill(intentId, MIN_OUTPUT, solverRecipient);
    }

    function test_fill_reverts_insufficientOutput() public {
        bytes32 intentId = _createIntent();

        uint256 tooLow = DESIRED_OUTPUT - 1;

        vm.prank(solver);
        wMeme.transfer(address(router), tooLow);
        vm.prank(solver);
        vm.expectRevert(HydrexMultichainAuctionRouter.InsufficientOutput.selector);
        router.fill(intentId, tooLow, solverRecipient);
    }

    function test_fill_reverts_outputNotDeposited() public {
        bytes32 intentId = _createIntent();

        vm.prank(solver);
        vm.expectRevert(HydrexMultichainAuctionRouter.OutputTokensNotReceived.selector);
        router.fill(intentId, DESIRED_OUTPUT, solverRecipient);
    }

    function test_fill_reverts_doubleFill() public {
        bytes32 intentId = _createIntent();
        _solverFill(intentId, DESIRED_OUTPUT);

        vm.prank(solver);
        wMeme.transfer(address(router), DESIRED_OUTPUT);
        vm.prank(solver);
        vm.expectRevert(HydrexMultichainAuctionRouter.IntentNotActive.selector);
        router.fill(intentId, DESIRED_OUTPUT, solverRecipient);
    }

    function test_fill_reverts_zeroInputRecipient() public {
        bytes32 intentId = _createIntent();

        vm.prank(solver);
        wMeme.transfer(address(router), DESIRED_OUTPUT);
        vm.prank(solver);
        vm.expectRevert(HydrexMultichainAuctionRouter.InvalidAddress.selector);
        router.fill(intentId, DESIRED_OUTPUT, address(0));
    }

    // ─── cancel ───────────────────────────────────────────────────────────────

    function test_cancel_afterFillBuffer() public {
        bytes32 intentId = _createIntent();
        uint256 userUsdcBefore = usdc.balanceOf(user);

        vm.warp(block.timestamp + AUCTION_SECONDS + router.FILL_BUFFER() + 1);

        vm.prank(user);
        router.cancel(intentId);

        assertEq(usdc.balanceOf(user), userUsdcBefore + INPUT_AMOUNT);
        assertEq(uint8(router.getIntent(intentId).status), uint8(HydrexMultichainAuctionRouter.IntentStatus.Cancelled));
        assertEq(router.reservedInput(address(usdc)), 0);
    }

    // Cancel reverts during the FILL_BUFFER window to protect in-flight bridge txs
    function test_cancel_reverts_duringFillBuffer() public {
        bytes32 intentId = _createIntent();
        vm.warp(block.timestamp + AUCTION_SECONDS + 1); // past auction end, inside buffer

        vm.prank(user);
        vm.expectRevert(HydrexMultichainAuctionRouter.AuctionNotExpired.selector);
        router.cancel(intentId);
    }

    function test_cancel_reverts_beforeExpiry() public {
        bytes32 intentId = _createIntent();
        vm.warp(block.timestamp + AUCTION_SECONDS - 1);

        vm.prank(user);
        vm.expectRevert(HydrexMultichainAuctionRouter.AuctionNotExpired.selector);
        router.cancel(intentId);
    }

    // Anyone can cancel after the full window (auction + buffer) — keeper/relayer UX
    function test_cancel_byThirdParty_afterFillBuffer() public {
        bytes32 intentId = _createIntent();
        uint256 userUsdcBefore = usdc.balanceOf(user);
        vm.warp(block.timestamp + AUCTION_SECONDS + router.FILL_BUFFER() + 1);

        address keeper = address(0xBEEF);
        vm.prank(keeper);
        router.cancel(intentId);

        assertEq(usdc.balanceOf(user), userUsdcBefore + INPUT_AMOUNT);
        assertEq(usdc.balanceOf(keeper), 0);
        assertEq(uint8(router.getIntent(intentId).status), uint8(HydrexMultichainAuctionRouter.IntentStatus.Cancelled));
    }

    function test_cancel_reverts_alreadyCancelled() public {
        bytes32 intentId = _createIntent();
        vm.warp(block.timestamp + AUCTION_SECONDS + router.FILL_BUFFER() + 1);

        vm.prank(user);
        router.cancel(intentId);

        vm.prank(user);
        vm.expectRevert(HydrexMultichainAuctionRouter.IntentNotActive.selector);
        router.cancel(intentId);
    }

    // ─── rescue ───────────────────────────────────────────────────────────────

    function test_rescue_stuckOutputTokens() public {
        wMeme.mint(address(router), 100e18);

        uint256 before = wMeme.balanceOf(address(this));
        router.rescue(address(wMeme), address(this), 100e18);
        assertEq(wMeme.balanceOf(address(this)), before + 100e18);
    }

    function test_rescue_reverts_notOwner() public {
        wMeme.mint(address(router), 100e18);

        vm.prank(user);
        vm.expectRevert(HydrexMultichainAuctionRouter.Unauthorized.selector);
        router.rescue(address(wMeme), user, 100e18);
    }

    // Fix #4: rescue cannot touch user-reserved input tokens
    function test_rescue_reverts_cannotTakeReservedInput() public {
        _createIntent(); // locks INPUT_AMOUNT of usdc

        // There are INPUT_AMOUNT USDC in the contract, but all are reserved
        vm.expectRevert(HydrexMultichainAuctionRouter.RescueExceedsAvailable.selector);
        router.rescue(address(usdc), address(this), 1);
    }

    // Fix #4: rescue can only take the non-reserved portion
    function test_rescue_canTakeNonReservedTokens() public {
        _createIntent(); // reserves INPUT_AMOUNT usdc

        // Separately send some extra usdc directly (e.g. stuck wrong-token delivery)
        uint256 extra = 500e6;
        usdc.mint(address(router), extra);

        // Can rescue only the extra, not the reserved portion
        router.rescue(address(usdc), address(this), extra);
        assertEq(usdc.balanceOf(address(this)), extra);

        // Cannot rescue one more wei
        vm.expectRevert(HydrexMultichainAuctionRouter.RescueExceedsAvailable.selector);
        router.rescue(address(usdc), address(this), 1);
    }

    // ─── concurrent intents ────────────────────────────────────────────────────

    function test_concurrentIntents_reservedInputTrackedCorrectly() public {
        usdc.mint(user, INPUT_AMOUNT);

        bytes32 id1 = _createIntent();
        bytes32 id2 = _createIntent();

        assertEq(router.reservedInput(address(usdc)), INPUT_AMOUNT * 2);

        _solverFill(id1, DESIRED_OUTPUT);
        assertEq(router.reservedInput(address(usdc)), INPUT_AMOUNT);

        vm.prank(solver);
        wMeme.transfer(address(router), DESIRED_OUTPUT);
        vm.prank(solver);
        router.fill(id2, DESIRED_OUTPUT, solverRecipient);
        assertEq(router.reservedInput(address(usdc)), 0);
    }

    function test_concurrentIntents_freeBalanceExcludesReserved() public {
        // inputToken == outputToken edge case
        wMeme.mint(user, INPUT_AMOUNT);
        vm.prank(user);
        wMeme.approve(address(router), type(uint256).max);

        vm.prank(user);
        bytes32 intentId = router.createIntent(
            address(wMeme),
            INPUT_AMOUNT,
            address(wMeme),
            DESIRED_OUTPUT,
            MIN_OUTPUT,
            AUCTION_SECONDS,
            userRecipient
        );

        assertEq(router.freeBalance(address(wMeme)), 0);

        vm.prank(solver);
        wMeme.transfer(address(router), DESIRED_OUTPUT);

        assertEq(router.freeBalance(address(wMeme)), DESIRED_OUTPUT);

        vm.prank(solver);
        router.fill(intentId, DESIRED_OUTPUT, solverRecipient);
    }

    // ─── fuzz ─────────────────────────────────────────────────────────────────

    function testFuzz_auctionPriceCurve(
        uint256 desiredOutput,
        uint256 minOutput,
        uint64 auctionSeconds,
        uint256 elapsedSeconds
    ) public {
        desiredOutput = bound(desiredOutput, 1e18, 1e30);
        minOutput = bound(minOutput, 1, desiredOutput);
        auctionSeconds = uint64(bound(auctionSeconds, 1, router.MAX_AUCTION_SECONDS()));
        elapsedSeconds = bound(elapsedSeconds, 0, auctionSeconds - 1);

        usdc.mint(user, INPUT_AMOUNT);

        vm.prank(user);
        bytes32 intentId = router.createIntent(
            address(usdc), INPUT_AMOUNT, address(wMeme),
            desiredOutput, minOutput, auctionSeconds, userRecipient
        );

        vm.warp(block.timestamp + elapsedSeconds);
        uint256 price = router.currentRequiredOutput(intentId);

        assertGe(price, minOutput, "price below minOutput");
        assertLe(price, desiredOutput, "price above desiredOutput");
    }

    function testFuzz_fill_alwaysSucceeds_atCurrentPrice(uint256 elapsedSeconds) public {
        // Fill is valid across the full window: auction duration + fill buffer
        elapsedSeconds = bound(elapsedSeconds, 0, AUCTION_SECONDS + router.FILL_BUFFER() - 1);

        bytes32 intentId = _createIntent();
        vm.warp(block.timestamp + elapsedSeconds);

        uint256 required = router.currentRequiredOutput(intentId);

        vm.prank(solver);
        wMeme.transfer(address(router), required);
        vm.prank(solver);
        router.fill(intentId, required, solverRecipient);

        assertEq(uint8(router.getIntent(intentId).status), uint8(HydrexMultichainAuctionRouter.IntentStatus.Filled));
    }
}

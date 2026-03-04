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

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {HydrexMultiRouter} from "./HydrexMultiRouter.sol";

/**
 * @title TokenJar
 * @notice Accumulates miscellaneous tokens and batch-sweeps them into stablecoins
 *         via HydrexMultiRouter. All swap outputs land in this contract first, then
 *         the total received per token is forwarded to feeRecipient in one shot
 *         for clean accounting.
 */
contract TokenJar is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @notice HydrexMultiRouter used to execute swaps
    HydrexMultiRouter public router;
    /// @notice Destination for all tokens collected after a sweep
    address public feeRecipient;

    /**
     * @param inputToken      Token held in the jar to sell (ETH_ADDRESS for native ETH)
     * @param outputToken     Stablecoin to receive
     * @param inputAmount     Amount to sell; 0 = use full jar balance
     * @param minOutputAmount Minimum output after fees (slippage guard)
     * @param dexRouter       Whitelisted DEX router address
     * @param callData        Encoded DEX calldata obtained off-chain
     */
    struct SweepInstruction {
        address inputToken;
        address outputToken;
        uint256 inputAmount;
        uint256 minOutputAmount;
        address dexRouter;
        bytes callData;
    }

    event Swept(uint256 numSwaps, address indexed recipient);
    event Forwarded(address indexed token, uint256 amount, address indexed recipient);
    event RouterUpdated(address indexed oldRouter, address indexed newRouter);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event TokenRecovered(address indexed token, uint256 amount, address indexed to);

    error InvalidAddress();
    error InvalidAmount();
    error NoInstructions();
    error ETHTransferFailed();
    error InsufficientBalance(address token);

    constructor(address _owner, address _router, address _feeRecipient) Ownable(_owner) {
        if (_router == address(0) || _feeRecipient == address(0)) revert InvalidAddress();
        router = HydrexMultiRouter(payable(_router));
        feeRecipient = _feeRecipient;
    }

    /*//////////////////////////////////////////////////////////////
                                SWEEP
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sweep up to 30 tokens into stables.
     *         All swap outputs are collected here first, then the full amount
     *         received per output token is forwarded to feeRecipient in one
     *         transfer each — making reconciliation straightforward.
     * @param instructions Array of swap configs (recommended max: 30)
     * @param deadline     Unix timestamp after which the call reverts
     */
    function sweep(SweepInstruction[] calldata instructions, uint256 deadline) external nonReentrant onlyOwner {
        if (instructions.length == 0) revert NoInstructions();

        uint256 len = instructions.length;
        HydrexMultiRouter.SwapData[] memory swaps = new HydrexMultiRouter.SwapData[](len);
        uint256 totalETH;

        // --- Pass 1: resolve amounts, approve inputs, collect unique output tokens ---
        address[] memory outputTokens = new address[](len);
        uint256 uniqueCount;

        for (uint256 i = 0; i < len; i++) {
            SweepInstruction calldata inst = instructions[i];

            uint256 inputAmount = inst.inputAmount == 0
                ? (inst.inputToken == ETH_ADDRESS ? address(this).balance : IERC20(inst.inputToken).balanceOf(address(this)))
                : inst.inputAmount;

            if (inputAmount == 0) revert InsufficientBalance(inst.inputToken);

            if (inst.inputToken == ETH_ADDRESS) {
                totalETH += inputAmount;
            } else {
                IERC20(inst.inputToken).forceApprove(address(router), inputAmount);
            }

            // Track unique output tokens for snapshot + forward
            address out = inst.outputToken;
            bool found;
            for (uint256 j = 0; j < uniqueCount; j++) {
                if (outputTokens[j] == out) { found = true; break; }
            }
            if (!found) outputTokens[uniqueCount++] = out;

            swaps[i] = HydrexMultiRouter.SwapData({
                router: inst.dexRouter,
                inputAsset: inst.inputToken,
                outputAsset: inst.outputToken,
                inputAmount: inputAmount,
                minOutputAmount: inst.minOutputAmount,
                callData: inst.callData,
                recipient: address(this), // collect here first
                origin: "token-jar",
                referral: address(0),
                referralFeeBps: 0
            });
        }

        // --- Snapshot output balances before swaps ---
        // For ETH outputs: subtract totalETH so input ETH doesn't pollute the delta.
        uint256[] memory balancesBefore = new uint256[](uniqueCount);
        for (uint256 i = 0; i < uniqueCount; i++) {
            balancesBefore[i] = outputTokens[i] == ETH_ADDRESS
                ? address(this).balance - totalETH
                : IERC20(outputTokens[i]).balanceOf(address(this));
        }

        // --- Execute all swaps ---
        router.executeSwaps{value: totalETH}(swaps, deadline);

        // --- Clear residual ERC20 approvals ---
        for (uint256 i = 0; i < len; i++) {
            if (instructions[i].inputToken != ETH_ADDRESS) {
                IERC20(instructions[i].inputToken).forceApprove(address(router), 0);
            }
        }

        // --- Forward everything received to feeRecipient ---
        address _recipient = feeRecipient;
        for (uint256 i = 0; i < uniqueCount; i++) {
            address token = outputTokens[i];
            uint256 current = token == ETH_ADDRESS
                ? address(this).balance
                : IERC20(token).balanceOf(address(this));
            uint256 received = current - balancesBefore[i];
            if (received == 0) continue;

            if (token == ETH_ADDRESS) {
                (bool ok, ) = payable(_recipient).call{value: received}("");
                if (!ok) revert ETHTransferFailed();
            } else {
                IERC20(token).safeTransfer(_recipient, received);
            }
            emit Forwarded(token, received, _recipient);
        }

        emit Swept(len, _recipient);
    }

    /*//////////////////////////////////////////////////////////////
                                ADMIN
    //////////////////////////////////////////////////////////////*/

    function setRouter(address _router) external onlyOwner {
        if (_router == address(0)) revert InvalidAddress();
        address old = address(router);
        router = HydrexMultiRouter(payable(_router));
        emit RouterUpdated(old, _router);
    }

    function setFeeRecipient(address _recipient) external onlyOwner {
        if (_recipient == address(0)) revert InvalidAddress();
        address old = feeRecipient;
        feeRecipient = _recipient;
        emit FeeRecipientUpdated(old, _recipient);
    }

    function recoverToken(address token, uint256 amount, address to) external onlyOwner {
        if (to == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();
        if (token == ETH_ADDRESS) {
            (bool ok, ) = payable(to).call{value: amount}("");
            if (!ok) revert ETHTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
        emit TokenRecovered(token, amount, to);
    }

    receive() external payable {}
}

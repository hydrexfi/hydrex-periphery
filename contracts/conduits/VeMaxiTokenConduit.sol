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

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IVoter} from "../interfaces/IVoter.sol";
import {IHydrexVotingEscrow} from "../interfaces/IHydrexVotingEscrow.sol";
import {IOptionsToken} from "../interfaces/IOptionsToken.sol";

/**
 * @title VeMaxiTokenConduit
 * @notice Conduit that claims rewards, swaps to HYDX, and creates ROLLING veNFT locks
 */
contract VeMaxiTokenConduit is AccessControl {
    /// @notice Role identifier for authorized executors
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    /// @notice ve(3,3) voter contract
    address public immutable voter;

    /// @notice veNFT contract whose tokenId ownership dictates distribution recipient
    address public immutable veToken;

    /// @notice HYDX token address (the token we buy back and lock)
    address public immutable hydxToken;

    /// @notice oHYDX options token address
    address public immutable optionsToken;

    /*
     * Events
     */

    /// @notice Emitted upon completion of claimSwapAndLock operation (for indexer compatibility)
    event ClaimSwapAndDistributeCompleted(
        uint256 indexed tokenId,
        address indexed owner,
        address indexed recipient,
        address[] claimedTokens,
        uint256[] claimedAmounts,
        address[] distributedTokens,
        uint256[] distributedAmounts,
        uint256[] treasuryFees
    );

    /// @notice Emitted upon completion of claimExerciseAndLock operation
    event ClaimExerciseAndLockCompleted(
        uint256 indexed tokenId,
        address indexed owner,
        uint256 optionsClaimedAmount,
        uint256 mintedNftId,
        uint256 mergeToTokenId
    );

    /*
     * Constructor
     */

    /**
     * @notice Initialize the conduit
     * @param defaultAdmin Address granted `DEFAULT_ADMIN_ROLE`
     * @param _voter Voter contract for claims and voting
     * @param _veToken veNFT contract used to determine recipients and authorization
     * @param _hydxToken HYDX token address
     * @param _optionsToken oHYDX options token address
     */
    constructor(address defaultAdmin, address _voter, address _veToken, address _hydxToken, address _optionsToken) {
        require(_voter != address(0), "Invalid voter address");
        require(_veToken != address(0), "Invalid veToken address");
        require(_hydxToken != address(0), "Invalid HYDX token address");
        require(_optionsToken != address(0), "Invalid options token address");

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(EXECUTOR_ROLE, msg.sender);

        voter = _voter;
        veToken = _veToken;
        hydxToken = _hydxToken;
        optionsToken = _optionsToken;

        uint8[] memory actions = new uint8[](3);
        actions[0] = 1;
        actions[1] = 3;
        actions[2] = 5;
        IHydrexVotingEscrow(_veToken).setConduitApprovalConfig(actions, "");
    }

    /*
     * User Functions
     */

    /**
     * @notice Claim rewards (fees + bribes), swap to HYDX, and create a ROLLING veNFT lock
     * @param tokenId veNFT id to act on. Lock recipient is `IERC721(veToken).ownerOf(tokenId)`
     * @param targets Swap targets (routers)
     * @param swaps Encoded calldata per target
     * @param feeAddresses Fee contracts to claim from
     * @param bribeAddresses Bribe contracts to claim from
     * @param claimTokens Tokens to claim from fee/bribe contracts
     * @param mergeToTokenId Optional tokenId to merge the newly created lock into (0 to skip merge)
     */
    function claimSwapAndLock(
        uint256 tokenId,
        address[] calldata targets,
        bytes[] calldata swaps,
        address[] calldata feeAddresses,
        address[] calldata bribeAddresses,
        address[] calldata claimTokens,
        uint256 mergeToTokenId
    ) external onlyRole(EXECUTOR_ROLE) {
        address owner = IERC721(veToken).ownerOf(tokenId);
        require(owner != address(0), "Invalid token owner");

        _assertNoDuplicateAddresses(claimTokens);

        uint256[] memory balancesBefore = new uint256[](claimTokens.length);
        for (uint256 i = 0; i < claimTokens.length; i++) {
            balancesBefore[i] = IERC20(claimTokens[i]).balanceOf(address(this));
        }

        _claimBribesAndFees(tokenId, feeAddresses, bribeAddresses, claimTokens);

        uint256[] memory claimedAmounts = new uint256[](claimTokens.length);
        for (uint256 i = 0; i < claimTokens.length; i++) {
            claimedAmounts[i] = IERC20(claimTokens[i]).balanceOf(address(this)) - balancesBefore[i];
        }

        uint256 hydxBefore = IERC20(hydxToken).balanceOf(address(this));
        _runSwaps(targets, swaps, claimTokens);
        uint256 hydxAcquired = IERC20(hydxToken).balanceOf(address(this)) - hydxBefore;

        require(hydxAcquired > 0, "No HYDX acquired");

        uint256 newTokenId = _createRollingLock(hydxAcquired, address(this));

        if (newTokenId != 0) {
            IERC721(veToken).safeTransferFrom(address(this), owner, newTokenId);
        }

        if (newTokenId != 0 && mergeToTokenId != 0) {
            _mergeVeNFTs(owner, newTokenId, mergeToTokenId);
        }

        // Emit in same format as VeTokenConduit for indexer compatibility
        // Use veToken address and amount of 1 to indicate veNFT creation (different from token distribution)
        address[] memory distributedTokens = new address[](1);
        distributedTokens[0] = veToken;
        uint256[] memory distributedAmounts = new uint256[](1);
        distributedAmounts[0] = 1;
        uint256[] memory treasuryFees = new uint256[](1);
        treasuryFees[0] = 0;

        emit ClaimSwapAndDistributeCompleted(
            tokenId,
            owner,
            owner,
            claimTokens,
            claimedAmounts,
            distributedTokens,
            distributedAmounts,
            treasuryFees
        );
    }

    /**
     * @notice Cast votes on the Voter for all veNFTs
     * @param pools Pool addresses to vote for
     * @param weights Weights to apply to each pool (1:1 with `pools`)
     */
    function vote(address[] calldata pools, uint256[] calldata weights) external onlyRole(EXECUTOR_ROLE) {
        require(pools.length == weights.length, "Pools/weights length mismatch");
        IVoter(voter).vote(pools, weights);
    }

    /**
     * @notice Claim oHYDX from fees/bribes, exercise to veNFT, and optionally merge
     * @param tokenId veNFT id to act on. Lock recipient is `IERC721(veToken).ownerOf(tokenId)`
     * @param feeAddresses Fee contracts to claim from
     * @param bribeAddresses Bribe contracts to claim from
     * @param mergeToTokenId Optional tokenId to merge the newly created veNFT into (0 to skip merge)
     */
    function claimExerciseAndLock(
        uint256 tokenId,
        address[] calldata feeAddresses,
        address[] calldata bribeAddresses,
        uint256 mergeToTokenId
    ) external onlyRole(EXECUTOR_ROLE) {
        address owner = IERC721(veToken).ownerOf(tokenId);
        require(owner != address(0), "Invalid token owner");

        // Claim oHYDX from fees/bribes
        uint256 balanceBefore = IERC20(optionsToken).balanceOf(address(this));

        address[] memory claimTokens = new address[](1);
        claimTokens[0] = optionsToken;

        _claimBribesAndFees(tokenId, feeAddresses, bribeAddresses, claimTokens);

        uint256 optionsClaimedAmount = IERC20(optionsToken).balanceOf(address(this)) - balanceBefore;

        // Exercise oHYDX to create veNFT
        uint256 mintedNftId;
        if (optionsClaimedAmount > 0) {
            mintedNftId = IOptionsToken(optionsToken).exerciseVe(optionsClaimedAmount, address(this));

            if (mintedNftId != 0) {
                IERC721(veToken).safeTransferFrom(address(this), owner, mintedNftId);
            }
        }

        // Merge if requested
        if (mintedNftId != 0 && mergeToTokenId != 0) {
            _mergeVeNFTs(owner, mintedNftId, mergeToTokenId);
        }

        emit ClaimExerciseAndLockCompleted(tokenId, owner, optionsClaimedAmount, mintedNftId, mergeToTokenId);
    }

    /*
     * Internal Main Flow Functions
     */

    /// @dev Step 1: Claim bribes and fees for a tokenId to this contract
    function _claimBribesAndFees(
        uint256 tokenId,
        address[] memory feeAddresses,
        address[] memory bribeAddresses,
        address[] memory claimTokens
    ) internal {
        // Build nested arrays so each fee/bribe contract claims the same set of tokens
        if (feeAddresses.length > 0) {
            address[][] memory feeClaimTokens = _createNestedTokenArray(feeAddresses.length, claimTokens);
            IVoter(voter).claimFeesToRecipientByTokenId(feeAddresses, feeClaimTokens, tokenId, address(this));
        }
        if (bribeAddresses.length > 0) {
            address[][] memory bribeClaimTokens = _createNestedTokenArray(bribeAddresses.length, claimTokens);
            IVoter(voter).claimBribesToRecipientByTokenId(bribeAddresses, bribeClaimTokens, tokenId, address(this));
        }
    }

    /// @dev Step 2: Approve inputs, execute swaps, assert HYDX balance increased
    /// @param targets Swap routers to call
    /// @param swaps Encoded calldata per target (1:1 with `targets`)
    /// @param inputTokens Tokens to grant temporary max allowance to for the duration of swaps
    function _runSwaps(address[] calldata targets, bytes[] calldata swaps, address[] calldata inputTokens) internal {
        require(targets.length == swaps.length, "Targets and swaps arrays length mismatch");

        // Approve max for all input tokens across all targets
        for (uint256 i = 0; i < inputTokens.length; i++) {
            address token = inputTokens[i];
            for (uint256 t = 0; t < targets.length; t++) {
                IERC20(token).approve(targets[t], 0);
                IERC20(token).approve(targets[t], type(uint256).max);
            }
        }

        // Execute swaps
        for (uint256 i = 0; i < targets.length; i++) {
            uint256 hydxBalanceBefore = IERC20(hydxToken).balanceOf(address(this));

            // Execute the swap with revert bubbling
            (bool success, bytes memory returndata) = targets[i].call(swaps[i]);
            if (!success) {
                if (returndata.length >= 68) {
                    assembly {
                        returndata := add(returndata, 0x04)
                    }
                    revert(abi.decode(returndata, (string)));
                }
                revert("Swap failed");
            }

            // Check that HYDX balance increased
            uint256 hydxBalanceAfter = IERC20(hydxToken).balanceOf(address(this));
            require(hydxBalanceAfter > hydxBalanceBefore, "No HYDX balance increase detected for swap");
        }

        // Clear approvals for safety
        for (uint256 i = 0; i < inputTokens.length; i++) {
            address token = inputTokens[i];
            for (uint256 t = 0; t < targets.length; t++) {
                IERC20(token).approve(targets[t], 0);
            }
        }
    }

    /// @dev Step 3: Create a ROLLING lock with the acquired HYDX
    /// @param amount Amount of HYDX to lock
    /// @param recipient Address to receive the veNFT (minted directly to this address)
    /// @return newTokenId The newly created veNFT token ID
    function _createRollingLock(uint256 amount, address recipient) internal returns (uint256 newTokenId) {
        IERC20(hydxToken).approve(veToken, amount);
        newTokenId = IHydrexVotingEscrow(veToken).createClaimableLockFor(amount, 0, recipient, recipient, 1);
    }

    /// @dev Merge two veNFTs owned by the same user
    /// @param user Owner of both veNFTs
    /// @param _from TokenId to merge from (burned)
    /// @param _to TokenId to merge into (receiver)
    function _mergeVeNFTs(address user, uint256 _from, uint256 _to) internal {
        require(user != address(0), "Invalid user address");
        require(_from != 0 && _to != 0 && _from != _to, "Invalid token IDs");

        address ownerFrom = IERC721(veToken).ownerOf(_from);
        address ownerTo = IERC721(veToken).ownerOf(_to);
        require(ownerFrom == user && ownerTo == user, "Not token owner");

        IHydrexVotingEscrow(veToken).merge(_from, _to);
    }

    /*
     * Internal Utility Functions
     */

    /// @notice Create `arrayCount` copies of the same `tokens` array
    /// @param arrayCount Number of arrays to create
    /// @param tokens Tokens to duplicate in each nested array
    /// @return result Nested array sized `arrayCount`, each referencing `tokens`
    function _createNestedTokenArray(
        uint256 arrayCount,
        address[] memory tokens
    ) internal pure returns (address[][] memory) {
        address[][] memory result = new address[][](arrayCount);
        for (uint256 i = 0; i < arrayCount; i++) {
            result[i] = tokens;
        }
        return result;
    }

    /// @notice Assert the provided addresses array contains no duplicates
    /// @dev O(n^2) check; acceptable for expected small arrays
    function _assertNoDuplicateAddresses(address[] memory addresses) internal pure {
        for (uint256 i = 0; i < addresses.length; i++) {
            for (uint256 j = i + 1; j < addresses.length; j++) {
                require(addresses[i] != addresses[j], "Duplicate claim token");
            }
        }
    }

    /*
     * Admin functions
     */

    /// @notice Admin wrapper to configure this conduit on the veToken contract
    /// @param actions Array of approval actions to enable for this conduit
    /// @param description Human-readable description
    function adminSetConduitApprovalConfig(
        uint8[] calldata actions,
        string calldata description
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        IHydrexVotingEscrow(veToken).setConduitApprovalConfig(actions, description);
    }

    /// @notice External wrapper to merge two veNFTs for a user
    /// @param user Owner of both veNFTs
    /// @param _from TokenId to merge from (burned)
    /// @param _to TokenId to merge into (receiver)
    function mergeFor(address user, uint256 _from, uint256 _to) external onlyRole(EXECUTOR_ROLE) {
        _mergeVeNFTs(user, _from, _to);
    }

    /**
     * @notice Emergency withdrawal of ERC20 tokens held by this contract
     * @param token ERC20 token to withdraw
     * @param amount Amount to withdraw
     * @param to Recipient address
     */
    function emergencyWithdrawERC20(address token, uint256 amount, address to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(token != address(0) && to != address(0), "Invalid address");
        require(amount > 0, "Invalid amount");
        IERC20(token).transfer(to, amount);
    }

    /**
     * @notice Emergency withdrawal of ETH held by this contract
     * @param amount Amount of ETH to withdraw
     * @param to Recipient address
     */
    function emergencyWithdrawETH(uint256 amount, address payable to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(to != address(0), "Invalid address");
        require(amount > 0, "Invalid amount");
        require(address(this).balance >= amount, "Insufficient balance");
        to.transfer(amount);
    }

    /**
     * @notice Allow the contract to receive ETH
     */
    receive() external payable {}
}

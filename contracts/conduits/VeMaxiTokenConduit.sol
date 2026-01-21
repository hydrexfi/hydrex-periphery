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

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IVoter} from "../interfaces/IVoter.sol";
import {IHydrexVotingEscrow} from "../interfaces/IHydrexVotingEscrow.sol";
import {IOptionsToken} from "../interfaces/IOptionsToken.sol";

/**
 * @title VeMaxiTokenConduit
 * @notice Conduit that claims rewards, swaps to HYDX, and creates ROLLING veNFT locks
 */
contract VeMaxiTokenConduit is AccessControlUpgradeable {
    /// @notice Role identifier for authorized executors
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    /// @notice ve(3,3) voter contract
    address public voter;

    /// @notice veNFT contract whose tokenId ownership dictates distribution recipient
    address public veToken;

    /// @notice HYDX token address (the token we buy back and lock)
    address public hydxToken;

    /// @notice oHYDX options token address
    address public optionsToken;

    /*
     * State Variables
     */

    /// @notice Total HYDX locked per user address (from swaps)
    mapping(address => uint256) public totalFlexLocked;

    /// @notice Total HYDX locked per user address (from options exercise)
    mapping(address => uint256) public totalProtocolLocked;

    /*
     * Events
     */

    /// @notice Emitted upon completion of claim operations (for indexer compatibility)
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

    /*
     * Constructor & Initializer
     */

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the conduit
     * @param defaultAdmin Address granted `DEFAULT_ADMIN_ROLE`
     * @param _voter Voter contract for claims and voting
     * @param _veToken veNFT contract used to determine recipients and authorization
     * @param _hydxToken HYDX token address
     * @param _optionsToken oHYDX options token address
     */
    function initialize(
        address defaultAdmin,
        address _voter,
        address _veToken,
        address _hydxToken,
        address _optionsToken
    ) external initializer {
        require(_voter != address(0), "Invalid voter address");
        require(_veToken != address(0), "Invalid veToken address");
        require(_hydxToken != address(0), "Invalid HYDX token address");
        require(_optionsToken != address(0), "Invalid options token address");

        __AccessControl_init();

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
     * @notice Cast votes on the Voter for all veNFTs
     * @param pools Pool addresses to vote for
     * @param weights Weights to apply to each pool (1:1 with `pools`)
     */
    function vote(address[] calldata pools, uint256[] calldata weights) external onlyRole(EXECUTOR_ROLE) {
        require(pools.length == weights.length, "Pools/weights length mismatch");
        IVoter(voter).vote(pools, weights);
    }

    /**
     * @notice Combined function: claim oHYDX + exercise AND claim tokens + swap, with separate merge targets
     * @param tokenId veNFT id to act on. Lock recipient is `IERC721(veToken).ownerOf(tokenId)`
     * @param targets Swap targets (routers)
     * @param swaps Encoded calldata per target
     * @param feeAddresses Fee contracts to claim from
     * @param bribeAddresses Bribe contracts to claim from
     * @param swapClaimTokens Tokens to claim and swap to HYDX (must NOT include optionsToken)
     * @param protocolLockMergeIntoId Optional tokenId to merge the exercised options veNFT into (0 to skip)
     * @param flexLockMergeIntoId Optional tokenId to merge the swapped HYDX veNFT into (0 to skip)
     */
    function claimExerciseSwapAndLock(
        uint256 tokenId,
        address[] calldata targets,
        bytes[] calldata swaps,
        address[] calldata feeAddresses,
        address[] calldata bribeAddresses,
        address[] calldata swapClaimTokens,
        uint256 protocolLockMergeIntoId,
        uint256 flexLockMergeIntoId
    ) external onlyRole(EXECUTOR_ROLE) {
        address owner = IERC721(veToken).ownerOf(tokenId);
        require(owner != address(0), "Invalid token owner");

        // Execute protocol lock (options exercise)
        (uint256 exercisedNftId, uint256 optionsClaimedAmount) = _executeProtocolLock(
            tokenId,
            feeAddresses,
            bribeAddresses,
            owner,
            protocolLockMergeIntoId
        );

        // Execute flex lock (swap and lock)
        (uint256 swapCreatedNftId, uint256[] memory swapClaimedAmounts) = _executeFlexLock(
            tokenId,
            targets,
            swaps,
            feeAddresses,
            bribeAddresses,
            swapClaimTokens,
            owner,
            flexLockMergeIntoId
        );

        // Emit event
        _emitCombinedEvent(
            tokenId,
            owner,
            exercisedNftId,
            swapCreatedNftId,
            optionsClaimedAmount,
            swapClaimTokens,
            swapClaimedAmounts
        );
    }

    /*
     * Internal Main Flow Functions
     */

    /// @dev Execute protocol lock: claim and exercise oHYDX
    function _executeProtocolLock(
        uint256 tokenId,
        address[] calldata feeAddresses,
        address[] calldata bribeAddresses,
        address owner,
        uint256 protocolLockMergeIntoId
    ) internal returns (uint256 exercisedNftId, uint256 optionsClaimedAmount) {
        uint256 optionsBalanceBefore = IERC20(optionsToken).balanceOf(address(this));

        address[] memory optionsClaimTokens = new address[](1);
        optionsClaimTokens[0] = optionsToken;

        _claimBribesAndFees(tokenId, feeAddresses, bribeAddresses, optionsClaimTokens);

        optionsClaimedAmount = IERC20(optionsToken).balanceOf(address(this)) - optionsBalanceBefore;

        if (optionsClaimedAmount > 0) {
            exercisedNftId = IOptionsToken(optionsToken).exerciseVe(optionsClaimedAmount, address(this));

            if (exercisedNftId != 0) {
                IERC721(veToken).safeTransferFrom(address(this), owner, exercisedNftId);

                if (protocolLockMergeIntoId != 0) {
                    _mergeVeNFTs(owner, exercisedNftId, protocolLockMergeIntoId);
                }
            }

            // Track the amount of oHYDX exercised (not HYDX, as exerciseVe creates locked veNFT directly)
            totalProtocolLocked[owner] += optionsClaimedAmount;
        }
    }

    /// @dev Execute flex lock: claim tokens, swap to HYDX, and create rolling lock
    function _executeFlexLock(
        uint256 tokenId,
        address[] calldata targets,
        bytes[] calldata swaps,
        address[] calldata feeAddresses,
        address[] calldata bribeAddresses,
        address[] calldata swapClaimTokens,
        address owner,
        uint256 flexLockMergeIntoId
    ) internal returns (uint256 swapCreatedNftId, uint256[] memory swapClaimedAmounts) {
        if (swapClaimTokens.length == 0) {
            return (0, new uint256[](0));
        }

        // Validate swap claim tokens
        _assertNoDuplicateAddresses(swapClaimTokens);
        for (uint256 i = 0; i < swapClaimTokens.length; i++) {
            require(swapClaimTokens[i] != optionsToken, "Cannot swap options token");
        }

        uint256[] memory swapBalancesBefore = new uint256[](swapClaimTokens.length);
        for (uint256 i = 0; i < swapClaimTokens.length; i++) {
            swapBalancesBefore[i] = IERC20(swapClaimTokens[i]).balanceOf(address(this));
        }

        _claimBribesAndFees(tokenId, feeAddresses, bribeAddresses, swapClaimTokens);

        swapClaimedAmounts = new uint256[](swapClaimTokens.length);
        for (uint256 i = 0; i < swapClaimTokens.length; i++) {
            swapClaimedAmounts[i] = IERC20(swapClaimTokens[i]).balanceOf(address(this)) - swapBalancesBefore[i];
        }

        uint256 hydxBefore = IERC20(hydxToken).balanceOf(address(this));
        _runSwaps(targets, swaps, swapClaimTokens);
        uint256 hydxAcquired = IERC20(hydxToken).balanceOf(address(this)) - hydxBefore;

        if (hydxAcquired > 0) {
            swapCreatedNftId = _createRollingLock(hydxAcquired, address(this));

            if (swapCreatedNftId != 0) {
                IERC721(veToken).safeTransferFrom(address(this), owner, swapCreatedNftId);

                if (flexLockMergeIntoId != 0) {
                    _mergeVeNFTs(owner, swapCreatedNftId, flexLockMergeIntoId);
                }
            }

            totalFlexLocked[owner] += hydxAcquired;
        }
    }

    /// @dev Emit combined event with all claimed tokens and amounts
    function _emitCombinedEvent(
        uint256 tokenId,
        address owner,
        uint256 exercisedNftId,
        uint256 swapCreatedNftId,
        uint256 optionsClaimedAmount,
        address[] calldata swapClaimTokens,
        uint256[] memory swapClaimedAmounts
    ) internal {
        address[] memory allClaimedTokens = new address[](swapClaimTokens.length + 1);
        uint256[] memory allClaimedAmounts = new uint256[](swapClaimTokens.length + 1);

        allClaimedTokens[0] = optionsToken;
        allClaimedAmounts[0] = optionsClaimedAmount;

        for (uint256 i = 0; i < swapClaimTokens.length; i++) {
            allClaimedTokens[i + 1] = swapClaimTokens[i];
            allClaimedAmounts[i + 1] = swapClaimedAmounts[i];
        }

        address[] memory distributedTokens = new address[](1);
        distributedTokens[0] = veToken;
        uint256[] memory distributedAmounts = new uint256[](1);
        uint256 nftCount = 0;
        if (exercisedNftId != 0) nftCount++;
        if (swapCreatedNftId != 0) nftCount++;
        distributedAmounts[0] = nftCount;

        uint256[] memory treasuryFees = new uint256[](1);
        treasuryFees[0] = 0;

        emit ClaimSwapAndDistributeCompleted(
            tokenId,
            owner,
            owner,
            allClaimedTokens,
            allClaimedAmounts,
            distributedTokens,
            distributedAmounts,
            treasuryFees
        );
    }

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

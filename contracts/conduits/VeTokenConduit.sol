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

/**
 * @title VeTokenConduit
 */
contract VeTokenConduit is AccessControl {
    /// @notice Role identifier for authorized executors
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    /// @notice Maximum treasury fee in basis points (100 = 1.00%)
    uint256 public constant MAX_TREASURY_FEE_BPS = 100;

    /// @notice Current treasury fee in basis points
    uint256 public treasuryFeeBps = 100;

    /// @notice Tokens that are considered valid distribution outputs
    address[] public approvedOutputTokens;

    /// @notice Routers that can be used for swaps in `_runSwaps`
    address[] public approvedRouters;

    /// @notice Address receiving the treasury fee on distribution
    address public treasury;

    /// @notice ve(3,3) voter contract
    address public immutable voter;

    /// @notice veNFT contract whose tokenId ownership dictates distribution recipient
    address public immutable veToken;

    /// @notice Optional per-user override for the final distribution recipient. If unset, the veNFT owner receives distributions.
    mapping(address => address) public userToPayoutRecipient;

    /*
     * Events
     */

    /// @notice Emitted upon completion of claimSwapAndDistribute operation
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

    /// @notice Emitted when a user's payout recipient override is updated
    event PayoutRecipientUpdated(address indexed user, address indexed newRecipient, address indexed updatedBy);

    /*
     * Constructor
     */

    /**
     * @notice Initialize the conduit
     * @param defaultAdmin Address granted `DEFAULT_ADMIN_ROLE`
     * @param _treasury Treasury address to receive protocol fee on distributions
     * @param _voter Voter contract for claims and voting
     * @param _veToken veNFT contract used to determine recipients and authorization
     * @param _approvedOutputTokens Array of tokens that are valid distribution outputs
     * @param _approvedRouters Array of routers that can be used for swaps
     */
    constructor(
        address defaultAdmin,
        address _treasury,
        address _voter,
        address _veToken,
        address[] memory _approvedOutputTokens,
        address[] memory _approvedRouters
    ) {
        require(_treasury != address(0), "Invalid treasury address");
        require(_voter != address(0), "Invalid voter address");
        require(_veToken != address(0), "Invalid veToken address");
        require(_approvedOutputTokens.length > 0, "Must have at least one approved output token");
        require(_approvedRouters.length > 0, "Must have at least one approved router");

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(EXECUTOR_ROLE, msg.sender);

        treasury = _treasury;
        voter = _voter;
        veToken = _veToken;

        for (uint256 i = 0; i < _approvedOutputTokens.length; i++) {
            require(_approvedOutputTokens[i] != address(0), "Invalid output token address");
            approvedOutputTokens.push(_approvedOutputTokens[i]);
        }

        for (uint256 i = 0; i < _approvedRouters.length; i++) {
            require(_approvedRouters[i] != address(0), "Invalid router address");
            approvedRouters.push(_approvedRouters[i]);
        }

        uint8[] memory actions = new uint8[](2);
        actions[0] = 3;
        actions[1] = 5;
        IHydrexVotingEscrow(_veToken).setConduitApprovalConfig(actions, "");
    }

    /*
     * View Functions
     */

    /// @notice Whether a token is in the approved output token list
    /// @param token Token to check
    /// @return True if the token is approved for distribution
    function isApprovedOutputToken(address token) public view returns (bool) {
        for (uint256 i = 0; i < approvedOutputTokens.length; i++) {
            if (approvedOutputTokens[i] == token) return true;
        }
        return false;
    }

    /// @notice Whether a router is approved for performing swaps
    /// @param router Router address to check
    /// @return True if the router is approved
    function isApprovedRouter(address router) public view returns (bool) {
        for (uint256 i = 0; i < approvedRouters.length; i++) {
            if (approvedRouters[i] == router) return true;
        }
        return false;
    }

    /// @notice View the effective recipient for a given owner (resolves to override or owner)
    /// @param owner The veNFT owner address
    /// @return effectiveRecipient The address that will receive distributions
    function getEffectiveRecipientForOwner(address owner) public view returns (address effectiveRecipient) {
        address configuredRecipient = userToPayoutRecipient[owner];
        return configuredRecipient == address(0) ? owner : configuredRecipient;
    }

    /*
     * User Functions
     */

    /// @notice Set or clear the caller's payout recipient override. Set to address(0) to clear and default to owning address.
    /// @param newRecipient The address to receive distributions on behalf of the caller, or address(0) to clear
    function setMyPayoutRecipient(address newRecipient) external {
        userToPayoutRecipient[msg.sender] = newRecipient;
        emit PayoutRecipientUpdated(msg.sender, newRecipient, msg.sender);
    }

    /**
     * @notice Claim rewards (fees + bribes), optionally swap claimed tokens into approved
     *         output tokens, and distribute to the veNFT owner with a treasury fee.
     * @param tokenId veNFT id to act on. Recipient is `IERC721(veToken).ownerOf(tokenId)`
     * @param targets Swap targets (routers). Must be approved in `approvedRouters`
     * @param swaps Encoded calldata per target
     * @param feeAddresses Fee contracts to claim from
     * @param bribeAddresses Bribe contracts to claim from
     * @param claimTokens Tokens to claim from fee/bribe contracts
     */
    function claimSwapAndDistribute(
        uint256 tokenId,
        address[] calldata targets,
        bytes[] calldata swaps,
        address[] calldata feeAddresses,
        address[] calldata bribeAddresses,
        address[] calldata claimTokens
    ) external onlyRole(EXECUTOR_ROLE) {
        address owner = IERC721(veToken).ownerOf(tokenId);
        require(owner != address(0), "Invalid token owner");

        address recipient = getEffectiveRecipientForOwner(owner);

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

        _runSwaps(targets, swaps, claimTokens);

        (uint256[] memory distributedAmounts, uint256[] memory treasuryFees) = _distributeAndTrack(recipient);

        // Emit comprehensive event
        emit ClaimSwapAndDistributeCompleted(
            tokenId,
            owner,
            recipient,
            claimTokens,
            claimedAmounts,
            approvedOutputTokens,
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

    /// @dev Step 2: Approve inputs, execute swaps, assert at least one approved output increased
    /// @param targets Swap routers to call (must be approved)
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
            require(isApprovedRouter(targets[i]), "Router not approved");

            // Store balances before swap
            uint256[] memory balancesBefore = new uint256[](approvedOutputTokens.length);
            for (uint256 j = 0; j < approvedOutputTokens.length; j++) {
                balancesBefore[j] = IERC20(approvedOutputTokens[j]).balanceOf(address(this));
            }

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

            // Check that at least one output token balance actually increased
            bool balanceIncreased = false;
            for (uint256 j = 0; j < approvedOutputTokens.length; j++) {
                uint256 balanceAfter = IERC20(approvedOutputTokens[j]).balanceOf(address(this));
                if (balanceAfter > balancesBefore[j]) {
                    balanceIncreased = true;
                    break;
                }
            }
            require(balanceIncreased, "No output token balance increase detected for swap");
        }

        // Clear approvals for safety
        for (uint256 i = 0; i < inputTokens.length; i++) {
            address token = inputTokens[i];
            for (uint256 t = 0; t < targets.length; t++) {
                IERC20(token).approve(targets[t], 0);
            }
        }
    }

    /// @dev Step 3: Distribute all approved output token balances to the recipient, less treasury fee, with tracking
    /// @return distributedAmounts Array of amounts distributed to recipient for each approved output token
    /// @return treasuryFees Array of treasury fees collected for each approved output token
    function _distributeAndTrack(
        address recipient
    ) internal returns (uint256[] memory distributedAmounts, uint256[] memory treasuryFees) {
        distributedAmounts = new uint256[](approvedOutputTokens.length);
        treasuryFees = new uint256[](approvedOutputTokens.length);

        for (uint256 i = 0; i < approvedOutputTokens.length; i++) {
            uint256 balance = IERC20(approvedOutputTokens[i]).balanceOf(address(this));
            if (balance > 0) {
                uint256 treasuryFee = (balance * treasuryFeeBps) / 10000;
                uint256 recipientAmount = balance - treasuryFee;

                treasuryFees[i] = treasuryFee;
                distributedAmounts[i] = recipientAmount;

                if (treasuryFee > 0) {
                    IERC20(approvedOutputTokens[i]).transfer(treasury, treasuryFee);
                }

                if (recipientAmount > 0) {
                    IERC20(approvedOutputTokens[i]).transfer(recipient, recipientAmount);
                }
            }
        }
    }

    /*
     * Internal Utility Functions
     */

    /// @notice Create `arrayCount` copies of the same `tokens` array
    /// @param arrayCount Number of arrays to create
    /// @param tokens Tokens to duplicate in each nested array
    /// @return result Nested array sized `arrayCount`, each referencing `tokens`
    /// @notice Create a nested `address[][]` from a single list of tokens
    /// @param arrayCount Number of inner arrays to create
    /// @param tokens Tokens to duplicate in each inner array
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

    /// @notice Set the treasury address that receives protocol fees
    /// @param _treasury New treasury address
    function setTreasury(address _treasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_treasury != address(0), "Invalid treasury address");
        treasury = _treasury;
    }

    /// @notice Set the treasury fee in basis points
    /// @param _treasuryFeeBps New treasury fee in BPS (max 100)
    function setTreasuryFeeBps(uint256 _treasuryFeeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_treasuryFeeBps <= MAX_TREASURY_FEE_BPS, "Fee exceeds max");
        treasuryFeeBps = _treasuryFeeBps;
    }

    /// @notice Add a router to the approved routers list
    /// @param router Router address to add
    function addApprovedRouter(address router) external onlyRole(DEFAULT_ADMIN_ROLE) {
        approvedRouters.push(router);
    }

    /// @notice Remove a router from the approved routers list
    /// @param router Router address to remove
    function removeApprovedRouter(address router) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i = 0; i < approvedRouters.length; i++) {
            if (approvedRouters[i] == router) {
                approvedRouters[i] = approvedRouters[approvedRouters.length - 1];
                approvedRouters.pop();
                break;
            }
        }
    }

    /// @notice Add multiple tokens to the approved output tokens list
    /// @param tokens Token addresses to add
    function addApprovedOutputTokens(address[] calldata tokens) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i = 0; i < tokens.length; i++) {
            approvedOutputTokens.push(tokens[i]);
        }
    }

    /// @notice Remove multiple tokens from the approved output tokens list
    /// @param tokens Token addresses to remove
    function removeApprovedOutputTokens(address[] calldata tokens) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 t = 0; t < tokens.length; t++) {
            address token = tokens[t];
            for (uint256 i = 0; i < approvedOutputTokens.length; i++) {
                if (approvedOutputTokens[i] == token) {
                    approvedOutputTokens[i] = approvedOutputTokens[approvedOutputTokens.length - 1];
                    approvedOutputTokens.pop();
                    break;
                }
            }
        }
    }

    /*
     * Payout recipient configuration
     */

    /// @notice Admin-set a user's payout recipient override
    /// @param user The user whose override to update
    /// @param newRecipient The address to receive distributions for this user, or address(0) to clear
    function adminSetPayoutRecipient(address user, address newRecipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        userToPayoutRecipient[user] = newRecipient;
        emit PayoutRecipientUpdated(user, newRecipient, msg.sender);
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

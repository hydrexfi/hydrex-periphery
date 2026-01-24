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

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IVoter} from "../interfaces/IVoter.sol";
import {IHydrexVotingEscrow} from "../interfaces/IHydrexVotingEscrow.sol";
import {VeConduitFactory} from "../conduits/VeConduitFactory.sol";

/**
 * @title PartnerEscrow
 * @notice Escrow contract that holds veNFTs for partners with vesting periods
 * @dev Partners can vote, claim rewards, and delegate while veNFT is escrowed
 * @dev Assume this is only used for permalocked token types
 */
contract PartnerEscrow is AccessControl, IERC721Receiver {
    bytes32 public constant PARTNER_ROLE = keccak256("PARTNER_ROLE");
    bytes32 public constant FACTORY_ROLE = keccak256("FACTORY_ROLE");

    /// @notice Address of the escrowed veNFT contract
    address public veToken;
    /// @notice Address of the voter contract for claiming rewards
    address public voter;
    /// @notice Token ID of the escrowed veNFT
    uint256 public tokenId;
    /// @notice Vesting period in seconds before partner can claim veNFT
    uint256 public vestingPeriod;
    /// @notice Timestamp when veNFT was deposited
    uint256 public depositTime;
    /// @notice Mapping of conduit addresses that are approved for use
    mapping(address => bool) public approvedConduits;
    /// @notice Address of the VeConduitFactory whose conduits are auto-whitelisted
    address public veConduitFactory;

    event VeTokenDeposited(address indexed veToken, uint256 indexed tokenId, uint256 depositTime);
    event VeTokenWithdrawn(address indexed veToken, uint256 indexed tokenId, address indexed to);
    event RewardsClaimedAndForwarded(address indexed partner, address[] tokens, uint256[] amounts);
    event ConduitApprovalUpdated(address indexed conduit, bool approved);
    event ConduitApprovalSet(address indexed conduit, uint256 indexed tokenId, bool approved);
event ERC20Withdrawn(
    address indexed token,
    uint256 amount,
    address indexed to,
    address indexed caller
);

event ERC721EmergencyWithdrawn(
    address indexed token,
    uint256 indexed tokenId,
    address indexed to,
    address caller
);

event ETHEmergencyWithdrawn(
    uint256 amount,
    address indexed to,
    address indexed caller
);

    /**
     * @notice Constructor sets up roles and configuration
     * @param _admin Admin address with emergency powers
     * @param _partner Partner address with voting/claiming rights
     * @param _voter Voter contract address for reward claims
     * @param _veToken Address of the veNFT contract (immutable per escrow lifetime)
     * @param _veConduitFactory Address of the VeConduitFactory whose conduits are allowed
     */
    constructor(address _admin, address _partner, address _voter, address _veToken, address _veConduitFactory) {
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(PARTNER_ROLE, _partner);
        _grantRole(FACTORY_ROLE, msg.sender);

        voter = _voter;
        veToken = _veToken;
        veConduitFactory = _veConduitFactory;
    }

    /*
        Modifiers & View Functions
    */

    /**
     * @dev Ensures the escrow currently holds the designated veNFT
     */
    modifier hasVeToken() {
        require(veToken != address(0) && IERC721(veToken).ownerOf(tokenId) == address(this), "No veNFT held");
        _;
    }

    /**
     * @notice Returns true if a conduit is allowed either by admin approval or by factory whitelist
     */
    function isConduitAllowed(address conduit) public view returns (bool) {
        if (approvedConduits[conduit]) return true;
        return _isConduitWhitelistedByFactory(conduit);
    }

    function _isConduitWhitelistedByFactory(address conduit) internal view returns (bool) {
        if (veConduitFactory == address(0)) return false;
        return VeConduitFactory(veConduitFactory).isFactoryConduit(conduit);
    }

    /*  
        Partner Functions
    */

    /**
     * @notice Partner can vote with the escrowed veNFT
     * @param _poolVote Array of pool addresses to vote for
     * @param _voteProportions Array of vote proportions
     */
    function vote(
        address[] calldata _poolVote,
        uint256[] calldata _voteProportions
    ) external onlyRole(PARTNER_ROLE) hasVeToken {
        IVoter(voter).vote(_poolVote, _voteProportions);
    }

    /**
     * @notice Partner can delegate voting power to another address
     * @param delegatee Address to delegate voting power to
     */
    function delegate(address delegatee) external onlyRole(PARTNER_ROLE) hasVeToken {
        IHydrexVotingEscrow(veToken).delegate(tokenId, delegatee);
    }

    /**
     * @notice Partner can approve or revoke a conduit for the escrowed veNFT
     * @param conduitAddress Address of the conduit to approve/revoke
     * @param approve True to approve, false to revoke
     */
    function setConduitApprovalForEscrowedToken(
        address conduitAddress,
        bool approve
    ) external onlyRole(PARTNER_ROLE) hasVeToken {
        require(isConduitAllowed(conduitAddress), "Conduit not allowed");
        IHydrexVotingEscrow(veToken).setConduitApproval(conduitAddress, tokenId, approve);
        emit ConduitApprovalSet(conduitAddress, tokenId, approve);
    }

    /**
     * @notice Partner claims rewards from fees and bribes
     * @param feeAddresses Array of fee distributor addresses
     * @param bribeAddresses Array of bribe contract addresses
     * @param claimTokens Array of token addresses to claim
     */
    function claimRewards(
        address[] calldata feeAddresses,
        address[] calldata bribeAddresses,
        address[] calldata claimTokens
    ) external onlyRole(PARTNER_ROLE) hasVeToken {
        // Record balances before claiming
        uint256[] memory balancesBefore = new uint256[](claimTokens.length);
        for (uint256 i = 0; i < claimTokens.length; i++) {
            balancesBefore[i] = IERC20(claimTokens[i]).balanceOf(address(this));
        }

        // Claim fees and bribes
        if (feeAddresses.length > 0) {
            address[][] memory feeClaimTokens = _createNestedTokenArray(feeAddresses.length, claimTokens);
            IVoter(voter).claimFeesToRecipientByTokenId(feeAddresses, feeClaimTokens, tokenId, address(this));
        }
        if (bribeAddresses.length > 0) {
            address[][] memory bribeClaimTokens = _createNestedTokenArray(bribeAddresses.length, claimTokens);
            IVoter(voter).claimBribesToRecipientByTokenId(bribeAddresses, bribeClaimTokens, tokenId, address(this));
        }

        // Calculate amounts received and forward to operator
        uint256[] memory amountsReceived = new uint256[](claimTokens.length);
        for (uint256 i = 0; i < claimTokens.length; i++) {
            uint256 balanceAfter = IERC20(claimTokens[i]).balanceOf(address(this));
            amountsReceived[i] = balanceAfter - balancesBefore[i];

            // Send claimed tokens to partner
            if (amountsReceived[i] > 0) {
                IERC20(claimTokens[i]).transfer(msg.sender, amountsReceived[i]);
            }
        }

        emit RewardsClaimedAndForwarded(msg.sender, claimTokens, amountsReceived);
    }

    /**
     * @notice Partner can claim the veNFT after vesting period completes
     */
    function claimVeToken() external onlyRole(PARTNER_ROLE) hasVeToken {
        require(block.timestamp >= depositTime + vestingPeriod, "Vesting period not complete");
        address _veToken = veToken;
        uint256 _tokenId = tokenId;
        veToken = address(0);
        tokenId = 0;
        depositTime = 0;
        IERC721(_veToken).safeTransferFrom(address(this), msg.sender, _tokenId);
        emit VeTokenWithdrawn(_veToken, _tokenId, msg.sender);
    }

    /*   
        Admin Functions
    */

    /**
     * @notice Factory finalizes deposit after transferring veNFT into this escrow
     * @param _tokenId Token ID that must already be owned by this escrow
     * @param _vestingPeriod Vesting period in seconds
     * @dev The factory should first transfer the veNFT from the admin to this escrow, then call this function
     */
    function factoryFinalizeDeposit(uint256 _tokenId, uint256 _vestingPeriod) external onlyRole(FACTORY_ROLE) {
        require(tokenId == 0, "Already holding veNFT");
        require(_vestingPeriod > 0, "Invalid vesting period");
        require(IERC721(veToken).ownerOf(_tokenId) == address(this), "Escrow not owner");
        tokenId = _tokenId;
        vestingPeriod = _vestingPeriod;
        depositTime = block.timestamp;
        emit VeTokenDeposited(veToken, _tokenId, depositTime);
    }

    /**
     * @notice Admin or factory can approve or revoke conduits for use by partners
     * @param conduitAddress Address of the conduit to approve/revoke
     * @param approved True to approve, false to revoke
     */
    function setConduitApproval(address conduitAddress, bool approved) external {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender) || hasRole(FACTORY_ROLE, msg.sender), "Access denied");
        require(conduitAddress != address(0), "Invalid conduit address");
        approvedConduits[conduitAddress] = approved;
        emit ConduitApprovalUpdated(conduitAddress, approved);
    }

    /**
     * @notice Admin or factory can batch approve or revoke multiple conduits
     * @param conduitAddresses Array of conduit addresses
     * @param approved Array of approval statuses
     */
    function batchSetConduitApproval(address[] calldata conduitAddresses, bool[] calldata approved) external {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender) || hasRole(FACTORY_ROLE, msg.sender), "Access denied");
        require(conduitAddresses.length == approved.length, "Array length mismatch");
        for (uint256 i = 0; i < conduitAddresses.length; i++) {
            require(conduitAddresses[i] != address(0), "Invalid conduit address");
            approvedConduits[conduitAddresses[i]] = approved[i];
            emit ConduitApprovalUpdated(conduitAddresses[i], approved[i]);
        }
    }

    /**
     * @notice Emergency withdraw of ERC20 tokens held by this contract
     * @param token ERC20 token address to withdraw
     * @param amount Amount to withdraw
     * @param to Recipient address
     */
    function withdrawERC20(address token, uint256 amount, address to) external {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender) || hasRole(PARTNER_ROLE, msg.sender), "Access denied");
        require(to != address(0), "Invalid recipient");
        IERC20(token).transfer(to, amount);
        emit ERC20Withdrawn(token, amount, to, msg.sender);
    }

    /**
     * @notice Emergency withdraw of an ERC721 token held by this contract
     * @param _tokenId Token ID to withdraw
     * @param to Recipient address
     */
    function emergencyWithdrawERC721(uint256 _tokenId, address to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(to != address(0), "Invalid recipient");
        emit ERC721EmergencyWithdrawn(veToken, _tokenId, to, msg.sender);
        IERC721(veToken).safeTransferFrom(address(this), to, _tokenId);
    }

    /**
     * @notice Emergency withdraw of ETH held by this contract
     * @param amount Amount of ETH to withdraw
     * @param to Recipient address
     */
    function emergencyWithdrawETH(uint256 amount, address payable to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(to != address(0), "Invalid recipient");
        require(address(this).balance >= amount, "Insufficient balance");
            emit ETHEmergencyWithdrawn(amount, to, msg.sender);
        to.transfer(amount);
    }

    /* 
        Helper & Override Functions
    */

    // Helper function to create nested arrays for claiming
    /**
     * @dev Create a nested array duplicating `tokens` `length` times
     * @param length Number of inner arrays to create
     * @param tokens Token list to duplicate in each inner array
     * @return nestedArray Constructed nested array of token lists
     */
    function _createNestedTokenArray(
        uint256 length,
        address[] memory tokens
    ) internal pure returns (address[][] memory) {
        address[][] memory nestedArray = new address[][](length);
        for (uint256 i = 0; i < length; i++) {
            nestedArray[i] = tokens;
        }
        return nestedArray;
    }

    /**
     * @notice ERC721 receiver hook
     * @return selector Function selector to confirm receipt
     */
    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    /**
     * @notice Allow the contract to receive ETH
     */
    receive() external payable {}
}

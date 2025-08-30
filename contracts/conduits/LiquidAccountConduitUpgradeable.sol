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
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IVoter} from "../interfaces/IVoter.sol";
import {IOptionsToken} from "../interfaces/IOptionsToken.sol";
import {IHydrexVotingEscrow} from "../interfaces/IHydrexVotingEscrow.sol";

/**
 * @title LiquidAccountConduitUpgradeable
 * @notice Conduit for claiming reward tokens, exercising options, and distributing other tokens
 * @dev Simplified flow:
 *      1) Claim all reward tokens for `user` to this contract
 *      2) Exercise option tokens to create veNFT(s) to this contract
 *      3) Send veNFT created to the end user
 *      4) Send other (non-option) tokens to user
 *      5) (optional) merge the new veNFT into the end user's existing veNFT
 */
contract LiquidAccountConduitUpgradeable is Initializable, AccessControlUpgradeable, IERC721Receiver {
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    address public voter;
    address public optionsToken;
    address public veToken;

    /*
     * Events
     */

    event OptionTokensClaimed(address indexed user, uint256 amount);
    event OptionTokensExercised(address indexed user, uint256 amount, uint256 nftId);
    event VeNftTransferred(address indexed user, uint256 indexed nftId);
    event TokensDistributed(address indexed user, address indexed token, uint256 amount);
    event MergeExecuted(address indexed user, uint256 indexed fromTokenId, uint256 indexed toTokenId);

    /*
     * Errors
     */

    error InvalidAddress();
    error InvalidAmount();
    error OptionsTokenMustBeFirstToken();
    error InvalidTokenIds();
    error NotTokenOwner();

    /*
     * Constructor & Initializer
     */

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address defaultAdmin,
        address _voter,
        address _optionsToken,
        address _veToken
    ) external initializer {
        if (_voter == address(0)) revert InvalidAddress();
        if (_optionsToken == address(0)) revert InvalidAddress();
        if (_veToken == address(0)) revert InvalidAddress();

        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(EXECUTOR_ROLE, defaultAdmin);

        voter = _voter;
        optionsToken = _optionsToken;
        veToken = _veToken;
    }

    /*
     * Main Functions
     */

    /**
     * @notice Claims reward tokens, exercises options, distributes tokens, and optionally merges the new veNFT
     * @param _gauges Array of gauge addresses to claim from
     * @param _tokens Array of token addresses to claim (options token MUST be at index 0)
     * @param _user Address to claim rewards for and receive: the minted veNFT and all non-option tokens
     * @param _mergeToTokenId Optional veNFT tokenId owned by `_user` to merge the newly minted veNFT into (0 to skip)
     */
    function claimAndExercise(
        address[] calldata _gauges,
        address[] calldata _tokens,
        address _user,
        uint256 _mergeToTokenId
    ) external onlyRole(EXECUTOR_ROLE) {
        if (_user == address(0)) revert InvalidAddress();
        if (_tokens.length == 0 || _tokens[0] != optionsToken) revert OptionsTokenMustBeFirstToken();

        uint256[] memory balancesBefore = new uint256[](_tokens.length);
        for (uint256 i = 0; i < _tokens.length; i++) {
            balancesBefore[i] = IERC20(_tokens[i]).balanceOf(address(this));
        }

        address[][] memory nestedTokens = _createNestedTokenArray(_gauges.length, _tokens);
        IVoter(voter).claimRewardTokensToRecipient(_gauges, nestedTokens, _user, address(this));

        uint256 optionsBalanceAfter = IERC20(optionsToken).balanceOf(address(this));
        uint256 optionsClaimedAmount = optionsBalanceAfter - balancesBefore[0];

        uint256 mintedNftId;
        if (optionsClaimedAmount > 0) {
            emit OptionTokensClaimed(_user, optionsClaimedAmount);
            mintedNftId = _convertToVeNFT(optionsClaimedAmount, _user);

            if (mintedNftId != 0) {
                IERC721(veToken).safeTransferFrom(address(this), _user, mintedNftId);
                emit VeNftTransferred(_user, mintedNftId);
            }
        }

        _distributeOtherTokens(_tokens, balancesBefore, _user);

        if (mintedNftId != 0 && _mergeToTokenId != 0) {
            _mergeVeNFTs(_user, mintedNftId, _mergeToTokenId);
        }
    }

    /*
     * Internal Functions
     */

    /**
     * @notice Exercises option tokens to create a veNFT minted to this contract
     * @param _amount Amount of option tokens to exercise
     * @param _user The end user on whose behalf this operation occurs (for event context)
     * @return nftId The newly minted veNFT id (0 if nothing minted)
     */
    function _convertToVeNFT(uint256 _amount, address _user) internal returns (uint256 nftId) {
        if (_amount == 0) return 0;
        nftId = IOptionsToken(optionsToken).exerciseVe(_amount, address(this));
        emit OptionTokensExercised(_user, _amount, nftId);
    }

    /**
     * @notice Creates nested token array for voter interface
     * @param arrayCount Number of arrays to create
     * @param tokens Token addresses to duplicate across arrays
     * @return result Nested array where each sub-array contains the same tokens
     */
    function _createNestedTokenArray(
        uint256 arrayCount,
        address[] calldata tokens
    ) internal pure returns (address[][] memory) {
        address[][] memory result = new address[][](arrayCount);
        for (uint256 i = 0; i < arrayCount; i++) {
            result[i] = tokens;
        }
        return result;
    }

    /**
     * @notice Distributes all non-option reward tokens to the user
     * @param _tokens Array of all token addresses
     * @param _balancesBefore Array of balances before claiming
     * @param _user Address to send tokens to
     */
    function _distributeOtherTokens(
        address[] calldata _tokens,
        uint256[] memory _balancesBefore,
        address _user
    ) internal {
        for (uint256 i = 0; i < _tokens.length; i++) {
            if (_tokens[i] != optionsToken) {
                uint256 balanceAfter = IERC20(_tokens[i]).balanceOf(address(this));
                uint256 claimedAmount = balanceAfter - _balancesBefore[i];

                if (claimedAmount > 0) {
                    IERC20(_tokens[i]).transfer(_user, claimedAmount);
                    emit TokensDistributed(_user, _tokens[i], claimedAmount);
                }
            }
        }
    }

    /**
     * @notice Internal merge helper for veNFTs
     * @dev Requires this contract to be approved as operator on the ve token by `user`.
     *      Both `_from` and `_to` must be owned by `user` at call time.
     */
    function _mergeVeNFTs(address user, uint256 _from, uint256 _to) internal {
        if (user == address(0)) revert InvalidAddress();
        if (_from == 0 || _to == 0 || _from == _to) revert InvalidTokenIds();

        address ownerFrom = IERC721(veToken).ownerOf(_from);
        address ownerTo = IERC721(veToken).ownerOf(_to);
        if (ownerFrom != user || ownerTo != user) revert NotTokenOwner();

        IHydrexVotingEscrow(veToken).merge(_from, _to);
        emit MergeExecuted(user, _from, _to);
    }

    /*
     * Admin Functions
     */

    /**
     * @notice External wrapper to merge two veNFTs for a user
     * @param user Owner of both veNFTs
     * @param _from TokenId to merge from (burned)
     * @param _to TokenId to merge into (receiver)
     */
    function mergeFor(address user, uint256 _from, uint256 _to) external onlyRole(EXECUTOR_ROLE) {
        _mergeVeNFTs(user, _from, _to);
    }

    /// @notice Admin wrapper to configure this conduit on the veToken contract
    /// @param actions Array of approval actions to enable for this conduit
    /// @param description Human-readable description
    function adminSetConduitApprovalConfig(
        uint8[] calldata actions,
        string calldata description
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        IHydrexVotingEscrow(veToken).setConduitApprovalConfig(actions, description);
    }

    /**
     * @notice Emergency function to recover any stuck tokens
     * @param _token Token address to recover
     * @param _amount Amount to recover
     * @param _recipient Address to send recovered tokens to
     */
    function emergencyRecover(
        address _token,
        uint256 _amount,
        address _recipient
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_token == address(0) || _recipient == address(0)) revert InvalidAddress();
        if (_amount == 0) revert InvalidAmount();

        IERC20(_token).transfer(_recipient, _amount);
    }

    /**
     * @notice Emergency function to withdraw ETH
     * @param _amount Amount of ETH to withdraw
     * @param _recipient Recipient of the withdrawn ETH
     */
    function emergencyWithdrawETH(uint256 _amount, address payable _recipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_recipient == address(0)) revert InvalidAddress();
        if (_amount == 0) revert InvalidAmount();
        require(address(this).balance >= _amount, "Insufficient balance");
        _recipient.transfer(_amount);
    }

    /**
     * @notice Emergency function to withdraw an ERC721 (e.g., exercised veNFT)
     * @param _token ERC721 token address
     * @param _tokenId Token ID to withdraw
     * @param _recipient Recipient of the withdrawn NFT
     */
    function emergencyWithdrawERC721(
        address _token,
        uint256 _tokenId,
        address _recipient
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_token == address(0) || _recipient == address(0)) revert InvalidAddress();
        IERC721(_token).safeTransferFrom(address(this), _recipient, _tokenId);
    }

    /**
     * @notice ERC721 receiver hook to accept safe mints/transfers
     */
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    /**
     * @notice Allow the contract to receive ETH
     */
    receive() external payable {}
}

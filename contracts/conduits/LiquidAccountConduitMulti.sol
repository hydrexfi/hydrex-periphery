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
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IVoter} from "../interfaces/IVoter.sol";
import {IOptionsToken} from "../interfaces/IOptionsToken.sol";
import {IHydrexVotingEscrow} from "../interfaces/IHydrexVotingEscrow.sol";

/**
 * @title LiquidAccountConduitMulti
 * @notice Conduit for claiming option tokens from gauges and arbitrary distributors, then exercising them
 * @dev Flow:
 *      1) Claim option tokens for `user` from gauges and/or external distributors to this contract
 *      2) Exercise option tokens to create veNFT(s) to this contract
 *      3) Send veNFT created to the end user
 *      4) (optional) merge the new veNFT into the end user's existing veNFT
 */
contract LiquidAccountConduitMulti is AccessControl, IERC721Receiver {
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    address public immutable voter;
    address public immutable optionsToken;
    address public immutable veToken;

    /*
     * State
     */

    /// @notice Timestamp of the last successful job process per user
    mapping(address => uint256) public lastJobTimestamp;

    /// @notice Global cumulative amount of options tokens accumulated by each user
    mapping(address => uint256) public cumulativeOptionsClaimed;

    /*
     * Events
     */

    event OptionsHarvestedFromGauge(address indexed gauge, uint256 amount, address indexed user);

    event OptionsHarvestedFromDistributor(address indexed distributor, uint256 amount, address indexed user);

    event LiquidConduitJobExecuted(
        address indexed user,
        uint256 totalOptionsClaimed,
        uint256 indexed mintedNftId,
        uint256 indexed mergedToTokenId
    );

    /*
     * Errors
     */

    error InvalidAddress();
    error InvalidAmount();
    error InvalidTokenIds();
    error NotTokenOwner();
    error InvalidLengths();
    error DistributorCallFailed();

    /*
     * Constructor
     */

    constructor(address defaultAdmin, address _voter, address _optionsToken, address _veToken) {
        if (_voter == address(0)) revert InvalidAddress();
        if (_optionsToken == address(0)) revert InvalidAddress();
        if (_veToken == address(0)) revert InvalidAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(EXECUTOR_ROLE, defaultAdmin);

        uint8[] memory actions = new uint8[](1);
        actions[0] = 4;
        IHydrexVotingEscrow(_veToken).setConduitApprovalConfig(actions, "");

        voter = _voter;
        optionsToken = _optionsToken;
        veToken = _veToken;
    }

    /*
     * Main Functions
     */

    /**
     * @notice Claims option tokens from gauges and arbitrary distributors, exercises them, and optionally merges the new veNFT
     * @param _gauges Array of gauge addresses to claim from
     * @param _user Address to claim rewards for and receive the minted veNFT
     * @param _mergeToTokenId Optional veNFT tokenId owned by `_user` to merge the newly minted veNFT into (0 to skip)
     * @param _distributorTargets Array of external distributor contract addresses to call
     * @param _distributorCalldata Array of calldata to execute on each distributor (must match length of _distributorTargets)
     */
    function claimExerciseAndMerge(
        address[] calldata _gauges,
        address _user,
        address[] calldata _distributorTargets,
        bytes[] calldata _distributorCalldata,
        uint256 _mergeToTokenId
    ) external onlyRole(EXECUTOR_ROLE) {
        if (_user == address(0)) revert InvalidAddress();
        if (_distributorTargets.length != _distributorCalldata.length) revert InvalidLengths();

        uint256 totalOptionsClaimed = 0;

        // Step 1: Claim from gauges
        for (uint256 i = 0; i < _gauges.length; i++) {
            uint256 balanceBefore = IERC20(optionsToken).balanceOf(address(this));

            address[] memory gaugeArray = new address[](1);
            gaugeArray[0] = _gauges[i];

            address[][] memory nestedTokens = new address[][](1);
            nestedTokens[0] = new address[](1);
            nestedTokens[0][0] = optionsToken;

            IVoter(voter).claimRewardTokensToRecipient(gaugeArray, nestedTokens, _user, address(this));

            uint256 balanceAfter = IERC20(optionsToken).balanceOf(address(this));
            uint256 claimedFromGauge = balanceAfter - balanceBefore;

            if (claimedFromGauge > 0) {
                emit OptionsHarvestedFromGauge(_gauges[i], claimedFromGauge, _user);
                totalOptionsClaimed += claimedFromGauge;
            }
        }

        // Step 2: Claim from external distributors
        for (uint256 i = 0; i < _distributorTargets.length; i++) {
            uint256 balanceBefore = IERC20(optionsToken).balanceOf(address(this));

            // Execute arbitrary call to distributor
            (bool success, ) = _distributorTargets[i].call(_distributorCalldata[i]);
            if (!success) revert DistributorCallFailed();

            uint256 balanceAfter = IERC20(optionsToken).balanceOf(address(this));
            uint256 claimedFromDistributor = balanceAfter - balanceBefore;

            if (claimedFromDistributor > 0) {
                emit OptionsHarvestedFromDistributor(_distributorTargets[i], claimedFromDistributor, _user);
                totalOptionsClaimed += claimedFromDistributor;
            }
        }

        // Step 3: Exercise all claimed options and mint veNFT
        uint256 mintedNftId;
        if (totalOptionsClaimed > 0) {
            mintedNftId = _convertToVeNFT(totalOptionsClaimed, _user);

            if (mintedNftId != 0) {
                IERC721(veToken).safeTransferFrom(address(this), _user, mintedNftId);
            }
        }

        // Step 4: Optionally merge into existing veNFT
        if (mintedNftId != 0 && _mergeToTokenId != 0) {
            _mergeVeNFTs(_user, mintedNftId, _mergeToTokenId);
        }

        lastJobTimestamp[_user] = block.timestamp;
        cumulativeOptionsClaimed[_user] += totalOptionsClaimed;

        emit LiquidConduitJobExecuted(_user, totalOptionsClaimed, mintedNftId, _mergeToTokenId);
    }

    /*
     * Internal Functions
     */

    /**
     * @notice Exercises option tokens to create a veNFT minted to this contract
     * @param _amount Amount of option tokens to exercise
     * @return nftId The newly minted veNFT id (0 if nothing minted)
     */
    function _convertToVeNFT(uint256 _amount, address /* _user */) internal returns (uint256 nftId) {
        if (_amount == 0) return 0;
        nftId = IOptionsToken(optionsToken).exerciseVe(_amount, address(this));
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

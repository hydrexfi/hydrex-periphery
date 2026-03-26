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
import {IKlimaRetirementAggregator} from "../interfaces/IKlimaRetirementAggregator.sol";

/**
 * @title KlimaVeTokenConduit
 * @notice Claims ve(3,3) rewards, swaps into output tokens, retires a configurable
 *         fraction of kVCM via Carbonmark, then distributes all output balances to
 *         the veNFT holder. Output tokens and retire fraction are admin-configurable.
 */
contract KlimaVeTokenConduit is AccessControl {
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    uint256 public constant MAX_TREASURY_FEE_BPS = 100;

    // -------------------------------------------------------------------------
    // Immutables
    // -------------------------------------------------------------------------

    address public immutable kvcm;
    address public immutable voter;
    address public immutable veToken;

    // -------------------------------------------------------------------------
    // Config
    // -------------------------------------------------------------------------

    /// @notice Tokens swept to the holder on each distribution cycle
    address[] public distributionTokens;

    address public retirementAggregator;
    address public aam;
    address public creditToken;
    address public carbonClass;

    /// @notice ERC-1155 token ID for the credit token (0 for ERC-20 credits)
    uint256 public creditTokenId;

    /// @notice Puro batch ID (0 for non-Puro credits)
    uint256 public batchId;

    /// @notice Fraction of kVCM balance to retire each cycle, in BPS (0–10000)
    uint256 public retireBps;

    uint256 public treasuryFeeBps;
    address public treasury;
    address[] public approvedRouters;
    string public retiringEntityName;
    address public impactBeneficiaryAddress;

    /// @notice Human-readable beneficiary name forwarded to the retirement aggregator
    string public beneficiaryString;

    /// @notice Retirement message forwarded to the retirement aggregator
    string public retirementMessage;

    // -------------------------------------------------------------------------
    // Tracking
    // -------------------------------------------------------------------------

    uint256 public totalTonnesRetired;
    uint256 public totalKvcmRetired;
    mapping(address => address) public userToPayoutRecipient;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

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

    event CarbonRetired(address indexed creditToken_, uint256 retireTonnes, uint256 kvcmSpent);
    event PayoutRecipientUpdated(address indexed user, address indexed newRecipient, address indexed updatedBy);
    event RetirementConfigUpdated(address retirementAggregator, address aam, address creditToken, address carbonClass, uint256 creditTokenId, uint256 batchId, uint256 retireBps);
    event RetirementDetailsUpdated(address impactBeneficiaryAddress, string retiringEntityName, string beneficiaryString, string retirementMessage);
    event DistributionTokensUpdated(address[] tokens);

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(
        address defaultAdmin,
        address _treasury,
        address _voter,
        address _veToken,
        address _kvcm,
        address[] memory _distributionTokens,
        address _retirementAggregator,
        address _aam,
        address _creditToken,
        address _carbonClass,
        uint256 _retireBps,
        address[] memory _approvedRouters
    ) {
        require(_treasury != address(0), "Invalid treasury");
        require(_voter != address(0), "Invalid voter");
        require(_veToken != address(0), "Invalid veToken");
        require(_kvcm != address(0), "Invalid kvcm");
        require(_distributionTokens.length > 0, "Must have at least one distribution token");
        require(_retirementAggregator != address(0), "Invalid retirement aggregator");
        require(_aam != address(0), "Invalid AAM");
        require(_creditToken != address(0), "Invalid credit token");
        require(_carbonClass != address(0), "Invalid carbon class");
        require(_retireBps <= 10000, "retireBps exceeds 100%");
        require(_approvedRouters.length > 0, "Must have at least one approved router");

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(EXECUTOR_ROLE, msg.sender);

        treasury = _treasury;
        voter = _voter;
        veToken = _veToken;
        kvcm = _kvcm;
        retirementAggregator = _retirementAggregator;
        aam = _aam;
        creditToken = _creditToken;
        carbonClass = _carbonClass;
        retireBps = _retireBps;
        retiringEntityName = "Hydrex";
        impactBeneficiaryAddress = 0xcba0000027bd78edf6714DE3bCC312360E469502;
        retirementMessage = "Programmatic carbon retirement via Hydrex's Carbon Strategy on the Base network";

        for (uint256 i = 0; i < _distributionTokens.length; i++) {
            require(_distributionTokens[i] != address(0), "Invalid distribution token");
            distributionTokens.push(_distributionTokens[i]);
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

    // -------------------------------------------------------------------------
    // View
    // -------------------------------------------------------------------------

    function isApprovedRouter(address router) public view returns (bool) {
        for (uint256 i = 0; i < approvedRouters.length; i++) {
            if (approvedRouters[i] == router) return true;
        }
        return false;
    }

    function getEffectiveRecipientForOwner(address owner) public view returns (address) {
        address configured = userToPayoutRecipient[owner];
        return configured == address(0) ? owner : configured;
    }

    function maxRetirableKvcm() external view returns (uint256) {
        return (IERC20(kvcm).balanceOf(address(this)) * retireBps) / 10000;
    }

    // -------------------------------------------------------------------------
    // User
    // -------------------------------------------------------------------------

    function setMyPayoutRecipient(address newRecipient) external {
        userToPayoutRecipient[msg.sender] = newRecipient;
        emit PayoutRecipientUpdated(msg.sender, newRecipient, msg.sender);
    }

    // -------------------------------------------------------------------------
    // Executor
    // -------------------------------------------------------------------------

    /**
     * @param retireTonnes  Tonnes to retire; pass 0 to skip retirement
     * @param maxKvcmIn     Max kVCM to spend on retirement — must be ≤ kvcmBalance * retireBps / 10000.
     *                      Compute off-chain via quoteRetireCreditViaKlima. Ignored when retireTonnes == 0.
     */
    function claimSwapAndDistribute(
        uint256 veTokenId,
        address[] calldata targets,
        bytes[] calldata swaps,
        address[] calldata feeAddresses,
        address[] calldata bribeAddresses,
        address[] calldata claimTokens,
        uint256 retireTonnes,
        uint256 maxKvcmIn
    ) external onlyRole(EXECUTOR_ROLE) {
        address owner = IERC721(veToken).ownerOf(veTokenId);
        require(owner != address(0), "Invalid token owner");
        address recipient = getEffectiveRecipientForOwner(owner);

        _assertNoDuplicateAddresses(claimTokens);

        uint256[] memory balancesBefore = new uint256[](claimTokens.length);
        for (uint256 i = 0; i < claimTokens.length; i++) {
            balancesBefore[i] = IERC20(claimTokens[i]).balanceOf(address(this));
        }

        _claimBribesAndFees(veTokenId, feeAddresses, bribeAddresses, claimTokens);

        uint256[] memory claimedAmounts = new uint256[](claimTokens.length);
        for (uint256 i = 0; i < claimTokens.length; i++) {
            claimedAmounts[i] = IERC20(claimTokens[i]).balanceOf(address(this)) - balancesBefore[i];
        }

        _runSwaps(targets, swaps, claimTokens);

        if (retireTonnes > 0) {
            _retireKvcm(retireTonnes, maxKvcmIn);
        }

        (uint256[] memory distAmounts, uint256[] memory fees) = _distribute(recipient);

        emit ClaimSwapAndDistributeCompleted(
            veTokenId, owner, recipient,
            claimTokens, claimedAmounts,
            distributionTokens, distAmounts, fees
        );
    }

    function vote(address[] calldata pools, uint256[] calldata weights) external onlyRole(EXECUTOR_ROLE) {
        require(pools.length == weights.length, "Pools/weights length mismatch");
        IVoter(voter).vote(pools, weights);
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    function _claimBribesAndFees(
        uint256 veTokenId,
        address[] memory feeAddresses,
        address[] memory bribeAddresses,
        address[] memory claimTokens
    ) internal {
        if (feeAddresses.length > 0) {
            IVoter(voter).claimFeesToRecipientByTokenId(
                feeAddresses, _createNestedTokenArray(feeAddresses.length, claimTokens), veTokenId, address(this)
            );
        }
        if (bribeAddresses.length > 0) {
            IVoter(voter).claimBribesToRecipientByTokenId(
                bribeAddresses, _createNestedTokenArray(bribeAddresses.length, claimTokens), veTokenId, address(this)
            );
        }
    }

    function _runSwaps(
        address[] calldata targets,
        bytes[] calldata swaps,
        address[] calldata inputTokens
    ) internal {
        require(targets.length == swaps.length, "Targets/swaps length mismatch");

        address[] memory outTokens = distributionTokens;

        for (uint256 i = 0; i < inputTokens.length; i++) {
            for (uint256 t = 0; t < targets.length; t++) {
                IERC20(inputTokens[i]).approve(targets[t], 0);
                IERC20(inputTokens[i]).approve(targets[t], type(uint256).max);
            }
        }

        for (uint256 i = 0; i < targets.length; i++) {
            require(isApprovedRouter(targets[i]), "Router not approved");

            uint256[] memory outBefore = new uint256[](outTokens.length);
            for (uint256 j = 0; j < outTokens.length; j++) {
                outBefore[j] = IERC20(outTokens[j]).balanceOf(address(this));
            }

            (bool success, bytes memory returndata) = targets[i].call(swaps[i]);
            if (!success) {
                if (returndata.length >= 68) {
                    assembly { returndata := add(returndata, 0x04) }
                    revert(abi.decode(returndata, (string)));
                }
                revert("Swap failed");
            }

            bool increased = false;
            for (uint256 j = 0; j < outTokens.length; j++) {
                if (IERC20(outTokens[j]).balanceOf(address(this)) > outBefore[j]) {
                    increased = true;
                    break;
                }
            }
            require(increased, "No output token balance increase after swap");
        }

        for (uint256 i = 0; i < inputTokens.length; i++) {
            for (uint256 t = 0; t < targets.length; t++) {
                IERC20(inputTokens[i]).approve(targets[t], 0);
            }
        }
    }

    function _retireKvcm(uint256 retireTonnes, uint256 maxKvcmIn) internal returns (uint256 kvcmSpent) {
        uint256 kvcmBalance = IERC20(kvcm).balanceOf(address(this));
        require(kvcmBalance > 0, "No kVCM balance to retire");
        require(maxKvcmIn > 0, "maxKvcmIn must be > 0");
        require(maxKvcmIn <= (kvcmBalance * retireBps) / 10000, "maxKvcmIn exceeds retire allocation");

        IKlimaRetirementAggregator.RetireDetails memory details;
        details.retiringAddress      = address(this);
        details.retiringEntityString = retiringEntityName;
        details.beneficiaryAddress   = impactBeneficiaryAddress;
        details.beneficiaryString    = beneficiaryString;
        details.retirementMessage    = retirementMessage;

        IERC20(kvcm).approve(aam, 0);
        IERC20(kvcm).approve(aam, maxKvcmIn);

        IKlimaRetirementAggregator(retirementAggregator).retireCreditViaKlima(
            creditToken, creditTokenId, batchId,
            retireTonnes, kvcm, carbonClass, maxKvcmIn, 0, details
        );

        kvcmSpent = kvcmBalance - IERC20(kvcm).balanceOf(address(this));

        IERC20(kvcm).approve(aam, 0);

        totalTonnesRetired += retireTonnes;
        totalKvcmRetired   += kvcmSpent;

        emit CarbonRetired(creditToken, retireTonnes, kvcmSpent);
    }

    function _distribute(address recipient) internal returns (
        uint256[] memory amounts,
        uint256[] memory fees
    ) {
        address[] memory tokens = distributionTokens;
        amounts = new uint256[](tokens.length);
        fees    = new uint256[](tokens.length);

        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 balance = IERC20(tokens[i]).balanceOf(address(this));
            if (balance == 0) continue;

            fees[i]    = (balance * treasuryFeeBps) / 10000;
            amounts[i] = balance - fees[i];

            if (fees[i] > 0)    IERC20(tokens[i]).transfer(treasury, fees[i]);
            if (amounts[i] > 0) IERC20(tokens[i]).transfer(recipient, amounts[i]);
        }
    }

    function _createNestedTokenArray(
        uint256 arrayCount,
        address[] memory tokens
    ) internal pure returns (address[][] memory result) {
        result = new address[][](arrayCount);
        for (uint256 i = 0; i < arrayCount; i++) {
            result[i] = tokens;
        }
    }

    function _assertNoDuplicateAddresses(address[] memory addresses) internal pure {
        for (uint256 i = 0; i < addresses.length; i++) {
            for (uint256 j = i + 1; j < addresses.length; j++) {
                require(addresses[i] != addresses[j], "Duplicate claim token");
            }
        }
    }

    // -------------------------------------------------------------------------
    // Admin
    // -------------------------------------------------------------------------

    function setDistributionTokens(address[] calldata tokens) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(tokens.length > 0, "Must have at least one distribution token");
        delete distributionTokens;
        for (uint256 i = 0; i < tokens.length; i++) {
            require(tokens[i] != address(0), "Invalid token address");
            distributionTokens.push(tokens[i]);
        }
        emit DistributionTokensUpdated(tokens);
    }

    function setRetirementConfig(
        address _retirementAggregator,
        address _aam,
        address _creditToken,
        address _carbonClass,
        uint256 _creditTokenId,
        uint256 _batchId,
        uint256 _retireBps
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_retirementAggregator != address(0), "Invalid retirement aggregator");
        require(_aam != address(0), "Invalid AAM");
        require(_creditToken != address(0), "Invalid credit token");
        require(_carbonClass != address(0), "Invalid carbon class");
        require(_retireBps <= 10000, "retireBps exceeds 100%");

        retirementAggregator = _retirementAggregator;
        aam = _aam;
        creditToken = _creditToken;
        carbonClass = _carbonClass;
        creditTokenId = _creditTokenId;
        batchId = _batchId;
        retireBps = _retireBps;

        emit RetirementConfigUpdated(_retirementAggregator, _aam, _creditToken, _carbonClass, _creditTokenId, _batchId, _retireBps);
    }

    /// @notice Set the human-readable retirement metadata forwarded to the aggregator
    function setRetirementDetails(
        address _impactBeneficiaryAddress,
        string calldata _retiringEntityName,
        string calldata _beneficiaryString,
        string calldata _retirementMessage
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_impactBeneficiaryAddress != address(0), "Invalid address");
        require(bytes(_retiringEntityName).length > 0, "Name cannot be empty");

        impactBeneficiaryAddress = _impactBeneficiaryAddress;
        retiringEntityName = _retiringEntityName;
        beneficiaryString = _beneficiaryString;
        retirementMessage = _retirementMessage;

        emit RetirementDetailsUpdated(_impactBeneficiaryAddress, _retiringEntityName, _beneficiaryString, _retirementMessage);
    }

    function adminSetConduitApprovalConfig(
        uint8[] calldata actions,
        string calldata description
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        IHydrexVotingEscrow(veToken).setConduitApprovalConfig(actions, description);
    }

    function setTreasury(address _treasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_treasury != address(0), "Invalid treasury");
        treasury = _treasury;
    }

    function setTreasuryFeeBps(uint256 _treasuryFeeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_treasuryFeeBps <= MAX_TREASURY_FEE_BPS, "Fee exceeds max");
        treasuryFeeBps = _treasuryFeeBps;
    }

    function addApprovedRouter(address router) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(router != address(0), "Invalid router");
        approvedRouters.push(router);
    }

    function removeApprovedRouter(address router) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i = 0; i < approvedRouters.length; i++) {
            if (approvedRouters[i] == router) {
                approvedRouters[i] = approvedRouters[approvedRouters.length - 1];
                approvedRouters.pop();
                break;
            }
        }
    }

    function adminSetPayoutRecipient(address user, address newRecipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        userToPayoutRecipient[user] = newRecipient;
        emit PayoutRecipientUpdated(user, newRecipient, msg.sender);
    }

    function emergencyWithdrawERC20(address token, uint256 amount, address to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(token != address(0) && to != address(0), "Invalid address");
        require(amount > 0, "Invalid amount");
        IERC20(token).transfer(to, amount);
    }

    function emergencyWithdrawETH(uint256 amount, address payable to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(to != address(0), "Invalid address");
        require(amount > 0 && address(this).balance >= amount, "Invalid amount");
        to.transfer(amount);
    }

    receive() external payable {}
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

struct MerkleTree {
    bytes32 merkleRoot;
    bytes32 ipfsHash;
}

struct Claim {
    uint208 amount;
    uint48 timestamp;
    bytes32 merkleRoot;
}

interface ICore {
    function isGovernorOrGuardian(address user) external view returns (bool);
    function isGovernor(address user) external view returns (bool);
}

interface IMerklDistributor {
    // Events
    event Claimed(address indexed user, address indexed token, uint256 amount);
    event DisputeAmountUpdated(uint256 _disputeAmount);
    event Disputed(string reason);
    event DisputePeriodUpdated(uint48 _disputePeriod);
    event DisputeResolved(bool valid);
    event DisputeTokenUpdated(address indexed _disputeToken);
    event OperatorClaimingToggled(address indexed user, bool isEnabled);
    event OperatorToggled(address indexed user, address indexed operator, bool isWhitelisted);
    event Recovered(address indexed token, address indexed to, uint256 amount);
    event Revoked();
    event TreeUpdated(bytes32 merkleRoot, bytes32 ipfsHash, uint48 endOfDisputePeriod);
    event TrustedToggled(address indexed eoa, bool trust);

    // State variables getters
    function tree() external view returns (bytes32 merkleRoot, bytes32 ipfsHash);
    function lastTree() external view returns (bytes32 merkleRoot, bytes32 ipfsHash);
    function disputeToken() external view returns (IERC20);
    function core() external view returns (ICore);
    function disputer() external view returns (address);
    function endOfDisputePeriod() external view returns (uint48);
    function disputePeriod() external view returns (uint48);
    function disputeAmount() external view returns (uint256);
    function claimed(address user, address token) external view returns (uint208 amount, uint48 timestamp, bytes32 merkleRoot);
    function canUpdateMerkleRoot(address eoa) external view returns (uint256);
    function onlyOperatorCanClaim(address user) external view returns (uint256);
    function operators(address user, address operator) external view returns (uint256);

    // External functions
    function initialize(ICore _core) external;
    
    function claim(
        address[] calldata users,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external;

    function getMerkleRoot() external view returns (bytes32);

    function toggleTrusted(address eoa) external;
    
    function updateTree(MerkleTree calldata _tree) external;
    
    function disputeTree(string memory reason) external;
    
    function resolveDispute(bool valid) external;
    
    function revokeTree() external;
    
    function toggleOnlyOperatorCanClaim(address user) external;
    
    function toggleOperator(address user, address operator) external;
    
    function recoverERC20(address tokenAddress, address to, uint256 amountToRecover) external;
    
    function setDisputePeriod(uint48 _disputePeriod) external;
    
    function setDisputeToken(IERC20 _disputeToken) external;
    
    function setDisputeAmount(uint256 _disputeAmount) external;
}


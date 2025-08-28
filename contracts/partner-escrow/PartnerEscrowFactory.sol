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
import {PartnerEscrow} from "./PartnerEscrow.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/**
 * @title PartnerEscrowFactory
 * @notice Factory contract for deploying and tracking PartnerEscrow contracts
 * @dev Uses role-based access control for deployment permissions
 */
contract PartnerEscrowFactory is AccessControl {
    bytes32 public constant DEPLOYER_ROLE = keccak256("DEPLOYER_ROLE");
    /// @notice ve(3,3) voter contract used by all escrows
    address public immutable voter;
    /// @notice veNFT contract used for all escrows
    address public immutable veToken;

    /// @notice Array of all deployed escrow contract addresses
    address[] public deployedEscrows;
    /// @notice Mapping from partner address to their escrow contracts
    mapping(address => address[]) public partnerToEscrows;
    /// @notice Mapping to verify if an address is a factory-deployed escrow
    mapping(address => bool) public isDeployedEscrow;
    /// @notice Mapping from deployed escrow address to the escrowed tokenId
    mapping(address => uint256) public escrowToTokenId;

    event EscrowDeployed(address indexed escrow, address indexed admin, address indexed partner, address voter, uint256 tokenId);

    /**
     * @notice Constructor sets voter, veToken and grants roles
     * @param _voter Voter contract address to be injected into all escrows
     * @param _veToken veNFT contract address used across all escrows
     */
    constructor(address _voter, address _veToken) {
        require(_voter != address(0), "Invalid voter");
        require(_veToken != address(0), "Invalid veToken");
        voter = _voter;
        veToken = _veToken;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(DEPLOYER_ROLE, msg.sender);
    }

    /**
     * @notice Deploy a new PartnerEscrow contract and pull the veNFT in a single transaction
     * @param _admin Admin address for the escrow contract (current owner of `_tokenId`)
     * @param _partner Partner address for the escrow contract
     * @param _tokenId veNFT tokenId to transfer into escrow
     * @param _vestingPeriod Vesting period in seconds
     * @return escrow Address of the deployed escrow contract
     */
    function deployEscrow(
        address _admin,
        address _partner,
        uint256 _tokenId,
        uint256 _vestingPeriod
    ) external onlyRole(DEPLOYER_ROLE) returns (address escrow) {
        require(_admin != address(0), "Invalid admin address");
        require(_partner != address(0), "Invalid partner address");
        require(_vestingPeriod > 0, "Invalid vesting period");

        require(
            IERC721(veToken).getApproved(_tokenId) == address(this) ||
                IERC721(veToken).isApprovedForAll(_admin, address(this)),
            "Factory not approved"
        );

        escrow = address(new PartnerEscrow(_admin, _partner, voter, veToken));

        deployedEscrows.push(escrow);
        partnerToEscrows[_partner].push(escrow);
        isDeployedEscrow[escrow] = true;
        escrowToTokenId[escrow] = _tokenId;

        IERC721(veToken).safeTransferFrom(_admin, escrow, _tokenId);
        PartnerEscrow(payable(escrow)).factoryFinalizeDeposit(_tokenId, _vestingPeriod);

        emit EscrowDeployed(escrow, _admin, _partner, voter, _tokenId);
    }

    /**
     * @notice Get the number of deployed escrows
     * @return count Number of deployed escrows
     */
    function getDeployedEscrowsCount() external view returns (uint256 count) {
        return deployedEscrows.length;
    }

    /**
     * @notice Get all deployed escrows
     * @return escrows Array of deployed escrow addresses
     */
    function getAllDeployedEscrows() external view returns (address[] memory escrows) {
        return deployedEscrows;
    }

    /**
     * @notice Get escrows for a specific partner
     * @param _partner Partner address
     * @return escrows Array of escrow addresses for the partner
     */
    function getPartnerEscrows(address _partner) external view returns (address[] memory escrows) {
        return partnerToEscrows[_partner];
    }

    /**
     * @notice Get the number of escrows for a specific partner
     * @param _partner Partner address
     * @return count Number of escrows for the partner
     */
    function getPartnerEscrowsCount(address _partner) external view returns (uint256 count) {
        return partnerToEscrows[_partner].length;
    }

    /**
     * @notice Check if an address is a deployed escrow from this factory
     * @param _escrow Address to check
     * @return isEscrow True if the address is a deployed escrow
     */
    function isEscrowFromFactory(address _escrow) external view returns (bool isEscrow) {
        return isDeployedEscrow[_escrow];
    }

    /**
     * @notice Grant deployer role to an address
     * @param _deployer Address to grant deployer role
     */
    function grantDeployerRole(address _deployer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(DEPLOYER_ROLE, _deployer);
    }

    /**
     * @notice Revoke deployer role from an address
     * @param _deployer Address to revoke deployer role
     */
    function revokeDeployerRole(address _deployer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(DEPLOYER_ROLE, _deployer);
    }
}

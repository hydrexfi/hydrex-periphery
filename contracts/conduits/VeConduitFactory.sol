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
import {VeTokenConduit} from "./VeTokenConduit.sol";

/**
 * @title VeConduitFactory
 * @notice Factory for deploying and tracking VeTokenConduit contracts
 */
contract VeConduitFactory is AccessControl {
    bytes32 public constant DEPLOYER_ROLE = keccak256("DEPLOYER_ROLE");

    /// @notice Shared addresses for most conduit constructors
    address public immutable voter;
    address public immutable veToken;

    /// @notice Default admin set on new conduits
    address public defaultConduitAdmin;

    /// @notice Global treasury used for all VeTokenConduits
    address public treasury;

    /// @notice Default approved routers used for all VeTokenConduits
    address[] public approvedRouters;

    /// @notice Flag mapping for quick membership check
    mapping(address => bool) public isFactoryConduit;

    /// @notice Per-caller registry of deployed VeToken conduits
    mapping(address => address[]) public creatorToVeTokenConduits;

    /// @notice Registry of VeTokenConduit deployments
    address[] public veTokenConduits;

    event VeTokenConduitDeployed(
        address indexed conduit,
        address indexed creator,
        address treasury,
        address voter,
        address veToken
    );
    event DefaultConduitAdminUpdated(address indexed oldAdmin, address indexed newAdmin);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event ApprovedRouterAdded(address indexed router);
    event ApprovedRouterRemoved(address indexed router);

    constructor(address _voter, address _veToken, address _defaultConduitAdmin, address _treasury) {
        require(_voter != address(0), "Invalid voter");
        require(_veToken != address(0), "Invalid veToken");
        require(_defaultConduitAdmin != address(0), "Invalid default admin");
        require(_treasury != address(0), "Invalid treasury");

        voter = _voter;
        veToken = _veToken;
        defaultConduitAdmin = _defaultConduitAdmin;
        treasury = _treasury;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(DEPLOYER_ROLE, msg.sender);
    }

    /* =====================
       View helpers
       ===================== */

    function getVeTokenConduits() external view returns (address[] memory) {
        return veTokenConduits;
    }

    function getVeTokenConduitsCount() external view returns (uint256) {
        return veTokenConduits.length;
    }

    function getCreatorVeTokenConduits(address creator) external view returns (address[] memory) {
        return creatorToVeTokenConduits[creator];
    }

    /* =====================
       Deploy functions
       ===================== */

    /**
     * @notice Deploy a VeTokenConduit using factory's global treasury and routers
     * @param approvedOutputTokens List of output tokens the conduit can distribute
     * @return conduit Deployed conduit address
     */
    function deployVeTokenConduit(
        address[] calldata approvedOutputTokens
    ) external onlyRole(DEPLOYER_ROLE) returns (address conduit) {
        require(treasury != address(0), "Treasury not set");
        require(approvedRouters.length > 0, "No routers set");
        conduit = address(
            new VeTokenConduit(defaultConduitAdmin, treasury, voter, veToken, approvedOutputTokens, approvedRouters)
        );
        _trackVeToken(conduit, msg.sender);
        veTokenConduits.push(conduit);
        emit VeTokenConduitDeployed(conduit, msg.sender, treasury, voter, veToken);
    }

    /* =====================
       Admin
       ===================== */

    function setDefaultConduitAdmin(address newAdmin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newAdmin != address(0), "Invalid admin");
        address old = defaultConduitAdmin;
        defaultConduitAdmin = newAdmin;
        emit DefaultConduitAdminUpdated(old, newAdmin);
    }

    function grantDeployerRole(address deployer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(DEPLOYER_ROLE, deployer);
    }

    function revokeDeployerRole(address deployer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(DEPLOYER_ROLE, deployer);
    }

    /**
     * @notice Set the global treasury used for newly deployed VeTokenConduits
     */
    function setTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newTreasury != address(0), "Invalid treasury");
        address old = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(old, newTreasury);
    }

    /**
     * @notice Add an approved router (used by new VeTokenConduits)
     */
    function addApprovedRouter(address router) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(router != address(0), "Invalid router");
        approvedRouters.push(router);
        emit ApprovedRouterAdded(router);
    }

    /**
     * @notice Remove an approved router (linear scan)
     */
    function removeApprovedRouter(address router) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i = 0; i < approvedRouters.length; i++) {
            if (approvedRouters[i] == router) {
                approvedRouters[i] = approvedRouters[approvedRouters.length - 1];
                approvedRouters.pop();
                emit ApprovedRouterRemoved(router);
                break;
            }
        }
    }

    /* =====================
       Internal
       ===================== */

    function _trackVeToken(address conduit, address creator) internal {
        isFactoryConduit[conduit] = true;
        creatorToVeTokenConduits[creator].push(conduit);
    }
}



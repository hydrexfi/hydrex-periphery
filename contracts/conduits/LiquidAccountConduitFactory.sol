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

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {LiquidAccountConduitUpgradeable} from "./LiquidAccountConduitUpgradeable.sol";

/**
 * @title LiquidAccountConduitFactory
 * @notice Factory contract for deploying upgradeable LiquidAccountConduit proxies
 * @dev Uses OpenZeppelin's ERC1967Proxy for transparent upgradeable proxies
 */
contract LiquidAccountConduitFactory is Ownable {
    address public implementation;
    address public immutable voter;
    address public immutable optionsToken;
    address public immutable veToken;
    
    event ConduitDeployed(
        address indexed conduit,
        address indexed defaultAdmin
    );
    
    event ImplementationUpgraded(
        address indexed oldImplementation,
        address indexed newImplementation
    );
    
    error InvalidAddress();
    
    constructor(address _owner, address _voter, address _optionsToken, address _veToken) Ownable(_owner) {
        if (_voter == address(0)) revert InvalidAddress();
        if (_optionsToken == address(0)) revert InvalidAddress();
        if (_veToken == address(0)) revert InvalidAddress();
        
        voter = _voter;
        optionsToken = _optionsToken;
        veToken = _veToken;
        implementation = address(new LiquidAccountConduitUpgradeable());
    }
    
    /**
     * @notice Deploys a new upgradeable LiquidAccountConduit proxy
     * @param defaultAdmin Admin address for the new conduit
     * @return conduit Address of the deployed proxy
     */
    function deployConduit(
        address defaultAdmin
    ) external onlyOwner returns (address conduit) {
        if (defaultAdmin == address(0)) revert InvalidAddress();
        
        bytes memory initData = abi.encodeWithSelector(
            LiquidAccountConduitUpgradeable.initialize.selector,
            defaultAdmin,
            voter,
            optionsToken,
            veToken
        );
        
        conduit = address(new ERC1967Proxy(implementation, initData));
        
        emit ConduitDeployed(conduit, defaultAdmin);
    }
    
    /**
     * @notice Upgrades the implementation contract
     * @param newImplementation Address of the new implementation
     */
    function upgradeImplementation(address newImplementation) external onlyOwner {
        if (newImplementation == address(0)) revert InvalidAddress();
        
        address oldImplementation = implementation;
        implementation = newImplementation;
        
        emit ImplementationUpgraded(oldImplementation, newImplementation);
    }
    
    /**
     * @notice Gets the implementation address
     * @return implementation address
     */
    function getImplementation() external view returns (address) {
        return implementation;
    }
    
    /**
     * @notice Gets the global configuration
     * @return voter, optionsToken, veToken addresses
     */
    function getGlobalConfig() external view returns (address, address, address) {
        return (voter, optionsToken, veToken);
    }
}

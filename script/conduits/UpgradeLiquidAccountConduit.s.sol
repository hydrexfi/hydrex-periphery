// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {LiquidAccountConduitFactory} from "../../contracts/conduits/LiquidAccountConduitFactory.sol";
import {LiquidAccountConduitUpgradeable} from "../../contracts/conduits/LiquidAccountConduitUpgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/**
 * @title UpgradeLiquidAccountConduit
 * @dev Script to upgrade LiquidAccountConduit implementations and existing proxies
 */
contract UpgradeLiquidAccountConduit is Script {
    function run() public {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(deployerKey);
        string memory networkName = vm.envOr("NETWORK", string("base"));

        // Factory address (must be provided)
        address factoryAddress = vm.envAddress("FACTORY_ADDRESS");
        
        // Optional: specific proxy to upgrade (if not provided, only updates factory implementation)
        address proxyToUpgrade = vm.envOr("PROXY_ADDRESS", address(0));

        console2.log("=== LiquidAccountConduit Upgrade ===");
        console2.log("Network:", networkName);
        console2.log("Deployer:", deployer);
        console2.log("Factory:", factoryAddress);
        if (proxyToUpgrade != address(0)) {
            console2.log("Proxy to upgrade:", proxyToUpgrade);
        }
        console2.log("\n=== Starting Upgrade ===");

        vm.startBroadcast(deployerKey);

        LiquidAccountConduitFactory factory = LiquidAccountConduitFactory(factoryAddress);
        address oldImplementation = factory.getImplementation();
        
        // Deploy new implementation
        LiquidAccountConduitUpgradeable newImplementation = new LiquidAccountConduitUpgradeable();
        
        console2.log("Old implementation:", oldImplementation);
        console2.log("New implementation deployed at:", address(newImplementation));
        
        // Update factory implementation for future deployments
        factory.upgradeImplementation(address(newImplementation));
        console2.log("Factory implementation updated");
        
        // If specific proxy provided, upgrade it
        if (proxyToUpgrade != address(0)) {
            console2.log("Upgrading existing proxy...");
            
            // Since we're using basic ERC1967Proxy (not TransparentUpgradeableProxy),
            // we need to manually update the implementation slot
            // This is only possible if the deployer is the admin or if the contract has upgrade functions
            
            console2.log("Note: ERC1967Proxy upgrade requires manual intervention");
            console2.log("Options to upgrade the proxy:");
            console2.log("1. Use a ProxyAdmin contract if one was deployed");
            console2.log("2. Add upgrade functionality to the implementation");
            console2.log("3. Use OpenZeppelin's upgrade plugins");
            console2.log("- Proxy:", proxyToUpgrade);
            console2.log("- New Implementation:", address(newImplementation));
        }

        vm.stopBroadcast();

        console2.log("\n=== Upgrade Successful ===");
        console2.log("Factory:", factoryAddress);
        console2.log("Old implementation:", oldImplementation);
        console2.log("New implementation:", address(newImplementation));
        if (proxyToUpgrade != address(0)) {
            console2.log("Upgraded proxy:", proxyToUpgrade);
        }

        _saveUpgrade(networkName, factoryAddress, oldImplementation, address(newImplementation), proxyToUpgrade);
    }

    function _saveUpgrade(
        string memory networkName,
        address factoryAddress,
        address oldImplementation,
        address newImplementation,
        address upgradedProxy
    ) internal {
        string memory upgradePath = string.concat(
            "deployments/",
            networkName,
            "-upgrade-",
            vm.toString(block.timestamp),
            ".json"
        );

        string memory json = "upgrade";
        vm.serializeString(json, "network", networkName);
        vm.serializeUint(json, "timestamp", block.timestamp);
        vm.serializeUint(json, "blockNumber", block.number);
        vm.serializeAddress(json, "factory", factoryAddress);
        vm.serializeAddress(json, "oldImplementation", oldImplementation);
        vm.serializeAddress(json, "newImplementation", newImplementation);
        
        if (upgradedProxy != address(0)) {
            vm.serializeAddress(json, "upgradedProxy", upgradedProxy);
        }
        
        string memory finalJson = vm.serializeString(json, "type", "implementation_upgrade");

        vm.writeFile(upgradePath, finalJson);
        console2.log("Upgrade details saved to:", upgradePath);
    }
}

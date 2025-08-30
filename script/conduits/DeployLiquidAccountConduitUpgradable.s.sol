// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {LiquidAccountConduitFactory} from "../../contracts/conduits/LiquidAccountConduitFactory.sol";
import {LiquidAccountConduitUpgradeable} from "../../contracts/conduits/LiquidAccountConduitUpgradeable.sol";
import {IHydrexVotingEscrow} from "../../contracts/interfaces/IHydrexVotingEscrow.sol";

/**
 * @title DeployLiquidAccountConduitUpgradable
 * @dev Deployment script for LiquidAccountConduitUpgradeable
 */
contract DeployLiquidAccountConduitUpgradable is Script {
    function run() public {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(deployerKey);
        string memory networkName = vm.envOr("NETWORK", string("base"));

        address admin = vm.envAddress("ADMIN");
        address voter = vm.envAddress("VOTER");
        address veToken = vm.envAddress("VE_TOKEN");
        address optionsToken = vm.envAddress("OPTIONS_TOKEN");

        console2.log("=== LiquidAccountConduit Deployment ===");
        console2.log("Network:", networkName);
        console2.log("Deployer:", deployer);
        console2.log("Admin:", admin);
        console2.log("Voter:", voter);
        console2.log("veToken:", veToken);
        console2.log("optionsToken:", optionsToken);
        console2.log("\n=== Starting Deployment ===");

        vm.startBroadcast(deployerKey);

        // Deploy factory
        LiquidAccountConduitFactory factory = new LiquidAccountConduitFactory(admin, voter, optionsToken, veToken);

        // Deploy conduit proxy through factory
        address conduitAddress = factory.deployConduit(admin);
        LiquidAccountConduitUpgradeable conduit = LiquidAccountConduitUpgradeable(payable(conduitAddress));

        // Post deployment
        // Set conduit approval config
        // Enable conduit approval for the user's veNFT to allow merging
        // Enable standard ERC721 operator approval for the conduit

        vm.stopBroadcast();

        console2.log("\n=== Deployment Successful ===");
        console2.log("LiquidAccountConduitFactory deployed at:", address(factory));
        console2.log("LiquidAccountConduit proxy deployed at:", address(conduit));
        console2.log("Implementation address:", factory.getImplementation());
        console2.log("Admin address:", admin);
        console2.log("Voter address:", voter);
        console2.log("veToken address:", veToken);
        console2.log("optionsToken address:", optionsToken);

        _saveDeployment(
            networkName,
            address(factory),
            address(conduit),
            factory.getImplementation(),
            admin,
            voter,
            veToken,
            optionsToken
        );
    }

    function _saveDeployment(
        string memory networkName,
        address factoryAddress,
        address proxyAddress,
        address implementationAddress,
        address admin,
        address voter,
        address veToken,
        address optionsToken
    ) internal {
        string memory deploymentPath = string.concat(
            "deployments/",
            networkName,
            "-liquid-account-conduit-",
            _toHexString(proxyAddress),
            ".json"
        );

        string memory json = "deployment";
        vm.serializeString(json, "network", networkName);
        vm.serializeUint(json, "timestamp", block.timestamp);
        vm.serializeUint(json, "blockNumber", block.number);

        string memory contractsJson = "contracts";

        // Factory entry
        string memory factoryJson = "LiquidAccountConduitFactory";
        vm.serializeAddress(factoryJson, "address", factoryAddress);
        string memory factoryData = vm.serializeString(factoryJson, "name", "LiquidAccountConduitFactory");

        // Implementation entry
        string memory implJson = "LiquidAccountConduitImplementation";
        vm.serializeAddress(implJson, "address", implementationAddress);
        string memory implData = vm.serializeString(implJson, "name", "LiquidAccountConduitUpgradeable");

        // Proxy entry
        string memory proxyJson = "LiquidAccountConduitUpgradeableProxy";
        vm.serializeAddress(proxyJson, "address", proxyAddress);
        vm.serializeAddress(proxyJson, "implementation", implementationAddress);
        vm.serializeAddress(proxyJson, "admin", admin);
        vm.serializeAddress(proxyJson, "voter", voter);
        vm.serializeAddress(proxyJson, "veToken", veToken);
        vm.serializeAddress(proxyJson, "optionsToken", optionsToken);
        string memory proxyData = vm.serializeString(proxyJson, "name", "LiquidAccountConduitUpgradeable");

        vm.serializeString(contractsJson, "factory", factoryData);
        vm.serializeString(contractsJson, "implementation", implData);
        string memory contractData = vm.serializeString(contractsJson, "proxy", proxyData);
        string memory finalJson = vm.serializeString(json, "contracts", contractData);

        vm.writeFile(deploymentPath, finalJson);
        console2.log("Deployment saved to:", deploymentPath);
    }

    function _toHexString(address account) internal pure returns (string memory) {
        bytes20 data = bytes20(account);
        bytes16 hexSymbols = 0x30313233343536373839616263646566; // 0-9a-f
        bytes memory str = new bytes(42);
        str[0] = "0";
        str[1] = "x";
        for (uint256 i = 0; i < 20; i++) {
            uint8 b = uint8(data[i]);
            str[2 + i * 2] = bytes1(hexSymbols[b >> 4]);
            str[3 + i * 2] = bytes1(hexSymbols[b & 0x0f]);
        }
        return string(str);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {VeConduitFactory} from "../../contracts/conduits/VeConduitFactory.sol";

/**
 * @title DeployVeConduitFactory
 * @dev Script to deploy VeConduitFactory and seed global settings
 */
contract DeployVeConduitFactory is Script {
    function run() public {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(deployerKey);

        string memory networkName = vm.envOr("NETWORK", string("base"));
        address admin = vm.envAddress("ADMIN");
        address voter = vm.envAddress("VOTER");
        address veToken = vm.envAddress("VE_TOKEN");
        address treasury = vm.envAddress("TREASURY");

        address[] memory routers = new address[](1);
        routers[0] = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5; // KyberSwap Router (Base)

        console2.log("=== VeConduitFactory Deployment ===");
        console2.log("Network:", networkName);
        console2.log("Deployer:", deployer);
        console2.log("Admin:", admin);
        console2.log("Voter:", voter);
        console2.log("VeToken:", veToken);
        console2.log("Treasury:", treasury);
        console2.log("\n=== Starting Deployment ===");

        vm.startBroadcast(deployerKey);

        VeConduitFactory factory = new VeConduitFactory(voter, veToken, admin, treasury);
        for (uint256 i = 0; i < routers.length; i++) {
            factory.addApprovedRouter(routers[i]);
        }

        vm.stopBroadcast();

        console2.log("\n=== Deployment Successful ===");
        console2.log("VeConduitFactory deployed at:", address(factory));
        console2.log("Admin address:", admin);
        console2.log("Voter address:", voter);
        console2.log("VeToken address:", veToken);
        console2.log("Treasury address:", treasury);
        console2.log("Routers seeded:", routers.length);

        _saveDeployment(networkName, address(factory), admin, treasury);
    }

    function _saveDeployment(
        string memory networkName,
        address factoryAddress,
        address admin,
        address treasury
    ) internal {
        string memory deploymentPath = string.concat(
            "deployments/",
            networkName,
            "-",
            _toHexString(factoryAddress),
            ".json"
        );

        string memory json = "deployment";
        vm.serializeString(json, "network", networkName);
        vm.serializeUint(json, "timestamp", block.timestamp);
        vm.serializeUint(json, "blockNumber", block.number);

        string memory contractJson = "contracts";
        string memory factoryJson = "VeConduitFactory";
        vm.serializeAddress(factoryJson, "address", factoryAddress);
        vm.serializeAddress(factoryJson, "admin", admin);
        vm.serializeAddress(factoryJson, "treasury", treasury);
        string memory factoryData = vm.serializeString(factoryJson, "name", "VeConduitFactory");

        string memory contractData = vm.serializeString(contractJson, "VeConduitFactory", factoryData);
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



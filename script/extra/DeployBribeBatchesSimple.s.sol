// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {BribeBatchesSimple} from "../../contracts/extra/BribeBatchesSimple.sol";

/**
 * @title DeployBribeBatchesSimple
 * @dev Script to deploy BribeBatchesSimple contract
 */
contract DeployBribeBatchesSimple is Script {
    function run() public {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(deployerKey);

        string memory networkName = vm.envOr("NETWORK", string("base"));

        console2.log("=== BribeBatchesSimple Deployment ===");
        console2.log("Network:", networkName);
        console2.log("Deployer:", deployer);
        console2.log("\n=== Starting Deployment ===");

        vm.startBroadcast(deployerKey);

        // Deploy BribeBatchesSimple contract
        BribeBatchesSimple bribeBatches = new BribeBatchesSimple();

        vm.stopBroadcast();

        console2.log("\n=== Deployment Successful ===");
        console2.log("BribeBatchesSimple deployed at:", address(bribeBatches));
        console2.log("Admin (DEFAULT_ADMIN_ROLE):", deployer);
        console2.log("Operator (OPERATOR_ROLE):", deployer);
        console2.log("Epoch Start:", bribeBatches.EPOCH_START());
        console2.log("Epoch Duration:", bribeBatches.EPOCH_DURATION());

        _saveDeployment(networkName, address(bribeBatches), deployer);
    }

    function _saveDeployment(string memory networkName, address bribeBatchesAddress, address deployer) internal {
        // Create a unique file per deployment
        string memory deploymentPath = string.concat(
            "deployments/",
            networkName,
            "-",
            _toHexString(bribeBatchesAddress),
            ".json"
        );

        // Create deployment JSON
        string memory json = "deployment";
        vm.serializeString(json, "network", networkName);
        vm.serializeUint(json, "timestamp", block.timestamp);
        vm.serializeUint(json, "blockNumber", block.number);

        // Contract information
        string memory contractJson = "contracts";
        string memory bribeBatchesJson = "BribeBatchesSimple";
        vm.serializeAddress(bribeBatchesJson, "address", bribeBatchesAddress);
        vm.serializeAddress(bribeBatchesJson, "deployer", deployer);
        vm.serializeUint(bribeBatchesJson, "epochStart", 1757548800);
        vm.serializeUint(bribeBatchesJson, "epochDuration", 14400); // 4 hours
        string memory bribeBatchesData = vm.serializeString(bribeBatchesJson, "name", "BribeBatchesSimple");

        string memory contractData = vm.serializeString(contractJson, "BribeBatchesSimple", bribeBatchesData);
        string memory finalJson = vm.serializeString(json, "contracts", contractData);

        // Write to file
        vm.writeFile(deploymentPath, finalJson);
        console2.log("\nDeployment saved to:", deploymentPath);
    }

    // Helper: convert address to 0x-prefixed hex string
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


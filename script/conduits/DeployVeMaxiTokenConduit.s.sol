// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {VeMaxiTokenConduit} from "../../contracts/conduits/VeMaxiTokenConduit.sol";

/**
 * @title DeployVeMaxiTokenConduit
 * @dev Script to deploy VeMaxiTokenConduit contract
 */
contract DeployVeMaxiTokenConduit is Script {
    function run() public {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(deployerKey);

        string memory networkName = vm.envOr("NETWORK", string("base"));
        address admin = vm.envAddress("ADMIN");
        address voter = vm.envAddress("VOTER");
        address veToken = vm.envAddress("VE_TOKEN");
        address hydxToken = vm.envAddress("HYDX_TOKEN");
        address optionsToken = vm.envAddress("OPTIONS_TOKEN");

        console2.log("=== VeMaxiTokenConduit Deployment ===");
        console2.log("Network:", networkName);
        console2.log("Deployer:", deployer);
        console2.log("Admin:", admin);
        console2.log("Voter:", voter);
        console2.log("VeToken:", veToken);
        console2.log("HYDX Token:", hydxToken);
        console2.log("Options Token:", optionsToken);
        console2.log("\n=== Starting Deployment ===");

        vm.startBroadcast(deployerKey);

        // Deploy VeMaxiTokenConduit contract
        VeMaxiTokenConduit veMaxiConduit = new VeMaxiTokenConduit(admin, voter, veToken, hydxToken, optionsToken);

        vm.stopBroadcast();

        console2.log("\n=== Deployment Successful ===");
        console2.log("VeMaxiTokenConduit deployed at:", address(veMaxiConduit));
        console2.log("Admin address:", admin);
        console2.log("Voter address:", voter);
        console2.log("VeToken address:", veToken);
        console2.log("HYDX Token address:", hydxToken);
        console2.log("Options Token address:", optionsToken);

        _saveDeployment(networkName, address(veMaxiConduit), admin, voter, veToken, hydxToken, optionsToken);
    }

    function _saveDeployment(
        string memory networkName,
        address veMaxiConduitAddress,
        address admin,
        address voter,
        address veToken,
        address hydxToken,
        address optionsToken
    ) internal {
        // Create a unique file per deployment to "add" rather than overwrite
        // e.g. deployments/base-<contractAddress>.json
        string memory deploymentPath = string.concat(
            "deployments/",
            networkName,
            "-",
            _toHexString(veMaxiConduitAddress),
            ".json"
        );

        // Create deployment JSON
        string memory json = "deployment";
        vm.serializeString(json, "network", networkName);
        vm.serializeUint(json, "timestamp", block.timestamp);
        vm.serializeUint(json, "blockNumber", block.number);

        // Contract information
        string memory contractJson = "contracts";
        string memory veMaxiConduitJson = "VeMaxiTokenConduit";
        vm.serializeAddress(veMaxiConduitJson, "address", veMaxiConduitAddress);
        vm.serializeAddress(veMaxiConduitJson, "admin", admin);
        vm.serializeAddress(veMaxiConduitJson, "voter", voter);
        vm.serializeAddress(veMaxiConduitJson, "veToken", veToken);
        vm.serializeAddress(veMaxiConduitJson, "hydxToken", hydxToken);
        vm.serializeAddress(veMaxiConduitJson, "optionsToken", optionsToken);
        string memory veMaxiConduitData = vm.serializeString(veMaxiConduitJson, "name", "VeMaxiTokenConduit");

        string memory contractData = vm.serializeString(contractJson, "VeMaxiTokenConduit", veMaxiConduitData);
        string memory finalJson = vm.serializeString(json, "contracts", contractData);

        // Write to file
        vm.writeFile(deploymentPath, finalJson);
        console2.log("Deployment saved to:", deploymentPath);
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

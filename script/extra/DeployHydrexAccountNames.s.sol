// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {HydrexAccountNames} from "../../contracts/extra/HydrexAccountNames.sol";

/**
 * @title DeployHydrexAccountNames
 * @dev Script to deploy HydrexAccountNames contract
 *
 * Required Environment Variables:
 * - DEPLOYER_KEY: Private key of the deployer
 * - VE_TOKEN: Address of the veNFT contract
 *
 * Optional Environment Variables:
 * - NETWORK: Network name (defaults to "base")
 */
contract DeployHydrexAccountNames is Script {
    function run() public {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(deployerKey);

        string memory networkName = vm.envOr("NETWORK", string("base"));
        address veToken = vm.envAddress("VE_TOKEN");

        console2.log("=== HydrexAccountNames Deployment ===");
        console2.log("Network:", networkName);
        console2.log("Deployer:", deployer);
        console2.log("VeToken:", veToken);
        console2.log("\n=== Starting Deployment ===");

        vm.startBroadcast(deployerKey);

        // Deploy HydrexAccountNames contract
        HydrexAccountNames accountNames = new HydrexAccountNames(veToken);

        vm.stopBroadcast();

        console2.log("\n=== Deployment Successful ===");
        console2.log("HydrexAccountNames deployed at:", address(accountNames));
        console2.log("VeToken address:", accountNames.veToken());
        console2.log("Max name length:", accountNames.MAX_NAME_LENGTH());

        _saveDeployment(networkName, address(accountNames), veToken);
    }

    function _saveDeployment(string memory networkName, address accountNamesAddress, address veToken) internal {
        // Create a unique file per deployment
        string memory deploymentPath = string.concat(
            "deployments/",
            networkName,
            "-",
            _toHexString(accountNamesAddress),
            ".json"
        );

        // Create deployment JSON
        string memory json = "deployment";
        vm.serializeString(json, "network", networkName);
        vm.serializeUint(json, "timestamp", block.timestamp);
        vm.serializeUint(json, "blockNumber", block.number);

        // Contract information
        string memory contractJson = "contracts";
        string memory accountNamesJson = "HydrexAccountNames";
        vm.serializeAddress(accountNamesJson, "address", accountNamesAddress);
        vm.serializeAddress(accountNamesJson, "veToken", veToken);
        vm.serializeUint(accountNamesJson, "maxNameLength", 24);
        string memory accountNamesData = vm.serializeString(accountNamesJson, "name", "HydrexAccountNames");

        string memory contractData = vm.serializeString(contractJson, "HydrexAccountNames", accountNamesData);
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

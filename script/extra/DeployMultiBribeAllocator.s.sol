// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {MultiBribeAllocator} from "../../contracts/extra/MultiBribeAllocator.sol";

/**
 * @title DeployMultiBribeAllocator
 * @dev Script to deploy MultiBribeAllocator contract
 *
 * Required Environment Variables:
 * - DEPLOYER_KEY: Private key of the deployer
 *
 * Optional Environment Variables:
 * - NETWORK: Network name (defaults to "base")
 */
contract DeployMultiBribeAllocator is Script {
    function run() public {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(deployerKey);

        string memory networkName = vm.envOr("NETWORK", string("base"));

        console2.log("=== MultiBribeAllocator Deployment ===");
        console2.log("Network:", networkName);
        console2.log("Deployer:", deployer);
        console2.log("\n=== Starting Deployment ===");

        vm.startBroadcast(deployerKey);

        // Deploy MultiBribeAllocator contract
        MultiBribeAllocator bribeAllocator = new MultiBribeAllocator();

        vm.stopBroadcast();

        console2.log("\n=== Deployment Successful ===");
        console2.log("MultiBribeAllocator deployed at:", address(bribeAllocator));

        _saveDeployment(networkName, address(bribeAllocator));
    }

    function _saveDeployment(string memory networkName, address bribeAllocatorAddress) internal {
        // Create a unique file per deployment
        string memory deploymentPath = string.concat(
            "deployments/",
            networkName,
            "-",
            _toHexString(bribeAllocatorAddress),
            ".json"
        );

        // Create deployment JSON
        string memory json = "deployment";
        vm.serializeString(json, "network", networkName);
        vm.serializeUint(json, "timestamp", block.timestamp);
        vm.serializeUint(json, "blockNumber", block.number);

        // Contract information
        string memory contractJson = "contracts";
        string memory bribeAllocatorJson = "MultiBribeAllocator";
        vm.serializeAddress(bribeAllocatorJson, "address", bribeAllocatorAddress);
        string memory bribeAllocatorData = vm.serializeString(bribeAllocatorJson, "name", "MultiBribeAllocator");

        string memory contractData = vm.serializeString(contractJson, "MultiBribeAllocator", bribeAllocatorData);
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

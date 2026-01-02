// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {FlexAccountClaims} from "../../contracts/extra/FlexAccountClaims.sol";

/**
 * @title DeployFlexAccountClaims
 * @dev Script to deploy FlexAccountClaims contract
 */
contract DeployFlexAccountClaims is Script {
    function run() public {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(deployerKey);

        string memory networkName = vm.envOr("NETWORK", string("base"));

        console2.log("=== FlexAccountClaims Deployment ===");
        console2.log("Network:", networkName);
        console2.log("Deployer:", deployer);
        console2.log("\n=== Starting Deployment ===");

        vm.startBroadcast(deployerKey);

        // Deploy FlexAccountClaims contract
        FlexAccountClaims flexClaims = new FlexAccountClaims();

        vm.stopBroadcast();

        console2.log("\n=== Deployment Successful ===");
        console2.log("FlexAccountClaims deployed at:", address(flexClaims));
        console2.log("Admin (DEFAULT_ADMIN_ROLE):", deployer);
        console2.log("veNFT Address:", flexClaims.VENFT());
        console2.log("oHYDX Address:", flexClaims.OHYDX());

        _saveDeployment(networkName, address(flexClaims), deployer);
    }

    function _saveDeployment(string memory networkName, address flexClaimsAddress, address deployer) internal {
        // Create a unique file per deployment
        string memory deploymentPath = string.concat(
            "deployments/",
            networkName,
            "-",
            _toHexString(flexClaimsAddress),
            ".json"
        );

        // Create deployment JSON
        string memory json = "deployment";
        vm.serializeString(json, "network", networkName);
        vm.serializeUint(json, "timestamp", block.timestamp);
        vm.serializeUint(json, "blockNumber", block.number);

        // Contract information
        string memory contractJson = "contracts";
        string memory flexClaimsJson = "FlexAccountClaims";
        vm.serializeAddress(flexClaimsJson, "address", flexClaimsAddress);
        vm.serializeAddress(flexClaimsJson, "deployer", deployer);
        vm.serializeAddress(flexClaimsJson, "venft", 0x9ee81fD729b91095563fE6dA11c1fE92C52F9728);
        vm.serializeAddress(flexClaimsJson, "ohydx", 0xA1136031150E50B015b41f1ca6B2e99e49D8cB78);
        string memory flexClaimsData = vm.serializeString(flexClaimsJson, "name", "FlexAccountClaims");

        string memory contractData = vm.serializeString(contractJson, "FlexAccountClaims", flexClaimsData);
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

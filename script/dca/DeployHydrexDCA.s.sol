// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {HydrexDCA} from "../../contracts/dca/HydrexDCA.sol";

/**
 * @title DeployHydrexDCA
 * @dev Script to deploy HydrexDCA contract
 */
contract DeployHydrexDCA is Script {
    function run() public {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(deployerKey);

        string memory networkName = vm.envOr("NETWORK", string("base"));
        address admin = vm.envAddress("ADMIN");

        address[] memory routers = new address[](1);
        routers[0] = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5; // KyberSwap Router (Base)

        console2.log("=== HydrexDCA Deployment ===");
        console2.log("Network:", networkName);
        console2.log("Deployer:", deployer);
        console2.log("Admin:", admin);
        console2.log("Operator:", admin);
        console2.log("\n=== Starting Deployment ===");

        vm.startBroadcast(deployerKey);

        HydrexDCA dca = new HydrexDCA(admin, admin);
        dca.whitelistRouters(routers);

        vm.stopBroadcast();

        console2.log("\n=== Deployment Successful ===");
        console2.log("HydrexDCA deployed at:", address(dca));
        console2.log("Admin address:", admin);
        console2.log("Operator address:", admin);
        console2.log("Minimum interval:", dca.minimumInterval(), "seconds");
        console2.log("Routers whitelisted:", routers.length);
        console2.log("  - KyberSwap:", routers[0]);

        _saveDeployment(networkName, address(dca), admin, admin);
    }

    function _saveDeployment(string memory networkName, address dcaAddress, address admin, address operator) internal {
        string memory deploymentPath = string.concat(
            "deployments/",
            networkName,
            "-",
            _toHexString(dcaAddress),
            ".json"
        );

        string memory json = "deployment";
        vm.serializeString(json, "network", networkName);
        vm.serializeUint(json, "timestamp", block.timestamp);
        vm.serializeUint(json, "blockNumber", block.number);

        string memory contractJson = "contracts";
        string memory dcaJson = "HydrexDCA";
        vm.serializeAddress(dcaJson, "address", dcaAddress);
        vm.serializeAddress(dcaJson, "admin", admin);
        vm.serializeAddress(dcaJson, "operator", operator);
        string memory dcaData = vm.serializeString(dcaJson, "name", "HydrexDCA");

        string memory contractData = vm.serializeString(contractJson, "HydrexDCA", dcaData);
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

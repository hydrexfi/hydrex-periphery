// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {VeMaxiTokenConduit} from "../../contracts/conduits/VeMaxiTokenConduit.sol";
import {VeMaxiTokenConduitProxy} from "../../contracts/conduits/VeMaxiTokenConduitProxy.sol";

/**
 * @title DeployVeMaxiTokenConduit
 * @dev Script to deploy VeMaxiTokenConduit contract with transparent proxy
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

        console2.log("=== VeMaxiTokenConduit Deployment (Upgradeable) ===");
        console2.log("Network:", networkName);
        console2.log("Deployer:", deployer);
        console2.log("Admin:", admin);
        console2.log("Voter:", voter);
        console2.log("veToken:", veToken);
        console2.log("HYDX Token:", hydxToken);
        console2.log("Options Token:", optionsToken);
        console2.log("\n=== Starting Deployment ===");

        vm.startBroadcast(deployerKey);

        // Deploy implementation
        VeMaxiTokenConduit implementation = new VeMaxiTokenConduit();
        console2.log("Implementation deployed at:", address(implementation));

        // Prepare initialization data
        bytes memory initData =
            abi.encodeWithSelector(VeMaxiTokenConduit.initialize.selector, deployer, voter, veToken, hydxToken, optionsToken);

        // Deploy proxy
        VeMaxiTokenConduitProxy proxy = new VeMaxiTokenConduitProxy(address(implementation), admin, initData);
        console2.log("Proxy deployed at:", address(proxy));

        // Get proxied instance
        VeMaxiTokenConduit conduit = VeMaxiTokenConduit(payable(address(proxy)));

        vm.stopBroadcast();

        console2.log("\n=== Deployment Successful ===");
        console2.log("Proxy Address:", address(proxy));
        console2.log("Implementation Address:", address(implementation));
        console2.log("Admin address:", admin);
        console2.log("Executor address:", deployer);
        console2.log("Voter:", conduit.voter());
        console2.log("veToken:", conduit.veToken());
        console2.log("HYDX Token:", conduit.hydxToken());
        console2.log("Options Token:", conduit.optionsToken());

        _saveDeployment(networkName, address(proxy), address(implementation), admin, deployer);
    }

    function _saveDeployment(
        string memory networkName,
        address proxyAddress,
        address implementationAddress,
        address admin,
        address executor
    ) internal {
        string memory deploymentPath =
            string.concat("deployments/", networkName, "-", _toHexString(proxyAddress), ".json");

        string memory json = "deployment";
        vm.serializeString(json, "network", networkName);
        vm.serializeUint(json, "timestamp", block.timestamp);
        vm.serializeUint(json, "blockNumber", block.number);

        string memory contractJson = "contracts";
        string memory conduitJson = "VeMaxiTokenConduit";
        vm.serializeAddress(conduitJson, "proxy", proxyAddress);
        vm.serializeAddress(conduitJson, "implementation", implementationAddress);
        vm.serializeAddress(conduitJson, "admin", admin);
        vm.serializeAddress(conduitJson, "executor", executor);
        string memory conduitData = vm.serializeString(conduitJson, "name", "VeMaxiTokenConduit");

        string memory contractData = vm.serializeString(contractJson, "VeMaxiTokenConduit", conduitData);
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

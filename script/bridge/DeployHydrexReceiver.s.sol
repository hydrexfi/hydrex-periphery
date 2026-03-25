// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {HydrexReceiver} from "../../contracts/bridge/HydrexReceiver.sol";

/**
 * @title DeployHydrexReceiver
 * @dev Deploys HydrexReceiver on Base mainnet for bridge integration testing.
 *
 * Required env vars:
 *   DEPLOYER_KEY       — private key of the deployer
 *
 * Optional env vars:
 *   NETWORK            — label for the deployment JSON (default: "base")
 *   BRIDGE             — Base-Solana bridge contract (default: 0x3eff766C76a1be2Ce1aCF2B69c78bCae257D5188)
 */
contract DeployHydrexReceiver is Script {
    // Base-Solana Bridge on Base mainnet
    address constant DEFAULT_BRIDGE = 0x3eff766C76a1be2Ce1aCF2B69c78bCae257D5188;

    function run() public {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(deployerKey);

        string memory networkName = vm.envOr("NETWORK", string("base"));
        address bridge = vm.envOr("BRIDGE", DEFAULT_BRIDGE);

        console2.log("=== HydrexReceiver Deployment ===");
        console2.log("Network: ", networkName);
        console2.log("Deployer:", deployer);
        console2.log("Bridge:  ", bridge);
        console2.log("\n=== Starting Deployment ===");

        vm.startBroadcast(deployerKey);

        HydrexReceiver receiver = new HydrexReceiver(bridge);

        vm.stopBroadcast();

        console2.log("\n=== Deployment Successful ===");
        console2.log("HydrexReceiver:", address(receiver));
        console2.log("Owner:         ", receiver.owner());
        console2.log("Bridge:        ", receiver.bridge());

        _saveDeployment(networkName, address(receiver), deployer, bridge);
    }

    function _saveDeployment(
        string memory networkName,
        address receiverAddress,
        address deployer,
        address bridge
    ) internal {
        string memory deploymentPath = string.concat(
            "deployments/",
            networkName,
            "-HydrexReceiver-",
            _toHexString(receiverAddress),
            ".json"
        );

        string memory json = "deployment";
        vm.serializeString(json, "network", networkName);
        vm.serializeUint(json, "timestamp", block.timestamp);
        vm.serializeUint(json, "blockNumber", block.number);

        string memory contractJson = "HydrexReceiver";
        vm.serializeAddress(contractJson, "address", receiverAddress);
        vm.serializeAddress(contractJson, "deployer", deployer);
        string memory contractData = vm.serializeAddress(contractJson, "bridge", bridge);

        string memory finalJson = vm.serializeString(json, "HydrexReceiver", contractData);
        vm.writeFile(deploymentPath, finalJson);
        console2.log("Deployment saved to:", deploymentPath);
    }

    function _toHexString(address account) internal pure returns (string memory) {
        bytes20 data = bytes20(account);
        bytes16 hexSymbols = 0x30313233343536373839616263646566;
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

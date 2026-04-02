// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {RewardClaims} from "../../contracts/extra/RewardClaims.sol";

contract DeployRewardClaims is Script {
    function run() public {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(deployerKey);
        string memory networkName = vm.envOr("NETWORK", string("base"));

        console2.log("=== RewardClaims Deployment ===");
        console2.log("Network:", networkName);
        console2.log("Deployer:", deployer);

        vm.startBroadcast(deployerKey);
        RewardClaims rewardClaims = new RewardClaims();
        vm.stopBroadcast();

        console2.log("\n=== Deployment Successful ===");
        console2.log("RewardClaims deployed at:", address(rewardClaims));
        console2.log("Admin (DEFAULT_ADMIN_ROLE):", deployer);

        _saveDeployment(networkName, address(rewardClaims), deployer);
    }

    function _saveDeployment(string memory networkName, address contractAddress, address deployer) internal {
        string memory deploymentPath = string.concat(
            "deployments/",
            networkName,
            "-reward-claims-",
            _toHexString(contractAddress),
            ".json"
        );

        string memory json = "deployment";
        vm.serializeString(json, "network", networkName);
        vm.serializeUint(json, "timestamp", block.timestamp);
        vm.serializeUint(json, "blockNumber", block.number);

        string memory contractJson = "RewardClaims";
        vm.serializeAddress(contractJson, "address", contractAddress);
        string memory contractData = vm.serializeAddress(contractJson, "deployer", deployer);
        string memory finalJson = vm.serializeString(json, "contracts", contractData);

        vm.writeFile(deploymentPath, finalJson);
        console2.log("\nDeployment saved to:", deploymentPath);
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

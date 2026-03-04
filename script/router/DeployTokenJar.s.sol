// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {TokenJar} from "../../contracts/router/TokenJar.sol";

/**
 * @title DeployTokenJar
 * @dev Deploys TokenJar on Base mainnet.
 *
 * Required env vars:
 *   DEPLOYER_KEY       — private key of the deployer
 *   FEE_RECIPIENT      — address that receives forwarded tokens
 *
 * Optional env vars (fall back to sensible defaults):
 *   NETWORK            — label for the deployment JSON (default: "base")
 *   OWNER              — contract owner (default: deployer)
 *   MULTI_ROUTER       — HydrexMultiRouter proxy (default: Base mainnet deployment)
 *   DEX_ROUTER         — whitelisted DEX router (default: KyberSwap on Base)
 */
contract DeployTokenJar is Script {
    // HydrexMultiRouter proxy on Base mainnet
    address constant DEFAULT_MULTI_ROUTER = 0x23823b8B3b7B5E9FE831DFD65Ed9Ea95dA51Dc1b;

    function run() public {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(deployerKey);

        string memory networkName = vm.envOr("NETWORK", string("base"));
        address owner = vm.envOr("ADMIN", deployer);
        address multiRouter = vm.envOr("MULTI_ROUTER", DEFAULT_MULTI_ROUTER);
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");

        console2.log("=== TokenJar Deployment ===");
        console2.log("Network:          ", networkName);
        console2.log("Deployer:         ", deployer);
        console2.log("Owner:            ", owner);
        console2.log("HydrexMultiRouter:", multiRouter);
        console2.log("Fee Recipient: ", feeRecipient);
        console2.log("\n=== Starting Deployment ===");

        vm.startBroadcast(deployerKey);

        TokenJar jar = new TokenJar(owner, multiRouter, feeRecipient);

        vm.stopBroadcast();

        console2.log("\n=== Deployment Successful ===");
        console2.log("TokenJar:         ", address(jar));
        console2.log("Owner:            ", jar.owner());
        console2.log("HydrexMultiRouter:", address(jar.router()));
        console2.log("Fee Recipient: ", jar.feeRecipient());

        _saveDeployment(networkName, address(jar), owner, multiRouter, feeRecipient);
    }

    function _saveDeployment(
        string memory networkName,
        address jarAddress,
        address owner,
        address multiRouter,
        address feeRecipient
    ) internal {
        string memory deploymentPath = string.concat(
            "deployments/",
            networkName,
            "-TokenJar-",
            _toHexString(jarAddress),
            ".json"
        );

        string memory json = "deployment";
        vm.serializeString(json, "network", networkName);
        vm.serializeUint(json, "timestamp", block.timestamp);
        vm.serializeUint(json, "blockNumber", block.number);

        string memory contractJson = "TokenJar";
        vm.serializeAddress(contractJson, "address", jarAddress);
        vm.serializeAddress(contractJson, "owner", owner);
        vm.serializeAddress(contractJson, "multiRouter", multiRouter);
        string memory contractData = vm.serializeAddress(contractJson, "feeRecipient", feeRecipient);

        string memory finalJson = vm.serializeString(json, "TokenJar", contractData);
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

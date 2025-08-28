// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {VeTokenConduit} from "../../contracts/conduits/VeTokenConduit.sol";

/**
 * @title DeployVeTokenConduit
 * @dev Script to deploy VeTokenConduit contract
 */
contract DeployVeTokenConduit is Script {
    function run() public {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(deployerKey);

        string memory networkName = vm.envOr("NETWORK", string("base"));
        address admin = vm.envAddress("ADMIN");
        address treasury = vm.envAddress("TREASURY");
        address voter = vm.envAddress("VOTER");
        address veToken = vm.envAddress("VE_TOKEN");

        address[] memory approvedOutputTokens = new address[](7);
        approvedOutputTokens[0] = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // USDC
        approvedOutputTokens[1] = 0x4200000000000000000000000000000000000006; // WETH
        approvedOutputTokens[2] = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf; // cbBTC
        approvedOutputTokens[3] = 0xcbD06E5A2B0C65597161de254AA074E489dEb510; // cbDOGE
        approvedOutputTokens[4] = 0xAC1Bd2486aAf3B5C0fc3Fd868558b082a531B2B4; // TOSHI
        approvedOutputTokens[5] = 0x532f27101965dd16442E59d40670FaF5eBB142E4; // BRETT
        approvedOutputTokens[6] = 0x1111111111166b7FE7bd91427724B487980aFc69; // ZORA

        address[] memory approvedRouters = new address[](1);
        approvedRouters[0] = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5; // KyberSwap Router

        console2.log("=== VeTokenConduit Deployment ===");
        console2.log("Network:", networkName);
        console2.log("Deployer:", deployer);
        console2.log("Admin:", admin);
        console2.log("Treasury:", treasury);
        console2.log("Treasury Fee:", "1% (100 BPS)");
        console2.log("\n=== Starting Deployment ===");

        vm.startBroadcast(deployerKey);

        // Deploy VeTokenConduit contract
        VeTokenConduit veTokenConduit = new VeTokenConduit(
            admin,
            treasury,
            voter,
            veToken,
            approvedOutputTokens,
            approvedRouters
        );

        vm.stopBroadcast();

        console2.log("\n=== Deployment Successful ===");
        console2.log("VeTokenConduit deployed at:", address(veTokenConduit));
        console2.log("Admin address:", admin);
        console2.log("Treasury address:", treasury);
        console2.log("Voter address:", voter);
        console2.log("VeToken address:", veToken);
        console2.log("Number of approved output tokens:", approvedOutputTokens.length);
        console2.log("First approved output token (USDC):", veTokenConduit.approvedOutputTokens(0));
        console2.log("Number of approved routers:", approvedRouters.length);
        console2.log("First approved router (KyberSwap):", veTokenConduit.approvedRouters(0));

        _saveDeployment(networkName, address(veTokenConduit), admin, treasury);
    }

    function _saveDeployment(
        string memory networkName,
        address VeTokenConduitAddress,
        address admin,
        address treasury
    ) internal {
        // Create a unique file per deployment to "add" rather than overwrite
        // e.g. deployments/base-<contractAddress>.json
        string memory deploymentPath = string.concat(
            "deployments/",
            networkName,
            "-",
            _toHexString(VeTokenConduitAddress),
            ".json"
        );

        // Create deployment JSON
        string memory json = "deployment";
        vm.serializeString(json, "network", networkName);
        vm.serializeUint(json, "timestamp", block.timestamp);
        vm.serializeUint(json, "blockNumber", block.number);

        // Contract information
        string memory contractJson = "contracts";
        string memory VeTokenConduitJson = "VeTokenConduit";
        vm.serializeAddress(VeTokenConduitJson, "address", VeTokenConduitAddress);
        vm.serializeAddress(VeTokenConduitJson, "admin", admin);
        vm.serializeAddress(VeTokenConduitJson, "treasury", treasury);
        vm.serializeUint(VeTokenConduitJson, "treasuryFeeBps", 100);
        string memory VeTokenConduitData = vm.serializeString(VeTokenConduitJson, "name", "VeTokenConduit");

        string memory contractData = vm.serializeString(contractJson, "VeTokenConduit", VeTokenConduitData);
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

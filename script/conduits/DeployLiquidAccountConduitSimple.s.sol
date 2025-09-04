// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {LiquidAccountConduitSimple} from "../../contracts/conduits/LiquidAccountConduitSimple.sol";
import {IHydrexVotingEscrow} from "../../contracts/interfaces/IHydrexVotingEscrow.sol";

/**
 * @title DeployLiquidAccountConduitSimple
 * @dev Deployment script for LiquidAccountConduitSimple - simplified version that only handles options tokens
 */
contract DeployLiquidAccountConduitSimple is Script {
    function run() public {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(deployerKey);
        string memory networkName = vm.envOr("NETWORK", string("base"));

        address admin = vm.envAddress("ADMIN");
        address voter = vm.envAddress("VOTER");
        address veToken = vm.envAddress("VE_TOKEN");
        address optionsToken = vm.envAddress("OPTIONS_TOKEN");

        console2.log("=== LiquidAccountConduitSimple Deployment ===");
        console2.log("Network:", networkName);
        console2.log("Deployer:", deployer);
        console2.log("Admin:", admin);
        console2.log("Voter:", voter);
        console2.log("veToken:", veToken);
        console2.log("optionsToken:", optionsToken);
        console2.log("\n=== Starting Deployment ===");

        vm.startBroadcast(deployerKey);

        LiquidAccountConduitSimple conduit = new LiquidAccountConduitSimple(admin, voter, optionsToken, veToken);

        // Post deployment
        // Set conduit approval config
        // Enable conduit approval for the user's veNFT to allow merging
        // Enable standard ERC721 operator approval for the conduit

        vm.stopBroadcast();

        console2.log("\n=== Deployment Successful ===");
        console2.log("LiquidAccountConduitSimple deployed at:", address(conduit));
        console2.log("Admin address:", admin);
        console2.log("Voter address:", voter);
        console2.log("veToken address:", veToken);
        console2.log("optionsToken address:", optionsToken);

        _saveDeployment(networkName, address(conduit), admin, voter, veToken, optionsToken);
    }

    function _saveDeployment(
        string memory networkName,
        address conduitAddress,
        address admin,
        address voter,
        address veToken,
        address optionsToken
    ) internal {
        string memory deploymentPath = string.concat(
            "deployments/",
            networkName,
            "-",
            _toHexString(conduitAddress),
            ".json"
        );

        string memory json = "deployment";
        vm.serializeString(json, "network", networkName);
        vm.serializeUint(json, "timestamp", block.timestamp);
        vm.serializeUint(json, "blockNumber", block.number);

        string memory contractsJson = "contracts";
        string memory entryJson = "LiquidAccountConduitSimple";
        vm.serializeAddress(entryJson, "address", conduitAddress);
        vm.serializeAddress(entryJson, "admin", admin);
        vm.serializeAddress(entryJson, "voter", voter);
        vm.serializeAddress(entryJson, "veToken", veToken);
        vm.serializeAddress(entryJson, "optionsToken", optionsToken);
        string memory entryData = vm.serializeString(entryJson, "name", "LiquidAccountConduitSimple");

        string memory contractData = vm.serializeString(contractsJson, "LiquidAccountConduitSimple", entryData);
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

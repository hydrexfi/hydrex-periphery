// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {LiquidAccountConduitMulti} from "../../contracts/conduits/LiquidAccountConduitMulti.sol";
import {IHydrexVotingEscrow} from "../../contracts/interfaces/IHydrexVotingEscrow.sol";

/**
 * @title DeployLiquidAccountConduitMulti
 * @dev Deployment script for LiquidAccountConduitMulti - generalized version with gauge and arbitrary distributor support
 */
contract DeployLiquidAccountConduitMulti is Script {
    function run() public {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(deployerKey);
        string memory networkName = vm.envOr("NETWORK", string("base"));

        address admin = vm.envAddress("ADMIN");
        address voter = vm.envAddress("VOTER");
        address veToken = vm.envAddress("VE_TOKEN");
        address optionsToken = vm.envAddress("OPTIONS_TOKEN");

        console2.log("=== LiquidAccountConduitMulti Deployment ===");
        console2.log("Network:", networkName);
        console2.log("Deployer:", deployer);
        console2.log("Admin:", admin);
        console2.log("Voter:", voter);
        console2.log("veToken:", veToken);
        console2.log("optionsToken:", optionsToken);
        console2.log("\n=== Starting Deployment ===");

        vm.startBroadcast(deployerKey);

        LiquidAccountConduitMulti conduit = new LiquidAccountConduitMulti(admin, voter, optionsToken, veToken);

        vm.stopBroadcast();

        console2.log("\n=== Deployment Successful ===");
        console2.log("LiquidAccountConduitMulti deployed at:", address(conduit));
        console2.log("Admin address:", admin);
        console2.log("Voter address:", voter);
        console2.log("veToken address:", veToken);
        console2.log("optionsToken address:", optionsToken);
        console2.log("\n=== Next Steps ===");
        console2.log("1. Users must call setApprovalForAll(conduitAddress, true) on veToken");
        console2.log("2. Users must call setConduitApproval(conduitAddress, tokenId, true) on veToken for merging");
        console2.log("3. For each distributor (e.g. Merkl), users must authorize the conduit as operator");
        console2.log("   - For Merkl: toggleOperator(user, conduitAddress)");
        console2.log("\n=== Usage ===");
        console2.log("This contract supports arbitrary distributor calls.");
        console2.log("See contracts/conduits/DISTRIBUTOR_EXAMPLES.md for usage examples.");

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
        string memory entryJson = "LiquidAccountConduitMulti";
        vm.serializeAddress(entryJson, "address", conduitAddress);
        vm.serializeAddress(entryJson, "admin", admin);
        vm.serializeAddress(entryJson, "voter", voter);
        vm.serializeAddress(entryJson, "veToken", veToken);
        vm.serializeAddress(entryJson, "optionsToken", optionsToken);
        string memory entryData = vm.serializeString(entryJson, "name", "LiquidAccountConduitMulti");

        string memory contractData = vm.serializeString(contractsJson, "LiquidAccountConduitMulti", entryData);
        string memory finalJson = vm.serializeString(json, "contracts", contractData);

        vm.writeFile(deploymentPath, finalJson);
        console2.log("\nDeployment saved to:", deploymentPath);
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

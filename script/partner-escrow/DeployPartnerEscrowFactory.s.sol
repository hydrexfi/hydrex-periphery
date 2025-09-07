// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {PartnerEscrowFactory} from "../../contracts/partner-escrow/PartnerEscrowFactory.sol";

/**
 * @title DeployPartnerEscrowFactory
 * @dev Script to deploy PartnerEscrowFactory contract with predefined approved conduits
 */
contract DeployPartnerEscrowFactory is Script {
    /* Configuration */

    /**
     * @notice Get default approved conduit for the network
     * @param networkName Name of the network
     * @return conduit Default conduit address to approve, or address(0) if none
     */
    function _getDefaultApprovedConduit(string memory networkName) internal pure returns (address conduit) {
        if (keccak256(bytes(networkName)) == keccak256(bytes("base"))) {
            conduit = 0xf2d9EaDCb3ec51577a1eAA2A1d37a12EFb9F3276; // TODO: This is a test conduit VeTokenConduit
        } else {
            conduit = address(0); // No default for other networks
        }
    }

    function run() public {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(deployerKey);

        string memory networkName = vm.envOr("NETWORK", string("base"));

        address voter = vm.envAddress("VOTER");
        address veToken = vm.envAddress("VE_TOKEN");

        // Get default approved conduit for this network
        address defaultConduit = _getDefaultApprovedConduit(networkName);

        console2.log("=== PartnerEscrowFactory Deployment ===");
        console2.log("Network:", networkName);
        console2.log("Deployer:", deployer);
        console2.log("Voter:", voter);
        console2.log("veToken:", veToken);
        console2.log("Default conduit:", defaultConduit);

        vm.startBroadcast(deployerKey);

        PartnerEscrowFactory factory = new PartnerEscrowFactory(voter, veToken);

        // Set default approved conduit
        if (defaultConduit != address(0)) {
            factory.setDefaultApprovedConduit(defaultConduit, true);
            console2.log("Default approved conduit set");
        }

        vm.stopBroadcast();

        console2.log("\n=== Deployment Successful ===");
        console2.log("PartnerEscrowFactory deployed at:", address(factory));

        _saveDeployment(networkName, address(factory), defaultConduit);
    }

    function _saveDeployment(string memory networkName, address factoryAddress, address defaultConduit) internal {
        string memory deploymentPath = string.concat(
            "deployments/",
            networkName,
            "-",
            _toHexString(factoryAddress),
            ".json"
        );

        string memory json = "deployment";
        vm.serializeString(json, "network", networkName);
        vm.serializeUint(json, "timestamp", block.timestamp);
        vm.serializeUint(json, "blockNumber", block.number);

        string memory contractsJson = "contracts";
        string memory entryJson = "PartnerEscrowFactory";
        vm.serializeAddress(entryJson, "address", factoryAddress);
        vm.serializeString(entryJson, "name", "PartnerEscrowFactory");
        string memory entryData = vm.serializeAddress(entryJson, "defaultApprovedConduit", defaultConduit);

        string memory contractData = vm.serializeString(contractsJson, "PartnerEscrowFactory", entryData);
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

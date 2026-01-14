// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {HydrexDCA} from "../../contracts/dca/HydrexDCA.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/**
 * @title UpgradeHydrexDCA
 * @dev Script to upgrade HydrexDCA implementation
 */
contract UpgradeHydrexDCA is Script {
    function run() public {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(deployerKey);

        string memory networkName = vm.envOr("NETWORK", string("base"));
        address proxyAddress = vm.envAddress("PROXY_ADDRESS");

        console2.log("=== HydrexDCA Upgrade ===");
        console2.log("Network:", networkName);
        console2.log("Deployer:", deployer);
        console2.log("Proxy Address:", proxyAddress);

        // Get ProxyAdmin address from proxy
        bytes32 adminSlot = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
        bytes32 adminBytes = vm.load(proxyAddress, adminSlot);
        address proxyAdminAddress = address(uint160(uint256(adminBytes)));
        
        console2.log("ProxyAdmin:", proxyAdminAddress);
        console2.log("\n=== Starting Upgrade ===");

        vm.startBroadcast(deployerKey);

        // Deploy new implementation
        HydrexDCA newImplementation = new HydrexDCA();
        console2.log("New Implementation deployed at:", address(newImplementation));

        // Upgrade via ProxyAdmin
        ProxyAdmin proxyAdmin = ProxyAdmin(proxyAdminAddress);
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(proxyAddress),
            address(newImplementation),
            "" // No initialization data
        );

        console2.log("Upgrade successful!");

        vm.stopBroadcast();

        console2.log("\n=== Upgrade Complete ===");
        console2.log("Proxy Address:", proxyAddress);
        console2.log("New Implementation:", address(newImplementation));

        _saveUpgrade(networkName, proxyAddress, address(newImplementation));
    }

    function _saveUpgrade(
        string memory networkName,
        address proxyAddress,
        address newImplementationAddress
    ) internal {
        string memory upgradePath = string.concat(
            "deployments/",
            networkName,
            "-",
            _toHexString(proxyAddress),
            "-upgrade-",
            vm.toString(block.timestamp),
            ".json"
        );

        string memory json = "upgrade";
        vm.serializeString(json, "network", networkName);
        vm.serializeUint(json, "timestamp", block.timestamp);
        vm.serializeUint(json, "blockNumber", block.number);
        vm.serializeAddress(json, "proxy", proxyAddress);
        string memory finalJson = vm.serializeAddress(json, "newImplementation", newImplementationAddress);

        vm.writeFile(upgradePath, finalJson);
        console2.log("Upgrade saved to:", upgradePath);
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

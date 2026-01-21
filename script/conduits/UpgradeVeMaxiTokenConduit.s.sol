// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {VeMaxiTokenConduit} from "../../contracts/conduits/VeMaxiTokenConduit.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/**
 * @title UpgradeVeMaxiTokenConduit
 * @dev Script to upgrade VeMaxiTokenConduit implementation
 */
contract UpgradeVeMaxiTokenConduit is Script {
    function run() public {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(deployerKey);

        string memory networkName = vm.envOr("NETWORK", string("base"));
        address proxyAddress = vm.envAddress("PROXY_ADDRESS");
        address proxyAdminAddress = vm.envAddress("PROXY_ADMIN");

        console2.log("=== VeMaxiTokenConduit Upgrade ===");
        console2.log("Network:", networkName);
        console2.log("Deployer:", deployer);
        console2.log("Proxy Address:", proxyAddress);
        console2.log("Proxy Admin:", proxyAdminAddress);

        vm.startBroadcast(deployerKey);

        // Deploy new implementation
        VeMaxiTokenConduit newImplementation = new VeMaxiTokenConduit();
        console2.log("New Implementation deployed at:", address(newImplementation));

        // Upgrade proxy to new implementation
        ProxyAdmin proxyAdmin = ProxyAdmin(proxyAdminAddress);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(proxyAddress), address(newImplementation), "");

        vm.stopBroadcast();

        console2.log("\n=== Upgrade Successful ===");
        console2.log("Proxy Address:", proxyAddress);
        console2.log("New Implementation Address:", address(newImplementation));
    }
}

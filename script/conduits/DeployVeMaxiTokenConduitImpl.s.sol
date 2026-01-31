// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {VeMaxiTokenConduit} from "../../contracts/conduits/VeMaxiTokenConduit.sol";

/**
 * @title DeployVeMaxiTokenConduitImpl
 * @dev Script to deploy a new VeMaxiTokenConduit implementation only (for manual upgrade via multisig)
 */
contract DeployVeMaxiTokenConduitImpl is Script {
    function run() public {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(deployerKey);

        string memory networkName = vm.envOr("NETWORK", string("base"));

        console2.log("=== VeMaxiTokenConduit Implementation Deployment ===");
        console2.log("Network:", networkName);
        console2.log("Deployer:", deployer);

        vm.startBroadcast(deployerKey);

        VeMaxiTokenConduit newImplementation = new VeMaxiTokenConduit();

        vm.stopBroadcast();

        console2.log("\n=== Deployment Successful ===");
        console2.log("New Implementation Address:", address(newImplementation));
        console2.log("\nTo upgrade, call ProxyAdmin.upgradeAndCall() with:");
        console2.log("  implementation:", address(newImplementation));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {EarningPowerSnapshotsLens} from "../../contracts/governance/EarningPowerSnapshotsLens.sol";

contract DeployEarningPowerSnapshotsLens is Script {
    function run() external returns (EarningPowerSnapshotsLens) {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address veNFT = vm.envAddress("VE_TOKEN");
        
        console2.log("Deploying EarningPowerSnapshotsLens...");
        console2.log("Deployer:", deployer);
        console2.log("veNFT:", veNFT);

        vm.startBroadcast(deployerPrivateKey);

        EarningPowerSnapshotsLens lens = new EarningPowerSnapshotsLens(deployer, veNFT);

        vm.stopBroadcast();

        console2.log("EarningPowerSnapshotsLens deployed at:", address(lens));
        
        return lens;
    }
}


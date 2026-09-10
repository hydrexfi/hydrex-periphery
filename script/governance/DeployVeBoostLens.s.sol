// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {VeBoostLens} from "../../contracts/governance/VeBoostLens.sol";

contract DeployVeBoostLens is Script {
    function run() external returns (VeBoostLens) {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address veNFT = vm.envAddress("VE_TOKEN");

        console2.log("Deploying VeBoostLens...");
        console2.log("Deployer:", deployer);
        console2.log("veNFT:", veNFT);

        vm.startBroadcast(deployerPrivateKey);

        VeBoostLens lens = new VeBoostLens(veNFT);

        vm.stopBroadcast();

        console2.log("VeBoostLens deployed at:", address(lens));
        console2.log("BOOST_BPS:", lens.BOOST_BPS());

        return lens;
    }
}

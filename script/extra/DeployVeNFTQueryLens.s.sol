// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import "../../contracts/extra/VeNFTQueryLens.sol";

contract DeployVeNFTQueryLens is Script {
    function run() external returns (VeNFTQueryLens) {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(deployerKey);
        
        console.log("Deployer:", deployer);
        
        vm.startBroadcast(deployerKey);
        
        VeNFTQueryLens lens = new VeNFTQueryLens();
        
        console.log("VeNFTQueryLens deployed at:", address(lens));
        
        vm.stopBroadcast();
        
        return lens;
    }
}


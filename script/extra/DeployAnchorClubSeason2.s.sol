// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {AnchorClubSeason1Snapshot} from "../../contracts/anchor-club/AnchorClubSeason1Snapshot.sol";
import {AnchorClubSeason2} from "../../contracts/anchor-club/AnchorClubSeason2.sol";
import {IOptionsToken} from "../../contracts/interfaces/IOptionsToken.sol";
import {ILiquidConduit} from "../../contracts/interfaces/ILiquidConduit.sol";
import {VeMaxiTokenConduit} from "../../contracts/conduits/VeMaxiTokenConduit.sol";

contract DeployAnchorClubSeason2 is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address admin = vm.addr(deployerKey);
        address optionsToken = vm.envAddress("OPTIONS_TOKEN");
        address veMaxiConduit = vm.envAddress("VE_MAXI_CONDUIT");

        vm.startBroadcast(deployerKey);

        // Deploy Season 1 Snapshot
        AnchorClubSeason1Snapshot snapshot = new AnchorClubSeason1Snapshot(admin);
        console.log("AnchorClubSeason1Snapshot:", address(snapshot));

        // Deploy Season 2
        AnchorClubSeason2 season2 = new AnchorClubSeason2(
            IOptionsToken(optionsToken),
            ILiquidConduit(address(snapshot)),
            VeMaxiTokenConduit(payable(veMaxiConduit)),
            admin
        );
        console.log("AnchorClubSeason2:", address(season2));

        vm.stopBroadcast();
    }
}

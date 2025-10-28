// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {AnchorClubFlexAccounts} from "../../contracts/anchor-club/AnchorClubFlexAccounts.sol";
import {AnchorClubLiquidConduit} from "../../contracts/anchor-club/AnchorClubLiquidConduit.sol";
import {LiquidAccountConduitSimple} from "../../contracts/conduits/LiquidAccountConduitSimple.sol";
import {IHydrexVotingEscrow} from "../../contracts/interfaces/IHydrexVotingEscrow.sol";
import {IOptionsToken} from "../../contracts/interfaces/IOptionsToken.sol";

contract DeployAnchorClub is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address admin = vm.addr(deployerKey);
        address veToken = vm.envAddress("VE_TOKEN");
        address optionsToken = vm.envAddress("OPTIONS_TOKEN");
        address conduitSimple = vm.envAddress("LIQUID_CONDUIT_SIMPLE");

        vm.startBroadcast(deployerKey);

        // Deploy Flex Accounts
        AnchorClubFlexAccounts flex = new AnchorClubFlexAccounts(
            IHydrexVotingEscrow(veToken),
            IOptionsToken(optionsToken),
            admin
        );
        console.log("AnchorClubFlexAccounts:", address(flex));

        // Deploy Liquid Conduit wrapper (single initial LiquidAccountConduitSimple)
        AnchorClubLiquidConduit liquid = new AnchorClubLiquidConduit(
            LiquidAccountConduitSimple(payable(conduitSimple)),
            IOptionsToken(optionsToken),
            admin
        );
        console.log("AnchorClubLiquidConduit:", address(liquid));

        vm.stopBroadcast();
    }
}



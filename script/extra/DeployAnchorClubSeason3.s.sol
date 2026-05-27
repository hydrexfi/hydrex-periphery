// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {AnchorClubSeason2Snapshot} from "../../contracts/anchor-club/AnchorClubSeason2Snapshot.sol";
import {AnchorClubSeason2VeMaxiSnapshot} from "../../contracts/anchor-club/AnchorClubSeason2VeMaxiSnapshot.sol";
import {AnchorClubSeason3} from "../../contracts/anchor-club/AnchorClubSeason3.sol";
import {IOptionsToken} from "../../contracts/interfaces/IOptionsToken.sol";
import {ILiquidConduit} from "../../contracts/interfaces/ILiquidConduit.sol";
import {IVeMaxiBalances} from "../../contracts/interfaces/IVeMaxiBalances.sol";

contract DeployAnchorClubSeason3 is Script {
    address constant OPTIONS_TOKEN = 0xA1136031150E50B015b41f1ca6B2e99e49D8cB78;
    address constant VE_MAXI_CONDUIT = 0x53388a4E98Bb56F8571433F5461010Fc287929d3;

    // Season 2's live liquid conduits — Season 3 keeps accruing against these
    // and subtracts the Season 2 snapshot below.
    address constant LIQUID_CONDUIT_1 = 0x95f04F2eEe7a197b30708E50D25B5E876917D259;
    address constant LIQUID_CONDUIT_2 = 0x5e932317B4AfbCE3d254072c1a39579967D8F9ae;
    address constant LIQUID_CONDUIT_3 = 0x9ee81fD729b91095563fE6dA11c1fE92C52F9728;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address admin = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        AnchorClubSeason2Snapshot liquidSnapshot = new AnchorClubSeason2Snapshot(admin);
        console.log("AnchorClubSeason2Snapshot:", address(liquidSnapshot));

        AnchorClubSeason2VeMaxiSnapshot veMaxiSnapshot = new AnchorClubSeason2VeMaxiSnapshot(admin);
        console.log("AnchorClubSeason2VeMaxiSnapshot:", address(veMaxiSnapshot));

        AnchorClubSeason3 season3 = new AnchorClubSeason3(
            IOptionsToken(OPTIONS_TOKEN),
            ILiquidConduit(address(liquidSnapshot)),
            IVeMaxiBalances(VE_MAXI_CONDUIT),
            IVeMaxiBalances(address(veMaxiSnapshot)),
            admin
        );
        console.log("AnchorClubSeason3:", address(season3));

        ILiquidConduit[] memory conduits = new ILiquidConduit[](3);
        conduits[0] = ILiquidConduit(LIQUID_CONDUIT_1);
        conduits[1] = ILiquidConduit(LIQUID_CONDUIT_2);
        conduits[2] = ILiquidConduit(LIQUID_CONDUIT_3);
        season3.addLiquidConduits(conduits);
        console.log("Registered 3 live liquid conduits");

        vm.stopBroadcast();
    }
}

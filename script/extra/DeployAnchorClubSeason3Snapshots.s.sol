// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {AnchorClubSeason3Snapshot} from "../../contracts/anchor-club/AnchorClubSeason3Snapshot.sol";
import {AnchorClubSeason3VeMaxiSnapshot} from "../../contracts/anchor-club/AnchorClubSeason3VeMaxiSnapshot.sol";

/**
 * @notice Step 1 of winding down Anchor Club. Deploys the empty Season 3 end-of-season snapshots.
 *         Deploying does not change any live behaviour —
 *         Season 3 keeps accruing until `FreezeAnchorClubSeason3` repoints it at these contracts.
 */
contract DeployAnchorClubSeason3Snapshots is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address admin = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        AnchorClubSeason3Snapshot liquidSnapshot = new AnchorClubSeason3Snapshot(admin);
        console.log("AnchorClubSeason3Snapshot:", address(liquidSnapshot));

        AnchorClubSeason3VeMaxiSnapshot veMaxiSnapshot = new AnchorClubSeason3VeMaxiSnapshot(admin);
        console.log("AnchorClubSeason3VeMaxiSnapshot:", address(veMaxiSnapshot));

        vm.stopBroadcast();
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {AnchorClubSeason3} from "../../contracts/anchor-club/AnchorClubSeason3.sol";
import {ILiquidConduit} from "../../contracts/interfaces/ILiquidConduit.sol";
import {IVeMaxiBalances} from "../../contracts/interfaces/IVeMaxiBalances.sol";

/**
 * @notice Step 3 of winding down Anchor Club. Repoints the live AnchorClubSeason3 contract at the
 *         frozen Season 3 snapshots so credits stop accruing while redemption stays open forever.
 *
 * @dev Season 3 is left deployed and untouched otherwise: `liquidSpentCredits`, `veMaxiSpentCredits`,
 *      the Season 2 baselines and the options-token wiring all stay exactly as they are. No Season 4
 *      contract is deployed.
 *
 *      Ordering matters. The liquid swap is *remove-then-add*, never add-then-remove: for the few
 *      seconds between the two transactions the live conduits and the frozen snapshot would both be
 *      summed, roughly doubling every user's redeemable balance. Removing first fails safe — liquid
 *      credits read 0 until the snapshot is added, so redemptions revert rather than over-pay.
 *
 *      If the admin is a Safe, submit these three calls as one batched transaction instead and the
 *      window disappears entirely.
 *
 *      Env:
 *        DEPLOYER_KEY                   admin key for AnchorClubSeason3
 *        SEASON3_LIQUID_SNAPSHOT        AnchorClubSeason3Snapshot address
 *        SEASON3_VEMAXI_SNAPSHOT        AnchorClubSeason3VeMaxiSnapshot address
 */
contract FreezeAnchorClubSeason3 is Script {
    address constant SEASON_3 = 0x2C8aF0F727aD97Ef0ba0119330D5609ac93D8699;

    // Live liquid conduits Season 3 has been accruing against
    address constant LIQUID_CONDUIT_1 = 0x95f04F2eEe7a197b30708E50D25B5E876917D259;
    address constant LIQUID_CONDUIT_2 = 0x5e932317B4AfbCE3d254072c1a39579967D8F9ae;
    address constant LIQUID_CONDUIT_3 = 0x9ee81fD729b91095563fE6dA11c1fE92C52F9728;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address liquidSnapshot = vm.envAddress("SEASON3_LIQUID_SNAPSHOT");
        address veMaxiSnapshot = vm.envAddress("SEASON3_VEMAXI_SNAPSHOT");

        AnchorClubSeason3 season3 = AnchorClubSeason3(SEASON_3);

        console.log("Freezing Season 3 at block:", block.number);
        console.log("  liquid snapshot:", liquidSnapshot);
        console.log("  veMaxi snapshot:", veMaxiSnapshot);

        vm.startBroadcast(deployerKey);

        // VeMaxi is a single setter — atomic, no window.
        season3.setVeMaxiConduit(IVeMaxiBalances(veMaxiSnapshot));
        console.log("VeMaxi source repointed at frozen snapshot");

        // Liquid: remove live conduits BEFORE adding the snapshot.
        ILiquidConduit[] memory live = new ILiquidConduit[](3);
        live[0] = ILiquidConduit(LIQUID_CONDUIT_1);
        live[1] = ILiquidConduit(LIQUID_CONDUIT_2);
        live[2] = ILiquidConduit(LIQUID_CONDUIT_3);
        season3.removeLiquidConduits(live);
        console.log("Removed 3 live liquid conduits");

        ILiquidConduit[] memory frozenSource = new ILiquidConduit[](1);
        frozenSource[0] = ILiquidConduit(liquidSnapshot);
        season3.addLiquidConduits(frozenSource);
        console.log("Added frozen liquid snapshot as sole conduit");

        vm.stopBroadcast();

        ILiquidConduit[] memory nowRegistered = season3.getLiquidConduits();
        require(nowRegistered.length == 1, "expected exactly one liquid source");
        require(address(nowRegistered[0]) == liquidSnapshot, "liquid source mismatch");
        require(address(season3.veMaxiConduit()) == veMaxiSnapshot, "veMaxi source mismatch");
        console.log("Season 3 frozen. Reconcile, then call freeze() on both snapshots.");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Hydropoints} from "../../contracts/basedrop/Hydropoints.sol";
import {HydrexBadges} from "../../contracts/basedrop/HydrexBadges.sol";
import {ProtocolMining} from "../../contracts/basedrop/ProtocolMining.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DeployMiningHydropoints is Script {
    function configureBadges(HydrexBadges badges) internal {
        // Hydrex badge configurations - only badges with supply limits
        uint256[] memory badgeIds = new uint256[](11);
        uint256[] memory maxSupplies = new uint256[](11);

        // Badge ID 0: Hydrex O.G. - Limited to 10000
        badgeIds[0] = 0;
        maxSupplies[0] = 10000;

        // Badge ID 6: Farcaster - Limited to 1000
        badgeIds[1] = 6;
        maxSupplies[1] = 1000;

        // Badge ID 7: Farcaster Pro - Limited to 100
        badgeIds[2] = 7;
        maxSupplies[2] = 100;

        // Badge ID 8: Squad Up - Limited to 5000
        badgeIds[3] = 8;
        maxSupplies[3] = 2500;

        // Badge ID 9: Base Dot ETH - Limited to 5000
        badgeIds[4] = 9;
        maxSupplies[4] = 5000;

        // Badge ID 10: Pretty Smart - Limited to 2500
        badgeIds[5] = 10;
        maxSupplies[5] = 1000;

        // Badge ID 11: It's Official - Limited to 500
        badgeIds[6] = 11;
        maxSupplies[6] = 250;

        // Badge ID 12: Buildooor - Limited to 250
        badgeIds[7] = 12;
        maxSupplies[7] = 250;

        // Badge ID 13: Content Coiner - Limited to 250
        badgeIds[8] = 13;
        maxSupplies[8] = 250;

        // Badge ID 14: Mother Flauncher - Limited to 250
        badgeIds[9] = 14;
        maxSupplies[9] = 250;

        // Badge ID 15: You The One - Limited to 100
        badgeIds[10] = 15;
        maxSupplies[10] = 100;

        // Configure all badges in a single transaction
        badges.setMaxSupplyBatch(badgeIds, maxSupplies);

        console2.log("=== Badge Configuration ===");
        for (uint256 i = 0; i < badgeIds.length; i++) {
            console2.log("Badge ID:", badgeIds[i], "Max Supply:", maxSupplies[i]);
        }
        console2.log("Note: Badges 1-5 (Based tier) have unlimited supply by default");
    }

    function run() public {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(deployerKey);

        // Configuration - can be overridden via environment variables
        address feeAddress = 0x74266f2b206D1359B83fc74949EF07176FB3AE03; // Hydrex Treasury
        uint256 rewardPerSecond = 21.11 ether;
        uint256 startTime = 1750784400; // June 24, 2025 17:00:00 UTC
        uint256 endTime = 1750784400 + 120 days;

        console2.log("Deployer:", deployer);
        console2.log("Fee Address:", feeAddress);
        console2.log("Reward Per Second:", rewardPerSecond);
        console2.log("Start Time:", startTime);
        console2.log("End Time:", endTime);

        vm.startBroadcast(deployerKey);

        // Deploy Hydropoints with deployer as default admin
        Hydropoints hydropoints = new Hydropoints(deployer);
        console2.log("Hydropoints deployed at:", address(hydropoints));

        // Deploy HydrexBadges
        HydrexBadges hydrexBadges = new HydrexBadges();
        console2.log("HydrexBadges deployed at:", address(hydrexBadges));

        // Configure badges with max supplies
        configureBadges(hydrexBadges);

        // 4 Minters + the Main Hydrex Deployer
        address[4] memory badgeMinters = [
            vm.envOr("BADGE_MINTER_1", address(0x1681b1d40AB2fb81F8a1dd28b56baFfbB869a214)),
            vm.envOr("BADGE_MINTER_2", address(0x1Fe6A414627ebC0cD35E5f82528f74f4eBD7CdE9)),
            vm.envOr("BADGE_MINTER_3", address(0xC0A052EFAC921a70cE3D3e429992abE5B5014452)),
            vm.envOr("BADGE_MINTER_4", address(0x674DE502c3e9918c3E3a6C88BA6d525bbd078f12))
        ];

        console2.log("=== Badge Minter Setup ===");
        for (uint256 i = 0; i < badgeMinters.length; i++) {
            hydrexBadges.grantRole(hydrexBadges.MINTER_ROLE(), badgeMinters[i]);
            console2.log("Granted MINTER_ROLE to badge minter", i + 1, ":", badgeMinters[i]);
        }

        // Deploy ProtocolMining
        ProtocolMining protocolMining = new ProtocolMining(
            hydropoints,
            feeAddress,
            rewardPerSecond,
            startTime,
            endTime
        );
        console2.log("ProtocolMining deployed at:", address(protocolMining));

        // Grant MINTER_ROLE to ProtocolMining contract
        hydropoints.grantRole(hydropoints.MINTER_ROLE(), address(protocolMining));
        console2.log("Granted MINTER_ROLE to ProtocolMining");

        // Add token farms for all pairs
        // pid 0: WETH/USDC
        protocolMining.add(750, IERC20(0x07e72E46C319a6d5aCA28Ad52f5C41a7821989Ad), 0, false);
        console2.log("Added token pool WETH/USDC with 750 allocation points and 0% deposit fee");

        // pid 1: USDC/WETH
        protocolMining.add(750, IERC20(0x0C9be6dF4e114D5Cb04Cbb934172Be1FcC5526c6), 0, false);
        console2.log("Added token pool USDC/WETH with 750 allocation points and 0% deposit fee");

        // pid 2: cbBTC/WETH
        protocolMining.add(1000, IERC20(0x558684fDAd1D3b69f920b0C8E5Ae9ff797e3f045), 0, false);
        console2.log("Added token pool cbBTC/WETH with 1000 allocation points and 0% deposit fee");

        // pid 3: cbDOGE/WETH
        protocolMining.add(750, IERC20(0x1877087D654ddE334e116283892782135b4764Ee), 0, false);
        console2.log("Added token pool cbDOGE/WETH with 750 allocation points and 0% deposit fee");

        // pid 4: cbXRP/WETH
        protocolMining.add(750, IERC20(0xC3518c97375BC2FBa44De018Da20A95DD12cAeEe), 0, false);
        console2.log("Added token pool cbXRP/WETH with 750 allocation points and 0% deposit fee");

        // pid 5: cbBTC/USDC
        protocolMining.add(750, IERC20(0x25154C35b24aF82196bAc0D143dD973335201b6a), 0, false);
        console2.log("Added token pool cbBTC/USDC with 750 allocation points and 0% deposit fee");

        // pid 6: GHO/USDC
        protocolMining.add(200, IERC20(0x5FD254Cd52235B9c04E53B48d77B52366BfB7c03), 0, false);
        console2.log("Added token pool GHO/USDC with 200 allocation points and 0% deposit fee");

        // pid 7: EURC/WETH
        protocolMining.add(200, IERC20(0xE72258d2844Dcd3092825D51bF3C380424723B2d), 0, false);
        console2.log("Added token pool EURC/WETH with 200 allocation points and 0% deposit fee");

        // pid 8: ETH/USDT0
        protocolMining.add(750, IERC20(0x50cBEfFdD5671C8CdcE323E0553F1990678100FC), 0, false);
        console2.log("Added token pool ETH/USDT0 with 750 allocation points and 0% deposit fee");

        vm.stopBroadcast();

        // Log final configuration
        console2.log("=== Deployment Complete ===");
        console2.log("Hydropoints:", address(hydropoints));
        console2.log("HydrexBadges:", address(hydrexBadges));
        console2.log("ProtocolMining:", address(protocolMining));
        console2.log("Default Admin:", deployer);
        console2.log("Mining Start:", startTime);
        console2.log("Mining End:", endTime);
        console2.log("Harvest Enabled:", protocolMining.harvestEnable());
    }
}

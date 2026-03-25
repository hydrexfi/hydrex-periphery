// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {HydrexMultichainAuctionRouter} from "../../contracts/bridge/HydrexMultichainAuctionRouter.sol";

/**
 * @title DeployHydrexMultichainAuctionRouter
 * @dev Deploys HydrexMultichainAuctionRouter on Base mainnet.
 *
 * Required env vars:
 *   DEPLOYER_KEY  — private key of the deployer
 *
 * Optional env vars:
 *   NETWORK       — label for the deployment JSON (default: "base")
 */
contract DeployHydrexMultichainAuctionRouter is Script {
    function run() public {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(deployerKey);
        string memory networkName = vm.envOr("NETWORK", string("base"));

        console2.log("=== HydrexMultichainAuctionRouter Deployment ===");
        console2.log("Network: ", networkName);
        console2.log("Deployer:", deployer);

        vm.startBroadcast(deployerKey);
        HydrexMultichainAuctionRouter router = new HydrexMultichainAuctionRouter();
        vm.stopBroadcast();

        console2.log("\n=== Deployment Successful ===");
        console2.log("HydrexMultichainAuctionRouter:", address(router));
        console2.log("Owner:                        ", router.owner());

        string memory deploymentPath = string.concat(
            "deployments/", networkName, "-HydrexMultichainAuctionRouter-",
            _toHexString(address(router)), ".json"
        );
        string memory json = "deployment";
        vm.serializeString(json, "network", networkName);
        vm.serializeUint(json, "timestamp", block.timestamp);
        string memory finalJson = vm.serializeAddress(json, "address", address(router));
        vm.writeFile(deploymentPath, finalJson);
        console2.log("Saved to:", deploymentPath);
    }

    function _toHexString(address account) internal pure returns (string memory) {
        bytes20 data = bytes20(account);
        bytes16 hexSymbols = 0x30313233343536373839616263646566;
        bytes memory str = new bytes(42);
        str[0] = "0"; str[1] = "x";
        for (uint256 i = 0; i < 20; i++) {
            uint8 b = uint8(data[i]);
            str[2 + i * 2] = bytes1(hexSymbols[b >> 4]);
            str[3 + i * 2] = bytes1(hexSymbols[b & 0x0f]);
        }
        return string(str);
    }
}

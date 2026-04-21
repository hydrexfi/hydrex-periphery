// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {SendDailyPoints} from "../../contracts/send/SendDailyPoints.sol";

/**
 * @title DeploySendDailyPoints
 * @dev Deploys the permissionless daily check-in contract. No constructor
 *      args, no roles, no admin — nothing to wire up.
 *
 *      Run with --verify to verify on BaseScan:
 *        forge script script/send/DeploySendDailyPoints.s.sol:DeploySendDailyPoints \
 *          --rpc-url $BASE_RPC_URL \
 *          --broadcast \
 *          --verify \
 *          --etherscan-api-key $BASESCAN_API_KEY
 *
 * Required env:
 *   DEPLOYER_KEY — deployer private key
 *
 * Optional env (with defaults):
 *   NETWORK      — deployment label (default: "base")
 */
contract DeploySendDailyPoints is Script {
    function run() public {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(deployerKey);

        string memory networkName = vm.envOr("NETWORK", string("base"));

        console2.log("=== SendDailyPoints Deployment ===");
        console2.log("Network: ", networkName);
        console2.log("Deployer:", deployer);
        console2.log("\n=== Starting Deployment ===");

        vm.startBroadcast(deployerKey);
        SendDailyPoints points = new SendDailyPoints();
        vm.stopBroadcast();

        console2.log("\n=== Deployment Successful ===");
        console2.log("SendDailyPoints:", address(points));
        console2.log("  currentDay:   ", points.currentDay());
        console2.log("  totalUsers:   ", points.totalUsers());
        console2.log("  totalCheckIns:", points.totalCheckIns());

        _sanityCheck(points);
        _saveDeployment(networkName, address(points), deployer);
    }

    function _sanityCheck(SendDailyPoints points) internal view {
        require(points.currentDay() == block.timestamp / 1 days, "points: currentDay mismatch");
        require(points.totalUsers() == 0, "points: totalUsers not zero");
        require(points.totalCheckIns() == 0, "points: totalCheckIns not zero");
        require(points.currentStreakOf(address(0xdead)) == 0, "points: stray streak");
        require(!points.hasCheckedInToday(address(0xdead)), "points: stray check-in");
    }

    function _saveDeployment(string memory networkName, address points, address deployer) internal {
        string memory deploymentPath = string.concat(
            "deployments/",
            networkName,
            "-send-daily-points-",
            _toHexString(points),
            ".json"
        );

        string memory json = "deployment";
        vm.serializeString(json, "network", networkName);
        vm.serializeUint(json, "timestamp", block.timestamp);
        vm.serializeUint(json, "blockNumber", block.number);
        vm.serializeAddress(json, "deployer", deployer);
        string memory finalJson = vm.serializeAddress(json, "SendDailyPoints", points);

        vm.writeFile(deploymentPath, finalJson);
        console2.log("\nDeployment saved to:", deploymentPath);
    }

    function _toHexString(address account) internal pure returns (string memory) {
        bytes20 data = bytes20(account);
        bytes16 hexSymbols = 0x30313233343536373839616263646566;
        bytes memory str = new bytes(42);
        str[0] = "0";
        str[1] = "x";
        for (uint256 i = 0; i < 20; i++) {
            uint8 b = uint8(data[i]);
            str[2 + i * 2] = bytes1(hexSymbols[b >> 4]);
            str[3 + i * 2] = bytes1(hexSymbols[b & 0x0f]);
        }
        return string(str);
    }
}

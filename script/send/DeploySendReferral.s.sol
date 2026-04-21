// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {SendReferralClaims} from "../../contracts/send/SendReferralClaims.sol";
import {SendReferralTokenJar} from "../../contracts/send/SendTokenJar.sol";

/**
 * @title DeploySendReferral
 * @dev Deploys:
 *        1. SendReferralClaims           (USDC hardcoded to Base mainnet)
 *        2. SendReferralTokenJar #1      (feeRecipient = SendReferralClaims)
 *        3. SendReferralTokenJar #2      (feeRecipient = TREASURY_FEE_RECIPIENT)
 *
 *      Run with --verify to verify on BaseScan:
 *        forge script script/send/DeploySendReferral.s.sol:DeploySendReferral \
 *          --rpc-url $BASE_RPC_URL \
 *          --broadcast \
 *          --verify \
 *          --etherscan-api-key $BASESCAN_API_KEY
 *
 * Required env:
 *   DEPLOYER_KEY  — deployer private key
 *
 * Optional env (with defaults):
 *   NETWORK       — deployment label        (default: "base")
 *   ADMIN         — admin for all 3         (default: deployer)
 *   MULTI_ROUTER  — HydrexMultiRouter proxy (default: Base mainnet)
 */
contract DeploySendReferral is Script {
    address constant DEFAULT_MULTI_ROUTER = 0x599bFa1039C9e22603F15642B711D56BE62071f4;
    address constant TREASURY_FEE_RECIPIENT = 0x1aE3753d9b60743A89159CcFF8E251C60B560311;

    function run() public {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(deployerKey);

        string memory networkName = vm.envOr("NETWORK", string("base"));
        address admin = vm.envOr("ADMIN", deployer);
        address multiRouter = vm.envOr("MULTI_ROUTER", DEFAULT_MULTI_ROUTER);

        console2.log("=== Send Referral Stack Deployment ===");
        console2.log("Network:           ", networkName);
        console2.log("Deployer:          ", deployer);
        console2.log("Admin:             ", admin);
        console2.log("HydrexMultiRouter: ", multiRouter);
        console2.log("Treasury Recipient:", TREASURY_FEE_RECIPIENT);
        console2.log("\n=== Starting Deployment ===");

        vm.startBroadcast(deployerKey);

        SendReferralClaims claims = new SendReferralClaims(admin);

        SendReferralTokenJar jarToClaims = new SendReferralTokenJar(admin, multiRouter, address(claims));

        SendReferralTokenJar jarToTreasury = new SendReferralTokenJar(admin, multiRouter, TREASURY_FEE_RECIPIENT);

        vm.stopBroadcast();

        console2.log("\n=== Deployment Successful ===");
        console2.log("SendReferralClaims:    ", address(claims));
        console2.log("  USDC:                ", address(claims.usdc()));
        console2.log("  Admin:               ", admin);
        console2.log("");
        console2.log("SendReferralTokenJar 1:", address(jarToClaims));
        console2.log("  Fee Recipient:       ", jarToClaims.feeRecipient(), "(= SendReferralClaims)");
        console2.log("  Router:              ", address(jarToClaims.router()));
        console2.log("");
        console2.log("SendReferralTokenJar 2:", address(jarToTreasury));
        console2.log("  Fee Recipient:       ", jarToTreasury.feeRecipient(), "(= Treasury)");
        console2.log("  Router:              ", address(jarToTreasury.router()));

        _assertWiring(claims, jarToClaims, jarToTreasury, admin, multiRouter);
        _saveDeployment(networkName, address(claims), address(jarToClaims), address(jarToTreasury), admin, multiRouter);
    }

    function _assertWiring(
        SendReferralClaims claims,
        SendReferralTokenJar jarToClaims,
        SendReferralTokenJar jarToTreasury,
        address admin,
        address multiRouter
    ) internal view {
        require(address(claims.usdc()) == 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913, "claims: USDC mismatch");
        require(claims.hasRole(claims.DEFAULT_ADMIN_ROLE(), admin), "claims: admin missing");
        require(claims.hasRole(claims.OPERATOR_ROLE(), admin), "claims: operator missing");

        require(jarToClaims.feeRecipient() == address(claims), "jar1: feeRecipient != claims");
        require(address(jarToClaims.router()) == multiRouter, "jar1: router mismatch");
        require(jarToClaims.hasRole(jarToClaims.DEFAULT_ADMIN_ROLE(), admin), "jar1: admin missing");

        require(jarToTreasury.feeRecipient() == TREASURY_FEE_RECIPIENT, "jar2: feeRecipient != treasury");
        require(address(jarToTreasury.router()) == multiRouter, "jar2: router mismatch");
        require(jarToTreasury.hasRole(jarToTreasury.DEFAULT_ADMIN_ROLE(), admin), "jar2: admin missing");
    }

    function _saveDeployment(
        string memory networkName,
        address claims,
        address jarToClaims,
        address jarToTreasury,
        address admin,
        address multiRouter
    ) internal {
        string memory deploymentPath = string.concat(
            "deployments/",
            networkName,
            "-send-referral-",
            _toHexString(claims),
            ".json"
        );

        string memory json = "deployment";
        vm.serializeString(json, "network", networkName);
        vm.serializeUint(json, "timestamp", block.timestamp);
        vm.serializeUint(json, "blockNumber", block.number);
        vm.serializeAddress(json, "admin", admin);
        vm.serializeAddress(json, "multiRouter", multiRouter);

        string memory claimsJson = "SendReferralClaims";
        vm.serializeAddress(claimsJson, "address", claims);
        string memory claimsData = vm.serializeAddress(
            claimsJson,
            "usdc",
            0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
        );

        string memory jar1Json = "SendReferralTokenJar1";
        vm.serializeAddress(jar1Json, "address", jarToClaims);
        string memory jar1Data = vm.serializeAddress(jar1Json, "feeRecipient", claims);

        string memory jar2Json = "SendReferralTokenJar2";
        vm.serializeAddress(jar2Json, "address", jarToTreasury);
        string memory jar2Data = vm.serializeAddress(jar2Json, "feeRecipient", TREASURY_FEE_RECIPIENT);

        vm.serializeString(json, "SendReferralClaims", claimsData);
        vm.serializeString(json, "SendReferralTokenJar1", jar1Data);
        string memory finalJson = vm.serializeString(json, "SendReferralTokenJar2", jar2Data);

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

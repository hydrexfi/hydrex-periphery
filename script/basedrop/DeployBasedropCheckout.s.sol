// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {BasedropCheckout} from "../../contracts/basedrop/BasedropCheckout.sol";
import {Hydropoints} from "../../contracts/basedrop/Hydropoints.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DeployBasedropCheckout
 * @dev Script to deploy BasedropCheckout contract for converting hydropoints to HYDX locks
 *
 * Required Environment Variables:
 * - DEPLOYER_KEY: Private key of the deployer
 * - HYDX_TOKEN: Address of the HYDX token contract
 * - HYDROPOINTS_TOKEN: Address of the Hydropoints token contract (not required if DEPLOY_MOCK_HYDROPOINTS=true)
 * - USDC_TOKEN: Address of the USDC token contract
 * - VOTING_ESCROW: Address of the voting escrow contract
 *
 * Optional Environment Variables:
 * - DEPLOY_MOCK_HYDROPOINTS: If true, deploys a new Hydropoints contract (defaults to false)
 *
 */
contract DeployBasedropCheckout is Script {
    function run() public {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(deployerKey);

        string memory networkName = vm.envOr("NETWORK", string("base"));

        // Required environment variables
        address hydrexToken = vm.envAddress("HYDX_TOKEN");
        address usdcToken = vm.envAddress("USDC_TOKEN");
        address votingEscrow = vm.envAddress("VE_TOKEN");
        address admin = deployer; // Use deployer as admin

        bool deployMockHydropoints = vm.envOr("DEPLOY_MOCK_HYDROPOINTS", false);
        uint256 mockHydropointsFunding = 1000000 * 10 ** 18; // 1M hydropoints

        address hydropointsToken;
        if (!deployMockHydropoints) {
            hydropointsToken = vm.envAddress("HYDROPOINTS_TOKEN");
        }

        console2.log("=== BasedropCheckout Deployment ===");
        console2.log("Network:", networkName);
        console2.log("Deployer:", deployer);
        console2.log("Admin:", admin);
        console2.log("HYDX Token:", hydrexToken);
        console2.log("USDC Token:", usdcToken);
        console2.log("Voting Escrow:", votingEscrow);
        console2.log("Deploy Mock Hydropoints:", deployMockHydropoints);
        if (!deployMockHydropoints) {
            console2.log("Hydropoints Token:", hydropointsToken);
        } else {
            console2.log("Mock Hydropoints Funding:", mockHydropointsFunding);
        }
        console2.log("Conversion Rate: 10 hydropoints = 1 HYDX");
        console2.log("USDC Rate: 10 hydropoints = 0.01 USDC");
        console2.log("\n=== Starting Deployment ===");

        vm.startBroadcast(deployerKey);

        // Deploy Hydropoints if requested
        Hydropoints hydropointsContract;
        if (deployMockHydropoints) {
            hydropointsContract = new Hydropoints(deployer);
            hydropointsToken = address(hydropointsContract);
            console2.log("Mock Hydropoints deployed at:", hydropointsToken);

            // Mint hydropoints to deployer for testing
            hydropointsContract.grantRole(hydropointsContract.MINTER_ROLE(), deployer);
            hydropointsContract.mint(deployer, mockHydropointsFunding);
            console2.log("Minted", mockHydropointsFunding, "hydropoints to deployer");
        } else {
            hydropointsContract = Hydropoints(hydropointsToken);
        }

        // Deploy BasedropCheckout contract
        BasedropCheckout basedropCheckout = new BasedropCheckout(
            hydrexToken,
            hydropointsToken,
            usdcToken,
            votingEscrow,
            admin
        );

        console2.log("BasedropCheckout deployed at:", address(basedropCheckout));

        if (deployMockHydropoints || hydropointsContract.hasRole(hydropointsContract.DEFAULT_ADMIN_ROLE(), deployer)) {
            hydropointsContract.grantRole(hydropointsContract.REDEEMER_ROLE(), address(basedropCheckout));
            console2.log("Granted REDEEMER_ROLE to BasedropCheckout on Hydropoints");
        } else {
            console2.log("WARNING: Hydropoints admin needs to manually grant REDEEMER_ROLE");
            console2.log("Execute: hydropoints.grantRole(REDEEMER_ROLE, ", address(basedropCheckout), ")");
            console2.log("This allows BasedropCheckout to redeem (burn) hydropoints during conversion");
        }

        console2.log("NOTE: Contract needs HYDX tokens to create locks for users");
        console2.log("Admin should fund contract with HYDX");

        vm.stopBroadcast();

        console2.log("\n=== Deployment Successful ===");
        console2.log("BasedropCheckout:", address(basedropCheckout));
        if (deployMockHydropoints) {
            console2.log("Mock Hydropoints:", hydropointsToken);
            console2.log("Deployer Hydropoints Balance:", hydropointsContract.balanceOf(deployer));
        }
        console2.log("Admin:", admin);

        console2.log("\n=== Contract Configuration ===");
        console2.log("Conversion Rate:", basedropCheckout.CONVERSION_RATE());
        console2.log("USDC Conversion Rate:", basedropCheckout.USDC_CONVERSION_RATE());
        console2.log("Lock Duration:", basedropCheckout.LOCK_DURATION());
        console2.log("Permanent Lock Type:", basedropCheckout.LOCK_TYPE_PERMANENT());
        console2.log("Temporary Lock Type:", basedropCheckout.LOCK_TYPE_TEMPORARY());

        _saveDeployment(
            networkName,
            address(basedropCheckout),
            admin,
            hydrexToken,
            hydropointsToken,
            usdcToken,
            votingEscrow
        );
    }

    function _saveDeployment(
        string memory networkName,
        address basedropCheckoutAddress,
        address admin,
        address hydrexToken,
        address hydropointsToken,
        address usdcToken,
        address votingEscrow
    ) internal {
        // Create a unique file per deployment
        string memory deploymentPath = string.concat(
            "deployments/",
            networkName,
            "-",
            _toHexString(basedropCheckoutAddress),
            ".json"
        );

        // Create deployment JSON
        string memory json = "deployment";
        vm.serializeString(json, "network", networkName);
        vm.serializeUint(json, "timestamp", block.timestamp);
        vm.serializeUint(json, "blockNumber", block.number);

        // Contract information
        string memory contractJson = "contracts";
        string memory basedropCheckoutJson = "BasedropCheckout";
        vm.serializeAddress(basedropCheckoutJson, "address", basedropCheckoutAddress);
        vm.serializeAddress(basedropCheckoutJson, "admin", admin);
        vm.serializeAddress(basedropCheckoutJson, "hydrexToken", hydrexToken);
        vm.serializeAddress(basedropCheckoutJson, "hydropointsToken", hydropointsToken);
        vm.serializeAddress(basedropCheckoutJson, "usdcToken", usdcToken);
        vm.serializeAddress(basedropCheckoutJson, "votingEscrow", votingEscrow);
        vm.serializeUint(basedropCheckoutJson, "conversionRate", 10);
        vm.serializeUint(basedropCheckoutJson, "usdcConversionRate", 10000);
        vm.serializeUint(basedropCheckoutJson, "lockDuration", 0);
        vm.serializeUint(basedropCheckoutJson, "lockTypePermanent", 2);
        string memory basedropCheckoutData = vm.serializeUint(basedropCheckoutJson, "lockTypeTemporary", 1);

        string memory contractData = vm.serializeString(contractJson, "BasedropCheckout", basedropCheckoutData);
        string memory finalJson = vm.serializeString(json, "contracts", contractData);

        // Write to file
        vm.writeFile(deploymentPath, finalJson);
        console2.log("Deployment saved to:", deploymentPath);
    }

    function _toHexString(address account) internal pure returns (string memory) {
        bytes20 data = bytes20(account);
        bytes16 hexSymbols = 0x30313233343536373839616263646566; // 0-9a-f
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

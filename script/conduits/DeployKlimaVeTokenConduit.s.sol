// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {KlimaVeTokenConduit} from "../../contracts/conduits/KlimaVeTokenConduit.sol";

/**
 * @title DeployKlimaVeTokenConduit
 * @dev Deploys KlimaVeTokenConduit with Klima/Carbonmark retirement integration.
 *      Reads admin/treasury/voter/veToken from .env; Klima protocol addresses are hardcoded Base mainnet constants.
 */
contract DeployKlimaVeTokenConduit is Script {
    // Klima protocol (Base mainnet)
    address constant KVCM = 0x00fBAC94Fec8D4089d3fe979F39454F48c71A65d;
    address constant HYDREX_BENEFICIARY = 0xcba0000027bd78edf6714DE3bCC312360E469502;
    address constant AZUSD = 0x3595ca37596D5895B70EFAB592ac315D5B9809B2;
    address constant RETIREMENT_AGGREGATOR = 0xdA0A793D7C32AB80bcdab7F8c725c96DB22464f4;
    address constant AAM = 0x1C24239309398220883207681602BfF4D10fbde1;
    address constant CREDIT_TOKEN = 0x270fF9B9C8B3D0403f14c7AB916c8721280fBBa3;
    address constant CARBON_CLASS = 0x0008f35758a4318942EcB5d5414116ce7B1Ede2d;

    // Retire 33.33% of kVCM per cycle
    uint256 constant RETIRE_BPS = 3333;

    function run() public {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(deployerKey);

        string memory networkName = vm.envOr("NETWORK", string("base"));
        address admin = vm.envAddress("ADMIN");
        address treasury = vm.envAddress("TREASURY");
        address voter = vm.envAddress("VOTER");
        address veToken = vm.envAddress("VE_TOKEN");

        address[] memory distributionTokens = new address[](2);
        distributionTokens[0] = KVCM;
        distributionTokens[1] = AZUSD;

        address[] memory approvedRouters = new address[](1);
        approvedRouters[0] = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5; // KyberSwap Router

        console2.log("=== KlimaVeTokenConduit Deployment ===");
        console2.log("Network:", networkName);
        console2.log("Deployer:", deployer);
        console2.log("Admin:", admin);
        console2.log("Treasury:", treasury);
        console2.log("Treasury Fee: 0% (0 BPS)");
        console2.log("Retire BPS:", RETIRE_BPS, "(33.33%)");
        console2.log("Beneficiary:", HYDREX_BENEFICIARY);
        console2.log(
            "Retirement Message: Programmatic carbon retirement via Hydrex's Carbon Strategy on the Base network"
        );
        console2.log("\n=== Klima Protocol Addresses ===");
        console2.log("kVCM:", KVCM);
        console2.log("azUSD:", AZUSD);
        console2.log("Retirement Aggregator:", RETIREMENT_AGGREGATOR);
        console2.log("AAM:", AAM);
        console2.log("Credit Token:", CREDIT_TOKEN);
        console2.log("Carbon Class:", CARBON_CLASS);
        console2.log("\n=== Starting Deployment ===");

        vm.startBroadcast(deployerKey);

        KlimaVeTokenConduit conduit = new KlimaVeTokenConduit(
            admin,
            treasury,
            voter,
            veToken,
            KVCM,
            distributionTokens,
            RETIREMENT_AGGREGATOR,
            AAM,
            CREDIT_TOKEN,
            CARBON_CLASS,
            RETIRE_BPS,
            approvedRouters
        );

        vm.stopBroadcast();

        console2.log("\n=== Deployment Successful ===");
        console2.log("KlimaVeTokenConduit deployed at:", address(conduit));
        console2.log("Admin:", admin);
        console2.log("Treasury:", treasury);
        console2.log("Voter:", voter);
        console2.log("VeToken:", veToken);
        console2.log("Distribution tokens:", distributionTokens.length);
        console2.log("Approved routers:", approvedRouters.length);

        _saveDeployment(networkName, address(conduit), admin, treasury, voter, veToken);
    }

    function _saveDeployment(
        string memory networkName,
        address conduitAddress,
        address admin,
        address treasury,
        address voter,
        address veToken
    ) internal {
        string memory deploymentPath = string.concat(
            "deployments/",
            networkName,
            "-",
            _toHexString(conduitAddress),
            ".json"
        );

        string memory json = "deployment";
        vm.serializeString(json, "network", networkName);
        vm.serializeUint(json, "timestamp", block.timestamp);
        vm.serializeUint(json, "blockNumber", block.number);

        string memory contractJson = "contracts";
        string memory conduitJson = "KlimaVeTokenConduit";
        vm.serializeAddress(conduitJson, "address", conduitAddress);
        vm.serializeAddress(conduitJson, "admin", admin);
        vm.serializeAddress(conduitJson, "treasury", treasury);
        vm.serializeAddress(conduitJson, "voter", voter);
        vm.serializeAddress(conduitJson, "veToken", veToken);
        vm.serializeAddress(conduitJson, "kvcm", KVCM);
        vm.serializeAddress(conduitJson, "azusd", AZUSD);
        vm.serializeAddress(conduitJson, "retirementAggregator", RETIREMENT_AGGREGATOR);
        vm.serializeAddress(conduitJson, "aam", AAM);
        vm.serializeAddress(conduitJson, "creditToken", CREDIT_TOKEN);
        vm.serializeAddress(conduitJson, "carbonClass", CARBON_CLASS);
        vm.serializeUint(conduitJson, "retireBps", RETIRE_BPS);
        vm.serializeUint(conduitJson, "treasuryFeeBps", 0);
        string memory conduitData = vm.serializeString(conduitJson, "name", "KlimaVeTokenConduit");

        string memory contractData = vm.serializeString(contractJson, "KlimaVeTokenConduit", conduitData);
        string memory finalJson = vm.serializeString(json, "contracts", contractData);

        vm.writeFile(deploymentPath, finalJson);
        console2.log("Deployment saved to:", deploymentPath);
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

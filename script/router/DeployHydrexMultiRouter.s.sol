// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {HydrexMultiRouter} from "../../contracts/router/HydrexMultiRouter.sol";
import {HydrexMultiRouterProxy} from "../../contracts/router/HydrexMultiRouterProxy.sol";

/**
 * @title DeployHydrexMultiRouter
 * @dev Script to deploy HydrexMultiRouter (UUPS) on Base mainnet
 */
contract DeployHydrexMultiRouter is Script {
    address constant ALGEBRA_ROUTER = 0x6f4bE24d7dC93b6ffcBAb3Fd0747c5817Cea3F9e;
    address constant ODOS_ROUTER = 0x19cEeAd7105607Cd444F5ad10dd51356436095a1;
    address constant KYBER_ROUTER = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;
    address constant ZEROX_ROUTER = 0x0000000000001fF3684f28c67538d4D072C22734;
    address constant OPENOCEAN_ROUTER = 0x6352a56caadC4F1E25CD6c75970Fa768A3304e64;
    address constant OKX_ROUTER = 0x2bD541Ab3b704F7d4c9DFf79EfaDeaa85EC034f1;
    address constant SOLIDLY_ROUTER = 0x8fB6177eb7AC7D9e75DE2D58D8749755D6BD9EA1;

    function run() public {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(deployerKey);

        string memory networkName = vm.envOr("NETWORK", string("base"));
        address admin = vm.envOr("ADMIN", deployer);
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");

        console2.log("=== HydrexMultiRouter Deployment (UUPS) ===");
        console2.log("Network:", networkName);
        console2.log("Deployer:", deployer);
        console2.log("Admin:", admin);
        console2.log("Fee Recipient:", feeRecipient);
        console2.log("\n=== Starting Deployment ===");

        vm.startBroadcast(deployerKey);

        HydrexMultiRouter impl = new HydrexMultiRouter();
        console2.log("Implementation deployed at:", address(impl));

        bytes memory initData = abi.encodeCall(HydrexMultiRouter.initialize, (admin, feeRecipient));
        HydrexMultiRouterProxy proxy = new HydrexMultiRouterProxy(address(impl), initData);
        console2.log("Proxy deployed at:", address(proxy));

        HydrexMultiRouter router = HydrexMultiRouter(payable(address(proxy)));
        address[] memory routers = new address[](7);
        routers[0] = ALGEBRA_ROUTER;
        routers[1] = ODOS_ROUTER;
        routers[2] = KYBER_ROUTER;
        routers[3] = ZEROX_ROUTER;
        routers[4] = OPENOCEAN_ROUTER;
        routers[5] = OKX_ROUTER;
        routers[6] = SOLIDLY_ROUTER;
        router.addRouters(routers);

        vm.stopBroadcast();

        console2.log("\n=== Deployment Successful ===");
        console2.log("Proxy:", address(proxy));
        console2.log("Implementation:", address(impl));
        console2.log("Admin:", admin);
        console2.log("Fee Recipient:", router.feeRecipient());
        console2.log("Fee BPS:", router.feeBps());
        console2.log("Routers whitelisted: Algebra, Odos, Kyber, ZeroX, OpenOcean, OKX, Solidly");

        _saveDeployment(networkName, address(proxy), address(impl), admin);
    }

    function _saveDeployment(
        string memory networkName,
        address proxyAddress,
        address implementationAddress,
        address admin
    ) internal {
        string memory deploymentPath = string.concat(
            "deployments/",
            networkName,
            "-",
            _toHexString(proxyAddress),
            ".json"
        );

        string memory json = "deployment";
        vm.serializeString(json, "network", networkName);
        vm.serializeUint(json, "timestamp", block.timestamp);
        vm.serializeUint(json, "blockNumber", block.number);

        string memory contractJson = "contracts";
        string memory routerJson = "HydrexMultiRouter";
        vm.serializeAddress(routerJson, "proxy", proxyAddress);
        vm.serializeAddress(routerJson, "implementation", implementationAddress);
        vm.serializeAddress(routerJson, "admin", admin);
        string memory routerData = vm.serializeString(routerJson, "name", "HydrexMultiRouter");

        string memory contractData = vm.serializeString(contractJson, "HydrexMultiRouter", routerData);
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

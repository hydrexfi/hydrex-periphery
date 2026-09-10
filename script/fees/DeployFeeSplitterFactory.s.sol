// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {HydrexFeeSplitterFactory} from "../../contracts/fees/HydrexFeeSplitterFactory.sol";

/**
 * @title DeployFeeSplitterFactory
 * @notice Deploys the HydrexFeeSplitterFactory. Everything is hardcoded below except the
 *         deployer key, which comes from DEPLOYER_KEY.
 * @dev After deploying:
 *        1. FACTORY_OWNER calls `acceptOwnership()` (Ownable2Step).
 *        2. Call `createSplitters(pools)` with the Algebra pools to wire. Permissionless, so the
 *           deployer or anyone can send it. Re-runnable: pools that already have one are skipped.
 *        3. Have the Algebra pools administrator call `setCommunityVault(splitter)` on each pool.
 *           `predictSplitter(pool)` gives the address before step 2, so the Safe batch for this
 *           step can be built ahead of time.
 *        4. Sweep on a schedule with `splitRange(start, count)`.
 */
contract DeployFeeSplitterFactory is Script {
    /* ---------------------------- CONFIGURATION ---------------------------- */

    string internal constant NETWORK = "base";

    /// @dev Hydrex VoterV5 on Base
    address internal constant VOTER = 0xc69E3eF39E3fFBcE2A1c570f8d3ADF76909ef17b;

    /// @dev Algebra Integral factory on Base; every managed pool must report this as `factory()`
    address internal constant ALGEBRA_FACTORY = 0x36077D39cdC65E1e3FB65810430E5b2c4D5fA29E;

    /// @dev Algebra's cut of community fees, in basis points. 150 = 1.5%.
    uint16 internal constant ALGEBRA_FEE_BPS = 150;

    /// @dev Receives Algebra's 1.5% share
    address internal constant ALGEBRA_FEE_RECIPIENT = 0x6cbd743d9b97DA1855E64893D3226F8eDCa16e76;

    /// @dev Receives the primary share for pools that have no gauge yet
    address internal constant FALLBACK_PRIMARY_RECIPIENT = 0x74266f2b206D1359B83fc74949EF07176FB3AE03;

    /// @dev Ends up owning the factory. Ownable2Step, so it must call `acceptOwnership()`.
    ///      Same address as the Algebra factory owner, so one signer covers both sides of the
    ///      migration: `createSplitters` here and `setCommunityVault` on the pools.
    address internal constant FACTORY_OWNER = 0x74266f2b206D1359B83fc74949EF07176FB3AE03;

    /* -------------------------------- RUN ---------------------------------- */

    function run() public {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(deployerKey);

        console2.log("=== HydrexFeeSplitterFactory Deployment ===");
        console2.log("Network:                ", NETWORK);
        console2.log("Deployer:               ", deployer);
        console2.log("Voter:                  ", VOTER);
        console2.log("Algebra factory:        ", ALGEBRA_FACTORY);
        console2.log("Algebra fee recipient:  ", ALGEBRA_FEE_RECIPIENT);
        console2.log("Algebra fee bps:        ", ALGEBRA_FEE_BPS);
        console2.log("Fallback primary:       ", FALLBACK_PRIMARY_RECIPIENT);
        console2.log("Factory owner:          ", FACTORY_OWNER);

        vm.startBroadcast(deployerKey);

        HydrexFeeSplitterFactory factory = new HydrexFeeSplitterFactory(
            VOTER,
            ALGEBRA_FACTORY,
            ALGEBRA_FEE_RECIPIENT,
            ALGEBRA_FEE_BPS,
            FALLBACK_PRIMARY_RECIPIENT
        );

        if (FACTORY_OWNER != deployer) factory.transferOwnership(FACTORY_OWNER);

        vm.stopBroadcast();

        console2.log("\n=== Deployment Successful ===");
        console2.log("HydrexFeeSplitterFactory:", address(factory));
        if (FACTORY_OWNER != deployer) {
            console2.log("Ownership transfer started. FACTORY_OWNER must call acceptOwnership().");
        }

        _saveDeployment(address(factory));
    }

    function _saveDeployment(address factoryAddress) internal {
        string memory path = string.concat(
            "deployments/",
            NETWORK,
            "-HydrexFeeSplitterFactory-",
            vm.toLowercase(vm.toString(factoryAddress)),
            ".json"
        );

        string memory entry = "HydrexFeeSplitterFactory";
        vm.serializeAddress(entry, "address", factoryAddress);
        vm.serializeAddress(entry, "voter", VOTER);
        vm.serializeAddress(entry, "algebraFactory", ALGEBRA_FACTORY);
        vm.serializeAddress(entry, "defaultSecondaryRecipient", ALGEBRA_FEE_RECIPIENT);
        vm.serializeUint(entry, "defaultSecondaryShareBps", ALGEBRA_FEE_BPS);
        vm.serializeAddress(entry, "fallbackPrimaryRecipient", FALLBACK_PRIMARY_RECIPIENT);
        string memory entryData = vm.serializeAddress(entry, "owner", FACTORY_OWNER);

        string memory json = "deployment";
        vm.serializeString(json, "network", NETWORK);
        vm.serializeUint(json, "timestamp", block.timestamp);
        vm.serializeUint(json, "blockNumber", block.number);

        string memory contractsJson = "contracts";
        string memory contractData = vm.serializeString(contractsJson, "HydrexFeeSplitterFactory", entryData);
        string memory finalJson = vm.serializeString(json, "contracts", contractData);

        vm.writeFile(path, finalJson);
        console2.log("Deployment saved to:", path);
    }
}

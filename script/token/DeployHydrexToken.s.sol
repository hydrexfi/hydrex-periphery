// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {HydrexToken} from "../../contracts/token/HydrexToken.sol";

contract DeployHydrexToken is Script {
    function run() public {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(deployerKey);
        address owner = vm.envAddress("TREASURY");

        string memory name = "Hydrex";
        string memory symbol = "HYDX";

        console2.log("Deployer:", deployer);
        console2.log("Owner:", owner);
        console2.log("Mining for vanity address starting with 00000...");

        // Mine for vanity address
        bytes32 salt = mineVanityAddress(name, symbol, owner);

        bytes memory bytecode = abi.encodePacked(type(HydrexToken).creationCode, abi.encode(name, symbol, owner));

        address predictedAddress = vm.computeCreate2Address(salt, keccak256(bytecode));
        console2.log("Found vanity address:", predictedAddress);
        console2.log("Using salt:", vm.toString(salt));

        vm.startBroadcast(deployerKey);

        // Deploy HydrexToken using the mined salt
        HydrexToken hydrexToken = new HydrexToken{salt: salt}(name, symbol, owner);
        console2.log("HydrexToken deployed at:", address(hydrexToken));

        // Verify the address matches
        require(address(hydrexToken) == predictedAddress, "Address mismatch");

        vm.stopBroadcast();

        console2.log("=== Deployment Complete ===");
        console2.log("HydrexToken:", address(hydrexToken));
        console2.log("Owner:", hydrexToken.owner());
        console2.log("Salt used:", vm.toString(salt));
        console2.log("Note: Owner needs to call initialMint() to mint initial tokens");
    }

    function mineVanityAddress(
        string memory name,
        string memory symbol,
        address owner
    ) internal view returns (bytes32) {
        bytes memory bytecode = abi.encodePacked(type(HydrexToken).creationCode, abi.encode(name, symbol, owner));
        bytes32 bytecodeHash = keccak256(bytecode);

        uint256 attempts = 0;
        uint256 maxAttempts = 1000000; // Higher limit for 5 zeros

        for (uint256 i = 0; i < maxAttempts; i++) {
            bytes32 salt = bytes32(i);
            address predicted = vm.computeCreate2Address(salt, bytecodeHash);
            attempts++;

            // Check if address starts with 00000 (first 5 hex digits = 20 bits)
            if (uint160(predicted) >> 140 == 0) {
                console2.log("Found after", attempts, "attempts");
                return salt;
            }

            // Log progress every 5k attempts
            if (attempts % 5000 == 0) {
                console2.log("Attempts:", attempts);
            }
        }

        console2.log("Could not find vanity address after", maxAttempts, "attempts");
        console2.log("Using random salt instead");
        return bytes32(block.timestamp);
    }
}

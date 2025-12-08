# LiquidAccountConduitMulti - Distributor Examples

The `LiquidAccountConduitMulti` contract supports arbitrary external distributor calls through its generalized interface. Here are examples of how to use different types of distributors:

## Interface

```solidity
function claimExerciseAndMerge(
    address[] calldata _gauges,
    address _user,
    uint256 _mergeToTokenId,
    address[] calldata _distributorTargets,  // Array of distributor contract addresses
    bytes[] calldata _distributorCalldata     // Array of encoded function calls
) external onlyRole(EXECUTOR_ROLE)
```

## Example 1: Merkl Distributor

```solidity
// Prepare Merkl claim data
address[] memory users = new address[](1);
users[0] = userAddress;

address[] memory tokens = new address[](1);
tokens[0] = optionsTokenAddress;

uint256[] memory amounts = new uint256[](1);
amounts[0] = 1000000000000000000; // Amount from Merkl tree

bytes32[][] memory proofs = new bytes32[][](1);
proofs[0] = merkleProof; // Your merkle proof array

// Encode the Merkl claim call
bytes memory merklCalldata = abi.encodeWithSignature(
    "claim(address[],address[],uint256[],bytes32[][])",
    users,
    tokens,
    amounts,
    proofs
);

// Set up distributor arrays
address[] memory distributorTargets = new address[](1);
distributorTargets[0] = merklDistributorAddress;

bytes[] memory distributorCalldata = new bytes[](1);
distributorCalldata[0] = merklCalldata;

// Call the conduit
conduit.claimExerciseAndMerge(
    gauges,
    userAddress,
    mergeToTokenId,
    distributorTargets,
    distributorCalldata
);
```

## Example 2: Multiple Distributors

You can claim from multiple distributors in a single transaction:

```solidity
// Prepare calls for 2 different distributors
address[] memory distributorTargets = new address[](2);
distributorTargets[0] = merklDistributorAddress;
distributorTargets[1] = anotherDistributorAddress;

bytes[] memory distributorCalldata = new bytes[](2);

// Merkl claim
distributorCalldata[0] = abi.encodeWithSignature(
    "claim(address[],address[],uint256[],bytes32[][])",
    users1, tokens1, amounts1, proofs1
);

// Another distributor with different interface
distributorCalldata[1] = abi.encodeWithSignature(
    "claimRewards(address,uint256)",
    userAddress,
    rewardAmount
);

conduit.claimExerciseAndMerge(
    gauges,
    userAddress,
    mergeToTokenId,
    distributorTargets,
    distributorCalldata
);
```

## Example 3: No External Distributors (Gauges Only)

If you only want to claim from gauges:

```solidity
// Empty arrays for distributors
address[] memory distributorTargets = new address[](0);
bytes[] memory distributorCalldata = new bytes[](0);

conduit.claimExerciseAndMerge(
    gauges,
    userAddress,
    mergeToTokenId,
    distributorTargets,
    distributorCalldata
);
```

## Example 4: Custom Reward Contract

```solidity
// For a custom contract with signature: claimFor(address beneficiary, address token)
bytes memory customCalldata = abi.encodeWithSignature(
    "claimFor(address,address)",
    userAddress,
    optionsTokenAddress
);

address[] memory distributorTargets = new address[](1);
distributorTargets[0] = customRewardContractAddress;

bytes[] memory distributorCalldata = new bytes[](1);
distributorCalldata[0] = customCalldata;

conduit.claimExerciseAndMerge(
    gauges,
    userAddress,
    mergeToTokenId,
    distributorTargets,
    distributorCalldata
);
```

## Important Notes

1. **Operator Approval**: For Merkl and some other distributors, you may need to call `toggleOperator(user, conduitAddress)` to authorize the conduit to claim on behalf of the user.

2. **Balance Tracking**: The contract tracks option token balance before and after each distributor call to emit accurate events.

3. **Failed Calls**: If any distributor call fails, the entire transaction reverts with `DistributorCallFailed()` error.

4. **Gas Considerations**: Each distributor call adds gas cost. Be mindful when claiming from many distributors in one transaction.


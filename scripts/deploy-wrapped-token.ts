/**
 * Deploy a CrossChainERC20 (wrapped SPL token) on Base via the factory.
 *
 * Usage:
 *   npx tsx scripts/deploy-wrapped-token.ts
 *
 * Required env vars:
 *   BASE_RPC_URL          — Base mainnet RPC
 *   DEPLOYER_KEY          — Private key (hex, with 0x prefix)
 *   SPL_MINT_ADDRESS      — Solana SPL token mint (base58)
 *   WRAPPED_TOKEN_NAME    — e.g. "Wrapped BONK"
 *   WRAPPED_TOKEN_SYMBOL  — e.g. "wBONK"
 *   SPL_DECIMALS          — Decimal places of the SPL token (must match exactly)
 */

import {
  createWalletClient,
  createPublicClient,
  http,
  parseAbi,
  parseAbiItem,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { base } from "viem/chains";
import "dotenv/config";

const FACTORY = "0xDD56781d0509650f8C2981231B6C917f2d5d7dF2" as const;

const factoryAbi = parseAbi([
  "function deploy(bytes32 remoteToken, string name, string symbol, uint8 decimals) returns (address)",
  "function isCrossChainErc20(address token) view returns (bool)",
  "event CrossChainERC20Created(address indexed localToken, bytes32 indexed remoteToken, address deployer)",
]);

const createdEvent = parseAbiItem(
  "event CrossChainERC20Created(address indexed localToken, bytes32 indexed remoteToken, address deployer)"
);

// Base58 alphabet
const BASE58_ALPHABET =
  "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

function base58ToBytes(b58: string): Uint8Array {
  const bytes: number[] = [];
  for (const char of b58) {
    const idx = BASE58_ALPHABET.indexOf(char);
    if (idx === -1) throw new Error(`Invalid base58 char: ${char}`);
    let carry = idx;
    for (let j = 0; j < bytes.length; j++) {
      carry += bytes[j] * 58;
      bytes[j] = carry & 0xff;
      carry >>= 8;
    }
    while (carry > 0) {
      bytes.push(carry & 0xff);
      carry >>= 8;
    }
  }
  // Leading zeros
  for (const char of b58) {
    if (char !== "1") break;
    bytes.push(0);
  }
  return new Uint8Array(bytes.reverse());
}

function splMintToBytes32(mint: string): Hex {
  const raw = base58ToBytes(mint);
  // Pad to 32 bytes (left-pad with zeros)
  const padded = new Uint8Array(32);
  padded.set(raw, 32 - raw.length);
  return ("0x" + Buffer.from(padded).toString("hex")) as Hex;
}

async function main() {
  const rpcUrl = process.env.BASE_RPC_URL;
  const privKey = process.env.DEPLOYER_KEY as Hex;
  const splMint = process.env.SPL_MINT_ADDRESS!;
  const tokenName = process.env.WRAPPED_TOKEN_NAME!;
  const tokenSymbol = process.env.WRAPPED_TOKEN_SYMBOL!;
  const decimals = parseInt(process.env.SPL_DECIMALS!);

  if (!rpcUrl || !privKey || !splMint || !tokenName || !tokenSymbol || isNaN(decimals)) {
    console.error(
      "Missing env vars. Need: BASE_RPC_URL, DEPLOYER_KEY, SPL_MINT_ADDRESS, WRAPPED_TOKEN_NAME, WRAPPED_TOKEN_SYMBOL, SPL_DECIMALS"
    );
    process.exit(1);
  }

  const account = privateKeyToAccount(privKey);
  const publicClient = createPublicClient({ chain: base, transport: http(rpcUrl) });
  const walletClient = createWalletClient({ account, chain: base, transport: http(rpcUrl) });

  const mintBytes32 = splMintToBytes32(splMint);
  console.log("SPL Mint:       ", splMint);
  console.log("Mint bytes32:   ", mintBytes32);

  // If WRAPPED_TOKEN_ADDRESS is already set, verify it and skip deployment
  const knownAddress = process.env.WRAPPED_TOKEN_ADDRESS as Hex | undefined;
  if (knownAddress) {
    const isValid = await publicClient.readContract({
      address: FACTORY,
      abi: factoryAbi,
      functionName: "isCrossChainErc20",
      args: [knownAddress],
    });
    if (isValid) {
      console.log("Wrapped token already deployed at:", knownAddress);
      return;
    }
    console.warn(`WRAPPED_TOKEN_ADDRESS ${knownAddress} is not a valid CrossChainERC20 — deploying fresh.`);
  }

  console.log(`Deploying ${tokenName} (${tokenSymbol}) with ${decimals} decimals...`);

  const hash = await walletClient.writeContract({
    address: FACTORY,
    abi: factoryAbi,
    functionName: "deploy",
    args: [mintBytes32, tokenName, tokenSymbol, decimals],
  });

  console.log("Deploy tx:", hash);
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  console.log("Status:", receipt.status);

  const deployLogs = await publicClient.getLogs({
    address: FACTORY,
    event: createdEvent,
    args: { remoteToken: mintBytes32 },
    blockHash: receipt.blockHash,
  });

  const deployed = deployLogs[0]?.args.localToken;
  console.log("Wrapped token deployed at:", deployed);
}

main().catch(console.error);

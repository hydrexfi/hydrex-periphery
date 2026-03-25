/**
 * End-to-end intent swap: create intent on Base → bridge BONK from Solana → wait for fill.
 *
 * Phase 1 (Base): approve USDC + createIntent
 * Phase 2 (Solana): bridge BONK with fill() calldata
 * Phase 3 (Monitor): wait for IntentFilled event, report latency
 *
 * Usage:
 *   npx tsx scripts/e2e-swap.ts
 *
 * Required env vars (already in .env):
 *   BASE_RPC_URL             — Base mainnet RPC
 *   DEPLOYER_KEY             — 0x-prefixed EVM private key (intent creator + default solver recipient)
 *   AUCTION_ROUTER_ADDRESS   — HydrexMultichainAuctionRouter on Base
 *   USDC_TOKEN               — USDC address on Base
 *   SOLANA_RPC_URL           — Solana mainnet RPC
 *   SOLANA_PRIVATE_KEY       — Solana wallet private key (base58, holds BONK)
 *   SPL_MINT_ADDRESS         — BONK mint address
 *   WRAPPED_TOKEN_ADDRESS    — Wrapped BONK ERC20 on Base
 *
 * Optional (with defaults):
 *   SPL_DECIMALS             — BONK decimals (default: 5, read on-chain)
 *   BRIDGE_AMOUNT            — Raw BONK units before decimal scaling (default: 1000)
 *   INPUT_AMOUNT             — USDC in 6-decimal units (default: 100000 = 0.1 USDC)
 *   DESIRED_OUTPUT           — Raw wBONK wanted (default: BRIDGE_AMOUNT × 10^decimals)
 *   MIN_OUTPUT               — Floor wBONK (default: 90% of desiredOutput)
 *   AUCTION_SECONDS          — Auction duration in seconds (default: 300)
 *   INPUT_RECIPIENT          — Solver's Base address to receive USDC (default: DEPLOYER_KEY address)
 *   RELAY_GAS_LIMIT          — Bridge relay gas limit (default: 400000)
 *   FILL_TIMEOUT_MS          — How long to wait for fill before giving up (default: 300000 = 5 min)
 */

// ─── EVM imports ─────────────────────────────────────────────────────────────

import {
  createPublicClient,
  createWalletClient,
  http,
  parseAbi,
  parseEventLogs,
  maxUint256,
  type Hex,
  type Address,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { base } from "viem/chains";

// ─── Solana imports ───────────────────────────────────────────────────────────

import {
  address,
  createKeyPairSignerFromBytes,
  createSolanaRpc,
  createSolanaRpcSubscriptions,
  getProgramDerivedAddress,
  appendTransactionMessageInstructions,
  createTransactionMessage,
  getSignatureFromTransaction,
  pipe,
  sendAndConfirmTransactionFactory,
  setTransactionMessageFeePayer,
  setTransactionMessageLifetimeUsingBlockhash,
  signTransactionMessageWithSigners,
  assertIsSendableTransaction,
  assertIsTransactionWithBlockhashLifetime,
  fetchEncodedAccount,
  getBase58Encoder,
  type Address as SolanaAddress,
  type Instruction,
} from "@solana/kit";
import { addSignersToTransactionMessage } from "@solana/kit";
import {
  findAssociatedTokenPda,
  fetchMaybeMint,
  fetchMaybeToken,
  TOKEN_PROGRAM_ADDRESS,
} from "@solana-program/token";
import { SYSTEM_PROGRAM_ADDRESS } from "@solana-program/system";
import { encodeFunctionData, toBytes } from "viem";
import bs58 from "bs58";
import "dotenv/config";

// ─── Solana constants ─────────────────────────────────────────────────────────

const BRIDGE_PROGRAM = address("HNCne2FkVaNghhjKXapxJzPaBvAKDG1Ge3gqhZyfVWLM");
const RELAYER_PROGRAM = address("g1et5VenhfJHJwsdJsDbxWZuotD5H4iELNG61kS4fb9");

const BRIDGE_SEED       = Buffer.from("bridge");
const OUTGOING_MSG_SEED = Buffer.from("outgoing_message");
const TOKEN_VAULT_SEED  = Buffer.from("token_vault");
const CFG_SEED          = Buffer.from("config");
const MTR_SEED          = Buffer.from("mtr");

const BRIDGE_GAS_FEE_RECEIVER_OFFSET  = 129;
const RELAYER_GAS_FEE_RECEIVER_OFFSET = 8 + 8 + 32 + 56 + 32;

const BRIDGE_SPL_DISC    = new Uint8Array([87, 109, 172, 103, 8, 187, 223, 126]);
const PAY_FOR_RELAY_DISC = new Uint8Array([41, 191, 218, 201, 250, 164, 156, 55]);

// ─── ABIs ─────────────────────────────────────────────────────────────────────

const erc20Abi = parseAbi([
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
  "function decimals() view returns (uint8)",
]);

const routerAbi = parseAbi([
  "function createIntent(address inputToken, uint256 inputAmount, address outputToken, uint256 desiredOutput, uint256 minOutput, uint64 auctionSeconds, address recipient) returns (bytes32 intentId)",
  "function currentRequiredOutput(bytes32 intentId) view returns (uint256)",
  "event IntentCreated(bytes32 indexed intentId, address indexed user, address inputToken, uint256 inputAmount, address outputToken, uint256 desiredOutput, uint256 minOutput, uint64 auctionSeconds, address recipient, uint64 startTime)",
  "event IntentFilled(bytes32 indexed intentId, address indexed filler, uint256 outputAmount, uint256 requiredAtFill, address inputRecipient)",
]);

const bridgeFillAbi = parseAbi([
  "function fill(bytes32 intentId, uint256 outputAmount, address inputRecipient)",
]);

// ─── Solana helpers ───────────────────────────────────────────────────────────

function writeU32LE(n: number): Buffer {
  const b = Buffer.alloc(4);
  b.writeUInt32LE(n);
  return b;
}

function writeU64LE(n: bigint): Buffer {
  const b = Buffer.alloc(8);
  b.writeBigUInt64LE(n);
  return b;
}

function writeU128LE(n: bigint): Buffer {
  const b = Buffer.alloc(16);
  b.writeBigUInt64LE(n & 0xffffffffffffffffn, 0);
  b.writeBigUInt64LE(n >> 64n, 8);
  return b;
}

function encodeBridgeSplData(
  salt: Uint8Array,
  to: Uint8Array,
  remoteToken: Uint8Array,
  amount: bigint,
  call: { target: Uint8Array; callData: Uint8Array; value: bigint } | null
): Buffer {
  const parts: Buffer[] = [
    Buffer.from(BRIDGE_SPL_DISC),
    Buffer.from(salt),
    Buffer.from(to),
    Buffer.from(remoteToken),
    writeU64LE(amount),
  ];
  if (call === null) {
    parts.push(Buffer.from([0x00]));
  } else {
    parts.push(Buffer.from([0x01]));
    parts.push(Buffer.from([0x00])); // CallType::Call
    parts.push(Buffer.from(call.target));
    parts.push(writeU128LE(call.value));
    parts.push(writeU32LE(call.callData.length));
    parts.push(Buffer.from(call.callData));
  }
  return Buffer.concat(parts);
}

function encodePayForRelayData(
  mtrSalt: Uint8Array,
  outgoingMessagePubkey: SolanaAddress,
  gasLimit: bigint
): Buffer {
  const pubkeyBytes = getBase58Encoder().encode(outgoingMessagePubkey);
  return Buffer.concat([
    Buffer.from(PAY_FOR_RELAY_DISC),
    Buffer.from(mtrSalt),
    Buffer.from(pubkeyBytes),
    writeU64LE(gasLimit),
  ]);
}

async function randomSaltPda(
  program: SolanaAddress,
  seedPrefix: Buffer
): Promise<{ salt: Uint8Array; pubkey: SolanaAddress }> {
  const salt = crypto.getRandomValues(new Uint8Array(32));
  const [pubkey] = await getProgramDerivedAddress({
    programAddress: program,
    seeds: [seedPrefix, Buffer.from(salt)],
  });
  return { salt, pubkey };
}

async function readGasFeeReceiver(
  rpc: ReturnType<typeof createSolanaRpc>,
  account: SolanaAddress,
  offset: number
): Promise<SolanaAddress> {
  const encoded = await fetchEncodedAccount(rpc, account);
  if (!encoded.exists) throw new Error(`Account ${account} not found`);
  return address(bs58.encode(Buffer.from(encoded.data).slice(offset, offset + 32)));
}

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  // ── Config ──────────────────────────────────────────────────────────────────
  const baseRpcUrl      = process.env.BASE_RPC_URL!;
  const deployerKey     = process.env.DEPLOYER_KEY as Hex;
  const routerAddr      = process.env.AUCTION_ROUTER_ADDRESS as Address;
  const usdcAddr        = (process.env.USDC_TOKEN || "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913") as Address;
  const solanaRpc       = process.env.SOLANA_RPC_URL!;
  const solanaKeyB58    = process.env.SOLANA_PRIVATE_KEY!;
  const splMint         = process.env.SPL_MINT_ADDRESS!;
  const wrappedToken    = process.env.WRAPPED_TOKEN_ADDRESS as Hex;
  const bridgeAmountRaw = BigInt(process.env.BRIDGE_AMOUNT || "1000");
  const inputAmount     = BigInt(process.env.INPUT_AMOUNT || "100000"); // 0.1 USDC
  const auctionSeconds  = BigInt(process.env.AUCTION_SECONDS || "300"); // 5 min
  const relayGasLimit   = BigInt(process.env.RELAY_GAS_LIMIT || "400000");
  const fillTimeoutMs   = parseInt(process.env.FILL_TIMEOUT_MS || "300000");

  if (!baseRpcUrl || !deployerKey || !routerAddr || !solanaRpc || !solanaKeyB58 || !splMint || !wrappedToken) {
    console.error("Missing required env vars. Check BASE_RPC_URL, DEPLOYER_KEY, AUCTION_ROUTER_ADDRESS, SOLANA_*, SPL_MINT_ADDRESS, WRAPPED_TOKEN_ADDRESS");
    process.exit(1);
  }

  // ── EVM clients ──────────────────────────────────────────────────────────────
  const account      = privateKeyToAccount(deployerKey);
  const publicClient = createPublicClient({ chain: base, transport: http(baseRpcUrl) });
  const walletClient = createWalletClient({ chain: base, account, transport: http(baseRpcUrl) });

  // Default: solver (input recipient) = same address as the intent creator
  const inputRecipient = (process.env.INPUT_RECIPIENT || account.address) as Address;

  // ── Solana setup ─────────────────────────────────────────────────────────────
  const payer = await createKeyPairSignerFromBytes(bs58.decode(solanaKeyB58));

  // Read BONK decimals on-chain
  const mintAddress = address(splMint);
  const rpcHostName = solanaRpc.replace(/^https?:\/\//, "");
  const solRpc = createSolanaRpc(`https://${rpcHostName}`);
  const solRpcSub = createSolanaRpcSubscriptions(`wss://${rpcHostName}`);

  const maybeMint = await fetchMaybeMint(solRpc, mintAddress);
  if (!maybeMint.exists) throw new Error(`Mint ${splMint} not found on Solana`);
  const splDecimals = maybeMint.data.decimals;
  const scaledAmount = bridgeAmountRaw * BigInt(10 ** splDecimals);

  const desiredOutput = BigInt(process.env.DESIRED_OUTPUT || String(scaledAmount));
  const minOutput     = BigInt(process.env.MIN_OUTPUT || String((desiredOutput * 90n) / 100n));

  // ── Summary ──────────────────────────────────────────────────────────────────
  console.log("╔══════════════════════════════════════════════════════════╗");
  console.log("║         Hydrex E2E Swap Test                             ║");
  console.log("╚══════════════════════════════════════════════════════════╝");
  console.log();
  console.log("📋 Intent (Base)");
  console.log(`   EVM wallet:        ${account.address}`);
  console.log(`   Input:             ${Number(inputAmount) / 1e6} USDC (${inputAmount} raw)`);
  console.log(`   Output token:      ${wrappedToken} (wBONK)`);
  console.log(`   Desired output:    ${desiredOutput} raw wBONK  (${Number(desiredOutput) / 10 ** splDecimals} BONK)`);
  console.log(`   Min output:        ${minOutput} raw wBONK  (${Number(minOutput) / 10 ** splDecimals} BONK)`);
  console.log(`   Auction duration:  ${auctionSeconds}s`);
  console.log(`   Recipient:         ${account.address}`);
  console.log();
  console.log("🌉 Bridge (Solana → Base)");
  console.log(`   Solana wallet:     ${payer.address}`);
  console.log(`   BONK decimals:     ${splDecimals} (on-chain)`);
  console.log(`   Bridge amount:     ${bridgeAmountRaw} raw × 10^${splDecimals} = ${scaledAmount}`);
  console.log(`   Input recipient:   ${inputRecipient}  ← gets the USDC`);
  console.log(`   Relay gas limit:   ${relayGasLimit}`);
  console.log();

  // ═══════════════════════════════════════════════════════════════════
  // PHASE 1: Create intent on Base
  // ═══════════════════════════════════════════════════════════════════

  console.log("━━━ Phase 1: Create Intent ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");

  // Check USDC balance
  const usdcBalance = await publicClient.readContract({
    address: usdcAddr, abi: erc20Abi, functionName: "balanceOf", args: [account.address],
  });
  console.log(`USDC balance: ${Number(usdcBalance) / 1e6} USDC`);
  if (usdcBalance < inputAmount) {
    throw new Error(`Insufficient USDC: have ${usdcBalance}, need ${inputAmount}`);
  }

  // Approve if needed
  const allowance = await publicClient.readContract({
    address: usdcAddr, abi: erc20Abi, functionName: "allowance",
    args: [account.address, routerAddr],
  });
  if (allowance < inputAmount) {
    console.log("Approving USDC...");
    const approveTx = await walletClient.writeContract({
      address: usdcAddr, abi: erc20Abi, functionName: "approve",
      args: [routerAddr, maxUint256],
    });
    await publicClient.waitForTransactionReceipt({ hash: approveTx });
    console.log(`Approved: ${approveTx}`);
  } else {
    console.log("USDC already approved ✓");
  }

  // createIntent
  console.log("Calling createIntent...");
  const createTxHash = await walletClient.writeContract({
    address: routerAddr,
    abi: routerAbi,
    functionName: "createIntent",
    args: [
      usdcAddr,
      inputAmount,
      wrappedToken as Address,
      desiredOutput,
      minOutput,
      auctionSeconds,
      account.address,
    ],
  });

  const createReceipt = await publicClient.waitForTransactionReceipt({ hash: createTxHash });
  if (createReceipt.status !== "success") throw new Error("createIntent tx reverted");

  // Parse intentId from logs
  const intentCreatedLogs = parseEventLogs({
    abi: routerAbi,
    eventName: "IntentCreated",
    logs: createReceipt.logs,
  });
  if (intentCreatedLogs.length === 0) throw new Error("IntentCreated event not found in receipt");
  const intentId = intentCreatedLogs[0].args.intentId as Hex;

  console.log();
  console.log(`✅ Intent created!`);
  console.log(`   Intent ID:   ${intentId}`);
  console.log(`   Tx:          ${createTxHash}`);
  console.log(`   Block:       ${createReceipt.blockNumber}`);
  console.log();

  const t0 = Date.now();

  // ═══════════════════════════════════════════════════════════════════
  // PHASE 2: Set up fill watcher before bridging
  // ═══════════════════════════════════════════════════════════════════

  console.log("━━━ Phase 2: Monitoring for fill ━━━━━━━━━━━━━━━━━━━━━━━━");
  console.log("Starting Base event watcher...");

  let fillResolve: (v: { outputAmount: bigint; txHash: Hex; blockNumber: bigint }) => void;
  let fillReject: (e: Error) => void;
  const fillPromise = new Promise<{ outputAmount: bigint; txHash: Hex; blockNumber: bigint }>(
    (res, rej) => { fillResolve = res; fillReject = rej; }
  );

  const unwatch = publicClient.watchEvent({
    address: routerAddr,
    event: routerAbi[3], // IntentFilled
    onLogs: (logs) => {
      for (const log of logs) {
        if (log.args.intentId?.toLowerCase() === intentId.toLowerCase()) {
          fillResolve!({
            outputAmount: log.args.outputAmount ?? 0n,
            txHash: log.transactionHash!,
            blockNumber: log.blockNumber!,
          });
        }
      }
    },
    onError: (err) => console.error("Watcher error:", err.message),
  });

  // Timeout guard
  const timeoutHandle = setTimeout(() => {
    unwatch();
    fillReject(new Error(`Fill not received within ${fillTimeoutMs / 1000}s`));
  }, fillTimeoutMs);

  // ═══════════════════════════════════════════════════════════════════
  // PHASE 3: Bridge BONK from Solana
  // ═══════════════════════════════════════════════════════════════════

  console.log();
  console.log("━━━ Phase 3: Bridge from Solana ━━━━━━━━━━━━━━━━━━━━━━━━");

  // Verify ATA balance
  const [ataAddress] = await findAssociatedTokenPda({
    owner: payer.address,
    tokenProgram: maybeMint.programAddress,
    mint: mintAddress,
  });
  const maybeAta = await fetchMaybeToken(solRpc, ataAddress);
  if (!maybeAta.exists) throw new Error(`ATA not found: ${ataAddress}. Fund your BONK wallet first.`);
  console.log(`ATA balance: ${maybeAta.data.amount} (need ${scaledAmount})`);
  if (maybeAta.data.amount < scaledAmount) {
    throw new Error(`Insufficient BONK: have ${maybeAta.data.amount}, need ${scaledAmount}`);
  }

  // PDAs
  const [bridgeAccountAddress] = await getProgramDerivedAddress({
    programAddress: BRIDGE_PROGRAM, seeds: [BRIDGE_SEED],
  });
  const mintBytes        = getBase58Encoder().encode(mintAddress);
  const remoteTokenBytes = toBytes(wrappedToken);
  const [tokenVaultAddress] = await getProgramDerivedAddress({
    programAddress: BRIDGE_PROGRAM,
    seeds: [TOKEN_VAULT_SEED, Buffer.from(mintBytes), Buffer.from(remoteTokenBytes)],
  });
  const { salt: outgoingMsgSalt, pubkey: outgoingMessage } =
    await randomSaltPda(BRIDGE_PROGRAM, OUTGOING_MSG_SEED);

  const bridgeGasFeeReceiver = await readGasFeeReceiver(solRpc, bridgeAccountAddress, BRIDGE_GAS_FEE_RECEIVER_OFFSET);

  // Encode fill() calldata
  const evmCallData = encodeFunctionData({
    abi: bridgeFillAbi,
    functionName: "fill",
    args: [intentId, scaledAmount, inputRecipient],
  });

  const routerBytes = toBytes(routerAddr as Hex);
  const bridgeSplData = encodeBridgeSplData(
    outgoingMsgSalt,
    routerBytes,
    remoteTokenBytes,
    scaledAmount,
    {
      target:   routerBytes,
      callData: Buffer.from(evmCallData.slice(2), "hex"),
      value:    0n,
    }
  );

  const bridgeSplIx: Instruction = {
    programAddress: BRIDGE_PROGRAM,
    accounts: [
      { address: payer.address,        role: 3 },
      { address: payer.address,        role: 3 },
      { address: bridgeGasFeeReceiver, role: 1 },
      { address: mintAddress,          role: 1 },
      { address: ataAddress,           role: 1 },
      { address: bridgeAccountAddress, role: 1 },
      { address: tokenVaultAddress,    role: 1 },
      { address: outgoingMessage,      role: 1 },
      { address: TOKEN_PROGRAM_ADDRESS,  role: 0 },
      { address: SYSTEM_PROGRAM_ADDRESS, role: 0 },
    ],
    data: new Uint8Array(bridgeSplData),
  };

  const ixs: Instruction[] = [bridgeSplIx];

  // pay_for_relay
  const [cfgAddress] = await getProgramDerivedAddress({
    programAddress: RELAYER_PROGRAM, seeds: [CFG_SEED],
  });
  const relayerGasFeeReceiver = await readGasFeeReceiver(solRpc, cfgAddress, RELAYER_GAS_FEE_RECEIVER_OFFSET);
  const { salt: mtrSalt, pubkey: mtrPubkey } = await randomSaltPda(RELAYER_PROGRAM, MTR_SEED);

  const payForRelayData = encodePayForRelayData(mtrSalt, outgoingMessage, relayGasLimit);
  const payForRelayIx: Instruction = {
    programAddress: RELAYER_PROGRAM,
    accounts: [
      { address: payer.address,          role: 3 },
      { address: cfgAddress,             role: 1 },
      { address: relayerGasFeeReceiver,  role: 1 },
      { address: mtrPubkey,              role: 1 },
      { address: SYSTEM_PROGRAM_ADDRESS, role: 0 },
    ],
    data: new Uint8Array(payForRelayData),
  };
  ixs.push(payForRelayIx);

  // Send Solana tx
  console.log("Sending bridge transaction...");
  const sendAndConfirmTx = sendAndConfirmTransactionFactory({ rpc: solRpc, rpcSubscriptions: solRpcSub });
  const blockhash = await solRpc.getLatestBlockhash().send();

  const transactionMessage = pipe(
    createTransactionMessage({ version: 0 }),
    (tx) => setTransactionMessageFeePayer(payer.address, tx),
    (tx) => setTransactionMessageLifetimeUsingBlockhash(blockhash.value, tx),
    (tx) => appendTransactionMessageInstructions(ixs, tx),
    (tx) => addSignersToTransactionMessage([payer], tx)
  );

  const signedTx  = await signTransactionMessageWithSigners(transactionMessage);
  const signature = getSignatureFromTransaction(signedTx);

  assertIsSendableTransaction(signedTx);
  assertIsTransactionWithBlockhashLifetime(signedTx);
  await sendAndConfirmTx(signedTx, { commitment: "confirmed" });

  const t1 = Date.now();

  console.log();
  console.log(`✅ Bridge tx sent!`);
  console.log(`   Signature:  ${signature}`);
  console.log(`   Explorer:   https://explorer.solana.com/tx/${signature}`);
  console.log(`   Intent ID:  ${intentId}`);
  console.log();
  console.log("⏳ Waiting for relayers to deliver on Base...");
  console.log("   Bridge finalization + relay typically takes 30-90s.");
  console.log();

  // ═══════════════════════════════════════════════════════════════════
  // PHASE 4: Wait for IntentFilled
  // ═══════════════════════════════════════════════════════════════════

  const fill = await fillPromise;
  clearTimeout(timeoutHandle);
  unwatch();

  const t2 = Date.now();
  const bridgeMs = t2 - t1;
  const totalMs  = t2 - t0;

  // What price did the auction settle at?
  const settledPct = desiredOutput > 0n
    ? ((Number(fill.outputAmount) / Number(desiredOutput)) * 100).toFixed(1)
    : "n/a";

  console.log("╔══════════════════════════════════════════════════════════╗");
  console.log("║         ✅  Intent Filled — E2E Complete                 ║");
  console.log("╚══════════════════════════════════════════════════════════╝");
  console.log();
  console.log(`Intent ID:          ${intentId}`);
  console.log(`Fill tx (Base):     ${fill.txHash}`);
  console.log(`Fill block:         ${fill.blockNumber}`);
  console.log(`Output paid:        ${fill.outputAmount} raw wBONK  (${Number(fill.outputAmount) / 10 ** splDecimals} BONK)`);
  console.log(`Auction settle:     ${settledPct}% of desired output`);
  console.log();
  console.log("⏱  Latency");
  console.log(`   Bridge tx → fill:   ${(bridgeMs / 1000).toFixed(1)}s`);
  console.log(`   Intent → fill:      ${(totalMs / 1000).toFixed(1)}s  (includes approval + createIntent)`);
  console.log();
  console.log(`Basescan: https://basescan.org/tx/${fill.txHash}`);
}

main().catch((err) => {
  console.error("\n❌ Error:", err.message || err);
  process.exit(1);
});

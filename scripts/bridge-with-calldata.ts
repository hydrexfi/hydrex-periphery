/**
 * Bridge SPL tokens from Solana → Base and call fill() on HydrexMultichainAuctionRouter.
 *
 * The bridge mints wrapped tokens directly to the router, then executes fill() atomically.
 * This is the canonical solver flow for cross-chain intent settlement.
 *
 * Usage:
 *   npx tsx scripts/bridge-with-calldata.ts [--no-relay]
 *
 * Required env vars:
 *   SOLANA_RPC_URL           — Solana mainnet RPC (use Helius/Triton, not public)
 *   SOLANA_PRIVATE_KEY       — Solana wallet private key (base58-encoded 64-byte keypair)
 *   SPL_MINT_ADDRESS         — SPL token mint to bridge (base58)
 *   WRAPPED_TOKEN_ADDRESS    — Wrapped ERC20 address on Base (the remoteToken)
 *   AUCTION_ROUTER_ADDRESS   — HydrexMultichainAuctionRouter address on Base
 *   INPUT_RECIPIENT          — Solver's Base address to receive input tokens (e.g. USDC)
 *   INTENT_ID                — bytes32 intent ID to fill (0x-prefixed hex, 66 chars)
 *   SPL_DECIMALS             — Decimal places of the SPL token
 *
 * Optional:
 *   BRIDGE_AMOUNT            — Raw token units to bridge before decimal scaling (default: 1000)
 *                              Must be >= currentRequiredOutput at the time fill() executes.
 *   RELAY_GAS_LIMIT          — Gas limit for Base execution (default: 400000)
 *                              If too low, tokens land in the router but fill() won't run.
 */

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
import { encodeFunctionData, parseAbi, toBytes, type Hex } from "viem";
import bs58 from "bs58";
import "dotenv/config";

// ─── Program addresses (mainnet) ─────────────────────────────────────────────

const BRIDGE_PROGRAM = address("HNCne2FkVaNghhjKXapxJzPaBvAKDG1Ge3gqhZyfVWLM");
const RELAYER_PROGRAM = address("g1et5VenhfJHJwsdJsDbxWZuotD5H4iELNG61kS4fb9");

// ─── PDA seeds (from bridge IDL constants) ───────────────────────────────────

const BRIDGE_SEED       = Buffer.from("bridge");
const OUTGOING_MSG_SEED = Buffer.from("outgoing_message");
const TOKEN_VAULT_SEED  = Buffer.from("token_vault");
const CFG_SEED          = Buffer.from("config");
const MTR_SEED          = Buffer.from("mtr");

// ─── Bridge account layout offsets (Borsh, no padding) ───────────────────────

const BRIDGE_GAS_FEE_RECEIVER_OFFSET  = 129; // verified by account scan
const RELAYER_GAS_FEE_RECEIVER_OFFSET = 8 + 8 + 32 + 56 + 32; // 136

// ─── Instruction discriminators (from IDL) ────────────────────────────────────

const BRIDGE_SPL_DISC    = new Uint8Array([87, 109, 172, 103, 8, 187, 223, 126]);
const PAY_FOR_RELAY_DISC = new Uint8Array([41, 191, 218, 201, 250, 164, 156, 55]);

// ─── Router ABI ───────────────────────────────────────────────────────────────

const routerAbi = parseAbi([
  "function fill(bytes32 intentId, uint256 outputAmount, address inputRecipient)",
]);

// ─── Encoding helpers ─────────────────────────────────────────────────────────

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

/**
 * Encode bridge_spl instruction data.
 * Layout: discriminator(8) | salt(32) | to(20) | remoteToken(20) | amount(u64) | call(option)
 */
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

/**
 * Encode pay_for_relay instruction data.
 * Layout: discriminator(8) | mtr_salt(32) | outgoing_message(32 pubkey) | gas_limit(u64)
 */
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

// ─── PDA helpers ──────────────────────────────────────────────────────────────

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
  const data = Buffer.from(encoded.data);
  return address(bs58.encode(data.slice(offset, offset + 32)));
}

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  const args       = process.argv.slice(2);
  const useRelay   = !args.includes("--no-relay");

  const solanaRpc      = process.env.SOLANA_RPC_URL!;
  const solanaKeyB58   = process.env.SOLANA_PRIVATE_KEY!;
  const splMint        = process.env.SPL_MINT_ADDRESS!;
  const wrappedToken   = process.env.WRAPPED_TOKEN_ADDRESS as Hex;
  const routerAddr     = process.env.AUCTION_ROUTER_ADDRESS as Hex;
  const inputRecipient = process.env.INPUT_RECIPIENT as Hex;
  const intentId       = process.env.INTENT_ID as Hex;
  const decimals       = parseInt(process.env.SPL_DECIMALS || "5");
  const bridgeAmount   = BigInt(process.env.BRIDGE_AMOUNT || "1000");
  const relayGasLimit  = BigInt(process.env.RELAY_GAS_LIMIT || "400000");

  if (!routerAddr || !inputRecipient || !intentId) {
    console.error("Missing required env vars: AUCTION_ROUTER_ADDRESS, INPUT_RECIPIENT, INTENT_ID");
    process.exit(1);
  }
  if (!solanaRpc || !solanaKeyB58 || !splMint || !wrappedToken) {
    console.error("Missing required env vars: SOLANA_RPC_URL, SOLANA_PRIVATE_KEY, SPL_MINT_ADDRESS, WRAPPED_TOKEN_ADDRESS");
    process.exit(1);
  }

  // ── Keypair ─────────────────────────────────────────────────────────────────
  const payer = await createKeyPairSignerFromBytes(bs58.decode(solanaKeyB58));

  console.log("=== HydrexMultichainAuctionRouter — Bridge Fill ===");
  console.log(`Payer:            ${payer.address}`);
  console.log(`SPL Mint:         ${splMint}`);
  console.log(`Wrapped Token:    ${wrappedToken}`);
  console.log(`Router:           ${routerAddr}`);
  console.log(`Intent ID:        ${intentId}`);
  console.log(`Input Recipient:  ${inputRecipient}`);
  console.log(`Bridge Amount:    ${bridgeAmount} (raw units, ×10^decimals)`);
  console.log(`Gas Limit:        ${relayGasLimit}`);
  console.log(`Auto-relay:       ${useRelay}`);
  console.log();

  const rpcHostName = solanaRpc.replace(/^https?:\/\//, "");
  const rpc = createSolanaRpc(`https://${rpcHostName}`);
  const rpcSubscriptions = createSolanaRpcSubscriptions(`wss://${rpcHostName}`);

  // ── Verify SPL mint ─────────────────────────────────────────────────────────
  const mintAddress = address(splMint);
  const maybeMint = await fetchMaybeMint(rpc, mintAddress);
  if (!maybeMint.exists) throw new Error(`Mint ${splMint} not found on-chain`);

  const onChainDecimals = maybeMint.data.decimals;
  const scaledAmount = bridgeAmount * BigInt(10 ** onChainDecimals);
  console.log(`Mint decimals:    ${onChainDecimals}`);
  console.log(`Scaled amount:    ${scaledAmount} (this must be >= currentRequiredOutput at fill time)`);

  // ── PDAs ────────────────────────────────────────────────────────────────────
  const [bridgeAccountAddress] = await getProgramDerivedAddress({
    programAddress: BRIDGE_PROGRAM,
    seeds: [BRIDGE_SEED],
  });

  const mintBytes        = getBase58Encoder().encode(mintAddress);
  const remoteTokenBytes = toBytes(wrappedToken);

  const [tokenVaultAddress] = await getProgramDerivedAddress({
    programAddress: BRIDGE_PROGRAM,
    seeds: [TOKEN_VAULT_SEED, Buffer.from(mintBytes), Buffer.from(remoteTokenBytes)],
  });

  const { salt: outgoingMsgSalt, pubkey: outgoingMessage } =
    await randomSaltPda(BRIDGE_PROGRAM, OUTGOING_MSG_SEED);

  console.log(`Bridge account:   ${bridgeAccountAddress}`);
  console.log(`Token vault:      ${tokenVaultAddress}`);
  console.log(`Outgoing msg:     ${outgoingMessage}`);

  // ── Gas fee receiver from bridge state ──────────────────────────────────────
  const bridgeGasFeeReceiver = await readGasFeeReceiver(
    rpc,
    bridgeAccountAddress,
    BRIDGE_GAS_FEE_RECEIVER_OFFSET
  );
  console.log(`Bridge fee recv:  ${bridgeGasFeeReceiver}`);

  // ── Payer's ATA ─────────────────────────────────────────────────────────────
  const [ataAddress] = await findAssociatedTokenPda({
    owner: payer.address,
    tokenProgram: maybeMint.programAddress,
    mint: mintAddress,
  });
  const maybeAta = await fetchMaybeToken(rpc, ataAddress);
  if (!maybeAta.exists) throw new Error(`ATA not found: ${ataAddress}. Create and fund it first.`);
  console.log(`From ATA:         ${ataAddress}`);
  console.log(`ATA balance:      ${maybeAta.data.amount}`);

  if (maybeAta.data.amount < scaledAmount) {
    throw new Error(`Insufficient balance: have ${maybeAta.data.amount}, need ${scaledAmount}`);
  }
  console.log();

  // ── Encode fill() calldata ───────────────────────────────────────────────────
  // `to` = router — tokens mint directly here, then fill() runs atomically.
  const evmCallData = encodeFunctionData({
    abi: routerAbi,
    functionName: "fill",
    args: [intentId, scaledAmount, inputRecipient],
  });
  console.log(`EVM calldata: ${evmCallData}`);
  console.log();

  // ── Build bridge_spl instruction ─────────────────────────────────────────────
  const routerBytes = toBytes(routerAddr);

  const bridgeSplData = encodeBridgeSplData(
    outgoingMsgSalt,
    routerBytes,       // `to` = router (tokens mint here)
    remoteTokenBytes,
    scaledAmount,
    {
      target:   routerBytes, // fill() executes on the router
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

  // ── Build pay_for_relay instruction ──────────────────────────────────────────
  if (useRelay) {
    const [cfgAddress] = await getProgramDerivedAddress({
      programAddress: RELAYER_PROGRAM,
      seeds: [CFG_SEED],
    });

    const relayerGasFeeReceiver = await readGasFeeReceiver(
      rpc,
      cfgAddress,
      RELAYER_GAS_FEE_RECEIVER_OFFSET
    );
    console.log(`Relayer fee recv: ${relayerGasFeeReceiver}`);

    const { salt: mtrSalt, pubkey: mtrPubkey } =
      await randomSaltPda(RELAYER_PROGRAM, MTR_SEED);
    console.log(`MTR pubkey:       ${mtrPubkey}`);

    const payForRelayData = encodePayForRelayData(mtrSalt, outgoingMessage, relayGasLimit);

    const payForRelayIx: Instruction = {
      programAddress: RELAYER_PROGRAM,
      accounts: [
        { address: payer.address,         role: 3 },
        { address: cfgAddress,            role: 1 },
        { address: relayerGasFeeReceiver, role: 1 },
        { address: mtrPubkey,             role: 1 },
        { address: SYSTEM_PROGRAM_ADDRESS, role: 0 },
      ],
      data: new Uint8Array(payForRelayData),
    };

    ixs.push(payForRelayIx);
  }

  // ── Send transaction ─────────────────────────────────────────────────────────
  console.log("Building and sending transaction...");
  const sendAndConfirmTx = sendAndConfirmTransactionFactory({ rpc, rpcSubscriptions });
  const blockhash = await rpc.getLatestBlockhash().send();

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

  console.log();
  console.log("=== Bridge Transaction Sent ===");
  console.log(`Signature:  ${signature}`);
  console.log(`Explorer:   https://explorer.solana.com/tx/${signature}`);
  console.log();
  if (useRelay) {
    console.log("Auto-relay enabled. The bridge will mint tokens and execute fill() on Base ~30-60s after finalization.");
    console.log("Monitor:    npx tsx scripts/monitor-router.ts");
  } else {
    console.log("No relay. Manually execute the message on Base after finalization.");
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});

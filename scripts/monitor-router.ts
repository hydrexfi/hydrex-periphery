/**
 * Monitor HydrexMultichainAuctionRouter on Base.
 * Watches IntentCreated, IntentFilled, and IntentCancelled events.
 * Polls active intents every 10s to show the current Dutch auction price.
 *
 * Run BEFORE sending the Solana bridge tx to measure end-to-end latency.
 *
 * Usage:
 *   npx tsx scripts/monitor-router.ts
 *
 * Required env vars:
 *   BASE_RPC_URL             — Base mainnet RPC (wss:// preferred, falls back to http)
 *   AUCTION_ROUTER_ADDRESS   — Deployed HydrexMultichainAuctionRouter address on Base
 */

import {
  createPublicClient,
  http,
  parseAbi,
  webSocket,
  formatUnits,
  type Hex,
  type Address,
} from "viem";
import { base } from "viem/chains";
import "dotenv/config";

const routerAbi = parseAbi([
  // Events
  "event IntentCreated(bytes32 indexed intentId, address indexed user, address inputToken, uint256 inputAmount, address outputToken, uint256 desiredOutput, uint256 minOutput, uint64 auctionSeconds, address recipient, uint64 startTime)",
  "event IntentFilled(bytes32 indexed intentId, address indexed filler, uint256 outputAmount, uint256 requiredAtFill, address inputRecipient)",
  "event IntentCancelled(bytes32 indexed intentId)",

  // View functions
  "function currentRequiredOutput(bytes32 intentId) view returns (uint256)",
  "function intents(bytes32 intentId) view returns (address user, address inputToken, uint256 inputAmount, address outputToken, uint256 desiredOutput, uint256 minOutput, uint64 startTime, uint64 auctionSeconds, address recipient, uint8 status)",
]);

// Track active intents for polling
const activeIntents = new Map<Hex, { desiredOutput: bigint; minOutput: bigint; outputToken: string }>();

function fmt(amount: bigint, decimals = 6): string {
  return formatUnits(amount, decimals);
}

function pct(current: bigint, desired: bigint): string {
  if (desired === 0n) return "0%";
  return ((Number(current) / Number(desired)) * 100).toFixed(1) + "%";
}

async function main() {
  const rpcUrl     = process.env.BASE_RPC_URL!;
  const routerAddr = process.env.AUCTION_ROUTER_ADDRESS! as Address;

  if (!rpcUrl || !routerAddr) {
    console.error("Missing env vars. Need: BASE_RPC_URL, AUCTION_ROUTER_ADDRESS");
    process.exit(1);
  }

  const transport = rpcUrl.startsWith("wss") ? webSocket(rpcUrl) : http(rpcUrl);
  const client    = createPublicClient({ chain: base, transport });

  console.log("=== HydrexMultichainAuctionRouter Monitor ===");
  console.log(`Router:  ${routerAddr}`);
  console.log(`RPC:     ${rpcUrl}`);
  console.log("Watching for IntentCreated, IntentFilled, IntentCancelled events...\n");

  const startTime = Date.now();

  // ── Watch IntentCreated ────────────────────────────────────────────────────
  client.watchEvent({
    address: routerAddr,
    event: routerAbi[0],
    onLogs: (logs) => {
      for (const log of logs) {
        const elapsed = ((Date.now() - startTime) / 1000).toFixed(1);
        const id = log.args.intentId as Hex;
        const desired = log.args.desiredOutput ?? 0n;
        const min     = log.args.minOutput ?? 0n;
        const secs    = log.args.auctionSeconds ?? 0n;

        console.log("┌─── INTENT CREATED ─────────────────────────────────────");
        console.log(`│ Time since start:   ${elapsed}s`);
        console.log(`│ Block:              ${log.blockNumber}`);
        console.log(`│ Tx:                 ${log.transactionHash}`);
        console.log(`│ Intent ID:          ${id}`);
        console.log(`│ User:               ${log.args.user}`);
        console.log(`│ Input token:        ${log.args.inputToken}`);
        console.log(`│ Input amount:       ${fmt(log.args.inputAmount ?? 0n)} (6 dec)`);
        console.log(`│ Output token:       ${log.args.outputToken}`);
        console.log(`│ Desired output:     ${fmt(desired)} (6 dec)  ← auction starts here`);
        console.log(`│ Min output:         ${fmt(min)} (6 dec)  ← floor after ${secs}s`);
        console.log(`│ Auction duration:   ${secs}s`);
        console.log(`│ Recipient:          ${log.args.recipient}`);
        console.log("└─────────────────────────────────────────────────────────\n");

        // Track for price polling
        activeIntents.set(id, {
          desiredOutput: desired,
          minOutput:     min,
          outputToken:   log.args.outputToken ?? "",
        });
      }
    },
    onError: (err) => console.error("Watch error (IntentCreated):", err.message),
  });

  // ── Watch IntentFilled ─────────────────────────────────────────────────────
  client.watchEvent({
    address: routerAddr,
    event: routerAbi[1],
    onLogs: (logs) => {
      for (const log of logs) {
        const elapsed = ((Date.now() - startTime) / 1000).toFixed(1);
        const id = log.args.intentId as Hex;
        const meta = activeIntents.get(id);
        const outputAmount = log.args.outputAmount ?? 0n;

        console.log("┌─── INTENT FILLED ──────────────────────────────────────");
        console.log(`│ Time since start:   ${elapsed}s`);
        console.log(`│ Block:              ${log.blockNumber}`);
        console.log(`│ Tx:                 ${log.transactionHash}`);
        console.log(`│ Intent ID:          ${id}`);
        console.log(`│ Filler:             ${log.args.filler}`);
        console.log(`│ Output paid:        ${fmt(outputAmount)} (6 dec)`);
        console.log(`│ Required at fill:   ${fmt(log.args.requiredAtFill ?? 0n)} (6 dec)`);
        if (meta) {
          console.log(`│ vs desired:         ${pct(outputAmount, meta.desiredOutput)} of desired output`);
        }
        console.log(`│ Input recipient:    ${log.args.inputRecipient}`);
        console.log("└─────────────────────────────────────────────────────────\n");

        activeIntents.delete(id);
      }
    },
    onError: (err) => console.error("Watch error (IntentFilled):", err.message),
  });

  // ── Watch IntentCancelled ──────────────────────────────────────────────────
  client.watchEvent({
    address: routerAddr,
    event: routerAbi[2],
    onLogs: (logs) => {
      for (const log of logs) {
        const elapsed = ((Date.now() - startTime) / 1000).toFixed(1);
        const id = log.args.intentId as Hex;

        console.log("┌─── INTENT CANCELLED ───────────────────────────────────");
        console.log(`│ Time since start:   ${elapsed}s`);
        console.log(`│ Block:              ${log.blockNumber}`);
        console.log(`│ Tx:                 ${log.transactionHash}`);
        console.log(`│ Intent ID:          ${id}`);
        console.log("└─────────────────────────────────────────────────────────\n");

        activeIntents.delete(id);
      }
    },
    onError: (err) => console.error("Watch error (IntentCancelled):", err.message),
  });

  // ── Poll active intents for current price ──────────────────────────────────
  async function pollPrices() {
    if (activeIntents.size === 0) return;

    console.log(`── Active intent prices (${new Date().toLocaleTimeString()}) ──`);
    for (const [intentId, meta] of activeIntents) {
      try {
        const current = await client.readContract({
          address:      routerAddr,
          abi:          routerAbi,
          functionName: "currentRequiredOutput",
          args:         [intentId],
        });
        const decay = meta.desiredOutput - current;
        console.log(
          `  ${intentId.slice(0, 12)}… ` +
          `current=${fmt(current)} | ` +
          `desired=${fmt(meta.desiredOutput)} | ` +
          `min=${fmt(meta.minOutput)} | ` +
          `decayed=${fmt(decay)} (${pct(decay, meta.desiredOutput - meta.minOutput)} of range)`
        );
      } catch {
        // Intent expired — remove from tracking on next fill/cancel event
        console.log(`  ${intentId.slice(0, 12)}… (expired or not found)`);
      }
    }
    console.log();
  }

  setInterval(pollPrices, 10_000);

  // ── Keep process alive ─────────────────────────────────────────────────────
  console.log("Monitoring... Press Ctrl+C to stop.\n");
  process.on("SIGINT", () => {
    console.log("\nStopped monitoring.");
    process.exit(0);
  });
}

main().catch(console.error);

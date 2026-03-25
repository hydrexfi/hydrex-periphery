/**
 * Monitor HydrexReceiver on Base for Delivered events.
 * Run this BEFORE sending the Solana bridge tx to measure latency.
 *
 * Usage:
 *   npx tsx scripts/monitor-base.ts
 *
 * Required env vars:
 *   BASE_RPC_URL       — Base mainnet RPC (websocket preferred for watchEvent)
 *   RECEIVER_ADDRESS   — Deployed HydrexReceiver address on Base
 */

import { createPublicClient, http, parseAbi, webSocket, type Hex } from "viem";
import { base } from "viem/chains";
import "dotenv/config";

const receiverAbi = parseAbi([
  "event Delivered(uint256 indexed deliveryId, address indexed twinSender, address token, uint256 amount, bytes32 intentId, address usdcRecipient)",
  "function deliveryCount() view returns (uint256)",
]);

async function main() {
  const rpcUrl = process.env.BASE_RPC_URL!;
  const receiver = process.env.RECEIVER_ADDRESS! as Hex;

  if (!rpcUrl || !receiver) {
    console.error("Missing env vars. Need: BASE_RPC_URL, RECEIVER_ADDRESS");
    process.exit(1);
  }

  // Use websocket if available, otherwise fall back to HTTP polling
  const transport = rpcUrl.startsWith("wss") ? webSocket(rpcUrl) : http(rpcUrl);
  const client = createPublicClient({ chain: base, transport });

  const currentCount = await client.readContract({
    address: receiver,
    abi: receiverAbi,
    functionName: "deliveryCount",
  });

  console.log("=== HydrexReceiver Monitor ===");
  console.log("Receiver:        ", receiver);
  console.log("Current deliveries:", currentCount.toString());
  console.log("Watching for new Delivered events...\n");

  const startTime = Date.now();

  const unwatch = client.watchEvent({
    address: receiver,
    event: receiverAbi[0],
    onLogs: (logs) => {
      for (const log of logs) {
        const elapsed = ((Date.now() - startTime) / 1000).toFixed(1);
        console.log("=== BRIDGE DELIVERY RECEIVED ===");
        console.log(`Time since monitor start: ${elapsed}s`);
        console.log(`Block:        ${log.blockNumber}`);
        console.log(`Tx:           ${log.transactionHash}`);
        console.log(`Delivery ID:  ${log.args.deliveryId}`);
        console.log(`Twin Sender:  ${log.args.twinSender}`);
        console.log(`Token:        ${log.args.token}`);
        console.log(`Amount:       ${log.args.amount}`);
        console.log(`Intent ID:    ${log.args.intentId}`);
        console.log(`USDC Recip:   ${log.args.usdcRecipient}`);
        console.log("================================\n");
      }
    },
    onError: (error) => {
      console.error("Watch error:", error.message);
    },
  });

  // Keep process alive
  console.log("Monitoring... Press Ctrl+C to stop.\n");
  process.on("SIGINT", () => {
    unwatch();
    console.log("\nStopped monitoring.");
    process.exit(0);
  });
}

main().catch(console.error);

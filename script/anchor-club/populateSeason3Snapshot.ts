/**
 * Writes the Season 3 end-of-season snapshot on-chain.
 *
 * Reads `script/anchor-club/data/season3-snapshot.json` and pushes it into the two snapshot contracts
 * via `batchSetSnapshot`. Idempotent and resumable: every entry is compared against its current
 * on-chain value first and only differences are written, so a failed or partial run can simply be
 * re-run. Verifies the full set by reading it back afterwards.
 *
 * Does NOT call `freeze()`, and does NOT touch AnchorClubSeason3. Repointing Season 3 at these
 * snapshots is a separate, later step (`FreezeAnchorClubSeason3`).
 *
 *   SEASON3_LIQUID_SNAPSHOT=0x… SEASON3_VEMAXI_SNAPSHOT=0x… npm run populate:anchor-club-season3
 *   DRY_RUN=1 …                 # report what would be written, send nothing
 */

import { createPublicClient, createWalletClient, http, getAddress, parseAbi, type Address } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { base } from "viem/chains";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import "dotenv/config";

const SNAPSHOT_FILE = resolve(process.cwd(), "script/anchor-club/data/season3-snapshot.json");

const LIQUID_CHUNK = Number(process.env.LIQUID_CHUNK ?? 150);
const VEMAXI_CHUNK = Number(process.env.VEMAXI_CHUNK ?? 100);
const READ_BATCH = 400;
const DRY_RUN = process.env.DRY_RUN === "1";

const liquidAbi = parseAbi([
  "function cumulativeOptionsClaimed(address) view returns (uint256)",
  "function batchSetSnapshot(address[] users, uint256[] amounts)",
  "function frozen() view returns (bool)",
  "function hasRole(bytes32, address) view returns (bool)",
]);
const veMaxiAbi = parseAbi([
  "function totalFlexLocked(address) view returns (uint256)",
  "function totalProtocolLocked(address) view returns (uint256)",
  "function batchSetSnapshot(address[] users, uint256[] flexLockedAmounts, uint256[] protocolLockedAmounts)",
  "function frozen() view returns (bool)",
  "function hasRole(bytes32, address) view returns (bool)",
]);

const ADMIN_ROLE = "0x0000000000000000000000000000000000000000000000000000000000000000" as const;

const rpc = process.env.BASE_RPC_URL ?? "https://mainnet.base.org";
const account = privateKeyToAccount(process.env.DEPLOYER_KEY as `0x${string}`);
const publicClient = createPublicClient({ chain: base, transport: http(rpc, { batch: true, retryCount: 5 }) });
const walletClient = createWalletClient({ account, chain: base, transport: http(rpc, { retryCount: 5 }) });

const log = (...a: unknown[]) => console.log(...a);
const fmt = (v: bigint) => (Number(v) / 1e18).toLocaleString(undefined, { maximumFractionDigits: 2 });

type LiquidEntry = { user: Address; amount: bigint };
type VeMaxiEntry = { user: Address; flexLocked: bigint; protocolLocked: bigint };

async function readCurrent<T>(
  entries: { user: Address }[],
  build: (user: Address) => readonly unknown[],
  parse: (results: bigint[]) => T
): Promise<T[]> {
  const out: T[] = [];
  for (let i = 0; i < entries.length; i += READ_BATCH) {
    const slice = entries.slice(i, i + READ_BATCH);
    const contracts = slice.flatMap((e) => build(e.user)) as never;
    const results = (await publicClient.multicall({ contracts, allowFailure: false })) as bigint[];
    const stride = results.length / slice.length;
    slice.forEach((_, j) => out.push(parse(results.slice(j * stride, (j + 1) * stride))));
  }
  return out;
}

/**
 * Fee headroom. viem's default maxFeePerGas is baseFee * 1.2 + priority, which Base's fee curve
 * outruns between one transaction and the next — the node then rejects the send as underpriced.
 * Base fees are fractions of a gwei here, so buying a wide margin costs effectively nothing.
 */
async function fees(attempt: number) {
  const block = await publicClient.getBlock();
  const baseFee = block.baseFeePerGas ?? 10_000_000n;
  const bump = BigInt(2 ** attempt);
  const maxPriorityFeePerGas = 1_000_000n * bump;
  const headroom = baseFee * 5n * bump;
  return {
    maxPriorityFeePerGas,
    maxFeePerGas: (headroom > 50_000_000n ? headroom : 50_000_000n) + maxPriorityFeePerGas,
  };
}

/** Send one batch, re-pricing and retrying if the node rejects it. */
async function send(label: string, write: (fee: Awaited<ReturnType<typeof fees>>) => Promise<`0x${string}`>) {
  let lastErr: unknown;
  for (let attempt = 0; attempt < 4; attempt++) {
    try {
      const hash = await write(await fees(attempt));
      const receipt = await publicClient.waitForTransactionReceipt({ hash });
      if (receipt.status !== "success") throw new Error(`${label} reverted: ${hash}`);
      log(`  ${label}  ${hash}  gas ${receipt.gasUsed}`);
      return receipt.gasUsed;
    } catch (err) {
      lastErr = err;
      const msg = err instanceof Error ? err.message.split("\n")[0] : String(err);
      log(`  ${label}  attempt ${attempt + 1} failed (${msg}) — repricing`);
      await new Promise((r) => setTimeout(r, 2000));
    }
  }
  throw lastErr;
}

async function main() {
  const liquidAddr = getAddress(process.env.SEASON3_LIQUID_SNAPSHOT as Address);
  const veMaxiAddr = getAddress(process.env.SEASON3_VEMAXI_SNAPSHOT as Address);

  const snap = JSON.parse(readFileSync(SNAPSHOT_FILE, "utf8"));
  const liquid: LiquidEntry[] = snap.liquid.map((r: any) => ({ user: getAddress(r.user), amount: BigInt(r.amount) }));
  const veMaxi: VeMaxiEntry[] = snap.veMaxi.map((r: any) => ({
    user: getAddress(r.user),
    flexLocked: BigInt(r.flexLocked),
    protocolLocked: BigInt(r.protocolLocked),
  }));

  log(`Snapshot from block ${snap.block} (${new Date(Number(snap.timestamp) * 1000).toISOString()})`);
  log(`  liquid entries ${liquid.length}, veMaxi entries ${veMaxi.length}`);
  log(`  liquid target  ${liquidAddr}`);
  log(`  veMaxi target  ${veMaxiAddr}`);
  log(`  sender         ${account.address}${DRY_RUN ? "   [DRY RUN]" : ""}\n`);

  if (snap.verification.mismatches.length || snap.verification.droppedWithCredits.length) {
    throw new Error("snapshot file failed its own verification — refusing to write it on-chain");
  }

  // Preflight: right key, and neither snapshot already sealed.
  const [liquidAdmin, veMaxiAdmin, liquidFrozen, veMaxiFrozen] = await Promise.all([
    publicClient.readContract({ address: liquidAddr, abi: liquidAbi, functionName: "hasRole", args: [ADMIN_ROLE, account.address] }),
    publicClient.readContract({ address: veMaxiAddr, abi: veMaxiAbi, functionName: "hasRole", args: [ADMIN_ROLE, account.address] }),
    publicClient.readContract({ address: liquidAddr, abi: liquidAbi, functionName: "frozen" }),
    publicClient.readContract({ address: veMaxiAddr, abi: veMaxiAbi, functionName: "frozen" }),
  ]);
  if (!liquidAdmin || !veMaxiAdmin) throw new Error(`${account.address} lacks DEFAULT_ADMIN_ROLE on a snapshot`);
  if (liquidFrozen || veMaxiFrozen) throw new Error("a snapshot is already frozen — cannot write");

  /*
   * Diff against what is already on-chain
   */

  log("Diffing against on-chain state...");
  const liquidNow = await readCurrent<bigint>(
    liquid,
    (user) => [{ address: liquidAddr, abi: liquidAbi, functionName: "cumulativeOptionsClaimed", args: [user] } as const],
    (r) => r[0]
  );
  const veMaxiNow = await readCurrent<[bigint, bigint]>(
    veMaxi,
    (user) => [
      { address: veMaxiAddr, abi: veMaxiAbi, functionName: "totalFlexLocked", args: [user] } as const,
      { address: veMaxiAddr, abi: veMaxiAbi, functionName: "totalProtocolLocked", args: [user] } as const,
    ],
    (r) => [r[0], r[1]]
  );

  const liquidTodo = liquid.filter((e, i) => liquidNow[i] !== e.amount);
  const veMaxiTodo = veMaxi.filter(
    (e, i) => veMaxiNow[i][0] !== e.flexLocked || veMaxiNow[i][1] !== e.protocolLocked
  );
  log(`  liquid: ${liquidTodo.length} to write, ${liquid.length - liquidTodo.length} already correct`);
  log(`  veMaxi: ${veMaxiTodo.length} to write, ${veMaxi.length - veMaxiTodo.length} already correct\n`);

  if (DRY_RUN) {
    log(
      `DRY RUN — would send ${Math.ceil(liquidTodo.length / LIQUID_CHUNK) + Math.ceil(veMaxiTodo.length / VEMAXI_CHUNK)} transactions`
    );
    return;
  }

  /*
   * Write
   */

  let gas = 0n;
  if (liquidTodo.length) {
    log(`Writing liquid snapshot (${Math.ceil(liquidTodo.length / LIQUID_CHUNK)} txs)...`);
    for (let i = 0; i < liquidTodo.length; i += LIQUID_CHUNK) {
      const slice = liquidTodo.slice(i, i + LIQUID_CHUNK);
      gas += await send(`liquid ${i + 1}-${i + slice.length}`, (fee) =>
        walletClient.writeContract({
          address: liquidAddr,
          abi: liquidAbi,
          functionName: "batchSetSnapshot",
          args: [slice.map((e) => e.user), slice.map((e) => e.amount)],
          ...fee,
        })
      );
    }
  }

  if (veMaxiTodo.length) {
    log(`\nWriting veMaxi snapshot (${Math.ceil(veMaxiTodo.length / VEMAXI_CHUNK)} txs)...`);
    for (let i = 0; i < veMaxiTodo.length; i += VEMAXI_CHUNK) {
      const slice = veMaxiTodo.slice(i, i + VEMAXI_CHUNK);
      gas += await send(`veMaxi ${i + 1}-${i + slice.length}`, (fee) =>
        walletClient.writeContract({
          address: veMaxiAddr,
          abi: veMaxiAbi,
          functionName: "batchSetSnapshot",
          args: [
            slice.map((e) => e.user),
            slice.map((e) => e.flexLocked),
            slice.map((e) => e.protocolLocked),
          ],
          ...fee,
        })
      );
    }
  }

  /*
   * Read the whole thing back
   */

  log("\nVerifying on-chain state against the snapshot file...");
  const liquidFinal = await readCurrent<bigint>(
    liquid,
    (user) => [{ address: liquidAddr, abi: liquidAbi, functionName: "cumulativeOptionsClaimed", args: [user] } as const],
    (r) => r[0]
  );
  const veMaxiFinal = await readCurrent<[bigint, bigint]>(
    veMaxi,
    (user) => [
      { address: veMaxiAddr, abi: veMaxiAbi, functionName: "totalFlexLocked", args: [user] } as const,
      { address: veMaxiAddr, abi: veMaxiAbi, functionName: "totalProtocolLocked", args: [user] } as const,
    ],
    (r) => [r[0], r[1]]
  );

  const bad: string[] = [];
  liquid.forEach((e, i) => {
    if (liquidFinal[i] !== e.amount) bad.push(`liquid ${e.user}: on-chain ${liquidFinal[i]} != ${e.amount}`);
  });
  veMaxi.forEach((e, i) => {
    if (veMaxiFinal[i][0] !== e.flexLocked || veMaxiFinal[i][1] !== e.protocolLocked) {
      bad.push(`veMaxi ${e.user}: on-chain ${veMaxiFinal[i]} != ${e.flexLocked},${e.protocolLocked}`);
    }
  });

  const sumLiquid = liquidFinal.reduce((a, b) => a + b, 0n);
  const sumFlex = veMaxiFinal.reduce((a, b) => a + b[0], 0n);
  const sumProtocol = veMaxiFinal.reduce((a, b) => a + b[1], 0n);

  log(`
Done. gas used ${gas}
  liquid entries on-chain     ${liquid.length}   total ${fmt(sumLiquid)}
  veMaxi entries on-chain     ${veMaxi.length}   flex ${fmt(sumFlex)}  protocol ${fmt(sumProtocol)}
  mismatches                  ${bad.length}

Snapshots are populated but NOT frozen, and Season 3 still reads its live sources.`);

  if (bad.length) {
    bad.slice(0, 20).forEach((b) => log(`  ${b}`));
    process.exitCode = 1;
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

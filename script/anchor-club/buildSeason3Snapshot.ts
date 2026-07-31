/**
 * Builds the Anchor Club Season 3 end-of-season snapshot.
 *
 * Enumerates every address that could hold Season 3 credits, reads all relevant values pinned to a
 * single block, and cross-checks the result against what AnchorClubSeason3 itself reports at that
 * block. Writes `script/anchor-club/data/season3-snapshot.json`.
 *
 * This script only reads. Nothing here sends a transaction.
 *
 *   npm run snapshot:anchor-club-season3
 *   BLOCK=49000000 npm run snapshot:anchor-club-season3   # pin to a specific block
 */

import { createPublicClient, http, getAddress, parseAbi, type Address, type Hex } from "viem";
import { base } from "viem/chains";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import "dotenv/config";

/*
 * Config
 */

const SEASON_3 = getAddress("0x2C8aF0F727aD97Ef0ba0119330D5609ac93D8699");
const S2_LIQUID_SNAPSHOT = getAddress("0x47f44Dc366f5b0809c291E7b59d88299E6A17708");
const S2_VEMAXI_SNAPSHOT = getAddress("0x210b958EEFEF1ce38C82C6c4E5215A73A2abC909");
const VEMAXI_CONDUIT = getAddress("0x53388a4E98Bb56F8571433F5461010Fc287929d3");

const LIQUID_CONDUITS: Address[] = [
  getAddress("0x95f04F2eEe7a197b30708E50D25B5E876917D259"),
  getAddress("0x5e932317B4AfbCE3d254072c1a39579967D8F9ae"),
  getAddress("0x9ee81fD729b91095563fE6dA11c1fE92C52F9728"),
];

/** Every contract whose logs can reveal a credit-holding address. */
const LOG_SOURCES: Address[] = [
  ...LIQUID_CONDUITS,
  VEMAXI_CONDUIT,
  SEASON_3,
  S2_LIQUID_SNAPSHOT,
  S2_VEMAXI_SNAPSHOT,
];

const OUT_FILE = resolve(process.cwd(), "script/anchor-club/data/season3-snapshot.json");
/** Log scanning is the slow half; cache the address list so re-reads are cheap. */
const CANDIDATES_FILE = resolve(process.cwd(), "script/anchor-club/data/season3-candidates.json");

const MAX_CHUNK = 500_000n;
const MIN_CHUNK = 2_000n;
const LOG_CONCURRENCY = 6;
const MULTICALL_BATCH = 400;

/*
 * ABIs
 */

const liquidAbi = parseAbi(["function cumulativeOptionsClaimed(address) view returns (uint256)"]);
const veMaxiAbi = parseAbi([
  "function totalFlexLocked(address) view returns (uint256)",
  "function totalProtocolLocked(address) view returns (uint256)",
]);
const season3Abi = parseAbi([
  "function calculateSeason3LiquidCredits(address) view returns (uint256)",
  "function calculateVeMaxiCredits(address) view returns (uint256)",
  "function liquidSpentCredits(address) view returns (uint256)",
  "function veMaxiSpentCredits(address) view returns (uint256)",
  "function liquidAccountMultiplier() view returns (uint256)",
  "function veMaxiMultiplier() view returns (uint256)",
  "function getLiquidConduits() view returns (address[])",
  "function veMaxiConduit() view returns (address)",
]);
// Batch writes on the Season 2 snapshots don't index their users, so recover them from calldata.
const s2BatchAbi = parseAbi([
  "function batchSetSnapshot(address[] users, uint256[] amounts)",
  "function batchSetSnapshot(address[] users, uint256[] flexLockedAmounts, uint256[] protocolLockedAmounts)",
]);

const client = createPublicClient({
  chain: base,
  transport: http(process.env.BASE_RPC_URL ?? "https://mainnet.base.org", { batch: true, retryCount: 5 }),
});

/*
 * Shared state, resolved once in main() and read by the passes below
 */

let pinned: bigint;
let blockTimestamp: bigint;
let liquidMultiplier: bigint;
let veMaxiMultiplier: bigint;

/*
 * Helpers
 */

function log(...args: unknown[]) {
  console.log(...args);
}

/** Binary search for the first block at which `address` has code. */
async function findDeploymentBlock(address: Address, head: bigint): Promise<bigint> {
  let lo = 0n;
  let hi = head;
  while (lo < hi) {
    const mid = (lo + hi) / 2n;
    const code = await client.getCode({ address, blockNumber: mid });
    if (code && code !== "0x") hi = mid;
    else lo = mid + 1n;
  }
  return lo;
}

async function mapLimit<T, R>(items: T[], limit: number, fn: (item: T, i: number) => Promise<R>): Promise<R[]> {
  const out = new Array<R>(items.length);
  let cursor = 0;
  await Promise.all(
    Array.from({ length: Math.min(limit, items.length) }, async () => {
      while (cursor < items.length) {
        const i = cursor++;
        out[i] = await fn(items[i], i);
      }
    })
  );
  return out;
}

const isAddressTopic = (topic: Hex) =>
  topic.length === 66 && topic.slice(2, 26) === "0".repeat(24) && topic.slice(26) !== "0".repeat(40);

/**
 * Pull every log a contract has emitted, halving the range whenever the provider caps the response.
 * Returns the raw logs so callers can harvest both topics and calldata.
 */
async function getAllLogs(address: Address, fromBlock: bigint, toBlock: bigint) {
  const collected: { topics: Hex[]; transactionHash: Hex; address: Address }[] = [];
  let cursor = fromBlock;
  let chunk = MAX_CHUNK;

  while (cursor <= toBlock) {
    const end = cursor + chunk - 1n > toBlock ? toBlock : cursor + chunk - 1n;
    try {
      const logs = await client.getLogs({ address, fromBlock: cursor, toBlock: end });
      for (const l of logs) {
        collected.push({
          topics: l.topics as Hex[],
          transactionHash: l.transactionHash!,
          address: getAddress(l.address),
        });
      }
      cursor = end + 1n;
      if (chunk < MAX_CHUNK) chunk *= 2n;
    } catch (err) {
      if (chunk <= MIN_CHUNK) throw err;
      chunk /= 2n;
    }
  }
  return collected;
}

/*
 * Main
 */

async function main() {
  const head = await client.getBlockNumber();
  pinned = process.env.BLOCK ? BigInt(process.env.BLOCK) : head;
  blockTimestamp = (await client.getBlock({ blockNumber: pinned })).timestamp;
  log(`Pinned to block ${pinned} (${new Date(Number(blockTimestamp) * 1000).toISOString()}), head is ${head}\n`);

  // Sanity: confirm Season 3 is still reading the live sources we think it is.
  const [registeredConduits, registeredVeMaxi, liquidBps, veMaxiBps] = await Promise.all([
    client.readContract({ address: SEASON_3, abi: season3Abi, functionName: "getLiquidConduits", blockNumber: pinned }),
    client.readContract({ address: SEASON_3, abi: season3Abi, functionName: "veMaxiConduit", blockNumber: pinned }),
    client.readContract({
      address: SEASON_3,
      abi: season3Abi,
      functionName: "liquidAccountMultiplier",
      blockNumber: pinned,
    }),
    client.readContract({ address: SEASON_3, abi: season3Abi, functionName: "veMaxiMultiplier", blockNumber: pinned }),
  ]);

  liquidMultiplier = liquidBps as bigint;
  veMaxiMultiplier = veMaxiBps as bigint;

  const registered = (registeredConduits as Address[]).map((a) => getAddress(a)).sort();
  const expected = [...LIQUID_CONDUITS].sort();
  if (JSON.stringify(registered) !== JSON.stringify(expected)) {
    throw new Error(`Season 3 liquid conduits are ${registered.join(", ")}, expected ${expected.join(", ")}`);
  }
  if (getAddress(registeredVeMaxi as Address) !== VEMAXI_CONDUIT) {
    throw new Error(`Season 3 veMaxi conduit is ${registeredVeMaxi}, expected ${VEMAXI_CONDUIT}`);
  }
  log(`Season 3 sources verified. multipliers: liquid ${liquidMultiplier}bps, veMaxi ${veMaxiMultiplier}bps\n`);

  /*
   * 1. Discover the scan range for each source
   */

  if (existsSync(CANDIDATES_FILE) && process.env.RESCAN !== "1") {
    const cached = JSON.parse(readFileSync(CANDIDATES_FILE, "utf8"));
    if (cached.block === pinned.toString()) {
      log(`Reusing ${cached.users.length} cached candidates (RESCAN=1 to force a fresh log scan)\n`);
      return readAndWrite(cached.users as Address[]);
    }
    log(`Cached candidates are from block ${cached.block}, rescanning for ${pinned}\n`);
  }

  log("Locating deployment blocks...");
  const deployBlocks = await mapLimit(LOG_SOURCES, LOG_SOURCES.length, async (addr) => {
    const b = await findDeploymentBlock(addr, pinned);
    log(`  ${addr}  block ${b}`);
    return b;
  });

  /*
   * 2. Enumerate candidate addresses
   *
   * Every indexed address parameter of every event these contracts emit is treated as a candidate.
   * That is deliberately over-inclusive: a false positive reads 0 on-chain and gets dropped in step 4,
   * whereas a missed user would silently forfeit their credits.
   */

  log("\nScanning logs...");
  const candidates = new Set<Address>();
  const batchSnapshotTxs = new Set<Hex>();

  const perSource = await mapLimit(LOG_SOURCES, LOG_CONCURRENCY, async (address, i) => {
    const logs = await getAllLogs(address, deployBlocks[i], pinned);
    let found = 0;
    for (const l of logs) {
      for (const topic of l.topics.slice(1)) {
        if (isAddressTopic(topic)) {
          candidates.add(getAddress(`0x${topic.slice(26)}`));
          found++;
        }
      }
      if (address === S2_LIQUID_SNAPSHOT || address === S2_VEMAXI_SNAPSHOT) {
        batchSnapshotTxs.add(l.transactionHash);
      }
    }
    log(`  ${address}  ${logs.length} logs, ${found} address topics`);
    return logs.length;
  });
  log(`  total logs: ${perSource.reduce((a, b) => a + b, 0)}`);

  // Season 2 batch writes don't index their users — recover them from the transaction calldata.
  log(`\nDecoding ${batchSnapshotTxs.size} Season 2 snapshot transactions...`);
  let recovered = 0;
  await mapLimit([...batchSnapshotTxs], LOG_CONCURRENCY, async (hash) => {
    const tx = await client.getTransaction({ hash });
    for (const abi of s2BatchAbi) {
      try {
        const { decodeFunctionData } = await import("viem");
        const decoded = decodeFunctionData({ abi: [abi], data: tx.input });
        for (const user of decoded.args[0] as Address[]) {
          if (!candidates.has(getAddress(user))) recovered++;
          candidates.add(getAddress(user));
        }
        break;
      } catch {
        /* not this overload */
      }
    }
  });
  log(`  ${recovered} addresses only reachable via batch calldata`);

  const users = [...candidates].sort();
  log(`\n${users.length} candidate addresses\n`);
  mkdirSync(dirname(CANDIDATES_FILE), { recursive: true });
  writeFileSync(CANDIDATES_FILE, JSON.stringify({ block: pinned.toString(), users }, null, 2));

  return readAndWrite(users);
}

/*
 * 3. Read every value at the pinned block, verify, and write the snapshot
 */

async function readAndWrite(users: Address[]) {
  log("Reading balances (multicall)...");
  type Row = {
    user: Address;
    liquidTotal: bigint;
    flexLocked: bigint;
    protocolLocked: bigint;
    s2Liquid: bigint;
    s2Flex: bigint;
    s2Protocol: bigint;
    liquidCredits: bigint;
    veMaxiCredits: bigint;
    liquidSpent: bigint;
    veMaxiSpent: bigint;
  };

  const rows: Row[] = [];
  for (let i = 0; i < users.length; i += MULTICALL_BATCH) {
    const slice = users.slice(i, i + MULTICALL_BATCH);
    const contracts = slice.flatMap((user) => [
      ...LIQUID_CONDUITS.map(
        (c) => ({ address: c, abi: liquidAbi, functionName: "cumulativeOptionsClaimed", args: [user] }) as const
      ),
      { address: VEMAXI_CONDUIT, abi: veMaxiAbi, functionName: "totalFlexLocked", args: [user] } as const,
      { address: VEMAXI_CONDUIT, abi: veMaxiAbi, functionName: "totalProtocolLocked", args: [user] } as const,
      { address: S2_LIQUID_SNAPSHOT, abi: liquidAbi, functionName: "cumulativeOptionsClaimed", args: [user] } as const,
      { address: S2_VEMAXI_SNAPSHOT, abi: veMaxiAbi, functionName: "totalFlexLocked", args: [user] } as const,
      { address: S2_VEMAXI_SNAPSHOT, abi: veMaxiAbi, functionName: "totalProtocolLocked", args: [user] } as const,
      { address: SEASON_3, abi: season3Abi, functionName: "calculateSeason3LiquidCredits", args: [user] } as const,
      { address: SEASON_3, abi: season3Abi, functionName: "calculateVeMaxiCredits", args: [user] } as const,
      { address: SEASON_3, abi: season3Abi, functionName: "liquidSpentCredits", args: [user] } as const,
      { address: SEASON_3, abi: season3Abi, functionName: "veMaxiSpentCredits", args: [user] } as const,
    ]);

    const results = await client.multicall({ contracts, blockNumber: pinned, allowFailure: false });
    const stride = contracts.length / slice.length;
    slice.forEach((user, j) => {
      const r = results.slice(j * stride, (j + 1) * stride) as bigint[];
      rows.push({
        user,
        liquidTotal: r[0] + r[1] + r[2],
        flexLocked: r[3],
        protocolLocked: r[4],
        s2Liquid: r[5],
        s2Flex: r[6],
        s2Protocol: r[7],
        liquidCredits: r[8],
        veMaxiCredits: r[9],
        liquidSpent: r[10],
        veMaxiSpent: r[11],
      });
    });
    log(`  ${Math.min(i + MULTICALL_BATCH, users.length)}/${users.length}`);
  }

  /*
   * 4. Filter, verify, write
   */

  const liquidRows = rows.filter((r) => r.liquidTotal > 0n);
  const veMaxiRows = rows.filter((r) => r.flexLocked > 0n || r.protocolLocked > 0n);

  // The snapshot is correct iff replaying Season 3's own formula over the snapshot values reproduces
  // exactly what Season 3 returns at this block, for every user.
  const mismatches: string[] = [];
  for (const r of rows) {
    const liquidDelta = r.liquidTotal > r.s2Liquid ? r.liquidTotal - r.s2Liquid : 0n;
    const expectedLiquid = (liquidDelta * liquidMultiplier) / 10_000n;
    const veLive = r.flexLocked + r.protocolLocked;
    const veBase = r.s2Flex + r.s2Protocol;
    const veDelta = veLive > veBase ? veLive - veBase : 0n;
    const expectedVeMaxi = (veDelta * veMaxiMultiplier) / 10_000n;
    if (expectedLiquid !== r.liquidCredits) {
      mismatches.push(`${r.user} liquid: computed ${expectedLiquid} vs on-chain ${r.liquidCredits}`);
    }
    if (expectedVeMaxi !== r.veMaxiCredits) {
      mismatches.push(`${r.user} veMaxi: computed ${expectedVeMaxi} vs on-chain ${r.veMaxiCredits}`);
    }
  }

  // Anyone Season 3 currently credits must appear in the snapshot, or they lose those credits.
  const dropped = rows.filter(
    (r) =>
      (r.liquidCredits > 0n && !liquidRows.includes(r)) || (r.veMaxiCredits > 0n && !veMaxiRows.includes(r))
  );

  const totals = rows.reduce(
    (acc, r) => {
      acc.liquidCredits += r.liquidCredits;
      acc.veMaxiCredits += r.veMaxiCredits;
      acc.liquidSpent += r.liquidSpent;
      acc.veMaxiSpent += r.veMaxiSpent;
      return acc;
    },
    { liquidCredits: 0n, veMaxiCredits: 0n, liquidSpent: 0n, veMaxiSpent: 0n }
  );

  const output = {
    network: "base",
    block: pinned.toString(),
    timestamp: blockTimestamp.toString(),
    season3: SEASON_3,
    sources: { liquidConduits: LIQUID_CONDUITS, veMaxiConduit: VEMAXI_CONDUIT },
    season2Baselines: { liquid: S2_LIQUID_SNAPSHOT, veMaxi: S2_VEMAXI_SNAPSHOT },
    multipliers: { liquidBps: Number(liquidMultiplier), veMaxiBps: Number(veMaxiMultiplier) },
    candidatesScanned: users.length,
    // -> AnchorClubSeason3Snapshot.batchSetSnapshot(users, amounts)
    liquid: liquidRows.map((r) => ({ user: r.user, amount: r.liquidTotal.toString() })),
    // -> AnchorClubSeason3VeMaxiSnapshot.batchSetSnapshot(users, flex, protocol)
    veMaxi: veMaxiRows.map((r) => ({
      user: r.user,
      flexLocked: r.flexLocked.toString(),
      protocolLocked: r.protocolLocked.toString(),
    })),
    credits: rows
      .filter((r) => r.liquidCredits > 0n || r.veMaxiCredits > 0n || r.liquidSpent > 0n || r.veMaxiSpent > 0n)
      .map((r) => ({
        user: r.user,
        liquidCredits: r.liquidCredits.toString(),
        veMaxiCredits: r.veMaxiCredits.toString(),
        liquidSpent: r.liquidSpent.toString(),
        veMaxiSpent: r.veMaxiSpent.toString(),
        liquidRemaining: (r.liquidCredits > r.liquidSpent ? r.liquidCredits - r.liquidSpent : 0n).toString(),
        veMaxiRemaining: (r.veMaxiCredits > r.veMaxiSpent ? r.veMaxiCredits - r.veMaxiSpent : 0n).toString(),
      })),
    totals: {
      liquidCredits: totals.liquidCredits.toString(),
      veMaxiCredits: totals.veMaxiCredits.toString(),
      liquidSpent: totals.liquidSpent.toString(),
      veMaxiSpent: totals.veMaxiSpent.toString(),
    },
    verification: { mismatches, droppedWithCredits: dropped.map((r) => r.user) },
  };

  mkdirSync(dirname(OUT_FILE), { recursive: true });
  writeFileSync(OUT_FILE, JSON.stringify(output, null, 2));

  const fmt = (v: bigint) => (Number(v) / 1e18).toLocaleString(undefined, { maximumFractionDigits: 2 });
  log(`
Snapshot @ block ${pinned}
  candidates scanned          ${users.length}
  liquid snapshot entries     ${liquidRows.length}
  veMaxi snapshot entries     ${veMaxiRows.length}
  users with credits earned   ${rows.filter((r) => r.liquidCredits > 0n || r.veMaxiCredits > 0n).length}
  users with unredeemed       ${rows.filter((r) => r.liquidCredits > r.liquidSpent || r.veMaxiCredits > r.veMaxiSpent).length}

  liquid credits earned       ${fmt(totals.liquidCredits)}
  liquid credits spent        ${fmt(totals.liquidSpent)}
  veMaxi credits earned       ${fmt(totals.veMaxiCredits)}
  veMaxi credits spent        ${fmt(totals.veMaxiSpent)}
  outstanding redeemable      ${fmt(
    totals.liquidCredits - totals.liquidSpent + totals.veMaxiCredits - totals.veMaxiSpent
  )}

  formula replay mismatches   ${mismatches.length}
  credited users dropped      ${dropped.length}

Written to ${OUT_FILE}`);

  if (mismatches.length || dropped.length) {
    log("\nFAILED verification:");
    mismatches.slice(0, 20).forEach((m) => log(`  ${m}`));
    dropped.slice(0, 20).forEach((d) => log(`  dropped with credits: ${d}`));
    process.exitCode = 1;
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});

# CLAUDE.md — hydrex-periphery

Foundry repo of auxiliary Hydrex contracts (`solc 0.8.26`, src = `contracts/`).
Domains: `token`, `basedrop` (campaign badges / protocol mining), `conduits`
(manager + delegate automation), `partner-escrow` (veHYDX escrow), `dca`,
`anchor-club`, `governance`, `fees` (fee splitter + factory), `router`
(multi-router + token jar), `send` (points / referral / token-jar payouts),
`extra` (bribe batches, claims, lenses). Mostly non-upgradeable; a few
contracts use `initializer`/`__gap`.

## Priorities (strict order)
1. Security > correctness > clarity > gas/efficiency.
2. Minimal diffs; preserve behaviour unless explicitly requested.
3. Explicit, readable code with well-named identifiers.

## Working style
- Before starting, state: goal, files to touch, risk areas.
- Small, reviewable steps. No drive-by refactors.
- Do not assume anything is safe because "it's common in DeFi". When unsure, ask.
- After each meaningful step, run the smallest relevant `forge test` subset.
- Do not claim tests passed unless you ran them.

## Solidity standards
- Custom errors, not long revert strings.
- `unchecked {}` only with clear justification and bounds.
- Checks-effects-interactions; treat every external call as hostile.
- Explicit units and rounding direction (wad/ray/bps).
- Treat ERC20s as non-standard: safe transfer helpers; handle fee-on-transfer /
  rebasing / weird return values where an amount is later relied upon.
- Orthogonality: each contract has one responsibility — extract a library or child
  contract rather than bolting on. Shared accounting/access logic lives in a base
  or library, never copy-pasted across conduits or escrows.
- Document key invariants as `@dev` NatSpec — they are the targets for fuzz/regression tests.
- Avoid: `tx.origin`, timestamp dependence for critical logic, unbounded loops over
  user-controlled arrays, silent storage-layout changes in upgradeable contracts.

## Deploy scripts
Deploy scripts under `script/` must verify the contracts they deploy on Base
(gated on non-local network). If you write or review a deploy that deploys but
skips verification, flag it.

## Commands
```
forge build
forge test                       # full suite
forge test --match-contract <X>  # targeted
forge fmt --check                # formatting
slither contracts/<path>         # if installed
```

## Definition of done — verify before you call it done

Writing the code is not done. Done means reviewed and green. Before reporting a
task complete:

1. **Test** — delegate to the `foundry-test-runner` subagent to build + run the
   relevant tests (and Slither on touched surfaces). Don't run the full suite
   inline; its output belongs in the subagent's context.
2. **Review** — delegate to the `solidity-reviewer` subagent to review the diff
   against the Hydrex security checklist. Use it even if you "already checked" —
   it's a fresh, independent pass.
3. **Fix** — resolve every CRITICAL/HIGH finding and every test failure. Apply
   MEDIUM/LOW unless there's a stated reason not to.
4. **Re-verify** — if you changed anything in step 3, re-run steps 1–2 on the new
   diff. Repeat until tests pass and the reviewer returns APPROVE / APPROVE WITH NITS.
5. **Report** — give me the reviewer verdict + test summary in one or two lines.
   Don't paste full logs unless asked.

Also required before done: every logic change has tests (happy path, edge case,
access-control failure, replay/double-claim where applicable); for any upgradeable
contract that touches storage, the layout is diffed and any change explained;
changes summarised as what / why / risk / tests.

Do not mark complete or move on until the loop closes. If you can't make checks
pass, stop and say what's blocking — an honest "stuck" beats a false "done".

## Commit hygiene — Conventional Commits
`type(scope): subject` — type ∈ {feat, fix, refactor, perf, test, docs, build, ci,
chore, revert}; scope = module (`conduit`, `escrow`, `dca`, `token`, `basedrop`);
imperative, lowercase, ≤72 chars. Security-relevant fixes name the risk, e.g.
`fix(conduit): prevent reentrancy on delegate execute`.

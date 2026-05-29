# Tasks: 001-ez404-v4-hooks

Status legend: `[x]` done · `[~]` in progress / partial · `[ ]` not started.

Foundry is now installed locally (1.7.1) and CI reproduces the working set (pinned commits, verified
in a clean checkout). `forge build` is green and the 15-test suite passes.

**D-13 pivot (see `research.md`):** the mint mechanism and dividend math were replaced after the
initial coin-age build. Mint is now a **pump.fun constant-product curve** (buy-only, ETH escrowed,
auto-graduates into the locked pool on sell-out); dividends are **flat per whole NFT** (single
accumulator per currency, dynamic eligibility, no coin-age / no snapshot). Tasks below are annotated:
coin-age-era items that were *superseded* are marked **(D-13: superseded)** with the replacement
noted; their `[x]` reflects that the coin-age version shipped and was then rewritten.

## Phase 0 — Spec & plan
- [x] T001 Constitution (`.specify/memory/constitution.md`)
- [x] T002 Feature spec (`spec.md`)
- [x] T003 Implementation plan (`plan.md`)
- [x] T004 Research / decision log (`research.md`)
- [x] T005 Data model & formulas (`data-model.md`)
- [x] T006 Behavioral contracts (`contracts/IEZ404.md`, `contracts/IEZ404Hook.md`)
- [x] T007 Quickstart (`quickstart.md`)

## Phase 1 — Scaffold
- [x] T010 Foundry config (`foundry.toml`, `remappings.txt` — nested `lib/<dep>/lib/...` paths)
- [x] T011 `.gitignore`, `README.md`, `LICENSE`
- [x] T012 CI workflow (`.github/workflows/test.yml`: pinned install → build → test)
- [x] T013 Install + pin the 5 deps (forge-std, v4-core, v4-periphery, solady, dn404); remappings verified

## Phase 2 — Token (EZ404)
- [x] T020 DN404 + DN404Mirror wiring, `_unit = 10_000e18`, name/symbol
- [x] T021 Reward-ledger state — **(D-13: superseded)** coin-age `B`/`S`/`t0`/`_eligBal` replaced by
      flat ledger: `B` (eligible whole-NFT count), `_weight[u]`, `acc0`/`acc1`, `_ck0`/`_ck1`,
      `claimable0`/`claimable1`, `undist0`/`undist1`. No `t0`/`S`/`tStart`/snapshot.
- [x] T022 `_accrue` + `_settle` — **(D-13: superseded)** two-accumulator coin-age replaced by a
      single accumulator per currency: `acc_c += mulDiv(F, ACC, B)`; reward `= mulDiv(w, acc−ck, ACC)`.
      `undist` rollover when `B == 0` retained.
- [x] T023 Override DN404 `_transfer`/`_mint`/`_burn` **and `_transferFromNFT`** to settle-before-move,
      then re-sync whole-NFT weight `_setWeight(·, bal/_unit())` (INV-1)
- [x] T024 Mint — **(D-13: superseded)** fixed-price `publicMint` + per-mint instant seed replaced by
      pump.fun constant-product curve: `quoteBuy`/`publicMint` (buy-only, `cost = mulDiv(vETH, Δ, vTok−Δ)`,
      escrow ETH, refund overpay), `_graduate` (ship `ethRaised` to `seedLiquidity` once on sell-out),
      `curveFinalReserves`/`remaining` views, `mintedUnits`/`ethRaised`/`graduated` state
- [x] T025 `notifyFeeETH`/`notifyFeeToken`/`claim`/`mintForSeed`
- [x] T026 `setHook`/`setExcluded` wiring (`_setExcluded` settles, zeroes/restores weight)
- [x] T027 Compile clean (`forge build`)
- [x] T028 Solvency — **(D-13: superseded & simplified)** the ceil-vs-floor + clamp apparatus is
      *removed*. Flat ledger has a single floored accumulator and a single floored per-holder term and
      **no subtracted term**, so `Σreward ≤ F` (solvent) and underflow is structurally impossible.
      Proven by AC-4 (conservation, flat) and AC-6 (dust earns nothing).

## Phase 3 — Hook (EZ404Hook)
- [x] T030 `getHookPermissions` (flags 0xA44) + ctor (manager, token, controller, feeBps)
- [x] T031 `_beforeAddLiquidity` (seed-only) + `_beforeRemoveLiquidity` (revert)
- [x] T032 `_afterSwap` dual-currency skim + `take` + route + `+fee` return
- [x] T033 `seedLiquidity` + `unlockCallback` (modifyLiquidity, settle ETH, mint+settle token, refund)
- [x] T034 `setKey`, `receive()`
- [x] T035 Compile clean

## Phase 4 — Tests
- [x] T040 Four-quadrant fee-currency tests (AC-2) — all 4 quadrants pass on a real `PoolManager`
- [x] T041 Seed price + liquidity present (AC-1) — `sp ≈ sqrtPInit` from `curveFinalReserves()`
- [x] T042 Outsider-add / remove blocked (AC-3)
- [x] T047 INV-1 regression: whole-NFT **weight** re-syncs on ERC-721 mirror transfer
      (`_transferFromNFT`); checks `weightOf` + `B` conservation (replaces the coin-age `t0` test)
- [x] T043 Conservation + flat weighting (AC-4): alice 100 NFTs / bob 50 NFTs split one fee 2:1 and
      sum back to `F`. **(D-13: superseded)** former age-weighting variant.
- [x] T044 Exclusions earn nothing; locked pool earns nothing (AC-5): sole eligible holder collects
      ~all of `F`; PM/hook/token `claimable0 == 0`.
- [x] T045 Dust earns nothing (AC-6): two holders with equal whole-NFT weight (1) split a fee equally
      even though one holds 1.5 units — the 0.5-unit dust earns 0. **(D-13: superseded)** former
      JIT/coin-age age-0-whale test (coin-age deleted).
- [x] T048 Curve quote + convexity (D-13): first NFT ≈ 0.001 ETH; `quoteBuy(100)` strictly exceeds
      100× the first-NFT price (CP convexity)
- [x] T049 Curve price rises (D-13): minting advances reserves so the next `quoteBuy` is strictly higher
- [x] T050t Curve graduation (D-13): `publicMint(MAX_SUPPLY)` flips `graduated`, auto-seeds the locked
      pool via `seedLiquidity`, and the sole holder can claim ~all of a post-graduation fee
- [x] T051t No mint after graduation (D-13): `publicMint` reverts `AlreadyGraduated` once sold out
- [x] T046 `forge test` green — all **15** tests pass on a real `PoolManager` (4-quadrant + seed + lock
      + INV-1 NFT-sync + AC-4/5/6 + curve quote/convexity/price-rise/graduation/no-remint).

## Phase 5 — Deploy
- [~] T050 `Deploy.s.sol`: EZ404 → HookMiner → `new{salt}` → wire → `initialize` at **curve final
      price** (`curveFinalReserves()` → `sqrtPFinal`); **no day-one seed** — the curve escrows mint
      ETH and auto-seeds on sell-out (D-13). Compiles.
- [ ] T051 Fork dry-run; assert `addr & 0x3FFF == 0xA44` (AC-7)
- [ ] T052 Parameterize chain (PoolManager address per network)

## Phase 6 — Audit pass
- [x] T060 Genesis low-`W` guard — **(D-13: dissolved)** the coin-age `W = B·t−S` blow-up is gone.
      Flat `acc += mulDiv(F, ACC, B)` with small `B` just means few holders legitimately split a fee;
      the `B == 0` case rolls into `undist`. No genesis guard needed; revisit only if a single-NFT
      early dominator is judged a problem (then a `B`-threshold hold could roll into `undist`).
- [ ] T061 `seedLiquidity` spot-price guard — D-11. Pool is now initialized at the curve final price
      and graduation seeds once off `getSlot0`; the single-seed sandwich surface remains. Consider
      seeding at `curveFinalReserves()` directly (not spot) or a deviation band.
- [ ] T062 Decide "% of mint ETH to LP" knob default — D-9. Currently 100% of `ethRaised` seeds the
      locked pool on graduation; a split-to-treasury knob is still open.
- [~] T063 Numerics review: **(D-13: simplified)** rounding-against-claimant/T028 clamp removed (no
      subtracted term). Still open — confirm `ACC = 1<<96` headroom with `B ≤ ~5000` and realistic
      per-swap fees, and multi-distribution accumulator drift, plus curve `mulDiv` floor dust bounds.
- [~] T064 DN404 mirror-NFT audit: `_transferFromNFT` override done; PM/hook excluded+skipNFT;
      still TODO — confirm test routers / any other NFT-holding actors are excluded or skipNFT
- [ ] T065 **(D-13: new)** Stalled-curve escape hatch: a curve that never reaches `MAX_SUPPLY` strands
      escrowed `ethRaised` and never opens trading. v1 has no manual `graduate()` (it would reintroduce
      a pool-price-vs-curve mismatch). Decide: leave documented-only, add a time/threshold-gated
      graduate, or a refund path. Open risk, not yet mitigated.

## Immediate next
Phase 4 complete (15 tests green on a real `PoolManager`; D-13 curve + flat-ledger refactor builds and
passes). Next: T051 fork deploy dry-run (assert `addr & 0x3FFF == 0xA44`), then the Phase 6 items —
T061 seed spot-price guard, T062 %-to-LP knob, and the T065 stalled-curve decision.

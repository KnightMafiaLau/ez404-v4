# Implementation Plan: EZ404 on Uniswap V4 Hooks

**Feature ID:** 001-ez404-v4-hooks
**Input:** `spec.md` · **Governs:** `tasks.md`

> HOW. Architecture, stack, structure, and phased build. Decisions and their rationale live in
> `research.md`; state shapes and formulas in `data-model.md`; behavioral contracts in
> `contracts/`.

## Constitution check
- DN404 retained (P1) ✓ · fees decoupled from ticks (P2) ✓ · permanent lock (P3) ✓ ·
  coin-age reflection following holders (P4) ✓ · `P0 = _unit/mintPrice` (P5) ✓ ·
  settle-before-move invariant (P6) ✓ · controller-only one-time wiring (P7) ✓ ·
  four-quadrant + settlement + conservation + exclusion tests (P8) ✓ · honest CI (P9) ✓.
No deviations.

## Tech stack
- **Solidity** ^0.8.26
- **Foundry** (forge / anvil / cast)
- **Uniswap V4** — `v4-core` (singleton PoolManager, flash accounting via unlock), `v4-periphery`
  (`BaseHook`, `HookMiner`, `LiquidityAmounts`)
- **Solady** `DN404` + `DN404Mirror` for the hybrid token
- Native ETH as `currency0` (`address(0)`); EZ404 as `currency1`

## Components

### EZ404 (src/EZ404.sol)
DN404 hybrid token + dual-currency coin-age reward ledger + capped public mint.
- `_unit() = 10_000e18`; `pbMintPrice = 0.001 ether`; `MAX_SUPPLY = 5000` units.
- Overrides DN404 balance mutators (`_transfer`, `_mint`, `_burn`) to call `_syncRewards`
  before the balance changes (P6).
- `notifyFeeETH()` / `notifyFeeToken(amt)` — hook-only fee intake → `_accrue`.
- `claim()` — pays accrued ETH and EZ404.
- `mintForSeed(to, amt)` — hook-only mint for the pool side of the seed.
- `setHook`, `setExcluded` — controller-only one-time wiring.

### EZ404Hook (src/EZ404Hook.sol)
V4 `BaseHook`.
- Permissions: `beforeAddLiquidity`, `beforeRemoveLiquidity`, `afterSwap`,
  `afterSwapReturnDelta` → flags `0xA44`.
- `_beforeAddLiquidity`: allow only `sender == address(this)` (seed path).
- `_beforeRemoveLiquidity`: revert always.
- `_afterSwap`: skim `feeBps` of the unspecified leg, `take` it, route to the token's ledger,
  return `+fee` on the unspecified currency. Dual-currency by construction.
- `seedLiquidity()` (controller) → `poolManager.unlock` → `unlockCallback`: read slot0, compute
  full-range liquidity for the ETH amount, `modifyLiquidity`, `settle{value}` ETH side, `sync` +
  `mintForSeed` + `settle` token side, refund ETH dust to controller.
- `setKey` (controller, one-time).

### Deploy (script/Deploy.s.sol)
1. Deploy `EZ404` (+ its DN404 mirror).
2. Mine hook address with `HookMiner.find(CREATE2_DEPLOYER, 0xA44, creationCode, ctorArgs)`,
   ctorArgs referencing the EZ404 address.
3. `new EZ404Hook{salt}` via the CREATE2 deployer.
4. `setHook(hook)`, `setKey(key)`, `setExcluded(PoolManager/hook/token/dead, true)`.
5. `poolManager.initialize(key, sqrtP0)` with `sqrtP0 = sqrt(_unit << 192 / mintPrice)`.
6. `seedLiquidity{value: …}` for the day-one locked position.

## Project structure
```
src/      EZ404.sol, EZ404Hook.sol
test/     EZ404Hook.t.sol (four-quadrant + seed + lock + conservation)
script/   Deploy.s.sol
specs/001-ez404-v4-hooks/  spec, plan, research, data-model, contracts/, quickstart, tasks
```

## Dual-currency coin-age math (summary)
A single `accFeePerShare` cannot express balance × time. Use a **two-accumulator** scheme per
currency. With `B` = total eligible balance, `S = Σ balᵢ·t0ᵢ`, total weight is
`W(t) = B·t − S`. For a fee `F` at time `t`: `accA += F·t/W`, `accB += F/W`. A holder's reward
is `bal·(accA−ckptA) − bal·t0·(accB−ckptB)`. O(1) per distribution and per balance change. Full
derivation and conservation argument in `data-model.md`.

## V4 specifics
- `afterSwap` can only return a delta on the **unspecified** currency (single `int128`). The
  unspecified currency is currency0 iff `exactInput != zeroForOne` → ETH is unspecified in only
  two of four quadrants, forcing dual-currency. Sign table in `contracts/IEZ404Hook.md`.
- Hook nets zero: `take(c, hook, fee)` (delta −fee) then `return +fee` (V4 credits +fee, charges
  the swapper). Verified per quadrant in tests.
- DN404 mirror NFT sync at swap time → PoolManager / routers / hook must `skipNFT` or be excluded.

## Phases
- **Phase 0 — Spec & plan.** This document + spec + research + data-model + contracts. ✓
- **Phase 1 — Scaffold.** Foundry project, deps, CI, structure. ✓
- **Phase 2 — Token.** EZ404 with DN404 + ledger + mint. Compiles, unit-tested.
- **Phase 3 — Hook.** EZ404Hook skim + seed + lock. Compiles.
- **Phase 4 — Tests.** Four-quadrant, seed, lock, conservation, exclusion, JIT. Green.
- **Phase 5 — Deploy.** CREATE2 mine + initialize@P0 + seed script; dry-run on a fork.
- **Phase 6 — Audit pass.** Genesis-weight guard, seed-price guard, numerics review.

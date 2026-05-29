# Feature Spec: EZ404 on Uniswap V4 Hooks

**Feature ID:** 001-ez404-v4-hooks
**Status:** Spec complete · Implementation WIP
**Date:** 2026-05-29

> WHAT and WHY. No implementation detail here — see `plan.md` for HOW.

## 1. Problem

The original EZ404 / `404pumpfun` (a 2024 DN404 fork) launched a hybrid token and, on every
mint, opened a full-range Uniswap **V3** LP funded by the buyer's ETH. The LP NFT was held by
the contract but credited to the minter, who could later claim swap fees. Known defects:

- **Dust LP & price discontinuity.** The pool was initialized at sqrtPriceX96 = 2^96 (a 1:1
  price), wildly mismatched against the ~1e-7 effective mint price. First trades arbitraged
  the gap.
- **O(n) fee accounting.** Claiming walked a per-minter `ownLPs` array.
- **Unimplemented whitelist.** `whitelistMint` had a `// check signature` comment and no check.
- **Frozen entitlement.** "Minter owns the fee stream forever" could not follow the token as
  it changed hands.

## 2. Goals

- Rebuild on **Uniswap V4 hooks**, keeping the **DN404 hybrid** token.
- Replace the per-minter LP-fee model with a **holdings-based, coin-age-weighted ETH/token
  dividend** (reflection) that is O(1) per swap and per transfer.
- Seed a single **permanently-locked, full-range** pool at the **correct launch price**.
- Make launch economics **immutable** and the contract **non-custodial**.

## 3. Non-goals

- No bonding curve (day-one locked pool instead).
- No re-centering / active liquidity management (impossible under a locked position by design).
- No upgradeability, no admin fee withdrawal, no pause.
- Whitelist/signature mint is **out of scope** for v1 (it was never functional in the original;
  we drop it rather than ship a stub).

## 4. Users & stories

- **Minter** — pays ETH to `publicMint`, receives EZ404 (and NFTs at unit granularity). Their
  ETH (or a configured fraction) seeds the locked pool.
- **Holder / earner** — holds EZ404 and accrues a pro-rata, coin-age-weighted share of swap
  fees, claimable in ETH and/or EZ404. Selling forfeits future accrual; the new holder starts
  earning (age resets on receive).
- **Trader** — swaps ETH↔EZ404 against the locked pool; pays the pool's LP fee plus a hook
  dividend skim.
- **Deployer / controller** — deploys, mines the hook address, wires keys and exclusions, and
  performs the one-time seed. Has no ongoing economic privilege.

## 5. Functional requirements

- **FR-1 Mint.** `publicMint(qty)` is payable at a fixed price; enforces `MAX_SUPPLY`; mints
  EZ404 to the buyer at `_unit` granularity.
- **FR-2 Seed.** A single full-range position is created from mint ETH at `P0 = _unit/mintPrice`
  and locked forever. Pool side tokens are minted to the PoolManager and excluded from accrual.
- **FR-3 Lock.** No party (including controller) can add or remove liquidity after seed; outside
  adds revert, all removes revert.
- **FR-4 Fee skim.** On every swap the hook takes `feeBps` of the *unspecified* leg and routes it
  to the dividend ledger. Because the unspecified leg is ETH in only two of four quadrants, the
  skim is **dual-currency**: distributed in whichever currency was collected.
- **FR-5 Accrual.** Collected fees accrue to eligible holders pro-rata by **balance × holding
  time**. O(1) per distribution and per balance change.
- **FR-6 Claim.** A holder can claim accrued ETH and EZ404 at any time.
- **FR-7 Exclusions.** PoolManager, hook, token contract, dead address, and the pool never accrue
  and never count toward total weight.
- **FR-8 Settlement invariant.** Every balance-changing path settles rewards before the balance
  moves (transfer, mint, burn, NFT ops, seed).

## 6. Acceptance criteria

- **AC-1** Initializing at `P0` and seeding leaves no first-trade arbitrage gap vs. mint price.
- **AC-2** For all four swap quadrants, exactly the correct currency is skimmed by exactly
  `feeBps`, the swap settles (no `CurrencyNotSettled`), and the hook nets zero delta.
- **AC-3** Any add-liquidity from a non-hook sender reverts; any remove-liquidity reverts.
- **AC-4** Over an arbitrary transfer/mint/burn/fee sequence, total claimed + claimable +
  undistributed never exceeds total notified (conservation; no over-payment).
- **AC-5** Fees attributable to excluded accounts are zero; the locked pool earns nothing.
- **AC-6** A freshly-bought (age≈0) balance earns ≈0 from a fee distributed immediately after
  purchase (coin-age defeats JIT reward farming).
- **AC-7** The hook address satisfies the V4 permission-bit pattern (`addr & 0x3FFF == 0xA44`).

## 7. Key entities (summary; detail in `data-model.md`)

- **EZ404 token** — DN404 hybrid + dual-currency coin-age reward ledger + capped public mint.
- **EZ404Hook** — V4 BaseHook: liquidity lock, swap-fee skim, one-time seed via unlock callback.
- **Reward ledger** — paired coin-age accumulators (ETH and EZ404), per-holder checkpoints,
  claimable balances, undistributed rollover.

## 8. Open risks (tracked, not blocking the spec)

- Low total-weight genesis window: accumulators can blow up and an early whale can eat early
  fees. Mitigation candidates: weight threshold / vesting.
- `seedLiquidity` reads spot price → sandwichable. Mitigation: seed at fixed `P0` or add a
  deviation band vs `P0`/TWAP.
- Sellable buyer supply ≈ locked pool supply → a coordinated dump can crater price. Inherent to
  the model, surfaced via the "% of mint ETH routed to LP" knob.

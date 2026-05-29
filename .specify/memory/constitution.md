# EZ404-V4 Constitution

These are the non-negotiable principles for the project. Every spec, plan, task, and
line of code is checked against this document. Amendments require an explicit entry in
the amendment log at the bottom.

Version: 1.0.0 · Ratified: 2026-05-29

---

## Principle 1 — DN404 hybrid is core
EZ404 ships as a DN404 (ERC-20 + ERC-721 mirror) hybrid token. The "404" identity is the
product, not an implementation detail. We do not degrade to a plain ERC-20 to simplify the
reward math. The `_unit` (ERC-20 wei per whole NFT) is fixed at deploy and chosen so the
mint price buys exactly one NFT-unit.

## Principle 2 — Fees are decoupled from any tick range
A permanently-locked liquidity position can never be re-centered. A narrow range would
strand out-of-range and die. Therefore fee entitlement MUST NOT be tied to a tick range or
to ownership of a concrete LP position. Fees are skimmed at swap time by the hook and
distributed through an O(1) share ledger. This replaces the original O(n) `ownLPs` loop.

## Principle 3 — Liquidity is permanently locked
The pool is seeded full-range on day one from mint ETH. `beforeRemoveLiquidity` reverts
unconditionally; `beforeAddLiquidity` accepts only the hook itself (seed path). There is no
admin escape hatch. Locked means locked.

## Principle 4 — Fee entitlement follows token holders, coin-age weighted
Holding EZ404 earns a pro-rata share of swap fees (reflection/dividend model). Weight is
balance × holding-time (coin-age). Age resets on receive. This deliberately drops the
original "minter owns the fee stream forever" design in favour of a live, transferable
holdings-based dividend. Every balance-changing path settles rewards first.

## Principle 5 — No price discontinuity at launch
The pool initialization price MUST equal the effective mint price. `P0 = _unit / mintPrice`.
Seeding or initializing at any other price re-introduces the original launch-arb bug.

## Principle 6 — Accounting invariants are sacred
- Every path that changes an eligible balance (transfer, mint, burn, NFT op, seed) MUST
  call the reward-settlement hook before the balance moves.
- The accumulators must conserve: distributed + undistributed == notified, within rounding
  that always rounds *against* the claimant (no over-payment).
- Excluded accounts (PoolManager, hook, token contract, dead, pool) NEVER accrue and NEVER
  contribute to total weight.

## Principle 7 — Minimal trust, immutable economics
Post-deploy economics (fee bps, mint price, supply cap, lock) are immutable. The only
privileged actor is `controller`, and only for one-time wiring: `setHook`, `setKey`,
`setExcluded`, and `seedLiquidity`. No mint authority beyond the capped public mint and the
one-time pool seed. No upgradeability.

## Principle 8 — Test-first on the dangerous parts
The following are proven by tests before they are trusted:
1. `afterSwapReturnDelta` sign across all four {direction × exact-in/out} quadrants.
2. Flash-accounting settlement nets to zero on seed and on every swap.
3. Reward conservation across transfer/mint/burn sequences.
4. Exclusions actually prevent the locked pool from eating fees.

## Principle 9 — Honest status
Implementation status is tracked truthfully in `tasks.md` and surfaced in CI. WIP is labelled
WIP. A red build is acceptable while tasks are open; a green build that hides skipped tests
is not.

---

## Amendment log
- 1.0.0 (2026-05-29): Initial ratification.

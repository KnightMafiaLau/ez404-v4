# EZ404-V4

A Uniswap **V4 hooks** rebuild of [`404pumpfun`](https://github.com/KnightMafiaLau/404pumpfun) — a
2024 DN404 fork. EZ404 keeps the DN404 (ERC-20 + ERC-721) hybrid token and replaces the original's
per-minter Uniswap V3 LP with a single **permanently-locked, full-range V4 pool** plus a
**holdings-based, coin-age-weighted swap-fee dividend**.

> **Status: WIP.** Spec and plan are complete; the contracts are drafted and being brought to a
> green build. See [`tasks.md`](specs/001-ez404-v4-hooks/tasks.md) and CI for live status.
> **Not audited. Do not deploy to mainnet.**

## What it does

- **Mint.** `publicMint` takes ETH at a fixed price and mints EZ404 at NFT-unit granularity.
- **Locked liquidity.** Mint ETH seeds one full-range V4 position at the launch price
  `P0 = _unit / mintPrice`, then locks it forever — `beforeRemoveLiquidity` reverts, and only the
  hook's own seed path may add.
- **Swap-fee dividend.** On every swap the hook skims `feeBps` of the trade and distributes it to
  EZ404 holders pro-rata by **balance × holding time** (coin-age). Hold to earn; selling forfeits
  future accrual. Claimable in both ETH and EZ404.

## Why this design

The original initialized its pool at a 1:1 price against a ~1e-7 effective mint price (instant
arb), walked an O(n) per-minter array to pay fees, froze the fee stream to the original minter, and
shipped an unimplemented whitelist. This rebuild fixes each of those:

| Original | EZ404-V4 |
|---|---|
| Pool at 1:1, mismatched mint price | Initialize at `P0 = _unit/mintPrice` (no launch arb) |
| O(n) `ownLPs` fee loop | O(1) coin-age share ledger, decoupled from any tick range |
| Fees frozen to minter | Fees follow holders (reflection), coin-age weighted |
| Per-mint dust V3 LPs | One locked full-range V4 pool |
| `// check signature` stub | Whitelist dropped from v1 (returns behind its own spec) |

A locked position can never be re-centered, so it is forced full-range; tying fees to a tick range
would strand out-of-range liquidity. The share ledger sidesteps that entirely.

## Key V4 detail

`afterSwap` can only return a delta on the **unspecified** currency, and ETH is unspecified in only
two of four {direction × exact-in/out} quadrants. So the fee skim is **dual-currency** by
necessity — see the four-quadrant truth table in
[`contracts/IEZ404Hook.md`](specs/001-ez404-v4-hooks/contracts/IEZ404Hook.md).

## Spec-Driven Development

This repo follows an SDD workflow. Read the specs before the code:

```
.specify/memory/constitution.md         non-negotiable principles
specs/001-ez404-v4-hooks/
  spec.md            WHAT & WHY (requirements, user stories, acceptance criteria)
  plan.md            HOW (architecture, stack, phases)
  research.md        decision log with rationale (D-1 … D-12)
  data-model.md      state shapes + the dual-currency coin-age math
  contracts/         behavioral contracts for EZ404 and EZ404Hook
  quickstart.md      build / test / deploy
  tasks.md           ordered task list with honest status
src/                 EZ404.sol, EZ404Hook.sol
test/                EZ404Hook.t.sol
script/              Deploy.s.sol
```

## Build

```bash
curl -L https://foundry.paradigm.xyz | bash && foundryup
forge install foundry-rs/forge-std Uniswap/v4-core Uniswap/v4-periphery Vectorized/solady
forge build
forge test -vvv
```

See [`quickstart.md`](specs/001-ez404-v4-hooks/quickstart.md) for deploy.

## License

MIT. See [LICENSE](LICENSE).

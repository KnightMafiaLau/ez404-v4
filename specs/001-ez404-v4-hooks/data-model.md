# Data Model & Formulas

State shapes and the math behind (a) the pump.fun-style mint curve and (b) the dual-currency,
flat-per-whole-NFT reward ledger. See D-13 in `research.md` for the why.

---

## Constants (EZ404)
| Name | Value | Meaning |
|---|---|---|
| `_unit()` | `10_000e18` | ERC-20 wei per whole NFT |
| `MAX_SUPPLY` | `5000` | NFT-units sold on the curve |
| `ACC` | `1 << 96` | fixed-point scale for the reward accumulators |
| `V_TOK0` | `67_650_000e18` | curve virtual token reserve (67.65M) |
| `V_ETH0` | `6.765 ether` | curve virtual ETH reserve |

`k = V_TOK0 · V_ETH0` is the constant product. Reserve ratio mirrors pump.fun
(`vTok0 : sold : remaining = 1.353 : 1 : 0.353`) ⇒ ~14.7× price run start→finish. First NFT
≈ 0.001 ETH; full sell-out raises ≈ 19.2 ETH; final ≈ 0.0147 ETH/NFT.

## Mint curve (constant product, buy-only)
Current virtual reserves derive from cumulative state:
```
vTok = V_TOK0 − mintedUnits·_unit()      // tokens "left" on the curve
vETH = V_ETH0 + ethRaised                // ETH taken so far
```
Cost to buy `qty` whole NFTs (Δ = `qty·_unit()`), the exact CP integral over the chunk:
```
cost = mulDiv(vETH, Δ, vTok − Δ)         // floored ⇒ buyer pays ≤ exact, never over-charged
```
`publicMint` escrows `cost`, mints `Δ`, refunds overpay. On `mintedUnits == MAX_SUPPLY` it
`_graduate()`s: ships all `ethRaised` to the hook's `seedLiquidity` once. Buy-only; no sell-back.

## Graduation seed price
Pool is `initialize`d (deploy-time) at the curve's deterministic final reserves so the last fill
and the opening spot are continuous:
```
vTokFinal = V_TOK0 − MAX_SUPPLY·_unit()
vEthFinal = mulDiv(V_ETH0, V_TOK0, vTokFinal)        // = k / vTokFinal
sqrtP     = sqrt(mulDiv(vTokFinal, 1<<192, vEthFinal))   // token-per-ETH (cur1/cur0), ETH = cur0
```
(`curveFinalReserves()` exposes `vTokFinal, vEthFinal`.) Actual `ethRaised` differs from the
theoretical raise only by floor dust, so any residual arb is sub-wei on the marginal price.

## Reward-ledger state (EZ404)
| Symbol | Type | Updated on | Meaning |
|---|---|---|---|
| `B` | uint256 | balance change | total **eligible whole-NFT count** (excludes excluded accounts) |
| `_weight[u]` | uint256 | balance change | `u`'s eligible whole-NFT count = `floor(bal/_unit())` |
| `excluded[u]` | bool | wiring | true ⇒ never accrues, never in `B` |
| `acc0` | uint256 | ETH fee | ETH accumulator |
| `acc1` | uint256 | token fee | EZ404 accumulator |
| `_ck0/_ck1[u]` | uint256 | settle | per-holder checkpoints |
| `claimable0[u]` | uint256 | settle | ETH owed to `u` |
| `claimable1[u]` | uint256 | settle | EZ404 owed to `u` |
| `undist0/undist1` | uint256 | accrue | rollover when `B == 0` (no eligible NFTs yet) |

No `tStart` / `t0` / `S`: dividends carry no time component (coin-age removed, D-13).

## Hook state (EZ404Hook)
| Symbol | Meaning |
|---|---|
| `poolManager` | V4 singleton |
| `token` | EZ404 |
| `controller` | one-time wiring + seed authority |
| `key`, `tickSpacing` | the single pool |
| `feeBps` | dividend skim (e.g. 100 = 1%) |

## Distribution (per currency)
On a fee `F` (currency c) with `F' = F + undist`:
```
if B == 0 or F' == 0:  undist = F';  return          // no eligible NFTs yet → roll over
undist = 0
acc += mulDiv(F', ACC, B)                            // split F' evenly across all B NFTs
```

## Settlement (per holder, per currency)
For holder `u` with eligible whole-NFT weight `w`:
```
claimable += mulDiv(w, acc − ckpt, ACC)
ckpt = acc
```
Intuition: each whole NFT `u` holds earns `(acc − ckpt)/ACC` per unit, i.e. an equal slice of every
fee accrued since `u` last settled.

## Conservation & solvency
Summing one fee `F'` over all eligible holders:
```
Σ_u floor(w_u · Δacc / ACC)  ≤  (Σ_u w_u)·Δacc/ACC  =  B·Δacc/ACC
                             =  B·floor(F'·ACC/B)/ACC  ≤  F'
```
So the distributed total is ≤ `F'` (every term is a floored `FullMath.mulDiv`); rounding dust stays
in the contract. There is **no subtracted term**, so settlement can never underflow.
**Invariant:** `Σ claimed + Σ claimable + undist + dust == Σ notified`.

## Eligibility (dynamic, no snapshot)
- Hold ≥ 1 whole NFT (`floor(bal/_unit()) ≥ 1`) → earning; weight tracks the whole-NFT count.
- Drop below a unit → that weight decrements (stop earning on the lost NFT); buy back → resume.
- Dust (`bal mod _unit()`) never earns. Excluded actors (PM/hook/token) are out regardless.

## Numeric guards (tracked in tasks)
- `ACC = 1<<96` headroom: with `B ≤ ~5000` and realistic per-swap fees, `F·ACC/B` and `w·Δacc/ACC`
  stay far inside uint256 and lose ≪1 wei to flooring (T063).
- Curve denominator `vTok − Δ` is always > 0 (Δ ≤ `MAX_SUPPLY·_unit()` < `V_TOK0`).
- JIT: dropping coin-age reopens single-fee JIT; judged marginal (D-13), revisit if it bites.

## DN404 integration points
Every DN404 balance mutator settles first, then re-syncs whole-NFT weight:
- `_transfer(from,to,amt)` → settle `from`/`to`, move, `_setWeight(·, bal/_unit())`.
- `_mint(to,amt)` (curve mint, seed) → settle `to`, mint, re-weight.
- `_burn(from,amt)` → settle `from`, burn, re-weight.
- `_transferFromNFT` (mirror `transferFrom`) bypasses `_transfer` → overridden with the same
  settle/re-weight shape (INV-1). Excluded actors (PM/hook) skip accrual and weight.

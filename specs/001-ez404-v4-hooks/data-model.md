# Data Model & Formulas

State shapes and the math behind the dual-currency coin-age reward ledger.

---

## Constants (EZ404)
| Name | Value | Meaning |
|---|---|---|
| `_unit()` | `10_000e18` | ERC-20 wei per whole NFT |
| `pbMintPrice` | `0.001 ether` (`1e15`) | ETH per `_unit` minted |
| `MAX_SUPPLY` | `5000` | max NFT-units mintable via public mint |
| `P0` | `_unit/pbMintPrice = 1e7` | EZ404 per ETH (raw), launch price |

## Reward-ledger state (EZ404)
| Symbol | Type | Updated on | Meaning |
|---|---|---|---|
| `tStart` | uint256 | ctor | epoch origin; `_now() = block.timestamp − tStart` |
| `B` | uint256 | balance change | total **eligible** balance (excludes excluded accounts) |
| `S` | uint256 | balance change | `Σ balᵢ · t0ᵢ` over eligible holders |
| `t0[u]` | uint256 | receive | holder `u`'s coin-age origin (age resets on receive) |
| `_eligBal[u]` | uint256 | balance change | tracked eligible balance of `u` |
| `excluded[u]` | bool | wiring | true ⇒ never accrues, never in `B`/`S` |
| `accA0,accB0` | uint256 | ETH fee | ETH accumulators |
| `accA1,accB1` | uint256 | token fee | EZ404 accumulators |
| `_ckA0/_ckB0/_ckA1/_ckB1[u]` | uint256 | settle | per-holder checkpoints |
| `claimable0[u]` | uint256 | settle | ETH owed to `u` |
| `claimable1[u]` | uint256 | settle | EZ404 owed to `u` |
| `undist0,undist1` | uint256 | accrue | rollover when `W==0` (no eligible weight yet) |

`P` is a fixed-point scale used by `FullMath.mulDiv` to keep precision in the accumulators.

## Hook state (EZ404Hook)
| Symbol | Meaning |
|---|---|
| `poolManager` | V4 singleton |
| `token` | EZ404 |
| `controller` | one-time wiring + seed authority |
| `key`, `tickSpacing` | the single pool |
| `feeBps` | dividend skim (e.g. 100 = 1%) |

## Coin-age weight
Total weight at time `t`:
```
W(t) = Σ balᵢ · (t − t0ᵢ) = (Σ balᵢ)·t − Σ balᵢ·t0ᵢ = B·t − S
```
`B` and `S` change only when a balance changes, so `W(t)` is available in O(1) at any `t`.

## Distribution (per currency)
On a fee `F` (currency c) at time `t`, with `F' = F + undist`:
```
if W == 0 or F' == 0:  undist = F';  return          // no eligible weight yet → roll over
undist = 0
accA += mulDiv(F', t·P, W)
accB += mulDiv(F', P,   W)
```

## Settlement (per holder, per currency)
For holder `u` with eligible balance `b` and origin `t0`:
```
claimable += mulDiv(b,      accA − ckptA, P)        // balance × time term
           − mulDiv(b·t0,   accB − ckptB, P)        // minus origin term
ckptA = accA;  ckptB = accB
```
Intuition: `b·(accA−ckptA) − b·t0·(accB−ckptB) = b·Σ F·(t−t0)/W = u`'s share of each fee weighted
by its own coin-age over the interval.

## Conservation
Summing the settlement over all eligible holders for one fee `F'`:
```
Σ_u [ b_u·(t·P/W) − b_u·t0_u·(P/W) ] / P
  = (1/W)·[ t·Σ b_u − Σ b_u·t0_u ]·F'
  = (1/W)·(B·t − S)·F' = (W/W)·F' = F'
```
So the distributed total equals `F'` exactly in exact arithmetic. In integer math every term uses
`FullMath.mulDiv` (floor), so the sum is ≤ `F'`: rounding dust stays in the contract, never
over-pays. **Invariant:** `Σ claimed + Σ claimable + undist + dust == Σ notified`.

## Numeric guards (tracked in tasks)
- `claimable += A − Bterm` must not underflow: prove `A ≥ Bterm` (holds because `t ≥ t0` over the
  accrual interval; needs care across the checkpoint window).
- Genesis `W ≈ 0`: route to `undist` until weight is material (D-11).
- `t0` policy on partial receive: v1 resets age on any receive (simplest, slightly punitive to
  accumulators); a balance-weighted blend is a documented alternative.
- All multiplications use `FullMath.mulDiv` with scale `P` to avoid truncation.

## DN404 integration points
Every DN404 balance mutator must settle first:
- `_transfer(from,to,amt)` → settle `from` and `to`, update `B`/`S`/`t0`, then move.
- `_mint(to,amt)` (public mint, seed) → settle `to`, then mint.
- `_burn(from,amt)` → settle `from`, then burn.
- NFT-side ops route through these ERC-20 balance changes; excluded actors (PM/hook) skip accrual.

# Research & Decision Log

Each decision records the question, the options weighed, what was chosen, and why. This is the
"why it is the way it is" record for `001-ez404-v4-hooks`.

---

## D-1 — Keep DN404, do not flatten to ERC-20
**Q:** The reward math is simpler on a plain ERC-20. Drop the hybrid?
**Decision:** Keep DN404. The 404 identity is the product (P1). Accept the extra complexity:
mirror-NFT sync at swap time, `_unit` granularity, exclusion of NFT-side actors.

## D-2 — Fee model: real LP-fee carrier vs. share ledger
**Options:** (1) hold a concrete LP position and distribute its collected fees; (2) a hook-level
swap-fee skim feeding an O(1) share ledger, decoupled from any tick range.
**Decision:** (2). A *locked* position can never be re-centered, so it is forced full-range; a
narrow locked range would strand out-of-range and die permanently. Tying fees to a position also
re-creates the in/out-of-range problem and the original O(n) loop. The share ledger sidesteps all
of it (P2).

## D-3 — Liquidity shape: bonding curve vs. day-one locked full-range
**Decision:** Day-one full-range, seeded from mint ETH, permanently locked. No bonding curve.
Simpler launch, no curve-migration step, and matches the "locked LP" identity (P3).

## D-4 — Fee entitlement: sticky-to-minter vs. follows holders
**Decision:** Follows token holders → a reflection/dividend token (hold EZ404 = earn fees). This
deliberately drops the original "minter owns the fee stream forever" soul. Consequence: fees must
settle on every transfer, and pool/PM/hook/contract/dead MUST be excluded or the locked pool eats
most fees (the classic reflection+LP trap) (P4, P7).

## D-5 — Weighting: flat vs. coin-age
**Decision:** Coin-age (balance × holding-time), age resets on receive. Honors both "weighted"
and "follows holders," and discourages mercenary in-and-out farming.

## D-6 — Coin-age accounting: single vs. two accumulators
**Problem:** A single `accFeePerShare` (MasterChef/Synthetix style) cannot express balance × time.
**Decision:** Two-accumulator scheme. `W(t) = B·t − S` where `B = Σ balᵢ`, `S = Σ balᵢ·t0ᵢ`
(both updated only on balance change). Per fee `F` at time `t`: `accA += F·t/W`, `accB += F/W`.
Reward `= bal·(accA−ckptA) − bal·t0·(accB−ckptB)`. O(1) everywhere; conserves (see data-model).
**Escape hatch:** if auditability is preferred over exactness, swap the core for discrete
multiplier tiers + a `poke()`. Not chosen for v1.

## D-7 — Fee currency: ETH-only vs. dual-currency
**Key V4 finding:** `afterSwap` returns a single `int128` and can only charge the *unspecified*
currency. ETH (currency0) is unspecified in only two of four {direction × exact-in/out} quadrants
(`unspecIs0 = exactInput != zeroForOne`). So:
- ETH-only fees are either gameable (skip the half where ETH is specified) or need a harvest-swap
  (MEV-exposed, adds a swap every block).
**Decision:** **Dual-currency.** Skim `feeBps` of the unspecified leg every swap; distribute in
whichever currency was collected, via paired accumulators (`accA0/accB0` for ETH, `accA1/accB1`
for EZ404; `W/B/S/t0` shared). Non-gameable, no harvest, no MEV surface.
**Alt offered:** ETH-only + `harvest()` if the user insists on single-currency dividends. Not
chosen.

## D-8 — Seed price must equal mint price
At any seed price ≠ effective mint price the original launch-arb returns. `P0 (EZ404 per ETH,
raw) = _unit/mintPrice = 1e22 / 1e15 = 1e7`. `sqrtP0 = uint160(sqrt(mulDiv(_unit, 1<<192,
mintPrice)))`. `initialize(key, sqrtP0)` before the first seed. Sanity: `0.001 ETH × P0 = 1e22 wei
= exactly one _unit` ✓ (P5).

## D-9 — Supply inflation from pairing
At `P0` full-range, the paired `amount1 ≈ amount0·P0 = _unit`, so each minted NFT-unit pairs ~1×
`_unit` into the pool → ~2× `_unit` minted per buyer unit (buyer + pool). Bounded ~1e8 tokens at
`MAX_SUPPLY = 5000`. Pool side is excluded, so no coin-age pollution.
**New knob surfaced:** *% of mint ETH routed to the locked LP* (currently 100%). Lowering it cuts
both inflation and depth; remainder could go to treasury. **Inherent risk (not a bug):** sellable
buyer supply ≈ locked pool supply → a mass dump can crater price.

## D-10 — Hook address mining
Flags `(1<<11)|(1<<9)|(1<<6)|(1<<2) = 0xA44`. Requirement: `hookAddr & 0x3FFF == 0xA44`
(`BaseHook.validateHookAddress` reverts otherwise). Deploy order: EZ404 first → its address into
the hook ctor args → `HookMiner.find` with **exact** ctor args → `new EZ404Hook{salt}` via the
CREATE2 deployer (`0x4e59…4956C`).

## D-11 — MEV / economic hazards
- **(good)** Coin-age defeats JIT reward farming: a flash-bought balance has age ≈ 0, earns ≈ 0.
- **(risk)** Low-`W` genesis window: `accA/accB` can blow up and a dominant early holder eats early
  fees. Mitigate with a `W`-threshold hold (roll into `undist` until weight is material) or vesting.
- **(risk)** `seedLiquidity` uses `getSlot0` spot price → sandwichable. Mitigate by seeding at fixed
  `P0` or adding a deviation band vs `P0`/TWAP.
- **(minor)** Fee on the unspecified leg lets a trader pick the smaller leg (exact-in charges the
  output, exact-out charges the input; they differ by ~the LP fee). Accepted.

## D-12 — Whitelist mint dropped
The original `whitelistMint` had no signature check (`// check signature` only). Rather than ship
a stub, v1 omits it. Can return later as a signed/Merkle gate behind its own spec.

## D-13 — Pivot: pump.fun curve + flat-per-whole-NFT dividends
**Supersedes D-3 (no curve), D-5 (coin-age), D-6 (two accumulators), D-8 (seed = mint price);
refines D-4/D-9.** A long design exploration (whitepaper + degen/NFT framing) converged here.

**(a) Mint via a pump.fun constant-product curve, graduate on sell-out.** Replaces the fixed-price
`publicMint` + per-mint instant seed.
- Virtual reserves `x·y = k`; buying Δ tokens costs exactly `y·Δ/(x−Δ)` (the CP integral over a
  discrete chunk — *exact*, not an approximation, so whole-NFT quantization is clean).
- Reserves chosen to mirror pump.fun's ratio `vTok0 : sold : remaining = 1.353 : 1 : 0.353`
  (~14.7× price run), scaled to the 5000-NFT / 50M-token curve:
  `V_TOK0 = 67.65M`, `V_ETH0 = 6.765 ETH`. First NFT ≈ 0.001 ETH; sell-out raises ≈ 19.2 ETH;
  final ≈ 0.0147 ETH/NFT.
- **ETH is escrowed** in the token until sell-out (reverses D-9 Knob-1's per-mint instant seed),
  then `_graduate()` ships all `ethRaised` to `seedLiquidity` once. `graduated` gate; sell-out is
  the only trigger (`mintedUnits == MAX_SUPPLY`).
- **Curve is buy-only** (no sell-back); exit is post-graduation via the AMM. Simpler, no curve-dump.
- **Seed at the curve's final price.** Pool is `initialize`d at `curveFinalReserves()`
  (`sqrtP = sqrt(vTokFinal/vEthFinal)·2^96`) so the curve's last fill and the pool's opening spot
  are continuous (D-8 changes: seed price = curve-end, no longer = a fixed mint price).
- **Open risk (T065):** a curve that never sells out strands escrowed ETH and never opens trading.
  v1 has no manual-graduate escape hatch (it would reintroduce a pool-price-vs-curve mismatch).
  Documented, not mitigated.

**(b) Dividends: flat per whole NFT, dynamic, no snapshot.** Replaces coin-age (D-5/D-6).
- Weight `weightᵢ = floor(balanceOf(i) / _unit())` = whole NFTs held. `B = Σ weightᵢ`. **Dust below
  one `_unit()` earns nothing** (a clean "own ≥ 1 NFT to earn" Schelling point).
- **Single accumulator per currency** (not two): on fee `F`, `acc_c += F·ACC/B`; reward
  `= weightᵢ·(acc_c − ckᵢ)/ACC`. No `t0`, no `S`, no time term — coin-age and `tStart` deleted.
- **Eligibility is dynamic and re-entrant:** hold a whole NFT → earn; drop below a unit → that
  weight decrements (stop earning on it); buy back up → resume. No frozen early-minter snapshot,
  no permanent disqualification.
- **Why this shape** (vs. the snapshot/diamond-hand model that was also designed and rejected): the
  snapshot froze a *closed* club (new buyers could never earn → no "hold for yield" story) and a
  permanent 1-wei cliff was hostile. "Hold a whole NFT" opens the club to anyone and softens the
  cliff to the unit boundary. Earliness is rewarded by *cheap curve entry*, not by dividends.
- **Trade-offs accepted:** (i) dropping coin-age reopens single-fee JIT (buy an NFT, skim one fee,
  sell) — judged marginal (per-swap skim is tiny, round-trip pays the pool fee twice); a coin-age
  multiplier can be layered later if it bites. (ii) `skipNFT` contracts holding whole units earn by
  balance even with `ownedLength == 0`; weight uses `floor(bal/_unit())` (skipNFT-independent),
  excluded actors are out regardless.
- **Solvency is now trivial:** one floored accumulator + floored per-holder term ⇒ `Σ ≤ F`, and
  there is no subtracted term so underflow is impossible. The whole D-6/T028 ceil-vs-floor + clamp
  apparatus is removed.

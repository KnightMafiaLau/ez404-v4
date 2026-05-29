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

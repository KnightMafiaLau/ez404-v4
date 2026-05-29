# Tasks: 001-ez404-v4-hooks

Status legend: `[x]` done · `[~]` in progress / drafted but unverified · `[ ]` not started.
"Drafted but unverified" means code exists but has not been compiled or tested locally (no Foundry
on the authoring machine — CI is the source of truth).

## Phase 0 — Spec & plan
- [x] T001 Constitution (`.specify/memory/constitution.md`)
- [x] T002 Feature spec (`spec.md`)
- [x] T003 Implementation plan (`plan.md`)
- [x] T004 Research / decision log (`research.md`)
- [x] T005 Data model & formulas (`data-model.md`)
- [x] T006 Behavioral contracts (`contracts/IEZ404.md`, `contracts/IEZ404Hook.md`)
- [x] T007 Quickstart (`quickstart.md`)

## Phase 1 — Scaffold
- [x] T010 Foundry config (`foundry.toml`, `remappings.txt`)
- [x] T011 `.gitignore`, `README.md`, `LICENSE`
- [x] T012 CI workflow (`.github/workflows/test.yml`: install deps → build → test)
- [ ] T013 `forge install` the four dependencies and commit lockfile / verify remappings (needs Foundry)

## Phase 2 — Token (EZ404)
- [~] T020 DN404 + DN404Mirror wiring, `_unit = 10_000e18`, name/symbol
- [~] T021 Reward-ledger state + `_now`, `B`/`S`/`t0`/`_eligBal`
- [~] T022 `_accrue` (dual-currency, `undist` rollover) + `_settle` + `_syncRewards`
- [~] T023 Override DN404 `_transfer`/`_mint`/`_burn` to settle-before-move (INV-1)
- [~] T024 `publicMint` (capped, priced) + route mint ETH to seed
- [~] T025 `notifyFeeETH`/`notifyFeeToken`/`claim`/`mintForSeed`
- [~] T026 `setHook`/`setExcluded` wiring
- [ ] T027 Compile clean (`forge build`) — **blocked on Foundry**
- [ ] T028 Prove `A ≥ Bterm` no-underflow; genesis-`W` floor; `t0`-on-receive policy

## Phase 3 — Hook (EZ404Hook)
- [~] T030 `getHookPermissions` (flags 0xA44) + ctor (manager, token, controller)
- [~] T031 `_beforeAddLiquidity` (seed-only) + `_beforeRemoveLiquidity` (revert)
- [~] T032 `_afterSwap` dual-currency skim + `take` + route + `+fee` return
- [~] T033 `seedLiquidity` + `unlockCallback` (modifyLiquidity, settle ETH, mint+settle token, refund)
- [~] T034 `setKey`, `receive()`
- [ ] T035 Compile clean — **blocked on Foundry**

## Phase 4 — Tests
- [~] T040 Four-quadrant fee-currency tests (AC-2)
- [~] T041 Seed price + liquidity present (AC-1)
- [~] T042 Outsider-add / remove blocked (AC-3)
- [ ] T043 Conservation over transfer/mint/burn/fee sequence (AC-4)
- [ ] T044 Exclusions earn nothing; locked pool earns nothing (AC-5)
- [ ] T045 JIT/coin-age: age≈0 earns ≈0 (AC-6)
- [ ] T046 All green (`forge test`) — **blocked on Foundry**

## Phase 5 — Deploy
- [~] T050 `Deploy.s.sol`: EZ404 → HookMiner → `new{salt}` → wire → `initialize@P0` → seed
- [ ] T051 Fork dry-run; assert `addr & 0x3FFF == 0xA44` (AC-7)
- [ ] T052 Parameterize chain (PoolManager address per network)

## Phase 6 — Audit pass
- [ ] T060 Genesis low-`W` guard (threshold/vesting) — D-11
- [ ] T061 `seedLiquidity` spot-price guard (fixed `P0` or deviation band) — D-11
- [ ] T062 Decide "% of mint ETH to LP" knob default — D-9
- [ ] T063 Numerics review (FullMath scale `P`, rounding-against-claimant)
- [ ] T064 DN404 mirror-NFT `skipNFT`/exclusion audit for PM/routers/hook

## Immediate next
T013 + T027/T035 — install Foundry, get `forge build` green, then close Phase 4.

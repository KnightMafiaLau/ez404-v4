# Tasks: 001-ez404-v4-hooks

Status legend: `[x]` done · `[~]` in progress / partial · `[ ]` not started.

Foundry is now installed locally (1.7.1) and CI reproduces the working set (pinned commits, verified
in a clean checkout). `forge build` is green and the 8-test suite passes.

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
- [x] T021 Reward-ledger state + `_now`, `B`/`S`/`t0`/`_eligBal`
- [x] T022 `_accrue` (dual-currency, `undist` rollover) + `_settle`
- [x] T023 Override DN404 `_transfer`/`_mint`/`_burn` **and `_transferFromNFT`** to settle-before-move (INV-1)
- [x] T024 `publicMint` (capped, priced) + route mint ETH to seed
- [x] T025 `notifyFeeETH`/`notifyFeeToken`/`claim`/`mintForSeed`
- [x] T026 `setHook`/`setExcluded` wiring
- [x] T027 Compile clean (`forge build`)
- [ ] T028 Prove `A ≥ Bterm` no-underflow; genesis-`W` floor; `t0`-on-receive policy

## Phase 3 — Hook (EZ404Hook)
- [x] T030 `getHookPermissions` (flags 0xA44) + ctor (manager, token, controller, feeBps)
- [x] T031 `_beforeAddLiquidity` (seed-only) + `_beforeRemoveLiquidity` (revert)
- [x] T032 `_afterSwap` dual-currency skim + `take` + route + `+fee` return
- [x] T033 `seedLiquidity` + `unlockCallback` (modifyLiquidity, settle ETH, mint+settle token, refund)
- [x] T034 `setKey`, `receive()`
- [x] T035 Compile clean

## Phase 4 — Tests
- [x] T040 Four-quadrant fee-currency tests (AC-2) — all 4 quadrants pass on a real `PoolManager`
- [x] T041 Seed price + liquidity present (AC-1)
- [x] T042 Outsider-add / remove blocked (AC-3)
- [x] T047 INV-1 regression: coin-age re-syncs on ERC-721 mirror transfer (`_transferFromNFT`);
      verified to fail when the override is neutered
- [ ] T043 Conservation over transfer/mint/burn/fee sequence (AC-4)
- [ ] T044 Exclusions earn nothing; locked pool earns nothing (AC-5)
- [ ] T045 JIT/coin-age: age≈0 earns ≈0 (AC-6)
- [~] T046 `forge test` green — existing 8-test suite passes; AC-4/5/6 tests (T043–T045) still to add

## Phase 5 — Deploy
- [~] T050 `Deploy.s.sol`: EZ404 → HookMiner → `new{salt}` → wire → `initialize@P0` → seed (compiles)
- [ ] T051 Fork dry-run; assert `addr & 0x3FFF == 0xA44` (AC-7)
- [ ] T052 Parameterize chain (PoolManager address per network)

## Phase 6 — Audit pass
- [ ] T060 Genesis low-`W` guard (threshold/vesting) — D-11
- [ ] T061 `seedLiquidity` spot-price guard (fixed `P0` or deviation band) — D-11
- [ ] T062 Decide "% of mint ETH to LP" knob default — D-9
- [ ] T063 Numerics review (FullMath scale `P`, rounding-against-claimant)
- [~] T064 DN404 mirror-NFT audit: `_transferFromNFT` override done; PM/hook excluded+skipNFT;
      still TODO — confirm test routers / any other NFT-holding actors are excluded or skipNFT

## Immediate next
T043–T045 (conservation, exclusion, JIT/coin-age tests) to finish Phase 4 coverage, then T028/T063
numerics and a fork dry-run (T051).

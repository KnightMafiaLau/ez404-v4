# Quickstart

## Prerequisites
```bash
# Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

## Install dependencies
Dependencies are not vendored. **Pin these exact commits** — `v4-periphery` `main` deleted
`BaseHook` (PR #510), and DN404 now lives in its own repo (removed from Solady). From the repo root:
```bash
forge install foundry-rs/forge-std@620536fa5277db4e3fd46772d5cbc1ea0696fb43
forge install Uniswap/v4-core@59d3ecf53afa9264a16bba0e38f4c5d2231f80bc
forge install Uniswap/v4-periphery@3779387e5d296f39df543d23524b050f89a62917
forge install Vectorized/solady@acd959aa4bd04720d640bf4e6a5c71037510cc4b
forge install Vectorized/dn404@3397cb11558ac853912ee87871422b6a29c9d346
```
`v4-core`/`v4-periphery` bring `solmate`/`openzeppelin`/`permit2` as nested submodules; `remappings.txt`
points at those nested `lib/<dep>/lib/...` paths. Tested with Foundry `stable` (forge 1.7.1).

## Build & test
```bash
forge build
forge test -vvv
```
Key tests (`test/EZ404Hook.t.sol`):
- `test_Q1_buy_exactIn_feeIn404` / `test_Q2_sell_exactIn_feeInETH` /
  `test_Q3_buy_exactOut_feeInETH` / `test_Q4_sell_exactOut_feeIn404` — four-quadrant fee currency.
- `test_seed_priceAndLiquidity` — pool initialized at `P0`, full-range liquidity present.
- `test_outsiderAddBlocked` / `test_removeBlocked` — permanent lock.
- `test_NFTtransfer_syncsCoinAge` — INV-1 regression: coin-age re-syncs on an ERC-721 mirror
  transfer (the `_transferFromNFT` path that bypasses `_transfer`).

## Deploy (local fork example)
```bash
forge script script/Deploy.s.sol \
  --rpc-url $RPC_URL --broadcast --private-key $PK
```
The script: deploys EZ404 → mines the hook address (flags `0xA44`) → deploys the hook via the
CREATE2 deployer → wires `setHook`/`setKey`/exclusions → `initialize(key, sqrtP0)` →
`seedLiquidity{value}`.

## Status
`forge build` is green and all 8 tests pass locally (Foundry 1.7.1). The four-quadrant fee
convention, permanent lock, seed, and the INV-1 NFT-transfer coin-age sync are verified against a
real V4 `PoolManager`. Remaining work (numeric guards, deploy dry-run on a fork) is in `tasks.md`.
Do not deploy to mainnet until Phase 6 (audit pass) is complete.

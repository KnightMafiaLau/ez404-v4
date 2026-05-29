# Quickstart

## Prerequisites
```bash
# Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

## Install dependencies
Dependencies are not vendored. From the repo root:
```bash
forge install foundry-rs/forge-std
forge install Uniswap/v4-core
forge install Uniswap/v4-periphery
forge install Vectorized/solady
```
`remappings.txt` already points at the resulting `lib/` paths.

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

## Deploy (local fork example)
```bash
forge script script/Deploy.s.sol \
  --rpc-url $RPC_URL --broadcast --private-key $PK
```
The script: deploys EZ404 → mines the hook address (flags `0xA44`) → deploys the hook via the
CREATE2 deployer → wires `setHook`/`setKey`/exclusions → `initialize(key, sqrtP0)` →
`seedLiquidity{value}`.

## Status
Implementation is WIP. See `tasks.md` for what is done and what remains, and CI for the live build
status. Do not deploy to mainnet until Phase 6 (audit pass) is complete.

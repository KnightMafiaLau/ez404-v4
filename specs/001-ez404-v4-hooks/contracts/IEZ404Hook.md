# Behavioral Contract: EZ404Hook

V4 `BaseHook`. Native ETH = `currency0` (`address(0)`), EZ404 = `currency1`.

## Permissions
```
beforeAddLiquidity = true
beforeRemoveLiquidity = true
afterSwap = true
afterSwapReturnDelta = true
```
Flag bits `(1<<11)|(1<<9)|(1<<6)|(1<<2) = 0xA44`. Deployed address MUST satisfy
`addr & 0x3FFF == 0xA44`.

## beforeAddLiquidity(sender, …)
- `require(sender == address(this))` — only the hook's own seed path may add liquidity.
- else revert `"LP locked: seed only"`.

## beforeRemoveLiquidity(…)
- revert `"LP permanently locked"` unconditionally. No exceptions, including controller.

## afterSwap(_, key, params, delta, _) → (selector, int128)
Skim `feeBps` of the **unspecified** leg and route it to the token's ledger.

```
exactInput = params.amountSpecified < 0
unspecIs0  = (exactInput != params.zeroForOne)   // true ⇒ unspecified currency is ETH
d   = unspecIs0 ? delta.amount0() : delta.amount1()
fee = (abs(d) * feeBps) / 10_000
if fee == 0: return (selector, 0)
c = unspecIs0 ? currency0 : currency1
poolManager.take(c, address(this), fee)          // hook delta on c becomes −fee
if c == ETH: token.notifyFeeETH{value: fee}()
else:        safeTransfer(c, token, fee); token.notifyFeeToken(fee)
return (selector, +int128(fee))                  // V4 credits +fee to hook (nets 0) and charges swapper
```

### Four-quadrant truth table (the #1 correctness risk — proven in tests)
| zeroForOne | mode | specified | **unspecified** | `unspecIs0` | unspec δ (to swapper) | take | fee currency |
|---|---|---|---|---|---|---|---|
| true (buy 404) | exactIn | cur0 ETH(in) | **cur1 404(out)** | false | **+** (output) | 404 | 404 |
| false (sell 404) | exactIn | cur1 404(in) | **cur0 ETH(out)** | true | **+** (output) | ETH | ETH |
| true (buy 404) | exactOut | cur1 404(out) | **cur0 ETH(in)** | true | **−** (input) | ETH | ETH |
| false (sell 404) | exactOut | cur0 ETH(out) | **cur1 404(in)** | false | **−** (input) | 404 | 404 |

Conclusions:
- `unspecIs0 = (exactInput != zeroForOne)` is correct in all four rows.
- `abs(d)` absorbs the output(+)/input(−) sign flip; `return +fee` makes the hook net zero and the
  swapper bear it in every quadrant.
- **Fee currency is decided by `unspecIs0`, not by buy/sell.** Exact-out buys pay in ETH; exact-in
  buys pay in 404. You cannot collect ETH-only without a harvest swap → dual-currency is forced.
- Fee base differs (output for exact-in, input for exact-out) by ~the LP fee → "pick the smaller
  leg" gaming is minor and accepted.

## seedLiquidity() payable — controller only
```
require(msg.sender == controller)
poolManager.unlock(abi.encode(msg.value))
```
### unlockCallback(data) — poolManager only
```
ethAmount = decode(data)
(sqrtP,,,) = poolManager.getSlot0(key.toId())          // == P0 right after initialize
lo = minUsableTick(tickSpacing); hi = maxUsableTick(tickSpacing)
L  = LiquidityAmounts.getLiquidityForAmount0(sqrtP, getSqrtPriceAtTick(hi), ethAmount)
(cd,) = poolManager.modifyLiquidity(key, {lo, hi, +L, 0}, "")
owed0 = uint128(-cd.amount0()); owed1 = uint128(-cd.amount1())
poolManager.settle{value: owed0}()                      // ETH side
poolManager.sync(currency1); token.mintForSeed(poolManager, owed1); poolManager.settle()  // token side
if ethAmount > owed0: refund (ethAmount − owed0) to controller
```
- `beforeAddLiquidity` sees `sender == address(this)` (hook calls `modifyLiquidity`) → passes lock.
- All deltas net to zero or the unlock reverts (`CurrencyNotSettled`).
- `receive() external payable {}` to hold ETH taken from `take` transiently.

## setKey(PoolKey) — controller only, one-time.

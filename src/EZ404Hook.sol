// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

interface IEZ404Fee {
    function notifyFeeETH() external payable;
    function notifyFeeToken(uint256 amt) external;
    function mintForSeed(address to, uint256 amount) external;
}

/// @title EZ404Hook
/// @notice Locks liquidity permanently and skims a dual-currency swap fee into EZ404's dividend
///         ledger. WIP — drafted against specs/001-ez404-v4-hooks, not yet compiled or tested.
contract EZ404Hook is BaseHook {
    using StateLibrary for IPoolManager;

    IEZ404Fee public immutable token;
    address public immutable controller;
    uint16 public immutable feeBps;                       // dividend skim, e.g. 100 = 1%

    PoolKey public key;
    int24 public tickSpacing;
    bool public keySet;

    error OnlyController();
    error OnlySeeder();
    error OnlyPM();
    error KeyAlreadySet();

    constructor(IPoolManager _pm, IEZ404Fee _token, address _controller, uint16 _feeBps)
        BaseHook(_pm)
    {
        token = _token;
        controller = _controller;
        feeBps = _feeBps;
    }

    // ─────────────────────────────────────────── permissions (flags 0xA44)
    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeAddLiquidity = true;
        p.beforeRemoveLiquidity = true;
        p.afterSwap = true;
        p.afterSwapReturnDelta = true;
    }

    // ─────────────────────────────────────────── liquidity lock
    function _beforeAddLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        // only the hook's own seed path (unlockCallback) may add liquidity
        require(sender == address(this), "LP locked: seed only");
        return BaseHook.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert("LP permanently locked");
    }

    // ─────────────────────────────────────────── fee skim (dual-currency)
    function _afterSwap(
        address,
        PoolKey calldata k,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        bool exactInput = params.amountSpecified < 0;
        bool unspecIs0 = (exactInput != params.zeroForOne);   // true ⇒ unspecified currency is cur0 (ETH)
        int128 d = unspecIs0 ? delta.amount0() : delta.amount1();
        uint256 mag = d < 0 ? uint256(uint128(-d)) : uint256(uint128(d));
        uint256 fee = mag * feeBps / 10_000;
        if (fee == 0) return (BaseHook.afterSwap.selector, int128(0));

        Currency c = unspecIs0 ? k.currency0 : k.currency1;
        poolManager.take(c, address(this), fee);              // hook delta on c → −fee

        if (Currency.unwrap(c) == address(0)) {
            token.notifyFeeETH{value: fee}();
        } else {
            SafeTransferLib.safeTransfer(Currency.unwrap(c), address(token), fee);
            token.notifyFeeToken(fee);
        }
        // +fee on the unspecified currency: V4 credits the hook (nets the take to 0) and charges the swapper
        return (BaseHook.afterSwap.selector, int128(int256(fee)));
    }

    // ─────────────────────────────────────────── one-time wiring
    function setKey(PoolKey calldata k) external {
        if (msg.sender != controller) revert OnlyController();
        if (keySet) revert KeyAlreadySet();
        key = k;
        tickSpacing = k.tickSpacing;
        keySet = true;
    }

    // ─────────────────────────────────────────── seed (controller or token/publicMint)
    function seedLiquidity() external payable {
        if (msg.sender != controller && msg.sender != address(token)) revert OnlySeeder();
        poolManager.unlock(abi.encode(msg.value));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPM();
        uint256 ethAmount = abi.decode(data, (uint256));

        (uint160 sqrtP,,,) = poolManager.getSlot0(key.toId());
        int24 lo = TickMath.minUsableTick(tickSpacing);
        int24 hi = TickMath.maxUsableTick(tickSpacing);
        // WIP/T061: getSlot0 spot price is sandwichable on incremental seeds — guard vs P0/TWAP.
        uint128 L =
            LiquidityAmounts.getLiquidityForAmount0(sqrtP, TickMath.getSqrtPriceAtTick(hi), ethAmount);

        (BalanceDelta cd,) = poolManager.modifyLiquidity(
            key, ModifyLiquidityParams(lo, hi, int256(uint256(L)), bytes32(0)), ""
        );
        uint256 owed0 = uint256(uint128(-cd.amount0()));      // ETH owed to pool
        uint256 owed1 = uint256(uint128(-cd.amount1()));      // EZ404 owed to pool

        poolManager.settle{value: owed0}();                   // ETH side
        poolManager.sync(key.currency1);
        token.mintForSeed(address(poolManager), owed1);       // mint pool side directly to PM
        poolManager.settle();                                 // EZ404 side

        if (ethAmount > owed0) {
            SafeTransferLib.safeTransferETH(controller, ethAmount - owed0);   // refund dust
        }
        return "";
    }

    receive() external payable {}                             // holds ETH from take() transiently
}

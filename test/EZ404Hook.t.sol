// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Verifies the four-quadrant fee-currency convention (#1 correctness risk), permanent lock,
// and seed settlement. WIP — drafted against specs/001-ez404-v4-hooks; not yet run (no Foundry
// on the authoring machine). CI is the source of truth.

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

import {DN404Mirror} from "dn404/DN404Mirror.sol";

import {EZ404} from "../src/EZ404.sol";
import {EZ404Hook, IEZ404Fee} from "../src/EZ404Hook.sol";

contract EZ404HookTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    EZ404 token;
    EZ404Hook hook;
    PoolKey poolKey;
    PoolId id;
    uint160 sqrtP0;

    uint24 constant LP_FEE = 3000;
    int24 constant TS = 60;
    uint16 constant HOOK_FEE_BPS = 100; // 1%
    address controller = address(this);

    function setUp() public {
        deployFreshManagerAndRouters(); // sets `manager`, `swapRouter`, `modifyLiquidityRouter`

        token = new EZ404();

        uint160 flags = uint160(
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        ); // 0xA44
        bytes memory args =
            abi.encode(IPoolManager(address(manager)), IEZ404Fee(address(token)), controller, HOOK_FEE_BPS);
        (address hookAddr, bytes32 salt) =
            HookMiner.find(address(this), flags, type(EZ404Hook).creationCode, args);
        hook = new EZ404Hook{salt: salt}(
            IPoolManager(address(manager)), IEZ404Fee(address(token)), controller, HOOK_FEE_BPS
        );
        require(address(hook) == hookAddr, "addr mismatch");

        token.setHook(address(hook));
        token.setExcluded(address(manager), true);

        poolKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), LP_FEE, TS, IHooks(address(hook)));
        id = poolKey.toId();
        hook.setKey(poolKey);

        // seed price = mint price: P0 = unit / pbMintPrice
        sqrtP0 = uint160(FixedPointMathLib.sqrt(FullMath.mulDiv(token.unit(), 1 << 192, token.pbMintPrice())));
        manager.initialize(poolKey, sqrtP0);

        vm.deal(controller, 100 ether);
        hook.seedLiquidity{value: 10 ether}();

        // stock the test contract with EZ404 for "sell" quadrants (bypass publicMint's seed path).
        // NOTE: hoist unit() out — if inlined as an arg it'd be the call that consumes vm.prank,
        // leaving mintForSeed un-pranked → OnlyHook().
        uint256 sellStock = 1_000 * token.unit();
        vm.prank(address(hook));
        token.mintForSeed(address(this), sellStock);
        token.approve(address(swapRouter), type(uint256).max);
    }

    // ── core: four-quadrant fee-currency assertion ──
    function _swapAssertFeeCurrency(bool zeroForOne, bool exactIn, int256 amt, uint256 ethVal) internal {
        bool unspecIs0 = (exactIn != zeroForOne); // true ⇒ fee in cur0 = ETH
        uint256 ethBefore = address(token).balance;
        uint256 tokBefore = token.balanceOf(address(token));

        swapRouter.swap{value: ethVal}(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amt,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 ethGain = address(token).balance - ethBefore;
        uint256 tokGain = token.balanceOf(address(token)) - tokBefore;
        if (unspecIs0) {
            assertGt(ethGain, 0, "expect ETH fee");
            assertEq(tokGain, 0, "no token fee");
        } else {
            assertGt(tokGain, 0, "expect token fee");
            assertEq(ethGain, 0, "no ETH fee");
        }
    }

    function test_Q1_buy_exactIn_feeIn404() public {
        _swapAssertFeeCurrency(true, true, -0.01 ether, 0.01 ether);
    }

    function test_Q2_sell_exactIn_feeInETH() public {
        _swapAssertFeeCurrency(false, true, -int256(token.unit()), 0);
    }

    function test_Q3_buy_exactOut_feeInETH() public {
        _swapAssertFeeCurrency(true, false, int256(token.unit()), 0.05 ether); // overfund; router refunds
    }

    function test_Q4_sell_exactOut_feeIn404() public {
        _swapAssertFeeCurrency(false, false, 0.001 ether, 0);
    }

    // ── seed / lock ──
    function test_seed_priceAndLiquidity() public view {
        (uint160 sp,,,) = manager.getSlot0(id);
        assertApproxEqRel(sp, sqrtP0, 1e15); // ≈ P0
        assertGt(manager.getLiquidity(id), 0);
        assertGt(token.balanceOf(address(manager)), 0); // pool side minted to PM
    }

    function test_outsiderAddBlocked() public {
        vm.expectRevert(); // beforeAddLiquidity: sender != hook
        modifyLiquidityRouter.modifyLiquidity(
            poolKey, ModifyLiquidityParams(TickMath.minUsableTick(TS), TickMath.maxUsableTick(TS), 1e18, 0), ""
        );
    }

    function test_removeBlocked() public {
        vm.expectRevert(); // beforeRemoveLiquidity: always
        modifyLiquidityRouter.modifyLiquidity(
            poolKey, ModifyLiquidityParams(TickMath.minUsableTick(TS), TickMath.maxUsableTick(TS), -1, 0), ""
        );
    }

    // ── INV-1 regression: coin-age must re-sync on an ERC-721 mirror transfer ──
    // This is the #1 correctness gap. A mirror `transferFrom` moves _unit() of ERC-20 via
    // _transferFromNFT, which bypasses _transfer. Without the _transferFromNFT override in EZ404,
    // bob's coin-age origin (t0) would never be set despite holding a unit → this test fails.
    function test_NFTtransfer_syncsCoinAge() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        uint256 u = token.unit();

        // alice is a fresh EOA (skipNFT=false) so the mint materializes NFTs (ids 1..3)
        vm.prank(address(hook));
        token.mintForSeed(alice, 3 * u);

        // advance so the coin-age origin is distinguishable from genesis (_now() == 0)
        vm.warp(block.timestamp + 7 days);
        uint256 ageNow = block.timestamp - token.tStart();

        assertEq(token.t0(bob), 0, "bob has no coin-age origin pre-transfer");
        uint256 bBefore = token.B();

        // move ONE NFT alice -> bob via the mirror. Hoist mirrorERC721() out so it doesn't
        // consume the prank (the footgun this very test file already tripped on once).
        address mirror = token.mirrorERC721();
        vm.prank(alice);
        DN404Mirror(payable(mirror)).transferFrom(alice, bob, 1);

        // ERC-20 balance followed the NFT
        assertEq(token.balanceOf(bob), u, "bob got 1 unit");
        assertEq(token.balanceOf(alice), 2 * u, "alice left with 2 units");

        // THE REGRESSION CHECKS — only pass if _transferFromNFT re-synced coin-age:
        assertEq(token.t0(bob), ageNow, "bob age reset on receive");
        assertEq(token.t0(alice), 0, "alice keeps her (genesis) age");
        assertEq(token.B(), bBefore, "total eligible balance conserved");
    }

    // NOTE: Deployers already provides a non-virtual `receive()`, so we inherit it.
}

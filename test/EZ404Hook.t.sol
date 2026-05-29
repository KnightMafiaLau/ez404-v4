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

    // ───────────────────────── reward-ledger AC tests (AC-4/5/6) ─────────────────────────
    // Inject a fee through the onlyHook intake — the same _accrue path the real _afterSwap uses.
    function _distributeEthFee(uint256 f) internal {
        vm.deal(address(hook), address(hook).balance + f);
        vm.prank(address(hook));
        token.notifyFeeETH{value: f}();
    }

    // Mint `u` whole units to a holder. skipNFT keeps it ERC-20-only (cheap; the coin-age ledger
    // tracks ERC-20 balance, not NFTs). Hoist unit() before the prank (the prank footgun).
    function _mintEligible(address who, uint256 u, bool skipNft) internal {
        if (skipNft) {
            vm.prank(who);
            token.setSkipNFT(true);
        }
        uint256 amt = u * token.unit();
        vm.prank(address(hook));
        token.mintForSeed(who, amt);
    }

    function _claimEth(address who) internal returns (uint256) {
        uint256 bal = who.balance;
        vm.prank(who);
        token.claim();
        return who.balance - bal;
    }

    // AC-5: the locked pool and every excluded actor accrue nothing — fees are NOT diluted by the
    // pool's balance (the classic reflection+LP trap this design exists to avoid).
    function test_AC5_excludedAndPoolEarnNothing() public {
        assertGt(token.balanceOf(address(manager)), 1_000 * token.unit(), "PM holds the pool side");

        token.setExcluded(address(this), true); // make alice the SOLE eligible holder
        address alice = makeAddr("alice");
        _mintEligible(alice, 100, true);
        vm.warp(block.timestamp + 30 days);

        uint256 F = 1 ether;
        _distributeEthFee(F);

        uint256 got = _claimEth(alice);
        assertApproxEqAbs(got, F, 1e9, "alice collects ~all of F (pool did not dilute)");

        assertEq(token.claimable0(address(manager)), 0, "locked pool earns 0");
        assertEq(token.claimable0(address(hook)), 0, "hook earns 0");
        assertEq(token.claimable0(address(token)), 0, "token contract earns 0");
    }

    // AC-4: conservation + coin-age weighting. One fee F across two equal-balance holders of
    // different age; the older earns more, and the parts sum back to F (rounding against them).
    function test_AC4_conservationAndAgeWeighting() public {
        token.setExcluded(address(this), true);
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        _mintEligible(alice, 100, true); // alice age origin = 0
        vm.warp(block.timestamp + 10 days);
        _mintEligible(bob, 100, true); // bob age origin = 10d
        vm.warp(block.timestamp + 20 days); // now: alice 30d, bob 20d

        uint256 F = 1 ether;
        _distributeEthFee(F);

        uint256 a = _claimEth(alice);
        uint256 b = _claimEth(bob);

        assertGt(a, b, "older holder earns more at equal balance");
        assertApproxEqAbs(a + b, F, 1e10, "rewards conserve to F");
        assertApproxEqRel(a, 0.6 ether, 1e15, "alice ~= 30/50 of F");
        assertApproxEqRel(b, 0.4 ether, 1e15, "bob ~= 20/50 of F");
    }

    // AC-6: coin-age defeats JIT. A whale that acquires a huge balance the instant before a fee has
    // age ~0, so it earns ~0; the aged incumbent keeps ~all of F despite far less balance.
    function test_AC6_jitEarnsNothing() public {
        token.setExcluded(address(this), true);
        address alice = makeAddr("alice");
        address jit = makeAddr("jit");

        _mintEligible(alice, 100, true);
        vm.warp(block.timestamp + 30 days); // alice ages
        _mintEligible(jit, 10_000, true); // 100x alice's balance, age 0

        uint256 F = 1 ether;
        _distributeEthFee(F); // same timestamp as jit's mint

        uint256 aliceGot = _claimEth(alice);
        uint256 jitGot = _claimEth(jit);

        assertLt(jitGot, 1e9, "age-0 whale earns ~nothing"); // teeth: balance-reflection ~0.99F
        assertApproxEqAbs(aliceGot, F, 1e9, "incumbent keeps ~all of F");
    }

    // NOTE: Deployers already provides a non-virtual `receive()`, so we inherit it.
}

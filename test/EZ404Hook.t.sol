// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Covers: four-quadrant fee-currency convention (#1 correctness risk), permanent lock, seed
// settlement, INV-1 mirror-NFT weight sync, the flat-per-whole-NFT dividend ACs, and the
// pump.fun curve + graduation (D-13). CI is the source of truth.

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
    uint160 sqrtPInit;

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

        // seed price = curve FINAL price, so the curve→pool handoff is continuous (D-13).
        (uint256 vTokFinal, uint256 vEthFinal) = token.curveFinalReserves();
        sqrtPInit = uint160(FixedPointMathLib.sqrt(FullMath.mulDiv(vTokFinal, 1 << 192, vEthFinal)));
        manager.initialize(poolKey, sqrtPInit);

        vm.deal(controller, 100 ether);
        // NB: setUp does NOT seed or mint — tests that need a live pool call _seedAndStock(); the
        // curve/graduation tests drive publicMint so they exercise the real seed path.
    }

    // Controller-seeds the locked pool and stocks the test contract with EZ404 for "sell" swaps
    // (bypasses the curve, which the four-quadrant tests don't need to exercise).
    function _seedAndStock() internal {
        hook.seedLiquidity{value: 10 ether}();
        uint256 sellStock = 1_000 * token.unit(); // hoist unit() out of the pranked call (footgun)
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
        _seedAndStock();
        _swapAssertFeeCurrency(true, true, -0.01 ether, 0.01 ether);
    }

    function test_Q2_sell_exactIn_feeInETH() public {
        _seedAndStock();
        _swapAssertFeeCurrency(false, true, -int256(token.unit()), 0);
    }

    function test_Q3_buy_exactOut_feeInETH() public {
        _seedAndStock();
        _swapAssertFeeCurrency(true, false, int256(token.unit()), 0.05 ether); // overfund; router refunds
    }

    function test_Q4_sell_exactOut_feeIn404() public {
        _seedAndStock();
        _swapAssertFeeCurrency(false, false, 0.001 ether, 0);
    }

    // ── seed / lock ──
    function test_seed_priceAndLiquidity() public {
        _seedAndStock();
        (uint160 sp,,,) = manager.getSlot0(id);
        assertApproxEqRel(sp, sqrtPInit, 1e15); // ≈ curve final price
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

    // ── INV-1 regression: whole-NFT weight must re-sync on an ERC-721 mirror transfer ──
    // A mirror `transferFrom` moves _unit() of ERC-20 via _transferFromNFT, which bypasses
    // _transfer. Without the _transferFromNFT override in EZ404, bob's weight would never update
    // despite holding a unit → this test fails.
    function test_NFTtransfer_syncsWeight() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        uint256 u = token.unit();

        // alice is a fresh EOA (skipNFT=false) so the mint materializes NFTs (ids 1..3)
        vm.prank(address(hook));
        token.mintForSeed(alice, 3 * u);

        assertEq(token.weightOf(alice), 3, "alice has 3 whole-NFT weight");
        assertEq(token.weightOf(bob), 0, "bob has none pre-transfer");
        uint256 bBefore = token.B();

        // move ONE NFT alice -> bob via the mirror. Hoist mirrorERC721() out so it doesn't
        // consume the prank (the footgun this very test file already tripped on once).
        address mirror = token.mirrorERC721();
        vm.prank(alice);
        DN404Mirror(payable(mirror)).transferFrom(alice, bob, 1);

        // ERC-20 balance followed the NFT
        assertEq(token.balanceOf(bob), u, "bob got 1 unit");
        assertEq(token.balanceOf(alice), 2 * u, "alice left with 2 units");

        // THE REGRESSION CHECKS — only pass if _transferFromNFT re-synced weight:
        assertEq(token.weightOf(bob), 1, "bob weight = 1 NFT");
        assertEq(token.weightOf(alice), 2, "alice weight = 2 NFTs");
        assertEq(token.B(), bBefore, "total eligible weight conserved");
    }

    // ───────────────────────── reward-ledger AC tests (AC-4/5/6) ─────────────────────────
    // Inject a fee through the onlyHook intake — the same _accrue path the real _afterSwap uses.
    function _distributeEthFee(uint256 f) internal {
        vm.deal(address(hook), address(hook).balance + f);
        vm.prank(address(hook));
        token.notifyFeeETH{value: f}();
    }

    // Mint `u` whole units to a holder. skipNFT keeps it ERC-20-only (cheap; weight is derived from
    // balance, not NFT possession). Hoist unit() before the prank (the prank footgun).
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
        _seedAndStock();
        assertGt(token.balanceOf(address(manager)), 0, "PM holds the pool side");

        token.setExcluded(address(this), true); // make alice the SOLE eligible holder
        address alice = makeAddr("alice");
        _mintEligible(alice, 100, true);

        uint256 F = 1 ether;
        _distributeEthFee(F);

        uint256 got = _claimEth(alice);
        assertApproxEqAbs(got, F, 1e9, "alice collects ~all of F (pool did not dilute)");

        assertEq(token.claimable0(address(manager)), 0, "locked pool earns 0");
        assertEq(token.claimable0(address(hook)), 0, "hook earns 0");
        assertEq(token.claimable0(address(token)), 0, "token contract earns 0");
    }

    // AC-4: conservation + flat-per-NFT weighting. One fee F across two holders with different
    // whole-NFT counts; earnings are proportional to NFT count and sum back to F.
    function test_AC4_conservationFlat() public {
        token.setExcluded(address(this), true);
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        _mintEligible(alice, 100, true); // 100 NFTs
        _mintEligible(bob, 50, true); // 50 NFTs

        uint256 F = 1 ether;
        _distributeEthFee(F);

        uint256 a = _claimEth(alice);
        uint256 b = _claimEth(bob);

        assertGt(a, b, "more NFTs => more reward");
        assertApproxEqAbs(a + b, F, 1e10, "rewards conserve to F");
        assertApproxEqRel(a, (F * 2) / 3, 1e15, "alice ~= 100/150 of F");
        assertApproxEqRel(b, F / 3, 1e15, "bob ~= 50/150 of F");
    }

    // AC-6: only WHOLE NFTs earn — dust below one _unit() is ignored. Two holders with weight 1
    // split a fee equally even though one holds 50% more tokens (the extra 0.5 unit is dust).
    function test_AC6_dustEarnsNothing() public {
        token.setExcluded(address(this), true);
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        uint256 u = token.unit();

        // alice: 1.5 units → weight 1 (the 0.5 dust must not earn)
        vm.prank(alice);
        token.setSkipNFT(true);
        vm.prank(address(hook));
        token.mintForSeed(alice, (u * 3) / 2);
        // bob: 1 unit → weight 1
        vm.prank(bob);
        token.setSkipNFT(true);
        vm.prank(address(hook));
        token.mintForSeed(bob, u);

        assertEq(token.weightOf(alice), 1, "alice weight 1 (dust ignored)");
        assertEq(token.weightOf(bob), 1, "bob weight 1");

        uint256 F = 1 ether;
        _distributeEthFee(F);

        uint256 a = _claimEth(alice);
        uint256 b = _claimEth(bob);
        assertApproxEqAbs(a, b, 1e9, "equal whole-NFT weight => equal reward despite alice's dust");
        assertApproxEqAbs(a + b, F, 1e10, "conserve to F");
    }

    // ───────────────────────── pump.fun curve + graduation (D-13) ─────────────────────────

    // First NFT ≈ start price; a 100-NFT chunk costs strictly more than 100× the first (convex).
    function test_curve_quoteAndConvexity() public view {
        uint256 first = token.quoteBuy(1);
        uint256 chunk = token.quoteBuy(100);
        // DEMO: 1% tolerance — the 100-NFT curve is coarser-grained than prod's 5000, so the first
        // NFT (a 1/100 chunk) sits ~0.7% above the marginal start price (prod uses 0.1%).
        assertApproxEqRel(first, 0.001 ether, 1e16, "first NFT ~= 0.001 ETH");
        assertGt(chunk, first * 100, "convex curve: a chunk costs more than N x the first NFT");
    }

    // Buying advances the curve → the next quote is strictly higher.
    function test_curve_priceRises() public {
        address b = makeAddr("buyer");
        vm.deal(b, 5 ether);
        vm.prank(b);
        token.setSkipNFT(true);

        uint256 p0 = token.quoteBuy(1);
        vm.prank(b);
        token.publicMint{value: 1 ether}(10); // DEMO: 10 < MAX_SUPPLY(100) so it doesn't sell out
        uint256 p1 = token.quoteBuy(1);

        assertGt(p1, p0, "marginal price rises as the curve fills");
        assertEq(token.mintedUnits(), 10);
        assertFalse(token.graduated(), "not sold out yet");
    }

    // Selling out the curve graduates: pool gets seeded with escrowed ETH and dividends turn on.
    function test_curve_graduation() public {
        address buyer = makeAddr("buyer");
        vm.deal(buyer, 30 ether);
        vm.prank(buyer);
        token.setSkipNFT(true); // avoid materializing 5000 NFTs; weight is balance-derived

        uint256 maxS = token.MAX_SUPPLY(); // hoist (footgun)
        assertFalse(token.graduated());

        vm.prank(buyer);
        token.publicMint{value: 30 ether}(maxS);

        assertTrue(token.graduated(), "sold out -> graduated");
        assertEq(token.mintedUnits(), maxS);
        assertGt(manager.getLiquidity(id), 0, "pool seeded at graduation");
        assertGt(token.balanceOf(address(manager)), 0, "pool holds the token side");
        assertEq(token.balanceOf(buyer), maxS * token.unit(), "buyer holds all curve NFTs");
        assertEq(token.weightOf(buyer), maxS, "buyer eligible for full weight");

        // dividends now live: buyer is the sole eligible holder (PM excluded)
        uint256 F = 1 ether;
        _distributeEthFee(F);
        uint256 got = _claimEth(buyer);
        assertApproxEqAbs(got, F, 1e9, "sole NFT holder collects ~all of F");
    }

    // After graduation the curve is closed.
    function test_curve_noMintAfterGraduation() public {
        address buyer = makeAddr("buyer");
        vm.deal(buyer, 30 ether);
        vm.prank(buyer);
        token.setSkipNFT(true);
        uint256 maxS = token.MAX_SUPPLY();
        vm.prank(buyer);
        token.publicMint{value: 30 ether}(maxS);

        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        vm.expectRevert(EZ404.AlreadyGraduated.selector);
        token.publicMint{value: 1 ether}(1);
    }

    // NOTE: Deployers already provides a non-virtual `receive()`, so we inherit it.
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DN404} from "dn404/DN404.sol";
import {DN404Mirror} from "dn404/DN404Mirror.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {LibString} from "solady/utils/LibString.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

/// @title EZ404
/// @notice DN404 hybrid (ERC-20 + ERC-721 mirror) with a pump.fun-style constant-product mint
///         curve that graduates (on sell-out) into a permanently-locked V4 pool, plus a
///         dual-currency, flat-per-whole-NFT swap-fee dividend ledger.
/// @dev    Curve: buyers mint whole NFTs along x·y=k virtual reserves; ETH is escrowed until
///         sell-out, then seeds the locked pool at the curve's final price. Dividends: each
///         whole NFT held earns an equal share of every swap fee (no coin-age, no snapshot;
///         dust below one `_unit()` earns nothing). See specs/001-ez404-v4-hooks D-13 and
///         data-model.md for the math.
contract EZ404 is DN404 {
    // ─────────────────────────────────────────── constants
    uint256 public constant MAX_SUPPLY = 5000; // NFT-units sold on the curve
    uint256 internal constant ACC = 1 << 96; // accumulator fixed-point scale

    // pump.fun-style constant-product virtual reserves (k = V_TOK0 · V_ETH0).
    // Token axis scaled to a 5000-NFT (50M-token) curve while preserving pump.fun's reserve ratio
    // (vTok0 : sold : remaining = 1.353 : 1 : 0.353 ⇒ ~14.7× price run start→finish).
    // First NFT ≈ 0.001 ETH; full sell-out raises ≈ 19.2 ETH; final ≈ 0.0147 ETH / NFT.
    uint256 public constant V_TOK0 = 67_650_000e18; // virtual token reserve (67.65M)
    uint256 public constant V_ETH0 = 6.765 ether; // virtual ETH reserve

    string private _name = "EZ404";
    string private _symbol = "EZ";

    // ─────────────────────────────────────────── roles / wiring
    address public immutable controller;
    address public hook; // set once via setHook
    mapping(address => bool) public excluded; // never accrues, never in B

    // ─────────────────────────────────────────── curve state
    uint256 public mintedUnits; // NFT-units sold on the curve
    uint256 public ethRaised; // ETH escrowed by the curve (seeds the pool at graduation)
    bool public graduated; // curve closed, pool seeded, dividends live

    // ─────────────────────────────────────────── dividend ledger (flat per whole NFT)
    uint256 public B; // total eligible whole-NFT count
    mapping(address => uint256) internal _weight; // eligible whole-NFT count per holder

    // paired accumulators: index 0 = ETH, index 1 = EZ404
    uint256 public acc0;
    uint256 public acc1;
    uint256 public undist0; // rollover when B == 0
    uint256 public undist1;

    mapping(address => uint256) internal _ck0;
    mapping(address => uint256) internal _ck1;
    mapping(address => uint256) public claimable0; // ETH owed
    mapping(address => uint256) public claimable1; // EZ404 owed

    // ─────────────────────────────────────────── events / errors
    event FeeAccrued(bool indexed isEth, uint256 amount);
    event Claimed(address indexed user, uint256 eth, uint256 token);
    event Bought(address indexed buyer, uint256 qty, uint256 cost);
    event Graduated(uint256 ethSeeded, uint256 units);
    error OnlyController();
    error OnlyHook();
    error HookAlreadySet();
    error SoldOut();
    error WrongValue();
    error AlreadyGraduated();

    modifier onlyController() {
        if (msg.sender != controller) revert OnlyController();
        _;
    }

    modifier onlyHook() {
        if (msg.sender != hook) revert OnlyHook();
        _;
    }

    constructor() {
        controller = msg.sender;
        address mirror = address(new DN404Mirror(msg.sender));
        _initializeDN404(0, msg.sender, mirror); // zero initial supply; mint via publicMint
        excluded[address(this)] = true; // the token contract itself never accrues
    }

    // ─────────────────────────────────────────── DN404 required overrides
    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function _unit() internal pure override returns (uint256) {
        return 10_000e18;
    }

    /// @notice Public view of `_unit()` for off-chain / deploy / test use.
    function unit() external pure returns (uint256) {
        return _unit();
    }

    function _tokenURI(uint256 id) internal pure override returns (string memory) {
        return string.concat("ez404://", LibString.toString(id));
    }

    // ─────────────────────────────────────────── wiring (controller, one-time each)
    function setHook(address h) external onlyController {
        if (hook != address(0)) revert HookAlreadySet();
        hook = h;
        _setExcluded(h, true);
    }

    function setExcluded(address a, bool v) external onlyController {
        _setExcluded(a, v);
    }

    function _setExcluded(address a, bool v) internal {
        // settle before flipping so no fees are stranded across the boundary
        _settle(a);
        if (v) {
            // Remove a's weight from B while it is STILL eligible, THEN mark excluded.
            // Order matters: _setWeight early-returns for excluded addresses, so flipping the flag
            // first would strand a's whole-NFT weight in B forever and dilute every future dividend.
            _setWeight(a, 0);
            excluded[a] = true;
            _setSkipNFT(a, true); // DN404: contracts hold ERC-20 only
        } else {
            excluded[a] = false;
            _setWeight(a, balanceOf(a) / _unit()); // re-enter B at current whole-NFT count
        }
    }

    // ─────────────────────────────────────────── curve mint
    /// @notice ETH cost to buy `qty` whole NFTs at the current curve point (constant product).
    /// @dev    Buying Δ tokens moves virtual reserves (x,y)→(x−Δ, y+cost) with x·y=k, so the exact
    ///         integral cost is `y·Δ/(x−Δ)`. Floored ⇒ buyer pays ≤ exact (never over-charges).
    function quoteBuy(uint256 qty) public view returns (uint256) {
        uint256 dTok = qty * _unit();
        uint256 vTok = V_TOK0 - mintedUnits * _unit();
        uint256 vETH = V_ETH0 + ethRaised;
        return FullMath.mulDiv(vETH, dTok, vTok - dTok);
    }

    /// @notice Buy `qty` whole NFTs along the curve. ETH is escrowed until the curve sells out,
    ///         then atomically seeds the permanently-locked pool. Overpayment is refunded.
    function publicMint(uint256 qty) external payable {
        if (graduated) revert AlreadyGraduated();
        if (qty == 0 || mintedUnits + qty > MAX_SUPPLY) revert SoldOut();
        uint256 cost = quoteBuy(qty);
        if (msg.value < cost) revert WrongValue();

        mintedUnits += qty;
        ethRaised += cost;
        _mint(msg.sender, qty * _unit()); // settles + updates weight inside override
        emit Bought(msg.sender, qty, cost);

        if (mintedUnits == MAX_SUPPLY) _graduate(); // sends ethRaised to the seed before refund

        uint256 refund = msg.value - cost;
        if (refund != 0) SafeTransferLib.safeTransferETH(msg.sender, refund);
    }

    /// @dev Close the curve and seed the locked pool with all escrowed ETH (at the curve's final
    ///      price — the pool is initialized at `curveFinalReserves()` at deploy). Sell-out only.
    function _graduate() internal {
        graduated = true;
        uint256 eth = ethRaised;
        emit Graduated(eth, mintedUnits);
        IEZ404HookSeed(hook).seedLiquidity{value: eth}();
    }

    /// @notice Final virtual reserves after a full sell-out. Deploy/seed initializes the pool at
    ///         this price (sqrtPriceX96 = sqrt(vTokFinal/vEthFinal)·2^96) so there is no jump
    ///         between the curve's last fill and the pool's opening spot.
    function curveFinalReserves() public pure returns (uint256 vTokFinal, uint256 vEthFinal) {
        vTokFinal = V_TOK0 - MAX_SUPPLY * _unit();
        vEthFinal = FullMath.mulDiv(V_ETH0, V_TOK0, vTokFinal); // k / vTokFinal
    }

    /// @notice NFT-units still available on the curve.
    function remaining() external view returns (uint256) {
        return MAX_SUPPLY - mintedUnits;
    }

    /// @notice Pool-side mint for the seed. Hook-only; `to` (PoolManager) must be excluded.
    function mintForSeed(address to, uint256 amount) external onlyHook {
        _mint(to, amount);
    }

    // ─────────────────────────────────────────── fee intake (hook only) + accrual
    function notifyFeeETH() external payable onlyHook {
        _accrue(true, msg.value);
    }

    function notifyFeeToken(uint256 amt) external onlyHook {
        // tokens were transferred to this contract by the hook before this call
        _accrue(false, amt);
    }

    /// @dev Flat per whole NFT: a fee F is split evenly across all `B` eligible NFTs. Single
    ///      floored accumulator ⇒ Σ paid ≤ F (solvent); no subtracted term ⇒ no underflow.
    function _accrue(bool isEth, uint256 amt) internal {
        if (isEth) {
            uint256 F = amt + undist0;
            if (B == 0 || F == 0) {
                undist0 = F; // no eligible NFTs yet → roll over
                return;
            }
            undist0 = 0;
            acc0 += FullMath.mulDiv(F, ACC, B);
        } else {
            uint256 F = amt + undist1;
            if (B == 0 || F == 0) {
                undist1 = F;
                return;
            }
            undist1 = 0;
            acc1 += FullMath.mulDiv(F, ACC, B);
        }
        emit FeeAccrued(isEth, amt);
    }

    // ─────────────────────────────────────────── claim
    function claim() external {
        _settle(msg.sender);
        uint256 e = claimable0[msg.sender];
        uint256 k = claimable1[msg.sender];
        claimable0[msg.sender] = 0;
        claimable1[msg.sender] = 0;
        if (e != 0) SafeTransferLib.safeTransferETH(msg.sender, e);
        if (k != 0) _transfer(address(this), msg.sender, k);
        emit Claimed(msg.sender, e, k);
    }

    // ─────────────────────────────────────────── reward settlement core
    /// @dev rewardᵢ = weightᵢ · (acc − ck) / ACC, weightᵢ = whole NFTs held. Floored, so the sum
    ///      over holders is ≤ the distributed fee; rounding dust stays in the contract.
    function _settle(address u) internal {
        if (excluded[u]) {
            _ck0[u] = acc0;
            _ck1[u] = acc1;
            return;
        }
        uint256 w = _weight[u];
        if (w != 0) {
            claimable0[u] += FullMath.mulDiv(w, acc0 - _ck0[u], ACC);
            claimable1[u] += FullMath.mulDiv(w, acc1 - _ck1[u], ACC);
        }
        _ck0[u] = acc0;
        _ck1[u] = acc1;
    }

    /// @dev Re-sync `a`'s eligible whole-NFT weight into B. No-op for excluded accounts.
    function _setWeight(address a, uint256 newW) internal {
        if (excluded[a]) return;
        B = B - _weight[a] + newW;
        _weight[a] = newW;
    }

    /// @notice Eligible whole-NFT weight currently counted for `a`.
    function weightOf(address a) external view returns (uint256) {
        return _weight[a];
    }

    // ─────────────────────────────────────────── DN404 balance hooks (settle-before-move)
    function _transfer(address from, address to, uint256 amount) internal override {
        _settle(from);
        _settle(to);
        super._transfer(from, to, amount);
        _setWeight(from, balanceOf(from) / _unit());
        _setWeight(to, balanceOf(to) / _unit());
    }

    function _mint(address to, uint256 amount) internal override {
        _settle(to);
        super._mint(to, amount);
        _setWeight(to, balanceOf(to) / _unit());
    }

    function _burn(address from, uint256 amount) internal override {
        _settle(from);
        super._burn(from, amount);
        _setWeight(from, balanceOf(from) / _unit());
    }

    /// @dev INV-1: an ERC-721 mirror transfer (`transferFrom` on the mirror) moves exactly
    ///      `_unit()` of ERC-20 via `_transferFromNFT`, which does NOT route through `_transfer`.
    ///      Without this override, whole-NFT weight would never re-sync on NFT moves. `_settle`
    ///      reads the shadow `_weight` (not the live balance), so settling after `super` is safe.
    function _transferFromNFT(address from, address to, uint256 id, address msgSender)
        internal
        override
    {
        _settle(from);
        _settle(to);
        super._transferFromNFT(from, to, id, msgSender);
        _setWeight(from, balanceOf(from) / _unit());
        _setWeight(to, balanceOf(to) / _unit());
    }

    receive() external payable override {} // claimable ETH funded via notifyFeeETH
}

interface IEZ404HookSeed {
    function seedLiquidity() external payable;
}

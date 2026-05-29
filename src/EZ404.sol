// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DN404} from "solady/tokens/DN404.sol";
import {DN404Mirror} from "solady/tokens/DN404Mirror.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

/// @title EZ404
/// @notice DN404 hybrid (ERC-20 + ERC-721 mirror) with a dual-currency, coin-age-weighted
///         swap-fee dividend ledger and a capped public mint.
/// @dev    WIP — drafted against specs/001-ez404-v4-hooks, not yet compiled or tested.
///         See contracts/IEZ404.md and data-model.md for the behavioral contract and math.
contract EZ404 is DN404 {
    // ─────────────────────────────────────────── constants
    uint256 public constant MAX_SUPPLY = 5000;            // NFT-units
    uint256 public constant pbMintPrice = 0.001 ether;    // ETH per _unit
    uint256 internal constant ACC = 1 << 96;              // accumulator fixed-point scale (P)

    string private _name = "EZ404";
    string private _symbol = "EZ";

    // ─────────────────────────────────────────── roles / wiring
    address public immutable controller;
    address public hook;                                  // set once via setHook
    mapping(address => bool) public excluded;             // never accrues, never in B/S

    // ─────────────────────────────────────────── mint accounting
    uint256 public mintedUnits;

    // ─────────────────────────────────────────── coin-age reward ledger
    uint256 public immutable tStart;
    uint256 public B;                                     // total eligible balance
    uint256 public S;                                     // Σ balᵢ·t0ᵢ
    mapping(address => uint256) public t0;                // coin-age origin (resets on receive)
    mapping(address => uint256) internal _eligBal;        // tracked eligible balance

    // paired accumulators: index 0 = ETH, index 1 = EZ404
    uint256 public accA0;
    uint256 public accB0;
    uint256 public accA1;
    uint256 public accB1;
    uint256 public undist0;                               // rollover when W == 0
    uint256 public undist1;

    mapping(address => uint256) internal _ckA0;
    mapping(address => uint256) internal _ckB0;
    mapping(address => uint256) internal _ckA1;
    mapping(address => uint256) internal _ckB1;
    mapping(address => uint256) public claimable0;        // ETH owed
    mapping(address => uint256) public claimable1;        // EZ404 owed

    // ─────────────────────────────────────────── events / errors
    event FeeAccrued(bool indexed isEth, uint256 amount);
    event Claimed(address indexed user, uint256 eth, uint256 token);
    error OnlyController();
    error OnlyHook();
    error HookAlreadySet();
    error SoldOut();
    error WrongValue();

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
        tStart = block.timestamp;
        address mirror = address(new DN404Mirror(msg.sender));
        _initializeDN404(0, msg.sender, mirror);          // zero initial supply; mint via publicMint
        // the token contract itself never accrues
        excluded[address(this)] = true;
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

    function _tokenURI(uint256 id) internal view override returns (string memory) {
        // WIP: placeholder metadata.
        return string.concat("ez404://", _toString(id));
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
        excluded[a] = v;
        if (v) {
            _setSkipNFT(a, true);                         // DN404: contracts hold ERC-20 only
            // drop out of B/S
            _setElig(a, 0, 0);
        } else {
            _setElig(a, balanceOf(a), _now());
        }
    }

    // ─────────────────────────────────────────── mint
    /// @notice Pay ETH, receive EZ404; the ETH seeds the locked pool (v1: 100%).
    function publicMint(uint256 qty) external payable {
        if (qty == 0 || mintedUnits + qty > MAX_SUPPLY) revert SoldOut();
        if (msg.value != qty * pbMintPrice) revert WrongValue();
        mintedUnits += qty;
        _mint(msg.sender, qty * _unit());                 // settles + updates elig inside override
        // route mint ETH to the locked pool seed
        IEZ404HookSeed(hook).seedLiquidity{value: msg.value}();
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

    function _accrue(bool isEth, uint256 amt) internal {
        uint256 t = _now();
        uint256 W = B * t - S;                            // total coin-age weight
        if (isEth) {
            uint256 F = amt + undist0;
            if (W == 0 || F == 0) {
                undist0 = F;
                return;
            }
            undist0 = 0;
            accA0 += FullMath.mulDiv(F, t * ACC, W);
            accB0 += FullMath.mulDiv(F, ACC, W);
        } else {
            uint256 F = amt + undist1;
            if (W == 0 || F == 0) {
                undist1 = F;
                return;
            }
            undist1 = 0;
            accA1 += FullMath.mulDiv(F, t * ACC, W);
            accB1 += FullMath.mulDiv(F, ACC, W);
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
    function _now() internal view returns (uint256) {
        return block.timestamp - tStart;
    }

    function _settle(address u) internal {
        if (excluded[u]) {
            _ckA0[u] = accA0;
            _ckB0[u] = accB0;
            _ckA1[u] = accA1;
            _ckB1[u] = accB1;
            return;
        }
        uint256 b = _eligBal[u];
        if (b != 0) {
            uint256 bt = b * t0[u];
            // WIP/T028: prove the A-term ≥ B-term so these subtractions never underflow.
            claimable0[u] += FullMath.mulDiv(b, accA0 - _ckA0[u], ACC)
                - FullMath.mulDiv(bt, accB0 - _ckB0[u], ACC);
            claimable1[u] += FullMath.mulDiv(b, accA1 - _ckA1[u], ACC)
                - FullMath.mulDiv(bt, accB1 - _ckB1[u], ACC);
        }
        _ckA0[u] = accA0;
        _ckB0[u] = accB0;
        _ckA1[u] = accA1;
        _ckB1[u] = accB1;
    }

    /// @dev Remove old (bal·t0) contribution from B/S and add the new one. No-op for excluded.
    function _setElig(address a, uint256 newBal, uint256 newT0) internal {
        if (excluded[a]) return;
        S -= _eligBal[a] * t0[a];
        B -= _eligBal[a];
        _eligBal[a] = newBal;
        t0[a] = newT0;
        B += newBal;
        S += newBal * newT0;
    }

    // ─────────────────────────────────────────── DN404 balance hooks (settle-before-move, INV-1)
    function _transfer(address from, address to, uint256 amount) internal override {
        _settle(from);
        _settle(to);
        super._transfer(from, to, amount);
        _setElig(from, balanceOf(from), t0[from]);        // sender keeps its age
        _setElig(to, balanceOf(to), _now());              // receiver resets age (v1 policy, D-6/T028)
    }

    function _mint(address to, uint256 amount) internal override {
        _settle(to);
        super._mint(to, amount);
        _setElig(to, balanceOf(to), _now());
    }

    function _burn(address from, uint256 amount) internal override {
        _settle(from);
        super._burn(from, amount);
        _setElig(from, balanceOf(from), t0[from]);
    }

    // WIP/INV-1/T064: NFT transfers via the DN404 mirror adjust ERC-20 balances WITHOUT routing
    // through _transfer above. _transferFromNFT must be overridden (or balances re-synced) so
    // coin-age settlement also fires on NFT moves. Tracked as the #1 correctness gap.

    function _toString(uint256 v) internal pure returns (string memory) {
        return FixedPointMathLib.toString(v);
    }

    receive() external payable {}                         // claimable ETH funded via notifyFeeETH
}

interface IEZ404HookSeed {
    function seedLiquidity() external payable;
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Deploys EZ404 + EZ404Hook, wires them, and initializes the pool at the curve's final price.
// No day-one seed: the pump.fun curve escrows mint ETH and auto-seeds the locked pool on sell-out
// (D-13). WIP — drafted against specs/001-ez404-v4-hooks; verify on a fork before any live use.
//
// Usage:
//   POOL_MANAGER=0x... forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --private-key $PK

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

import {EZ404} from "../src/EZ404.sol";
import {EZ404Hook, IEZ404Fee} from "../src/EZ404Hook.sol";

contract Deploy is Script {
    // Canonical CREATE2 deployer (forge routes `new{salt}` through it when broadcasting).
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint24 constant LP_FEE = 3000;
    int24 constant TICK_SPACING = 60;
    uint16 constant HOOK_FEE_BPS = 100; // 1% dividend skim

    function run() external {
        address pm = vm.envAddress("POOL_MANAGER");

        vm.startBroadcast();

        // 1) token first (controller = broadcaster)
        EZ404 token = new EZ404();

        // 2) mine hook address with EXACT ctor args (flags 0xA44)
        uint160 flags = uint160(
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory args =
            abi.encode(IPoolManager(pm), IEZ404Fee(address(token)), msg.sender, HOOK_FEE_BPS);
        (address hookAddr, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(EZ404Hook).creationCode, args);

        // 3) deploy hook at the mined address
        EZ404Hook hook =
            new EZ404Hook{salt: salt}(IPoolManager(pm), IEZ404Fee(address(token)), msg.sender, HOOK_FEE_BPS);
        require(address(hook) == hookAddr, "hook addr mismatch");
        require((uint160(address(hook)) & 0x3FFF) == 0xA44, "flag bits"); // AC-7

        // 4) wire token <-> hook + exclusions
        token.setHook(address(hook));
        token.setExcluded(pm, true);

        // 5) pool key (native ETH = currency0) + hand it to the hook
        PoolKey memory key = PoolKey(
            Currency.wrap(address(0)), Currency.wrap(address(token)), LP_FEE, TICK_SPACING, IHooks(address(hook))
        );
        hook.setKey(key);

        // 6) initialize at the curve's FINAL price so the curve→pool handoff is continuous (D-13).
        //    No seed here — publicMint escrows ETH and auto-seeds on sell-out (_graduate).
        (uint256 vTokFinal, uint256 vEthFinal) = token.curveFinalReserves();
        uint160 sqrtPFinal =
            uint160(FixedPointMathLib.sqrt(FullMath.mulDiv(vTokFinal, 1 << 192, vEthFinal)));
        IPoolManager(pm).initialize(key, sqrtPFinal);

        vm.stopBroadcast();

        console2.log("EZ404    :", address(token));
        console2.log("EZ404Hook:", address(hook));
        console2.log("sqrtPFinal:", uint256(sqrtPFinal));
    }
}

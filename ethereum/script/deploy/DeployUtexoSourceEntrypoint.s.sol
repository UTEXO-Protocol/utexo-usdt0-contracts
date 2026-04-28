// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { Script, console2 } from 'forge-std/Script.sol';
import { UtexoSourceEntrypoint } from '../../src/UtexoSourceEntrypoint.sol';

/// @title DeployUtexoSourceEntrypoint
/// @notice Deploys `UtexoSourceEntrypoint` on a source chain (Ethereum, OP, Base, …).
///         The contract is stateless and non-upgradeable — all parameters are immutable.
///         To update any parameter, redeploy and point the frontend to the new address.
///
/// Env:
///   PRIVATE_KEY          — deployer private key
///   TOKEN_ADDRESS        — ERC-20 pulled from users (canonical USDT on Ethereum;
///                          USDT0 token on chains where it is native)
///   OFT_ADDRESS          — USDT0 OFT (adapter or native) on this source chain
///   DST_EID              — LayerZero endpoint id of the destination chain
///                          (Arbitrum = 30110)
///   BRIDGE_COMPOSER      — BridgeComposer address on the destination chain,
///                          left-padded to 32 bytes (bytes32)
///                          e.g. 0x000000000000000000000000<BridgeComposer address>
///
/// Usage:
///   forge script script/deploy/DeployUtexoSourceEntrypoint.s.sol \
///     --rpc-url $RPC_URL --broadcast --verify
contract DeployUtexoSourceEntrypoint is Script {
    function run() external returns (UtexoSourceEntrypoint entrypoint) {
        uint256 pk              = vm.envUint('PRIVATE_KEY');
        address token           = vm.envAddress('TOKEN_ADDRESS');
        address oft             = vm.envAddress('OFT_ADDRESS');
        uint32  dstEid          = uint32(vm.envUint('DST_EID'));
        bytes32 bridgeComposer  = vm.envBytes32('BRIDGE_COMPOSER');

        vm.startBroadcast(pk);
        entrypoint = new UtexoSourceEntrypoint(token, oft, dstEid, bridgeComposer);
        vm.stopBroadcast();

        console2.log('UtexoSourceEntrypoint deployed at:', address(entrypoint));
        console2.log('Token:          ', entrypoint.token());
        console2.log('OFT:            ', entrypoint.oft());
        console2.log('DstEid:         ', entrypoint.dstEid());
        console2.log('BridgeComposer: ');
        console2.logBytes32(entrypoint.bridgeComposer());
    }
}

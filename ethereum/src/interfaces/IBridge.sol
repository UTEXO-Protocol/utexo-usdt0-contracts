// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title IBridge (minimal)
/// @notice Local re-declaration of the subset of the Utexo Bridge interface that
///         `UtexoLZAdapter` calls on the inbound (FundsIn) path. The full Bridge
///         interface lives in `utexo-smart-contracts/ethereum/src/interfaces/IBridge.sol`.
/// @dev Layout must stay byte-compatible with the upstream definition.
interface IBridge {
    /// @notice Adapter-side `fundsIn`: locks the bridged token after a
    ///         cross-chain transfer was originated on `sourceChainId`. The
    ///         upstream Bridge guards this overload with `onlyLZAdapter` so
    ///         only the trusted adapter can supply a non-spoofable
    ///         `sourceChainId`. Direct EVM users on Arbitrum call the
    ///         no-`sourceChainId` overload, which the upstream Bridge fills
    ///         with `block.chainid` itself.
    /// @dev Payable: if the active route uses NATIVE commission currency,
    ///      `msg.value` must equal the quoted native commission; otherwise
    ///      `msg.value` must be 0. Replay protection is enforced via
    ///      `operationId` (rejected if it already exists in `fundsInRecords`).
    function fundsIn(
        uint256 amount,
        uint256 sourceChainId,
        string  calldata destinationChain,
        string  calldata destinationAddress,
        uint256 operationId
    ) external payable;
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title IBridge (minimal)
/// @notice Local re-declaration of the subset of the Utexo Bridge interface that
///         `UtexoLZAdapter` calls on the inbound (FundsIn) path. The full Bridge
///         interface lives in `utexo-smart-contracts/ethereum/src/interfaces/IBridge.sol`.
/// @dev Layout must stay byte-compatible with the upstream definition.
interface IBridge {
    /// @notice Lock the bridged token in the Bridge to initiate a transfer to another chain.
    /// @dev Payable: if the active route uses NATIVE commission currency, `msg.value`
    ///      must equal the quoted native commission; otherwise `msg.value` must be 0.
    /// @dev Permissionless on the EVM side. Replay protection is enforced via
    ///      `operationId` (rejected if it already exists in `fundsInRecords`).
    function fundsIn(
        uint256 amount,
        string  calldata destinationChain,
        string  calldata destinationAddress,
        uint256 operationId
    ) external payable;
}

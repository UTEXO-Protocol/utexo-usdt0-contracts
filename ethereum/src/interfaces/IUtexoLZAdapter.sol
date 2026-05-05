// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title IUtexoLZAdapter
/// @notice Bidirectional adapter between the Utexo `Bridge` and the LayerZero / USDT0 stack
///         on Arbitrum. Handles two distinct flows:
///
///           • Inbound  (non-Arbitrum EVM → RGB): receives USDT0 via LayerZero compose
///                       and calls `Bridge.fundsIn` to lock it.
///           • Outbound (RGB → non-Arbitrum EVM): receives USDT0 from `Bridge.fundsOut`
///                       and forwards it via `OFT.send` to the user's destination chain.
interface IUtexoLZAdapter {
    // =========================================================================
    // Errors
    // =========================================================================

    error InvalidEndpoint();
    error InvalidOft();
    error InvalidToken();
    error InvalidBridge();
    error InvalidMultisigProxy();
    error InvalidRecipient();

    error NotEndpoint();
    error NotMultisigProxy();
    error NotFromOft();

    error ZeroAmount();
    error InsufficientNativeFee(uint256 provided, uint256 required);
    error NativeRefundFailed();

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted on a successful inbound `lzCompose` → `Bridge.fundsIn` call.
    /// @param guid               LayerZero message guid.
    /// @param srcEid             Source LayerZero endpoint id.
    /// @param amountLD           Amount of USDT0 forwarded into the Bridge (gross).
    /// @param destinationChain   Target chain identifier (e.g. "rgb").
    /// @param destinationAddress Target address on the destination chain.
    /// @param operationId        Backend-assigned operation identifier.
    event ComposeFundsIn(
        bytes32 indexed guid,
        uint32  srcEid,
        uint256 amountLD,
        string  destinationChain,
        string  destinationAddress,
        uint256 operationId
    );

    /// @notice Emitted on a successful outbound `sendOut` → `OFT.send` call.
    /// @param guid       LayerZero message guid returned by the OFT.
    /// @param dstEid     Destination LayerZero endpoint id.
    /// @param recipient  Recipient address on the destination chain (left-padded bytes32).
    /// @param amountLD   Amount of USDT0 sent.
    event SendOut(
        bytes32 indexed guid,
        uint32  dstEid,
        bytes32 recipient,
        uint256 amountLD
    );

    // =========================================================================
    // State views
    // =========================================================================

    function endpoint()      external view returns (address);
    function oft()           external view returns (address);
    function token()         external view returns (address);
    function bridge()        external view returns (address);
    function multisigProxy() external view returns (address);

    // =========================================================================
    // Outbound — restricted to MultisigProxy
    // =========================================================================

    /// @notice Forward USDT0 (already held by this adapter as a result of a prior
    ///         `Bridge.fundsOut(recipient = address(this))` leg) to a user on a
    ///         destination LayerZero chain.
    /// @dev Re-quotes the LayerZero fee on-chain. `msg.value` must cover the quoted
    ///      `nativeFee`; surplus is refunded to `multisigProxy`.
    /// @param dstEid       Destination LayerZero endpoint id.
    /// @param recipient    Recipient on destination chain (address left-padded to bytes32).
    /// @param amount       Amount of USDT0 to send.
    /// @param minAmountLD  Slippage guard.
    /// @param extraOptions LayerZero executor options (`lzReceiveOption` only — no compose).
    /// @return guid LayerZero message guid.
    function sendOut(
        uint32  dstEid,
        bytes32 recipient,
        uint256 amount,
        uint256 minAmountLD,
        bytes   calldata extraOptions
    ) external payable returns (bytes32 guid);

    /// @notice Convenience re-export of `OFT.quoteSend` for the outbound shape.
    function quoteSendOut(
        uint32  dstEid,
        bytes32 recipient,
        uint256 amount,
        uint256 minAmountLD,
        bytes   calldata extraOptions
    ) external view returns (uint256 nativeFee);
}

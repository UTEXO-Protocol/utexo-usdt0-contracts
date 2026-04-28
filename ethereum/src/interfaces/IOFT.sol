// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title IOFT (minimal)
/// @notice Local re-declaration of the LayerZero V2 OFT interface, limited to the
///         entry points the Utexo source entrypoint depends on. Kept self-contained
///         so this repo does not take a hard dependency on `@layerzerolabs/*`
///         packages at the Solidity layer.
/// @dev Layouts must stay byte-compatible with the upstream definitions:
///      https://github.com/LayerZero-Labs/LayerZero-v2 (packages/layerzero-v2/evm/oapp)

/// @dev LayerZero `SendParam` struct.
struct SendParam {
    uint32  dstEid;        // destination endpoint id
    bytes32 to;            // recipient (address left-padded into 32 bytes)
    uint256 amountLD;      // amount to send, in local decimals
    uint256 minAmountLD;   // minimum amount to deliver, in local decimals
    bytes   extraOptions;  // LayerZero executor options (lzReceive/lzCompose gas + value)
    bytes   composeMsg;    // payload delivered to the composer on the destination chain
    bytes   oftCmd;        // OFT-specific command (always empty for standard transfers)
}

/// @dev LayerZero fee struct.
struct MessagingFee {
    uint256 nativeFee;
    uint256 lzTokenFee;
}

/// @dev LayerZero send receipt struct.
struct MessagingReceipt {
    bytes32 guid;
    uint64  nonce;
    MessagingFee fee;
}

/// @dev OFT-side receipt.
struct OFTReceipt {
    uint256 amountSentLD;
    uint256 amountReceivedLD;
}

interface IOFT {
    /// @notice Sends tokens cross-chain via LayerZero.
    /// @dev The caller must have approved `token()` to the OFT for at least `sendParam.amountLD`.
    ///      `msg.value` must cover `fee.nativeFee`; any surplus is returned to `refundAddress`.
    function send(
        SendParam calldata sendParam,
        MessagingFee calldata fee,
        address refundAddress
    ) external payable returns (MessagingReceipt memory, OFTReceipt memory);

    /// @notice Quotes the LayerZero messaging fee for the given `sendParam`.
    function quoteSend(SendParam calldata sendParam, bool payInLzToken)
        external view returns (MessagingFee memory);
}

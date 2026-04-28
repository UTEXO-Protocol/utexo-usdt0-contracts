// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title IUtexoSourceEntrypoint
/// @notice User-facing deposit entrypoint on source chains (Ethereum, OP, Base, …).
///         Wraps the USDT0 OFT `send()` call so the visible protocol surface belongs
///         to Utexo rather than directly to Tether's OFT contract.
interface IUtexoSourceEntrypoint {
    // =========================================================================
    // Types
    // =========================================================================

    /// @param amountLD     Amount of `token` to deposit, in local decimals.
    /// @param minAmountLD  Minimum amount that must be credited on destination; serves
    ///                     as a slippage guard against OFT-side fees.
    /// @param extraOptions LayerZero executor options encoding `lzReceive` / `lzCompose`
    ///                     gas budgets and the destination-side `msg.value` forwarded
    ///                     into `BridgeComposer.lzCompose`. Produced by the backend.
    /// @param composeMsg   Opaque payload consumed by `BridgeComposer` on destination.
    ///                     Produced by the backend; this contract never inspects it.
    struct DepositParams {
        uint256 amountLD;
        uint256 minAmountLD;
        bytes   extraOptions;
        bytes   composeMsg;
    }

    // =========================================================================
    // Errors
    // =========================================================================

    error InvalidTokenAddress();
    error InvalidOftAddress();
    error InvalidBridgeComposer();
    error InvalidDstEid();
    error ZeroAmount();
    error InsufficientNativeFee(uint256 provided, uint256 required);
    error NativeRefundFailed();
    error TokenResidue(uint256 remaining);

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted for every successful deposit forwarded to the USDT0 OFT.
    /// @param guid       LayerZero message guid; correlates with the compose event on
    ///                   the destination chain.
    /// @param user       Address whose tokens were pulled and charged for the LZ fee.
    /// @param amountLD   Amount of `token` forwarded into the OFT (gross, pre-OFT-fee).
    /// @param composeMsg Opaque payload forwarded to `BridgeComposer`.
    event Deposit(
        bytes32 indexed guid,
        address indexed user,
        uint256 amountLD,
        bytes   composeMsg
    );

    // =========================================================================
    // State views
    // =========================================================================

    function token() external view returns (address);
    function oft() external view returns (address);
    function dstEid() external view returns (uint32);
    function bridgeComposer() external view returns (bytes32);

    // =========================================================================
    // User entry point
    // =========================================================================

    /// @notice Pulls `p.amountLD` of `token` from the caller, forwards it into the
    ///         USDT0 OFT, and requests LayerZero delivery to the Utexo
    ///         `BridgeComposer` on the destination chain with the provided
    ///         `composeMsg`.
    /// @dev    `msg.value` must cover the LayerZero native fee returned by
    ///         `IOFT.quoteSend`. Surplus is refunded to the caller.
    function deposit(DepositParams calldata p) external payable returns (bytes32 guid);

    /// @notice Convenience re-export of `IOFT.quoteSend` so frontends can quote without
    ///         knowing the OFT address / hard-coded `dstEid` / `bridgeComposer`.
    function quote(DepositParams calldata p) external view returns (uint256 nativeFee);
}

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
    ///                     into `UtexoLZAdapter.lzCompose`. Produced by the backend.
    /// @param payload      Caller-supplied business payload encoded as
    ///                     `abi.encode(string destinationChain, string destinationAddress, uint256 operationId)`.
    ///                     The entrypoint decodes it on the source chain to validate
    ///                     the format (malformed input reverts here, before any LZ fee
    ///                     is paid) and re-encodes it with `block.chainid` prepended
    ///                     as the actual `composeMsg` forwarded to LayerZero. The
    ///                     `sourceChainId` part is therefore non-spoofable.
    struct DepositParams {
        uint256 amountLD;
        uint256 minAmountLD;
        bytes   extraOptions;
        bytes   payload;
    }

    // =========================================================================
    // Errors
    // =========================================================================

    error InvalidTokenAddress();
    error InvalidOftAddress();
    error InvalidLZAdapter();
    error InvalidDstEid();
    error ZeroAmount();
    error InsufficientNativeFee(uint256 provided, uint256 required);
    error NativeRefundFailed();

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted for every successful deposit forwarded to the USDT0 OFT.
    /// @param guid               LayerZero message guid; correlates with the compose
    ///                           event on the destination chain.
    /// @param user               Address whose tokens were pulled and charged for the
    ///                           LZ fee.
    /// @param amountLD           Amount of `token` forwarded into the OFT (gross,
    ///                           pre-OFT-fee).
    /// @param sourceChainId      `block.chainid` captured at deposit time; embedded
    ///                           in the `composeMsg` and consumed by `Bridge.fundsIn`
    ///                           on Arbitrum for commission routing.
    /// @param destinationChain   Final destination chain id (passes through to Bridge).
    /// @param destinationAddress Final recipient address on `destinationChain`.
    /// @param operationId        Backend-assigned operation id (replay guard on Bridge).
    event Deposit(
        bytes32 indexed guid,
        address indexed user,
        uint256 amountLD,
        uint256 sourceChainId,
        string  destinationChain,
        string  destinationAddress,
        uint256 operationId
    );

    // =========================================================================
    // State views
    // =========================================================================

    function token() external view returns (address);
    function oft() external view returns (address);
    function dstEid() external view returns (uint32);
    function lzAdapter() external view returns (bytes32);

    // =========================================================================
    // User entry point
    // =========================================================================

    /// @notice Pulls `p.amountLD` of `token` from the caller, forwards it into the
    ///         USDT0 OFT, and requests LayerZero delivery to the Utexo
    ///         `UtexoLZAdapter` on the destination chain. The entrypoint
    ///         constructs the `composeMsg` itself with `block.chainid` as the first
    ///         field so the caller cannot spoof the source-chain identifier that
    ///         `Bridge` will use for commission routing.
    /// @dev    `msg.value` must cover the LayerZero native fee returned by
    ///         `IOFT.quoteSend`. Surplus is refunded to the caller.
    function deposit(DepositParams calldata p) external payable returns (bytes32 guid);

    /// @notice Convenience re-export of `IOFT.quoteSend` so frontends can quote without
    ///         knowing the OFT address / hard-coded `dstEid` / `lzAdapter`. Builds
    ///         the same `composeMsg` as `deposit`.
    function quote(DepositParams calldata p) external view returns (uint256 nativeFee);
}

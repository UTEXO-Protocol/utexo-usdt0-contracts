// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { IERC20 }    from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import { SafeERC20 } from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import { ReentrancyGuard } from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';

import { IUtexoSourceEntrypoint } from './interfaces/IUtexoSourceEntrypoint.sol';
import {
    IOFT,
    SendParam,
    MessagingFee,
    MessagingReceipt,
    OFTReceipt
} from './interfaces/IOFT.sol';

/// @title UtexoSourceEntrypoint
/// @notice Utexo's user-facing deposit contract on source chains (Ethereum, OP, Base, …).
/// @dev
///     ┌────────────┐ transferFrom  ┌────────────────────┐   OFT.send    ┌──────────────┐
///     │  user EOA  │──────────────▶│ UtexoSource        │──────────────▶│ USDT0 OFT    │
///     └────────────┘               │ Entrypoint (this)  │               └──────┬───────┘
///                                  └────────────────────┘                      │
///                                                                              │ LayerZero
///                                                                              ▼
///                                                               ┌──────────────────────┐
///                                                               │ UtexoLZAdapter       │
///                                                               │ (destination chain)  │
///                                                               └──────────────────────┘
///
///     Properties:
///       • Stateless — only immutables.
///       • Non-upgradeable. Replacement = redeploy; no owner, no pause, no admin.
///       • `dstEid` and `lzAdapter` are fixed at construction and cannot be
///         re-pointed at a different destination by the caller or anyone else.
///       • `composeMsg` is opaque: the entrypoint never inspects or rewrites it.
///       • LayerZero fee is re-quoted on-chain; surplus `msg.value` is refunded to
///         `msg.sender`.
contract UtexoSourceEntrypoint is IUtexoSourceEntrypoint, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =========================================================================
    // Immutables
    // =========================================================================

    /// @inheritdoc IUtexoSourceEntrypoint
    address public immutable override token;

    /// @inheritdoc IUtexoSourceEntrypoint
    address public immutable override oft;

    /// @inheritdoc IUtexoSourceEntrypoint
    uint32  public immutable override dstEid;

    /// @inheritdoc IUtexoSourceEntrypoint
    bytes32 public immutable override lzAdapter;

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param token_      ERC-20 that will be pulled from users and forwarded into
    ///                    the OFT. On Ethereum this is canonical USDT; on chains
    ///                    where USDT0 is native this is the USDT0 token itself.
    /// @param oft_        USDT0 OFT on this chain.
    /// @param dstEid_     LayerZero endpoint id of the destination chain (Arbitrum).
    /// @param lzAdapter_  `UtexoLZAdapter` address on the destination chain, encoded
    ///                    as bytes32 (address left-padded, per LayerZero V2 convention).
    constructor(
        address token_,
        address oft_,
        uint32  dstEid_,
        bytes32 lzAdapter_
    ) {
        if (token_ == address(0))      revert InvalidTokenAddress();
        if (oft_ == address(0))        revert InvalidOftAddress();
        if (dstEid_ == 0)              revert InvalidDstEid();
        if (lzAdapter_ == bytes32(0))  revert InvalidLZAdapter();

        token     = token_;
        oft       = oft_;
        dstEid    = dstEid_;
        lzAdapter = lzAdapter_;
    }

    // =========================================================================
    // User entry point
    // =========================================================================

    /// @inheritdoc IUtexoSourceEntrypoint
    function deposit(DepositParams calldata depositParams)
        external
        payable
        override
        nonReentrant
        returns (bytes32 guid)
    {
        if (depositParams.amountLD == 0) revert ZeroAmount();

        // 1. Pull the user's tokens into this contract, then allow the OFT to pull
        //    exactly `amountLD` on `send()`. The OFT consumes the entire allowance
        //    via `transferFrom`;
        IERC20(token).safeTransferFrom(msg.sender, address(this), depositParams.amountLD);
        IERC20(token).safeIncreaseAllowance(oft, depositParams.amountLD);

        // 2. Build the LayerZero send parameters. `dstEid` and `to` are immutable on
        //    this contract — the caller cannot redirect the funds.
        SendParam memory sp = SendParam({
            dstEid:       dstEid,
            to:           lzAdapter,
            amountLD:     depositParams.amountLD,
            minAmountLD:  depositParams.minAmountLD,
            extraOptions: depositParams.extraOptions,
            composeMsg:   depositParams.composeMsg,
            oftCmd:       ''
        });

        // 3. Re-quote the LayerZero fee on-chain. This defends against the window
        //    between `quoteSend` off-chain and transaction inclusion, during which
        //    LayerZero pricing may change.
        MessagingFee memory fee = IOFT(oft).quoteSend(sp, false);
        if (msg.value < fee.nativeFee) {
            revert InsufficientNativeFee({ provided: msg.value, required: fee.nativeFee });
        }

        // 4. Forward exactly `fee.nativeFee` to the OFT; refund surplus ourselves.
        //    Using `msg.sender` as `refundAddress` is defensive only: with this call
        //    shape the OFT has no surplus to refund.
        (MessagingReceipt memory receipt, ) =
            IOFT(oft).send{ value: fee.nativeFee }(sp, fee, msg.sender);
        guid = receipt.guid;

        // 5. Refund the user's native surplus (msg.value - nativeFee).
        uint256 excess = msg.value - fee.nativeFee;
        if (excess != 0) {
            (bool ok, ) = msg.sender.call{ value: excess }('');
            if (!ok) revert NativeRefundFailed();
        }

        emit Deposit(guid, msg.sender, depositParams.amountLD, depositParams.composeMsg);
    }

    /// @inheritdoc IUtexoSourceEntrypoint
    function quote(DepositParams calldata depositParams)
        external
        view
        override
        returns (uint256 nativeFee)
    {
        SendParam memory sp = SendParam({
            dstEid:       dstEid,
            to:           lzAdapter,
            amountLD:     depositParams.amountLD,
            minAmountLD:  depositParams.minAmountLD,
            extraOptions: depositParams.extraOptions,
            composeMsg:   depositParams.composeMsg,
            oftCmd:       ''
        });
        return IOFT(oft).quoteSend(sp, false).nativeFee;
    }
}

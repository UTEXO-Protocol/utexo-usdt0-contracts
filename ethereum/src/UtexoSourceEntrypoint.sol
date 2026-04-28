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
///                                                               │ BridgeComposer       │
///                                                               │ (destination chain)  │
///                                                               └──────────────────────┘
///
///     Properties:
///       • Stateless — only immutables. Token residue is asserted to be zero at exit.
///       • Non-upgradeable. Replacement = redeploy; no owner, no pause, no admin.
///       • `dstEid` and `bridgeComposer` are fixed at construction and cannot be
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
    bytes32 public immutable override bridgeComposer;

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param token_          ERC-20 that will be pulled from users and forwarded into
    ///                        the OFT. On Ethereum this is canonical USDT; on chains
    ///                        where USDT0 is native this is the USDT0 token itself
    ///                        (typically the same address as `oft_`).
    /// @param oft_            USDT0 OFT (adapter or native) on this chain.
    /// @param dstEid_         LayerZero endpoint id of the destination chain (Arbitrum).
    /// @param bridgeComposer_ `BridgeComposer` address on the destination chain, encoded
    ///                        as bytes32 (address left-padded, per LayerZero V2 convention).
    constructor(
        address token_,
        address oft_,
        uint32  dstEid_,
        bytes32 bridgeComposer_
    ) {
        if (token_ == address(0))           revert InvalidTokenAddress();
        if (oft_ == address(0))             revert InvalidOftAddress();
        if (dstEid_ == 0)                   revert InvalidDstEid();
        if (bridgeComposer_ == bytes32(0))  revert InvalidBridgeComposer();

        token          = token_;
        oft            = oft_;
        dstEid         = dstEid_;
        bridgeComposer = bridgeComposer_;
    }

    // =========================================================================
    // User entry point
    // =========================================================================

    /// @inheritdoc IUtexoSourceEntrypoint
    function deposit(DepositParams calldata p)
        external
        payable
        override
        nonReentrant
        returns (bytes32 guid)
    {
        if (p.amountLD == 0) revert ZeroAmount();

        // 1. Pull the user's tokens into this contract, then allow the OFT to pull
        //    exactly `amountLD` on `send()`. The OFT consumes the entire allowance
        //    via `transferFrom`; we assert residue at the end of the call for
        //    defence-in-depth against an OFT that under-consumes.
        IERC20(token).safeTransferFrom(msg.sender, address(this), p.amountLD);
        IERC20(token).safeIncreaseAllowance(oft, p.amountLD);

        // 2. Build the LayerZero send parameters. `dstEid` and `to` are immutable on
        //    this contract — the caller cannot redirect the funds.
        SendParam memory sp = SendParam({
            dstEid:       dstEid,
            to:           bridgeComposer,
            amountLD:     p.amountLD,
            minAmountLD:  p.minAmountLD,
            extraOptions: p.extraOptions,
            composeMsg:   p.composeMsg,
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

        // 6. Token invariant: entrypoint must not hold any tokens across calls.
        uint256 residue = IERC20(token).balanceOf(address(this));
        if (residue != 0) revert TokenResidue(residue);

        emit Deposit(guid, msg.sender, p.amountLD, p.composeMsg);
    }

    /// @inheritdoc IUtexoSourceEntrypoint
    function quote(DepositParams calldata p)
        external
        view
        override
        returns (uint256 nativeFee)
    {
        SendParam memory sp = SendParam({
            dstEid:       dstEid,
            to:           bridgeComposer,
            amountLD:     p.amountLD,
            minAmountLD:  p.minAmountLD,
            extraOptions: p.extraOptions,
            composeMsg:   p.composeMsg,
            oftCmd:       ''
        });
        return IOFT(oft).quoteSend(sp, false).nativeFee;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { IERC20 }    from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import { SafeERC20 } from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import { ReentrancyGuard } from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';

import { IOAppComposer }      from '@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/interfaces/IOAppComposer.sol';
import { ILayerZeroComposer } from '@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol';
import { OFTComposeMsgCodec } from '@layerzerolabs/lz-evm-oapp-v2/contracts/oft/libs/OFTComposeMsgCodec.sol';

import { IUtexoLZAdapter } from './interfaces/IUtexoLZAdapter.sol';
import { IBridge }         from './interfaces/IBridge.sol';
import {
    IOFT,
    SendParam,
    MessagingFee,
    MessagingReceipt
} from './interfaces/IOFT.sol';

/// @title UtexoLZAdapter
/// @notice Bidirectional adapter between the Utexo `Bridge` (on Arbitrum) and the
///         USDT0 OFT / LayerZero V2 stack. Lives in the USDT0 layer repo so the
///         core security contracts (Bridge, MultisigProxy, CommissionManager) stay
///         free of LayerZero dependencies.
///
/// @dev Two flows are supported:
///
///      ┌──────────────────────────── Inbound (FundsIn) ───────────────────────────┐
///      │  LayerZero ──► OFT.lzReceive (mints USDT0 to this contract)              │
///      │                                                                          │
///      │  LayerZero ──► UtexoLZAdapter.lzCompose                                  │
///      │                  │                                                       │
///      │                  ├─► validate msg.sender == endpoint, _from == oft       │
///      │                  ├─► decode amountLD + business payload                  │
///      │                  ├─► approve Bridge for amountLD                         │
///      │                  └─► Bridge.fundsIn{ value: msg.value }(amount, ...)     │
///      └──────────────────────────────────────────────────────────────────────────┘
///
///      ┌──────────────────────────── Outbound (FundsOut) ─────────────────────────┐
///      │  MultisigProxy.executeBatch ──► [0] Bridge.fundsOut(recipient = adapter)│
///      │                            └──► [1] UtexoLZAdapter.sendOut               │
///      │                                       │                                  │
///      │                                       ├─► validate msg.sender == proxy   │
///      │                                       ├─► re-quote LZ fee on-chain       │
///      │                                       ├─► approve OFT for amount         │
///      │                                       └─► OFT.send(SendParam{...})       │
///      └──────────────────────────────────────────────────────────────────────────┘
///
///      All five participating addresses (endpoint, oft, token, bridge, multisigProxy)
///      are immutable. To repoint any of them — redeploy the adapter and update the
///      reference via federation governance on `MultisigProxy`.
contract UtexoLZAdapter is IUtexoLZAdapter, IOAppComposer, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =========================================================================
    // Immutables
    // =========================================================================

    /// @inheritdoc IUtexoLZAdapter
    address public immutable override endpoint;

    /// @inheritdoc IUtexoLZAdapter
    address public immutable override oft;

    /// @inheritdoc IUtexoLZAdapter
    address public immutable override token;

    /// @inheritdoc IUtexoLZAdapter
    address public immutable override bridge;

    /// @inheritdoc IUtexoLZAdapter
    address public immutable override multisigProxy;

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param endpoint_      LayerZero V2 EndpointV2 on Arbitrum.
    /// @param oft_           USDT0 OFT contract on Arbitrum.
    /// @param token_         USDT0 token on Arbitrum.
    /// @param bridge_        Utexo `Bridge` contract on Arbitrum.
    /// @param multisigProxy_ Utexo `MultisigProxy`.
    constructor(
        address endpoint_,
        address oft_,
        address token_,
        address bridge_,
        address multisigProxy_
    ) {
        if (endpoint_      == address(0)) revert InvalidEndpoint();
        if (oft_           == address(0)) revert InvalidOft();
        if (token_         == address(0)) revert InvalidToken();
        if (bridge_        == address(0)) revert InvalidBridge();
        if (multisigProxy_ == address(0)) revert InvalidMultisigProxy();

        endpoint      = endpoint_;
        oft           = oft_;
        token         = token_;
        bridge        = bridge_;
        multisigProxy = multisigProxy_;
    }

    // =========================================================================
    // Inbound — LayerZero compose hook
    // =========================================================================

    /// @inheritdoc ILayerZeroComposer
    /// @dev Tokens have already been credited to this contract by `OFT._lzReceive`.
    ///      This call decodes the compose payload and
    ///      forwards the tokens into `Bridge.fundsIn`.
    function lzCompose(
        address _from,
        bytes32 _guid,
        bytes   calldata _message,
        address /*_executor*/,
        bytes   calldata /*_extraData*/
    )
        external
        payable
        override
        nonReentrant
    {
        if (msg.sender != endpoint) revert NotEndpoint();
        if (_from      != oft)      revert NotFromOft();

        // 1. Decode the LayerZero compose data.
        uint256 amountLD     = OFTComposeMsgCodec.amountLD(_message);
        bytes memory payload = OFTComposeMsgCodec.composeMsg(_message);

        // 2. Decode the business payload — produced by the Utexo backend on the
        //    source chain and copied through LayerZero unchanged.
        (
            string memory destinationChain,
            string memory destinationAddress,
            uint256 operationId
        ) = abi.decode(payload, (string, string, uint256));

        // 3. Approve Bridge to pull the USDT0 we just received via lzReceive.
        IERC20(token).safeIncreaseAllowance(bridge, amountLD);

        // 4. Forward the call. `msg.value` here is the value the LayerZero Executor
        //    forwarded into this lzCompose, sized off-chain by the backend to match
        //    the route's NATIVE commission (or 0 for TOKEN-currency routes).
        IBridge(bridge).fundsIn{ value: msg.value }(
            amountLD,
            destinationChain,
            destinationAddress,
            operationId
        );

        emit ComposeFundsIn(
            _guid,
            OFTComposeMsgCodec.srcEid(_message),
            amountLD,
            destinationChain,
            destinationAddress,
            operationId
        );
    }

    // =========================================================================
    // Outbound — MultisigProxy-only OFT send
    // =========================================================================

    /// @inheritdoc IUtexoLZAdapter
    function sendOut(
        uint32  dstEid,
        bytes32 recipient,
        uint256 amount,
        uint256 minAmountLD,
        bytes   calldata extraOptions
    )
        external
        payable
        override
        nonReentrant
        returns (bytes32 guid)
    {
        if (msg.sender != multisigProxy) revert NotMultisigProxy();
        if (amount     == 0)             revert ZeroAmount();
        if (recipient  == bytes32(0))    revert InvalidRecipient();

        // 1. Build the LayerZero send parameters. `composeMsg` is empty — we are
        //    delivering plain USDT0 to the user, not invoking any compose hook on
        //    the destination.
        SendParam memory sp = SendParam({
            dstEid:       dstEid,
            to:           recipient,
            amountLD:     amount,
            minAmountLD:  minAmountLD,
            extraOptions: extraOptions,
            composeMsg:   '',
            oftCmd:       ''
        });

        // 2. Re-quote on-chain — defends against the off-chain quote going stale
        //    between TEE signing and MultisigProxy.executeBatch inclusion.
        MessagingFee memory fee = IOFT(oft).quoteSend(sp, false);
        if (msg.value < fee.nativeFee) {
            revert InsufficientNativeFee({ provided: msg.value, required: fee.nativeFee });
        }

        // 3. Approve OFT to pull the USDT0 we received from Bridge.fundsOut.
        IERC20(token).safeIncreaseAllowance(oft, amount);

        // 4. Forward exactly `fee.nativeFee` to the OFT. Refund handled below.
        (MessagingReceipt memory receipt, ) = IOFT(oft).send{ value: fee.nativeFee }(
            sp,
            fee,
            multisigProxy /* refundAddress — defensive only; OFT consumes the full fee */
        );
        guid = receipt.guid;

        // 5. Refund native surplus back to MultisigProxy's float.
        uint256 excess = msg.value - fee.nativeFee;
        if (excess != 0) {
            (bool ok, ) = multisigProxy.call{ value: excess }('');
            if (!ok) revert NativeRefundFailed();
        }

        emit SendOut(guid, dstEid, recipient, amount);
    }

    /// @inheritdoc IUtexoLZAdapter
    function quoteSendOut(
        uint32  dstEid,
        bytes32 recipient,
        uint256 amount,
        uint256 minAmountLD,
        bytes   calldata extraOptions
    )
        external
        view
        override
        returns (uint256 nativeFee)
    {
        SendParam memory sp = SendParam({
            dstEid:       dstEid,
            to:           recipient,
            amountLD:     amount,
            minAmountLD:  minAmountLD,
            extraOptions: extraOptions,
            composeMsg:   '',
            oftCmd:       ''
        });
        return IOFT(oft).quoteSend(sp, false).nativeFee;
    }
}

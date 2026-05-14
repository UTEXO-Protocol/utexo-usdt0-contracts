// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { IERC20 }    from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import { SafeERC20 } from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import { ReentrancyGuard } from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';

import { IOAppComposer }      from '@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/interfaces/IOAppComposer.sol';
import { ILayerZeroComposer } from '@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol';
import { OFTComposeMsgCodec } from '@layerzerolabs/lz-evm-oapp-v2/contracts/oft/libs/OFTComposeMsgCodec.sol';

import { IOFT, SendParam }                  from '@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol';
import { MessagingFee, MessagingReceipt }   from '@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol';

import { IUtexoLZAdapter } from './interfaces/IUtexoLZAdapter.sol';
import { IBridge }         from '@utexo-smart-contracts/interfaces/IBridge.sol';

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
///      │                  ├─► validate composeFrom ∈ trustedEntrypoints           │
///      │                  ├─► decode amountLD + business payload                  │
///      │                  ├─► approve Bridge for amountLD                         │
///      │                  ├─► try Bridge.fundsIn{value: msg.value}                │
///      │                  │     • on success: emit ComposeFundsIn                 │
///      │                  │     • on revert : park funds in _stuckFunds[guid],    │
///      │                  │                   emit ComposeFundsInFailed,          │
///      │                  │                   return ok (frees the LZ queue)     │
///      │                  └─► release via refundStuckFunds (federation only)      │
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
    // Storage
    // =========================================================================

    /// @notice Trusted source-chain entrypoint set. `lzCompose` accepts a
    ///         call only if `OFTComposeMsgCodec.composeFrom(_message)` is
    ///         flagged here. Maintained by federation governance via
    ///         `setTrustedEntrypoint` (callable only by `multisigProxy`).
    ///
    ///         Keyed by `bytes32` so the same registry works for EVM (address
    ///         left-padded) and non-EVM source chains (full 32-byte address).
    mapping(bytes32 entrypoint => bool trusted) public override trustedEntrypoints;

    /// @dev Records of inbound compose payloads whose `Bridge.fundsIn` call
    ///      reverted. Keyed by LayerZero compose guid (unique per packet).
    mapping(bytes32 guid => StuckFunds) internal _stuckFunds;

    // =========================================================================
    // Modifiers
    // =========================================================================

    /// @dev Restricts a function to `multisigProxy`. The proxy itself gates
    ///      each call behind federation governance (M-of-N + timelock), so a
    ///      function carrying this modifier is effectively a federation-only
    ///      administrative entrypoint.
    modifier onlyMultisigProxy() {
        if (msg.sender != multisigProxy) revert NotMultisigProxy();
        _;
    }

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
    ///      This call decodes the compose payload and forwards it into
    ///      `Bridge.fundsIn`. If the forwarded call reverts the payload is
    ///      captured under `_stuckFunds[_guid]` and an `ComposeFundsInFailed`
    ///      event is emitted — `lzCompose` itself returns successfully so the
    ///      LayerZero endpoint clears its compose queue and stops retrying.
    ///      The parked funds can later be released to a federation-approved
    ///      recipient via `refundStuckFunds`.
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

        // 1. Reject any call whose source-chain `OFT.send` caller is not a
        //    trusted entrypoint.
        bytes32 composeFrom_ = OFTComposeMsgCodec.composeFrom(_message);
        if (!trustedEntrypoints[composeFrom_]) {
            revert UntrustedComposeSource(composeFrom_);
        }

        // 2. Decode the LayerZero compose data.
        uint256 amountLD     = OFTComposeMsgCodec.amountLD(_message);
        bytes memory payload = OFTComposeMsgCodec.composeMsg(_message);

        // 3. Decode the business payload. `sourceChainId` is the EVM chain id
        //    captured by `UtexoSourceEntrypoint` from `block.chainid` at deposit
        //    time — non-spoofable.
        (
            uint256 sourceChainId,
            uint256 destinationChainId,
            string memory destinationAddress,
            uint256 operationId
        ) = abi.decode(payload, (uint256, uint256, string, uint256));

        // 4. Approve Bridge to pull the USDT0 we just received via lzReceive.
        IERC20(token).safeIncreaseAllowance(bridge, amountLD);

        // 5. Forward the call. `msg.value` here is the value the LayerZero
        //    Executor forwarded into this lzCompose, sized off-chain by the
        //    backend to match the route's NATIVE commission (or 0 for
        //    TOKEN-currency routes). Calls the adapter-only `fundsIn` overload
        //    (5-arg, `onlyLZAdapter`-gated) so the non-spoofable
        //    `sourceChainId` reaches commission routing. If Bridge rejects the
        //    call (paused, duplicate operationId, native-value mismatch, …) the
        //    funds are parked in `_stuckFunds[_guid]` and recoverable off the
        //    hot path.
        try IBridge(bridge).fundsIn{ value: msg.value }(
            amountLD,
            sourceChainId,
            destinationChainId,
            destinationAddress,
            operationId
        ) {
            emit ComposeFundsIn(
                _guid, sourceChainId, amountLD,
                destinationChainId, destinationAddress, operationId
            );
        } catch (bytes memory reason) {
            // Bridge did not pull the approved allowance — reset it so the
            // unconsumed approval cannot accumulate across repeated failures.
            IERC20(token).forceApprove(bridge, 0);

            _stuckFunds[_guid] = StuckFunds({
                amountLD:           amountLD,
                nativeValue:        msg.value,
                operationId:        operationId,
                sourceChainId:      sourceChainId,
                destinationChainId: destinationChainId,
                destinationAddress: destinationAddress
            });

            emit ComposeFundsInFailed(
                _guid, sourceChainId, amountLD, msg.value,
                destinationChainId, destinationAddress, operationId, reason
            );
        }
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
        onlyMultisigProxy
        nonReentrant
    {
        if (amount    == 0)          revert ZeroAmount();
        if (recipient == bytes32(0)) revert InvalidRecipient();

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
            tx.origin /* refundAddress — defensive only; OFT consumes the full fee */
        );

        // 5. Refund native surplus to `tx.origin` — the relayer EOA that
        //    submitted `MultisigProxy.executeBatch`.
        uint256 excess = msg.value - fee.nativeFee;
        if (excess != 0) {
            (bool ok, ) = tx.origin.call{ value: excess }('');
            if (!ok) revert NativeRefundFailed();
        }

        emit SendOut(receipt.guid, dstEid, recipient, amount);
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

    // =========================================================================
    // Stuck-funds recovery
    // =========================================================================

    /// @inheritdoc IUtexoLZAdapter
    function getStuckFunds(bytes32 guid) external view override returns (StuckFunds memory) {
        return _stuckFunds[guid];
    }

    /// @inheritdoc IUtexoLZAdapter
    /// @dev Federation governance entrypoint: `MultisigProxy` is the only
    ///      caller. The proxy itself gates this on the M-of-N federation
    ///      timelock (see its `proposeAdminExecute*` flow). Off-chain the
    ///      backend reimburses the original user from `recipient`.
    function refundStuckFunds(bytes32 guid, address recipient)
        external
        override
        onlyMultisigProxy
        nonReentrant
    {
        if (recipient == address(0)) revert InvalidRecipient();

        StuckFunds memory record = _stuckFunds[guid];
        if (record.amountLD == 0) revert NoStuckFunds(guid);

        delete _stuckFunds[guid];

        // Token leg. SafeERC20 reverts on failure, the whole call rolls back.
        IERC20(token).safeTransfer(recipient, record.amountLD);

        // Native leg, if any. A revert here also rolls back the token transfer
        // and the delete — the record stays recoverable.
        if (record.nativeValue != 0) {
            (bool ok, ) = recipient.call{ value: record.nativeValue }('');
            if (!ok) revert NativeRefundFailed();
        }

        emit StuckFundsRefunded(guid, recipient, record.amountLD, record.nativeValue);
    }

    // =========================================================================
    // Trusted entrypoint registry
    // =========================================================================

    /// @inheritdoc IUtexoLZAdapter
    /// @dev Federation governance entrypoint: `MultisigProxy` is the only
    ///      caller. The proxy gates this on its M-of-N timelock flow, so
    ///      mutating the trusted set is a deliberate federation decision —
    ///      e.g. adding a freshly deployed source-chain entrypoint, rotating
    ///      an entrypoint after redeploy, or revoking a compromised one.
    function setTrustedEntrypoint(bytes32 entrypoint, bool trusted)
        external
        override
        onlyMultisigProxy
    {
        if (entrypoint == bytes32(0)) revert InvalidEntrypoint();

        trustedEntrypoints[entrypoint] = trusted;
        emit TrustedEntrypointSet(entrypoint, trusted);
    }
}

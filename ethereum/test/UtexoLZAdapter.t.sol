// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { Test } from 'forge-std/Test.sol';

import { OFTComposeMsgCodec } from '@layerzerolabs/lz-evm-oapp-v2/contracts/oft/libs/OFTComposeMsgCodec.sol';

import { UtexoLZAdapter }  from '../src/UtexoLZAdapter.sol';
import { IUtexoLZAdapter } from '../src/interfaces/IUtexoLZAdapter.sol';

import { MockERC20 }  from './mocks/MockERC20.sol';
import { MockOFT }    from './mocks/MockOFT.sol';
import { MockBridge } from './mocks/MockBridge.sol';

/// @title UtexoLZAdapterTest
/// @notice Verifies the inbound (`lzCompose` → `Bridge.fundsIn`) and outbound
///         (`sendOut` → `OFT.send`) flows of `UtexoLZAdapter`, plus access
///         control, native-fee handling, surplus refunds and refund failures.
contract UtexoLZAdapterTest is Test {
    // -- Events (re-declared for vm.expectEmit) -------------------------------
    event ComposeFundsIn(
        bytes32 indexed guid,
        uint256 sourceChainId,
        uint256 amountLD,
        uint256 destinationChainId,
        string  destinationAddress,
        uint256 operationId
    );

    event SendOut(
        bytes32 indexed guid,
        uint32  dstEid,
        bytes32 recipient,
        uint256 amountLD
    );

    event ComposeFundsInFailed(
        bytes32 indexed guid,
        uint256 sourceChainId,
        uint256 amountLD,
        uint256 nativeValue,
        uint256 destinationChainId,
        string  destinationAddress,
        uint256 operationId,
        bytes   reason
    );

    event StuckFundsRefunded(
        bytes32 indexed guid,
        address indexed recipient,
        uint256 amountLD,
        uint256 nativeValue
    );

    event TrustedEntrypointSet(bytes32 indexed entrypoint, bool trusted);

    // -- Constants ------------------------------------------------------------
    uint32  constant SRC_EID         = 30101;     // LZ endpoint id of the inbound packet
    uint32  constant DST_EID         = 30110;     // Arbitrum eid (outbound stub)
    uint256 constant SOURCE_CHAIN_ID = 1;         // Default `block.chainid` carried by composeMsg
    uint256 constant RGB_CHAIN_ID    = 1_000_001; // Reserved-range id for RGB (non-EVM endpoint)
    uint256 constant NATIVE_FEE      = 0.01 ether;

    /// @dev Recognisable bytes32 used as `composeFrom` for every "honest" lzCompose
    ///      test — populated into `trustedEntrypoints` during `setUp`.
    bytes32 constant TRUSTED_ENTRYPOINT_B32 = bytes32(uint256(0xE471) << 240);

    // -- Actors ---------------------------------------------------------------
    address endpoint      = makeAddr('endpoint');
    address multisigProxy = makeAddr('multisigProxy');
    address relayer       = makeAddr('relayer');
    address recipientEoa  = makeAddr('recipient');
    bytes32 recipientB32  = bytes32(uint256(uint160(makeAddr('recipient'))));

    // -- SUT ------------------------------------------------------------------
    MockERC20      token;
    MockOFT        oft;
    MockBridge     bridge;
    UtexoLZAdapter adapter;

    function setUp() public {
        token  = new MockERC20('USDT', 'USDT');
        oft    = new MockOFT(address(token));
        bridge = new MockBridge(address(token));
        oft.setNativeFee(NATIVE_FEE);

        adapter = new UtexoLZAdapter(
            endpoint,
            address(oft),
            address(token),
            address(bridge),
            multisigProxy
        );

        vm.deal(endpoint,      100 ether);
        vm.deal(multisigProxy, 100 ether);

        // Whitelist the entrypoint used by every "honest" inbound test.
        vm.prank(multisigProxy);
        adapter.setTrustedEntrypoint(TRUSTED_ENTRYPOINT_B32, true);
    }

    // =========================================================================
    // Construction
    // =========================================================================

    function test_constructor_setsImmutables() public view {
        assertEq(adapter.endpoint(),      endpoint,        'endpoint');
        assertEq(adapter.oft(),           address(oft),    'oft');
        assertEq(adapter.token(),         address(token),  'token');
        assertEq(adapter.bridge(),        address(bridge), 'bridge');
        assertEq(adapter.multisigProxy(), multisigProxy,   'multisigProxy');
    }

    function test_constructor_revertsOnZeroEndpoint() public {
        vm.expectRevert(IUtexoLZAdapter.InvalidEndpoint.selector);
        new UtexoLZAdapter(address(0), address(oft), address(token), address(bridge), multisigProxy);
    }

    function test_constructor_revertsOnZeroOft() public {
        vm.expectRevert(IUtexoLZAdapter.InvalidOft.selector);
        new UtexoLZAdapter(endpoint, address(0), address(token), address(bridge), multisigProxy);
    }

    function test_constructor_revertsOnZeroToken() public {
        vm.expectRevert(IUtexoLZAdapter.InvalidToken.selector);
        new UtexoLZAdapter(endpoint, address(oft), address(0), address(bridge), multisigProxy);
    }

    function test_constructor_revertsOnZeroBridge() public {
        vm.expectRevert(IUtexoLZAdapter.InvalidBridge.selector);
        new UtexoLZAdapter(endpoint, address(oft), address(token), address(0), multisigProxy);
    }

    function test_constructor_revertsOnZeroMultisigProxy() public {
        vm.expectRevert(IUtexoLZAdapter.InvalidMultisigProxy.selector);
        new UtexoLZAdapter(endpoint, address(oft), address(token), address(bridge), address(0));
    }

    // =========================================================================
    // lzCompose — inbound (FundsIn) happy paths
    // =========================================================================

    function test_lzCompose_happyPath_forwardsToBridge() public {
        uint256 amount = 500e6;
        token.mint(address(adapter), amount);

        uint256 destChainId = RGB_CHAIN_ID;
        string  memory destAddr = 'tb1q-dest-addr';
        uint256 opId            = 42;

        bytes memory message = _encodeCompose(
            uint64(7),
            SRC_EID,
            amount,
            TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, destChainId, destAddr, opId)
        );

        bytes32 guid = keccak256('inbound-guid');

        vm.expectEmit(true, false, false, true, address(adapter));
        emit ComposeFundsIn(guid, SOURCE_CHAIN_ID, amount, destChainId, destAddr, opId);

        vm.prank(endpoint);
        adapter.lzCompose{ value: 0.005 ether }(
            address(oft),
            guid,
            message,
            address(0),
            ''
        );

        // Bridge received the tokens, the value, and the args byte-for-byte.
        assertEq(token.balanceOf(address(bridge)),    amount,           'bridge holds tokens');
        assertEq(token.balanceOf(address(adapter)),   0,                'adapter cleared of tokens');
        assertEq(bridge.lastAmount(),                 amount,           'amount forwarded');
        assertEq(bridge.lastSourceChainId(),          SOURCE_CHAIN_ID,  'sourceChainId forwarded');
        assertEq(bridge.lastDestinationChainId(),     destChainId,      'destChainId forwarded');
        assertEq(bridge.lastDestinationAddress(),     destAddr,         'destAddr forwarded');
        assertEq(bridge.lastOperationId(),            opId,             'opId forwarded');
        assertEq(bridge.lastMsgValue(),               0.005 ether,      'msg.value forwarded');
        assertEq(bridge.lastCaller(),                 address(adapter), 'caller is adapter');

        // Allowance fully consumed.
        assertEq(token.allowance(address(adapter), address(bridge)), 0, 'allowance consumed');
    }

    function test_lzCompose_zeroNativeValue_okForTokenRoutes() public {
        // TOKEN-currency routes pass msg.value == 0. Adapter must still forward.
        uint256 amount = 100e6;
        token.mint(address(adapter), amount);

        bytes memory message = _encodeCompose(
            uint64(1),
            SRC_EID,
            amount,
            TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, string('rgb'), string('addr'), uint256(1))
        );

        vm.prank(endpoint);
        adapter.lzCompose{ value: 0 }(address(oft), bytes32(0), message, address(0), '');

        assertEq(bridge.lastMsgValue(), 0, 'zero value forwarded');
        assertEq(token.balanceOf(address(bridge)), amount, 'bridge holds tokens');
    }

    /// @dev `sourceChainId` is read from the business payload (set by
    ///      `UtexoSourceEntrypoint` from `block.chainid` on the source side)
    ///      and surfaced both via the event and via the forwarded
    ///      `Bridge.fundsIn` call.
    function test_lzCompose_emitsSourceChainIdFromPayload() public {
        uint256 customChainId = 137; // pretend the deposit came from Polygon
        uint256 amount        = 7e6;
        token.mint(address(adapter), amount);

        bytes memory message = _encodeCompose(
            uint64(99),
            SRC_EID,
            amount,
            TRUSTED_ENTRYPOINT_B32,
            abi.encode(customChainId, RGB_CHAIN_ID, string('b'), uint256(0))
        );

        vm.expectEmit(true, false, false, true, address(adapter));
        emit ComposeFundsIn(bytes32('g'), customChainId, amount, RGB_CHAIN_ID, 'b', 0);

        vm.prank(endpoint);
        adapter.lzCompose(address(oft), bytes32('g'), message, address(0), '');

        assertEq(bridge.lastSourceChainId(), customChainId, 'sourceChainId forwarded to Bridge');
    }

    // =========================================================================
    // lzCompose — access control & failure paths
    // =========================================================================

    function test_lzCompose_revertsIfNotEndpoint() public {
        bytes memory message = _encodeCompose(
            uint64(1), SRC_EID, 1e6, TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, RGB_CHAIN_ID, string('b'), uint256(0))
        );

        vm.prank(makeAddr('attacker'));
        vm.expectRevert(IUtexoLZAdapter.NotEndpoint.selector);
        adapter.lzCompose(address(oft), bytes32(0), message, address(0), '');
    }

    function test_lzCompose_revertsIfFromIsNotOft() public {
        bytes memory message = _encodeCompose(
            uint64(1), SRC_EID, 1e6, TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, RGB_CHAIN_ID, string('b'), uint256(0))
        );

        vm.prank(endpoint);
        vm.expectRevert(IUtexoLZAdapter.NotFromOft.selector);
        adapter.lzCompose(makeAddr('not-oft'), bytes32(0), message, address(0), '');
    }

    /// @dev Bridge.fundsIn revert no longer makes `lzCompose` revert — instead
    ///      the funds are parked under `_stuckFunds[guid]` and a failure event
    ///      is emitted. `lzCompose` itself returns successfully so the LZ
    ///      endpoint clears its compose queue.
    function test_lzCompose_storesStuckRecordIfBridgeReverts() public {
        bridge.setReverts(true);

        uint256 amount      = 1e6;
        uint256 nativeValue = 0.005 ether;
        token.mint(address(adapter), amount);

        uint256 destChainId = RGB_CHAIN_ID;
        string  memory destAddr = 'tb1q-stuck';
        uint256 opId            = 99;

        bytes memory message = _encodeCompose(
            uint64(1), SRC_EID, amount, TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, destChainId, destAddr, opId)
        );

        bytes32 guid = bytes32('stuck-guid');

        // Reason data is the abi-encoded `Error(string)` for the mock's
        // revert message — assert the indexed guid and the non-indexed
        // scalar/string fields, ignore `reason` byte-for-byte.
        vm.expectEmit(true, false, false, false, address(adapter));
        emit ComposeFundsInFailed(
            guid, SOURCE_CHAIN_ID, amount, nativeValue, destChainId, destAddr, opId, ''
        );

        vm.prank(endpoint);
        adapter.lzCompose{ value: nativeValue }(
            address(oft), guid, message, address(0), ''
        );

        // Funds did NOT leave the adapter — Bridge rejected the call.
        assertEq(token.balanceOf(address(bridge)),  0,      'bridge unchanged');
        assertEq(token.balanceOf(address(adapter)), amount, 'adapter still holds tokens');
        assertEq(address(adapter).balance,          nativeValue, 'adapter holds native');

        // Allowance from the failed attempt was reset to 0 so it does not
        // accumulate across compose calls with different guids.
        assertEq(token.allowance(address(adapter), address(bridge)), 0, 'allowance reset');

        // Stuck record captured every field needed to drive a later refund.
        IUtexoLZAdapter.StuckFunds memory rec = adapter.getStuckFunds(guid);
        assertEq(rec.amountLD,            amount,          'stuck amountLD');
        assertEq(rec.nativeValue,         nativeValue,     'stuck nativeValue');
        assertEq(rec.operationId,         opId,            'stuck opId');
        assertEq(rec.sourceChainId,       SOURCE_CHAIN_ID, 'stuck sourceChainId');
        assertEq(rec.destinationChainId,  destChainId,     'stuck destChainId');
        assertEq(rec.destinationAddress,  destAddr,        'stuck destAddr');
    }

    function test_lzCompose_happyPath_doesNotCreateStuckRecord() public {
        uint256 amount = 250e6;
        token.mint(address(adapter), amount);

        bytes32 guid = bytes32('happy-guid');
        bytes memory message = _encodeCompose(
            uint64(1), SRC_EID, amount, TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, RGB_CHAIN_ID, string('addr'), uint256(7))
        );

        vm.prank(endpoint);
        adapter.lzCompose(address(oft), guid, message, address(0), '');

        IUtexoLZAdapter.StuckFunds memory rec = adapter.getStuckFunds(guid);
        assertEq(rec.amountLD,    0, 'no record on success');
        assertEq(rec.nativeValue, 0, 'no record on success');
    }

    // =========================================================================
    // sendOut — outbound (FundsOut) happy paths
    // =========================================================================

    function test_sendOut_happyPath_forwardsToOft() public {
        uint256 amount = 1_000e6;
        token.mint(address(adapter), amount);

        bytes memory extraOptions = hex'0003010011010000000000000000000000000000ea60';

        uint256 proxyBalBefore = multisigProxy.balance;

        vm.expectEmit(true, false, false, true, address(adapter));
        emit SendOut(
            keccak256(abi.encode('mock-guid', uint64(1))),
            DST_EID,
            recipientB32,
            amount
        );

        // `vm.prank(msgSender, txOrigin)` sets both — the adapter refunds
        // the native surplus to `tx.origin` (= the relayer EOA in production).
        // The MockOFT-generated guid is asserted via the `SendOut` event above;
        // the function intentionally returns nothing.
        vm.prank(multisigProxy, relayer);
        adapter.sendOut{ value: NATIVE_FEE }(
            DST_EID, recipientB32, amount, amount, extraOptions
        );

        // OFT received the tokens and the routing parameters byte-for-byte.
        assertEq(token.balanceOf(address(oft)),      amount,        'oft holds tokens');
        assertEq(token.balanceOf(address(adapter)),  0,             'adapter cleared');
        assertEq(uint256(oft.lastDstEid()),          DST_EID,       'dstEid forwarded');
        assertEq(oft.lastTo(),                       recipientB32,  'to forwarded');
        assertEq(oft.lastAmountLD(),                 amount,        'amount forwarded');
        assertEq(oft.lastMinAmountLD(),              amount,        'minAmount forwarded');
        assertEq(oft.lastExtraOptions(),             extraOptions,  'extraOptions forwarded');
        assertEq(oft.lastComposeMsg().length,        0,             'composeMsg empty');
        assertEq(oft.lastOftCmd().length,            0,             'oftCmd empty');
        assertEq(oft.lastMsgValue(),                 NATIVE_FEE,    'native fee forwarded');
        // OFT.send is called with refundAddress = tx.origin, which equals the
        // relayer EOA in production. Defensive only — OFT consumes the full fee.
        assertEq(oft.lastRefundAddress(),            relayer,       'refund addr = tx.origin');

        // Exact-fee call: proxy balance drops by exactly NATIVE_FEE.
        assertEq(multisigProxy.balance, proxyBalBefore - NATIVE_FEE, 'no surplus expected');

        // Adapter holds nothing afterward.
        assertEq(token.allowance(address(adapter), address(oft)), 0, 'oft allowance consumed');
        assertEq(address(adapter).balance, 0, 'no native residue');
    }

    function test_sendOut_surplusNativeRefundedToTxOrigin() public {
        uint256 amount  = 250e6;
        uint256 surplus = 0.05 ether;
        token.mint(address(adapter), amount);

        uint256 proxyBalBefore   = multisigProxy.balance;
        uint256 relayerBalBefore = relayer.balance;

        // tx.origin = relayer → surplus is refunded to relayer.
        vm.prank(multisigProxy, relayer);
        adapter.sendOut{ value: NATIVE_FEE + surplus }(
            DST_EID, recipientB32, amount, amount, hex'0003'
        );

        // Proxy paid the full msg.value (fee + surplus).
        assertEq(
            multisigProxy.balance,
            proxyBalBefore - NATIVE_FEE - surplus,
            'proxy paid fee + surplus'
        );
        // Relayer received exactly the surplus as refund from the adapter.
        assertEq(relayer.balance, relayerBalBefore + surplus, 'surplus refunded to tx.origin');
        assertEq(address(adapter).balance, 0, 'no native residue');
    }

    /// @dev `sendOut` no longer returns the guid — it is published only via
    ///      the `SendOut` event. Assert that each successive call emits a
    ///      distinct, MockOFT-derived guid.
    function test_sendOut_emitsUniqueGuidPerCall() public {
        token.mint(address(adapter), 100e6);

        vm.expectEmit(true, false, false, true, address(adapter));
        emit SendOut(keccak256(abi.encode('mock-guid', uint64(1))), DST_EID, recipientB32, 50e6);

        vm.prank(multisigProxy, relayer);
        adapter.sendOut{ value: NATIVE_FEE }(
            DST_EID, recipientB32, 50e6, 50e6, hex'0003'
        );

        token.mint(address(adapter), 100e6);

        vm.expectEmit(true, false, false, true, address(adapter));
        emit SendOut(keccak256(abi.encode('mock-guid', uint64(2))), DST_EID, recipientB32, 50e6);

        vm.prank(multisigProxy, relayer);
        adapter.sendOut{ value: NATIVE_FEE }(
            DST_EID, recipientB32, 50e6, 50e6, hex'0003'
        );
    }

    // =========================================================================
    // sendOut — access control & input validation
    // =========================================================================

    function test_sendOut_revertsIfNotMultisigProxy() public {
        token.mint(address(adapter), 100e6);

        address attacker = makeAddr('attacker');
        vm.deal(attacker, 1 ether);

        vm.prank(attacker);
        vm.expectRevert(IUtexoLZAdapter.NotMultisigProxy.selector);
        adapter.sendOut{ value: NATIVE_FEE }(
            DST_EID, recipientB32, 100e6, 100e6, hex'0003'
        );
    }

    function test_sendOut_revertsOnZeroAmount() public {
        vm.prank(multisigProxy, relayer);
        vm.expectRevert(IUtexoLZAdapter.ZeroAmount.selector);
        adapter.sendOut{ value: NATIVE_FEE }(
            DST_EID, recipientB32, 0, 0, hex'0003'
        );
    }

    function test_sendOut_revertsOnZeroRecipient() public {
        vm.prank(multisigProxy, relayer);
        vm.expectRevert(IUtexoLZAdapter.InvalidRecipient.selector);
        adapter.sendOut{ value: NATIVE_FEE }(
            DST_EID, bytes32(0), 100e6, 100e6, hex'0003'
        );
    }

    function test_sendOut_revertsOnInsufficientNativeFee() public {
        token.mint(address(adapter), 100e6);

        vm.prank(multisigProxy, relayer);
        vm.expectRevert(abi.encodeWithSelector(
            IUtexoLZAdapter.InsufficientNativeFee.selector,
            NATIVE_FEE - 1,
            NATIVE_FEE
        ));
        adapter.sendOut{ value: NATIVE_FEE - 1 }(
            DST_EID, recipientB32, 100e6, 100e6, hex'0003'
        );
    }

    function test_sendOut_revertsIfOftReverts() public {
        oft.setSendReverts(true);
        token.mint(address(adapter), 100e6);

        vm.prank(multisigProxy, relayer);
        vm.expectRevert(bytes('MockOFT: forced revert'));
        adapter.sendOut{ value: NATIVE_FEE }(
            DST_EID, recipientB32, 100e6, 100e6, hex'0003'
        );
    }

    /// @dev Refund failure path: `tx.origin` is spoofed to a contract that
    ///      rejects plain-ether transfers (no `receive()`). Cannot happen in
    ///      production where `tx.origin` is always the backend relayer EOA,
    ///      but the branch is reachable on-chain so the revert must surface.
    function test_sendOut_revertsIfRefundFails() public {
        RejectingRecipient rr = new RejectingRecipient();

        uint256 amount = 100e6;
        token.mint(address(adapter), amount);

        vm.prank(multisigProxy, address(rr));
        vm.expectRevert(IUtexoLZAdapter.NativeRefundFailed.selector);
        adapter.sendOut{ value: NATIVE_FEE + 1 }(
            DST_EID, recipientB32, amount, amount, hex'0003'
        );
    }

    /// @dev Exact-fee call skips the refund branch entirely, so even a
    ///      `tx.origin` that rejects ETH does not block the call.
    function test_sendOut_exactFee_skipsRefundBranch() public {
        RejectingRecipient rr = new RejectingRecipient();

        uint256 amount = 100e6;
        token.mint(address(adapter), amount);

        vm.prank(multisigProxy, address(rr));
        adapter.sendOut{ value: NATIVE_FEE }(
            DST_EID, recipientB32, amount, amount, hex'0003'
        );

        assertEq(token.balanceOf(address(oft)), amount, 'tokens forwarded');
    }

    // =========================================================================
    // quoteSendOut
    // =========================================================================

    function test_quoteSendOut_matchesOft() public {
        oft.setNativeFee(0.0042 ether);
        uint256 fee = adapter.quoteSendOut(
            DST_EID, recipientB32, 1e6, 1e6, hex'0003'
        );
        assertEq(fee, 0.0042 ether, 'quote matches oft');
    }

    // =========================================================================
    // Stuck-funds — getStuckFunds + refundStuckFunds
    // =========================================================================

    function test_getStuckFunds_returnsZeroForUnknownGuid() public view {
        IUtexoLZAdapter.StuckFunds memory rec = adapter.getStuckFunds(bytes32('unknown'));
        assertEq(rec.amountLD,            0,  'amountLD');
        assertEq(rec.nativeValue,         0,  'nativeValue');
        assertEq(rec.operationId,         0,  'operationId');
        assertEq(rec.sourceChainId,       0,  'sourceChainId');
        assertEq(rec.destinationChainId,  0,  'destinationChainId');
        assertEq(rec.destinationAddress,  '', 'destinationAddress');
    }

    function test_refundStuckFunds_happyPath_tokenAndNative() public {
        uint256 amount      = 1_500e6;
        uint256 nativeValue = 0.02 ether;
        bytes32 guid        = bytes32('to-refund');

        _createStuckRecord(guid, amount, nativeValue, RGB_CHAIN_ID, 'tb1q-bad', 13);

        address payable refundTo = payable(makeAddr('refundTo'));
        uint256 tokenBalBefore   = token.balanceOf(refundTo);
        uint256 nativeBalBefore  = refundTo.balance;

        vm.expectEmit(true, true, false, true, address(adapter));
        emit StuckFundsRefunded(guid, refundTo, amount, nativeValue);

        vm.prank(multisigProxy);
        adapter.refundStuckFunds(guid, refundTo);

        // Funds left the adapter and landed on the recipient.
        assertEq(token.balanceOf(refundTo),         tokenBalBefore + amount,      'tokens transferred');
        assertEq(refundTo.balance,                  nativeBalBefore + nativeValue, 'native transferred');
        assertEq(token.balanceOf(address(adapter)), 0,                            'adapter cleared of tokens');
        assertEq(address(adapter).balance,          0,                            'adapter cleared of native');

        // Record is gone.
        IUtexoLZAdapter.StuckFunds memory rec = adapter.getStuckFunds(guid);
        assertEq(rec.amountLD, 0, 'record deleted');
    }

    function test_refundStuckFunds_tokenOnlyWhenNativeValueIsZero() public {
        uint256 amount = 800e6;
        bytes32 guid   = bytes32('token-only');

        _createStuckRecord(guid, amount, 0, RGB_CHAIN_ID, 'addr', 1);

        address refundTo = makeAddr('refundTo');

        vm.prank(multisigProxy);
        adapter.refundStuckFunds(guid, refundTo);

        assertEq(token.balanceOf(refundTo),         amount, 'tokens transferred');
        assertEq(refundTo.balance,                  0,      'no native delivered');
        assertEq(token.balanceOf(address(adapter)), 0,      'adapter cleared');
    }

    function test_refundStuckFunds_revertsIfNotMultisigProxy() public {
        bytes32 guid = bytes32('any');
        _createStuckRecord(guid, 1e6, 0, RGB_CHAIN_ID, 'addr', 1);

        address attacker = makeAddr('attacker');
        vm.prank(attacker);
        vm.expectRevert(IUtexoLZAdapter.NotMultisigProxy.selector);
        adapter.refundStuckFunds(guid, attacker);
    }

    function test_refundStuckFunds_revertsOnZeroRecipient() public {
        bytes32 guid = bytes32('any');
        _createStuckRecord(guid, 1e6, 0, RGB_CHAIN_ID, 'addr', 1);

        vm.prank(multisigProxy);
        vm.expectRevert(IUtexoLZAdapter.InvalidRecipient.selector);
        adapter.refundStuckFunds(guid, address(0));
    }

    function test_refundStuckFunds_revertsIfNoStuckFunds() public {
        bytes32 unknown = bytes32('unknown');
        vm.prank(multisigProxy);
        vm.expectRevert(abi.encodeWithSelector(
            IUtexoLZAdapter.NoStuckFunds.selector, unknown
        ));
        adapter.refundStuckFunds(unknown, makeAddr('any'));
    }

    /// @dev Refund must atomically roll back if the native leg fails, so the
    ///      record stays recoverable on the next attempt.
    function test_refundStuckFunds_revertsAndPreservesRecordIfNativeRefundFails() public {
        uint256 amount      = 100e6;
        uint256 nativeValue = 0.01 ether;
        bytes32 guid        = bytes32('native-fail');

        _createStuckRecord(guid, amount, nativeValue, RGB_CHAIN_ID, 'addr', 1);

        RejectingRecipient rr = new RejectingRecipient();

        vm.prank(multisigProxy);
        vm.expectRevert(IUtexoLZAdapter.NativeRefundFailed.selector);
        adapter.refundStuckFunds(guid, address(rr));

        // Record + adapter balances preserved by the revert rollback.
        IUtexoLZAdapter.StuckFunds memory rec = adapter.getStuckFunds(guid);
        assertEq(rec.amountLD,    amount,      'record preserved');
        assertEq(rec.nativeValue, nativeValue, 'record preserved');
        assertEq(token.balanceOf(address(adapter)), amount,      'tokens preserved');
        assertEq(address(adapter).balance,          nativeValue, 'native preserved');
    }

    // =========================================================================
    // Trusted entrypoint registry — setTrustedEntrypoint
    // =========================================================================

    function test_setTrustedEntrypoint_setsAndUnsets() public {
        bytes32 ep = bytes32(uint256(0xC0FFEE));

        // Initial state: not trusted.
        assertEq(adapter.trustedEntrypoints(ep), false, 'starts untrusted');

        // Set true.
        vm.expectEmit(true, false, false, true, address(adapter));
        emit TrustedEntrypointSet(ep, true);

        vm.prank(multisigProxy);
        adapter.setTrustedEntrypoint(ep, true);
        assertEq(adapter.trustedEntrypoints(ep), true, 'trusted after set(true)');

        // Set false.
        vm.expectEmit(true, false, false, true, address(adapter));
        emit TrustedEntrypointSet(ep, false);

        vm.prank(multisigProxy);
        adapter.setTrustedEntrypoint(ep, false);
        assertEq(adapter.trustedEntrypoints(ep), false, 'untrusted after set(false)');
    }

    function test_setTrustedEntrypoint_revertsIfNotMultisigProxy() public {
        bytes32 ep = bytes32(uint256(0xC0FFEE));
        address attacker = makeAddr('attacker');

        vm.prank(attacker);
        vm.expectRevert(IUtexoLZAdapter.NotMultisigProxy.selector);
        adapter.setTrustedEntrypoint(ep, true);
    }

    function test_setTrustedEntrypoint_revertsOnZeroEntrypoint() public {
        vm.prank(multisigProxy);
        vm.expectRevert(IUtexoLZAdapter.InvalidEntrypoint.selector);
        adapter.setTrustedEntrypoint(bytes32(0), true);
    }

    // =========================================================================
    // lzCompose — trusted-entrypoint enforcement
    // =========================================================================

    /// @dev Any `composeFrom` outside `trustedEntrypoints` must revert before
    ///      the payload is decoded or any Bridge interaction starts.
    function test_lzCompose_revertsOnUntrustedComposeSource() public {
        bytes32 attackerB32 = bytes32(uint256(0xBADBAD));
        uint256 amount = 1e6;
        token.mint(address(adapter), amount);

        bytes memory message = _encodeCompose(
            uint64(1), SRC_EID, amount, attackerB32,
            abi.encode(SOURCE_CHAIN_ID, string('rgb'), string('a'), uint256(0))
        );

        vm.prank(endpoint);
        vm.expectRevert(abi.encodeWithSelector(
            IUtexoLZAdapter.UntrustedComposeSource.selector, attackerB32
        ));
        adapter.lzCompose(address(oft), bytes32('x'), message, address(0), '');

        // Funds did not move and no stuck record was created — the call
        // reverts entirely, leaving the LZ composeQueue intact.
        assertEq(token.balanceOf(address(bridge)),  0,      'bridge untouched');
        assertEq(token.balanceOf(address(adapter)), amount, 'adapter still holds tokens');

        IUtexoLZAdapter.StuckFunds memory rec = adapter.getStuckFunds(bytes32('x'));
        assertEq(rec.amountLD, 0, 'no stuck record for untrusted source');
    }

    function test_lzCompose_revertsWhenTrustedEntrypointRevoked() public {
        // Revoke the entrypoint that `setUp` whitelisted.
        vm.prank(multisigProxy);
        adapter.setTrustedEntrypoint(TRUSTED_ENTRYPOINT_B32, false);

        bytes memory message = _encodeCompose(
            uint64(1), SRC_EID, 1e6, TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, RGB_CHAIN_ID, string('b'), uint256(0))
        );

        vm.prank(endpoint);
        vm.expectRevert(abi.encodeWithSelector(
            IUtexoLZAdapter.UntrustedComposeSource.selector, TRUSTED_ENTRYPOINT_B32
        ));
        adapter.lzCompose(address(oft), bytes32('y'), message, address(0), '');
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    /// @dev Drive `lzCompose` against a reverting Bridge so a stuck record
    ///      is created for `guid`. `sourceChainId` is set to `SOURCE_CHAIN_ID`.
    function _createStuckRecord(
        bytes32 guid,
        uint256 amount,
        uint256 nativeValue,
        uint256 destChainId,
        string memory destAddr,
        uint256 opId
    ) internal {
        bridge.setReverts(true);
        token.mint(address(adapter), amount);

        bytes memory message = _encodeCompose(
            uint64(0), SRC_EID, amount, TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, destChainId, destAddr, opId)
        );

        vm.prank(endpoint);
        adapter.lzCompose{ value: nativeValue }(
            address(oft), guid, message, address(0), ''
        );
    }

    /// @dev Build the full LayerZero compose-message payload that the Endpoint
    ///      would deliver to `lzCompose`. Layout:
    ///        [nonce (8)][srcEid (4)][amountLD (32)][composeFrom (32)][business]
    function _encodeCompose(
        uint64  nonce_,
        uint32  srcEid_,
        uint256 amountLD_,
        bytes32 composeFrom_,
        bytes memory businessPayload
    ) internal pure returns (bytes memory) {
        return OFTComposeMsgCodec.encode(
            nonce_,
            srcEid_,
            amountLD_,
            abi.encodePacked(composeFrom_, businessPayload)
        );
    }
}

/// @dev Contract that rejects every plain-ether transfer. Used as a spoofed
///      `tx.origin` to force the `NativeRefundFailed` branch in `sendOut`.
///      No `receive()` / `fallback()` is declared, so any value-carrying call
///      reverts.
contract RejectingRecipient {}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { Test } from 'forge-std/Test.sol';

import { OFTComposeMsgCodec } from '@layerzerolabs/lz-evm-oapp-v2/contracts/oft/libs/OFTComposeMsgCodec.sol';

import { UtexoLZAdapter }  from '../src/UtexoLZAdapter.sol';
import { IUtexoLZAdapter } from '../src/interfaces/IUtexoLZAdapter.sol';

import { MockERC20 }  from './helpers/MockERC20.sol';
import { MockOFT }    from './helpers/MockOFT.sol';
import { MockBridge } from './helpers/MockBridge.sol';

/// @title UtexoLZAdapterTest
/// @notice Verifies the inbound (`lzCompose` → `Bridge.fundsIn`) and outbound
///         (`sendOut` → `OFT.send`) flows of `UtexoLZAdapter`, plus access
///         control, native-fee handling, surplus refunds and refund failures.
contract UtexoLZAdapterTest is Test {
    // -- Events (re-declared for vm.expectEmit) -------------------------------
    event ComposeFundsIn(
        bytes32 indexed guid,
        uint32  srcEid,
        uint256 amountLD,
        string  destinationChain,
        string  destinationAddress,
        uint256 operationId
    );

    event SendOut(
        bytes32 indexed guid,
        uint32  dstEid,
        bytes32 recipient,
        uint256 amountLD
    );

    // -- Constants ------------------------------------------------------------
    uint32  constant SRC_EID    = 30101;        // Ethereum mainnet eid (inbound)
    uint32  constant DST_EID    = 30110;        // Arbitrum eid (outbound stub)
    uint256 constant NATIVE_FEE = 0.01 ether;

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

        string  memory destChain = 'rgb';
        string  memory destAddr  = 'tb1q-dest-addr';
        uint256 opId             = 42;

        bytes memory message = _encodeCompose(
            uint64(7),
            SRC_EID,
            amount,
            abi.encode(destChain, destAddr, opId)
        );

        bytes32 guid = keccak256('inbound-guid');

        vm.expectEmit(true, false, false, true, address(adapter));
        emit ComposeFundsIn(guid, SRC_EID, amount, destChain, destAddr, opId);

        vm.prank(endpoint);
        adapter.lzCompose{ value: 0.005 ether }(
            address(oft),
            guid,
            message,
            address(0),
            ''
        );

        // Bridge received the tokens, the value, and the args byte-for-byte.
        assertEq(token.balanceOf(address(bridge)),    amount, 'bridge holds tokens');
        assertEq(token.balanceOf(address(adapter)),   0,      'adapter cleared of tokens');
        assertEq(bridge.lastAmount(),                 amount, 'amount forwarded');
        assertEq(bridge.lastDestinationChain(),       destChain, 'destChain forwarded');
        assertEq(bridge.lastDestinationAddress(),     destAddr,  'destAddr forwarded');
        assertEq(bridge.lastOperationId(),            opId,   'opId forwarded');
        assertEq(bridge.lastMsgValue(),               0.005 ether, 'msg.value forwarded');
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
            abi.encode(string('rgb'), string('addr'), uint256(1))
        );

        vm.prank(endpoint);
        adapter.lzCompose{ value: 0 }(address(oft), bytes32(0), message, address(0), '');

        assertEq(bridge.lastMsgValue(), 0, 'zero value forwarded');
        assertEq(token.balanceOf(address(bridge)), amount, 'bridge holds tokens');
    }

    function test_lzCompose_emitsSrcEidFromMessage() public {
        uint32  encodedSrcEid = 12345;
        uint256 amount        = 7e6;
        token.mint(address(adapter), amount);

        bytes memory message = _encodeCompose(
            uint64(99),
            encodedSrcEid,
            amount,
            abi.encode(string('a'), string('b'), uint256(0))
        );

        vm.expectEmit(true, false, false, true, address(adapter));
        emit ComposeFundsIn(bytes32('g'), encodedSrcEid, amount, 'a', 'b', 0);

        vm.prank(endpoint);
        adapter.lzCompose(address(oft), bytes32('g'), message, address(0), '');
    }

    // =========================================================================
    // lzCompose — access control & failure paths
    // =========================================================================

    function test_lzCompose_revertsIfNotEndpoint() public {
        bytes memory message = _encodeCompose(
            uint64(1), SRC_EID, 1e6,
            abi.encode(string('a'), string('b'), uint256(0))
        );

        vm.prank(makeAddr('attacker'));
        vm.expectRevert(IUtexoLZAdapter.NotEndpoint.selector);
        adapter.lzCompose(address(oft), bytes32(0), message, address(0), '');
    }

    function test_lzCompose_revertsIfFromIsNotOft() public {
        bytes memory message = _encodeCompose(
            uint64(1), SRC_EID, 1e6,
            abi.encode(string('a'), string('b'), uint256(0))
        );

        vm.prank(endpoint);
        vm.expectRevert(IUtexoLZAdapter.NotFromOft.selector);
        adapter.lzCompose(makeAddr('not-oft'), bytes32(0), message, address(0), '');
    }

    function test_lzCompose_revertsIfBridgeReverts() public {
        bridge.setReverts(true);
        uint256 amount = 1e6;
        token.mint(address(adapter), amount);

        bytes memory message = _encodeCompose(
            uint64(1), SRC_EID, amount,
            abi.encode(string('a'), string('b'), uint256(0))
        );

        vm.prank(endpoint);
        vm.expectRevert(bytes('MockBridge: forced revert'));
        adapter.lzCompose(address(oft), bytes32(0), message, address(0), '');
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
        vm.prank(multisigProxy, relayer);
        bytes32 guid = adapter.sendOut{ value: NATIVE_FEE }(
            DST_EID, recipientB32, amount, amount, extraOptions
        );

        // Returned guid matches MockOFT's deterministic counter-based guid.
        assertEq(guid, keccak256(abi.encode('mock-guid', uint64(1))), 'guid');

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

    function test_sendOut_returnsGuidFromOft() public {
        token.mint(address(adapter), 100e6);

        vm.prank(multisigProxy, relayer);
        bytes32 g1 = adapter.sendOut{ value: NATIVE_FEE }(
            DST_EID, recipientB32, 50e6, 50e6, hex'0003'
        );

        token.mint(address(adapter), 100e6);
        vm.prank(multisigProxy, relayer);
        bytes32 g2 = adapter.sendOut{ value: NATIVE_FEE }(
            DST_EID, recipientB32, 50e6, 50e6, hex'0003'
        );

        assertTrue(g1 != g2, 'guids must differ across calls');
        assertEq(g1, keccak256(abi.encode('mock-guid', uint64(1))), 'g1');
        assertEq(g2, keccak256(abi.encode('mock-guid', uint64(2))), 'g2');
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
    // Helpers
    // =========================================================================

    /// @dev Build the full LayerZero compose-message payload that the Endpoint
    ///      would deliver to `lzCompose`. Layout:
    ///        [nonce (8)][srcEid (4)][amountLD (32)][composeFrom (32)][business]
    function _encodeCompose(
        uint64  nonce_,
        uint32  srcEid_,
        uint256 amountLD_,
        bytes memory businessPayload
    ) internal pure returns (bytes memory) {
        return OFTComposeMsgCodec.encode(
            nonce_,
            srcEid_,
            amountLD_,
            abi.encodePacked(bytes32(0), businessPayload)
        );
    }
}

/// @dev Contract that rejects every plain-ether transfer. Used as a spoofed
///      `tx.origin` to force the `NativeRefundFailed` branch in `sendOut`.
///      No `receive()` / `fallback()` is declared, so any value-carrying call
///      reverts.
contract RejectingRecipient {}

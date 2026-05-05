// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { Test } from 'forge-std/Test.sol';

import { UtexoSourceEntrypoint } from '../src/UtexoSourceEntrypoint.sol';
import { IUtexoSourceEntrypoint } from '../src/interfaces/IUtexoSourceEntrypoint.sol';

import { MockERC20 } from './helpers/MockERC20.sol';
import { MockOFT }   from './helpers/MockOFT.sol';

/// @title UtexoSourceEntrypointTest
/// @notice Verifies that `UtexoSourceEntrypoint` forwards deposits into the OFT
///         with immutable destination parameters, enforces the on-chain fee quote,
///         refunds surplus native, and never holds tokens after a call.
contract UtexoSourceEntrypointTest is Test {
    event Deposit(
        bytes32 indexed guid,
        address indexed user,
        uint256 amountLD,
        bytes   composeMsg
    );

    // -- Constants ------------------------------------------------------------
    uint32  constant DST_EID = 30110; // Arbitrum LayerZero eid
    bytes32 constant LZ_ADAPTER = bytes32(uint256(uint160(0xC0d1e0000000000000000000000000000000CAfe)));
    uint256 constant NATIVE_FEE = 0.01 ether;

    // -- Actors ---------------------------------------------------------------
    address user = makeAddr('user');

    // -- SUT ------------------------------------------------------------------
    MockERC20 token;
    MockOFT   oft;
    UtexoSourceEntrypoint entrypoint;

    function setUp() public {
        token = new MockERC20('USDT', 'USDT');
        oft   = new MockOFT(address(token));
        oft.setNativeFee(NATIVE_FEE);

        entrypoint = new UtexoSourceEntrypoint(
            address(token),
            address(oft),
            DST_EID,
            LZ_ADAPTER
        );

        token.mint(user, 1_000_000e6);
        vm.deal(user, 10 ether);
    }

    // =========================================================================
    // Construction
    // =========================================================================

    function test_constructor_setsImmutables() public view {
        assertEq(entrypoint.token(),          address(token), 'token');
        assertEq(entrypoint.oft(),            address(oft),   'oft');
        assertEq(uint256(entrypoint.dstEid()), DST_EID,       'dstEid');
        assertEq(entrypoint.lzAdapter(),      LZ_ADAPTER,     'lzAdapter');
    }

    function test_constructor_revertsOnZeroToken() public {
        vm.expectRevert(IUtexoSourceEntrypoint.InvalidTokenAddress.selector);
        new UtexoSourceEntrypoint(address(0), address(oft), DST_EID, LZ_ADAPTER);
    }

    function test_constructor_revertsOnZeroOft() public {
        vm.expectRevert(IUtexoSourceEntrypoint.InvalidOftAddress.selector);
        new UtexoSourceEntrypoint(address(token), address(0), DST_EID, LZ_ADAPTER);
    }

    function test_constructor_revertsOnZeroEid() public {
        vm.expectRevert(IUtexoSourceEntrypoint.InvalidDstEid.selector);
        new UtexoSourceEntrypoint(address(token), address(oft), 0, LZ_ADAPTER);
    }

    function test_constructor_revertsOnZeroLZAdapter() public {
        vm.expectRevert(IUtexoSourceEntrypoint.InvalidLZAdapter.selector);
        new UtexoSourceEntrypoint(address(token), address(oft), DST_EID, bytes32(0));
    }

    // =========================================================================
    // Happy path
    // =========================================================================

    function test_deposit_happyPath_forwardsAndEmits() public {
        IUtexoSourceEntrypoint.DepositParams memory p = _params(100e6);

        vm.startPrank(user);
        token.approve(address(entrypoint), p.amountLD);

        uint256 userBalBefore = user.balance;

        vm.expectEmit(true, true, false, true, address(entrypoint));
        emit Deposit(
            keccak256(abi.encode('mock-guid', uint64(1))),
            user,
            p.amountLD,
            p.composeMsg
        );

        bytes32 guid = entrypoint.deposit{ value: NATIVE_FEE }(p);
        vm.stopPrank();

        // guid correlates with the mock's assigned value.
        assertEq(guid, keccak256(abi.encode('mock-guid', uint64(1))), 'guid');

        // OFT received tokens and the immutable routing params.
        assertEq(token.balanceOf(address(oft)), p.amountLD, 'oft holds tokens');
        assertEq(uint256(oft.lastDstEid()), DST_EID,       'dstEid forwarded');
        assertEq(oft.lastTo(),              LZ_ADAPTER,      'to forwarded');
        assertEq(oft.lastAmountLD(),        p.amountLD,    'amount forwarded');
        assertEq(oft.lastMinAmountLD(),     p.minAmountLD, 'minAmount forwarded');
        assertEq(oft.lastMsgValue(),        NATIVE_FEE,    'msg.value forwarded');
        assertEq(oft.lastRefundAddress(),   user,          'refund addr');

        // Exact-fee call: user's native balance drops by exactly NATIVE_FEE.
        assertEq(user.balance, userBalBefore - NATIVE_FEE, 'no surplus refund expected');

        // Entrypoint holds no tokens and no allowance after the call.
        assertEq(token.balanceOf(address(entrypoint)), 0, 'no token residue');
        assertEq(token.allowance(address(entrypoint), address(oft)), 0, 'allowance consumed');
    }

    function test_deposit_surplusNative_isRefunded() public {
        IUtexoSourceEntrypoint.DepositParams memory p = _params(250e6);
        uint256 surplus = 0.05 ether;

        vm.startPrank(user);
        token.approve(address(entrypoint), p.amountLD);

        uint256 userBalBefore = user.balance;
        entrypoint.deposit{ value: NATIVE_FEE + surplus }(p);
        vm.stopPrank();

        assertEq(user.balance, userBalBefore - NATIVE_FEE, 'surplus refunded');
        assertEq(address(entrypoint).balance, 0,           'no native residue');
    }

    function test_deposit_forwardsOpaqueComposeMsgUnchanged() public {
        bytes memory opaque = hex'deadbeefcafebabe1337';
        IUtexoSourceEntrypoint.DepositParams memory p = IUtexoSourceEntrypoint.DepositParams({
            amountLD:     42e6,
            minAmountLD:  42e6,
            extraOptions: hex'0003010011010000000000000000000000000000ea60',
            composeMsg:   opaque
        });

        vm.startPrank(user);
        token.approve(address(entrypoint), p.amountLD);
        entrypoint.deposit{ value: NATIVE_FEE }(p);
        vm.stopPrank();

        assertEq(oft.lastComposeMsg(),   opaque,           'composeMsg forwarded byte-for-byte');
        assertEq(oft.lastExtraOptions(), p.extraOptions,   'extraOptions forwarded');
        assertEq(oft.lastOftCmd().length, 0,                'oftCmd is always empty');
    }

    // =========================================================================
    // Reverts
    // =========================================================================

    function test_deposit_revertsOnZeroAmount() public {
        IUtexoSourceEntrypoint.DepositParams memory p = _params(0);

        vm.prank(user);
        vm.expectRevert(IUtexoSourceEntrypoint.ZeroAmount.selector);
        entrypoint.deposit{ value: NATIVE_FEE }(p);
    }

    function test_deposit_revertsOnInsufficientNativeFee() public {
        IUtexoSourceEntrypoint.DepositParams memory p = _params(10e6);

        vm.startPrank(user);
        token.approve(address(entrypoint), p.amountLD);

        vm.expectRevert(abi.encodeWithSelector(
            IUtexoSourceEntrypoint.InsufficientNativeFee.selector,
            NATIVE_FEE - 1,
            NATIVE_FEE
        ));
        entrypoint.deposit{ value: NATIVE_FEE - 1 }(p);
        vm.stopPrank();
    }

    function test_deposit_revertsIfTokenApprovalMissing() public {
        IUtexoSourceEntrypoint.DepositParams memory p = _params(10e6);

        vm.prank(user);
        vm.expectRevert(); // ERC20: insufficient allowance
        entrypoint.deposit{ value: NATIVE_FEE }(p);
    }

    function test_deposit_propagatesOftRevert() public {
        oft.setSendReverts(true);
        IUtexoSourceEntrypoint.DepositParams memory p = _params(10e6);

        vm.startPrank(user);
        token.approve(address(entrypoint), p.amountLD);
        vm.expectRevert(bytes('MockOFT: forced revert'));
        entrypoint.deposit{ value: NATIVE_FEE }(p);
        vm.stopPrank();
    }

    function test_deposit_revertsIfRefundRecipientRejectsNative() public {
        // Rejecting-fallback contract as caller — surplus refund must fail.
        RejectingRecipient rec = new RejectingRecipient(entrypoint, token);
        token.mint(address(rec), 100e6);
        vm.deal(address(rec), 1 ether);

        IUtexoSourceEntrypoint.DepositParams memory p = _params(10e6);

        vm.expectRevert(IUtexoSourceEntrypoint.NativeRefundFailed.selector);
        rec.go{ value: NATIVE_FEE + 1 }(p);
    }

    function test_deposit_exactFee_contractRecipient_ok() public {
        // Same rejecting contract, but with exact fee → no refund attempt, no revert.
        RejectingRecipient rec = new RejectingRecipient(entrypoint, token);
        token.mint(address(rec), 100e6);
        vm.deal(address(rec), 1 ether);

        IUtexoSourceEntrypoint.DepositParams memory p = _params(10e6);
        rec.go{ value: NATIVE_FEE }(p);

        assertEq(token.balanceOf(address(oft)), p.amountLD, 'tokens forwarded');
    }

    // =========================================================================
    // Quote
    // =========================================================================

    function test_quote_matchesOft() public {
        oft.setNativeFee(0.0037 ether);
        IUtexoSourceEntrypoint.DepositParams memory p = _params(5e6);
        assertEq(entrypoint.quote(p), 0.0037 ether, 'quote passthrough');
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _params(uint256 amount)
        internal
        pure
        returns (IUtexoSourceEntrypoint.DepositParams memory)
    {
        return IUtexoSourceEntrypoint.DepositParams({
            amountLD:     amount,
            minAmountLD:  amount,
            extraOptions: hex'0003',                 // arbitrary non-empty
            composeMsg:   hex'01020304'              // arbitrary non-empty
        });
    }
}

/// @dev Contract that rejects plain-ether transfers. Used to force the
///      `NativeRefundFailed` branch.
contract RejectingRecipient {
    UtexoSourceEntrypoint immutable ep;
    MockERC20             immutable tk;

    constructor(UtexoSourceEntrypoint ep_, MockERC20 tk_) {
        ep = ep_;
        tk = tk_;
    }

    function go(IUtexoSourceEntrypoint.DepositParams calldata p) external payable {
        tk.approve(address(ep), p.amountLD);
        ep.deposit{ value: msg.value }(p);
    }

    // No `receive()` / `fallback()` → any ETH sent to this contract reverts.
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { IERC20 } from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {
    IOFT,
    SendParam,
    MessagingFee,
    MessagingReceipt,
    OFTReceipt
} from '../../src/interfaces/IOFT.sol';

/// @title MockOFT
/// @notice Minimal OFT stub for testing the Utexo source entrypoint in isolation.
///         Records the last `send()` call so tests can assert that `SendParam` was
///         forwarded byte-for-byte. Burns the pulled tokens to simulate the cross-
///         chain lock.
contract MockOFT is IOFT {
    address public immutable token;

    /// Native fee the stub quotes and expects on `send()`.
    uint256 public nativeFeeQuote;

    /// Set to true to make `send()` revert — useful for failure-path tests.
    bool public sendReverts;

    /// Fake guid returned in `MessagingReceipt`; increments on every successful send.
    uint64 public guidCounter;

    // Last-call recording -----------------------------------------------------
    SendParam     internal _lastSendParam;
    MessagingFee  public   lastFee;
    address       public   lastRefundAddress;
    uint256       public   lastMsgValue;

    // Accessors (avoid returning the full struct to keep callers out of
    // stack-too-deep territory).
    function lastDstEid()       external view returns (uint32)  { return _lastSendParam.dstEid; }
    function lastTo()           external view returns (bytes32) { return _lastSendParam.to; }
    function lastAmountLD()     external view returns (uint256) { return _lastSendParam.amountLD; }
    function lastMinAmountLD()  external view returns (uint256) { return _lastSendParam.minAmountLD; }
    function lastExtraOptions() external view returns (bytes memory) { return _lastSendParam.extraOptions; }
    function lastComposeMsg()   external view returns (bytes memory) { return _lastSendParam.composeMsg; }
    function lastOftCmd()       external view returns (bytes memory) { return _lastSendParam.oftCmd; }

    constructor(address token_) {
        token = token_;
    }

    function setNativeFee(uint256 fee_) external {
        nativeFeeQuote = fee_;
    }

    function setSendReverts(bool v) external {
        sendReverts = v;
    }

    function quoteSend(SendParam calldata, bool)
        external
        view
        override
        returns (MessagingFee memory)
    {
        return MessagingFee({ nativeFee: nativeFeeQuote, lzTokenFee: 0 });
    }

    function send(
        SendParam calldata sendParam,
        MessagingFee calldata fee,
        address refundAddress
    )
        external
        payable
        override
        returns (MessagingReceipt memory receipt, OFTReceipt memory oftReceipt)
    {
        require(!sendReverts, 'MockOFT: forced revert');
        require(msg.value == fee.nativeFee, 'MockOFT: msg.value != nativeFee');
        require(fee.nativeFee == nativeFeeQuote, 'MockOFT: stale fee');

        // Pull tokens — proves the caller set the allowance correctly.
        IERC20(token).transferFrom(msg.sender, address(this), sendParam.amountLD);

        // Record for assertions.
        _lastSendParam    = sendParam;
        lastFee           = fee;
        lastRefundAddress = refundAddress;
        lastMsgValue      = msg.value;

        guidCounter += 1;
        receipt = MessagingReceipt({
            guid:  keccak256(abi.encode('mock-guid', guidCounter)),
            nonce: guidCounter,
            fee:   fee
        });
        oftReceipt = OFTReceipt({
            amountSentLD:     sendParam.amountLD,
            amountReceivedLD: sendParam.amountLD
        });
    }
}

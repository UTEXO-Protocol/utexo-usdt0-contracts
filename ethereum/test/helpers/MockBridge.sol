// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { IERC20 } from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import { IBridge } from '../../src/interfaces/IBridge.sol';

/// @title MockBridge
/// @notice Minimal Bridge stub for testing `UtexoLZAdapter` in isolation. Pulls
///         the locked tokens via `transferFrom` (proves the caller set the
///         allowance) and records the call args + forwarded `msg.value` so
///         tests can assert byte-for-byte forwarding.
contract MockBridge is IBridge {
    address public immutable token;

    /// Force `fundsIn` to revert — used by failure-path tests.
    bool public reverts;

    // Last-call recording -----------------------------------------------------
    uint256 public lastAmount;
    string  public lastDestinationChain;
    string  public lastDestinationAddress;
    uint256 public lastOperationId;
    uint256 public lastMsgValue;
    address public lastCaller;

    constructor(address token_) {
        token = token_;
    }

    function setReverts(bool v) external {
        reverts = v;
    }

    function fundsIn(
        uint256 amount,
        string  calldata destinationChain,
        string  calldata destinationAddress,
        uint256 operationId
    ) external payable override {
        require(!reverts, 'MockBridge: forced revert');

        IERC20(token).transferFrom(msg.sender, address(this), amount);

        lastAmount             = amount;
        lastDestinationChain   = destinationChain;
        lastDestinationAddress = destinationAddress;
        lastOperationId        = operationId;
        lastMsgValue           = msg.value;
        lastCaller             = msg.sender;
    }

    receive() external payable {}
}

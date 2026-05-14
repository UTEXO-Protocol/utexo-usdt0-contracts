// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { IERC20 } from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

/// @title MockBridge
/// @notice Minimal Bridge stub for testing `UtexoLZAdapter` in isolation. Pulls
///         the locked tokens via `transferFrom` (proves the caller set the
///         allowance) and records the call args + forwarded `msg.value` so
///         tests can assert byte-for-byte forwarding.
///
/// @dev    Implements only the adapter-only `fundsIn` overload that
///         `UtexoLZAdapter.lzCompose` invokes. Not declared as `IBridge` —
///         Solidity dispatches by selector at runtime, so a matching function
///         signature on this stub is sufficient. The full upstream `IBridge`
///         lives in the utexo-smart-contracts submodule and would require
///         stubbing many unrelated members (`fundsOut`, `setLZAdapter`, …)
///         that the adapter never calls in tests.
contract MockBridge {
    address public immutable token;

    /// Force `fundsIn` to revert — used by failure-path tests.
    bool public reverts;

    // Last-call recording -----------------------------------------------------
    uint256 public lastAmount;
    uint256 public lastSourceChainId;
    uint256 public lastDestinationChainId;
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

    /// @notice Mirrors the adapter-only overload
    ///         `Bridge.fundsIn(uint256 amount, uint256 sourceChainId,
    ///                         uint256 destinationChainId, string destinationAddress,
    ///                         uint256 operationId)`.
    function fundsIn(
        uint256 amount,
        uint256 sourceChainId,
        uint256 destinationChainId,
        string  calldata destinationAddress,
        uint256 operationId
    ) external payable {
        require(!reverts, 'MockBridge: forced revert');

        IERC20(token).transferFrom(msg.sender, address(this), amount);

        lastAmount             = amount;
        lastSourceChainId      = sourceChainId;
        lastDestinationChainId = destinationChainId;
        lastDestinationAddress = destinationAddress;
        lastOperationId        = operationId;
        lastMsgValue           = msg.value;
        lastCaller             = msg.sender;
    }

    receive() external payable {}
}

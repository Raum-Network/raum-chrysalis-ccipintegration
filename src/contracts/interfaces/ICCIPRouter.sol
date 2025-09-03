// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Minimal Client library types used by CCIP receiver
library Client {
  struct EVMTokenAmount { address token; uint256 amount; }
  struct Any2EVMMessage {
    bytes32 messageId;
    uint64 sourceChainSelector;
    bytes sender;
    bytes data;
    EVMTokenAmount[] destTokenAmounts;
  }
}

interface IAny2EVMMessageReceiver {
  function ccipReceive(Client.Any2EVMMessage calldata message) external;
}

interface IRouterClient {
  function isChainSupported(uint64 destChainSelector) external view returns (bool);
  function getFee(uint64 destinationChainSelector, bytes calldata message) external view returns (uint256);
}

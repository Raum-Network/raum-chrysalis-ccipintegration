// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./ICCIPRouter.sol";

interface IReceiver {
  function onReceiveCCIP(bytes calldata payload, address sender) external;
}

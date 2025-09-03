// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
interface PolygonBridgeInterface {
  function withdraw(address token, uint256 amount, address to) external;
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IRelayer {
  function relay(bytes calldata data) external;
}

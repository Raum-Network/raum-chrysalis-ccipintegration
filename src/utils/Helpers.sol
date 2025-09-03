// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
library Helpers {
  function toAddress(bytes memory data) internal pure returns (address addr) {
    assembly { addr := mload(add(data,20)) }
  }
}

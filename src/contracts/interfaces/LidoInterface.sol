// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface LidoInterface {
    function submit(address _referral) external payable;
    function balanceOf(address _account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

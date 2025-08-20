// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { IRouterClient } from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import { OwnerIsCreator } from "@chainlink/contracts-ccip/src/v0.8/shared/access/OwnerIsCreator.sol";
import { Client } from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import { IERC20 } from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract ChrysalisSender is OwnerIsCreator, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum ActionType { Stake, RequestClaim, Claim }

    error NotEnoughBalance(uint256 currentBalance, uint256 requiredBalance);
    error DestinationChainNotAllowlisted(uint64 destinationChainSelector);
    error InvalidRequest();
    error Unauthorized();
    error InsufficientStake();
    error NothingToClaim();
    error AlreadyRequested();
    error ClaimAlreadyProcessed();

    IRouterClient private immutable i_ccipRouter;
    IERC20 private immutable i_linkToken;
    IERC20 private immutable i_usdcToken;
    IERC20 private immutable i_steth;

    mapping(uint64 => bool) public allowlistedChains;
    mapping(address => uint256) public userStakes;
    mapping(address => uint256) public userRequestedClaims;
    mapping(address => bool) public userClaimProcessed;

    event StakingAction(
        bytes32 messageId,
        uint64 destinationChainSelector,
        address receiver,
        uint256 amount,
        uint256 ccipFee,
        address user,
        ActionType actionType
    );

    constructor() {
        i_ccipRouter = IRouterClient(0x9C32fCB86BF0f4a1A8921a9Fe46de3198bb884B2);
        i_linkToken = IERC20(0x0Fd9e8d3aF1aaee056EB9e802c3A762a667b1904);
        i_usdcToken = IERC20(0x41E94Eb019C0762f9Bfcf9Fb1E58725BfB0e7582);
        i_steth = IERC20(0x42063fB4e9049d75001753C3C0c5524151144140);
    }

    modifier onlyAllowlistedChain(uint64 _destinationChainSelector) {
        if (!allowlistedChains[_destinationChainSelector]) {
            revert DestinationChainNotAllowlisted(_destinationChainSelector);
        }
        _;
    }

    function allowlistDestinationChain(uint64 _destinationChainSelector, bool _allowed) external onlyOwner {
        allowlistedChains[_destinationChainSelector] = _allowed;
    }

    function stakeTokens(
        uint64 _destinationChainSelector,
        address _receiver,
        uint256 _amount,
        uint64 _gasLimit
    ) external nonReentrant onlyAllowlistedChain(_destinationChainSelector) returns (bytes32 messageId) {
        require(_amount > 0, "Stake amount must be greater than zero");

        userStakes[msg.sender] += _amount;

        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: address(i_linkToken), amount: _amount});

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(_receiver),
            data: abi.encode(msg.sender, ActionType.Stake, _amount),
            tokenAmounts: tokenAmounts,
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: _gasLimit})),
            feeToken: address(i_linkToken)
        });

        // Fee Calculation & Transfer
        uint256 ccipFee = i_ccipRouter.getFee(_destinationChainSelector, message);
        if (ccipFee > i_linkToken.balanceOf(msg.sender)) {
            revert NotEnoughBalance(i_linkToken.balanceOf(msg.sender), ccipFee);
        }

        i_linkToken.safeTransferFrom(msg.sender, address(this), ccipFee + _amount);
        i_linkToken.approve(address(i_ccipRouter), ccipFee + _amount);

        messageId = i_ccipRouter.ccipSend(_destinationChainSelector, message);

        emit StakingAction(messageId, _destinationChainSelector, _receiver, _amount, ccipFee, msg.sender, ActionType.Stake);
    }

    function requestClaim(uint256 _amount , address _receiver , uint64 _destinationChainSelector) external nonReentrant onlyAllowlistedChain(_destinationChainSelector) returns (bytes32 messageId) {
        require(_amount > 0, "Amount must be greater than zero");
        // require(userStakes[msg.sender] >= _amount, "Insufficient stake");
        require(userRequestedClaims[msg.sender] == 0, "Already requested");

        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: address(i_steth), amount: _amount});

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(_receiver),
            data: abi.encode(msg.sender, ActionType.RequestClaim, _amount),
            tokenAmounts: tokenAmounts,
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: 999999})),
            feeToken: address(i_linkToken)
        });

        uint256 ccipFee = i_ccipRouter.getFee(_destinationChainSelector, message);
        if (ccipFee > i_linkToken.balanceOf(msg.sender)) {
            revert NotEnoughBalance(i_linkToken.balanceOf(msg.sender), ccipFee);
        }

        i_linkToken.safeTransferFrom(msg.sender, address(this), ccipFee);
        i_linkToken.approve(address(i_ccipRouter), ccipFee);

        messageId = i_ccipRouter.ccipSend(_destinationChainSelector, message);

        emit StakingAction(messageId, _destinationChainSelector, _receiver, _amount, ccipFee, msg.sender, ActionType.RequestClaim);

        userRequestedClaims[msg.sender] = _amount;
    }

    function claimTokens(uint64 _destinationChainSelector, address _receiver, uint64 _gasLimit) external nonReentrant onlyAllowlistedChain(_destinationChainSelector) returns (bytes32 messageId) {
        uint256 requestedAmount = userRequestedClaims[msg.sender];
        require(requestedAmount > 0, "Nothing to claim");
        require(!userClaimProcessed[msg.sender], "Claim already processed");

        userClaimProcessed[msg.sender] = true;
        // userStakes[msg.sender] -= requestedAmount;
        userRequestedClaims[msg.sender] = 0;

        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: address(i_steth), amount: requestedAmount});

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(_receiver),
            data: abi.encode(msg.sender, ActionType.Claim, requestedAmount),
            tokenAmounts: tokenAmounts,
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: _gasLimit})),
            feeToken: address(i_linkToken)
        });

        uint256 ccipFee = i_ccipRouter.getFee(_destinationChainSelector, message);
        if (ccipFee > i_linkToken.balanceOf(msg.sender)) {
            revert NotEnoughBalance(i_linkToken.balanceOf(msg.sender), ccipFee);
        }

        i_linkToken.safeTransferFrom(msg.sender, address(this), ccipFee);
        i_linkToken.approve(address(i_ccipRouter), ccipFee);

        messageId = i_ccipRouter.ccipSend(_destinationChainSelector, message);

        emit StakingAction(messageId, _destinationChainSelector, _receiver, requestedAmount, ccipFee, msg.sender, ActionType.Claim);
    }
}

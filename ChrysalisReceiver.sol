// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {OwnerIsCreator} from "@chainlink/contracts-ccip/src/v0.8/shared/access/OwnerIsCreator.sol";
import {IERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableMap} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/utils/structs/EnumerableMap.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface UniswapInterface {
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
}

interface LidoInterface {
    function submit(address _referral) external payable;
    function balanceOf(address _account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface PolygonBridgeInterface {
    function depositFor(address user, address rootToken, bytes calldata depositData) external payable;
}

contract ChrysalisReceiver is CCIPReceiver, OwnerIsCreator, ReentrancyGuard {
    using EnumerableMap for EnumerableMap.Bytes32ToUintMap;
    using SafeERC20 for IERC20;

    enum ActionType { Stake, RequestClaim, Claim }
    enum ErrorCode { RESOLVED, BASIC }

    error SourceChainNotAllowed(uint64 sourceChainSelector);
    error SenderNotAllowed(address sender);
    error OnlySelf();
    error ErrorCase();
    error MessageNotFailed(bytes32 messageId);
    error InvalidActionType();

    UniswapInterface public dexRouter;
    LidoInterface public lidoRouter;
    PolygonBridgeInterface public bridgeInterface;
    address public immutable i_weth;

    bool internal s_simRevert = false;

    EnumerableMap.Bytes32ToUintMap internal s_failedMessages;

    mapping(uint64 chainSelector => bool isAllowlisted) public allowlistedSourceChains;
    mapping(address sender => bool isAllowlisted) public allowlistedSenders;
    mapping(bytes32 messageId => Client.Any2EVMMessage contents) public s_messageContents;

    event MessageFailed(bytes32 indexed messageId, bytes reason);
    event MessageRecovered(bytes32 indexed messageId);
    event StakingActionProcessed(address indexed user, uint256 amount, ActionType actionType);

    constructor(
        address ccipRouterAddress,
        address WETHAddress
    ) CCIPReceiver(ccipRouterAddress) {
        dexRouter = UniswapInterface(0xeE567Fe1712Faf6149d80dA1E6934E354124CfE3);
        lidoRouter = LidoInterface(0x3e3FE7dBc6B4C189E7128855dD526361c49b40Af);
        bridgeInterface = PolygonBridgeInterface(0x34F5A25B627f50Bb3f5cAb72807c4D4F405a9232);
        i_weth = WETHAddress;
    }

    receive() external payable {}

    modifier onlyAllowlisted(uint64 _sourceChainSelector, address _sender) {
        if (!allowlistedSourceChains[_sourceChainSelector]) revert SourceChainNotAllowed(_sourceChainSelector);
        if (!allowlistedSenders[_sender]) revert SenderNotAllowed(_sender);
        _;
    }

    modifier onlySelf() {
        if (msg.sender != address(this)) revert OnlySelf();
        _;
    }

    function allowlistSourceChain(uint64 _sourceChainSelector, bool _allowed) external onlyOwner {
        allowlistedSourceChains[_sourceChainSelector] = _allowed;
    }

    function allowlistSender(address _sender, bool _allowed) external onlyOwner {
        allowlistedSenders[_sender] = _allowed;
    }

    function ccipReceive(
        Client.Any2EVMMessage calldata any2EvmMessage
    ) external override onlyRouter onlyAllowlisted(any2EvmMessage.sourceChainSelector, abi.decode(any2EvmMessage.sender, (address))) {
        try this.processMessage(any2EvmMessage) {
        } catch (bytes memory err) {
            s_failedMessages.set(any2EvmMessage.messageId, uint256(ErrorCode.BASIC));
            s_messageContents[any2EvmMessage.messageId] = any2EvmMessage;
            emit MessageFailed(any2EvmMessage.messageId, err);
            return;
        }
    }

    function processMessage(
        Client.Any2EVMMessage calldata any2EvmMessage
    ) external onlySelf onlyAllowlisted(any2EvmMessage.sourceChainSelector, abi.decode(any2EvmMessage.sender, (address))) {
        if (s_simRevert) revert ErrorCase();

        (address sender, ActionType actionType, uint256 amount) = abi.decode(any2EvmMessage.data, (address, ActionType, uint256));

        if (actionType == ActionType.Stake) {
            _ccipReceive(any2EvmMessage);
        } else if (actionType == ActionType.RequestClaim) {
            _handleRequestClaim(sender, amount);
        } else if (actionType == ActionType.Claim) {
            _handleClaim(sender, amount);
        } else {
            revert InvalidActionType();
        }

        emit StakingActionProcessed(sender, amount, actionType);
    }

    function retryFailedMessage(bytes32 messageId, address tokenReceiver) external onlyOwner {
        if (s_failedMessages.get(messageId) != uint256(ErrorCode.BASIC)) revert MessageNotFailed(messageId);

        s_failedMessages.set(messageId, uint256(ErrorCode.RESOLVED));

        Client.Any2EVMMessage memory message = s_messageContents[messageId];

        IERC20(message.destTokenAmounts[0].token).safeTransfer(tokenReceiver, message.destTokenAmounts[0].amount);

        emit MessageRecovered(messageId);
    }

    function setSimRevert(bool simRevert) external onlyOwner {
        s_simRevert = simRevert;
    }

    function _ccipReceive(Client.Any2EVMMessage memory any2EvmMessage) internal override {
        address usdcToken = any2EvmMessage.destTokenAmounts[0].token;
        uint256 amount = any2EvmMessage.destTokenAmounts[0].amount;
        address sender = abi.decode(any2EvmMessage.data, (address));

        IERC20(usdcToken).approve(address(dexRouter), amount);

        address[] memory path = new address[](2);
        path[0] = address(usdcToken);
        path[1] = i_weth;

        uint256 ethBefore = address(this).balance;
        uint256 stethBefore = lidoRouter.balanceOf(address(this));

        dexRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(amount, 0, path, address(this), block.timestamp);

        uint256 ethAfter = address(this).balance;

        lidoRouter.submit{value: ethAfter - ethBefore}(address(this));

        uint256 stethAfter = lidoRouter.balanceOf(address(this));

        bytes memory depositData = abi.encode(stethAfter - stethBefore);

        lidoRouter.approve(address(bridgeInterface), stethAfter - stethBefore);

        bridgeInterface.depositFor(sender, address(lidoRouter), depositData);
    }

    function _handleRequestClaim(address sender, uint256 amount) internal {
        // Implement logic for handling request claim
    }

    function _handleClaim(address sender, uint256 amount) internal {
        // Implement logic for handling claim
    }

    function getFailedMessagesIds() external view returns (bytes32[] memory ids) {
        uint256 length = s_failedMessages.length();
        bytes32[] memory allKeys = new bytes32[](length);
        for (uint256 i = 0; i < length; i++) {
            (bytes32 key, ) = s_failedMessages.at(i);
            allKeys[i] = key;
        }
        return allKeys;
    }
}

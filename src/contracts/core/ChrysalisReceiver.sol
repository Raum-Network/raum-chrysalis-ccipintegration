// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {OwnerIsCreator} from "@chainlink/contracts-ccip/src/v0.8/shared/access/OwnerIsCreator.sol";
import {IERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableMap} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/utils/structs/EnumerableMap.sol";

interface UniswapInterface {
    function factory() external pure returns (address);

    function WETH() external pure returns (address);

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;
}

interface LidoInterface {
    function submit(address _referral) external payable;

    function balanceOf(address _account) external view returns (uint256);

    function approve(address spender, uint256 amount) external returns (bool);

    function requestWithdrawals(uint256[] memory _amounts, address _owner)
        external
        returns (uint256[] memory ids);

    function claimWithdrawalsTo(
        uint256[] memory _requestIds,
        uint256[] memory _hints,
        address _recipient
    ) external;

    function getWithdrawalStatus(uint256[] memory _requestIds)
    view
    external returns (WithdrawalRequestStatus[] memory statuses);

    struct WithdrawalRequestStatus {
    uint256 amountOfStETH;
    uint256 amountOfShares;
    address owner;
    uint256 timestamp;
    bool isFinalized;
    bool isClaimed;
}

}

contract ChrysalisReceiver is CCIPReceiver, OwnerIsCreator {
    using EnumerableMap for EnumerableMap.Bytes32ToUintMap;
    using SafeERC20 for IERC20;

    enum ErrorCode {
        RESOLVED,
        BASIC
    }

    enum ActionType {
        Stake,
        Request,
        Claim
    }

    error SourceChainNotAllowed(uint64 sourceChainSelector);
    error SenderNotAllowed(address sender);
    error OnlySelf();
    error ErrorCase();
    error MessageNotFailed(bytes32 messageId);

    UniswapInterface public dexRouter;
    IRouterClient private immutable ccipRouter;
    LidoInterface public lidoRouter;
    address public immutable rnstETHToken;
    uint256 public ethPriceInUSDT = 1602 ether;

    bool internal s_simRevert = false;

    EnumerableMap.Bytes32ToUintMap internal s_failedMessages;

    mapping(uint64 => bool) public allowlistedSourceChains;

    mapping(address => bool) public allowlistedSenders;

    mapping(address => uint256) public stakedAmount;

    mapping(bytes32 => Client.Any2EVMMessage) public s_messageContents;

    mapping(address => uint256[]) public userWithdrawals;

    mapping(address => mapping(uint256 => bool)) public userHasNft;

    event MessageFailed(bytes32 indexed messageId, bytes reason);
    event MessageRecovered(bytes32 indexed messageId);

    constructor(address ccipRouterAddress)
        CCIPReceiver(ccipRouterAddress)
    {

        LidoInterface _lidoRouter = LidoInterface(
            0x3F1c547b21f65e10480dE3ad8E19fAAC46C95034
        );
        ccipRouter = IRouterClient(0xb9531b46fE8808fB3659e39704953c2B1112DD43);
        lidoRouter = _lidoRouter;
        rnstETHToken = 0xA39Ca1f59d4b688aC4aA956EB708C15C0A63dbfe;
    }

    receive() external payable {}

    modifier onlyAllowlisted(uint64 _sourceChainSelector, address _sender) {
        if (!allowlistedSourceChains[_sourceChainSelector])
            revert SourceChainNotAllowed(_sourceChainSelector);
        if (!allowlistedSenders[_sender]) revert SenderNotAllowed(_sender);
        _;
    }

    modifier onlySelf() {
        if (msg.sender != address(this)) revert OnlySelf();
        _;
    }

    function allowlistSourceChain(uint64 _sourceChainSelector, bool _allowed)
        external
        onlyOwner
    {
        allowlistedSourceChains[_sourceChainSelector] = _allowed;
    }

    function allowlistSender(address _sender, bool _allowed)
        external
        onlyOwner
    {
        allowlistedSenders[_sender] = _allowed;
    }

    function ccipReceive(Client.Any2EVMMessage calldata any2EvmMessage)
        external
        override
        onlyRouter
        onlyAllowlisted(
            any2EvmMessage.sourceChainSelector,
            abi.decode(any2EvmMessage.sender, (address))
        )
    {
        try this.processMessage(any2EvmMessage) {} catch (bytes memory err) {
            s_failedMessages.set(
                any2EvmMessage.messageId,
                uint256(ErrorCode.BASIC)
            );
            s_messageContents[any2EvmMessage.messageId] = any2EvmMessage;
            emit MessageFailed(any2EvmMessage.messageId, err);
            return;
        }
    }

    function processMessage(Client.Any2EVMMessage calldata any2EvmMessage)
        external
        onlySelf
        onlyAllowlisted(
            any2EvmMessage.sourceChainSelector,
            abi.decode(any2EvmMessage.sender, (address))
        )
    {
        if (s_simRevert) revert ErrorCase();
        _ccipReceive(any2EvmMessage);
    }

    function retryFailedMessage(bytes32 messageId, address tokenReceiver)
        external
        onlyOwner
    {
        if (s_failedMessages.get(messageId) != uint256(ErrorCode.BASIC))
            revert MessageNotFailed(messageId);

        s_failedMessages.set(messageId, uint256(ErrorCode.RESOLVED));

        Client.Any2EVMMessage memory message = s_messageContents[messageId];

        IERC20(message.destTokenAmounts[0].token).safeTransfer(
            tokenReceiver,
            message.destTokenAmounts[0].amount
        );

        emit MessageRecovered(messageId);
    }

    function setSimRevert(bool simRevert) external onlyOwner {
        s_simRevert = simRevert;
    }

    function _ccipReceive(Client.Any2EVMMessage memory any2EvmMessage)
        internal
        override
    {
        address usdcToken = any2EvmMessage.destTokenAmounts[0].token;
        uint256 amount = any2EvmMessage.destTokenAmounts[0].amount;
        (address user, ActionType action) = abi.decode(
            any2EvmMessage.data,
            (address, ActionType)
        );
        uint64 sourceChainSelector = any2EvmMessage.sourceChainSelector;

        if (action == ActionType.Stake) {
            _handleStake(usdcToken, amount, user, sourceChainSelector);
        } else if (action == ActionType.Request) {
            _handleWithdrawRequest(amount, user);
        } else if (action == ActionType.Claim) {
            uint256 nftId;
            uint256 hint;
             (user, action, nftId, hint) = abi.decode(any2EvmMessage.data, (address, ActionType, uint256, uint256));
            _handleWithdrawClaim(user, nftId, hint);
        }
    }

    function _handleStake(
        address usdcToken,
        uint256 amount,
        address user,
        uint64 sourceChainSelector
    ) internal {

        uint256 stethBefore = lidoRouter.balanceOf(address(this));

        uint256 userStakeAmount = (amount * 1 ether) / ethPriceInUSDT;

        lidoRouter.submit{value: userStakeAmount}(address(this));

        uint256 stethAfter = lidoRouter.balanceOf(address(this));
        uint256 mintedAmount = stethAfter - stethBefore;

        stakedAmount[user] += mintedAmount;

        IERC20(rnstETHToken).approve(address(ccipRouter), mintedAmount);

        Client.EVMTokenAmount[]
            memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({
            token: address(rnstETHToken),
            amount: mintedAmount
        });

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(user),
            data: "0x",
            tokenAmounts: tokenAmounts,
            extraArgs: "",
            feeToken: address(0)
        });

        ccipRouter.ccipSend{value: 1e15}(5719461335882077547, message);
    }

    function _handleWithdrawRequest(uint256 amount, address user) internal returns (uint256) {
        uint256[] memory amounts;
        amounts[0] = amount;
        uint256[] memory nftId = lidoRouter.requestWithdrawals(
            amounts,
            address(this)
        );
        uint256[] storage withdrawals = userWithdrawals[user];
        withdrawals.push(nftId[0]);
        return nftId[0];
    }

    function _handleWithdrawClaim(
        address user,
        uint256 nftId,
        uint256 hint
    ) internal {
        require(userHasNft[user][nftId], "NFT ID not found for user");
        require(this.getWithdrawalStatus(nftId) == true , "Status not yet Finalized");
        uint256[] memory userId;
        uint256[] memory hints;
        hints[0] = hint;
        userId[0] = nftId;
        uint256 ethBefore = address(this).balance;
        lidoRouter.claimWithdrawalsTo(userId, hints, address(this));
        uint256 ethAfter = address(this).balance;
        uint256 mintedAmount = ethAfter - ethBefore;
        IERC20(rnstETHToken).approve(address(ccipRouter), mintedAmount);
          Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: address(rnstETHToken), amount: mintedAmount});

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(user),
            data: "0x",
            tokenAmounts: tokenAmounts,
            extraArgs: "",
            feeToken: address(0)
        });

        ccipRouter.ccipSend{value: 1e15}(5719461335882077547, message);

        userHasNft[user][nftId] = false;
        delete userWithdrawals[user][nftId];
    }

    function getFailedMessagesIds()
        external
        view
        returns (bytes32[] memory ids)
    {
        uint256 length = s_failedMessages.length();
        bytes32[] memory allKeys = new bytes32[](length);
        for (uint256 i = 0; i < length; i++) {
            (bytes32 key, ) = s_failedMessages.at(i);
            allKeys[i] = key;
        }
        return allKeys;
    }

    function getWithdrawalStatus(uint256 nftId) view public returns(bool)  {
        uint256[] memory nfts;
        nfts[0] = nftId;
        LidoInterface.WithdrawalRequestStatus[] memory statuses = lidoRouter.getWithdrawalStatus(nfts);

        return statuses[0].isFinalized;
    }

     function setRate(uint256 _rate) external onlyOwner {
        ethPriceInUSDT = _rate;
    }
}

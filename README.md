# 🌉 Raum Chrysalis CCIP Integration

## 🌐 Overview

This repository is a **Proof of Concept (PoC)** demonstrating a **cross-chain staking aggregator** that integrates:

- **Chainlink CCIP (Cross-Chain Interoperability Protocol)** for cross-chain messaging  
- **Lido Staking** for tokenized staking (PoC uses Ethereum Sepolia for staking)  

The system allows users to **stake USDC on Chain A**, transfer it securely across chains, stake into Lido (or other supported protocols), and mint **receipt tokens on the source chain**.

---

## 🔗 Contract Overview

| Contract                  | Description                                                                 |
|---------------------------|-----------------------------------------------------------------------------|
| `ChrysalisSender.sol`     | Handles CCIP message dispatch and CCTP-based USDC transfer initiation       |
| `ChrysalisReceiver.sol`   | Receives CCIP messages, executes staking logic (Lido in this PoC)                         
| `ICCIPRouter.sol`        | Router interface for CCIP on destination chain                      |
| `ICircleMessenger.sol`    | Helper interface for Circle message flows                                   |
| `ICCIPRouter.sol`         | Interface for CCIP message routing                                          |
| `IReceiver.sol`           | Interface for contracts accepting payloads                                  |
| `IRelayer.sol`            | *(Optional)* For extended relayer customization                            |
| `SafeMath.sol`            | Library for safe arithmetic operations                                      |

---

## 🐛 Chrysalis Protocol Flow

1. User initiates **stake** on **Chain A**  
2. **CCIP** transmits payload instructions cross-chain 
3. On **Chain B**:token is received and converted to the Supporting Asset Using Swap Routes
4. On **Chain B**: Supporting Asset is received and staked (Lido in this PoC)  
5. **Receipt token** is Bridged Back on Chain A,  mapped 1:1 with staked position  

This design is **modular**:  
- Add new staking protocols (Aave, RocketPool, etc.)  
- Switch relayers or fallback routes (CCIP vs native bridges)  

---

## 🚧 Project Status

Stage: **PoC**  

### Milestones
- ✅ Hybrid CCIP  + staking  + CCTs
- 🔜 Expand to multiple DeFi staking protocols  
- 🔜 ERC-4337 Paymaster support for gasless UX  
- 🔜 Relayer failover logic  

---

## 🧱 Tech Stack

- **Solidity** ^0.8.x  
- **Chainlink CCIP**  
- **OpenZeppelin** contracts  
- **Hardhat** for testing/deployment  
- **Future**: Account Abstraction (ERC-4337) , Transaction Bundling

---

## 🧪 Testing

PoC tested between:

- **Source Chain**: Arbitrum Sepolia  , Base Sepolia etc.
- **Destination Chain**: Ethereum Sepolia  

Full **unit tests** + **integration tests** will be extended as more staking strategies are added.

---

## 🚀 Next Steps

- ERC-4337 Paymaster for gasless staking  
- Multi-strategy staking expansion  
- Subgraph + dashboard for user tracking  
- Extended test coverage for core contracts  


# AIXCB Staking Contracts

This repository contains the smart contracts for AIXCB's staking system, which includes LP token staking and reward distribution mechanisms.

## Overview

The staking system consists of two main contracts:

1. `AIXCBLPStaking.sol`: Handles staking of Aerodrome vAMM-aixCB/WETH LP tokens with multi-token rewards
2. `AIXCBStaking.sol`: Manages staking of AIXCB tokens with multi-token rewards

### Key Features

- Multi-token reward system
- Loyalty tracking and VIP status
- Emergency controls and circuit breakers
- Upgradeable contracts (UUPS pattern)
- Role-based access control
- Comprehensive security features

## Contract Architecture

### AIXCBLPStaking.sol

- **Purpose**: Manages LP token staking and reward distribution
- **Features**:
  - Multiple reward tokens support
  - Loyalty tracking system
  - Emergency controls
  - Circuit breakers
  - Role-based access control

### AIXCBStaking.sol

- **Purpose**: Manages AIXCB token staking and reward distribution
- **Features**:
  - Multiple reward tokens support
  - Period-based staking
  - VIP status based on stake amount
  - Loyalty tracking system
  - Emergency controls
  - Role-based access control

## Development Environment

- Solidity version: ^0.8.20
- Framework: Hardhat
- Testing: Hardhat + Chai + Ethers.js
- Deployment: Hardhat + Ignition

## Known Considerations

1. Reward rate calculations use fixed-point arithmetic with 18 decimal precision
2. Emergency withdrawals incur a 20% fee
3. VIP status requires 1,000,000 tokens staked
4. Contracts are pausable and upgradeable

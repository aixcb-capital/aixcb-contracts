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
- **Key Functions**:
  ```solidity
  // View Functions
  totalStakedAmount() returns (uint256)
  userStakes(address) returns (UserStake)
  getPendingRewards(address user, address token) returns (uint256)
  getRewardTokens() returns (address[])
  getRewardPool(address token) returns (uint256 totalReward, uint256 distributed, uint256 ratePerSecond, uint256 lastUpdate)
  getLoyaltyStats(address user) returns (uint256 stakingPower, uint256 currentStreak, uint256 longestStreak, uint256 totalDays, uint256 lastUpdate, uint256 engagement)

  // State-Changing Functions
  stake(uint256 amount)
  withdraw(uint256 amount)
  claimRewards()
  emergencyWithdraw()
  ```
- **Events**:
  ```solidity
  event StakeDeposited(address indexed user, uint256 amount, uint256 timestamp)
  event StakeWithdrawn(address indexed user, uint256 amount, uint256 timestamp)
  event RewardsClaimed(address indexed user, address indexed token, uint256 amount, uint256 timestamp)
  event RewardPoolUpdated(address indexed token, uint256 newAccumulatedPerShare, uint256 totalDistributed, uint256 timestamp)
  event LoyaltyMetrics(address indexed user, uint256 stakingPower, uint256 currentStreak, uint256 totalStakingDays, uint256 engagementScore, uint256 timestamp)
  ```

### AIXCBStaking.sol

- **Purpose**: Manages AIXCB token staking and reward distribution
- **Key Functions**:
  ```solidity
  // View Functions
  getUserStake(address user, uint256 periodIndex) returns (UserStake)
  getUserTotalStake(address user) returns (uint256)
  getTotalStaked() returns (uint256)
  pendingRewards(address user, uint256 periodIndex, address token) returns (uint256)
  getRewardPoolInfo(uint256 periodIndex, address token) returns (uint256 totalReward, uint256 rewardRate, uint256 periodFinish, uint256 totalDistributed, uint256 remainingRewards)
  getLoyaltyStats(address user) returns (LoyaltyStats)
  isVIP(address) returns (bool)
  getAPR(uint256 periodIndex, address token) returns (uint256)

  // State-Changing Functions
  stake(StakeParams calldata params)
  withdraw(uint256 periodIndex)
  claimRewards(uint256 periodIndex)
  emergencyWithdraw(uint256 periodIndex)
  ```
- **Events**:
  ```solidity
  event Staked(address indexed user, uint256 amount, uint256 periodIndex, uint256 startTime, uint256 endTime)
  event Withdrawn(address indexed user, uint256 amount, uint256 periodIndex, uint256 stakeDuration)
  event RewardPaid(address indexed user, address indexed token, uint256 amount, uint256 periodIndex)
  event VIPStatusChanged(address indexed user, bool status, uint256 totalStake)
  event LoyaltyMetrics(address indexed user, uint256 stakingPower, uint256 currentStreak, uint256 totalStakingDays, uint256 engagementScore, uint256 timestamp)
  ```

## Development Environment

- Solidity version: ^0.8.20
- Framework: Hardhat
- Testing: Hardhat + Chai + Ethers.js
- Deployment: Hardhat + Ignition

## Contract Parameters and Limits

### AIXCBLPStaking
- Maximum stake: 10,000,000 LP tokens
- Emergency withdrawal fee: 20%
- Reward calculation precision: 18 decimals

### AIXCBStaking
- Staking periods: 90 days, 180 days, 360 days
- Emergency withdrawal fee: 20%
- VIP status threshold: 1,000,000 AIXCB
- Reward calculation precision: 18 decimals

## Known Considerations

1. Reward rate calculations use fixed-point arithmetic with 18 decimal precision
2. Emergency withdrawals incur a 20% fee
3. VIP status requires 1,000,000 tokens staked
4. Contracts are pausable and upgradeable
5. Role-based access control determines admin functions
6. Circuit breakers can pause specific functionalities

## For Integrators

Both contracts implement comprehensive event logging and state tracking suitable for protocol integrations. Key metrics like TVL, APR, and user positions can be tracked through the provided view functions and events.

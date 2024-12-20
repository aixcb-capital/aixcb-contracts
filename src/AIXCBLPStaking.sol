// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title AIXCBLPStaking
 * @notice Staking contract for Aerodrome vAMM-aixCB/WETH LP tokens with multi-token rewards
 * @dev Implements upgradeable pattern with UUPS proxy
 * 
 * This contract allows users to:
 * - Stake Aerodrome LP tokens
 * - Earn multiple reward tokens
 * - Track loyalty and VIP status
 * - Monitor staking metrics
 * - Withdraw stakes at any time
 * - Claim rewards independently
 * 
 * Security features:
 * - Emergency mode with admin controls
 * - Circuit breakers for critical functions
 * - Role-based access control
 * - Reentrancy protection
 * 
 * @custom:security-contact security@aixcb.com
 */
contract AIXCBLPStaking is
    ReentrancyGuardUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20Metadata;

    // ============ Constants ============

    /// @notice Role constants for access control
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant EMERGENCY_ADMIN_ROLE = keccak256("EMERGENCY_ADMIN_ROLE");
    bytes32 public constant REWARD_MANAGER_ROLE = keccak256("REWARD_MANAGER_ROLE");

    /// @notice Circuit breaker identifiers
    bytes32 public constant STAKING_CIRCUIT = keccak256("STAKING_CIRCUIT");
    bytes32 public constant WITHDRAW_CIRCUIT = keccak256("WITHDRAW_CIRCUIT");
    bytes32 public constant REWARD_CIRCUIT = keccak256("REWARD_CIRCUIT");

    /// @notice Mathematical and limit constants
    uint256 private constant PRECISION = 1e18;
    uint256 private constant SECONDS_PER_YEAR = 365 days;
    uint256 private constant EMERGENCY_WITHDRAW_FEE = 2000; // 20%
    uint256 public constant MAX_STAKE_AMOUNT = 10_000_000 * 1e18; // 10M LP tokens

    // ============ Storage ============

    /// @notice Core contract state
    IERC20Metadata public lpToken; // Aerodrome vAMM-aixCB/WETH LP token
    address public treasury;
    bool public emergencyMode;
    mapping(bytes32 => bool) public circuitBreakers;

    /// @notice Reward token management
    address[] public rewardTokens;
    mapping(address => bool) public isRewardToken;
    mapping(address => RewardPool) public rewardPools;

    /// @notice Staking data structures
    struct UserStake {
        uint128 stakedAmount;      // Amount of LP tokens staked
        uint48 initialStakeTime;   // Time of first stake
        uint48 lastUpdateTime;     // Last time rewards were updated
        mapping(address => uint256) rewardDebt; // Reward debt per token
    }

    struct RewardPool {
        uint256 totalRewardAmount;     // Total rewards allocated
        uint256 accumulatedPerShare;   // Accumulated rewards per share
        uint256 lastUpdateTimestamp;   // Last reward update time
        uint256 totalDistributedAmount;// Total rewards distributed
        uint256 rewardRatePerSecond;   // Rewards per second
    }

    struct LoyaltyStats {
        uint256 stakingPower;      // Weighted stake amount
        uint256 currentStreak;     // Current staking streak in days
        uint256 longestStreak;     // Longest staking streak achieved
        uint256 totalStakingDays;  // Total days staked
        uint256 lastUpdateTime;    // Last loyalty update time
        uint256 engagementScore;   // Overall engagement score
    }

    /// @notice State variables for staking and rewards
    mapping(address => UserStake) public userStakes;
    mapping(address => LoyaltyStats) public loyaltyStats;
    uint256 public totalStakedAmount;

    // ============ Events ============

    event StakeDeposited(address indexed user, uint256 amount, uint256 timestamp);
    event StakeWithdrawn(address indexed user, uint256 amount, uint256 timestamp);
    event RewardsClaimed(address indexed user, address indexed token, uint256 amount, uint256 timestamp);
    event RewardPoolUpdated(
        address indexed token,
        uint256 newAccumulatedPerShare,
        uint256 totalDistributed,
        uint256 timestamp
    );
    event RewardRateModified(address indexed token, uint256 newRate, uint256 timestamp);
    event EmergencyModeActivated(uint256 timestamp);
    event EmergencyModeDeactivated(uint256 timestamp);
    event CircuitBreakerToggled(bytes32 indexed circuit, bool status, uint256 timestamp);
    event LoyaltyMetrics(
        address indexed user,
        uint256 stakingPower,
        uint256 currentStreak,
        uint256 totalStakingDays,
        uint256 engagementScore,
        uint256 timestamp
    );
    event RewardTokenAdded(address indexed token, uint256 timestamp);
    event EmergencyWithdraw(address indexed user, uint256 amount, uint256 fee, uint256 timestamp);
    event RewardTokenRemoved(address indexed token, uint256 timestamp);
    event Recovered(address indexed token, uint256 amount, uint256 timestamp);

    // ============ Errors ============

    error ZeroAmount();
    error InsufficientRewards();
    error NoStakeFound();
    error ExceedsMaxStake();
    error InvalidAmount();
    error TransferFailed();
    error CircuitBreakerActive();
    error EmergencyModeActive();
    error NotEmergencyMode();
    error InvalidToken();
    error CannotRecoverLPToken();
    error CannotRecoverRewardToken();
    error TokenNotRewardToken();
    error HasPendingRewards();

    // ============ Modifiers ============

    /// @notice Ensures circuit breaker is not active
    modifier circuitBreakerNotActive(bytes32 circuit) {
        if (circuitBreakers[circuit]) revert CircuitBreakerActive();
        _;
    }

    /// @notice Ensures contract is not in emergency mode
    modifier notInEmergencyMode() {
        if (emergencyMode) revert EmergencyModeActive();
        _;
    }

    /// @notice Ensures contract is in emergency mode
    modifier onlyEmergencyMode() {
        if (!emergencyMode) revert NotEmergencyMode();
        _;
    }

    // ============ Initialization ============

    /// @notice Initializes the contract
    /// @param _lpToken The Aerodrome vAMM-aixCB/WETH LP token address
    /// @param _initialRewardTokens Array of initial reward token addresses
    /// @param _treasury Address where fees are sent
    function initialize(
        address _lpToken,
        address[] memory _initialRewardTokens,
        address _treasury
    ) external initializer {
        __ReentrancyGuard_init();
        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        require(_lpToken != address(0), "Invalid LP token address");
        require(_treasury != address(0), "Invalid treasury address");
        require(_initialRewardTokens.length > 0, "No reward tokens");

        lpToken = IERC20Metadata(_lpToken);
        treasury = _treasury;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(EMERGENCY_ADMIN_ROLE, msg.sender);
        _grantRole(REWARD_MANAGER_ROLE, msg.sender);

        // Initialize reward tokens
        for (uint256 i = 0; i < _initialRewardTokens.length; i++) {
            _addRewardToken(_initialRewardTokens[i]);
        }

        // Initialize contract as paused
        _pause();
    }

    /// @notice Internal function to authorize contract upgrades
    /// @dev Required by UUPS pattern, restricted to ADMIN_ROLE
    /// @param newImplementation Address of the new implementation contract
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {}

    // ============ Core Functions ============

    /// @notice Stakes LP tokens to earn rewards
    /// @param amount Amount of LP tokens to stake
    /// @dev Reverts if amount is 0 or exceeds max stake amount
    function stake(uint256 amount) 
        external 
        nonReentrant 
        whenNotPaused 
        notInEmergencyMode 
        circuitBreakerNotActive(STAKING_CIRCUIT) 
    {
        if (amount == 0) revert ZeroAmount();
        
        UserStake storage userStake = userStakes[msg.sender];
        uint256 newTotalStake = uint256(userStake.stakedAmount) + amount;
        if (newTotalStake > MAX_STAKE_AMOUNT) revert ExceedsMaxStake();

        _updateRewards(msg.sender);
        
        // If user already has a stake, claim pending rewards first
        if (userStake.stakedAmount > 0) {
            _claimRewards(msg.sender);
        }

        totalStakedAmount += amount;
        userStake.stakedAmount = uint128(newTotalStake);
        userStake.initialStakeTime = userStake.initialStakeTime == 0 ? 
            uint48(block.timestamp) : userStake.initialStakeTime;
        userStake.lastUpdateTime = uint48(block.timestamp);

        // Update reward debts for all tokens
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            address token = rewardTokens[i];
            userStake.rewardDebt[token] = (newTotalStake * rewardPools[token].accumulatedPerShare) / PRECISION;
        }

        lpToken.safeTransferFrom(msg.sender, address(this), amount);

        _updateLoyaltyMetrics(msg.sender, amount, true);

        emit StakeDeposited(msg.sender, amount, block.timestamp);
    }

    /// @notice Withdraws staked LP tokens and claims rewards
    /// @param amount Amount of LP tokens to withdraw
    /// @dev Reverts if amount is 0 or exceeds staked amount
    function withdraw(uint256 amount) 
        external 
        nonReentrant 
        whenNotPaused 
        notInEmergencyMode
        circuitBreakerNotActive(WITHDRAW_CIRCUIT) 
    {
        UserStake storage userStake = userStakes[msg.sender];
        if (userStake.stakedAmount == 0) revert NoStakeFound();
        if (amount == 0) revert ZeroAmount();
        if (amount > userStake.stakedAmount) revert InvalidAmount();

        _updateRewards(msg.sender);
        _claimRewards(msg.sender);

        totalStakedAmount -= amount;
        userStake.stakedAmount -= uint128(amount);
        userStake.lastUpdateTime = uint48(block.timestamp);

        // Update reward debts for all tokens
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            address token = rewardTokens[i];
            userStake.rewardDebt[token] = (uint256(userStake.stakedAmount) * rewardPools[token].accumulatedPerShare) / PRECISION;
        }

        lpToken.safeTransfer(msg.sender, amount);

        _updateLoyaltyMetrics(msg.sender, amount, false);

        emit StakeWithdrawn(msg.sender, amount, block.timestamp);
    }

    /// @notice Claims pending rewards for all reward tokens
    /// @dev Reverts if no rewards are available
    function claimRewards() 
        external 
        nonReentrant 
        whenNotPaused 
        notInEmergencyMode
        circuitBreakerNotActive(REWARD_CIRCUIT) 
    {
        _updateRewards(msg.sender);
        _claimRewards(msg.sender);
    }

    /// @notice Emergency withdrawal without rewards
    /// @dev Only available in emergency mode, incurs withdrawal fee
    function emergencyWithdraw() external nonReentrant onlyEmergencyMode {
        UserStake storage userStake = userStakes[msg.sender];
        if (userStake.stakedAmount == 0) revert NoStakeFound();

        uint256 amount = userStake.stakedAmount;
        uint256 fee = (amount * EMERGENCY_WITHDRAW_FEE) / 10000;
        uint256 withdrawAmount = amount - fee;

        totalStakedAmount -= amount;
        delete userStakes[msg.sender];

        if (fee > 0) {
            lpToken.safeTransfer(treasury, fee);
        }
        lpToken.safeTransfer(msg.sender, withdrawAmount);

        emit EmergencyWithdraw(msg.sender, amount, fee, block.timestamp);
    }

    // ============ Reward Management Functions ============

    /// @notice Adds a new reward token
    /// @param token Address of the reward token to add
    function addRewardToken(address token) 
        external 
        onlyRole(REWARD_MANAGER_ROLE) 
        whenNotPaused 
        nonReentrant 
    {
        _addRewardToken(token);
    }

    /// @notice Funds a reward pool for a specific token
    /// @param token Address of the reward token
    /// @param amount Amount to add to the reward pool
    function fundRewardPool(address token, uint256 amount)
        external
        onlyRole(REWARD_MANAGER_ROLE)
        whenNotPaused
        nonReentrant
    {
        if (!isRewardToken[token]) revert InvalidToken();
        if (amount == 0) revert ZeroAmount();

        RewardPool storage pool = rewardPools[token];
        
        // Update rewards before modifying the pool
        _updateRewardPool(token);

        // Transfer tokens to contract
        IERC20Metadata(token).safeTransferFrom(msg.sender, address(this), amount);

        // Update pool parameters
        pool.totalRewardAmount += amount;
        pool.rewardRatePerSecond = (pool.totalRewardAmount - pool.totalDistributedAmount) / SECONDS_PER_YEAR;

        emit RewardRateModified(token, pool.rewardRatePerSecond, block.timestamp);
    }

    // ============ Internal Functions ============

    /// @notice Updates rewards for all tokens
    /// @param account Address of the account to update
    function _updateRewards(address account) internal {
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            _updateRewardPool(rewardTokens[i]);
            _updateUserRewards(account, rewardTokens[i]);
        }
    }

    /// @notice Updates the reward pool for a specific token
    /// @param token Address of the reward token
    function _updateRewardPool(address token) internal {
        RewardPool storage pool = rewardPools[token];
        
        if (totalStakedAmount == 0) {
            pool.lastUpdateTimestamp = block.timestamp;
            return;
        }

        uint256 timeDiff = block.timestamp - pool.lastUpdateTimestamp;
        if (timeDiff > 0) {
            uint256 reward = timeDiff * pool.rewardRatePerSecond;
            uint256 newRewardPerShare = (reward * PRECISION) / totalStakedAmount;
            pool.accumulatedPerShare += newRewardPerShare;
            pool.lastUpdateTimestamp = block.timestamp;

            emit RewardPoolUpdated(
                token,
                pool.accumulatedPerShare,
                pool.totalDistributedAmount,
                block.timestamp
            );
        }
    }

    /// @notice Updates user rewards for a specific token
    /// @param account Address of the user
    /// @param token Address of the reward token
    function _updateUserRewards(address account, address token) internal {
        UserStake storage userStake = userStakes[account];
        if (userStake.stakedAmount == 0) return;

        RewardPool storage pool = rewardPools[token];
        uint256 pending = (uint256(userStake.stakedAmount) * pool.accumulatedPerShare) / PRECISION - userStake.rewardDebt[token];
        
        if (pending > 0) {
            uint256 remainingRewards = pool.totalRewardAmount - pool.totalDistributedAmount;
            uint256 transferAmount = pending > remainingRewards ? remainingRewards : pending;
            
            if (transferAmount > 0) {
                pool.totalDistributedAmount += transferAmount;
                IERC20Metadata(token).safeTransfer(account, transferAmount);
                emit RewardsClaimed(account, token, transferAmount, block.timestamp);
            }
        }

        userStake.rewardDebt[token] = (uint256(userStake.stakedAmount) * pool.accumulatedPerShare) / PRECISION;
    }

    /// @notice Claims all pending rewards for a user
    /// @param account Address of the user
    function _claimRewards(address account) internal {
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            _updateUserRewards(account, rewardTokens[i]);
        }
    }

    /// @notice Updates loyalty metrics for a user
    /// @param user Address of the user
    /// @param amount Amount of tokens involved
    /// @param isStaking Whether the operation is staking (true) or withdrawing (false)
    function _updateLoyaltyMetrics(address user, uint256 amount, bool isStaking) internal {
        LoyaltyStats storage stats = loyaltyStats[user];
        uint256 currentTime = block.timestamp;

        if (isStaking) {
            stats.stakingPower += amount;
            
            if (stats.lastUpdateTime == 0) {
                stats.currentStreak = 1;
                stats.totalStakingDays = 1;
            } else {
                uint256 daysSinceLastUpdate = (currentTime - stats.lastUpdateTime) / 1 days;
                if (daysSinceLastUpdate >= 1) {
                    stats.currentStreak++;
                    if (stats.currentStreak > stats.longestStreak) {
                        stats.longestStreak = stats.currentStreak;
                    }
                    stats.totalStakingDays += daysSinceLastUpdate;
                } else if (daysSinceLastUpdate > 1) {
                    stats.currentStreak = 1;
                    stats.totalStakingDays += daysSinceLastUpdate;
                }
            }
        } else {
            stats.stakingPower = stats.stakingPower > amount ? stats.stakingPower - amount : 0;
        }

        stats.lastUpdateTime = currentTime;
        stats.engagementScore = _calculateEngagementScore(user);

        emit LoyaltyMetrics(
            user,
            stats.stakingPower,
            stats.currentStreak,
            stats.totalStakingDays,
            stats.engagementScore,
            currentTime
        );
    }

    /// @notice Calculates engagement score for a user
    /// @param user Address of the user
    /// @return Calculated engagement score
    function _calculateEngagementScore(address user) internal view returns (uint256) {
        LoyaltyStats storage stats = loyaltyStats[user];
        return (stats.stakingPower * stats.totalStakingDays * (100 + stats.currentStreak)) / 100;
    }

    // ============ View Functions ============

    /// @notice Gets pending rewards for a user for a specific token
    /// @param user Address of the user
    /// @param token Address of the reward token
    /// @return Amount of pending rewards
    function getPendingRewards(address user, address token) external view returns (uint256) {
        if (!isRewardToken[token]) revert InvalidToken();

        UserStake storage userStake = userStakes[user];
        if (userStake.stakedAmount == 0) return 0;

        RewardPool storage pool = rewardPools[token];
        uint256 accumulatedPerShare = pool.accumulatedPerShare;

        if (totalStakedAmount > 0) {
            uint256 timeDiff = block.timestamp - pool.lastUpdateTimestamp;
            uint256 reward = timeDiff * pool.rewardRatePerSecond;
            accumulatedPerShare += (reward * PRECISION) / totalStakedAmount;
        }

        return (uint256(userStake.stakedAmount) * accumulatedPerShare) / PRECISION - userStake.rewardDebt[token];
    }

    /// @notice Gets all reward token addresses
    /// @return Array of reward token addresses
    function getRewardTokens() external view returns (address[] memory) {
        return rewardTokens;
    }

    /// @notice Gets reward pool information for a token
    /// @param token Address of the reward token
    /// @return totalReward Total amount of rewards allocated to the pool
    /// @return distributed Total amount of rewards distributed so far
    /// @return ratePerSecond Current reward rate per second
    /// @return lastUpdate Last time the pool was updated
    function getRewardPool(address token) external view returns (
        uint256 totalReward,
        uint256 distributed,
        uint256 ratePerSecond,
        uint256 lastUpdate
    ) {
        if (!isRewardToken[token]) revert InvalidToken();
        RewardPool storage pool = rewardPools[token];
        return (
            pool.totalRewardAmount,
            pool.totalDistributedAmount,
            pool.rewardRatePerSecond,
            pool.lastUpdateTimestamp
        );
    }

    /// @notice Gets loyalty statistics for a user
    /// @param user Address of the user
    /// @return stakingPower Current staking power of the user
    /// @return currentStreak Current consecutive staking streak in days
    /// @return longestStreak Longest staking streak achieved
    /// @return totalDays Total number of days staked
    /// @return lastUpdate Last time loyalty metrics were updated
    /// @return engagement Current engagement score
    function getLoyaltyStats(address user) external view returns (
        uint256 stakingPower,
        uint256 currentStreak,
        uint256 longestStreak,
        uint256 totalDays,
        uint256 lastUpdate,
        uint256 engagement
    ) {
        LoyaltyStats storage stats = loyaltyStats[user];
        return (
            stats.stakingPower,
            stats.currentStreak,
            stats.longestStreak,
            stats.totalStakingDays,
            stats.lastUpdateTime,
            stats.engagementScore
        );
    }

    // ============ Emergency Functions ============

    /// @notice Activates emergency mode
    function enableEmergencyMode() external onlyRole(EMERGENCY_ADMIN_ROLE) {
        emergencyMode = true;
        emit EmergencyModeActivated(block.timestamp);
    }

    /// @notice Deactivates emergency mode
    function disableEmergencyMode() external onlyRole(EMERGENCY_ADMIN_ROLE) {
        emergencyMode = false;
        emit EmergencyModeDeactivated(block.timestamp);
    }

    /// @notice Toggles circuit breaker status
    /// @param circuit The circuit to toggle
    function toggleCircuitBreaker(bytes32 circuit) external onlyRole(EMERGENCY_ADMIN_ROLE) {
        circuitBreakers[circuit] = !circuitBreakers[circuit];
        emit CircuitBreakerToggled(circuit, circuitBreakers[circuit], block.timestamp);
    }

    // ============ Internal Functions ============

    /// @notice Pauses all contract operations
    function pause() external onlyRole(EMERGENCY_ADMIN_ROLE) {
        _pause();
    }

    /// @notice Unpauses contract operations
    function unpause() external onlyRole(EMERGENCY_ADMIN_ROLE) {
        _unpause();
    }

    /// @notice Adds a new reward token to the contract
    /// @param token Address of the new reward token
    function _addRewardToken(address token) internal {
        require(token != address(0), "Invalid token address");
        require(!isRewardToken[token], "Token already added");

        isRewardToken[token] = true;
        rewardTokens.push(token);
        emit RewardTokenAdded(token, block.timestamp);
    }

    /// @notice Removes a reward token from the contract
    /// @dev Only callable by admin role. Ensures all rewards are distributed before removal
    /// @param token Address of the reward token to remove
    function removeRewardToken(address token) 
        external 
        onlyRole(ADMIN_ROLE) 
        whenNotPaused 
        nonReentrant 
    {
        if (!isRewardToken[token]) revert TokenNotRewardToken();
        
        // Check for pending rewards
        RewardPool storage pool = rewardPools[token];
        if (pool.totalRewardAmount > pool.totalDistributedAmount) revert HasPendingRewards();

        // Remove from mapping
        isRewardToken[token] = false;

        // Remove from array
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            if (rewardTokens[i] == token) {
                rewardTokens[i] = rewardTokens[rewardTokens.length - 1];
                rewardTokens.pop();
                break;
            }
        }

        // Clean up pool data
        delete rewardPools[token];

        emit RewardTokenRemoved(token, block.timestamp);
    }

    /// @notice Recovers accidentally sent ERC20 tokens
    /// @dev Only callable by admin role. Cannot recover LP tokens or active reward tokens
    /// @param tokenAddress Address of the token to recover
    /// @param tokenAmount Amount of tokens to recover
    function recoverERC20(address tokenAddress, uint256 tokenAmount) 
        external 
        onlyRole(ADMIN_ROLE) 
        nonReentrant 
    {
        if (tokenAddress == address(lpToken)) revert CannotRecoverLPToken();
        if (isRewardToken[tokenAddress]) revert CannotRecoverRewardToken();
        
        IERC20Metadata(tokenAddress).safeTransfer(treasury, tokenAmount);
        
        emit Recovered(tokenAddress, tokenAmount, block.timestamp);
    }

    uint256[50] private __gap;
} 
// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/// @title AIXCBStaking - A flexible staking contract for aixCB tokens
/// @notice This contract implements a staking system with multiple lock periods, reward distribution,
///         loyalty tracking, and emergency controls
/// @dev Implements upgradeable pattern with UUPS proxy
/// @custom:security-contact security@aixcb.com
contract AIXCBStaking is
    ReentrancyGuardUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20Metadata;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant EMERGENCY_ADMIN_ROLE = keccak256("EMERGENCY_ADMIN_ROLE");
    bytes32 public constant REWARD_MANAGER_ROLE = keccak256("REWARD_MANAGER_ROLE");

    uint256 private constant PRECISION = 1e18;
    uint256 private constant SECONDS_PER_YEAR = 365 days;

    // Kept for storage compatibility (not used in logic)
    uint256 private constant EMERGENCY_WITHDRAW_FEE = 2000;
    uint256[] public lockPeriods;
    // Kept for storage compatibility (not used in logic)
    uint256[] public PERIOD_RATES;
    uint256 public constant MAX_PERIOD_INDEX = 2;

    IERC20Metadata public stakingToken;
    address public treasury;
    mapping(address => mapping(uint256 => UserStake)) public userStakes;
    mapping(uint256 => uint256) public totalStakedForPeriod;
    mapping(address => uint256) private _totalUserStake;
    mapping(uint256 => address[]) private _stakersPerPeriod;
    mapping(uint256 => mapping(address => bool)) private _hasStakedInPeriod;

    address[] public rewardTokens;
    mapping(address => bool) public isRewardToken;
    mapping(uint256 => mapping(address => RewardPool)) public rewardPools;
    mapping(address => mapping(uint256 => mapping(address => uint256))) public userRewardPerSharePaid;
    mapping(address => mapping(uint256 => mapping(address => uint256))) public userRewards;

    // Kept for storage compatibility (not used in logic)
    mapping(address => LoyaltyStats) public loyaltyStats;
    // Kept for storage compatibility (not used in logic)
    mapping(address => bool) public isVIP;

    mapping(bytes32 => bool) public circuitBreakers;
    bool public emergencyMode;

    bytes32 public constant STAKING_CIRCUIT = keccak256("STAKING_CIRCUIT");
    bytes32 public constant WITHDRAWAL_CIRCUIT = keccak256("WITHDRAWAL_CIRCUIT");
    bytes32 public constant REWARDS_CIRCUIT = keccak256("REWARDS_CIRCUIT");

    /// @notice Emitted when a user stakes tokens
    /// @param user Address of the staking user
    /// @param amount Amount of tokens staked
    /// @param periodIndex Index of the staking period
    /// @param startTime Start timestamp of the stake
    /// @param endTime End timestamp of the stake
    event Staked(address indexed user, uint256 amount, uint256 periodIndex, uint256 startTime, uint256 endTime);

    /// @notice Emitted when a user withdraws staked tokens
    /// @param user Address of the withdrawing user
    /// @param amount Amount of tokens withdrawn
    /// @param periodIndex Index of the staking period
    /// @param stakeDuration Total duration of the stake
    event Withdrawn(address indexed user, uint256 amount, uint256 periodIndex, uint256 stakeDuration);

    /// @notice Emitted when rewards are paid to a user
    /// @param user Address of the user receiving rewards
    /// @param token Address of the reward token
    /// @param amount Amount of rewards paid
    /// @param periodIndex Index of the staking period
    event RewardPaid(address indexed user, address indexed token, uint256 amount, uint256 periodIndex);

    /// @notice Emitted when a circuit breaker is toggled
    /// @param circuit Identifier of the circuit
    /// @param active New state of the circuit breaker
    /// @param timestamp Time of the toggle
    event CircuitBreakerToggled(bytes32 circuit, bool active, uint256 timestamp);

    /// @notice Emitted when an emergency withdrawal occurs
    /// @param user Address of the withdrawing user
    /// @param amount Amount withdrawn
    /// @param fee Fee charged for emergency withdrawal
    /// @param timestamp Time of the withdrawal
    event EmergencyWithdraw(address indexed user, uint256 amount, uint256 fee, uint256 timestamp);

    /// @notice Emitted when reward tokens are withdrawn in case of emergency
    /// @param token Address of the reward token
    /// @param recipient Address to receive the tokens
    /// @param amount Amount of tokens withdrawn
    /// @param timestamp Time of the withdrawal
    event EmergencyTokenWithdraw(address indexed token, address indexed recipient, uint256 amount, uint256 timestamp);

    /// @notice Event emitted when staking is started
    event StakingStarted(uint256 timestamp);

    /// @notice Event emitted when staking is stopped
    event StakingStopped(uint256 timestamp);

    /// @notice Emitted when a reward token is removed from the contract
    /// @param token Address of the removed reward token
    /// @param timestamp Timestamp of the removal
    event RewardTokenRemoved(address indexed token, uint256 timestamp);

    /// @notice Emitted when ERC20 tokens are recovered
    /// @param token Address of the recovered token
    /// @param amount Amount of tokens recovered
    /// @param timestamp Timestamp of the recovery
    event Recovered(address indexed token, uint256 amount, uint256 timestamp);

    /// @notice Emitted when a new reward token is added to the contract
    /// @param token Address of the added reward token
    /// @param timestamp Timestamp of the addition
    event RewardTokenAdded(address indexed token, uint256 timestamp);

    /// @notice Emitted when a user upgrades their stake to a longer lock period
    /// @param user Address of the user upgrading the stake
    /// @param oldPeriodIndex Original staking period index
    /// @param newPeriodIndex New staking period index
    /// @param amount Amount of tokens being upgraded
    /// @param timestamp Time of the upgrade
    event StakeUpgraded(
        address indexed user,
        uint256 oldPeriodIndex,
        uint256 newPeriodIndex,
        uint256 amount,
        uint256 timestamp
    );

    error DeadlineExpired();
    error ZeroAmount();
    error InvalidPeriod();
    error StakeExists();
    error StakeExpired();
    error NotVIP();
    error StakeLocked();
    error StakeNotFound();
    error Unauthorized();
    error CircuitBreakerActive();
    error NotInEmergencyMode();
    error CannotRecoverStakingToken();
    error CannotRecoverRewardToken();
    error TokenNotRewardToken();
    error HasPendingRewards();
    error InvalidUpgradePath();

    /// @notice Represents a user's stake in a specific period
    /// @dev Packed into a single storage slot
    struct UserStake {
        uint128 amount;
        uint48 startTime;
        uint48 endTime;
        uint32 periodIndex;
        bool initialized;
    }

    /// @notice Represents a reward pool for a specific period and token
    struct RewardPool {
        uint256 totalReward;
        uint256 accumulatedPerShare;
        uint256 lastUpdateTime;
        uint256 totalDistributed;
        uint256 periodFinish;
        uint256 rewardRate;
    }

    /// @notice Parameters for staking operation
    struct StakeParams {
        uint256 amount;
        uint256 periodIndex;
        uint256 deadline;
    }

    /// @notice Tracks user loyalty and engagement metrics
    struct LoyaltyStats {
        uint256 stakingPower;
        uint256 currentStreak;
        uint256 longestStreak;
        uint256 totalStakingDays;
        uint256 lastUpdateTime;
        uint256 engagementScore;
    }

    /// @notice Initializes the contract with the staking token and initial reward tokens
    /// @param _stakingToken The ERC20 token that can be staked
    /// @param _initialRewardTokens Array of initial reward token addresses
    /// @param _treasury Address where emergency withdrawal fees are sent
    function initialize(
        address _stakingToken,
        address[] memory _initialRewardTokens,
        address _treasury
    ) external initializer {
        __ReentrancyGuard_init();
        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        require(_stakingToken != address(0), "Invalid staking token address");
        require(_treasury != address(0), "Invalid treasury address");
        stakingToken = IERC20Metadata(_stakingToken);
        treasury = _treasury;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(EMERGENCY_ADMIN_ROLE, msg.sender);
        _grantRole(REWARD_MANAGER_ROLE, msg.sender);

        lockPeriods = [90 days, 180 days, 360 days];
        // periodRates initialized but unused for backward compatibility

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

    /// @notice Internal function to add a new reward token
    /// @dev Prevents duplicate token additions and zero address
    /// @param token Address of the reward token to add
    function _addRewardToken(address token) internal {
        require(token != address(0), "Invalid token address");
        require(IERC20Metadata(token).decimals() == 18, "Invalid token decimals");

        if (!isRewardToken[token]) {
            rewardTokens.push(token);
            isRewardToken[token] = true;
            emit RewardTokenAdded(token, block.timestamp);
        }
    }

    /// @notice Adds a new reward token to the accepted list
    /// @dev Can only be called by accounts with REWARD_MANAGER_ROLE
    /// @param token Address of the reward token to add
    function addRewardToken(address token)
        external
        onlyRole(REWARD_MANAGER_ROLE)
        whenNotPaused
        nonReentrant
    {
        _addRewardToken(token);
    }

    /// @notice Stakes tokens for a specified period
    /// @param params Staking parameters including amount, period, deadline, and minimum rate
    function stake(StakeParams calldata params)
        external
        nonReentrant
        whenNotPaused
        notEmergency
        whenCircuitActive(STAKING_CIRCUIT)
        validPeriod(params.periodIndex)
        validAmount(params.amount)
    {
        if (block.timestamp > params.deadline) revert DeadlineExpired();

        UserStake storage userStake = userStakes[msg.sender][params.periodIndex];
        uint256 endTime;
        bool isNewStake = !userStake.initialized;

        _updateReward(msg.sender, params.periodIndex);

        if (isNewStake) {
            endTime = block.timestamp + lockPeriods[params.periodIndex];
            userStakes[msg.sender][params.periodIndex] = UserStake({
                amount: uint128(params.amount),
                startTime: uint48(block.timestamp),
                endTime: uint48(endTime),
                periodIndex: uint32(params.periodIndex),
                initialized: true
            });

            if (!_hasStakedInPeriod[params.periodIndex][msg.sender]) {
                _stakersPerPeriod[params.periodIndex].push(msg.sender);
                _hasStakedInPeriod[params.periodIndex][msg.sender] = true;
            }
        } else {
            if (block.timestamp >= userStake.endTime) revert StakeExpired();
            endTime = userStake.endTime;
            userStake.amount = uint128(uint256(userStake.amount) + params.amount);
        }

        totalStakedForPeriod[params.periodIndex] += params.amount;
        _totalUserStake[msg.sender] += params.amount;

        stakingToken.safeTransferFrom(msg.sender, address(this), params.amount);

        for (uint256 i = 0; i < rewardTokens.length; i++) {
            address token = rewardTokens[i];
            RewardPool storage pool = rewardPools[params.periodIndex][token];
            userRewardPerSharePaid[msg.sender][params.periodIndex][token] = pool.accumulatedPerShare;
        }

        emit Staked(msg.sender, params.amount, params.periodIndex, block.timestamp, endTime);
    }

    /// @notice Withdraws staked tokens after lock period expires
    /// @param periodIndex Index of the staking period to withdraw from
    function withdraw(uint256 periodIndex)
        external
        nonReentrant
        whenNotPaused
        notEmergency
        whenCircuitActive(WITHDRAWAL_CIRCUIT)
        validPeriod(periodIndex)
    {
        UserStake storage userStakeData = userStakes[msg.sender][periodIndex];
        if (!userStakeData.initialized) revert StakeNotFound();

        // Allow withdrawal if either lock period ended OR all reward pools finished
        if (block.timestamp < userStakeData.endTime && !isAllRewardPoolsFinished(periodIndex)) {
            revert StakeLocked();
        }

        _updateReward(msg.sender, periodIndex);

        // Optimize reward claims loop
        uint256 rewardTokenLength = rewardTokens.length;
        for (uint256 i = 0; i < rewardTokenLength; i++) {
            address token = rewardTokens[i];

            uint256 reward = userRewards[msg.sender][periodIndex][token];
            if (reward > 0) {
                uint256 contractBalance = IERC20Metadata(token).balanceOf(address(this));
                uint256 transferAmount = Math.min(reward, contractBalance);

                if (transferAmount > 0) {
                    userRewards[msg.sender][periodIndex][token] -= transferAmount;
                    RewardPool storage pool = rewardPools[periodIndex][token];
                    pool.totalDistributed += transferAmount;

                    IERC20Metadata(token).safeTransfer(msg.sender, transferAmount);
                    emit RewardPaid(msg.sender, token, transferAmount, periodIndex);
                }
            }
        }

        uint256 amount = userStakeData.amount;
        totalStakedForPeriod[periodIndex] -= amount;
        _totalUserStake[msg.sender] -= amount;

        delete userStakes[msg.sender][periodIndex];

        // Token transfer after state updates
        stakingToken.safeTransfer(msg.sender, amount);

        uint256 stakeDuration = block.timestamp - userStakeData.startTime;
        emit Withdrawn(msg.sender, amount, periodIndex, stakeDuration);
    }

    /// @notice Claims accumulated rewards for a specific staking period
    /// @param periodIndex Index of the staking period to claim rewards from
    function claimRewards(uint256 periodIndex)
        external
        nonReentrant
        whenNotPaused
        notEmergency
        whenCircuitActive(REWARDS_CIRCUIT)
        validPeriod(periodIndex)
    {
        _updateReward(msg.sender, periodIndex);

        for (uint256 i = 0; i < rewardTokens.length; i++) {
            address token = rewardTokens[i];
            uint256 reward = userRewards[msg.sender][periodIndex][token];

            if (reward > 0) {
                uint256 balance = IERC20Metadata(token).balanceOf(address(this));
                uint256 transferAmount = Math.min(reward, balance);

                if (transferAmount > 0) {
                    userRewards[msg.sender][periodIndex][token] -= transferAmount;
                    RewardPool storage pool = rewardPools[periodIndex][token];
                    pool.totalDistributed += transferAmount;

                    IERC20Metadata(token).safeTransfer(msg.sender, transferAmount);
                    emit RewardPaid(msg.sender, token, transferAmount, periodIndex);
                }

            }
        }
    }

    /// @notice Updates reward calculations for a user's stake
    /// @param account User address to update rewards for
    /// @param periodIndex Index of the staking period
    function _updateReward(address account, uint256 periodIndex) internal {
        uint256 totalStaked = totalStakedForPeriod[periodIndex];

        for (uint256 i = 0; i < rewardTokens.length; i++) {
            address token = rewardTokens[i];
            RewardPool storage pool = rewardPools[periodIndex][token];

            uint256 lastTimeRewardApplicable = Math.min(block.timestamp, pool.periodFinish);
            uint256 timeDelta = lastTimeRewardApplicable - pool.lastUpdateTime;

            if (timeDelta > 0 && totalStaked > 0) {
                // Simplified calculation
                uint256 rewardForPeriod = timeDelta * pool.rewardRate;
                pool.accumulatedPerShare += (rewardForPeriod * PRECISION) / totalStaked;
                pool.lastUpdateTime = lastTimeRewardApplicable;
            }

            // Update user rewards if needed
            if (account != address(0)) {
                UserStake storage userStakeData = userStakes[account][periodIndex];
                if (userStakeData.initialized) {
                    uint256 userRewardDelta = (userStakeData.amount *
                        (pool.accumulatedPerShare - userRewardPerSharePaid[account][periodIndex][token])) / PRECISION;
                    userRewards[account][periodIndex][token] += userRewardDelta;
                    userRewardPerSharePaid[account][periodIndex][token] = pool.accumulatedPerShare;
                }
            }
        }
    }

    /// @notice Allows reward manager to fund reward pools
    /// @param periodIndex Index of the staking period to fund
    /// @param token Address of the reward token
    /// @param amount Amount of tokens to add to the reward pool
    function fundRewardPool(uint256 periodIndex, address token, uint256 amount)
        external
        nonReentrant
        onlyRole(REWARD_MANAGER_ROLE)
        validPeriod(periodIndex)
        validRewardToken(token)
        validAmount(amount)
    {
        RewardPool storage pool = rewardPools[periodIndex][token];
        _updateReward(address(0), periodIndex);

        IERC20Metadata(token).safeTransferFrom(msg.sender, address(this), amount);
        pool.totalReward += amount;

        if (block.timestamp >= pool.periodFinish) {
            pool.rewardRate = amount / SECONDS_PER_YEAR;
            pool.periodFinish = block.timestamp + SECONDS_PER_YEAR;
        } else {
            uint256 remaining = pool.periodFinish - block.timestamp;
            uint256 leftover = remaining * pool.rewardRate;
            pool.rewardRate = (leftover + amount) / remaining;
        }

        pool.lastUpdateTime = block.timestamp;
    }

    /// @notice Toggles circuit breaker for emergency controls
    /// @dev Only callable by emergency admin
    /// @param circuit Identifier of the circuit to toggle
    function toggleCircuitBreaker(bytes32 circuit) external onlyRole(EMERGENCY_ADMIN_ROLE) {
        circuitBreakers[circuit] = !circuitBreakers[circuit];
        emit CircuitBreakerToggled(circuit, circuitBreakers[circuit], block.timestamp);
    }

    /// @notice Enables emergency mode for the contract
    /// @dev Only callable by emergency admin
    function enableEmergencyMode() external onlyRole(EMERGENCY_ADMIN_ROLE) {
        emergencyMode = true;
        emit CircuitBreakerToggled("EMERGENCY_MODE", true, block.timestamp);
    }

    /// @notice Disables emergency mode for the contract
    /// @dev Only callable by emergency admin
    function disableEmergencyMode() external onlyRole(EMERGENCY_ADMIN_ROLE) {
        emergencyMode = false;
        emit CircuitBreakerToggled("EMERGENCY_MODE", false, block.timestamp);
    }

    /// @notice Withdraws reward tokens in case of emergency
    /// @dev Only callable by emergency admin and only in emergency mode
    /// @param token Address of the reward token to withdraw
    /// @param amount Amount of tokens to withdraw
    /// @param recipient Address to receive the tokens
    /// @custom:security nonReentrant
    function emergencyWithdrawRewardToken(
        address token,
        uint256 amount,
        address recipient
    ) external
        nonReentrant
        onlyRole(EMERGENCY_ADMIN_ROLE)
        validRewardToken(token)
        validAmount(amount)
    {
        require(emergencyMode, "Not in emergency mode");
        require(recipient != address(0), "Invalid recipient");

        IERC20Metadata(token).safeTransfer(recipient, amount);

        emit EmergencyTokenWithdraw(token, recipient, amount, block.timestamp);
    }

    /// @notice Allows emergency withdrawal with fee
    /// @param periodIndex Index of the staking period to withdraw from
    /// @custom:security nonReentrant
    function emergencyWithdraw(uint256 periodIndex) external nonReentrant {
        require(emergencyMode, "Not in emergency mode");
        UserStake storage userStakeData = userStakes[msg.sender][periodIndex];
        if (!userStakeData.initialized) revert StakeNotFound();

        uint256 amount = userStakeData.amount;

        // Update state before transfers
        totalStakedForPeriod[periodIndex] -= amount;
        _totalUserStake[msg.sender] -= amount;
        delete userStakes[msg.sender][periodIndex];

        // Transfer full amount to user (no fee)
        stakingToken.safeTransfer(msg.sender, amount);

        // Emit event with zero fee
        emit EmergencyWithdraw(msg.sender, amount, 0, block.timestamp);
    }

    /// @notice Gets user stake information
    /// @dev Returns full stake struct
    /// @param user Address of the user
    /// @param periodIndex Index of the staking period
    /// @return UserStake struct containing stake details
    function getUserStake(address user, uint256 periodIndex) external view returns (UserStake memory) {
        return userStakes[user][periodIndex];
    }

    /// @notice Gets total amount staked by a user
    /// @dev Returns sum of all active stakes
    /// @param user Address of the user
    /// @return Total amount of tokens staked
    function getUserTotalStake(address user) external view returns (uint256) {
        return _totalUserStake[user];
    }

    /// @notice Gets total amount staked across all users
    /// @dev Returns sum of all stakes across all periods
    /// @return Total amount of tokens staked in the contract
    function getTotalStaked() external view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i <= MAX_PERIOD_INDEX; i++) {
            total += totalStakedForPeriod[i];
        }
        return total;
    }

    /// @notice Calculates pending rewards for a user
    /// @dev Includes both claimed and unclaimed rewards
    /// @param user Address of the user
    /// @param periodIndex Index of the staking period
    /// @param token Address of the reward token
    /// @return Amount of pending rewards
    function pendingRewards(address user, uint256 periodIndex, address token)
        external
        view
        returns (uint256)
    {
        RewardPool storage pool = rewardPools[periodIndex][token];
        UserStake storage userStakeData = userStakes[user][periodIndex];
        if (!userStakeData.initialized) {
            return 0;
        }

        uint256 accumulatedPerShare = pool.accumulatedPerShare;
        uint256 totalStaked = totalStakedForPeriod[periodIndex];

        uint256 lastTimeRewardApplicable = block.timestamp < pool.periodFinish ?
                                            block.timestamp : pool.periodFinish;

        if (totalStaked > 0 && pool.lastUpdateTime < lastTimeRewardApplicable) {
            uint256 timeDiff = lastTimeRewardApplicable - pool.lastUpdateTime;
            uint256 reward = timeDiff * pool.rewardRate;  // Total rewards for this period
            uint256 rewardPerShare = (reward * 1e18) / totalStaked;  // Scale up for precision
            accumulatedPerShare += rewardPerShare;
        }

        uint256 userPaid = userRewardPerSharePaid[user][periodIndex][token];
        uint256 pending = (userStakeData.amount * (accumulatedPerShare - userPaid)) / 1e18;
        return userRewards[user][periodIndex][token] + pending;
    }

    /// @notice Pauses all contract operations
    /// @dev Only callable by emergency admin
    function pause() external onlyRole(EMERGENCY_ADMIN_ROLE) {
        _pause();
    }

    /// @notice Unpauses contract operations
    /// @dev Only callable by emergency admin
    function unpause() external onlyRole(EMERGENCY_ADMIN_ROLE) {
        _unpause();
    }

    /// @notice Prevents reentrancy attacks
    /// @param circuit The circuit to check
    modifier whenCircuitActive(bytes32 circuit) {
        if (circuitBreakers[circuit]) {
            revert CircuitBreakerActive();
        }
        _;
    }

    /// @notice Prevents execution during emergency mode
    modifier notEmergency() {
        if (emergencyMode) {
            revert NotInEmergencyMode();
        }
        _;
    }

    /// @notice Validates if token is an accepted reward token
    modifier validRewardToken(address token) {
        if (!isRewardToken[token]) revert TokenNotRewardToken();
        _;
    }

    /// @notice Validates period index is within bounds
    modifier validPeriod(uint256 periodIndex) {
        if (periodIndex > MAX_PERIOD_INDEX) revert InvalidPeriod();
        _;
    }

    /// @notice Validates amount is greater than zero
    modifier validAmount(uint256 amount) {
        if (amount == 0) revert ZeroAmount();
        _;
    }

    /// @notice Gets all stakers for a specific period
    /// @dev Returns array of addresses that have staked in the period
    /// @param periodIndex Index of the staking period
    /// @return Array of staker addresses
    function getStakersForPeriod(uint256 periodIndex) external view returns (address[] memory) {
        return _stakersPerPeriod[periodIndex];
    }

    /// @notice Gets the number of stakers in a specific period
    /// @dev Returns count of unique stakers in the period
    /// @param periodIndex Index of the staking period
    /// @return Number of stakers
    function getStakerCountForPeriod(uint256 periodIndex) external view returns (uint256) {
        return _stakersPerPeriod[periodIndex].length;
    }

    /// @notice Checks if an address has staked in a specific period
    /// @dev Returns boolean indicating if address has staked
    /// @param periodIndex Index of the staking period
    /// @param staker Address to check
    /// @return True if address has staked in period
    function hasStakedInPeriod(uint256 periodIndex, address staker) external view returns (bool) {
        return _hasStakedInPeriod[periodIndex][staker];
    }

    /// @notice Checks if all reward pools are properly funded
    /// @return bool True if all pools are funded
    function areRewardPoolsFunded() public view returns (bool) {
        for (uint256 periodIndex = 0; periodIndex <= MAX_PERIOD_INDEX; periodIndex++) {
            for (uint256 i = 0; i < rewardTokens.length; i++) {
                address token = rewardTokens[i];
                RewardPool storage pool = rewardPools[periodIndex][token];
                if (pool.totalReward == 0 || pool.rewardRate == 0) {
                    return false;
                }
            }
        }
        return true;
    }

    /// @notice Starts staking by unpausing the contract if all conditions are met
    /// @dev Only callable by admin and only if reward pools are funded
    function startStaking() external onlyRole(ADMIN_ROLE) {
        require(areRewardPoolsFunded(), "Reward pools not funded");
        _unpause();
        emit StakingStarted(block.timestamp);
    }

    /// @notice Emergency stops staking by pausing the contract
    /// @dev Only callable by emergency admin
    function stopStaking() external onlyRole(EMERGENCY_ADMIN_ROLE) {
        _pause();
        emit StakingStopped(block.timestamp);
    }

    /// @notice Gets the current reward rate for a specific period and token
    /// @param periodIndex Index of the staking period
    /// @param token Address of the reward token
    /// @return Current reward rate per second
    function getRewardRate(uint256 periodIndex, address token)
        external view
        validRewardToken(token)
        returns (uint256)
    {
        require(periodIndex <= MAX_PERIOD_INDEX, "Invalid period index");
        require(isRewardToken[token], "Token not accepted as reward");
        return rewardPools[periodIndex][token].rewardRate;
    }

    /// @notice Gets detailed information about a reward pool
    /// @param periodIndex Index of the staking period
    /// @param token Address of the reward token
    /// @return totalReward Total amount of rewards allocated to this pool
    /// @return rewardRate Current reward rate per second
    /// @return periodFinish Timestamp when reward distribution ends
    /// @return totalDistributed Total amount of rewards distributed so far
    /// @return remainingRewards Remaining undistributed rewards in the pool
    function getRewardPoolInfo(uint256 periodIndex, address token)
        external
        view
        validRewardToken(token)
        returns (
            uint256 totalReward,
            uint256 rewardRate,
            uint256 periodFinish,
            uint256 totalDistributed,
            uint256 remainingRewards
        )
    {
        require(periodIndex <= MAX_PERIOD_INDEX, "Invalid period index");
        require(isRewardToken[token], "Token not accepted as reward");

        RewardPool storage pool = rewardPools[periodIndex][token];
        uint256 remaining = IERC20Metadata(token).balanceOf(address(this)) - pool.totalDistributed;

        return (
            pool.totalReward,
            pool.rewardRate,
            pool.periodFinish,
            pool.totalDistributed,
            remaining
        );
    }

    /// @notice Calculates the current APR for a staking period
    /// @param periodIndex Index of the staking period
    /// @param token Address of the reward token
    /// @return Annual Percentage Rate (scaled by PRECISION)
    function getAPR(uint256 periodIndex, address token)
        external
        view
        validPeriod(periodIndex)
        validRewardToken(token)
        returns (uint256)
    {
        RewardPool storage pool = rewardPools[periodIndex][token];
        uint256 totalStaked = totalStakedForPeriod[periodIndex];

        if (totalStaked == 0) return 0;

        // APR = (rewardRate * SECONDS_PER_YEAR * 100 * PRECISION) / totalStaked
        return (pool.rewardRate * SECONDS_PER_YEAR * 100 * PRECISION) / totalStaked;
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

        // Check for pending rewards across all periods
        for (uint256 periodIndex = 0; periodIndex <= MAX_PERIOD_INDEX; periodIndex++) {
            RewardPool storage pool = rewardPools[periodIndex][token];
            if (pool.totalReward > pool.totalDistributed) revert HasPendingRewards();
        }

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

        // Clean up pool data for all periods
        for (uint256 periodIndex = 0; periodIndex <= MAX_PERIOD_INDEX; periodIndex++) {
            delete rewardPools[periodIndex][token];
        }

        emit RewardTokenRemoved(token, block.timestamp);
    }

    /// @notice Recovers accidentally sent ERC20 tokens
    /// @dev Only callable by admin role. Cannot recover staking token or active reward tokens
    /// @param tokenAddress Address of the token to recover
    /// @param tokenAmount Amount of tokens to recover
    function recoverERC20(address tokenAddress, uint256 tokenAmount)
        external
        onlyRole(ADMIN_ROLE)
        nonReentrant
    {
        if (tokenAddress == address(stakingToken)) revert CannotRecoverStakingToken();
        if (isRewardToken[tokenAddress]) revert CannotRecoverRewardToken();

        IERC20Metadata(tokenAddress).safeTransfer(treasury, tokenAmount);

        emit Recovered(tokenAddress, tokenAmount, block.timestamp);
    }

    /// @notice Gets the amount staked by a user for a specific period
    /// @param user Address of the user to check
    /// @param periodIndex Index of the staking period
    /// @return Amount of tokens staked by the user in the specified period
    function getUserStakeForPeriod(
        address user,
        uint256 periodIndex
    ) external view
        validPeriod(periodIndex)
        returns (uint256)
    {
        UserStake storage userStake = userStakes[user][periodIndex];
        if (!userStake.initialized) return 0;
        return userStake.amount;
    }

    /// @notice Checks if all reward pools for a given period have finished their distribution period
    /// @param periodIndex Index of the staking period to check
    /// @return bool True if all reward pools for the period have finished distribution
    function isAllRewardPoolsFinished(uint256 periodIndex)
        public
        view
        returns (bool)
    {
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            address token = rewardTokens[i];
            RewardPool storage pool = rewardPools[periodIndex][token];
            if (block.timestamp < pool.periodFinish) {
                return false;
            }
        }
        return true;
    }

    /// @notice Upgrades a user's stake to a longer lock period
    /// @dev Claims all pending rewards from the current period before upgrading
    /// @param currentPeriodIndex The current staking period index
    /// @param newPeriodIndex The new staking period index to upgrade to
    function upgradeStakePeriod(uint256 currentPeriodIndex, uint256 newPeriodIndex)
        external
        nonReentrant
        whenNotPaused
        notEmergency
        validPeriod(currentPeriodIndex)
        validPeriod(newPeriodIndex)
    {
        require(lockPeriods[newPeriodIndex] > lockPeriods[currentPeriodIndex],
            "Can only upgrade to longer lock");

        UserStake storage currentStake = userStakes[msg.sender][currentPeriodIndex];
        if (!currentStake.initialized) revert StakeNotFound();

        _updateReward(msg.sender, currentPeriodIndex);

        _claimRewardsForPeriod(currentPeriodIndex);

        uint256 amount = currentStake.amount;
        uint256 newEndTime = block.timestamp + lockPeriods[newPeriodIndex];

        totalStakedForPeriod[currentPeriodIndex] -= amount;
        delete userStakes[msg.sender][currentPeriodIndex];

        UserStake storage newStake = userStakes[msg.sender][newPeriodIndex];

        if (newStake.initialized) {
            newStake.amount += uint128(amount);
        } else {
            userStakes[msg.sender][newPeriodIndex] = UserStake({
                amount: uint128(amount),
                startTime: uint48(block.timestamp),
                endTime: uint48(newEndTime),
                periodIndex: uint32(newPeriodIndex),
                initialized: true
            });

            if (!_hasStakedInPeriod[newPeriodIndex][msg.sender]) {
                _stakersPerPeriod[newPeriodIndex].push(msg.sender);
                _hasStakedInPeriod[newPeriodIndex][msg.sender] = true;
            }
        }

        totalStakedForPeriod[newPeriodIndex] += amount;

        emit StakeUpgraded(msg.sender, currentPeriodIndex, newPeriodIndex, amount, newEndTime);
    }

    /// @notice Internal function to claim rewards for a specific staking period
    /// @dev Transfers all pending rewards to the user and emits RewardPaid events
    /// @param periodIndex The staking period index to claim rewards from
    function _claimRewardsForPeriod(uint256 periodIndex) internal {
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            address token = rewardTokens[i];
            uint256 reward = userRewards[msg.sender][periodIndex][token];
            if (reward > 0) {
                userRewards[msg.sender][periodIndex][token] = 0;
                IERC20Metadata(token).safeTransfer(msg.sender, reward);
                emit RewardPaid(msg.sender, token, reward, periodIndex);
            }
        }
    }

    uint256[50] private __gap;
}
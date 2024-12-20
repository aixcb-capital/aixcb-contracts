import { expect } from "chai";
import { ethers } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import { AIXCBLPStaking, MockERC20 } from "../typechain-types";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

describe("AIXCBLPStaking Comprehensive Tests", () => {
    // Constants
    const SECONDS_PER_YEAR = 365 * 24 * 60 * 60;
    const TIME_BUFFER = 2;
    const INITIAL_REWARD_AMOUNT = ethers.parseEther("1000000");
    const EMERGENCY_WITHDRAW_FEE = 2000; // 20%

    // Contract instances
    let staking: AIXCBLPStaking;
    let lpToken: MockERC20;
    let rewardTokenA: MockERC20;
    let rewardTokenB: MockERC20;
    let rewardTokenC: MockERC20;

    // Signers
    let owner: SignerWithAddress;
    let users: SignerWithAddress[];
    let treasury: SignerWithAddress;

    beforeEach(async () => {
        [owner, ...users] = await ethers.getSigners();
        treasury = users[users.length - 1];

        // Deploy mock tokens
        const MockToken = await ethers.getContractFactory("MockERC20");
        lpToken = await MockToken.deploy("Aerodrome LP", "aLP");
        rewardTokenA = await MockToken.deploy("Token A", "TKA");
        rewardTokenB = await MockToken.deploy("Token B", "TKB");
        rewardTokenC = await MockToken.deploy("Token C", "TKC");

        // Deploy staking implementation
        const Staking = await ethers.getContractFactory("AIXCBLPStaking");
        const stakingImpl = await Staking.deploy();

        // Initialize implementation
        const initData = Staking.interface.encodeFunctionData("initialize", [
            await lpToken.getAddress(),
            [
                await rewardTokenA.getAddress(),
                await rewardTokenB.getAddress(),
                await rewardTokenC.getAddress()
            ],
            treasury.address
        ]);

        // Deploy proxy
        const TransparentProxy = await ethers.getContractFactory("TransparentUpgradeableProxy");
        const proxy = await TransparentProxy.deploy(
            await stakingImpl.getAddress(),
            owner.address,
            initData
        );

        staking = Staking.attach(await proxy.getAddress()) as AIXCBLPStaking;

        // Setup initial token balances and approvals
        await setupTokensAndApprovals();
    });

    async function setupTokensAndApprovals() {
        // Mint reward tokens to owner
        await rewardTokenA.mint(owner.address, ethers.parseEther("10000000"));
        await rewardTokenB.mint(owner.address, ethers.parseEther("10000000"));
        await rewardTokenC.mint(owner.address, ethers.parseEther("10000000"));

        // Approve reward tokens
        await rewardTokenA.approve(await staking.getAddress(), ethers.parseEther("10000000"));
        await rewardTokenB.approve(await staking.getAddress(), ethers.parseEther("10000000"));
        await rewardTokenC.approve(await staking.getAddress(), ethers.parseEther("10000000"));

        // Mint LP tokens to users
        for (const user of users.slice(0, -1)) {
            await lpToken.mint(user.address, ethers.parseEther("1000000"));
            await lpToken.connect(user).approve(await staking.getAddress(), ethers.parseEther("1000000"));
        }

        // Unpause contract first
        await staking.unpause();

        // Fund reward pools after unpausing
        await staking.fundRewardPool(await rewardTokenA.getAddress(), INITIAL_REWARD_AMOUNT);
        await staking.fundRewardPool(await rewardTokenB.getAddress(), INITIAL_REWARD_AMOUNT);
        await staking.fundRewardPool(await rewardTokenC.getAddress(), INITIAL_REWARD_AMOUNT);
    }

    describe("Initialization & Setup", () => {
        it("should initialize with correct parameters", async () => {
            expect(await staking.lpToken()).to.equal(await lpToken.getAddress());
            expect(await staking.treasury()).to.equal(treasury.address);
            
            const rewardTokens = await staking.getRewardTokens();
            expect(rewardTokens).to.have.lengthOf(3);
            expect(rewardTokens).to.include(await rewardTokenA.getAddress());
            expect(rewardTokens).to.include(await rewardTokenB.getAddress());
            expect(rewardTokens).to.include(await rewardTokenC.getAddress());
        });

        it("should set up correct roles", async () => {
            expect(await staking.hasRole(await staking.DEFAULT_ADMIN_ROLE(), owner.address)).to.be.true;
            expect(await staking.hasRole(await staking.ADMIN_ROLE(), owner.address)).to.be.true;
            expect(await staking.hasRole(await staking.EMERGENCY_ADMIN_ROLE(), owner.address)).to.be.true;
            expect(await staking.hasRole(await staking.REWARD_MANAGER_ROLE(), owner.address)).to.be.true;
        });

        it("should have correct initial state", async () => {
            expect(await staking.paused()).to.be.false;
            expect(await staking.emergencyMode()).to.be.false;
            expect(await staking.totalStakedAmount()).to.equal(0);
        });
    });

    describe("Staking Mechanics", () => {
        it("should handle basic stake correctly", async () => {
            const user = users[0];
            const amount = ethers.parseEther("1000");

            const balanceBefore = await lpToken.balanceOf(user.address);
            await staking.connect(user).stake(amount);
            const balanceAfter = await lpToken.balanceOf(user.address);

            expect(balanceAfter).to.equal(balanceBefore - amount);
            expect(await staking.totalStakedAmount()).to.equal(amount);

            const userStake = await staking.userStakes(user.address);
            expect(userStake.stakedAmount).to.equal(amount);
            expect(userStake.initialStakeTime).to.be.gt(0);
        });

        it("should handle multiple stakes from same user", async () => {
            const user = users[0];
            const amount1 = ethers.parseEther("1000");
            const amount2 = ethers.parseEther("2000");

            await staking.connect(user).stake(amount1);
            await staking.connect(user).stake(amount2);

            const userStake = await staking.userStakes(user.address);
            expect(userStake.stakedAmount).to.equal(amount1 + amount2);
            expect(await staking.totalStakedAmount()).to.equal(amount1 + amount2);
        });

        it("should enforce staking limits", async () => {
            const user = users[0];
            
            // Test zero amount
            await expect(staking.connect(user).stake(0))
                .to.be.revertedWithCustomError(staking, "ZeroAmount");

            // Test max stake
            const maxStake = await staking.MAX_STAKE_AMOUNT();
            await expect(staking.connect(user).stake(maxStake + 1n))
                .to.be.revertedWithCustomError(staking, "ExceedsMaxStake");
        });
    });

    describe("Reward Distribution", () => {
        it("should calculate and distribute rewards correctly", async () => {
            const user = users[0];
            const amount = ethers.parseEther("1000");

            await staking.connect(user).stake(amount);
            await time.increase(30 * 24 * 60 * 60); // 30 days

            const pendingRewards = await staking.getPendingRewards(user.address, await rewardTokenA.getAddress());
            expect(pendingRewards).to.be.gt(0);

            const balanceBefore = await rewardTokenA.balanceOf(user.address);
            await staking.connect(user).claimRewards();
            const balanceAfter = await rewardTokenA.balanceOf(user.address);

            expect(balanceAfter).to.be.gt(balanceBefore);
            expect(balanceAfter - balanceBefore).to.be.closeTo(pendingRewards, ethers.parseEther("0.1"));
        });

        it("should distribute rewards proportionally with multiple stakers", async () => {
            const [user1, user2] = users;
            const amount1 = ethers.parseEther("1000");
            const amount2 = ethers.parseEther("2000");

            // User1 stakes first
            await staking.connect(user1).stake(amount1);
            await time.increase(15 * 24 * 60 * 60); // 15 days

            // User2 stakes double the amount
            await staking.connect(user2).stake(amount2);
            
            // Both earn rewards for the same period
            await time.increase(15 * 24 * 60 * 60); // Another 15 days

            // Claim rewards for both users
            await staking.connect(user1).claimRewards();
            await staking.connect(user2).claimRewards();

            // Check final balances
            const user1Balance = await rewardTokenA.balanceOf(user1.address);
            const user2Balance = await rewardTokenA.balanceOf(user2.address);

            // User2 should have approximately 0.5x rewards since they staked for half the time
            const ratio = Number(user2Balance) / Number(user1Balance);
            expect(ratio).to.be.closeTo(0.5, 0.1);
        });

        it("should handle multiple reward tokens correctly", async () => {
            const user = users[0];
            const amount = ethers.parseEther("1000");

            await staking.connect(user).stake(amount);
            await time.increase(30 * 24 * 60 * 60); // 30 days

            const rewardTokens = [
                await rewardTokenA.getAddress(),
                await rewardTokenB.getAddress(),
                await rewardTokenC.getAddress()
            ];

            for (const token of rewardTokens) {
                const pending = await staking.getPendingRewards(user.address, token);
                expect(pending).to.be.gt(0);
            }

            await staking.connect(user).claimRewards();

            for (const token of rewardTokens) {
                const contract = await ethers.getContractAt("MockERC20", token);
                const balance = await contract.balanceOf(user.address);
                expect(balance).to.be.gt(0);
            }
        });
    });

    describe("Withdrawal Mechanics", () => {
        it("should handle basic withdrawal correctly", async () => {
            const user = users[0];
            const amount = ethers.parseEther("1000");

            await staking.connect(user).stake(amount);
            const balanceBefore = await lpToken.balanceOf(user.address);
            
            await staking.connect(user).withdraw(amount);
            const balanceAfter = await lpToken.balanceOf(user.address);

            expect(balanceAfter - balanceBefore).to.equal(amount);
            expect(await staking.totalStakedAmount()).to.equal(0);
        });

        it("should prevent excessive withdrawal", async () => {
            const user = users[0];
            const amount = ethers.parseEther("1000");

            await staking.connect(user).stake(amount);
            await expect(staking.connect(user).withdraw(amount + 1n))
                .to.be.revertedWithCustomError(staking, "InvalidAmount");
        });

        it("should handle emergency withdrawal correctly", async () => {
            const user = users[0];
            const amount = ethers.parseEther("1000");

            await staking.connect(user).stake(amount);
            await staking.connect(owner).enableEmergencyMode();

            const balanceBefore = await lpToken.balanceOf(user.address);
            const treasuryBalanceBefore = await lpToken.balanceOf(treasury.address);

            await staking.connect(user).emergencyWithdraw();

            const balanceAfter = await lpToken.balanceOf(user.address);
            const treasuryBalanceAfter = await lpToken.balanceOf(treasury.address);

            const withdrawnAmount = balanceAfter - balanceBefore;
            const fee = treasuryBalanceAfter - treasuryBalanceBefore;

            expect(withdrawnAmount + fee).to.equal(amount);
            expect(fee).to.equal(amount * BigInt(EMERGENCY_WITHDRAW_FEE) / 10000n);
        });
    });

    describe("Loyalty & Engagement", () => {
        it("should track loyalty metrics correctly", async () => {
            const user = users[0];
            const amount = ethers.parseEther("1000");

            await staking.connect(user).stake(amount);

            // Get loyalty stats struct
            const stats = await staking.loyaltyStats(user.address);

            // Check that values are reasonable
            expect(Number(stats.stakingPower)).to.be.gt(0);
            expect(Number(stats.currentStreak)).to.be.gt(0);
            expect(Number(stats.totalStakingDays)).to.be.gt(0);
            expect(Number(stats.lastUpdateTime)).to.be.gt(0);
            expect(Number(stats.engagementScore)).to.be.gt(0);
        });

        it("should track loyalty streaks correctly", async () => {
            const user = users[0];
            const amount = ethers.parseEther("1000");

            // First stake
            await staking.connect(user).stake(amount);
            const initialStats = await staking.loyaltyStats(user.address);
            expect(Number(initialStats.currentStreak)).to.equal(1);

            // Advance time and make another stake
            await time.increase(24 * 60 * 60); // 1 day
            await staking.connect(user).stake(amount);
            const afterSecondStake = await staking.loyaltyStats(user.address);
            expect(Number(afterSecondStake.currentStreak)).to.equal(2);

            // Withdraw all and check streak
            await staking.connect(user).withdraw(amount * 2n);
            const afterWithdraw = await staking.loyaltyStats(user.address);
            // The streak should stay at 2 since withdrawals don't reset streaks in this contract
            expect(Number(afterWithdraw.currentStreak)).to.equal(2);
        });
    });

    describe("Emergency Controls", () => {
        it("should handle circuit breakers correctly", async () => {
            const user = users[0];
            const amount = ethers.parseEther("1000");

            await staking.connect(owner).toggleCircuitBreaker(await staking.STAKING_CIRCUIT());
            await expect(staking.connect(user).stake(amount))
                .to.be.revertedWithCustomError(staking, "CircuitBreakerActive");

            await staking.connect(owner).toggleCircuitBreaker(await staking.STAKING_CIRCUIT());
            await expect(staking.connect(user).stake(amount)).to.not.be.reverted;
        });

        it("should handle emergency mode correctly", async () => {
            const user = users[0];
            const amount = ethers.parseEther("1000");

            await staking.connect(user).stake(amount);
            await staking.connect(owner).enableEmergencyMode();

            // Regular withdrawal should be blocked
            await expect(staking.connect(user).withdraw(amount))
                .to.be.revertedWithCustomError(staking, "EmergencyModeActive");

            // Emergency withdrawal should work
            await expect(staking.connect(user).emergencyWithdraw())
                .to.not.be.reverted;
        });

        it("should recover accidentally sent tokens", async () => {
            const amount = ethers.parseEther("1000");
            const randomToken = await (await ethers.getContractFactory("MockERC20")).deploy("Random", "RND");
            await randomToken.mint(staking.getAddress(), amount);

            const balanceBefore = await randomToken.balanceOf(treasury.address);
            await staking.connect(owner).recoverERC20(await randomToken.getAddress(), amount);
            const balanceAfter = await randomToken.balanceOf(treasury.address);

            expect(balanceAfter - balanceBefore).to.equal(amount);
        });
    });

    describe("Reward Pool Management", () => {
        it("should handle reward pool funding correctly", async () => {
            const amount = ethers.parseEther("500000");
            const token = await rewardTokenA.getAddress();

            const poolBefore = await staking.getRewardPool(token);

            await staking.connect(owner).fundRewardPool(token, amount);

            const poolAfter = await staking.getRewardPool(token);

            // Calculate expected rate based on total remaining rewards
            const remainingRewards = BigInt(poolAfter.totalReward) - BigInt(poolAfter.distributed);
            const expectedRate = remainingRewards / BigInt(SECONDS_PER_YEAR);

            // Check total reward increased
            expect(BigInt(poolAfter.totalReward)).to.equal(BigInt(poolBefore.totalReward) + amount);
            
            // Check reward rate with 1% tolerance
            const tolerance = expectedRate / 100n;
            expect(BigInt(poolAfter.ratePerSecond)).to.be.closeTo(expectedRate, tolerance);
        });

        it("should handle reward token removal correctly", async () => {
            const token = await rewardTokenA.getAddress();
            
            // First distribute all rewards
            const user = users[0];
            await staking.connect(user).stake(ethers.parseEther("1000"));
            await time.increase(SECONDS_PER_YEAR);
            await staking.connect(user).claimRewards();

            await staking.connect(owner).removeRewardToken(token);
            expect(await staking.isRewardToken(token)).to.be.false;

            const rewardTokens = await staking.getRewardTokens();
            expect(rewardTokens).to.not.include(token);
        });

        it("should prevent removing reward token with pending rewards", async () => {
            const token = await rewardTokenA.getAddress();
            
            const user = users[0];
            await staking.connect(user).stake(ethers.parseEther("1000"));
            await time.increase(30 * 24 * 60 * 60); // 30 days

            await expect(staking.connect(owner).removeRewardToken(token))
                .to.be.revertedWithCustomError(staking, "HasPendingRewards");
        });
    });
}); 
import { expect } from "chai";
import { ethers } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import { AIXCBStaking, MockERC20 } from "../typechain-types";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

describe("AIXCBStaking Comprehensive Tests", () => {
    // Constants
    const NINETY_DAYS = 90 * 24 * 60 * 60;
    const ONE_HUNDRED_EIGHTY_DAYS = 180 * 24 * 60 * 60;
    const THREE_SIXTY_DAYS = 360 * 24 * 60 * 60;
    const SECONDS_PER_YEAR = 365 * 24 * 60 * 60;
    const TIME_BUFFER = 2;
    const VIP_THRESHOLD = ethers.parseEther("1000000");
    const INITIAL_REWARD_AMOUNT = ethers.parseEther("1000000");

    // Contract instances
    let staking: AIXCBStaking;
    let stakingToken: MockERC20;
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
        stakingToken = await MockToken.deploy("AIXCB Token", "AIXCB");
        rewardTokenB = await MockToken.deploy("Token B", "TKB");
        rewardTokenC = await MockToken.deploy("Token C", "TKC");

        // Deploy staking implementation
        const Staking = await ethers.getContractFactory("AIXCBStaking");
        const stakingImpl = await Staking.deploy();

        // Initialize implementation
        const initData = Staking.interface.encodeFunctionData("initialize", [
            await stakingToken.getAddress(),
            [
                await stakingToken.getAddress(),
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

        staking = Staking.attach(await proxy.getAddress()) as AIXCBStaking;

        // Setup initial token balances and approvals
        await setupTokensAndApprovals();
    });

    async function setupTokensAndApprovals() {
        // Mint tokens to owner for reward pools
        await stakingToken.mint(owner.address, ethers.parseEther("10000000"));
        await rewardTokenB.mint(owner.address, ethers.parseEther("10000000"));
        await rewardTokenC.mint(owner.address, ethers.parseEther("10000000"));

        // Approve reward pool funding
        await stakingToken.approve(await staking.getAddress(), ethers.parseEther("10000000"));
        await rewardTokenB.approve(await staking.getAddress(), ethers.parseEther("10000000"));
        await rewardTokenC.approve(await staking.getAddress(), ethers.parseEther("10000000"));

        // Fund reward pools for each period
        for (let i = 0; i <= 2; i++) {
            await staking.fundRewardPool(i, await stakingToken.getAddress(), INITIAL_REWARD_AMOUNT);
            await staking.fundRewardPool(i, await rewardTokenB.getAddress(), INITIAL_REWARD_AMOUNT);
            await staking.fundRewardPool(i, await rewardTokenC.getAddress(), INITIAL_REWARD_AMOUNT);
        }

        // Mint and approve tokens for test users
        for (const user of users.slice(0, -1)) {
            await stakingToken.mint(user.address, ethers.parseEther("1000000"));
            await stakingToken.connect(user).approve(await staking.getAddress(), ethers.parseEther("1000000"));
        }

        // Unpause contract
        await staking.unpause();
    }

    describe("Initialization & Setup", () => {
        it("should initialize with correct parameters", async () => {
            expect(await staking.stakingToken()).to.equal(await stakingToken.getAddress());
            expect(await staking.treasury()).to.equal(treasury.address);
            
            expect(await staking.rewardTokens(0)).to.equal(await stakingToken.getAddress());
            expect(await staking.rewardTokens(1)).to.equal(await rewardTokenB.getAddress());
            expect(await staking.rewardTokens(2)).to.equal(await rewardTokenC.getAddress());
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
            
            for (let i = 0; i <= 2; i++) {
                const pool = await staking.getRewardPoolInfo(i, await stakingToken.getAddress());
                expect(pool.totalReward).to.equal(INITIAL_REWARD_AMOUNT);
            }
        });
    });

    describe("Staking Mechanics", () => {
        it("should handle single stake correctly", async () => {
            const amount = ethers.parseEther("1000");
            const user = users[0];
            const startTime = await time.latest();

            await staking.connect(user).stake({
                amount,
                periodIndex: 0,
                deadline: startTime + 3600,
                minRate: 0
            });

            const userStake = await staking.getUserStake(user.address, 0);
            expect(userStake.amount).to.equal(amount);
            expect(userStake.initialized).to.be.true;
            expect(Number(userStake.startTime)).to.be.closeTo(startTime, 2);
            expect(Number(userStake.endTime)).to.be.closeTo(startTime + NINETY_DAYS, 2);
        });

        it("should handle multiple stakes in different periods", async () => {
            const user = users[0];
            const amounts = [
                ethers.parseEther("1000"),
                ethers.parseEther("2000"),
                ethers.parseEther("3000")
            ];

            for (let i = 0; i <= 2; i++) {
                await staking.connect(user).stake({
                    amount: amounts[i],
                    periodIndex: i,
                    deadline: (await time.latest()) + 3600,
                    minRate: 0
                });

                const userStake = await staking.getUserStake(user.address, i);
                expect(userStake.amount).to.equal(amounts[i]);
                expect(userStake.periodIndex).to.equal(i);
            }

            expect(await staking.getUserTotalStake(user.address))
                .to.equal(amounts.reduce((a, b) => a + b));
        });

        it("should enforce staking limits and conditions", async () => {
            const user = users[0];
            const amount = ethers.parseEther("1000");

            // Test expired deadline
            const pastDeadline = (await time.latest()) - 3600;
            await expect(staking.connect(user).stake({
                amount,
                periodIndex: 0,
                deadline: pastDeadline,
                minRate: 0
            })).to.be.revertedWithCustomError(staking, "DeadlineExpired");

            // Test zero amount
            await expect(staking.connect(user).stake({
                amount: 0,
                periodIndex: 0,
                deadline: (await time.latest()) + 3600,
                minRate: 0
            })).to.be.revertedWithCustomError(staking, "ZeroAmount");

            // Test invalid period
            await expect(staking.connect(user).stake({
                amount,
                periodIndex: 3,
                deadline: (await time.latest()) + 3600,
                minRate: 0
            })).to.be.revertedWithCustomError(staking, "InvalidPeriod");
        });
    });

    describe("Reward Distribution", () => {
        it("should calculate and distribute rewards correctly", async () => {
            const user = users[0];
            const amount = ethers.parseEther("1000");

            await staking.connect(user).stake({
                amount,
                periodIndex: 0,
                deadline: (await time.latest()) + 3600,
                minRate: 0
            });

            await time.increase(30 * 24 * 60 * 60); // 30 days

            const pendingRewards = await staking.pendingRewards(user.address, 0, await stakingToken.getAddress());
            expect(pendingRewards).to.be.gt(0);

            const balanceBefore = await stakingToken.balanceOf(user.address);
            await staking.connect(user).claimRewards(0);
            const balanceAfter = await stakingToken.balanceOf(user.address);

            expect(balanceAfter).to.be.gt(balanceBefore);
            // Use a larger tolerance for reward comparison due to block timestamp variations
            expect(balanceAfter - balanceBefore).to.be.closeTo(pendingRewards, ethers.parseEther("1"));
        });

        it("should handle multiple reward tokens correctly", async () => {
            const user = users[0];
            const amount = ethers.parseEther("1000");

            await staking.connect(user).stake({
                amount,
                periodIndex: 0,
                deadline: (await time.latest()) + 3600,
                minRate: 0
            });

            await time.increase(30 * 24 * 60 * 60); // 30 days

            const rewardTokens = [
                await stakingToken.getAddress(),
                await rewardTokenB.getAddress(),
                await rewardTokenC.getAddress()
            ];

            for (const token of rewardTokens) {
                const pending = await staking.pendingRewards(user.address, 0, token);
                expect(pending).to.be.gt(0);
            }

            await staking.connect(user).claimRewards(0);

            for (const token of rewardTokens) {
                const contract = await ethers.getContractAt("MockERC20", token);
                const balance = await contract.balanceOf(user.address);
                expect(balance).to.be.gt(0);
            }
        });

        it("should distribute rewards proportionally with multiple stakers", async () => {
            const [user1, user2] = users;
            const amount1 = ethers.parseEther("1000");
            const amount2 = ethers.parseEther("2000");

            // User1 stakes first
            await staking.connect(user1).stake({
                amount: amount1,
                periodIndex: 0,
                deadline: (await time.latest()) + 3600,
                minRate: 0
            });

            // Check initial rewards
            const initialRewards1 = await staking.pendingRewards(user1.address, 0, await stakingToken.getAddress());

            await time.increase(15 * 24 * 60 * 60); // 15 days
            const midRewards1 = await staking.pendingRewards(user1.address, 0, await stakingToken.getAddress());

            // User2 stakes double the amount
            await staking.connect(user2).stake({
                amount: amount2,
                periodIndex: 0,
                deadline: (await time.latest()) + 3600,
                minRate: 0
            });

            await time.increase(15 * 24 * 60 * 60); // Another 15 days

            const finalRewards1 = await staking.pendingRewards(user1.address, 0, await stakingToken.getAddress());
            const finalRewards2 = await staking.pendingRewards(user2.address, 0, await stakingToken.getAddress());

            const ratio = Number(finalRewards2) / Number(finalRewards1);
            // User2 should have ~0.5x rewards since they staked for half the time
            expect(ratio).to.be.closeTo(0.5, 0.1);
        });
    });

    describe("Withdrawal Mechanics", () => {
        it("should prevent early withdrawal", async () => {
            const user = users[0];
            const amount = ethers.parseEther("1000");

            await staking.connect(user).stake({
                amount,
                periodIndex: 0,
                deadline: (await time.latest()) + 3600,
                minRate: 0
            });

            await time.increase(30 * 24 * 60 * 60); // 30 days

            await expect(staking.connect(user).withdraw(0))
                .to.be.revertedWithCustomError(staking, "StakeLocked");
        });

        it("should allow withdrawal after lock period", async () => {
            const user = users[0];
            const amount = ethers.parseEther("1000");

            // Record initial balance
            const initialBalance = await stakingToken.balanceOf(user.address);

            await staking.connect(user).stake({
                amount,
                periodIndex: 0,
                deadline: (await time.latest()) + 3600,
                minRate: 0
            });

            const userStake = await staking.getUserStake(user.address, 0);

            await time.increase(NINETY_DAYS + 1);

            // Get balances before withdrawal
            const stakingBalanceBefore = await stakingToken.balanceOf(user.address);
            const stakingContractBalance = await stakingToken.balanceOf(await staking.getAddress());

            // Get pending rewards before withdrawal
            const pendingRewards = await staking.pendingRewards(user.address, 0, await stakingToken.getAddress());

            // Then withdraw stake
            await staking.connect(user).withdraw(0);

            const finalBalance = await stakingToken.balanceOf(user.address);

            // The withdrawal amount should equal the staked amount plus any accrued rewards
            const withdrawalAmount = finalBalance - stakingBalanceBefore;
            expect(withdrawalAmount).to.be.closeTo(amount + pendingRewards, ethers.parseEther("0.1"));

            // Verify the stake is cleared
            const stakeAfter = await staking.getUserStake(user.address, 0);
            expect(stakeAfter.amount).to.equal(0);
            expect(stakeAfter.initialized).to.be.false;
        });

        it("should handle emergency withdrawal correctly", async () => {
            const user = users[0];
            const amount = ethers.parseEther("1000");

            await staking.connect(user).stake({
                amount,
                periodIndex: 0,
                deadline: (await time.latest()) + 3600,
                minRate: 0
            });

            await staking.connect(owner).enableEmergencyMode();

            const balanceBefore = await stakingToken.balanceOf(user.address);
            const treasuryBalanceBefore = await stakingToken.balanceOf(treasury.address);

            await staking.connect(user).emergencyWithdraw(0);

            const balanceAfter = await stakingToken.balanceOf(user.address);
            const treasuryBalanceAfter = await stakingToken.balanceOf(treasury.address);

            const withdrawnAmount = balanceAfter - balanceBefore;
            const fee = treasuryBalanceAfter - treasuryBalanceBefore;

            expect(withdrawnAmount + fee).to.equal(amount);
            expect(fee).to.equal(amount * BigInt(2000) / BigInt(10000)); // 20% fee
        });
    });

    describe("VIP Status & Loyalty", () => {
        it("should track VIP status correctly", async () => {
            const user = users[0];
            
            // Stake below VIP threshold
            await staking.connect(user).stake({
                amount: VIP_THRESHOLD - ethers.parseEther("1000"),
                periodIndex: 0,
                deadline: (await time.latest()) + 3600,
                minRate: 0
            });

            expect(await staking.isVIP(user.address)).to.be.false;

            // Stake to reach VIP threshold
            await staking.connect(user).stake({
                amount: ethers.parseEther("1000"),
                periodIndex: 0,
                deadline: (await time.latest()) + 3600,
                minRate: 0
            });

            expect(await staking.isVIP(user.address)).to.be.true;
        });

        it("should update loyalty metrics correctly", async () => {
            const user = users[0];
            const amount = ethers.parseEther("1000");

            await staking.connect(user).stake({
                amount,
                periodIndex: 0,
                deadline: (await time.latest()) + 3600,
                minRate: 0
            });

            const stats = await staking.loyaltyStats(user.address);
            expect(stats.stakingPower).to.be.gt(0);
            expect(stats.currentStreak).to.be.gt(0);
            expect(stats.totalStakingDays).to.be.gt(0);
        });
    });

    describe("Emergency Controls", () => {
        it("should handle circuit breakers correctly", async () => {
            const user = users[0];
            const amount = ethers.parseEther("1000");

            await staking.connect(owner).toggleCircuitBreaker(await staking.STAKING_CIRCUIT());

            await expect(staking.connect(user).stake({
                amount,
                periodIndex: 0,
                deadline: (await time.latest()) + 3600,
                minRate: 0
            })).to.be.revertedWithCustomError(staking, "CircuitBreakerActive");
        });

        it("should handle emergency mode correctly", async () => {
            const user = users[0];
            const amount = ethers.parseEther("1000");

            await staking.connect(user).stake({
                amount,
                periodIndex: 0,
                deadline: (await time.latest()) + 3600,
                minRate: 0
            });

            await staking.connect(owner).enableEmergencyMode();

            // Regular withdrawal should be blocked
            await expect(staking.connect(user).withdraw(0))
                .to.be.revertedWithCustomError(staking, "NotInEmergencyMode");

            // Emergency withdrawal should work
            await expect(staking.connect(user).emergencyWithdraw(0))
                .to.not.be.reverted;
        });
    });

    describe("Reward Pool Management", () => {
        it("should handle reward pool funding correctly", async () => {
            const amount = ethers.parseEther("500000");
            const token = await stakingToken.getAddress();

            const poolBefore = await staking.getRewardPoolInfo(0, token);

            await staking.connect(owner).fundRewardPool(0, token, amount);

            const poolAfter = await staking.getRewardPoolInfo(0, token);

            const expectedRate = amount / BigInt(SECONDS_PER_YEAR);

            // Check total reward increased
            expect(poolAfter.totalReward).to.equal(poolBefore.totalReward + amount);
            
            // Check reward rate matches expected rate
            expect(poolAfter.rewardRate).to.equal(expectedRate);
        });

        it("should calculate APR correctly", async () => {
            const user = users[0];
            const amount = ethers.parseEther("1000");

            await staking.connect(user).stake({
                amount,
                periodIndex: 0,
                deadline: (await time.latest()) + 3600,
                minRate: 0
            });

            const apr = await staking.getAPR(0, await stakingToken.getAddress());
            expect(apr).to.be.gt(0);
        });
    });
}); 
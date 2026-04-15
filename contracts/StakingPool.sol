// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title StakingPool
 * @notice 通用质押挖矿合约
 *
 * 支持:
 *   - 质押 stakeToken 获得 rewardToken 奖励
 *   - 动态奖励速率（rewardPerSecond）
 *   - 锁定期设置（lockPeriod）
 *   - 紧急提款（forfeits pending rewards）
 */
contract StakingPool is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20  public immutable stakeToken;
    IERC20  public immutable rewardToken;

    uint256 public rewardPerSecond;     // 每秒发出的奖励代币数量（含 decimals）
    uint256 public lockPeriod;          // 质押锁定时间（秒）

    uint256 public totalStaked;
    uint256 public accRewardPerShare;   // 累计每股奖励 * PRECISION
    uint256 public lastUpdateTime;
    uint256 private constant PRECISION = 1e12;

    uint256 public startTime;
    uint256 public endTime;

    struct UserInfo {
        uint256 amount;         // 质押量
        uint256 rewardDebt;     // 已计算奖励基准
        uint256 stakeTime;      // 最新质押时间（用于锁定期）
        uint256 pendingReward;  // 已结算但未领取
    }
    mapping(address => UserInfo) public userInfo;

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 amount);
    event RewardRateUpdated(uint256 rewardPerSecond);

    constructor(
        address stakeToken_,
        address rewardToken_,
        uint256 rewardPerSecond_,
        uint256 startTime_,
        uint256 endTime_,
        uint256 lockPeriod_
    ) {
        require(startTime_ < endTime_, "Invalid time range");
        stakeToken     = IERC20(stakeToken_);
        rewardToken    = IERC20(rewardToken_);
        rewardPerSecond = rewardPerSecond_;
        startTime      = startTime_;
        endTime        = endTime_;
        lockPeriod     = lockPeriod_;
        lastUpdateTime = startTime_;
    }

    // ─── 读取函数 ─────────────────────────────────────────
    function pendingReward(address user) external view returns (uint256) {
        UserInfo memory u = userInfo[user];
        uint256 acc = accRewardPerShare;
        if (block.timestamp > lastUpdateTime && totalStaked > 0) {
            uint256 elapsed = _elapsed(lastUpdateTime, block.timestamp);
            acc += elapsed * rewardPerSecond * PRECISION / totalStaked;
        }
        return u.pendingReward + (u.amount * acc / PRECISION) - u.rewardDebt;
    }

    // ─── 质押 ─────────────────────────────────────────────
    function stake(uint256 amount) external nonReentrant {
        require(amount > 0, "Zero amount");
        require(block.timestamp >= startTime, "Not started");
        require(block.timestamp < endTime, "Pool ended");

        _updatePool();

        UserInfo storage u = userInfo[msg.sender];

        // 结算旧奖励
        if (u.amount > 0) {
            uint256 pending = u.amount * accRewardPerShare / PRECISION - u.rewardDebt;
            u.pendingReward += pending;
        }

        stakeToken.safeTransferFrom(msg.sender, address(this), amount);
        u.amount     += amount;
        u.stakeTime   = block.timestamp;
        u.rewardDebt  = u.amount * accRewardPerShare / PRECISION;
        totalStaked  += amount;

        emit Staked(msg.sender, amount);
    }

    // ─── 取回质押 ─────────────────────────────────────────
    function unstake(uint256 amount) external nonReentrant {
        UserInfo storage u = userInfo[msg.sender];
        require(u.amount >= amount, "Insufficient staked");
        require(block.timestamp >= u.stakeTime + lockPeriod, "Still locked");

        _updatePool();

        uint256 pending = u.amount * accRewardPerShare / PRECISION - u.rewardDebt;
        u.pendingReward += pending;

        u.amount     -= amount;
        totalStaked  -= amount;
        u.rewardDebt  = u.amount * accRewardPerShare / PRECISION;

        stakeToken.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    // ─── 领取奖励 ─────────────────────────────────────────
    function claimReward() external nonReentrant {
        _updatePool();
        UserInfo storage u = userInfo[msg.sender];
        uint256 pending = u.pendingReward + u.amount * accRewardPerShare / PRECISION - u.rewardDebt;
        require(pending > 0, "Nothing to claim");
        u.pendingReward = 0;
        u.rewardDebt    = u.amount * accRewardPerShare / PRECISION;
        rewardToken.safeTransfer(msg.sender, pending);
        emit RewardClaimed(msg.sender, pending);
    }

    // ─── 紧急提款（放弃奖励） ──────────────────────────────
    function emergencyWithdraw() external nonReentrant {
        UserInfo storage u = userInfo[msg.sender];
        uint256 amount = u.amount;
        require(amount > 0, "Nothing staked");
        totalStaked    -= amount;
        u.amount        = 0;
        u.rewardDebt    = 0;
        u.pendingReward = 0;
        stakeToken.safeTransfer(msg.sender, amount);
        emit EmergencyWithdraw(msg.sender, amount);
    }

    // ─── 内部：更新奖励池 ──────────────────────────────────
    function _updatePool() internal {
        if (block.timestamp <= lastUpdateTime) return;
        if (totalStaked == 0) {
            lastUpdateTime = block.timestamp;
            return;
        }
        uint256 elapsed = _elapsed(lastUpdateTime, block.timestamp);
        accRewardPerShare += elapsed * rewardPerSecond * PRECISION / totalStaked;
        lastUpdateTime = block.timestamp;
    }

    function _elapsed(uint256 from, uint256 to) internal view returns (uint256) {
        uint256 cap = endTime < to ? endTime : to;
        return cap > from ? cap - from : 0;
    }

    // ─── Owner 管理 ────────────────────────────────────────
    function setRewardPerSecond(uint256 rate) external onlyOwner {
        _updatePool();
        rewardPerSecond = rate;
        emit RewardRateUpdated(rate);
    }

    function setEndTime(uint256 time) external onlyOwner {
        require(time > block.timestamp, "Must be future");
        endTime = time;
    }

    function setLockPeriod(uint256 seconds_) external onlyOwner {
        lockPeriod = seconds_;
    }

    /// @notice 充入奖励代币
    function fundRewards(uint256 amount) external onlyOwner {
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice 提回多余奖励（池子结束后）
    function recoverReward(uint256 amount) external onlyOwner {
        require(block.timestamp > endTime, "Pool still active");
        rewardToken.safeTransfer(owner(), amount);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./FairLaunchToken.sol";
import "./StakingPool.sol";

/**
 * @title FairLaunchFactory
 * @notice 一键发射工厂合约
 *
 * 用户调用 createToken() 并附带 BNB 作为初始流动性，
 * 工厂自动：
 *   1. 部署 FairLaunchToken
 *   2. 将代币转给创建者
 *   3. （可选）部署 StakingPool 并绑定
 *   4. 收取平台创建费用
 */
contract FairLaunchFactory is Ownable {

    // 平台收费（BNB）
    uint256 public createFee = 0.05 ether;

    // 记录所有已发射的代币
    address[] public allTokens;
    mapping(address => address[]) public userTokens;

    // 质押池记录
    mapping(address => address) public tokenStakingPool;

    // BSC PancakeSwap Router（主网）
    address public constant PANCAKE_ROUTER_MAINNET = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    // BSC PancakeSwap Router（测试网）
    address public constant PANCAKE_ROUTER_TESTNET = 0xD99D1c33F9fC3444f8101754aBC46c52416550D1;

    address public defaultRouter;

    event TokenCreated(
        address indexed creator,
        address indexed token,
        address stakingPool,
        string  name,
        string  symbol
    );
    event FeeUpdated(uint256 newFee);

    constructor(bool testnet) {
        defaultRouter = testnet ? PANCAKE_ROUTER_TESTNET : PANCAKE_ROUTER_MAINNET;
    }

    // ─────────────────────────────────────────────────────
    //  对外接口
    // ─────────────────────────────────────────────────────
    struct LaunchParams {
        // 基础信息
        string  name;
        string  symbol;
        uint256 totalSupply;          // 不含 decimals

        // 买税（基点，100=1%）
        uint16  buyBurn;
        uint16  buyDividend;
        uint16  buyLiquidity;
        uint16  buyMarketing;

        // 卖税
        uint16  sellBurn;
        uint16  sellDividend;
        uint16  sellLiquidity;
        uint16  sellMarketing;

        // 功能开关
        bool    enableBurn;
        bool    enableDividend;
        bool    enableLiquidity;
        bool    enableStaking;

        // 安全参数
        uint256 maxWalletPct;         // 0 = 不限
        uint256 cooldown;
        bool    antiBot;
        uint256 antiBotDuration;
        uint256 antiBotMaxBuyPct;

        // 营销钱包（address(0) = 发射者本人）
        address marketingWallet;

        // 质押池参数（enableStaking=true 时生效）
        uint256 stakingRewardPerSecond;
        uint256 stakingDuration;       // 秒
        uint256 stakingLockPeriod;     // 秒
        uint256 stakingRewardAmount;   // 奖励代币数量（从总供给划拨）
    }

    /**
     * @notice 发射代币
     * @dev msg.value 必须 >= createFee
     *      多余的 BNB 会在前端做流动性添加引导（合约不自动 add，用户控制）
     */
    function createToken(LaunchParams calldata p) external payable returns (address tokenAddr, address stakingAddr) {
        require(msg.value >= createFee, "Insufficient fee");

        FairLaunchToken.InitParams memory init = FairLaunchToken.InitParams({
            name_:             p.name,
            symbol_:           p.symbol,
            totalSupply_:      p.totalSupply,
            marketingWallet_:  p.marketingWallet,
            router_:           defaultRouter,
            buyBurn:           p.buyBurn,
            buyDividend:       p.buyDividend,
            buyLiquidity:      p.buyLiquidity,
            buyMarketing:      p.buyMarketing,
            sellBurn:          p.sellBurn,
            sellDividend:      p.sellDividend,
            sellLiquidity:     p.sellLiquidity,
            sellMarketing:     p.sellMarketing,
            enableBurn:        p.enableBurn,
            enableDividend:    p.enableDividend,
            enableLiquidity:   p.enableLiquidity,
            enableStaking:     p.enableStaking,
            maxWalletPct:      p.maxWalletPct,
            cooldown:          p.cooldown,
            antiBot:           p.antiBot,
            antiBotDuration:   p.antiBotDuration,
            antiBotMaxBuyPct:  p.antiBotMaxBuyPct
        });

        FairLaunchToken token = new FairLaunchToken(init);
        tokenAddr = address(token);

        uint256 totalSupplyWei = p.totalSupply * 10 ** 18;

        // 处理质押池
        if (p.enableStaking && p.stakingRewardAmount > 0) {
            uint256 rewardWei = p.stakingRewardAmount * 10 ** 18;
            require(rewardWei < totalSupplyWei, "Reward exceeds supply");

            StakingPool pool = new StakingPool(
                tokenAddr,
                tokenAddr,
                p.stakingRewardPerSecond,
                block.timestamp,
                block.timestamp + p.stakingDuration,
                p.stakingLockPeriod
            );
            stakingAddr = address(pool);

            // 将奖励代币从工厂转入质押池
            token.transfer(stakingAddr, rewardWei);
            token.setStakingPool(stakingAddr);
            tokenStakingPool[tokenAddr] = stakingAddr;
        }

        // 将剩余代币转给发射者
        uint256 remaining = token.balanceOf(address(this));
        if (remaining > 0) {
            token.transfer(msg.sender, remaining);
        }

        // 将 token 所有权转给发射者
        token.transferOwnership(msg.sender);

        // 记录
        allTokens.push(tokenAddr);
        userTokens[msg.sender].push(tokenAddr);

        // 收取平台费，多余 BNB 退回
        uint256 excess = msg.value - createFee;
        if (excess > 0) {
            (bool ok,) = payable(msg.sender).call{value: excess}("");
            require(ok, "Refund failed");
        }

        emit TokenCreated(msg.sender, tokenAddr, stakingAddr, p.name, p.symbol);
    }

    // ─── 查询函数 ────────────────────────────────────────
    function allTokensLength() external view returns (uint256) {
        return allTokens.length;
    }

    function userTokensLength(address user) external view returns (uint256) {
        return userTokens[user].length;
    }

    function getUserTokens(address user) external view returns (address[] memory) {
        return userTokens[user];
    }

    // ─── Owner 管理 ───────────────────────────────────────
    function setCreateFee(uint256 fee) external onlyOwner {
        createFee = fee;
        emit FeeUpdated(fee);
    }

    function setDefaultRouter(address router) external onlyOwner {
        defaultRouter = router;
    }

    function withdrawFees() external onlyOwner {
        (bool ok,) = payable(owner()).call{value: address(this).balance}("");
        require(ok);
    }

    receive() external payable {}
}

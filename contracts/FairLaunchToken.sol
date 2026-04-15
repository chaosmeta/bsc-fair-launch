// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interfaces/IPancake.sol";

/**
 * @title FairLaunchToken
 * @notice BSC 公平发射代币合约，支持燃烧/分红/回流/营销税
 *
 * 税率说明（买/卖独立配置）：
 *   burnTax      - 燃烧，直接销毁
 *   dividendTax  - 分红，按持仓比例分配给持币者
 *   liquidityTax - 回流，自动注入 PancakeSwap LP
 *   marketingTax - 营销，转入项目方钱包
 *
 * 安全机制：
 *   maxWalletAmount  - 最大钱包持仓限制
 *   cooldownEnabled  - 交易冷却时间（防机器人）
 *   antiBotEnabled   - 发射初期限制大额购买
 */
contract FairLaunchToken is IERC20, Ownable, ReentrancyGuard {

    // ─── 基础信息 ────────────────────────────────────────
    string  public name;
    string  public symbol;
    uint8   public constant decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    // ─── 税率结构体 ──────────────────────────────────────
    struct TaxConfig {
        uint16 burnTax;        // 燃烧税率 (basis points, 100 = 1%)
        uint16 dividendTax;    // 分红税率
        uint16 liquidityTax;   // 回流税率
        uint16 marketingTax;   // 营销税率
    }
    TaxConfig public buyTax;
    TaxConfig public sellTax;

    // 最大税率上限（防止恶意设置高税）
    uint16 public constant MAX_TOTAL_TAX = 2500; // 25%

    // ─── 功能开关 ────────────────────────────────────────
    bool public burnEnabled;
    bool public dividendEnabled;
    bool public liquidityEnabled;
    bool public stakingEnabled;

    // ─── 分红状态 ────────────────────────────────────────
    uint256 public totalDividendsDistributed;
    uint256 private _dividendPerTokenStored;
    uint256 private constant PRECISION = 1e18;
    mapping(address => uint256) private _dividendDebt;
    mapping(address => uint256) public pendingDividends;

    // ─── 流动性自动注入 ──────────────────────────────────
    IPancakeRouter public pancakeRouter;
    address        public pancakePair;
    uint256        public swapThreshold;   // 触发 swap 的积累量
    bool           private _swapping;

    // ─── 营销钱包 ────────────────────────────────────────
    address public marketingWallet;

    // ─── 安全机制 ────────────────────────────────────────
    uint256 public maxWalletAmount;        // 0 = 不限制
    uint256 public cooldownTime;           // 秒，0 = 关闭
    mapping(address => uint256) public lastTrade;

    bool   public antiBotEnabled;
    uint256 public antiBotEndTime;
    uint256 public antiBotMaxBuy;          // 发射初期最大购买量

    // ─── 白名单（免税地址）───────────────────────────────
    mapping(address => bool) public isExempt;

    // ─── 质押合约地址 ────────────────────────────────────
    address public stakingPool;

    // ─── 发射状态 ────────────────────────────────────────
    bool public tradingEnabled;

    // ─── 事件 ────────────────────────────────────────────
    event TaxConfigUpdated(bool isBuy, TaxConfig config);
    event DividendClaimed(address indexed user, uint256 amount);
    event LiquidityAdded(uint256 tokenAmount, uint256 bnbAmount);
    event TradingEnabled();
    event StakingPoolSet(address pool);

    // ─────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────
    struct InitParams {
        string  name_;
        string  symbol_;
        uint256 totalSupply_;       // 不含 decimals
        address marketingWallet_;
        address router_;            // PancakeSwap Router
        // 买税
        uint16 buyBurn;
        uint16 buyDividend;
        uint16 buyLiquidity;
        uint16 buyMarketing;
        // 卖税
        uint16 sellBurn;
        uint16 sellDividend;
        uint16 sellLiquidity;
        uint16 sellMarketing;
        // 功能开关
        bool enableBurn;
        bool enableDividend;
        bool enableLiquidity;
        bool enableStaking;
        // 安全参数
        uint256 maxWalletPct;       // 最大钱包百分比 (0-100)，0 = 不限
        uint256 cooldown;           // 冷却秒数
        bool    antiBot;
        uint256 antiBotDuration;    // 秒
        uint256 antiBotMaxBuyPct;   // 发射初期单笔最大购买 %
    }

    constructor(InitParams memory p) {
        // 税率校验
        require(
            uint256(p.buyBurn) + p.buyDividend + p.buyLiquidity + p.buyMarketing <= MAX_TOTAL_TAX,
            "Buy tax exceeds 25%"
        );
        require(
            uint256(p.sellBurn) + p.sellDividend + p.sellLiquidity + p.sellMarketing <= MAX_TOTAL_TAX,
            "Sell tax exceeds 25%"
        );

        name   = p.name_;
        symbol = p.symbol_;

        uint256 supply = p.totalSupply_ * 10 ** decimals;
        totalSupply = supply;
        _balances[msg.sender] = supply;
        emit Transfer(address(0), msg.sender, supply);

        marketingWallet = p.marketingWallet_ != address(0) ? p.marketingWallet_ : msg.sender;

        // 税率设置
        buyTax  = TaxConfig(p.buyBurn,  p.buyDividend,  p.buyLiquidity,  p.buyMarketing);
        sellTax = TaxConfig(p.sellBurn, p.sellDividend, p.sellLiquidity, p.sellMarketing);

        // 功能开关
        burnEnabled      = p.enableBurn;
        dividendEnabled  = p.enableDividend;
        liquidityEnabled = p.enableLiquidity;
        stakingEnabled   = p.enableStaking;

        // PancakeSwap
        if (p.router_ != address(0)) {
            pancakeRouter = IPancakeRouter(p.router_);
            pancakePair   = IPancakeFactory(pancakeRouter.factory())
                                .createPair(address(this), pancakeRouter.WETH());
        }

        swapThreshold = supply / 1000; // 0.1% 触发 swap

        // 安全参数
        if (p.maxWalletPct > 0) {
            maxWalletAmount = supply * p.maxWalletPct / 100;
        }
        cooldownTime = p.cooldown;

        if (p.antiBot) {
            antiBotEnabled  = true;
            antiBotEndTime  = block.timestamp + p.antiBotDuration;
            antiBotMaxBuy   = supply * p.antiBotMaxBuyPct / 100;
        }

        // 白名单
        isExempt[msg.sender]       = true;
        isExempt[address(this)]    = true;
        isExempt[marketingWallet]  = true;
        isExempt[address(0xdead)]  = true;
    }

    // ─────────────────────────────────────────────────────
    //  ERC20 标准
    // ─────────────────────────────────────────────────────
    function balanceOf(address account) public view override returns (uint256) {
        return _balances[account];
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function allowance(address owner_, address spender) public view override returns (uint256) {
        return _allowances[owner_][spender];
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 allowed = _allowances[from][msg.sender];
        require(allowed >= amount, "Insufficient allowance");
        if (allowed != type(uint256).max) {
            _allowances[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    // ─────────────────────────────────────────────────────
    //  核心转账逻辑
    // ─────────────────────────────────────────────────────
    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0) && to != address(0), "Zero address");
        require(amount > 0, "Zero amount");
        require(_balances[from] >= amount, "Insufficient balance");

        // 交易开关
        if (!tradingEnabled) {
            require(isExempt[from] || isExempt[to], "Trading not enabled");
        }

        // 防机器人
        if (antiBotEnabled && block.timestamp < antiBotEndTime) {
            if (to != pancakePair && !isExempt[to]) {
                require(amount <= antiBotMaxBuy, "AntiBot: max buy exceeded");
            }
        }

        // 冷却时间
        if (cooldownTime > 0 && !isExempt[from]) {
            require(block.timestamp >= lastTrade[from] + cooldownTime, "Cooldown active");
            lastTrade[from] = block.timestamp;
        }

        // 最大钱包
        if (maxWalletAmount > 0 && !isExempt[to] && to != pancakePair) {
            require(_balances[to] + amount <= maxWalletAmount, "Exceeds max wallet");
        }

        // 触发 swap（回流 + 分红 BNB）
        bool shouldSwap = !_swapping
            && !isExempt[from]
            && to == pancakePair
            && liquidityEnabled
            && _balances[address(this)] >= swapThreshold;

        if (shouldSwap) {
            _swapping = true;
            _swapAndDistribute();
            _swapping = false;
        }

        // 收税
        bool takeTax = !isExempt[from] && !isExempt[to] && !_swapping;
        if (takeTax) {
            bool isBuy  = from == pancakePair;
            bool isSell = to   == pancakePair;
            if (isBuy || isSell) {
                amount = _applyTax(from, to, amount, isBuy);
            }
        }

        // 分红快照更新
        if (dividendEnabled) {
            _updateDividend(from);
            _updateDividend(to);
        }

        _balances[from] -= amount;
        _balances[to]   += amount;
        emit Transfer(from, to, amount);
    }

    // ─────────────────────────────────────────────────────
    //  税率处理
    // ─────────────────────────────────────────────────────
    function _applyTax(
        address from,
        address /*to*/,
        uint256 amount,
        bool isBuy
    ) internal returns (uint256 netAmount) {
        TaxConfig memory tax = isBuy ? buyTax : sellTax;

        uint256 burnAmt      = burnEnabled     ? amount * tax.burnTax      / 10000 : 0;
        uint256 dividendAmt  = dividendEnabled ? amount * tax.dividendTax  / 10000 : 0;
        uint256 liquidityAmt = liquidityEnabled? amount * tax.liquidityTax / 10000 : 0;
        uint256 marketingAmt =                  amount * tax.marketingTax / 10000;

        uint256 totalTax = burnAmt + dividendAmt + liquidityAmt + marketingAmt;

        // 燃烧
        if (burnAmt > 0) {
            _balances[from]         -= burnAmt;
            _balances[address(0xdead)] += burnAmt;
            totalSupply             -= burnAmt;
            emit Transfer(from, address(0xdead), burnAmt);
        }

        // 分红累积到合约
        if (dividendAmt > 0) {
            _balances[from]          -= dividendAmt;
            _balances[address(this)] += dividendAmt;
        }

        // 回流累积到合约
        if (liquidityAmt > 0) {
            _balances[from]          -= liquidityAmt;
            _balances[address(this)] += liquidityAmt;
        }

        // 营销
        if (marketingAmt > 0) {
            _balances[from]             -= marketingAmt;
            _balances[marketingWallet]  += marketingAmt;
            emit Transfer(from, marketingWallet, marketingAmt);
        }

        return amount - totalTax;
    }

    // ─────────────────────────────────────────────────────
    //  回流 & 分红 BNB 分发
    // ─────────────────────────────────────────────────────
    function _swapAndDistribute() internal {
        uint256 contractBalance = _balances[address(this)];
        if (contractBalance < swapThreshold) return;

        // 一半用于加流动性，另一半卖成 BNB
        TaxConfig memory tax = sellTax;
        uint256 totalTaxBps = uint256(tax.dividendTax) + tax.liquidityTax;
        if (totalTaxBps == 0) return;

        uint256 liquidityShare = contractBalance * tax.liquidityTax / totalTaxBps;
        uint256 dividendShare  = contractBalance - liquidityShare;

        uint256 halfLiq = liquidityShare / 2;
        uint256 swapAmount = dividendShare + halfLiq;

        // Swap tokens -> BNB
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = pancakeRouter.WETH();

        _allowances[address(this)][address(pancakeRouter)] = swapAmount;

        try pancakeRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
            swapAmount, 0, path, address(this), block.timestamp
        ) {} catch { return; }

        uint256 bnbReceived = address(this).balance;
        if (bnbReceived == 0) return;

        // 分配 BNB：回流 & 分红
        uint256 liqBNB      = dividendShare > 0
            ? bnbReceived * halfLiq / swapAmount
            : bnbReceived;
        uint256 dividendBNB = bnbReceived - liqBNB;

        // 加流动性
        if (liqBNB > 0 && _balances[address(this)] >= halfLiq) {
            _allowances[address(this)][address(pancakeRouter)] = halfLiq;
            try pancakeRouter.addLiquidityETH{value: liqBNB}(
                address(this), halfLiq, 0, 0, owner(), block.timestamp
            ) {
                emit LiquidityAdded(halfLiq, liqBNB);
            } catch {}
        }

        // 分发分红
        if (dividendBNB > 0 && totalSupply > 0) {
            _dividendPerTokenStored += dividendBNB * PRECISION / totalSupply;
            totalDividendsDistributed += dividendBNB;
        }
    }

    // ─────────────────────────────────────────────────────
    //  分红领取
    // ─────────────────────────────────────────────────────
    function _updateDividend(address account) internal {
        if (account == address(0) || account == address(0xdead)) return;
        uint256 earned = _balances[account] * (_dividendPerTokenStored - _dividendDebt[account]) / PRECISION;
        pendingDividends[account] += earned;
        _dividendDebt[account]    = _dividendPerTokenStored;
    }

    function claimDividend() external nonReentrant {
        require(dividendEnabled, "Dividend not enabled");
        _updateDividend(msg.sender);
        uint256 pending = pendingDividends[msg.sender];
        require(pending > 0, "Nothing to claim");
        pendingDividends[msg.sender] = 0;
        (bool ok,) = payable(msg.sender).call{value: pending}("");
        require(ok, "BNB transfer failed");
        emit DividendClaimed(msg.sender, pending);
    }

    function pendingDividendOf(address account) external view returns (uint256) {
        uint256 earned = _balances[account] * (_dividendPerTokenStored - _dividendDebt[account]) / PRECISION;
        return pendingDividends[account] + earned;
    }

    // ─────────────────────────────────────────────────────
    //  Owner 管理函数
    // ─────────────────────────────────────────────────────
    function enableTrading() external onlyOwner {
        tradingEnabled = true;
        emit TradingEnabled();
    }

    function setStakingPool(address pool) external onlyOwner {
        stakingPool = pool;
        isExempt[pool] = true;
        emit StakingPoolSet(pool);
    }

    function setBuyTax(uint16 burn, uint16 dividend, uint16 liquidity, uint16 marketing) external onlyOwner {
        require(uint256(burn) + dividend + liquidity + marketing <= MAX_TOTAL_TAX, "Exceeds max tax");
        buyTax = TaxConfig(burn, dividend, liquidity, marketing);
        emit TaxConfigUpdated(true, buyTax);
    }

    function setSellTax(uint16 burn, uint16 dividend, uint16 liquidity, uint16 marketing) external onlyOwner {
        require(uint256(burn) + dividend + liquidity + marketing <= MAX_TOTAL_TAX, "Exceeds max tax");
        sellTax = TaxConfig(burn, dividend, liquidity, marketing);
        emit TaxConfigUpdated(false, sellTax);
    }

    function setExempt(address account, bool exempt) external onlyOwner {
        isExempt[account] = exempt;
    }

    function setMarketingWallet(address wallet) external onlyOwner {
        marketingWallet = wallet;
    }

    function setMaxWallet(uint256 amount) external onlyOwner {
        maxWalletAmount = amount;
    }

    function setSwapThreshold(uint256 amount) external onlyOwner {
        swapThreshold = amount;
    }

    function disableAntiBot() external onlyOwner {
        antiBotEnabled = false;
    }

    // 紧急提取合约内 BNB（仅限 owner）
    function rescueBNB() external onlyOwner {
        (bool ok,) = payable(owner()).call{value: address(this).balance}("");
        require(ok);
    }

    receive() external payable {}
}

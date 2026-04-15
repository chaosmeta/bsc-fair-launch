# 🚀 BSC Fair Launch Platform

> BSC 链公平发射平台 —— 支持税币发射，可自选燃烧、分红、回流、质押功能

## 功能特性

- ✅ **公平发射** - 无预挖、无私募，所有人平等参与
- 🔥 **燃烧税** - 每笔交易自动燃烧代币，持续通缩
- 💰 **分红税** - 交易税自动分配给持币者
- 💧 **回流税** - 自动向 PancakeSwap 注入流动性
- 🏦 **质押挖矿** - 支持代币质押获得奖励
- ⚙️ **灵活配置** - 发射时自由组合以上功能

## 项目结构

```
bsc-fair-launch/
├── contracts/
│   ├── FairLaunchFactory.sol     # 工厂合约（核心）
│   ├── FairLaunchToken.sol       # 税币代币合约
│   ├── StakingPool.sol           # 质押合约
│   └── interfaces/
│       ├── IPancakeRouter.sol
│       └── IPancakeFactory.sol
├── frontend/
│   ├── index.html                # 主页
│   ├── launch.html               # 发射页面
│   ├── staking.html              # 质押页面
│   └── assets/
│       ├── app.js
│       └── style.css
├── scripts/
│   ├── deploy.js                 # 部署脚本
│   └── verify.js                 # 合约验证
├── test/
│   └── FairLaunch.test.js
├── hardhat.config.js
└── package.json
```

## 快速开始

### 安装依赖
```bash
npm install
```

### 配置环境变量
```bash
cp .env.example .env
# 编辑 .env 填入私钥和 API Key
```

### 编译合约
```bash
npx hardhat compile
```

### 部署到 BSC 测试网
```bash
npx hardhat run scripts/deploy.js --network bscTestnet
```

### 部署到 BSC 主网
```bash
npx hardhat run scripts/deploy.js --network bscMainnet
```

## 税率配置说明

| 功能 | 最低税率 | 最高税率 | 说明 |
|------|----------|----------|------|
| 燃烧 | 0% | 10% | 销毁代币 |
| 分红 | 0% | 10% | 分配给持币者 |
| 回流 | 0% | 10% | 注入流动性 |
| 营销 | 0% | 5% | 项目方钱包 |
| **合计** | **0%** | **25%** | 买卖税总上限 |

## 安全说明

- 合约已添加防貔貅机制（可选）
- 支持交易冷却时间防机器人
- 支持最大钱包限额
- 发射完成后可放弃 Owner 权限

## License

MIT

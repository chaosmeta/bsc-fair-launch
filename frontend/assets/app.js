/**
 * app.js — FairPad 前端核心逻辑
 * 
 * 依赖：ethers.js v5 (CDN)
 * 
 * 使用前请将 FACTORY_ADDRESS 替换为部署后的工厂合约地址
 */

// ─── 配置 ──────────────────────────────────────────────
const CONFIG = {
  CHAIN_ID: 97,             // 97 = BSC Testnet, 56 = BSC Mainnet
  CHAIN_NAME: 'BSC Testnet',
  RPC_URL: 'https://data-seed-prebsc-1-s1.binance.org:8545',
  EXPLORER: 'https://testnet.bscscan.com',
  FACTORY_ADDRESS: '0x0000000000000000000000000000000000000000', // 部署后更新
};

// ─── ABI（精简版，仅包含前端所需函数）──────────────────
const FACTORY_ABI = [
  "function createToken((string name, string symbol, uint256 totalSupply, uint16 buyBurn, uint16 buyDividend, uint16 buyLiquidity, uint16 buyMarketing, uint16 sellBurn, uint16 sellDividend, uint16 sellLiquidity, uint16 sellMarketing, bool enableBurn, bool enableDividend, bool enableLiquidity, bool enableStaking, uint256 maxWalletPct, uint256 cooldown, bool antiBot, uint256 antiBotDuration, uint256 antiBotMaxBuyPct, address marketingWallet, uint256 stakingRewardPerSecond, uint256 stakingDuration, uint256 stakingLockPeriod, uint256 stakingRewardAmount) p) payable returns (address token, address staking)",
  "function allTokensLength() view returns (uint256)",
  "function allTokens(uint256) view returns (address)",
  "function getUserTokens(address) view returns (address[])",
  "function createFee() view returns (uint256)",
  "event TokenCreated(address indexed creator, address indexed token, address stakingPool, string name, string symbol)",
];

const TOKEN_ABI = [
  "function name() view returns (string)",
  "function symbol() view returns (string)",
  "function totalSupply() view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
  "function buyTax() view returns (uint16 burnTax, uint16 dividendTax, uint16 liquidityTax, uint16 marketingTax)",
  "function sellTax() view returns (uint16 burnTax, uint16 dividendTax, uint16 liquidityTax, uint16 marketingTax)",
  "function burnEnabled() view returns (bool)",
  "function dividendEnabled() view returns (bool)",
  "function liquidityEnabled() view returns (bool)",
  "function stakingEnabled() view returns (bool)",
  "function claimDividend()",
  "function pendingDividendOf(address) view returns (uint256)",
  "function enableTrading()",
];

const STAKING_ABI = [
  "function stake(uint256 amount)",
  "function unstake(uint256 amount)",
  "function claimReward()",
  "function emergencyWithdraw()",
  "function pendingReward(address) view returns (uint256)",
  "function userInfo(address) view returns (uint256 amount, uint256 rewardDebt, uint256 stakeTime, uint256 pendingReward)",
  "function totalStaked() view returns (uint256)",
  "function rewardPerSecond() view returns (uint256)",
  "function endTime() view returns (uint256)",
  "function lockPeriod() view returns (uint256)",
];

// ─── 全局状态 ──────────────────────────────────────────
window.provider       = null;
window.signer         = null;
window.userAddress    = null;
window.factoryContract = null;
window.ethers         = window.ethers; // from CDN

// ─── 钱包连接 ──────────────────────────────────────────
async function connectMetaMask() {
  if (!window.ethereum) {
    alert('请先安装 MetaMask 钱包插件！');
    return;
  }
  try {
    await window.ethereum.request({ method: 'eth_requestAccounts' });
    window.provider = new ethers.providers.Web3Provider(window.ethereum);
    await ensureCorrectNetwork();
    window.signer = window.provider.getSigner();
    window.userAddress = await window.signer.getAddress();
    window.factoryContract = new ethers.Contract(CONFIG.FACTORY_ADDRESS, FACTORY_ABI, window.signer);
    updateConnectBtn();
    closeWalletModal?.();
    onWalletConnected();
  } catch (err) {
    console.error('MetaMask connect error:', err);
  }
}

async function connectWalletConnect() {
  // WalletConnect v2 集成占位
  alert('WalletConnect 即将支持，请使用 MetaMask');
}

async function ensureCorrectNetwork() {
  const network = await window.provider.getNetwork();
  if (network.chainId !== CONFIG.CHAIN_ID) {
    try {
      await window.ethereum.request({
        method: 'wallet_switchEthereumChain',
        params: [{ chainId: '0x' + CONFIG.CHAIN_ID.toString(16) }],
      });
    } catch (switchError) {
      if (switchError.code === 4902) {
        await window.ethereum.request({
          method: 'wallet_addEthereumChain',
          params: [{
            chainId: '0x' + CONFIG.CHAIN_ID.toString(16),
            chainName: CONFIG.CHAIN_NAME,
            rpcUrls: [CONFIG.RPC_URL],
            blockExplorerUrls: [CONFIG.EXPLORER],
            nativeCurrency: { name: 'BNB', symbol: 'BNB', decimals: 18 },
          }],
        });
      }
    }
  }
}

function updateConnectBtn() {
  const btn = document.getElementById('connectBtn');
  if (!btn) return;
  if (window.userAddress) {
    btn.textContent = window.userAddress.slice(0,6) + '...' + window.userAddress.slice(-4);
    btn.style.background = '#22c55e';
  } else {
    btn.textContent = '连接钱包';
    btn.style.background = '#f0b429';
  }
}

function onWalletConnected() {
  // 各页面自行实现此函数来加载数据
  if (typeof onConnected === 'function') onConnected();
}

// ─── 工具函数 ──────────────────────────────────────────
function formatAddress(addr) {
  return addr.slice(0,6) + '...' + addr.slice(-4);
}

function formatNumber(n, decimals = 2) {
  return parseFloat(ethers.utils.formatUnits(n, 18)).toFixed(decimals);
}

function bpsToPercent(bps) {
  return (bps / 100).toFixed(1) + '%';
}

function explorerUrl(type, value) {
  return `${CONFIG.EXPLORER}/${type}/${value}`;
}

// ─── 监听账户变化 ──────────────────────────────────────
if (window.ethereum) {
  window.ethereum.on('accountsChanged', accounts => {
    if (accounts.length === 0) {
      window.userAddress = null;
      updateConnectBtn();
    } else {
      window.userAddress = accounts[0];
      updateConnectBtn();
    }
  });
  window.ethereum.on('chainChanged', () => window.location.reload());
}

// ─── 钱包模态框（主页用）──────────────────────────────
function openWalletModal() {
  const m = document.getElementById('walletModal');
  if (m) m.classList.add('active');
}
function closeWalletModal() {
  const m = document.getElementById('walletModal');
  if (m) m.classList.remove('active');
}

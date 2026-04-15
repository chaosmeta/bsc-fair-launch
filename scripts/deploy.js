const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  const network = hre.network.name;
  const isTestnet = network === "bscTestnet";

  console.log("======================================");
  console.log("  BSC Fair Launch Platform Deployer");
  console.log("======================================");
  console.log("Network   :", network);
  console.log("Deployer  :", deployer.address);
  console.log("Balance   :", hre.ethers.formatEther(await hre.ethers.provider.getBalance(deployer.address)), "BNB");
  console.log("--------------------------------------");

  // 部署工厂合约
  console.log("\n[1/1] Deploying FairLaunchFactory...");
  const Factory = await hre.ethers.getContractFactory("FairLaunchFactory");
  const factory = await Factory.deploy(isTestnet);
  await factory.waitForDeployment();
  const factoryAddress = await factory.getAddress();

  console.log("✅ FairLaunchFactory deployed to:", factoryAddress);
  console.log("\n--------------------------------------");
  console.log("Contract Addresses:");
  console.log("  FairLaunchFactory:", factoryAddress);
  console.log("--------------------------------------");
  console.log("\nNext steps:");
  console.log("  1. Verify contract on BscScan:");
  console.log(`     npx hardhat verify --network ${network} ${factoryAddress} ${isTestnet}`);
  console.log("  2. Update frontend/assets/app.js with factory address");
  console.log("  3. Test token creation via frontend");
  console.log("======================================\n");

  // 保存部署信息
  const fs = require("fs");
  const deployInfo = {
    network,
    factory: factoryAddress,
    deployer: deployer.address,
    timestamp: new Date().toISOString(),
  };
  fs.writeFileSync(
    `deployments/${network}.json`,
    JSON.stringify(deployInfo, null, 2)
  );
  console.log(`Deployment info saved to deployments/${network}.json`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

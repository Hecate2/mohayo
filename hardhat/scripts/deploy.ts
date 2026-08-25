import { ethers } from "hardhat";
import { deployContract, loadArtifact, extractPlaceholders, linkBytecode, saveManifest, Manifest } from "../lib/artifacts";

// 生产部署与链下运维层：从 Foundry out/ 读取 ABI+字节码，按依赖顺序部署全部核心合约。
// 用法：npx hardhat run scripts/deploy.ts --network anvil
//   PRIVATE_KEY 默认 Anvil 账户0；测试网部署时通过环境变量注入。
async function main() {
  const [deployer] = await ethers.getSigners();
  const chainId = (await ethers.provider.getNetwork()).chainId;
  const gmEnabled = process.env.GM_ENABLED !== "false";
  console.log(`Deploying on chain ${chainId} from ${deployer.address} (gmEnabled=${gmEnabled})`);

  // ---- 1. 库（CombatEndLib/CombatTargetLib 无依赖，CombatLib 引用二者）----
  const endLib = await deployContract(deployer, "CombatEndLib");
  const targetLib = await deployContract(deployer, "CombatTargetLib");
  const combatLib = await deployContract(deployer, "CombatLib", [], {
    da7689389236bd2b6b571b159bf4a19988: await endLib.getAddress(),
    "844a33c2d4643cc0e192d47dc7cffa323d": await targetLib.getAddress(),
  });

  // ---- 2. 随机数路由 + 默认 Provider（角色创建/词条用；战斗走房间级链式 PRNG）----
  const rng = await deployContract(deployer, "RNGRouter");
  const blockRng = await deployContract(deployer, "BlockEntropyRNG");
  await (await rng.setGlobalProvider(await blockRng.getAddress())).wait();
  await (await rng.setCategoryProvider(ethers.keccak256(ethers.toUtf8Bytes("AFFIX")), await blockRng.getAddress())).wait();

  // ---- 3. 经济 + 技能注册表 ----
  const economy = await deployContract(deployer, "Economy");
  const sr = await deployContract(deployer, "SkillRegistry");

  // ---- 4. 角色注册表（gmEnabled 由环境变量控制，主网传 false）----
  const cr = await deployContract(deployer, "CharacterRegistry", [await rng.getAddress(), await sr.getAddress(), gmEnabled]);

  // ---- 5. 战斗结算器（链接 CombatLib）----
  const { bytecode: ceBc } = loadArtifact("CombatEngine");
  const ceLibs: Record<string, string> = {};
  for (const h of extractPlaceholders(ceBc)) {
    if (h === "221cdbf7e942681421010bad8dbcea653e") {
      ceLibs[h] = await combatLib.getAddress();
    } else {
      throw new Error(`CombatEngine unexpected placeholder ${h}`);
    }
  }
  const ce = await deployContract(deployer, "CombatEngine", [await sr.getAddress(), await cr.getAddress(), await economy.getAddress()], ceLibs);

  // ---- 6. 权限授予 ----
  await (await economy.setMinter(await ce.getAddress(), true)).wait();
  await (await economy.setSpender(await ce.getAddress(), true)).wait();
  await (await cr.setCombatEngine(await ce.getAddress())).wait();

  // ---- 7. 写入部署清单 ----
  const manifest: Manifest = {
    chainId: Number(chainId),
    deployer: deployer.address,
    gmEnabled,
    contracts: {
      RNGRouter: await rng.getAddress(),
      BlockEntropyRNG: await blockRng.getAddress(),
      Economy: await economy.getAddress(),
      SkillRegistry: await sr.getAddress(),
      CharacterRegistry: await cr.getAddress(),
      CombatEngine: await ce.getAddress(),
      CombatEndLib: await endLib.getAddress(),
      CombatTargetLib: await targetLib.getAddress(),
      CombatLib: await combatLib.getAddress(),
    },
  };
  saveManifest(Number(chainId), manifest);
  console.log("Deploy complete:", JSON.stringify(manifest.contracts, null, 2));
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});

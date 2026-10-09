import { ethers } from "hardhat";
import { getContracts } from "../lib/artifacts";
async function main() {
  const [deployer] = await ethers.getSigners();
  const chainId = Number((await ethers.provider.getNetwork()).chainId);
  const { contracts } = getContracts(deployer, chainId);
  const r = await contracts.CombatEngine.rooms(3);
  console.log("type:", typeof r, Array.isArray(r));
  console.log("keys:", Object.keys(r));
  console.log("members type:", typeof r.members);
  const g = await contracts.CombatEngine.getRoom(3);
  console.log("getRoom keys:", Object.keys(g));
  console.log("getRoom members:", typeof g.members, Array.isArray(g.members));
}
main().catch((e) => { console.error(e); process.exitCode = 1; });

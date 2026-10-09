import { ethers } from "hardhat";
import { getContracts } from "../lib/artifacts";
async function main() {
  const [deployer] = await ethers.getSigners();
  const chainId = Number((await ethers.provider.getNetwork()).chainId);
  const { contracts } = getContracts(deployer, chainId);
  const ce = contracts.CombatEngine;
  const roomId = 3;
  const before = await ce.getRoom(roomId);
  console.log("before: phase=", before.phase, "turn=", before.turnId, "block=", await ethers.provider.getBlockNumber());
  const tx = await ce.advanceTurn(roomId);
  const rc = await tx.wait();
  console.log("tx status:", rc.status, "block:", rc.blockNumber);
  const after = await ce.getRoom(roomId);
  console.log("after: phase=", after.phase, "turn=", after.turnId, "block=", await ethers.provider.getBlockNumber());
  console.log("member0 hp:", after.members[0].hp.toString(), "alive:", after.members[0].alive);
  console.log("enemy0 hp:", after.enemies[0].hp.toString(), "alive:", after.enemies[0].alive);
  const logs = rc.logs.map((l: any) => { try { return ce.interface.parseLog(l); } catch { return null; } }).filter(Boolean);
  console.log("logs:", logs.map((l: any) => l.name).join(", "));
}
main().catch((e) => { console.error(e); process.exitCode = 1; });

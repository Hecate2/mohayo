import { ethers } from "hardhat";
import { getContracts } from "../lib/artifacts";
async function main() {
  const [deployer] = await ethers.getSigners();
  const chainId = Number((await ethers.provider.getNetwork()).chainId);
  const { contracts } = getContracts(deployer, chainId);
  const ce = contracts.CombatEngine;
  const roomId = 3;
  const before = await ce.getRoom(roomId);
  console.log("before: phase=", Number(before.phase), "turn=", Number(before.turnId));
  try {
    const tx = await ce.advanceTurn(roomId, { gasLimit: 5_000_000 });
    const rc = await tx.wait();
    console.log("tx status:", rc.status, "gasUsed:", rc.gasUsed.toString());
    const after = await ce.getRoom(roomId);
    console.log("after: phase=", Number(after.phase), "turn=", Number(after.turnId));
    console.log("member0 hp:", after.members[0].hp.toString(), "enemy0 hp:", after.enemies[0].hp.toString());
  } catch (e: any) {
    console.log("FAILED:", e.shortMessage || e.message);
  }
}
main().catch((e) => { console.error(e); process.exitCode = 1; });

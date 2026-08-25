import { ethers } from "hardhat";
import { getContracts } from "../lib/artifacts";
async function main() {
  const [deployer] = await ethers.getSigners();
  const chainId = Number((await ethers.provider.getNetwork()).chainId);
  const { contracts } = getContracts(deployer, chainId);
  const ce = contracts.CombatEngine;
  const roomId = Number(process.env.ROOM_ID || 3);
  let r = await ce.getRoom(roomId);
  let phase = Number(r.phase);
  console.log(`room ${roomId} phase=${phase}`);
  for (let i = 0; i < 60 && phase === 1; i++) {
    await (await ce.advanceTurn(roomId, { gasLimit: 2_000_000 })).wait();
    r = await ce.getRoom(roomId);
    phase = Number(r.phase);
  }
  console.log(`final phase=${phase} turn=${Number(r.turnId)} memberCount=${Number(r.memberCount)} enemyCount=${Number(r.enemyCount)}`);
  const aliveM = r.members.slice(0, Number(r.memberCount)).filter((m: any) => m.alive).length;
  const aliveE = r.enemies.slice(0, Number(r.enemyCount)).filter((e: any) => e.alive).length;
  console.log(`aliveMembers=${aliveM} aliveEnemies=${aliveE} rewardPool=${Number(r.rewardPool)}`);
}
main().catch((e) => { console.error(e); process.exitCode = 1; });

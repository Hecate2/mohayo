import { ethers } from "hardhat";
import { ethers as rawEthers } from "ethers";
import { getContracts } from "../lib/artifacts";

// 私链战斗全流程集成测试（Anvil 账户模拟，无需 vanity 私钥）。
// 覆盖：create-room → join-room(×2) → set-plan(×2) → start-combat → advance-turn 直至结算。
// 用法：npx hardhat run scripts/flow.ts --network anvil

const ALICE = "0x00000000000000000000000000000000000A11CE";
const BOB = "0x0000000000000000000000000000000000000B0B";
const RPC = process.env.ANVIL_RPC || "http://127.0.0.1:8545";

async function impersonate(addr: string) {
  await ethers.provider.send("anvil_impersonateAccount", [addr]);
  await ethers.provider.send("anvil_setBalance", [addr, "0x56BC75E2D63100000"]); // 100 ETH 供 gas
}

async function main() {
  const [deployer] = await ethers.getSigners();
  const chainId = Number((await ethers.provider.getNetwork()).chainId);
  const { contracts } = getContracts(deployer, chainId);
  const { CombatEngine: ce, CharacterRegistry: cr } = contracts;

  // 1. 模拟 alice/bob：Anvil impersonate + 独立 JsonRpcSigner 直连节点
  await impersonate(ALICE);
  await impersonate(BOB);
  const rawProvider = new rawEthers.JsonRpcProvider(RPC);
  const alice = await rawProvider.getSigner(ALICE);
  const bob = await rawProvider.getSigner(BOB);
  console.log("impersonated alice/bob");

  // 2. 创建房间（deployer 为 leader）
  const rc0 = await (await ce.createRoom(1)).wait();
  const ev0 = rc0.logs
    .map((l: any) => {
      try { return ce.interface.parseLog(l); } catch { return null; }
    })
    .find((e: any) => e && e.name === "RoomCreated");
  const roomId = Number(ev0.args.roomId);
  console.log(`Room ${roomId} created (leader=${deployer.address})`);

  // 3. 加入房间
  await (await ce.connect(alice).joinRoom(roomId, 1)).wait();
  console.log("alice joined with token 1");
  await (await ce.connect(bob).joinRoom(roomId, 2)).wait();
  console.log("bob joined with token 2");

  // 4. 设置技能计划（attack 循环）
  const plan = new Array(16).fill(0);
  plan[0] = 1;
  await (await ce.connect(alice).setPlan(roomId, plan, 1)).wait();
  await (await ce.connect(bob).setPlan(roomId, plan, 1)).wait();
  console.log("plans set (attack loop)");

  // 5. 开始战斗
  await (await ce.startCombat(roomId)).wait();
  console.log("combat started");

  // 6. 推进回合直至结算（上限 60 回合防死循环）
  // 显式 gasLimit：战斗结算走 DELEGATECALL 库，estimateGas 可能略低估导致 OOG
  const GAS = { gasLimit: 2_000_000 };
  let phase = 1;
  let turns = 0;
  for (let i = 0; i < 60 && phase === 1; i++) {
    await (await ce.advanceTurn(roomId, GAS)).wait();
    const r = await ce.getRoom(roomId);
    phase = Number(r.phase);
    turns = Number(r.turnId);
  }
  console.log(`advanced ${turns} turns, phase=${phase}`);

  // 7. 最终状态
  const r = await ce.getRoom(roomId);
  const aliveMembers = r.members.slice(0, Number(r.memberCount)).filter((m: any) => m.alive).length;
  const aliveEnemies = r.enemies.slice(0, Number(r.enemyCount)).filter((e: any) => e.alive).length;
  console.log(JSON.stringify({
    phase: Number(r.phase),
    turnId: Number(r.turnId),
    manaPool: Number(r.manaPool),
    rewardPool: Number(r.rewardPool),
    memberCount: Number(r.memberCount),
    enemyCount: Number(r.enemyCount),
    aliveMembers,
    aliveEnemies,
    bossSpawned: r.bossSpawned,
  }, null, 2));

  // 8. 结算断言
  if (phase !== 2) {
    throw new Error(`combat did not settle (phase=${phase})`);
  }
  if (aliveMembers === 0) {
    console.log("RESULT: DEFEAT (all members down)");
  } else {
    console.log("RESULT: VICTORY");
  }
  console.log("FLOW TEST PASSED");
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});

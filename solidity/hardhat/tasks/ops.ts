import { task } from "hardhat/config";
import { getContracts } from "../lib/artifacts";

// 链下运维任务：GM 铸造、房间/战斗流程、状态查询。
// 用法：npx hardhat gm-mint --network anvil --to <addr> --class 1 --race 0 [--skill 1,2]
//       npx hardhat create-room --network anvil --difficulty 1
//       npx hardhat advance-turn --network anvil --room 1
//       --signer <privateKey> 可选：默认用网络配置账户；传私钥可模拟任意玩家（如 alice/bob）。

function networkChainId() {
  return Number(process.env.HARDHAT_NETWORK === "testnet" ? process.env.TESTNET_CHAIN_ID || 0 : 1337);
}

async function getSigner(hre: any, signerKey?: string) {
  if (signerKey) return new hre.ethers.Wallet(signerKey, hre.ethers.provider);
  const [s] = await hre.ethers.getSigners();
  return s;
}

function addSignerParam(t: any) {
  return t.addOptionalParam("signer", "操作者私钥（默认网络账户）", "");
}

task("gm-mint", "GM 铸造指定属性角色（测试网全功能，主网物理移除）")
  .addParam("to", "接收地址")
  .addOptionalParam("class", "职业 id", "1")
  .addOptionalParam("race", "种族 id", "0")
  .addOptionalParam("skills", "技能 id 列表，逗号分隔", "")
  .addOptionalParam("affixes", "词条 id 列表，逗号分隔", "")
  .setAction(async (args, hre) => {
    const signer = await getSigner(hre, args.signer);
    const { contracts } = getContracts(signer, networkChainId());
    const skills = args.skills ? args.skills.split(",").map(Number) : [];
    const affixes = args.affixes ? args.affixes.split(",").map(Number) : [];
    const tx = await contracts.CharacterRegistry.gmMintCharacter(args.to, Number(args.class), Number(args.race), affixes, skills);
    const rc = await tx.wait();
    const ev = rc.logs.map((l: any) => {
      try { return contracts.CharacterRegistry.interface.parseLog(l); } catch { return null; }
    }).find((e: any) => e && e.name === "CharacterCreated");
    console.log(`GM minted token ${ev?.args?.tokenId.toString()} -> ${args.to}`);
  });

task("create-room", "创建地下城房间")
  .addParam("difficulty", "地下城难度 id", "1")
  .setAction(async (args, hre) => {
    const signer = await getSigner(hre, args.signer);
    const { contracts } = getContracts(signer, networkChainId());
    const tx = await contracts.CombatEngine.createRoom(Number(args.difficulty));
    const rc = await tx.wait();
    const ev = rc.logs.map((l: any) => {
      try { return contracts.CombatEngine.interface.parseLog(l); } catch { return null; }
    }).find((e: any) => e && e.name === "RoomCreated");
    console.log(`Room ${ev?.args?.roomId.toString()} created (difficulty ${args.difficulty})`);
  });

task("join-room", "加入房间")
  .addParam("room", "房间 id")
  .addParam("char", "角色 tokenId")
  .setAction(async (args, hre) => {
    const signer = await getSigner(hre, args.signer);
    const { contracts } = getContracts(signer, networkChainId());
    await (await contracts.CombatEngine.joinRoom(Number(args.room), Number(args.char))).wait();
    console.log(`Joined room ${args.room} with char ${args.char}`);
  });

task("set-plan", "设置技能计划")
  .addParam("room", "房间 id")
  .addParam("skills", "技能 id 列表，逗号分隔")
  .setAction(async (args, hre) => {
    const signer = await getSigner(hre, args.signer);
    const { contracts } = getContracts(signer, networkChainId());
    const skills = args.skills.split(",").map(Number);
    // 合约签名 setPlan(uint32, uint16[16], uint8)：定长数组 + 长度
    const plan = new Array(16).fill(0);
    skills.forEach((s, i) => (plan[i] = s));
    await (await contracts.CombatEngine.setPlan(Number(args.room), plan, skills.length)).wait();
    console.log(`Plan set for room ${args.room}: [${skills.join(", ")}]`);
  });

task("start-combat", "开始战斗")
  .addParam("room", "房间 id")
  .setAction(async (args, hre) => {
    const signer = await getSigner(hre, args.signer);
    const { contracts } = getContracts(signer, networkChainId());
    await (await contracts.CombatEngine.startCombat(Number(args.room))).wait();
    console.log(`Combat started in room ${args.room}`);
  });

task("advance-turn", "推进一回合")
  .addParam("room", "房间 id")
  .setAction(async (args, hre) => {
    const signer = await getSigner(hre, args.signer);
    const { contracts } = getContracts(signer, networkChainId());
    await (await contracts.CombatEngine.advanceTurn(Number(args.room))).wait();
    console.log(`Turn advanced in room ${args.room}`);
  });

task("room-state", "查看房间状态")
  .addParam("room", "房间 id")
  .setAction(async (args, hre) => {
    const signer = await getSigner(hre, args.signer);
    const { contracts } = getContracts(signer, networkChainId());
    const r = await contracts.CombatEngine.rooms(Number(args.room));
    console.log(JSON.stringify({
      id: r.id.toString(), difficulty: r.difficulty, phase: r.phase, turnId: r.turnId.toString(),
      manaPool: r.manaPool.toString(), rewardPool: r.rewardPool.toString(),
      memberCount: r.memberCount, enemyCount: r.enemyCount, bossSpawned: r.bossSpawned,
    }, null, 2));
  });

task("char-state", "查看角色状态")
  .addParam("token", "角色 tokenId")
  .setAction(async (args, hre) => {
    const signer = await getSigner(hre, args.signer);
    const { contracts } = getContracts(signer, networkChainId());
    const c = await contracts.CharacterRegistry.characters(Number(args.token));
    console.log(JSON.stringify({
      classId: c.classId, race: c.race, level: c.level, hp: c.hp.toString(), maxHp: c.maxHp.toString(),
      attack: c.attack.toString(), magic: c.magic.toString(), speed: c.speed.toString(),
      roomId: c.roomId.toString(), skillCount: c.skillCount,
    }, null, 2));
  });

task("vault-give", "房间金库道具划转（GM/引擎内部账本）")
  .addParam("room", "房间 id")
  .addParam("to", "接收地址")
  .addParam("item", "道具 id")
  .addParam("count", "数量", "1")
  .setAction(async (args, hre) => {
    const signer = await getSigner(hre, args.signer);
    const { contracts } = getContracts(signer, networkChainId());
    await (await contracts.CombatEngine.gmGiveItem(Number(args.room), args.to, Number(args.item), Number(args.count))).wait();
    console.log(`Vault give item ${args.item} x${args.count} -> ${args.to} in room ${args.room}`);
  });

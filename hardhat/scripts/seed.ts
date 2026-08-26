import { ethers } from "hardhat";
import { getContracts } from "../lib/artifacts";

// 播种测试数据（与 script/Seed.s.sol 同口径，保证合约测试与私链验证同一状态）。
// 用法：npx hardhat run scripts/seed.ts --network anvil
async function main() {
  const [deployer] = await ethers.getSigners();
  const chainId = Number((await ethers.provider.getNetwork()).chainId);
  const { contracts } = getContracts(deployer, chainId);
  const { RNGRouter, Economy, SkillRegistry: sr, CharacterRegistry: cr, CombatEngine: ce } = contracts;

  // ethers v6 合约调用返回 TransactionResponse；用 staticCall 预取返回值再发送。
  const reg = async (fn: any, ...args: any[]) => {
    const id = await fn.staticCall(...args);
    await (await fn(...args)).wait();
    return Number(id);
  };

  // 幂等守卫：各注册表已有数据则跳过对应段落，保证可安全重跑。
  const seeded = Number(await cr.classCount()) > 0;
  const alice = process.env.SEED_ALICE || "0x00000000000000000000000000000000000A11CE";
  const bob = process.env.SEED_BOB || "0x0000000000000000000000000000000000000B0B";

  // ---- 职业（content-design.md §4：剑士/守卫/火枪手/黑魔法师/白魔法师 + 无职业）----
  if (!seeded) {
  await cr.registerClass(1, { baseHp: 120, baseAttack: 30, baseMagic: 10, baseSpeed: 10, skillSlots: 1 }); // 剑士
  await cr.registerClass(2, { baseHp: 135, baseAttack: 18, baseMagic: 8, baseSpeed: 8, skillSlots: 1 }); // 守卫
  await cr.registerClass(3, { baseHp: 90, baseAttack: 28, baseMagic: 8, baseSpeed: 22, skillSlots: 1 }); // 火枪手
  await cr.registerClass(4, { baseHp: 80, baseAttack: 10, baseMagic: 35, baseSpeed: 12, skillSlots: 1 }); // 黑魔法师
  await cr.registerClass(5, { baseHp: 95, baseAttack: 12, baseMagic: 28, baseSpeed: 14, skillSlots: 1 }); // 白魔法师
  await cr.registerClass(6, { baseHp: 100, baseAttack: 20, baseMagic: 20, baseSpeed: 15, skillSlots: 3 }); // 无职业

  // ---- 技能（先注册：种族技 id 供 _seedRaces 引用；与 BaseTest 同口径）----
  const emptyEffects = () => Array.from({ length: 4 }, () => ({ op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000 }));
  const eff = (op: number, duration: number, magnitude: number, scope: number, prob = 1000) => ({ op, duration, magnitude, scope, prob });

  const mkSkill = (p: Partial<any> = {}) => ({
    id: 0, kind: 1, apCost: 0, apGain: 0, ammoId: 0, ammoCost: 0, manaCost: 0, hpCost: 0,
    targeting: 1, weightMode: 0, targetCount: 0, power: 0, damageCap: 0, baseAcc: 1000, flags: 0,
    effects: emptyEffects(), effectCount: 0,
    summon: { templateId: 0, maxCount: 0, enemyHeadroom: 0 },
    ...p,
  });

  const skillAttack = await reg(sr.registerSkill, mkSkill({ kind: 1, targeting: 1, power: 100 }));
  const skillMagicBolt = await reg(sr.registerSkill, mkSkill({ kind: 2, manaCost: 5, targeting: 1, power: 150 }));
  const skillHeal = await reg(sr.registerSkill, mkSkill({ kind: 3, manaCost: 5, targeting: 5, power: 100, effects: [eff(9, 0, 0, 1), ...emptyEffects().slice(1)], effectCount: 1 }));
  const skillStrike3 = await reg(sr.registerSkill, mkSkill({ kind: 1, targeting: 3, targetCount: 3, power: 50, apCost: 10, apGain: 15 }));
  const skillShield = await reg(sr.registerSkill, mkSkill({ kind: 3, manaCost: 5, targeting: 9, effects: [eff(4, 3, 0, 0), ...emptyEffects().slice(1)], effectCount: 1 }));
  const skillStun = await reg(sr.registerSkill, mkSkill({ kind: 1, targeting: 1, power: 50, effects: [eff(1, 2, 0, 1), ...emptyEffects().slice(1)], effectCount: 1 }));
  const skillSmoke = await reg(sr.registerSkill, mkSkill({ kind: 3, manaCost: 5, targeting: 8, effects: [eff(6, 2, 200, 2), ...emptyEffects().slice(1)], effectCount: 1 }));
  const skillManaBurst = await reg(sr.registerSkill, mkSkill({ kind: 3, targeting: 9, effects: [eff(13, 0, 20, 0), ...emptyEffects().slice(1)], effectCount: 1 }));
  const skillDot = await reg(sr.registerSkill, mkSkill({ kind: 2, manaCost: 5, targeting: 1, power: 30, effects: [eff(8, 3, 10, 1), ...emptyEffects().slice(1)], effectCount: 1 }));
  const skillTaunt = await reg(sr.registerSkill, mkSkill({ kind: 3, manaCost: 3, targeting: 1, effects: [eff(11, 2, 0, 1), ...emptyEffects().slice(1)], effectCount: 1 }));
  const skillBerserk = await reg(sr.registerSkill, mkSkill({ kind: 3, targeting: 9, effects: [eff(2, 2, 300, 0), eff(3, 2, 200, 0), ...emptyEffects().slice(2)], effectCount: 2 })); // 兽人
  const skillStoneBody = await reg(sr.registerSkill, mkSkill({ kind: 3, targeting: 9, effects: [eff(4, 4, 80, 0), ...emptyEffects().slice(1)], effectCount: 1 })); // 巨人
  const skillSpiritReturn = await reg(sr.registerSkill, mkSkill({ kind: 3, targeting: 9, effects: [eff(10, 0, 0, 0), eff(9, 0, 30, 0), ...emptyEffects().slice(2)], effectCount: 2 })); // 矮人
  const skillStorm = await reg(sr.registerSkill, mkSkill({ kind: 2, manaCost: 10, targeting: 3, targetCount: 3, power: 60, effects: [eff(1, 1, 0, 1, 300), ...emptyEffects().slice(1)], effectCount: 1 })); // 精灵
  const skillDragonScale = await reg(sr.registerSkill, mkSkill({ kind: 3, targeting: 9, effects: [eff(4, 3, 60, 0), eff(2, 3, 150, 0), ...emptyEffects().slice(2)], effectCount: 2 })); // 龙人
  const skillHolyLight = await reg(sr.registerSkill, mkSkill({ kind: 3, manaCost: 5, targeting: 10, effects: [eff(9, 0, 100, 1), ...emptyEffects().slice(1)], effectCount: 1 })); // 天使 1
  const skillAngelJudgment = await reg(sr.registerSkill, mkSkill({ kind: 2, manaCost: 10, targeting: 3, targetCount: 4, power: 80 })); // 天使 2
  const skillSoulDrain = await reg(sr.registerSkill, mkSkill({ kind: 1, targeting: 1, power: 100, apGain: 10, effects: [eff(12, 0, 300, 0), ...emptyEffects().slice(1)], effectCount: 1 })); // 恶魔 1
  const skillAbyssWhisper = await reg(sr.registerSkill, mkSkill({ kind: 3, manaCost: 5, targeting: 4, effects: [eff(6, 2, 200, 3), ...emptyEffects().slice(1)], effectCount: 1 })); // 恶魔 2
  const skillSummon = await reg(sr.registerSkill, mkSkill({ kind: 4, manaCost: 10, targeting: 9, effects: [eff(14, 0, 0, 0), ...emptyEffects().slice(1)], effectCount: 1, summon: { templateId: 0, maxCount: 0, enemyHeadroom: 0 } }));
  const skillIdle = await reg(sr.registerSkill, mkSkill({ kind: 3, targeting: 9 }));
  await reg(sr.registerClassSkill, mkSkill({ kind: 3, targeting: 9, effects: [eff(7, 2, 0, 0), ...emptyEffects().slice(1)], effectCount: 1 }), 3); // 鹰眼：火枪手 classId=3

  // ---- 种族（content-design.md §3：常见四 + 略稀有二 + 最稀有二，含种族技）----
  await cr.registerRace(0, { statMods: [0, 0, 0], hpMod: 0, raceSkillId: 0, raceSkillId2: 0, selfSelectBonus: 2, exists: true }); // 人类
  await cr.registerRace(1, { statMods: [200, -200, -100], hpMod: 100, raceSkillId: skillBerserk, raceSkillId2: 0, selfSelectBonus: 0, exists: true }); // 兽人
  await cr.registerRace(2, { statMods: [100, -200, -300], hpMod: 300, raceSkillId: skillStoneBody, raceSkillId2: 0, selfSelectBonus: 0, exists: true }); // 巨人
  await cr.registerRace(3, { statMods: [100, -200, -100], hpMod: 150, raceSkillId: skillSpiritReturn, raceSkillId2: 0, selfSelectBonus: 0, exists: true }); // 矮人
  await cr.registerRace(4, { statMods: [-100, 200, 300], hpMod: -100, raceSkillId: skillStorm, raceSkillId2: 0, selfSelectBonus: 0, exists: true }); // 精灵
  await cr.registerRace(5, { statMods: [200, 200, -100], hpMod: -100, raceSkillId: skillDragonScale, raceSkillId2: 0, selfSelectBonus: 0, exists: true }); // 龙人
  await cr.registerRace(6, { statMods: [-200, 300, -50], hpMod: 100, raceSkillId: skillHolyLight, raceSkillId2: skillAngelJudgment, selfSelectBonus: 0, exists: true }); // 天使
  await cr.registerRace(7, { statMods: [300, -100, 200], hpMod: -150, raceSkillId: skillSoulDrain, raceSkillId2: skillAbyssWhisper, selfSelectBonus: 0, exists: true }); // 恶魔

  // ---- 词条模板（content-design.md §6.2：18 条可实现）----
  const tier = [450, 300, 160, 75, 15];
  // 正面（5）
  await cr.registerAffixTemplate(1, { direction: 0, resourceType: 0, manaDiscount: 0, apBonus: 0, manaGainBonus: 0, apCapBonus: 0, statMods: [100, 0, 0], hpMod: 0, tierWeights: tier }); // 巨力
  await cr.registerAffixTemplate(2, { direction: 0, resourceType: 0, manaDiscount: 0, apBonus: 0, manaGainBonus: 0, apCapBonus: 0, statMods: [0, 100, 0], hpMod: 0, tierWeights: tier }); // 魔性
  await cr.registerAffixTemplate(3, { direction: 0, resourceType: 0, manaDiscount: 0, apBonus: 0, manaGainBonus: 0, apCapBonus: 0, statMods: [0, 0, 0], hpMod: 150, tierWeights: tier }); // 铁躯
  await cr.registerAffixTemplate(4, { direction: 0, resourceType: 0, manaDiscount: 0, apBonus: 0, manaGainBonus: 0, apCapBonus: 0, statMods: [0, 0, 100], hpMod: 0, tierWeights: tier }); // 迅捷
  await cr.registerAffixTemplate(5, { direction: 0, resourceType: 1, manaDiscount: 0, apBonus: 0, manaGainBonus: 1, apCapBonus: 0, statMods: [0, 0, 0], hpMod: 0, tierWeights: tier }); // 聚魔
  // 双刃（9）
  await cr.registerAffixTemplate(6, { direction: 1, resourceType: 0, manaDiscount: 0, apBonus: 0, manaGainBonus: 0, apCapBonus: 0, statMods: [0, 300, 0], hpMod: -100, tierWeights: tier }); // 玻璃法杖
  await cr.registerAffixTemplate(7, { direction: 1, resourceType: 0, manaDiscount: 0, apBonus: 0, manaGainBonus: 0, apCapBonus: 0, statMods: [-50, 0, 200], hpMod: 0, tierWeights: tier }); // 轻装突袭
  await cr.registerAffixTemplate(8, { direction: 1, resourceType: 0, manaDiscount: 0, apBonus: 0, manaGainBonus: 0, apCapBonus: 0, statMods: [250, -150, 0], hpMod: 0, tierWeights: tier }); // 蛮力觉醒
  await cr.registerAffixTemplate(9, { direction: 1, resourceType: 0, manaDiscount: 0, apBonus: 0, manaGainBonus: 0, apCapBonus: 0, statMods: [-150, 250, 0], hpMod: 0, tierWeights: tier }); // 贤者血脉
  await cr.registerAffixTemplate(10, { direction: 1, resourceType: 0, manaDiscount: 0, apBonus: 0, manaGainBonus: 0, apCapBonus: 0, statMods: [0, 0, -100], hpMod: 200, tierWeights: tier }); // 磐石骨架
  await cr.registerAffixTemplate(11, { direction: 1, resourceType: 0, manaDiscount: 0, apBonus: 0, manaGainBonus: 0, apCapBonus: 0, statMods: [0, 0, 200], hpMod: -100, tierWeights: tier }); // 疾风之躯
  await cr.registerAffixTemplate(12, { direction: 1, resourceType: 1, manaDiscount: 1, apBonus: 0, manaGainBonus: 0, apCapBonus: 0, statMods: [0, 0, -100], hpMod: 0, tierWeights: tier }); // 默诵
  await cr.registerAffixTemplate(13, { direction: 1, resourceType: 1, manaDiscount: 0, apBonus: 1, manaGainBonus: -1, apCapBonus: 0, statMods: [0, 0, 0], hpMod: 0, tierWeights: tier }); // 好战本能
  await cr.registerAffixTemplate(14, { direction: 1, resourceType: 1, manaDiscount: 0, apBonus: 0, manaGainBonus: 0, apCapBonus: 5, statMods: [0, -100, 0], hpMod: 0, tierWeights: tier }); // 斗魂
  // 负面（4）
  await cr.registerAffixTemplate(15, { direction: 2, resourceType: 0, manaDiscount: 0, apBonus: 0, manaGainBonus: 0, apCapBonus: 0, statMods: [0, 0, 0], hpMod: -100, tierWeights: tier }); // 脆弱
  await cr.registerAffixTemplate(16, { direction: 2, resourceType: 0, manaDiscount: 0, apBonus: 0, manaGainBonus: 0, apCapBonus: 0, statMods: [0, 0, -100], hpMod: 0, tierWeights: tier }); // 迟钝
  await cr.registerAffixTemplate(17, { direction: 2, resourceType: 1, manaDiscount: 0, apBonus: 0, manaGainBonus: -1, apCapBonus: 0, statMods: [0, 0, 0], hpMod: 0, tierWeights: tier }); // 散魔
  await cr.registerAffixTemplate(18, { direction: 2, resourceType: 0, manaDiscount: 0, apBonus: 0, manaGainBonus: 0, apCapBonus: 0, statMods: [0, -100, 0], hpMod: 0, tierWeights: tier }); // 魔素蚀体

  // ---- 怪物 AI 与敌人模板 ----
  const aiSlime = await reg(sr.registerAI, { skillCycle: [skillAttack, 0, 0, 0, 0, 0, 0, 0], cycleLen: 1 });
  const aiBoss = await reg(sr.registerAI, { skillCycle: [skillAttack, skillAttack, skillMagicBolt, 0, 0, 0, 0, 0], cycleLen: 3 });

  const templateSlime = await reg(sr.registerTemplate, {
    aiId: aiSlime, threat: 1, maxHp: 50, power: 12, magic: 5, speed: 8, baseAcc: 1000,
    rewardMin: 5, rewardMax: 10, onDeathSpawn: { templateId: 0, count: 0, prob: 0 },
  });
  const templateBoss = await reg(sr.registerTemplate, {
    aiId: aiBoss, threat: 5, maxHp: 200, power: 25, magic: 15, speed: 12, baseAcc: 1000,
    rewardMin: 30, rewardMax: 50, onDeathSpawn: { templateId: templateSlime, count: 2, prob: 500 },
  });
  await reg(sr.registerTemplate, {
    aiId: aiSlime, threat: 1, maxHp: 30, power: 10, magic: 3, speed: 6, baseAcc: 1000,
    rewardMin: 3, rewardMax: 6, onDeathSpawn: { templateId: 0, count: 0, prob: 0 },
  });

  // ---- 地下城 ----
  await ce.registerEnemyTable(1, [templateSlime], [100]);
  await ce.setDungeon(1, { tableId: 1, enemyCount: 2, manaPerTurn: 10, rewardBase: 20, entryFee: 5, rescueFee: 10, turnInterval: 5 });

  // ---- 测试角色（GM 铸造，固定属性，供 CLI/Bot 联调）----
  await (await cr.gmMintCharacter(alice, 1, 0, [], [skillAttack])).wait();
  await (await cr.gmMintCharacter(bob, 3, 0, [], [skillAttack])).wait();
  } // end if (!seeded)

  console.log("Seed complete on chain", chainId);
  console.log("  skills:", (await sr.skillCount()).toString());
  console.log("  ais:", (await sr.aiCount()).toString());
  console.log("  templates:", (await sr.templateCount()).toString());
  console.log("  alice chars:", (await cr.balanceOf(alice)).toString());
  console.log("  bob chars:", (await cr.balanceOf(bob)).toString());
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});

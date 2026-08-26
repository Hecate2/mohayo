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
  // 千分比增量（与种族/词条同约定：1000+mod 为乘数）；1 级职业值与原口径一致（与 BaseTest 同口径）
  if (!seeded) {
  await cr.registerClass(1, { baseHpPct: 200, baseAttackPct: 2000, baseMagicPct: 0, baseSpeedPct: 0, skillSlots: 1, exists: true }); // 剑士
  await cr.registerClass(2, { baseHpPct: 350, baseAttackPct: 800, baseMagicPct: -200, baseSpeedPct: -200, skillSlots: 1, exists: true }); // 守卫
  await cr.registerClass(3, { baseHpPct: -100, baseAttackPct: 1800, baseMagicPct: -200, baseSpeedPct: 1200, skillSlots: 1, exists: true }); // 火枪手
  await cr.registerClass(4, { baseHpPct: -200, baseAttackPct: 0, baseMagicPct: 2500, baseSpeedPct: 200, skillSlots: 1, exists: true }); // 黑魔法师
  await cr.registerClass(5, { baseHpPct: -50, baseAttackPct: 200, baseMagicPct: 1800, baseSpeedPct: 400, skillSlots: 1, exists: true }); // 白魔法师
  await cr.registerClass(6, { baseHpPct: 0, baseAttackPct: 1000, baseMagicPct: 1000, baseSpeedPct: 500, skillSlots: 3, exists: true }); // 无职业

  // ---- 技能（先注册：种族技 id 供 _seedRaces 引用；与 BaseTest 同口径；资源以 1 为单位：小 1-3 / 中 3-5 / 大 10）----
  const emptyEffects = () => Array.from({ length: 4 }, () => ({ op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000 }));
  const eff = (op: number, duration: number, magnitude: number, scope: number, prob = 1000) => ({ op, duration, magnitude, scope, prob });

  const mkSkill = (p: Partial<any> = {}) => ({
    id: 0, kind: 1, apCost: 0, apGain: 0, ammoId: 0, ammoCost: 0, manaCost: 0, hpCost: 0,
    targeting: 1, weightMode: 0, targetCount: 0, power: 0, damageCap: 0, baseAcc: 1000, flags: 0,
    effects: emptyEffects(), effectCount: 0,
    summon: { templateId: 0, maxCount: 0, enemyHeadroom: 0 },
    ...p,
  });

  // 通用技能（公共自选池）
  const skillAttack = await reg(sr.registerSkill, mkSkill({ kind: 1, targeting: 1, power: 100 })); // 普攻
  const skillMagicBolt = await reg(sr.registerSkill, mkSkill({ kind: 2, manaCost: 1, targeting: 1, power: 150 })); // 魔弹
  const skillHeal = await reg(sr.registerSkill, mkSkill({ kind: 3, manaCost: 1, targeting: 5, power: 100, effects: [eff(9, 0, 0, 1), ...emptyEffects().slice(1)], effectCount: 1 })); // 治疗
  const skillStrike3 = await reg(sr.registerSkill, mkSkill({ kind: 1, apCost: 1, apGain: 2, targeting: 3, targetCount: 3, power: 50 })); // 快速剑
  const skillShield = await reg(sr.registerSkill, mkSkill({ kind: 3, manaCost: 1, targeting: 9, effects: [eff(4, 3, 0, 0), ...emptyEffects().slice(1)], effectCount: 1 })); // 盾墙
  const skillStun = await reg(sr.registerSkill, mkSkill({ kind: 1, apCost: 3, targeting: 1, power: 50, effects: [eff(1, 2, 0, 1), ...emptyEffects().slice(1)], effectCount: 1 })); // 盾击
  const skillSmoke = await reg(sr.registerSkill, mkSkill({ kind: 3, manaCost: 1, targeting: 8, effects: [eff(6, 2, 200, 2), ...emptyEffects().slice(1)], effectCount: 1 })); // 尘幕
  const skillManaBurst = await reg(sr.registerSkill, mkSkill({ kind: 3, targeting: 9, effects: [eff(13, 0, 1, 0), ...emptyEffects().slice(1)], effectCount: 1 })); // 魔素涌动
  const skillDot = await reg(sr.registerSkill, mkSkill({ kind: 1, apCost: 2, targeting: 1, power: 200, baseAcc: 950, effects: [eff(8, 3, 18, 1), ...emptyEffects().slice(1)], effectCount: 1 })); // 毒刃（物理+固定DOT）
  const skillTaunt = await reg(sr.registerSkill, mkSkill({ kind: 3, manaCost: 1, targeting: 1, effects: [eff(11, 2, 0, 1), ...emptyEffects().slice(1)], effectCount: 1 })); // 嘲讽
  const skillSummon = await reg(sr.registerSkill, mkSkill({ kind: 4, manaCost: 3, targeting: 9, effects: [eff(14, 0, 0, 0), ...emptyEffects().slice(1)], effectCount: 1, summon: { templateId: 0, maxCount: 1, enemyHeadroom: 2 } })); // 召唤
  const skillIdle = await reg(sr.registerSkill, mkSkill({ kind: 3, targeting: 9 })); // 待机

  // 一闪：公共自选池（原剑士职业技移入）（小技能：AP 1）
  const skillFlash = await reg(sr.registerSkill, mkSkill({ kind: 1, apCost: 1, targeting: 1, power: 350, damageCap: 350, baseAcc: 650 }));
  // 暴风剑：公共自选池·爆发（高命中四连斩、随机目标多段、高 AP 消耗）（中等技能：AP 5）
  const skillStormBlade = await reg(sr.registerSkill, mkSkill({ kind: 1, apCost: 5, targeting: 3, targetCount: 4, power: 250, baseAcc: 900 }));

  // 种族技
  const skillBerserk = await reg(sr.registerSkill, mkSkill({ kind: 3, targeting: 9, effects: [eff(2, 2, 300, 0), eff(3, 2, 200, 0), ...emptyEffects().slice(2)], effectCount: 2 })); // 兽人·狂暴
  const skillStoneBody = await reg(sr.registerSkill, mkSkill({ kind: 3, targeting: 9, effects: [eff(4, 4, 80, 0), ...emptyEffects().slice(1)], effectCount: 1 })); // 巨人·磐石之躯
  const skillSpiritReturn = await reg(sr.registerSkill, mkSkill({ kind: 3, targeting: 9, effects: [eff(10, 0, 0, 0), eff(9, 0, 30, 0), ...emptyEffects().slice(2)], effectCount: 2 })); // 矮人·烈酒回魂
  const skillStorm = await reg(sr.registerSkill, mkSkill({ kind: 2, manaCost: 3, targeting: 3, targetCount: 3, power: 60, effects: [eff(1, 1, 0, 1, 300), ...emptyEffects().slice(1)], effectCount: 1 })); // 精灵·暴风术
  const skillDragonScale = await reg(sr.registerSkill, mkSkill({ kind: 3, targeting: 9, effects: [eff(4, 3, 60, 0), eff(2, 3, 150, 0), ...emptyEffects().slice(2)], effectCount: 2 })); // 龙人·龙鳞
  const skillHolyLight = await reg(sr.registerSkill, mkSkill({ kind: 3, manaCost: 1, targeting: 10, effects: [eff(9, 0, 100, 1), ...emptyEffects().slice(1)], effectCount: 1 })); // 天使·圣愈之光
  const skillAngelJudgment = await reg(sr.registerSkill, mkSkill({ kind: 2, manaCost: 3, targeting: 3, targetCount: 4, power: 80 })); // 天使·天使雷击
  const skillSoulDrain = await reg(sr.registerSkill, mkSkill({ kind: 1, apGain: 1, targeting: 1, power: 100, effects: [eff(12, 0, 300, 0), ...emptyEffects().slice(1)], effectCount: 1 })); // 恶魔·汲魂
  const skillAbyssWhisper = await reg(sr.registerSkill, mkSkill({ kind: 3, manaCost: 1, targeting: 4, effects: [eff(6, 2, 200, 3), ...emptyEffects().slice(1)], effectCount: 1 })); // 恶魔·深渊低语

  // 职业技（classId 绑定）
  await reg(sr.registerClassSkill, mkSkill({ kind: 3, targeting: 9, effects: [eff(7, 2, 0, 0), ...emptyEffects().slice(1)], effectCount: 1 }), 3); // 鹰眼：火枪手 classId=3（小技能：AP 1）
  await reg(sr.registerClassSkill, mkSkill({ kind: 2, apCost: 1, apGain: 1, manaCost: 1, targeting: 1, power: 200 }), 1); // 魔法剑：剑士 classId=1
  await reg(sr.registerClassSkill, mkSkill({ kind: 1, apGain: 1, ammoId: 1, ammoCost: 3, targeting: 3, targetCount: 3, power: 60, baseAcc: 700 }), 3); // 左轮弹雨：火枪手 classId=1
  await reg(sr.registerClassSkill, mkSkill({ kind: 1, ammoId: 2, ammoCost: 1, targeting: 1, power: 300, effects: [eff(13, 0, 1, 0), ...emptyEffects().slice(1)], effectCount: 1 }), 3); // 龙击弹：火枪手 classId=2
  await reg(sr.registerClassSkill, mkSkill({ kind: 2, apCost: 2, manaCost: 0, targeting: 4, power: 500, flags: 3, effects: [eff(1, 3, 0, 0), ...emptyEffects().slice(1)], effectCount: 1 }), 4); // 爆裂魔法：黑魔法师 classId=4

  // ---- 种族（content-design.md §3：常见四 + 略稀有二 + 最稀有二，含种族技）----
  await cr.registerRace(0, { statMods: [0, 0, 0], hpMod: 0, raceSkillId: 0, raceSkillId2: 0, selfSelectBonus: 2, exists: true }); // 人类：基准，自选 +2
  await cr.registerRace(1, { statMods: [200, -200, -100], hpMod: 100, raceSkillId: skillBerserk, raceSkillId2: 0, selfSelectBonus: 0, exists: true }); // 兽人：物攻+20%/魔攻-20%/敏捷-10%/生命+10%
  await cr.registerRace(2, { statMods: [100, -200, -300], hpMod: 300, raceSkillId: skillStoneBody, raceSkillId2: 0, selfSelectBonus: 0, exists: true }); // 巨人：生命+30%/物攻+10%/魔攻-20%/敏捷-30%
  await cr.registerRace(3, { statMods: [100, -200, -100], hpMod: 150, raceSkillId: skillSpiritReturn, raceSkillId2: 0, selfSelectBonus: 0, exists: true }); // 矮人：生命+15%/物攻+10%/魔攻-20%/敏捷-10%
  await cr.registerRace(4, { statMods: [-100, 200, 300], hpMod: -100, raceSkillId: skillStorm, raceSkillId2: 0, selfSelectBonus: 0, exists: true }); // 精灵：敏捷+30%/魔攻+20%/生命-10%/物攻-10%
  await cr.registerRace(5, { statMods: [200, 200, -100], hpMod: -100, raceSkillId: skillDragonScale, raceSkillId2: 0, selfSelectBonus: 0, exists: true }); // 龙人：物攻+20%/魔攻+20%/生命-10%/敏捷-10%
  await cr.registerRace(6, { statMods: [-200, 300, -50], hpMod: 100, raceSkillId: skillHolyLight, raceSkillId2: skillAngelJudgment, selfSelectBonus: 0, exists: true }); // 天使：魔攻+30%/生命+10%/物攻-20%/敏捷-5%
  await cr.registerRace(7, { statMods: [300, -100, 200], hpMod: -150, raceSkillId: skillSoulDrain, raceSkillId2: skillAbyssWhisper, selfSelectBonus: 0, exists: true }); // 恶魔：物攻+30%/敏捷+20%/魔攻-10%/生命-15%

  // ---- 词条模板（四种能力词条；与 Seed.s.sol 同口径）----
  const weights = [400, 220, 140, 90, 60, 35, 25, 15, 10, 5];
  const values = [0, 100, 250, 450, 700, 950, 1200, 1450, 1700, 2000];
  await cr.registerAffixTemplate(1, { statType: 0, exists: false, tierWeights: weights, tierValues: values }); // 生命
  await cr.registerAffixTemplate(2, { statType: 1, exists: false, tierWeights: weights, tierValues: values }); // 物攻
  await cr.registerAffixTemplate(3, { statType: 2, exists: false, tierWeights: weights, tierValues: values }); // 魔攻
  await cr.registerAffixTemplate(4, { statType: 3, exists: false, tierWeights: weights, tierValues: values }); // 敏捷

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
  await ce.setDungeon(1, { tableId: 1, enemyCount: 2, manaPerTurn: 1, rewardBase: 20, entryFee: 5, rescueFee: 10, turnInterval: 5 });

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

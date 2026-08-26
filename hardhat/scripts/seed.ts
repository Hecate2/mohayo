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

  // ---- 职业 ----
  if (!seeded) {
  await cr.registerClass(1, { baseHp: 120, baseAttack: 30, baseMagic: 10, baseSpeed: 10, skillSlots: 1 });
  await cr.registerClass(2, { baseHp: 90, baseAttack: 28, baseMagic: 8, baseSpeed: 22, skillSlots: 1 });
  await cr.registerClass(3, { baseHp: 80, baseAttack: 10, baseMagic: 35, baseSpeed: 12, skillSlots: 1 });
  await cr.registerClass(4, { baseHp: 95, baseAttack: 12, baseMagic: 28, baseSpeed: 14, skillSlots: 1 });
  await cr.registerClass(5, { baseHp: 100, baseAttack: 20, baseMagic: 20, baseSpeed: 15, skillSlots: 3 });

  // ---- 种族 ----
  await cr.registerRace(0, { capPermille: [1000, 1000, 1000], capHpPermille: 1000, raceSkillId: 0, selfSelectBonus: 2 });
  await cr.registerRace(1, { capPermille: [900, 1300, 1100], capHpPermille: 900, raceSkillId: 0, selfSelectBonus: 0 });
  await cr.registerRace(2, { capPermille: [1100, 900, 900], capHpPermille: 1200, raceSkillId: 0, selfSelectBonus: 0 });
  await cr.registerRace(3, { capPermille: [1200, 1200, 1200], capHpPermille: 1200, raceSkillId: 0, selfSelectBonus: 0 });
  await cr.registerRace(4, { capPermille: [1300, 1300, 1100], capHpPermille: 1000, raceSkillId: 0, selfSelectBonus: 0 });

  // ---- 词条模板 ----
  await cr.registerAffixTemplate(1, { direction: 0, resourceType: 0, manaDiscount: 0, apBonus: 0, statMods: [100, 0, 0], hpMod: 0, tierWeights: [300, 250, 200, 150, 100] });
  await cr.registerAffixTemplate(2, { direction: 0, resourceType: 0, manaDiscount: 0, apBonus: 0, statMods: [0, 0, 0], hpMod: 150, tierWeights: [300, 250, 200, 150, 100] });
  await cr.registerAffixTemplate(3, { direction: 1, resourceType: 0, manaDiscount: 0, apBonus: 0, statMods: [250, 0, -100], hpMod: 0, tierWeights: [200, 200, 200, 200, 200] });
  await cr.registerAffixTemplate(4, { direction: 1, resourceType: 0, manaDiscount: 0, apBonus: 0, statMods: [-50, 0, 200], hpMod: 0, tierWeights: [200, 200, 200, 200, 200] });
  await cr.registerAffixTemplate(5, { direction: 1, resourceType: 1, manaDiscount: 5, apBonus: 0, statMods: [0, 300, 0], hpMod: -100, tierWeights: [200, 200, 200, 200, 200] });
  await cr.registerAffixTemplate(6, { direction: 1, resourceType: 2, manaDiscount: 0, apBonus: 3, statMods: [200, 0, -150], hpMod: 0, tierWeights: [200, 200, 200, 200, 200] });
  await cr.registerAffixTemplate(7, { direction: 2, resourceType: 0, manaDiscount: 0, apBonus: 0, statMods: [-100, 0, 0], hpMod: 0, tierWeights: [200, 200, 200, 200, 200] });
  await cr.registerAffixTemplate(8, { direction: 2, resourceType: 0, manaDiscount: 0, apBonus: 0, statMods: [0, 0, 0], hpMod: -100, tierWeights: [200, 200, 200, 200, 200] });

  // ---- 技能（与 Seed.s.sol 完全同口径）----
  const emptyEffects = () => Array.from({ length: 4 }, () => ({ op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000 }));
  const eff = (op: number, duration: number, magnitude: number, scope: number) => ({ op, duration, magnitude, scope, prob: 1000 });

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
  const skillBerserk = await reg(sr.registerSkill, mkSkill({ kind: 3, targeting: 9, effects: [eff(2, 2, 300, 0), eff(3, 2, 200, 0), ...emptyEffects().slice(2)], effectCount: 2 }));
  const skillSummon = await reg(sr.registerSkill, mkSkill({ kind: 4, manaCost: 10, targeting: 9, effects: [eff(14, 0, 0, 0), ...emptyEffects().slice(1)], effectCount: 1, summon: { templateId: 0, maxCount: 0, enemyHeadroom: 0 } }));
  const skillIdle = await reg(sr.registerSkill, mkSkill({ kind: 3, targeting: 9 }));
  await reg(sr.registerClassSkill, mkSkill({ kind: 3, targeting: 9, effects: [eff(7, 2, 0, 0), ...emptyEffects().slice(1)], effectCount: 1 }), 2); // 鹰眼：火枪手

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

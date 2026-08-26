// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RNGRouter} from "../src/core/RNGRouter.sol";
import {BlockEntropyRNG} from "../src/core/BlockEntropyRNG.sol";
import {Economy} from "../src/core/Economy.sol";
import {SkillRegistry} from "../src/core/SkillRegistry.sol";
import {CharacterRegistry} from "../src/core/CharacterRegistry.sol";
import {CombatEngine} from "../src/core/CombatEngine.sol";
import {CombatTypes} from "../src/libs/CombatTypes.sol";
import {MockRNG} from "./mocks/MockRNG.sol";

/// @title BaseTest - 全合约部署 + 测试数据播种（测试共享夹具）
/// @notice 与 Anvil 私链的 Seed 脚本使用同一套数据口径，保证合约测试与客户端测试验证同一状态。
contract BaseTest is Test {
    RNGRouter public rng;
    BlockEntropyRNG public blockRng;
    MockRNG public mockRng;
    Economy public economy;
    SkillRegistry public sr;
    CharacterRegistry public cr;
    CombatEngine public ce;

    bytes32 public constant CAT_COMBAT = keccak256("COMBAT");
    bytes32 public constant CAT_AFFIX = keccak256("AFFIX");
    bytes32 public constant CAT_DROP = keccak256("DROP");

    // 测试账号
    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);
    address public carol = address(0xC4A01);

    // 注册的技能/模板 id（供测试引用）
    uint32 public skillAttack;
    uint32 public skillMagicBolt;
    uint32 public skillHeal;
    uint32 public skillStrike3;
    uint32 public skillShield;
    uint32 public skillStun;
    uint32 public skillSmoke;
    uint32 public skillEagleEye;
    uint32 public skillManaBurst;
    uint32 public skillDot;
    uint32 public skillTaunt;
    uint32 public skillBerserk;
    uint32 public skillSummon;
    uint32 skillIdle; // 待机怪空技能
    uint16 aiSlime;
    uint16 public aiBoss;
    uint16 public templateSlime;
    uint16 public templateBoss;
    uint16 public templateSummoned;

    function setUp() public virtual {
        // 真实时间戳：避免 day=0 与映射默认值冲突（work/mintUsd 的自然日判定）
        vm.warp(1_700_000_000);

        // ---- 部署核心合约 ----
        rng = new RNGRouter();
        blockRng = new BlockEntropyRNG();
        mockRng = new MockRNG();
        mockRng.setSeed(42);
        // 角色创建/词条随机走 RNGRouter（mockRng 确定性）；战斗走房间级链式 PRNG
        rng.setGlobalProvider(address(mockRng));
        rng.setCategoryProvider(CAT_AFFIX, address(mockRng));

        economy = new Economy();
        sr = new SkillRegistry();
        cr = new CharacterRegistry(rng, sr, true); // gmEnabled = true（测试网语义）
        ce = new CombatEngine(sr, cr, economy);

        // ---- 权限授予 ----
        economy.setMinter(address(ce), true);
        economy.setSpender(address(ce), true);
        cr.setCombatEngine(address(ce));

        // ---- 播种测试数据 ----
        _seedClasses();
        _seedRaces();
        _seedAffixes();
        _seedSkills();
        _seedAIAndTemplates();
        _seedDungeons();
    }

    // ---- 职业 ----
    function _seedClasses() internal {
        cr.registerClass(1, CharacterRegistry.ClassDef({baseHp: 120, baseAttack: 30, baseMagic: 10, baseSpeed: 10, skillSlots: 1})); // 战士
        cr.registerClass(2, CharacterRegistry.ClassDef({baseHp: 90, baseAttack: 28, baseMagic: 8, baseSpeed: 22, skillSlots: 1})); // 火枪手
        cr.registerClass(3, CharacterRegistry.ClassDef({baseHp: 80, baseAttack: 10, baseMagic: 35, baseSpeed: 12, skillSlots: 1})); // 黑魔法师
        cr.registerClass(4, CharacterRegistry.ClassDef({baseHp: 95, baseAttack: 12, baseMagic: 28, baseSpeed: 14, skillSlots: 1})); // 白魔法师
        cr.registerClass(5, CharacterRegistry.ClassDef({baseHp: 100, baseAttack: 20, baseMagic: 20, baseSpeed: 15, skillSlots: 3})); // 无职业
    }

    // ---- 种族（上限乘区 + 种族技 + 自选槽加成）----
    function _seedRaces() internal {
        cr.registerRace(0, CharacterRegistry.RaceDef({capPermille: [1000, 1000, 1000], capHpPermille: 1000, raceSkillId: 0, selfSelectBonus: 2})); // 人类
        cr.registerRace(1, CharacterRegistry.RaceDef({capPermille: [900, 1300, 1100], capHpPermille: 900, raceSkillId: 0, selfSelectBonus: 0})); // 精灵
        cr.registerRace(2, CharacterRegistry.RaceDef({capPermille: [1100, 900, 900], capHpPermille: 1200, raceSkillId: 0, selfSelectBonus: 0})); // 龙人
        cr.registerRace(3, CharacterRegistry.RaceDef({capPermille: [1200, 1200, 1200], capHpPermille: 1200, raceSkillId: 0, selfSelectBonus: 0})); // 天使
        cr.registerRace(4, CharacterRegistry.RaceDef({capPermille: [1300, 1300, 1100], capHpPermille: 1000, raceSkillId: 0, selfSelectBonus: 0})); // 恶魔
    }

    // ---- 词条模板（方向 × 档位；资源流词条 ≤2 条）----
    function _seedAffixes() internal {
        // 正面：攻击 +10%
        cr.registerAffixTemplate(1, CharacterRegistry.AffixTemplate({direction: 0, resourceType: 0, manaDiscount: 0, apBonus: 0, statMods: [int64(100), 0, 0], hpMod: 0, tierWeights: [300, 250, 200, 150, 100]}));
        // 正面：HP +15%
        cr.registerAffixTemplate(2, CharacterRegistry.AffixTemplate({direction: 0, resourceType: 0, manaDiscount: 0, apBonus: 0, statMods: [int64(0), 0, 0], hpMod: 150, tierWeights: [300, 250, 200, 150, 100]}));
        // 双刃：攻击 +25% 速度 -10%
        cr.registerAffixTemplate(3, CharacterRegistry.AffixTemplate({direction: 1, resourceType: 0, manaDiscount: 0, apBonus: 0, statMods: [int64(250), 0, -100], hpMod: 0, tierWeights: [uint16(200), 200, 200, 200, 200]}));
        // 双刃：速度 +20% 攻击 -5%
        cr.registerAffixTemplate(4, CharacterRegistry.AffixTemplate({direction: 1, resourceType: 0, manaDiscount: 0, apBonus: 0, statMods: [int64(-50), 0, 200], hpMod: 0, tierWeights: [uint16(200), 200, 200, 200, 200]}));
        // 双刃：魔攻 +30% HP -10%（资源流：默诵 manaDiscount）
        cr.registerAffixTemplate(5, CharacterRegistry.AffixTemplate({direction: 1, resourceType: 1, manaDiscount: 5, apBonus: 0, statMods: [int64(0), 300, 0], hpMod: -100, tierWeights: [uint16(200), 200, 200, 200, 200]}));
        // 双刃：攻击 +20% 速度 -15%（资源流：好战本能 apBonus）
        cr.registerAffixTemplate(6, CharacterRegistry.AffixTemplate({direction: 1, resourceType: 2, manaDiscount: 0, apBonus: 3, statMods: [int64(200), 0, -150], hpMod: 0, tierWeights: [uint16(200), 200, 200, 200, 200]}));
        // 负面：攻击 -10%
        cr.registerAffixTemplate(7, CharacterRegistry.AffixTemplate({direction: 2, resourceType: 0, manaDiscount: 0, apBonus: 0, statMods: [int64(-100), 0, 0], hpMod: 0, tierWeights: [uint16(200), 200, 200, 200, 200]}));
        // 负面：HP -10%
        cr.registerAffixTemplate(8, CharacterRegistry.AffixTemplate({direction: 2, resourceType: 0, manaDiscount: 0, apBonus: 0, statMods: [int64(0), 0, 0], hpMod: -100, tierWeights: [uint16(200), 200, 200, 200, 200]}));
    }

    // ---- 技能 ----
    function _seedSkills() internal {
        // 普攻：物理单目标，apCost 0，命中后 +10 AP
        skillAttack = sr.registerSkill(SkillRegistry.Skill({
            id: 0, kind: 1, apCost: 0, apGain: 10, ammoId: 0, ammoCost: 0, manaCost: 0, hpCost: 0,
            targeting: 1, weightMode: 0, targetCount: 0, power: 100, damageCap: 0, baseAcc: 1000, flags: 0,
            effects: [SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000})],
            effectCount: 0, summon: SkillRegistry.SummonRule({templateId: 0, maxCount: 0, enemyHeadroom: 0})
        }));

        // 魔弹：魔法单目标
        skillMagicBolt = sr.registerSkill(SkillRegistry.Skill({
            id: 0, kind: 2, apCost: 0, apGain: 0, ammoId: 0, ammoCost: 0, manaCost: 5, hpCost: 0,
            targeting: 1, weightMode: 0, targetCount: 0, power: 150, damageCap: 0, baseAcc: 1000, flags: 0,
            effects: [SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000})],
            effectCount: 0, summon: SkillRegistry.SummonRule({templateId: 0, maxCount: 0, enemyHeadroom: 0})
        }));

        // 治疗：我方单目标，HEAL 效果
        skillHeal = sr.registerSkill(SkillRegistry.Skill({
            id: 0, kind: 3, apCost: 0, apGain: 0, ammoId: 0, ammoCost: 0, manaCost: 5, hpCost: 0,
            targeting: 5, weightMode: 1, targetCount: 0, power: 100, damageCap: 0, baseAcc: 1000, flags: 0,
            effects: [SkillRegistry.Effect({op: 9, duration: 0, magnitude: 0, scope: 1, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000})],
            effectCount: 1, summon: SkillRegistry.SummonRule({templateId: 0, maxCount: 0, enemyHeadroom: 0})
        }));

        // 三连击：多段连击（3 段独立目标）
        skillStrike3 = sr.registerSkill(SkillRegistry.Skill({
            id: 0, kind: 1, apCost: 10, apGain: 15, ammoId: 0, ammoCost: 0, manaCost: 0, hpCost: 0,
            targeting: 3, weightMode: 0, targetCount: 3, power: 50, damageCap: 0, baseAcc: 1000, flags: 0,
            effects: [SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000})],
            effectCount: 0, summon: SkillRegistry.SummonRule({templateId: 0, maxCount: 0, enemyHeadroom: 0})
        }));

        // 护盾：SHIELD 效果（盾量 = power × 魔攻）
        skillShield = sr.registerSkill(SkillRegistry.Skill({
            id: 0, kind: 3, apCost: 0, apGain: 0, ammoId: 0, ammoCost: 0, manaCost: 5, hpCost: 0,
            targeting: 9, weightMode: 0, targetCount: 0, power: 100, damageCap: 0, baseAcc: 1000, flags: 0,
            effects: [SkillRegistry.Effect({op: 4, duration: 3, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000})],
            effectCount: 1, summon: SkillRegistry.SummonRule({templateId: 0, maxCount: 0, enemyHeadroom: 0})
        }));

        // 眩晕：STUN 效果（对敌单体）
        skillStun = sr.registerSkill(SkillRegistry.Skill({
            id: 0, kind: 1, apCost: 10, apGain: 0, ammoId: 0, ammoCost: 0, manaCost: 0, hpCost: 0,
            targeting: 1, weightMode: 0, targetCount: 0, power: 50, damageCap: 0, baseAcc: 1000, flags: 0,
            effects: [SkillRegistry.Effect({op: 1, duration: 2, magnitude: 0, scope: 1, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000})],
            effectCount: 1, summon: SkillRegistry.SummonRule({templateId: 0, maxCount: 0, enemyHeadroom: 0})
        }));

        // 烟幕：ROOM_ALL 全体 ACC_DOWN
        skillSmoke = sr.registerSkill(SkillRegistry.Skill({
            id: 0, kind: 3, apCost: 0, apGain: 0, ammoId: 0, ammoCost: 0, manaCost: 5, hpCost: 0,
            targeting: 8, weightMode: 0, targetCount: 0, power: 0, damageCap: 0, baseAcc: 1000, flags: 0,
            effects: [SkillRegistry.Effect({op: 6, duration: 2, magnitude: 200, scope: 2, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000})],
            effectCount: 1, summon: SkillRegistry.SummonRule({templateId: 0, maxCount: 0, enemyHeadroom: 0})
        }));

        // 鹰眼：GUAR_NEXT（职业绑定，仅火枪手）
        skillEagleEye = sr.registerClassSkill(SkillRegistry.Skill({
            id: 0, kind: 3, apCost: 5, apGain: 0, ammoId: 0, ammoCost: 0, manaCost: 0, hpCost: 0,
            targeting: 9, weightMode: 0, targetCount: 0, power: 0, damageCap: 0, baseAcc: 1000, flags: 0,
            effects: [SkillRegistry.Effect({op: 7, duration: 2, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000})],
            effectCount: 1, summon: SkillRegistry.SummonRule({templateId: 0, maxCount: 0, enemyHeadroom: 0})
        }), 2); // 火枪手 classId=2

        // 魔素爆发：MANA_DELTA 注入（圣泉）
        skillManaBurst = sr.registerSkill(SkillRegistry.Skill({
            id: 0, kind: 3, apCost: 0, apGain: 0, ammoId: 0, ammoCost: 0, manaCost: 0, hpCost: 0,
            targeting: 9, weightMode: 0, targetCount: 0, power: 0, damageCap: 0, baseAcc: 1000, flags: 0,
            effects: [SkillRegistry.Effect({op: 13, duration: 0, magnitude: 20, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000})],
            effectCount: 1, summon: SkillRegistry.SummonRule({templateId: 0, maxCount: 0, enemyHeadroom: 0})
        }));

        // 灼烧：DOT 效果
        skillDot = sr.registerSkill(SkillRegistry.Skill({
            id: 0, kind: 2, apCost: 0, apGain: 0, ammoId: 0, ammoCost: 0, manaCost: 5, hpCost: 0,
            targeting: 1, weightMode: 0, targetCount: 0, power: 30, damageCap: 0, baseAcc: 1000, flags: 0,
            effects: [SkillRegistry.Effect({op: 8, duration: 3, magnitude: 10, scope: 1, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000})],
            effectCount: 1, summon: SkillRegistry.SummonRule({templateId: 0, maxCount: 0, enemyHeadroom: 0})
        }));

        // 嘲讽：TAUNT（对敌单体）
        skillTaunt = sr.registerSkill(SkillRegistry.Skill({
            id: 0, kind: 3, apCost: 0, apGain: 0, ammoId: 0, ammoCost: 0, manaCost: 3, hpCost: 0,
            targeting: 1, weightMode: 0, targetCount: 0, power: 0, damageCap: 0, baseAcc: 1000, flags: 0,
            effects: [SkillRegistry.Effect({op: 11, duration: 2, magnitude: 0, scope: 1, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000})],
            effectCount: 1, summon: SkillRegistry.SummonRule({templateId: 0, maxCount: 0, enemyHeadroom: 0})
        }));

        // 狂暴：DMG_OUT_MOD + DMG_IN_MOD（种族技）
        skillBerserk = sr.registerSkill(SkillRegistry.Skill({
            id: 0, kind: 3, apCost: 0, apGain: 0, ammoId: 0, ammoCost: 0, manaCost: 0, hpCost: 0,
            targeting: 9, weightMode: 0, targetCount: 0, power: 0, damageCap: 0, baseAcc: 1000, flags: 0,
            effects: [SkillRegistry.Effect({op: 2, duration: 2, magnitude: 300, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 3, duration: 2, magnitude: 200, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000})],
            effectCount: 2, summon: SkillRegistry.SummonRule({templateId: 0, maxCount: 0, enemyHeadroom: 0})
        }));

        // 召唤（怪物侧）：SUMMON
        skillSummon = sr.registerSkill(SkillRegistry.Skill({
            id: 0, kind: 4, apCost: 0, apGain: 0, ammoId: 0, ammoCost: 0, manaCost: 10, hpCost: 0,
            targeting: 9, weightMode: 0, targetCount: 0, power: 0, damageCap: 0, baseAcc: 1000, flags: 0,
            effects: [SkillRegistry.Effect({op: 14, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000})],
            effectCount: 1, summon: SkillRegistry.SummonRule({templateId: 0, maxCount: 1, enemyHeadroom: 2})
        }));

        // 待机空技能（魔素岩/宝箱）
        skillIdle = sr.registerSkill(SkillRegistry.Skill({
            id: 0, kind: 3, apCost: 0, apGain: 0, ammoId: 0, ammoCost: 0, manaCost: 0, hpCost: 0,
            targeting: 9, weightMode: 0, targetCount: 0, power: 0, damageCap: 0, baseAcc: 1000, flags: 0,
            effects: [SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000})],
            effectCount: 0, summon: SkillRegistry.SummonRule({templateId: 0, maxCount: 0, enemyHeadroom: 0})
        }));
    }

    // ---- 怪物 AI 与敌人模板 ----
    function _seedAIAndTemplates() internal {
        // 史莱姆 AI：普攻循环
        aiSlime = sr.registerAI(SkillRegistry.MonsterAI({
            skillCycle: [uint16(skillAttack), 0, 0, 0, 0, 0, 0, 0],
            cycleLen: 1
        }));
        // Boss AI：普攻 × 2 → 大招（魔弹）
        aiBoss = sr.registerAI(SkillRegistry.MonsterAI({
            skillCycle: [uint16(skillAttack), uint16(skillAttack), uint16(skillMagicBolt), 0, 0, 0, 0, 0],
            cycleLen: 3
        }));

        templateSlime = sr.registerTemplate(SkillRegistry.EnemyTemplate({
            aiId: aiSlime, threat: 1, maxHp: 50, power: 12, magic: 5, speed: 8, baseAcc: 1000,
            rewardMin: 5, rewardMax: 10,
            onDeathSpawn: SkillRegistry.OnDeathSpawn({templateId: 0, count: 0, prob: 0})
        }));

        // Boss：死亡召唤史莱姆（概率 500‰）
        templateBoss = sr.registerTemplate(SkillRegistry.EnemyTemplate({
            aiId: aiBoss, threat: 5, maxHp: 200, power: 25, magic: 15, speed: 12, baseAcc: 1000,
            rewardMin: 30, rewardMax: 50,
            onDeathSpawn: SkillRegistry.OnDeathSpawn({templateId: templateSlime, count: 2, prob: 500})
        }));

        templateSummoned = sr.registerTemplate(SkillRegistry.EnemyTemplate({
            aiId: aiSlime, threat: 1, maxHp: 30, power: 10, magic: 3, speed: 6, baseAcc: 1000,
            rewardMin: 3, rewardMax: 6,
            onDeathSpawn: SkillRegistry.OnDeathSpawn({templateId: 0, count: 0, prob: 0})
        }));
    }

    // ---- 地下城 ----
    function _seedDungeons() internal {
        uint16[] memory ids = new uint16[](1);
        ids[0] = templateSlime;
        uint16[] memory ws = new uint16[](1);
        ws[0] = 100;
        ce.registerEnemyTable(1, ids, ws);
        ce.setDungeon(1, CombatTypes.DungeonConfig({
            tableId: 1, enemyCount: 2, manaPerTurn: 10, rewardBase: 20, entryFee: 5, rescueFee: 10, turnInterval: 5
        }));
    }

    // ---- 测试辅助 ----
    function _createCharacter(address player, uint8 classId, uint32[] memory skillIds) internal returns (uint256 tokenId) {
        vm.prank(player);
        tokenId = cr.createCharacter(classId, skillIds);
    }

    function _gmCharacter(address player, uint8 classId, uint8 race, uint16[] memory affixIds, uint32[] memory skillIds) internal returns (uint256 tokenId) {
        tokenId = cr.gmMintCharacter(player, classId, race, affixIds, skillIds);
    }

    function _joinAndStart(address leader, uint32 roomId, uint256 charId) internal {
        vm.prank(leader);
        ce.joinRoom(roomId, charId);
        vm.prank(leader);
        ce.startCombat(roomId);
    }
}

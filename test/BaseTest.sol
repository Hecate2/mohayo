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
    uint32 public skillBerserk; // 兽人种族技
    uint32 public skillSummon;
    uint32 skillIdle; // 待机怪空技能
    // 本轮新增（用户定案）
    uint32 public skillFlash; // 一闪（公共自选池）
    uint32 public skillStormBlade; // 暴风剑（公共自选池·爆发）
    uint32 public skillMagicSword; // 魔法剑（剑士职业技）
    uint32 public skillRevolverRain; // 左轮弹雨（火枪手职业技）
    uint32 public skillDragonBullet; // 龙击弹（火枪手职业技）
    uint32 public skillBurstMagic; // 爆裂魔法（黑魔法师职业技）
    // 种族技（8 种族）
    uint32 public skillStoneBody; // 磐石之躯（巨人）
    uint32 public skillSpiritReturn; // 烈酒回魂（矮人）
    uint32 public skillStorm; // 暴风术（精灵）
    uint32 public skillDragonScale; // 龙鳞（龙人）
    uint32 public skillHolyLight; // 圣愈之光（天使）
    uint32 public skillAngelJudgment; // 天使雷击（天使）
    uint32 public skillSoulDrain; // 汲魂（恶魔）
    uint32 public skillAbyssWhisper; // 深渊低语（恶魔）
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
        _seedSkills(); // 先注册技能（种族技 id 供 _seedRaces 引用）
        _seedRaces();
        _seedAffixes();
        _seedAIAndTemplates();
        _seedDungeons();
    }

    // ---- 职业（content-design.md §4：剑士/守卫/火枪手/黑魔法师/白魔法师 + 无职业）----
    // 千分比**增量**（与种族/词条同约定：1000+mod 为乘数）：剑士 hp +200‰(×1.2)、攻 +2000‰(×3.0) …
    // 1 级能力值 = 基准 × (1000+职业+种族+词条)/1000（与原口径 1 级职业值一致）
    function _seedClasses() internal {
        cr.registerClass(1, CharacterRegistry.ClassDef({baseHpPct: 200, baseAttackPct: 2000, baseMagicPct: 0, baseSpeedPct: 0, skillSlots: 1, exists: true})); // 剑士
        cr.registerClass(2, CharacterRegistry.ClassDef({baseHpPct: 350, baseAttackPct: 800, baseMagicPct: -200, baseSpeedPct: -200, skillSlots: 1, exists: true})); // 守卫
        cr.registerClass(3, CharacterRegistry.ClassDef({baseHpPct: -100, baseAttackPct: 1800, baseMagicPct: -200, baseSpeedPct: 1200, skillSlots: 1, exists: true})); // 火枪手
        cr.registerClass(4, CharacterRegistry.ClassDef({baseHpPct: -200, baseAttackPct: 0, baseMagicPct: 2500, baseSpeedPct: 200, skillSlots: 1, exists: true})); // 黑魔法师
        cr.registerClass(5, CharacterRegistry.ClassDef({baseHpPct: -50, baseAttackPct: 200, baseMagicPct: 1800, baseSpeedPct: 400, skillSlots: 1, exists: true})); // 白魔法师
        cr.registerClass(6, CharacterRegistry.ClassDef({baseHpPct: 0, baseAttackPct: 1000, baseMagicPct: 1000, baseSpeedPct: 500, skillSlots: 3, exists: true})); // 无职业
    }

    // ---- 种族（content-design.md §3：常见四 + 略稀有二 + 最稀有二，含种族技）----
    function _seedRaces() internal {
        cr.registerRace(0, CharacterRegistry.RaceDef({statMods: [int16(0), 0, 0], hpMod: int16(0), raceSkillId: 0, raceSkillId2: 0, selfSelectBonus: 2, exists: true})); // 人类：基准，自选 +2
        cr.registerRace(1, CharacterRegistry.RaceDef({statMods: [int16(200), -200, -100], hpMod: int16(100), raceSkillId: skillBerserk, raceSkillId2: 0, selfSelectBonus: 0, exists: true})); // 兽人：物攻+20%/魔攻-20%/敏捷-10%/生命+10%
        cr.registerRace(2, CharacterRegistry.RaceDef({statMods: [int16(100), -200, -300], hpMod: int16(300), raceSkillId: skillStoneBody, raceSkillId2: 0, selfSelectBonus: 0, exists: true})); // 巨人：生命+30%/物攻+10%/魔攻-20%/敏捷-30%
        cr.registerRace(3, CharacterRegistry.RaceDef({statMods: [int16(100), -200, -100], hpMod: int16(150), raceSkillId: skillSpiritReturn, raceSkillId2: 0, selfSelectBonus: 0, exists: true})); // 矮人：生命+15%/物攻+10%/魔攻-20%/敏捷-10%
        cr.registerRace(4, CharacterRegistry.RaceDef({statMods: [int16(-100), 200, 300], hpMod: int16(-100), raceSkillId: skillStorm, raceSkillId2: 0, selfSelectBonus: 0, exists: true})); // 精灵：敏捷+30%/魔攻+20%/生命-10%/物攻-10%
        cr.registerRace(5, CharacterRegistry.RaceDef({statMods: [int16(200), 200, -100], hpMod: int16(-100), raceSkillId: skillDragonScale, raceSkillId2: 0, selfSelectBonus: 0, exists: true})); // 龙人：物攻+20%/魔攻+20%/生命-10%/敏捷-10%
        cr.registerRace(6, CharacterRegistry.RaceDef({statMods: [int16(-200), 300, -50], hpMod: int16(100), raceSkillId: skillHolyLight, raceSkillId2: skillAngelJudgment, selfSelectBonus: 0, exists: true})); // 天使：魔攻+30%/生命+10%/物攻-20%/敏捷-5%
        cr.registerRace(7, CharacterRegistry.RaceDef({statMods: [int16(300), -100, 200], hpMod: int16(-150), raceSkillId: skillSoulDrain, raceSkillId2: skillAbyssWhisper, selfSelectBonus: 0, exists: true})); // 恶魔：物攻+30%/敏捷+20%/魔攻-10%/生命-15%
    }

    // ---- 词条模板（四种能力词条；资源效果固定四种、由引擎内置）----
    function _seedAffixes() internal {
        uint16[10] memory weights = [uint16(400), 220, 140, 90, 60, 35, 25, 15, 10, 5];
        uint16[10] memory values = [uint16(0), 100, 250, 450, 700, 950, 1200, 1450, 1700, 2000];

        _registerAffix(1, 0, weights, values); // 生命
        _registerAffix(2, 1, weights, values); // 物攻
        _registerAffix(3, 2, weights, values); // 魔攻
        _registerAffix(4, 3, weights, values); // 敏捷
    }

    function _registerAffix(uint16 id, uint8 statType, uint16[10] memory weights, uint16[10] memory values) internal {
        cr.registerAffixTemplate(
            id,
            CharacterRegistry.AffixTemplate({statType: statType, exists: false, tierWeights: weights, tierValues: values})
        );
    }

    // ---- 技能 ----
    function _seedSkills() internal {
        // 普攻：物理单目标，apCost 0，命中后 +1 AP（数量级：AP 以 1 为单位）
        skillAttack = sr.registerSkill(SkillRegistry.Skill({
            id: 0, kind: 1, apCost: 0, apGain: 1, ammoId: 0, ammoCost: 0, manaCost: 0, hpCost: 0,
            targeting: 1, weightMode: 0, targetCount: 0, power: 100, damageCap: 0, baseAcc: 1000, flags: 0,
            effects: [SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000})],
            effectCount: 0, summon: SkillRegistry.SummonRule({templateId: 0, maxCount: 0, enemyHeadroom: 0})
        }));

        // 魔弹：魔法单目标（小技能：魔素 1）
        skillMagicBolt = sr.registerSkill(SkillRegistry.Skill({
            id: 0, kind: 2, apCost: 0, apGain: 0, ammoId: 0, ammoCost: 0, manaCost: 1, hpCost: 0,
            targeting: 1, weightMode: 0, targetCount: 0, power: 150, damageCap: 0, baseAcc: 1000, flags: 0,
            effects: [SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000})],
            effectCount: 0, summon: SkillRegistry.SummonRule({templateId: 0, maxCount: 0, enemyHeadroom: 0})
        }));

        // 治疗：我方单目标，HEAL 效果（小技能：魔素 1）
        skillHeal = sr.registerSkill(SkillRegistry.Skill({
            id: 0, kind: 3, apCost: 0, apGain: 0, ammoId: 0, ammoCost: 0, manaCost: 1, hpCost: 0,
            targeting: 5, weightMode: 1, targetCount: 0, power: 100, damageCap: 0, baseAcc: 1000, flags: 0,
            effects: [SkillRegistry.Effect({op: 9, duration: 0, magnitude: 0, scope: 1, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000})],
            effectCount: 1, summon: SkillRegistry.SummonRule({templateId: 0, maxCount: 0, enemyHeadroom: 0})
        }));

        // 三连击：多段连击（3 段独立目标）——攒点基本功：耗 1 产 2（净 +1/轮）
        skillStrike3 = sr.registerSkill(SkillRegistry.Skill({
            id: 0, kind: 1, apCost: 1, apGain: 2, ammoId: 0, ammoCost: 0, manaCost: 0, hpCost: 0,
            targeting: 3, weightMode: 0, targetCount: 3, power: 50, damageCap: 0, baseAcc: 1000, flags: 0,
            effects: [SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000})],
            effectCount: 0, summon: SkillRegistry.SummonRule({templateId: 0, maxCount: 0, enemyHeadroom: 0})
        }));

        // 护盾：SHIELD 效果（盾量 = power × 魔攻）（小技能：魔素 1）
        skillShield = sr.registerSkill(SkillRegistry.Skill({
            id: 0, kind: 3, apCost: 0, apGain: 0, ammoId: 0, ammoCost: 0, manaCost: 1, hpCost: 0,
            targeting: 9, weightMode: 0, targetCount: 0, power: 100, damageCap: 0, baseAcc: 1000, flags: 0,
            effects: [SkillRegistry.Effect({op: 4, duration: 3, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000})],
            effectCount: 1, summon: SkillRegistry.SummonRule({templateId: 0, maxCount: 0, enemyHeadroom: 0})
        }));

        // 眩晕：STUN 效果（对敌单体）（中等技能：AP 3）
        skillStun = sr.registerSkill(SkillRegistry.Skill({
            id: 0, kind: 1, apCost: 3, apGain: 0, ammoId: 0, ammoCost: 0, manaCost: 0, hpCost: 0,
            targeting: 1, weightMode: 0, targetCount: 0, power: 50, damageCap: 0, baseAcc: 1000, flags: 0,
            effects: [SkillRegistry.Effect({op: 1, duration: 2, magnitude: 0, scope: 1, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000})],
            effectCount: 1, summon: SkillRegistry.SummonRule({templateId: 0, maxCount: 0, enemyHeadroom: 0})
        }));

        // 烟幕：ROOM_ALL 全体 ACC_DOWN（小技能：魔素 1）
        skillSmoke = sr.registerSkill(SkillRegistry.Skill({
            id: 0, kind: 3, apCost: 0, apGain: 0, ammoId: 0, ammoCost: 0, manaCost: 1, hpCost: 0,
            targeting: 8, weightMode: 0, targetCount: 0, power: 0, damageCap: 0, baseAcc: 1000, flags: 0,
            effects: [SkillRegistry.Effect({op: 6, duration: 2, magnitude: 200, scope: 2, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000})],
            effectCount: 1, summon: SkillRegistry.SummonRule({templateId: 0, maxCount: 0, enemyHeadroom: 0})
        }));

        // 鹰眼：GUAR_NEXT（职业绑定，仅火枪手）（小技能：AP 1——行动成本是真正的代价）
        skillEagleEye = sr.registerClassSkill(SkillRegistry.Skill({
            id: 0, kind: 3, apCost: 1, apGain: 0, ammoId: 0, ammoCost: 0, manaCost: 0, hpCost: 0,
            targeting: 9, weightMode: 0, targetCount: 0, power: 0, damageCap: 0, baseAcc: 1000, flags: 0,
            effects: [SkillRegistry.Effect({op: 7, duration: 2, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000})],
            effectCount: 1, summon: SkillRegistry.SummonRule({templateId: 0, maxCount: 0, enemyHeadroom: 0})
        }), 3); // 火枪手 classId=3

        // 魔素爆发：MANA_DELTA 注入（圣泉）（数量级：魔素以 1 为单位）
        skillManaBurst = sr.registerSkill(SkillRegistry.Skill({
            id: 0, kind: 3, apCost: 0, apGain: 0, ammoId: 0, ammoCost: 0, manaCost: 0, hpCost: 0,
            targeting: 9, weightMode: 0, targetCount: 0, power: 0, damageCap: 0, baseAcc: 1000, flags: 0,
            effects: [SkillRegistry.Effect({op: 13, duration: 0, magnitude: 1, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000})],
            effectCount: 1, summon: SkillRegistry.SummonRule({templateId: 0, maxCount: 0, enemyHeadroom: 0})
        }));

        // 毒刃：单体物理斩击 + 固定值持续流血（公共自选池·输出·保底——本轮加强：DOT 不随属性缩放，
        //       低攻角色（无职业/白法）的稳定清场手段；直伤随物攻成长、流血固定，随等级相对衰减不威胁职业招牌）
        //       小技能：AP 2
        skillDot = sr.registerSkill(SkillRegistry.Skill({
            id: 0, kind: 1, apCost: 2, apGain: 0, ammoId: 0, ammoCost: 0, manaCost: 0, hpCost: 0,
            targeting: 1, weightMode: 0, targetCount: 0, power: 200, damageCap: 0, baseAcc: 950, flags: 0,
            effects: [SkillRegistry.Effect({op: 8, duration: 3, magnitude: 18, scope: 1, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000})],
            effectCount: 1, summon: SkillRegistry.SummonRule({templateId: 0, maxCount: 0, enemyHeadroom: 0})
        }));

        // 嘲讽：TAUNT（对敌单体）（小技能：魔素 1）
        skillTaunt = sr.registerSkill(SkillRegistry.Skill({
            id: 0, kind: 3, apCost: 0, apGain: 0, ammoId: 0, ammoCost: 0, manaCost: 1, hpCost: 0,
            targeting: 1, weightMode: 0, targetCount: 0, power: 0, damageCap: 0, baseAcc: 1000, flags: 0,
            effects: [SkillRegistry.Effect({op: 11, duration: 2, magnitude: 0, scope: 1, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000})],
            effectCount: 1, summon: SkillRegistry.SummonRule({templateId: 0, maxCount: 0, enemyHeadroom: 0})
        }));

        // 狂暴：DMG_OUT_MOD + DMG_IN_MOD（兽人种族技）
        skillBerserk = sr.registerSkill(SkillRegistry.Skill({
            id: 0, kind: 3, apCost: 0, apGain: 0, ammoId: 0, ammoCost: 0, manaCost: 0, hpCost: 0,
            targeting: 9, weightMode: 0, targetCount: 0, power: 0, damageCap: 0, baseAcc: 1000, flags: 0,
            effects: [SkillRegistry.Effect({op: 2, duration: 2, magnitude: 300, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 3, duration: 2, magnitude: 200, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000})],
            effectCount: 2, summon: SkillRegistry.SummonRule({templateId: 0, maxCount: 0, enemyHeadroom: 0})
        }));

        // 磐石之躯：自施护盾，持续更久（巨人种族技）
        skillStoneBody = sr.registerSkill(SkillRegistry.Skill({
            id: 0, kind: 3, apCost: 0, apGain: 0, ammoId: 0, ammoCost: 0, manaCost: 0, hpCost: 0,
            targeting: 9, weightMode: 0, targetCount: 0, power: 0, damageCap: 0, baseAcc: 1000, flags: 0,
            effects: [SkillRegistry.Effect({op: 4, duration: 4, magnitude: 80, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000})],
            effectCount: 1, summon: SkillRegistry.SummonRule({templateId: 0, maxCount: 0, enemyHeadroom: 0})
        }));

        // 烈酒回魂：净化自身负面 + 少量回血（矮人种族技）
        skillSpiritReturn = sr.registerSkill(SkillRegistry.Skill({
            id: 0, kind: 3, apCost: 0, apGain: 0, ammoId: 0, ammoCost: 0, manaCost: 0, hpCost: 0,
            targeting: 9, weightMode: 0, targetCount: 0, power: 0, damageCap: 0, baseAcc: 1000, flags: 0,
            effects: [SkillRegistry.Effect({op: 10, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 9, duration: 0, magnitude: 30, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000})],
            effectCount: 2, summon: SkillRegistry.SummonRule({templateId: 0, maxCount: 0, enemyHeadroom: 0})
        }));

        // 暴风术：多段魔法攻击，每段概率眩晕（精灵种族技）（中等技能：魔素 3）
        skillStorm = sr.registerSkill(SkillRegistry.Skill({
            id: 0, kind: 2, apCost: 0, apGain: 0, ammoId: 0, ammoCost: 0, manaCost: 3, hpCost: 0,
            targeting: 3, weightMode: 0, targetCount: 3, power: 60, damageCap: 0, baseAcc: 1000, flags: 0,
            effects: [SkillRegistry.Effect({op: 1, duration: 1, magnitude: 0, scope: 1, prob: 300}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000})],
            effectCount: 1, summon: SkillRegistry.SummonRule({templateId: 0, maxCount: 0, enemyHeadroom: 0})
        }));

        // 龙鳞：自施护盾 + 提升自身造成伤害（龙人种族技）
        skillDragonScale = sr.registerSkill(SkillRegistry.Skill({
            id: 0, kind: 3, apCost: 0, apGain: 0, ammoId: 0, ammoCost: 0, manaCost: 0, hpCost: 0,
            targeting: 9, weightMode: 0, targetCount: 0, power: 0, damageCap: 0, baseAcc: 1000, flags: 0,
            effects: [SkillRegistry.Effect({op: 4, duration: 3, magnitude: 60, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 2, duration: 3, magnitude: 150, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000})],
            effectCount: 2, summon: SkillRegistry.SummonRule({templateId: 0, maxCount: 0, enemyHeadroom: 0})
        }));

        // 圣愈之光：确定性治疗血量亏空比例最高者（天使种族技 1）（小技能：魔素 1）
        skillHolyLight = sr.registerSkill(SkillRegistry.Skill({
            id: 0, kind: 3, apCost: 0, apGain: 0, ammoId: 0, ammoCost: 0, manaCost: 1, hpCost: 0,
            targeting: 10, weightMode: 0, targetCount: 0, power: 0, damageCap: 0, baseAcc: 1000, flags: 0,
            effects: [SkillRegistry.Effect({op: 9, duration: 0, magnitude: 100, scope: 1, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000})],
            effectCount: 1, summon: SkillRegistry.SummonRule({templateId: 0, maxCount: 0, enemyHeadroom: 0})
        }));

        // 天使雷击：多段随机雷电魔法（天使种族技 2）（中等技能：魔素 3）
        skillAngelJudgment = sr.registerSkill(SkillRegistry.Skill({
            id: 0, kind: 2, apCost: 0, apGain: 0, ammoId: 0, ammoCost: 0, manaCost: 3, hpCost: 0,
            targeting: 3, weightMode: 0, targetCount: 4, power: 80, damageCap: 0, baseAcc: 1000, flags: 0,
            effects: [SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000})],
            effectCount: 0, summon: SkillRegistry.SummonRule({templateId: 0, maxCount: 0, enemyHeadroom: 0})
        }));

        // 汲魂：单体攻击并按伤害比例吸血（恶魔种族技 1）（命中产出 AP 1）
        skillSoulDrain = sr.registerSkill(SkillRegistry.Skill({
            id: 0, kind: 1, apCost: 0, apGain: 1, ammoId: 0, ammoCost: 0, manaCost: 0, hpCost: 0,
            targeting: 1, weightMode: 0, targetCount: 0, power: 100, damageCap: 0, baseAcc: 1000, flags: 0,
            effects: [SkillRegistry.Effect({op: 12, duration: 0, magnitude: 300, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000})],
            effectCount: 1, summon: SkillRegistry.SummonRule({templateId: 0, maxCount: 0, enemyHeadroom: 0})
        }));

        // 深渊低语：降低敌方全体命中（恶魔种族技 2）（小技能：魔素 1）
        skillAbyssWhisper = sr.registerSkill(SkillRegistry.Skill({
            id: 0, kind: 3, apCost: 0, apGain: 0, ammoId: 0, ammoCost: 0, manaCost: 1, hpCost: 0,
            targeting: 4, weightMode: 0, targetCount: 0, power: 0, damageCap: 0, baseAcc: 1000, flags: 0,
            effects: [SkillRegistry.Effect({op: 6, duration: 2, magnitude: 200, scope: 3, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000})],
            effectCount: 1, summon: SkillRegistry.SummonRule({templateId: 0, maxCount: 0, enemyHeadroom: 0})
        }));

        // 召唤（怪物侧）：SUMMON（中等技能：魔素 3）
        skillSummon = sr.registerSkill(SkillRegistry.Skill({
            id: 0, kind: 4, apCost: 0, apGain: 0, ammoId: 0, ammoCost: 0, manaCost: 3, hpCost: 0,
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

        // 一闪：低 AP、难命中、命中即大伤害（公共自选池，原剑士职业技移入）（小技能：AP 1）
        skillFlash = sr.registerSkill(SkillRegistry.Skill({
            id: 0, kind: 1, apCost: 1, apGain: 0, ammoId: 0, ammoCost: 0, manaCost: 0, hpCost: 0,
            targeting: 1, weightMode: 0, targetCount: 0, power: 350, damageCap: 350, baseAcc: 650, flags: 0,
            effects: [SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000})],
            effectCount: 0, summon: SkillRegistry.SummonRule({templateId: 0, maxCount: 0, enemyHeadroom: 0})
        }));

        // 暴风剑：高命中四连斩、随机目标多段、消耗大量 AP（公共自选池·输出·爆发——总伤与斩铁剑同级但
        //       随机分摊，聚焦击杀弱于职业招牌；AP 上限天然封顶爆发频率）（中等技能：AP 5）
        skillStormBlade = sr.registerSkill(SkillRegistry.Skill({
            id: 0, kind: 1, apCost: 5, apGain: 0, ammoId: 0, ammoCost: 0, manaCost: 0, hpCost: 0,
            targeting: 3, weightMode: 0, targetCount: 4, power: 250, damageCap: 0, baseAcc: 900, flags: 0,
            effects: [SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000})],
            effectCount: 0, summon: SkillRegistry.SummonRule({templateId: 0, maxCount: 0, enemyHeadroom: 0})
        }));

        // 魔法剑：魔攻输出 + 少量魔素消耗 + 少量 AP 产出（剑士职业技）（小技能：魔素 1、AP 产出 1）
        skillMagicSword = sr.registerClassSkill(SkillRegistry.Skill({
            id: 0, kind: 2, apCost: 0, apGain: 1, ammoId: 0, ammoCost: 0, manaCost: 1, hpCost: 0,
            targeting: 1, weightMode: 0, targetCount: 0, power: 200, damageCap: 0, baseAcc: 1000, flags: 0,
            effects: [SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000})],
            effectCount: 0, summon: SkillRegistry.SummonRule({templateId: 0, maxCount: 0, enemyHeadroom: 0})
        }), 1); // 剑士 classId=1

        // 左轮弹雨：铅弹 ×3 连射、命中率不高，命中后产出少量 AP（火枪手职业技）（AP 产出 1）
        skillRevolverRain = sr.registerClassSkill(SkillRegistry.Skill({
            id: 0, kind: 1, apCost: 0, apGain: 1, ammoId: 1, ammoCost: 3, manaCost: 0, hpCost: 0,
            targeting: 3, weightMode: 0, targetCount: 3, power: 60, damageCap: 0, baseAcc: 700, flags: 0,
            effects: [SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000})],
            effectCount: 0, summon: SkillRegistry.SummonRule({templateId: 0, maxCount: 0, enemyHeadroom: 0})
        }), 3); // 火枪手 classId=3

        // 龙击弹：昂贵单体重击，命中后为房间魔素池注入少量魔素（火枪手职业技）（魔素产出 1）
        skillDragonBullet = sr.registerClassSkill(SkillRegistry.Skill({
            id: 0, kind: 1, apCost: 0, apGain: 0, ammoId: 2, ammoCost: 1, manaCost: 0, hpCost: 0,
            targeting: 1, weightMode: 0, targetCount: 0, power: 300, damageCap: 0, baseAcc: 1000, flags: 0,
            effects: [SkillRegistry.Effect({op: 13, duration: 0, magnitude: 1, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000})],
            effectCount: 1, summon: SkillRegistry.SummonRule({templateId: 0, maxCount: 0, enemyHeadroom: 0})
        }), 3); // 火枪手 classId=3

        // 爆裂魔法：耗光全队魔素，全体伤害随魔素量成长，固有绝对命中 + 自晕（黑魔法师职业技）
        skillBurstMagic = sr.registerClassSkill(SkillRegistry.Skill({
            id: 0, kind: 2, apCost: 0, apGain: 0, ammoId: 0, ammoCost: 0, manaCost: 0, hpCost: 0,
            targeting: 4, weightMode: 0, targetCount: 0, power: 500, damageCap: 0, baseAcc: 1000, flags: 3,
            effects: [SkillRegistry.Effect({op: 1, duration: 3, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000}), SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000})],
            effectCount: 1, summon: SkillRegistry.SummonRule({templateId: 0, maxCount: 0, enemyHeadroom: 0})
        }), 4); // 黑魔法师 classId=4
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
            tableId: 1, enemyCount: 2, manaPerTurn: 1, rewardBase: 20, entryFee: 5, rescueFee: 10, turnInterval: 5
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

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {RNGRouter} from "../src/core/RNGRouter.sol";
import {Economy} from "../src/core/Economy.sol";
import {SkillRegistry} from "../src/core/SkillRegistry.sol";
import {CharacterRegistry} from "../src/core/CharacterRegistry.sol";
import {CombatEngine} from "../src/core/CombatEngine.sol";
import {CombatTypes} from "../src/libs/CombatTypes.sol";

/// @title Seed - 播种测试数据（与 BaseTest 同口径，保证合约测试与私链验证同一状态）
/// @notice 用法：forge script script/Seed.s.sol --rpc-url <RPC> --broadcast
///         从 deployments/<chainId>.json 读取合约地址；生产环境不跑本脚本。
contract Seed is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);

        string memory manifest = string.concat("deployments/", vm.toString(block.chainid), ".json");
        string memory json = vm.readFile(manifest);
        RNGRouter rng = RNGRouter(abi.decode(vm.parseJson(json, ".contracts.RNGRouter"), (address)));
        Economy economy = Economy(abi.decode(vm.parseJson(json, ".contracts.Economy"), (address)));
        SkillRegistry sr = SkillRegistry(abi.decode(vm.parseJson(json, ".contracts.SkillRegistry"), (address)));
        CharacterRegistry cr = CharacterRegistry(abi.decode(vm.parseJson(json, ".contracts.CharacterRegistry"), (address)));
        CombatEngine ce = CombatEngine(abi.decode(vm.parseJson(json, ".contracts.CombatEngine"), (address)));

        // ---- 职业（content-design.md §4：剑士/守卫/火枪手/黑魔法师/白魔法师 + 无职业）----
        // 千分比**增量**（与种族/词条同约定：1000+mod 为乘数）；1 级职业值与原口径一致（与 BaseTest 同口径）
        cr.registerClass(1, CharacterRegistry.ClassDef({baseHpPct: 200, baseAttackPct: 2000, baseMagicPct: 0, baseSpeedPct: 0, skillSlots: 1, exists: true})); // 剑士
        cr.registerClass(2, CharacterRegistry.ClassDef({baseHpPct: 350, baseAttackPct: 800, baseMagicPct: -200, baseSpeedPct: -200, skillSlots: 1, exists: true})); // 守卫
        cr.registerClass(3, CharacterRegistry.ClassDef({baseHpPct: -100, baseAttackPct: 1800, baseMagicPct: -200, baseSpeedPct: 1200, skillSlots: 1, exists: true})); // 火枪手
        cr.registerClass(4, CharacterRegistry.ClassDef({baseHpPct: -200, baseAttackPct: 0, baseMagicPct: 2500, baseSpeedPct: 200, skillSlots: 1, exists: true})); // 黑魔法师
        cr.registerClass(5, CharacterRegistry.ClassDef({baseHpPct: -50, baseAttackPct: 200, baseMagicPct: 1800, baseSpeedPct: 400, skillSlots: 1, exists: true})); // 白魔法师
        cr.registerClass(6, CharacterRegistry.ClassDef({baseHpPct: 0, baseAttackPct: 1000, baseMagicPct: 1000, baseSpeedPct: 500, skillSlots: 3, exists: true})); // 无职业

        // ---- 技能（先注册：种族技 id 供 _seedRaces 引用；与 BaseTest 同口径；资源以 1 为单位：小 1-3 / 中 3-5 / 大 10）----
        uint32 skillAttack = _registerSkill(sr, 1, 0, 1, 0, 0, 0, 0, 1, 0, 0, 100, 0, 1000, 0, _emptyEffects(), 0);
        uint32 skillMagicBolt = _registerSkill(sr, 2, 0, 0, 0, 0, 1, 0, 1, 0, 0, 150, 0, 1000, 0, _emptyEffects(), 0);
        uint32 skillHeal = _registerSkill(sr, 3, 0, 0, 0, 0, 1, 0, 5, 1, 0, 100, 0, 1000, 0, _healEffect(), 1);
        uint32 skillStrike3 = _registerSkill(sr, 1, 1, 2, 0, 0, 0, 0, 3, 0, 3, 50, 0, 1000, 0, _emptyEffects(), 0);
        uint32 skillShield = _registerSkill(sr, 3, 0, 0, 0, 0, 1, 0, 9, 0, 0, 100, 0, 1000, 0, _shieldEffect(), 1);
        uint32 skillStun = _registerSkill(sr, 1, 3, 0, 0, 0, 0, 0, 1, 0, 0, 50, 0, 1000, 0, _stunEffect(), 1);
        uint32 skillSmoke = _registerSkill(sr, 3, 0, 0, 0, 0, 1, 0, 8, 0, 0, 0, 0, 1000, 0, _smokeEffect(), 1);
        uint32 skillManaBurst = _registerSkill(sr, 3, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 0, 1000, 0, _manaBurstEffect(), 1);
        uint32 skillDot = _registerSkill(sr, 1, 2, 0, 0, 0, 0, 0, 1, 0, 0, 200, 0, 950, 0, _dotEffect(), 1);
        uint32 skillTaunt = _registerSkill(sr, 3, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 1000, 0, _tauntEffect(), 1);
        uint32 skillBerserk = _registerSkill(sr, 3, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 0, 1000, 0, _berserkEffects(), 2); // 兽人
        uint32 skillStoneBody = _registerSkill(sr, 3, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 0, 1000, 0, _stoneBodyEffects(), 1); // 巨人
        uint32 skillSpiritReturn = _registerSkill(sr, 3, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 0, 1000, 0, _spiritReturnEffects(), 2); // 矮人
        uint32 skillStorm = _registerSkill(sr, 2, 0, 0, 0, 0, 3, 0, 3, 0, 3, 60, 0, 1000, 0, _stormEffects(), 1); // 精灵
        uint32 skillDragonScale = _registerSkill(sr, 3, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 0, 1000, 0, _dragonScaleEffects(), 2); // 龙人
        uint32 skillHolyLight = _registerSkill(sr, 3, 0, 0, 0, 0, 1, 0, 10, 0, 0, 0, 0, 1000, 0, _holyLightEffects(), 1); // 天使 1
        uint32 skillAngelJudgment = _registerSkill(sr, 2, 0, 0, 0, 0, 3, 0, 3, 0, 4, 80, 0, 1000, 0, _emptyEffects(), 0); // 天使 2
        uint32 skillSoulDrain = _registerSkill(sr, 1, 0, 1, 0, 0, 0, 0, 1, 0, 0, 100, 0, 1000, 0, _soulDrainEffects(), 1); // 恶魔 1
        uint32 skillAbyssWhisper = _registerSkill(sr, 3, 0, 0, 0, 0, 1, 0, 4, 0, 0, 0, 0, 1000, 0, _abyssWhisperEffects(), 1); // 恶魔 2
        uint32 skillSummon = _registerSkill(sr, 4, 0, 0, 0, 0, 3, 0, 9, 0, 0, 0, 0, 1000, 0, _summonEffect(), 1);
        uint32 skillIdle = _registerSkill(sr, 3, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 0, 1000, 0, _emptyEffects(), 0);
        // 鹰眼：职业绑定（火枪手 classId=3）（小技能：AP 1）
        _registerClassSkill(sr, 3, 3, 1, 0, 0, 0, 0, 0, 9, 0, 0, 0, 0, 1000, 0, _guarNextEffect(), 1);
        // 一闪：公共自选池（原剑士职业技移入）（小技能：AP 1）
        uint32 skillFlash = _registerSkill(sr, 1, 1, 0, 0, 0, 0, 0, 1, 0, 0, 350, 350, 650, 0, _emptyEffects(), 0);
        // 暴风剑：公共自选池·爆发（高命中四连斩、随机目标多段、高 AP 消耗）（中等技能：AP 5）
        uint32 skillStormBlade = _registerSkill(sr, 1, 5, 0, 0, 0, 0, 0, 3, 0, 4, 250, 0, 900, 0, _emptyEffects(), 0);
        // 魔法剑：剑士职业技（魔攻输出 + 少量魔素 + 少量 AP）（小技能：魔素 1、AP 产出 1）
        uint32 skillMagicSword = _registerClassSkill(sr, 1, 2, 0, 1, 0, 0, 1, 0, 1, 0, 0, 200, 0, 1000, 0, _emptyEffects(), 0);
        // 左轮弹雨：火枪手职业技（铅弹 ammoId=1，命中后少量 AP）（AP 产出 1）
        uint32 skillRevolverRain = _registerClassSkill(sr, 3, 1, 0, 1, 1, 3, 0, 0, 3, 0, 3, 60, 0, 700, 0, _emptyEffects(), 0);
        // 龙击弹：火枪手职业技（龙击弹 ammoId=2，命中后注入少量魔素）（魔素产出 1）
        uint32 skillDragonBullet = _registerClassSkill(sr, 3, 1, 0, 0, 2, 1, 0, 0, 1, 0, 0, 300, 0, 1000, 0, _dragonBulletEffects(), 1);
        // 爆裂魔法：黑魔法师职业技（耗光魔素 + 固有绝对命中 + 自晕）
        uint32 skillBurstMagic = _registerClassSkill(sr, 4, 2, 0, 0, 0, 0, 0, 0, 4, 0, 0, 500, 0, 1000, 3, _burstMagicEffects(), 1);

        // ---- 职业技能补齐（content-design.md §4；类内自动发放）----
        // 剑士：快速剑（三连轻击，AP1 产 2）、斩铁剑（贵而稳的重击，AP 10）
        uint32 skillRapidStrike = _registerClassSkill(sr, 1, 1, 1, 2, 0, 0, 0, 0, 3, 0, 3, 50, 0, 1000, 0, _emptyEffects(), 0);
        uint32 skillIronCleave = _registerClassSkill(sr, 1, 1, 10, 0, 0, 0, 0, 0, 1, 0, 0, 800, 0, 1000, 0, _emptyEffects(), 0);
        // 守卫：盾击（单体 + 概率眩晕 + 嘲讽）、盾墙（高额护盾）、回避（纯加法命中）
        uint32 skillShieldBash = _registerClassSkill(sr, 2, 1, 3, 0, 0, 0, 0, 0, 1, 0, 0, 80, 0, 1000, 0, _shieldBashEffects(), 2);
        uint32 skillShieldWall = _registerClassSkill(sr, 2, 3, 0, 0, 0, 0, 1, 0, 9, 0, 0, 0, 0, 1000, 0, _shield150Effect(), 1);
        uint32 skillGuardEvade = _registerClassSkill(sr, 2, 3, 0, 0, 0, 0, 1, 0, 9, 0, 0, 0, 0, 1000, 0, _evadeEffect(), 1);
        // 黑魔法师：献祭（以命换多段随机攻击 + 产魔素）、黑幕（降敌方全体命中）
        uint32 skillSacrifice = _registerClassSkill(sr, 4, 1, 0, 0, 0, 0, 0, 50, 3, 0, 2, 120, 0, 1000, 0, _manaBurstEffect(), 1);
        uint32 skillBlackVeil = _registerClassSkill(sr, 4, 3, 0, 0, 0, 0, 1, 0, 4, 0, 0, 0, 0, 1000, 0, _accDownAllEffect(), 1);
        // 白魔法师：光弹（弹着数固定的多目标圣光弹）、圣泉（按亏空加权小治疗 + 回魔）、替身人偶（召唤己方假目标）
        uint32 skillLightOrb = _registerClassSkill(sr, 5, 2, 0, 0, 0, 0, 1, 0, 2, 0, 4, 80, 0, 1000, 0, _emptyEffects(), 0);
        uint32 skillHolySpring = _registerClassSkill(sr, 5, 3, 0, 0, 0, 0, 1, 0, 6, 1, 3, 90, 0, 1000, 0, _manaBurstEffect(), 1);
        uint16 templateDecoy = sr.registerTemplate(SkillRegistry.EnemyTemplate({
            aiId: 0, threat: 0, maxHp: 120, power: 0, magic: 0, speed: 0, baseAcc: 0,
            rewardMin: 0, rewardMax: 0,
            onDeathSpawn: SkillRegistry.OnDeathSpawn({templateId: 0, count: 0, prob: 0})
        }));
        uint32 skillDecoyDoll = _registerClassSkillSummon(sr, 5, 4, 0, 0, 0, 0, 1, 0, 9, 0, 0, 0, 0, 1000, 4, _summonEffect(), 1,
            SkillRegistry.SummonRule({templateId: templateDecoy, maxCount: 1, enemyHeadroom: 0}));

        // ---- 自选池补齐（content-design.md §5；公共池技）----
        // 急救包扎：小额治疗随机我方
        uint32 skillFirstAid = _registerSkill(sr, 3, 0, 0, 0, 0, 1, 0, 5, 1, 0, 60, 0, 1000, 0, _emptyEffects(), 0);
        // 致盲粉：大幅降低自己与单个随机敌人命中（双刃）
        uint32 skillBlindingPowder = _registerSkill(sr, 3, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 1000, 0, _blindingEffects(), 2);
        // 岩石壁垒：小额护盾
        uint32 skillRockBulwark = _registerSkill(sr, 3, 0, 0, 0, 0, 1, 0, 9, 0, 0, 0, 0, 1000, 0, _shield60Effect(), 1);
        // 魔力护盾：护盾量 = power × 魔攻（kind=MAGIC 走魔法缩放路径）
        uint32 skillMagicShield = _registerSkill(sr, 2, 0, 0, 0, 0, 1, 0, 9, 0, 0, 1000, 0, 1000, 0, _shieldEffect(), 1);
        // 龙息：多目标魔法吐息
        uint32 skillDragonBreath = _registerSkill(sr, 2, 0, 0, 0, 0, 2, 0, 2, 0, 2, 70, 0, 1000, 0, _emptyEffects(), 0);
        // 魔爆术：全体魔法（低伤，法系基础清场）
        uint32 skillManaClap = _registerSkill(sr, 2, 0, 0, 0, 0, 2, 0, 4, 0, 0, 60, 0, 1000, 0, _emptyEffects(), 0);

        // ---- 种族（content-design.md §3：常见四 + 略稀有二 + 最稀有二，含种族技）----
        cr.registerRace(0, CharacterRegistry.RaceDef({statMods: [int16(0), 0, 0], hpMod: int16(0), raceSkillId: 0, raceSkillId2: 0, selfSelectBonus: 2, exists: true})); // 人类：基准，自选 +2
        cr.registerRace(1, CharacterRegistry.RaceDef({statMods: [int16(200), -200, -100], hpMod: int16(100), raceSkillId: skillBerserk, raceSkillId2: 0, selfSelectBonus: 0, exists: true})); // 兽人：物攻+20%/魔攻-20%/敏捷-10%/生命+10%
        cr.registerRace(2, CharacterRegistry.RaceDef({statMods: [int16(100), -200, -300], hpMod: int16(300), raceSkillId: skillStoneBody, raceSkillId2: 0, selfSelectBonus: 0, exists: true})); // 巨人：生命+30%/物攻+10%/魔攻-20%/敏捷-30%
        cr.registerRace(3, CharacterRegistry.RaceDef({statMods: [int16(100), -200, -100], hpMod: int16(150), raceSkillId: skillSpiritReturn, raceSkillId2: 0, selfSelectBonus: 0, exists: true})); // 矮人：生命+15%/物攻+10%/魔攻-20%/敏捷-10%
        cr.registerRace(4, CharacterRegistry.RaceDef({statMods: [int16(-100), 200, 300], hpMod: int16(-100), raceSkillId: skillStorm, raceSkillId2: 0, selfSelectBonus: 0, exists: true})); // 精灵：敏捷+30%/魔攻+20%/生命-10%/物攻-10%
        cr.registerRace(5, CharacterRegistry.RaceDef({statMods: [int16(200), 200, -100], hpMod: int16(-100), raceSkillId: skillDragonScale, raceSkillId2: 0, selfSelectBonus: 0, exists: true})); // 龙人：物攻+20%/魔攻+20%/生命-10%/敏捷-10%
        cr.registerRace(6, CharacterRegistry.RaceDef({statMods: [int16(-200), 300, -50], hpMod: int16(100), raceSkillId: skillHolyLight, raceSkillId2: skillAngelJudgment, selfSelectBonus: 0, exists: true})); // 天使：魔攻+30%/生命+10%/物攻-20%/敏捷-5%
        cr.registerRace(7, CharacterRegistry.RaceDef({statMods: [int16(300), -100, 200], hpMod: int16(-150), raceSkillId: skillSoulDrain, raceSkillId2: skillAbyssWhisper, selfSelectBonus: 0, exists: true})); // 恶魔：物攻+30%/敏捷+20%/魔攻-10%/生命-15%

        // ---- 词条模板（四种能力词条；资源效果固定四种、由引擎内置）----
        uint16[10] memory weights = [uint16(400), 220, 140, 90, 60, 35, 25, 15, 10, 5];
        uint16[10] memory values = [uint16(0), 100, 250, 450, 700, 950, 1200, 1450, 1700, 2000];
        _registerAffix(cr, 1, 0, weights, values); // 生命
        _registerAffix(cr, 2, 1, weights, values); // 物攻
        _registerAffix(cr, 3, 2, weights, values); // 魔攻
        _registerAffix(cr, 4, 3, weights, values); // 敏捷

        // ---- 怪物 AI 与敌人模板 ----
        uint16 aiSlime = sr.registerAI(SkillRegistry.MonsterAI({skillCycle: [uint16(skillAttack), 0, 0, 0, 0, 0, 0, 0], cycleLen: 1}));
        uint16 aiBoss = sr.registerAI(SkillRegistry.MonsterAI({skillCycle: [uint16(skillAttack), uint16(skillAttack), uint16(skillMagicBolt), 0, 0, 0, 0, 0], cycleLen: 3}));

        uint16 templateSlime = sr.registerTemplate(SkillRegistry.EnemyTemplate({
            aiId: aiSlime, threat: 1, maxHp: 50, power: 12, magic: 5, speed: 8, baseAcc: 1000,
            rewardMin: 5, rewardMax: 10,
            onDeathSpawn: SkillRegistry.OnDeathSpawn({templateId: 0, count: 0, prob: 0})
        }));
        uint16 templateBoss = sr.registerTemplate(SkillRegistry.EnemyTemplate({
            aiId: aiBoss, threat: 5, maxHp: 200, power: 25, magic: 15, speed: 12, baseAcc: 1000,
            rewardMin: 30, rewardMax: 50,
            onDeathSpawn: SkillRegistry.OnDeathSpawn({templateId: templateSlime, count: 2, prob: 500})
        }));
        uint16 templateSummoned = sr.registerTemplate(SkillRegistry.EnemyTemplate({
            aiId: aiSlime, threat: 1, maxHp: 30, power: 10, magic: 3, speed: 6, baseAcc: 1000,
            rewardMin: 3, rewardMax: 6,
            onDeathSpawn: SkillRegistry.OnDeathSpawn({templateId: 0, count: 0, prob: 0})
        }));

        // ---- 地下城 ----
        uint16[] memory ids = new uint16[](1);
        ids[0] = templateSlime;
        uint16[] memory ws = new uint16[](1);
        ws[0] = 100;
        ce.registerEnemyTable(1, ids, ws);
        ce.setDungeon(1, CombatTypes.DungeonConfig({tableId: 1, enemyCount: 2, manaPerTurn: 1, rewardBase: 20, entryFee: 5, rescueFee: 10, turnInterval: 5, battles: 1}));

        // =====================================================================
        //  D9 机神帝座（content-design.md §8.2，最难关：四场决战；与 BaseTest._seedD9 同口径）
        // =====================================================================
        uint32 skillSparkSaw = _registerSkill(sr, 1, 0, 0, 0, 0, 0, 0, 1, 0, 1, 1300, 0, 950, 0, _emptyEffects(), 0); // 机神士兵·火花锯刃
        uint32 skillParticleSlash = _registerSkill(sr, 1, 0, 0, 0, 0, 0, 0, 1, 0, 1, 1700, 0, 950, 0, _emptyEffects(), 0); // 机神督军·粒子斩
        uint32 skillMarshalLeak = _registerSkill(sr, 3, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 0, 1000, 0, _manaLeakEffect(), 1); // 督军·磁场超载（魔素+100）
        uint32 skillFurnaceLeak = _registerSkill(sr, 3, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 0, 1000, 0, _manaLeakEffect(), 1); // 魔素炉·魔素泄漏（+100）
        uint32 skillFurnaceSiphon = _registerSkill(sr, 3, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 0, 1000, 0, _manaSiphonEffect(), 1); // 魔素炉·魔素虹吸（-80）
        uint32 skillEmperorCannon = _registerSkill(sr, 1, 0, 0, 0, 0, 40, 0, 1, 0, 1, 17000, 0, 900, 0, _emptyEffects(), 0); // 皇帝·机神火花炮
        uint32 skillEmperorWheel = _registerSkill(sr, 2, 0, 0, 0, 0, 12, 0, 3, 0, 4, 6700, 0, 900, 0, _wheelEffects(), 1); // 皇帝·机神幻光轮（4 段）
        uint32 skillEmperorLeak = _registerSkill(sr, 3, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 0, 1000, 0, _manaLeakEffect(), 1); // 皇帝·魔素泄漏
        uint32 skillEmperorSiphon = _registerSkill(sr, 3, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 0, 1000, 0, _manaSiphonEffect(), 1); // 皇帝·魔素虹吸
        uint32 skillEmperorPressure = _registerSkill(sr, 3, 0, 0, 0, 0, 2, 0, 4, 0, 0, 0, 0, 1000, 0, _pressureEffects(), 2); // 皇帝·帝王威压

        // AI（士兵/督军/宝箱不依赖召唤技，可先注册）
        uint16 aiSoldier = sr.registerAI(SkillRegistry.MonsterAI({skillCycle: [uint16(skillSparkSaw), 0, 0, 0, 0, 0, 0, 0], cycleLen: 1}));
        uint16 aiMarshal = sr.registerAI(SkillRegistry.MonsterAI({skillCycle: [uint16(skillParticleSlash), uint16(skillParticleSlash), uint16(skillMarshalLeak), 0, 0, 0, 0, 0], cycleLen: 3}));
        uint16 aiChest = sr.registerAI(SkillRegistry.MonsterAI({skillCycle: [uint16(0), 0, 0, 0, 0, 0, 0, 0], cycleLen: 1}));

        // 模板（士兵/督军：引用已注册 AI）
        uint16 templateSoldier = sr.registerTemplate(SkillRegistry.EnemyTemplate({
            aiId: aiSoldier, threat: 3, maxHp: 2600, power: 380, magic: 150, speed: 28, baseAcc: 1000,
            rewardMin: 8, rewardMax: 15,
            onDeathSpawn: SkillRegistry.OnDeathSpawn({templateId: 0, count: 0, prob: 0})
        }));
        uint16 templateMarshal = sr.registerTemplate(SkillRegistry.EnemyTemplate({
            aiId: aiMarshal, threat: 8, maxHp: 9000, power: 900, magic: 600, speed: 42, baseAcc: 1000,
            rewardMin: 40, rewardMax: 70,
            onDeathSpawn: SkillRegistry.OnDeathSpawn({templateId: 0, count: 0, prob: 0})
        }));

        // 召唤技（须在 templateSoldier 注册后再注册，否则 SummonRule 引用到 0）
        uint32 skillFurnaceSummon = _registerSummonSkill(sr, templateSoldier);
        uint32 skillEmperorSummon = _registerSummonSkill(sr, templateSoldier);

        // 炉 / 皇帝 AI（引用召唤技，须在其后注册）
        uint16 aiFurnace = sr.registerAI(SkillRegistry.MonsterAI({skillCycle: [uint16(skillFurnaceLeak), uint16(skillFurnaceSiphon), uint16(skillFurnaceSummon), uint16(skillFurnaceLeak), uint16(skillFurnaceSiphon), 0, 0, 0], cycleLen: 5}));
        uint16 aiEmperor = sr.registerAI(SkillRegistry.MonsterAI({skillCycle: [uint16(skillEmperorWheel), uint16(skillEmperorCannon), uint16(skillEmperorPressure), uint16(skillEmperorSummon), uint16(skillEmperorLeak), uint16(skillEmperorCannon), 0, 0], cycleLen: 6}));

        // 皇帝 / 炉 / 宝箱模板（皇帝须先于炉/宝箱注册，供 onDeathSpawn 引用）
        uint16 templateEmperor = sr.registerTemplate(SkillRegistry.EnemyTemplate({
            aiId: aiEmperor, threat: 9, maxHp: 60000, power: 3000, magic: 3000, speed: 60, baseAcc: 1000,
            rewardMin: 300, rewardMax: 450,
            onDeathSpawn: SkillRegistry.OnDeathSpawn({templateId: 0, count: 0, prob: 0})
        }));
        uint16 templateFurnace = sr.registerTemplate(SkillRegistry.EnemyTemplate({
            aiId: aiFurnace, threat: 4, maxHp: 22000, power: 0, magic: 0, speed: 5, baseAcc: 0,
            rewardMin: 120, rewardMax: 180,
            onDeathSpawn: SkillRegistry.OnDeathSpawn({templateId: templateEmperor, count: 1, prob: 600})
        }));
        uint16 templateChest = sr.registerTemplate(SkillRegistry.EnemyTemplate({
            aiId: aiChest, threat: 0, maxHp: 1, power: 0, magic: 0, speed: 1, baseAcc: 0,
            rewardMin: 150, rewardMax: 250,
            onDeathSpawn: SkillRegistry.OnDeathSpawn({templateId: templateEmperor, count: 1, prob: 200})
        }));

        // 敌人表
        _ceTable(ce, 71, templateSoldier); // ① 机神哨岗
        _ceWeightedTable(ce, 72, templateSoldier, 60, templateMarshal, 40); // ② 机神行军
        _ceWeightedTable(ce, 73, templateFurnace, 55, templateSoldier, 45); // ③ 魔素炉阵
        _ceWeightedTable(ce, 74, templateEmperor, 55, templateSoldier, 45); // ④ 皇帝亲征（变体）
        _ceTable(ce, 75, templateChest); // ④ 王座宝箱（变体）

        // 地下城 D9（四场决战 + ④ 王座大厅变体：85% 宝箱 / 15% 皇帝亲征）
        ce.setDungeon(9, CombatTypes.DungeonConfig({tableId: 71, enemyCount: 3, manaPerTurn: 6, rewardBase: 200, entryFee: 40, rescueFee: 80, turnInterval: 5, battles: 4}));
        CombatTypes.BattleConfig[] memory bcs = new CombatTypes.BattleConfig[](4);
        bcs[0] = CombatTypes.BattleConfig({tableId: 71, enemyCount: 3});
        bcs[1] = CombatTypes.BattleConfig({tableId: 72, enemyCount: 3});
        bcs[2] = CombatTypes.BattleConfig({tableId: 73, enemyCount: 2});
        bcs[3] = CombatTypes.BattleConfig({tableId: 75, enemyCount: 1});
        ce.setDungeonBattles(9, bcs);
        ce.addBattleVariant(9, 4, 75, 850);
        ce.addBattleVariant(9, 4, 74, 150);

        // ---- D10（content-design.md §8.3 占位）：仅 1 场，内容未定，复用史莱姆表 ----
        _ceTable(ce, 101, templateSlime);
        ce.setDungeon(10, CombatTypes.DungeonConfig({tableId: 101, enemyCount: 2, manaPerTurn: 4, rewardBase: 60, entryFee: 10, rescueFee: 20, turnInterval: 5, battles: 1}));

        // ---- 测试角色（GM 铸造，固定属性，供 CLI/Bot 联调）----
        address alice = vm.envOr("SEED_ALICE", address(0xA11CE));
        address bob = vm.envOr("SEED_BOB", address(0xB0B));
        uint32[] memory solo = new uint32[](1);
        solo[0] = skillAttack;
        cr.gmMintCharacter(alice, 1, 0, new uint16[](0), solo);
        cr.gmMintCharacter(bob, 3, 0, new uint16[](0), solo);

        vm.stopBroadcast();

        console2.log("Seed complete on chain", block.chainid);
        console2.log("  skills:", sr.skillCount());
        console2.log("  ais:", sr.aiCount());
        console2.log("  templates:", sr.templateCount());
        console2.log("  alice char:", cr.balanceOf(alice));
        console2.log("  bob char:", cr.balanceOf(bob));
    }

    function _registerAffix(
        CharacterRegistry cr,
        uint16 id,
        uint8 statType,
        uint16[10] memory weights,
        uint16[10] memory values
    ) internal {
        cr.registerAffixTemplate(
            id,
            CharacterRegistry.AffixTemplate({statType: statType, exists: false, tierWeights: weights, tierValues: values})
        );
    }

    // ---- 技能构造辅助（与 BaseTest 同口径）----
    function _registerSkill(
        SkillRegistry sr,
        uint8 kind, uint16 apCost, uint16 apGain, uint16 ammoId, uint16 ammoCost, uint32 manaCost, uint16 hpCost,
        uint8 targeting, uint8 weightMode, uint8 targetCount, uint64 power, uint64 damageCap, uint16 baseAcc, uint8 flags,
        SkillRegistry.Effect[4] memory effects, uint8 effectCount
    ) internal returns (uint32) {
        return sr.registerSkill(SkillRegistry.Skill({
            id: 0, kind: kind, apCost: apCost, apGain: apGain, ammoId: ammoId, ammoCost: ammoCost, manaCost: manaCost, hpCost: hpCost,
            targeting: targeting, weightMode: weightMode, targetCount: targetCount, power: power, damageCap: damageCap, baseAcc: baseAcc, flags: flags,
            effects: effects, effectCount: effectCount,
            summon: SkillRegistry.SummonRule({templateId: 0, maxCount: 0, enemyHeadroom: 0})
        }));
    }

    function _registerClassSkill(
        SkillRegistry sr, uint8 classId,
        uint8 kind, uint16 apCost, uint16 apGain, uint16 ammoId, uint16 ammoCost, uint32 manaCost, uint16 hpCost,
        uint8 targeting, uint8 weightMode, uint8 targetCount, uint64 power, uint64 damageCap, uint16 baseAcc, uint8 flags,
        SkillRegistry.Effect[4] memory effects, uint8 effectCount
    ) internal returns (uint32) {
        return sr.registerClassSkill(SkillRegistry.Skill({
            id: 0, kind: kind, apCost: apCost, apGain: apGain, ammoId: ammoId, ammoCost: ammoCost, manaCost: manaCost, hpCost: hpCost,
            targeting: targeting, weightMode: weightMode, targetCount: targetCount, power: power, damageCap: damageCap, baseAcc: baseAcc, flags: flags,
            effects: effects, effectCount: effectCount,
            summon: SkillRegistry.SummonRule({templateId: 0, maxCount: 0, enemyHeadroom: 0})
        }), classId);
    }

    function _emptyEffects() internal pure returns (SkillRegistry.Effect[4] memory e) {
        for (uint8 i; i < 4; ++i) e[i] = SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000});
    }

    function _healEffect() internal pure returns (SkillRegistry.Effect[4] memory e) {
        e[0] = SkillRegistry.Effect({op: 9, duration: 0, magnitude: 0, scope: 1, prob: 1000});
    }

    function _shieldEffect() internal pure returns (SkillRegistry.Effect[4] memory e) {
        e[0] = SkillRegistry.Effect({op: 4, duration: 3, magnitude: 0, scope: 0, prob: 1000});
    }

    function _stunEffect() internal pure returns (SkillRegistry.Effect[4] memory e) {
        e[0] = SkillRegistry.Effect({op: 1, duration: 2, magnitude: 0, scope: 1, prob: 1000});
    }

    function _smokeEffect() internal pure returns (SkillRegistry.Effect[4] memory e) {
        e[0] = SkillRegistry.Effect({op: 6, duration: 2, magnitude: 200, scope: 2, prob: 1000});
    }

    function _manaBurstEffect() internal pure returns (SkillRegistry.Effect[4] memory e) {
        e[0] = SkillRegistry.Effect({op: 13, duration: 0, magnitude: 1, scope: 0, prob: 1000});
    }

    function _dotEffect() internal pure returns (SkillRegistry.Effect[4] memory e) {
        e[0] = SkillRegistry.Effect({op: 8, duration: 3, magnitude: 18, scope: 1, prob: 1000});
    }

    function _tauntEffect() internal pure returns (SkillRegistry.Effect[4] memory e) {
        e[0] = SkillRegistry.Effect({op: 11, duration: 2, magnitude: 0, scope: 1, prob: 1000});
    }

    function _berserkEffects() internal pure returns (SkillRegistry.Effect[4] memory e) {
        e[0] = SkillRegistry.Effect({op: 2, duration: 2, magnitude: 300, scope: 0, prob: 1000});
        e[1] = SkillRegistry.Effect({op: 3, duration: 2, magnitude: 200, scope: 0, prob: 1000});
    }

    function _stoneBodyEffects() internal pure returns (SkillRegistry.Effect[4] memory e) {
        e[0] = SkillRegistry.Effect({op: 4, duration: 4, magnitude: 80, scope: 0, prob: 1000});
    }

    function _spiritReturnEffects() internal pure returns (SkillRegistry.Effect[4] memory e) {
        e[0] = SkillRegistry.Effect({op: 10, duration: 0, magnitude: 0, scope: 0, prob: 1000});
        e[1] = SkillRegistry.Effect({op: 9, duration: 0, magnitude: 30, scope: 0, prob: 1000});
    }

    function _stormEffects() internal pure returns (SkillRegistry.Effect[4] memory e) {
        e[0] = SkillRegistry.Effect({op: 1, duration: 1, magnitude: 0, scope: 1, prob: 300});
    }

    function _dragonScaleEffects() internal pure returns (SkillRegistry.Effect[4] memory e) {
        e[0] = SkillRegistry.Effect({op: 4, duration: 3, magnitude: 60, scope: 0, prob: 1000});
        e[1] = SkillRegistry.Effect({op: 2, duration: 3, magnitude: 150, scope: 0, prob: 1000});
    }

    function _holyLightEffects() internal pure returns (SkillRegistry.Effect[4] memory e) {
        e[0] = SkillRegistry.Effect({op: 9, duration: 0, magnitude: 100, scope: 1, prob: 1000});
    }

    function _soulDrainEffects() internal pure returns (SkillRegistry.Effect[4] memory e) {
        e[0] = SkillRegistry.Effect({op: 12, duration: 0, magnitude: 300, scope: 0, prob: 1000});
    }

    function _abyssWhisperEffects() internal pure returns (SkillRegistry.Effect[4] memory e) {
        e[0] = SkillRegistry.Effect({op: 6, duration: 2, magnitude: 200, scope: 3, prob: 1000});
    }

    function _summonEffect() internal pure returns (SkillRegistry.Effect[4] memory e) {
        e[0] = SkillRegistry.Effect({op: 14, duration: 0, magnitude: 0, scope: 0, prob: 1000});
    }

    function _guarNextEffect() internal pure returns (SkillRegistry.Effect[4] memory e) {
        e[0] = SkillRegistry.Effect({op: 7, duration: 2, magnitude: 0, scope: 0, prob: 1000});
    }

    function _dragonBulletEffects() internal pure returns (SkillRegistry.Effect[4] memory e) {
        e[0] = SkillRegistry.Effect({op: 13, duration: 0, magnitude: 1, scope: 0, prob: 1000});
    }

    function _burstMagicEffects() internal pure returns (SkillRegistry.Effect[4] memory e) {
        e[0] = SkillRegistry.Effect({op: 1, duration: 3, magnitude: 0, scope: 0, prob: 1000});
    }

    function _shieldBashEffects() internal pure returns (SkillRegistry.Effect[4] memory e) {
        e[0] = SkillRegistry.Effect({op: 1, duration: 2, magnitude: 0, scope: 1, prob: 400});
        e[1] = SkillRegistry.Effect({op: 11, duration: 2, magnitude: 0, scope: 1, prob: 1000});
    }

    function _shield150Effect() internal pure returns (SkillRegistry.Effect[4] memory e) {
        e[0] = SkillRegistry.Effect({op: 4, duration: 3, magnitude: 150, scope: 0, prob: 1000});
    }

    function _shield60Effect() internal pure returns (SkillRegistry.Effect[4] memory e) {
        e[0] = SkillRegistry.Effect({op: 4, duration: 3, magnitude: 60, scope: 0, prob: 1000});
    }

    function _evadeEffect() internal pure returns (SkillRegistry.Effect[4] memory e) {
        e[0] = SkillRegistry.Effect({op: 5, duration: 3, magnitude: 300, scope: 0, prob: 1000});
    }

    function _accDownAllEffect() internal pure returns (SkillRegistry.Effect[4] memory e) {
        e[0] = SkillRegistry.Effect({op: 6, duration: 2, magnitude: 200, scope: 3, prob: 1000});
    }

    function _blindingEffects() internal pure returns (SkillRegistry.Effect[4] memory e) {
        e[0] = SkillRegistry.Effect({op: 6, duration: 2, magnitude: 250, scope: 0, prob: 1000});
        e[1] = SkillRegistry.Effect({op: 6, duration: 2, magnitude: 400, scope: 1, prob: 1000});
    }

    /// @notice 召唤型职业技注册：额外携带 summon 规则（替身人偶等己方召唤用 flags bit2）
    function _registerClassSkillSummon(
        SkillRegistry sr, uint8 classId,
        uint8 kind, uint16 apCost, uint16 apGain, uint16 ammoId, uint16 ammoCost, uint32 manaCost, uint16 hpCost,
        uint8 targeting, uint8 weightMode, uint8 targetCount, uint64 power, uint64 damageCap, uint16 baseAcc, uint8 flags,
        SkillRegistry.Effect[4] memory effects, uint8 effectCount, SkillRegistry.SummonRule memory summon
    ) internal returns (uint32) {
        return sr.registerClassSkill(SkillRegistry.Skill({
            id: 0, kind: kind, apCost: apCost, apGain: apGain, ammoId: ammoId, ammoCost: ammoCost, manaCost: manaCost, hpCost: hpCost,
            targeting: targeting, weightMode: weightMode, targetCount: targetCount, power: power, damageCap: damageCap, baseAcc: baseAcc, flags: flags,
            effects: effects, effectCount: effectCount,
            summon: summon
        }), classId);
    }

    // ---- D9 机神帝座技能/表辅助（与 BaseTest._seedD9 同口径）----
    function _manaLeakEffect() internal pure returns (SkillRegistry.Effect[4] memory e) {
        e[0] = SkillRegistry.Effect({op: 13, duration: 0, magnitude: 100, scope: 0, prob: 1000});
    }

    function _manaSiphonEffect() internal pure returns (SkillRegistry.Effect[4] memory e) {
        e[0] = SkillRegistry.Effect({op: 13, duration: 0, magnitude: 80, scope: 1, prob: 1000});
    }

    function _wheelEffects() internal pure returns (SkillRegistry.Effect[4] memory e) {
        e[0] = SkillRegistry.Effect({op: 1, duration: 2, magnitude: 0, scope: 1, prob: 400});
    }

    function _pressureEffects() internal pure returns (SkillRegistry.Effect[4] memory e) {
        e[0] = SkillRegistry.Effect({op: 6, duration: 3, magnitude: 300, scope: 3, prob: 1000});
        e[1] = SkillRegistry.Effect({op: 1, duration: 1, magnitude: 0, scope: 3, prob: 300});
    }

    /// @notice 怪物侧召唤技：一次性召唤 maxCount 个指定模板的敌人（魔素 0，无头寸限制）
    function _registerSummonSkill(SkillRegistry sr, uint16 templateId) internal returns (uint32) {
        return sr.registerSkill(SkillRegistry.Skill({
            id: 0, kind: 4, apCost: 0, apGain: 0, ammoId: 0, ammoCost: 0, manaCost: 0, hpCost: 0,
            targeting: 9, weightMode: 0, targetCount: 0, power: 0, damageCap: 0, baseAcc: 1000, flags: 0,
            effects: _summonEffect(), effectCount: 1,
            summon: SkillRegistry.SummonRule({templateId: templateId, maxCount: 2, enemyHeadroom: 0})
        }));
    }

    function _ceTable(CombatEngine ce, uint16 tableId, uint16 templateId) internal {
        uint16[] memory ids = new uint16[](1);
        ids[0] = templateId;
        uint16[] memory ws = new uint16[](1);
        ws[0] = 100;
        ce.registerEnemyTable(tableId, ids, ws);
    }

    function _ceWeightedTable(CombatEngine ce, uint16 tableId, uint16 t1, uint16 w1, uint16 t2, uint16 w2) internal {
        uint16[] memory ids = new uint16[](2);
        ids[0] = t1;
        ids[1] = t2;
        uint16[] memory ws = new uint16[](2);
        ws[0] = w1;
        ws[1] = w2;
        ce.registerEnemyTable(tableId, ids, ws);
    }
}

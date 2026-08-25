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

        // ---- 职业 ----
        cr.registerClass(1, CharacterRegistry.ClassDef({baseHp: 120, baseAttack: 30, baseMagic: 10, baseDefense: 25, baseSpeed: 10, skillSlots: 1})); // 战士
        cr.registerClass(2, CharacterRegistry.ClassDef({baseHp: 90, baseAttack: 28, baseMagic: 8, baseDefense: 15, baseSpeed: 22, skillSlots: 1})); // 火枪手
        cr.registerClass(3, CharacterRegistry.ClassDef({baseHp: 80, baseAttack: 10, baseMagic: 35, baseDefense: 12, baseSpeed: 12, skillSlots: 1})); // 黑魔法师
        cr.registerClass(4, CharacterRegistry.ClassDef({baseHp: 95, baseAttack: 12, baseMagic: 28, baseDefense: 18, baseSpeed: 14, skillSlots: 1})); // 白魔法师
        cr.registerClass(5, CharacterRegistry.ClassDef({baseHp: 100, baseAttack: 20, baseMagic: 20, baseDefense: 18, baseSpeed: 15, skillSlots: 3})); // 无职业

        // ---- 种族 ----
        cr.registerRace(0, CharacterRegistry.RaceDef({capPermille: [1000, 1000, 1000, 1000], capHpPermille: 1000, raceSkillId: 0, selfSelectBonus: 2})); // 人类
        cr.registerRace(1, CharacterRegistry.RaceDef({capPermille: [900, 1300, 1000, 1100], capHpPermille: 900, raceSkillId: 0, selfSelectBonus: 0})); // 精灵
        cr.registerRace(2, CharacterRegistry.RaceDef({capPermille: [1100, 900, 1300, 900], capHpPermille: 1200, raceSkillId: 0, selfSelectBonus: 0})); // 龙人
        cr.registerRace(3, CharacterRegistry.RaceDef({capPermille: [1200, 1200, 1200, 1200], capHpPermille: 1200, raceSkillId: 0, selfSelectBonus: 0})); // 天使
        cr.registerRace(4, CharacterRegistry.RaceDef({capPermille: [1300, 1300, 900, 1100], capHpPermille: 1000, raceSkillId: 0, selfSelectBonus: 0})); // 恶魔

        // ---- 词条模板 ----
        cr.registerAffixTemplate(1, CharacterRegistry.AffixTemplate({direction: 0, resourceType: 0, manaDiscount: 0, apBonus: 0, statMods: [int64(100), 0, 0, 0], hpMod: 0, tierWeights: [300, 250, 200, 150, 100]}));
        cr.registerAffixTemplate(2, CharacterRegistry.AffixTemplate({direction: 0, resourceType: 0, manaDiscount: 0, apBonus: 0, statMods: [int64(0), 0, 0, 0], hpMod: 150, tierWeights: [300, 250, 200, 150, 100]}));
        cr.registerAffixTemplate(3, CharacterRegistry.AffixTemplate({direction: 1, resourceType: 0, manaDiscount: 0, apBonus: 0, statMods: [int64(250), 0, -100, 0], hpMod: 0, tierWeights: [uint16(200), 200, 200, 200, 200]}));
        cr.registerAffixTemplate(4, CharacterRegistry.AffixTemplate({direction: 1, resourceType: 0, manaDiscount: 0, apBonus: 0, statMods: [int64(-50), 0, 0, 200], hpMod: 0, tierWeights: [uint16(200), 200, 200, 200, 200]}));
        cr.registerAffixTemplate(5, CharacterRegistry.AffixTemplate({direction: 1, resourceType: 1, manaDiscount: 5, apBonus: 0, statMods: [int64(0), 300, 0, 0], hpMod: -100, tierWeights: [uint16(200), 200, 200, 200, 200]}));
        cr.registerAffixTemplate(6, CharacterRegistry.AffixTemplate({direction: 1, resourceType: 2, manaDiscount: 0, apBonus: 3, statMods: [int64(200), 0, -150, 0], hpMod: 0, tierWeights: [uint16(200), 200, 200, 200, 200]}));
        cr.registerAffixTemplate(7, CharacterRegistry.AffixTemplate({direction: 2, resourceType: 0, manaDiscount: 0, apBonus: 0, statMods: [int64(-100), 0, 0, 0], hpMod: 0, tierWeights: [uint16(200), 200, 200, 200, 200]}));
        cr.registerAffixTemplate(8, CharacterRegistry.AffixTemplate({direction: 2, resourceType: 0, manaDiscount: 0, apBonus: 0, statMods: [int64(0), 0, 0, 0], hpMod: -100, tierWeights: [uint16(200), 200, 200, 200, 200]}));

        // ---- 技能 ----
        uint32 skillAttack = _registerSkill(sr, 1, 0, 10, 0, 0, 0, 0, 1, 0, 0, 100, 0, 1000, 0, _emptyEffects(), 0);
        uint32 skillMagicBolt = _registerSkill(sr, 2, 0, 0, 0, 0, 5, 0, 1, 0, 0, 150, 0, 1000, 0, _emptyEffects(), 0);
        uint32 skillHeal = _registerSkill(sr, 3, 0, 0, 0, 0, 5, 0, 5, 1, 0, 100, 0, 1000, 0, _healEffect(), 1);
        uint32 skillStrike3 = _registerSkill(sr, 1, 10, 15, 0, 0, 0, 0, 3, 0, 3, 50, 0, 1000, 0, _emptyEffects(), 0);
        uint32 skillShield = _registerSkill(sr, 3, 0, 0, 0, 0, 5, 0, 9, 0, 0, 100, 0, 1000, 0, _shieldEffect(), 1);
        uint32 skillStun = _registerSkill(sr, 1, 10, 0, 0, 0, 0, 0, 1, 0, 0, 50, 0, 1000, 0, _stunEffect(), 1);
        uint32 skillSmoke = _registerSkill(sr, 3, 0, 0, 0, 0, 5, 0, 8, 0, 0, 0, 0, 1000, 0, _smokeEffect(), 1);
        uint32 skillManaBurst = _registerSkill(sr, 3, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 0, 1000, 0, _manaBurstEffect(), 1);
        uint32 skillDot = _registerSkill(sr, 2, 0, 0, 0, 0, 5, 0, 1, 0, 0, 30, 0, 1000, 0, _dotEffect(), 1);
        uint32 skillTaunt = _registerSkill(sr, 3, 0, 0, 0, 0, 3, 0, 1, 0, 0, 0, 0, 1000, 0, _tauntEffect(), 1);
        uint32 skillBerserk = _registerSkill(sr, 3, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 0, 1000, 0, _berserkEffects(), 2);
        uint32 skillSummon = _registerSkill(sr, 4, 0, 0, 0, 0, 10, 0, 9, 0, 0, 0, 0, 1000, 0, _summonEffect(), 1);
        uint32 skillIdle = _registerSkill(sr, 3, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 0, 1000, 0, _emptyEffects(), 0);
        // 鹰眼：职业绑定（火枪手 classId=2）
        _registerClassSkill(sr, 2, 3, 5, 0, 0, 0, 0, 0, 9, 0, 0, 0, 0, 1000, 0, _guarNextEffect(), 1);

        // ---- 怪物 AI 与敌人模板 ----
        uint16 aiSlime = sr.registerAI(SkillRegistry.MonsterAI({skillCycle: [uint16(skillAttack), 0, 0, 0, 0, 0, 0, 0], cycleLen: 1}));
        uint16 aiBoss = sr.registerAI(SkillRegistry.MonsterAI({skillCycle: [uint16(skillAttack), uint16(skillAttack), uint16(skillMagicBolt), 0, 0, 0, 0, 0], cycleLen: 3}));

        uint16 templateSlime = sr.registerTemplate(SkillRegistry.EnemyTemplate({
            aiId: aiSlime, threat: 1, race: 0, maxHp: 50, power: 12, defense: 5, magic: 5, speed: 8, baseAcc: 1000,
            rewardMin: 5, rewardMax: 10,
            onDeathSpawn: SkillRegistry.OnDeathSpawn({templateId: 0, count: 0, prob: 0})
        }));
        uint16 templateBoss = sr.registerTemplate(SkillRegistry.EnemyTemplate({
            aiId: aiBoss, threat: 5, race: 0, maxHp: 200, power: 25, defense: 10, magic: 15, speed: 12, baseAcc: 1000,
            rewardMin: 30, rewardMax: 50,
            onDeathSpawn: SkillRegistry.OnDeathSpawn({templateId: templateSlime, count: 2, prob: 500})
        }));
        uint16 templateSummoned = sr.registerTemplate(SkillRegistry.EnemyTemplate({
            aiId: aiSlime, threat: 1, race: 0, maxHp: 30, power: 10, defense: 3, magic: 3, speed: 6, baseAcc: 1000,
            rewardMin: 3, rewardMax: 6,
            onDeathSpawn: SkillRegistry.OnDeathSpawn({templateId: 0, count: 0, prob: 0})
        }));

        // ---- 地下城 ----
        uint16[] memory ids = new uint16[](1);
        ids[0] = templateSlime;
        uint16[] memory ws = new uint16[](1);
        ws[0] = 100;
        ce.registerEnemyTable(1, ids, ws);
        ce.setDungeon(1, CombatTypes.DungeonConfig({tableId: 1, enemyCount: 2, manaPerTurn: 10, rewardBase: 20, entryFee: 5, rescueFee: 10, turnInterval: 5}));

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
            modRace: [uint8(0), 0, 0, 0], modPermille: [uint16(0), 0, 0, 0],
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
            modRace: [uint8(0), 0, 0, 0], modPermille: [uint16(0), 0, 0, 0],
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
        e[0] = SkillRegistry.Effect({op: 13, duration: 0, magnitude: 20, scope: 0, prob: 1000});
    }

    function _dotEffect() internal pure returns (SkillRegistry.Effect[4] memory e) {
        e[0] = SkillRegistry.Effect({op: 8, duration: 3, magnitude: 10, scope: 1, prob: 1000});
    }

    function _tauntEffect() internal pure returns (SkillRegistry.Effect[4] memory e) {
        e[0] = SkillRegistry.Effect({op: 11, duration: 2, magnitude: 0, scope: 1, prob: 1000});
    }

    function _berserkEffects() internal pure returns (SkillRegistry.Effect[4] memory e) {
        e[0] = SkillRegistry.Effect({op: 2, duration: 2, magnitude: 300, scope: 0, prob: 1000});
        e[1] = SkillRegistry.Effect({op: 3, duration: 2, magnitude: 200, scope: 0, prob: 1000});
    }

    function _summonEffect() internal pure returns (SkillRegistry.Effect[4] memory e) {
        e[0] = SkillRegistry.Effect({op: 14, duration: 0, magnitude: 0, scope: 0, prob: 1000});
    }

    function _guarNextEffect() internal pure returns (SkillRegistry.Effect[4] memory e) {
        e[0] = SkillRegistry.Effect({op: 7, duration: 2, magnitude: 0, scope: 0, prob: 1000});
    }
}

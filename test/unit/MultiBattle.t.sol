// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../BaseTest.sol";
import {CombatTypes} from "../../src/libs/CombatTypes.sol";
import {CharacterRegistry} from "../../src/core/CharacterRegistry.sol";
import {SkillRegistry} from "../../src/core/SkillRegistry.sol";

/// @title MultiBattle - 多场战斗推进 + 队长接任 + GM 造任意等级
/// @notice 只验证机制行为（阶段切换/队长接任/300 级属性），不做严格数值断言（数值层未定档）。
///         机制验证用独立难度 6/8 的轻量地下城，不占用真实 D9（难度 9 由 BaseTest._seedD9 播种）。
contract MultiBattleTest is BaseTest {
    uint16 aiAoE;
    uint16 templateAoETank;

    // ---- 机制用地下城：难度 6 = 4 场轻量（battleIndex 推进）/ 难度 8 = 1 场 AoE 坦克（队长接任）----
    function _seedMechanicsDungeons() internal {
        uint16[] memory s1 = new uint16[](1); s1[0] = templateSlime; uint16[] memory w1 = new uint16[](1); w1[0] = 100;
        ce.registerEnemyTable(61, s1, w1); // 第 1 场：史莱姆
        uint16[] memory s2 = new uint16[](1); s2[0] = templateBoss; uint16[] memory w2 = new uint16[](1); w2[0] = 100;
        ce.registerEnemyTable(62, s2, w2); // 第 2 场：Boss
        uint16[] memory s3 = new uint16[](1); s3[0] = templateSlime; uint16[] memory w3 = new uint16[](1); w3[0] = 100;
        ce.registerEnemyTable(63, s3, w3); // 第 3 场：史莱姆
        uint16[] memory s4 = new uint16[](1); s4[0] = templateSlime; uint16[] memory w4 = new uint16[](1); w4[0] = 100;
        ce.registerEnemyTable(64, s4, w4); // 第 4 场（末场）：史莱姆

        ce.setDungeon(6, CombatTypes.DungeonConfig({tableId: 61, enemyCount: 2, manaPerTurn: 1, rewardBase: 20, entryFee: 5, rescueFee: 10, turnInterval: 0, battles: 4}));
        CombatTypes.BattleConfig[] memory bcs = new CombatTypes.BattleConfig[](4);
        bcs[0] = CombatTypes.BattleConfig({tableId: 61, enemyCount: 2});
        bcs[1] = CombatTypes.BattleConfig({tableId: 62, enemyCount: 1});
        bcs[2] = CombatTypes.BattleConfig({tableId: 63, enemyCount: 1});
        bcs[3] = CombatTypes.BattleConfig({tableId: 64, enemyCount: 1});
        ce.setDungeonBattles(6, bcs);

        // AoE 坦克：AOE 全体固定伤害、超高血、超高速（队长接任用：全场同受伤害速杀）
        SkillRegistry.Skill memory aoe = SkillRegistry.Skill({
            id: 0, kind: 1, apCost: 0, apGain: 0, ammoId: 0, ammoCost: 0, manaCost: 0, hpCost: 0,
            targeting: 4, weightMode: 0, targetCount: 0, power: 2000, damageCap: 0, baseAcc: 1000, flags: 0,
            effects: [empty(0), empty(0), empty(0), empty(0)], effectCount: 0,
            summon: SkillRegistry.SummonRule({templateId: 0, maxCount: 0, enemyHeadroom: 0})
        });
        uint32 aoeId = sr.registerSkill(aoe);
        aiAoE = sr.registerAI(SkillRegistry.MonsterAI({skillCycle: [uint16(aoeId), 0, 0, 0, 0, 0, 0, 0], cycleLen: 1}));
        templateAoETank = sr.registerTemplate(SkillRegistry.EnemyTemplate({
            aiId: aiAoE, threat: 1, maxHp: 1_000_000, power: 100, magic: 0, speed: 255, baseAcc: 1000,
            rewardMin: 0, rewardMax: 0,
            onDeathSpawn: SkillRegistry.OnDeathSpawn({templateId: 0, count: 0, prob: 0})
        }));
        uint16[] memory idsA = new uint16[](1); idsA[0] = templateAoETank;
        uint16[] memory wsA = new uint16[](1); wsA[0] = 100;
        ce.registerEnemyTable(88, idsA, wsA);
        ce.setDungeon(8, CombatTypes.DungeonConfig({tableId: 88, enemyCount: 1, manaPerTurn: 0, rewardBase: 0, entryFee: 0, rescueFee: 0, turnInterval: 0, battles: 1}));
    }

    function empty(uint8 op) internal pure returns (SkillRegistry.Effect memory e) {
        return SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000});
    }

    function setUp() public override {
        super.setUp();
        _seedMechanicsDungeons();
    }

    function _driveToOver(uint32 roomId, uint16 maxTurns) internal {
        // 用 alice 的身份排攻击计划（角色已在外层创建）
        uint32[] memory solo = new uint32[](1);
        solo[0] = skillAttack;
        vm.prank(alice);
        ce.setPlan(roomId, _planOf(solo), 1);
        uint16 guard = 0;
        while (ce.getRoom(roomId).phase == ce.PHASE_COMBAT() && guard < maxTurns) {
            ce.advanceTurn(roomId);
            guard++;
        }
    }

    function _planOf(uint32[] memory skillIds) internal pure returns (uint16[16] memory plan) {
        for (uint256 i; i < skillIds.length; ++i) plan[i] = uint16(skillIds[i]);
    }

    // ---------- 1) GM 制造 300 级角色：HP 无加成基线 = 30000；能力值 = 1 级基准 × 300 ----------
    function test_GmMintThreeHundred_HpThirtyThousand() public {
        // 无职业·人类：HP 修正 0 → 满级无生命加成 = BASE_HP(100) × 300 = 30000（设计锚点）
        uint256 id = cr.gmMintCharacterAtLevel(alice, 6, 0, new uint16[](0), new uint32[](0), 300);
        (uint64 hp, uint64 maxHp, uint64 atk,,) = cr.getStats(id);
        assertEq(cr.getCharacter(id).level, 300, "level 300");
        assertEq(hp, 30_000, "no-bonus level300 HP = 30000");
        // 能力值 = 1 级基准 × 300 线性插值：无职业物攻 +1000‰（×2），10 × 2 × 300 = 6000
        assertEq(atk, 6000, "attack = base x classMod x 300");
    }

    function test_GmSetLevel_MovesStats() public {
        uint256 id = _gmCharacter(alice, 6, 0, new uint16[](0), new uint32[](0));
        (,,, uint64 atk1,) = cr.getStats(id);
        cr.gmSetLevel(id, 300);
        (uint64 hp,,, uint64 atk300,) = cr.getStats(id);
        assertEq(hp, 30_000, "hp 30000 at 300");
        assertEq(atk300, atk1 * 300, "atk x300");
    }

    // ---------- 2) 多场地下城推进：队长 advanceBattle 进入下一场，末场才结算 ----------
    function test_MultiBattle_Advance_OnlyByLeader() public {
        vm.prank(alice);
        uint32 roomId = ce.createRoom(6);
        assertEq(ce.getRoom(roomId).totalBattles, 4, "4 battles registered");
        // 300 级无职业·人类进房（自带 skillAttack，有 3 槽位足以保留，清弱史莱姆）
        uint32[] memory solo = new uint32[](1);
        solo[0] = skillAttack;
        uint256 sword = cr.gmMintCharacterAtLevel(alice, 6, 0, new uint16[](0), solo, 300);
        _joinAndStart(alice, roomId, sword);
        assertEq(ce.getRoom(roomId).battleIndex, 1, "battle 1");

        // 第 1 场清场 → INTERMISSION
        _driveToOver(roomId, 30);
        assertEq(uint8(ce.getRoom(roomId).phase), uint8(ce.PHASE_INTERMISSION()), "intermission after b1");

        // 非队长不能推进（中途可加入：INTERMISSION 可 joinRoom）
        uint256 bow = cr.gmMintCharacterAtLevel(bob, 1, 0, new uint16[](0), new uint32[](0), 300);
        vm.prank(bob);
        ce.joinRoom(roomId, bow);
        vm.prank(bob);
        vm.expectRevert(bytes("CE: not leader"));
        ce.advanceBattle(roomId);

        // 队长推进 → 第 2 场（Boss）
        vm.prank(alice);
        ce.advanceBattle(roomId);
        assertEq(ce.getRoom(roomId).battleIndex, 2, "battle 2");
        assertEq(uint8(ce.getRoom(roomId).phase), uint8(ce.PHASE_COMBAT()), "combat after advance");

        _driveToOver(roomId, 30);
        assertEq(uint8(ce.getRoom(roomId).phase), uint8(ce.PHASE_INTERMISSION()), "intermission after b2");

        // 推进 → 第 3 场
        vm.prank(alice);
        ce.advanceBattle(roomId);
        assertEq(ce.getRoom(roomId).battleIndex, 3, "battle 3");
        _driveToOver(roomId, 30);
        assertEq(uint8(ce.getRoom(roomId).phase), uint8(ce.PHASE_INTERMISSION()), "intermission after b3");

        // 推进到第 4 场（末场）→ 清场后直接最终结算
        vm.prank(alice);
        ce.advanceBattle(roomId);
        assertEq(ce.getRoom(roomId).battleIndex, 4, "battle 4");
        _driveToOver(roomId, 30);
        assertEq(uint8(ce.getRoom(roomId).phase), uint8(ce.PHASE_SETTLED()), "final settle");
    }

    // ---------- 3) 队长战死 → 按进入顺序接任；傀儡不可当队长 ----------
    function test_CaptainSuccession_ByEntryOrder() public {
        // difficulty 8：1 个 AoE 坦克，全体每回合受到 (2000×100/1000)=200 伤害
        // 剑士 1 级 HP=120，首回合即阵亡；队长先死则按加入顺序接任
        uint256 c1 = cr.gmMintCharacterAtLevel(alice, 1, 0, new uint16[](0), new uint32[](0), 1);
        uint256 c2 = cr.gmMintCharacterAtLevel(bob, 1, 0, new uint16[](0), new uint32[](0), 1);

        vm.prank(alice);
        uint32 roomId = ce.createRoom(8);
        vm.prank(alice);
        ce.joinRoom(roomId, c1);
        vm.prank(bob);
        ce.joinRoom(roomId, c2); // 开战前加入（战斗开始后不再可入房）
        vm.prank(alice);
        ce.startCombat(roomId);
        assertEq(ce.getRoom(roomId).leader, alice, "alice leads");

        // 打到 alice（队长）阵亡 → 队长自动接任 bob
        uint16 guard = 0;
        while (ce.getRoom(roomId).members[0].alive && guard < 30) {
            ce.advanceTurn(roomId);
            guard++;
        }
        assertTrue(!ce.getRoom(roomId).members[0].alive, "alice died");
        assertEq(ce.getRoom(roomId).leader, bob, "bob succeeds in entry order");
    }
}
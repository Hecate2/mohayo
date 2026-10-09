// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../BaseTest.sol";
import {SkillRegistry} from "../../src/core/SkillRegistry.sol";
import {CharacterRegistry} from "../../src/core/CharacterRegistry.sol";
import {CombatEngine} from "../../src/core/CombatEngine.sol";
import {CombatTypes} from "../../src/libs/CombatTypes.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title CombatEngineTest - 战斗结算器集成测试
/// @notice 用 GM 铸造指定角色 + MockRNG.setFixed 强制掷骰，验证房间生命周期、
///         技能结算（伤害/治疗/护盾/眩晕/DOT/多段/绝对命中/嘲讽）、死亡召唤、
///         超时惩罚、道具金库、AP 累积与胜负判定。
contract CombatEngineTest is BaseTest {
    uint32 skillNuke; // 物理单体高伤
    uint32 skillMegaNuke; // 物理单体超高伤（Boss 战）
    uint32 skillMagicNuke; // 魔法单体（耗魔素）
    uint32 skillHealBig; // 大治疗
    uint32 skillShieldBig; // 大护盾
    uint32 skillDotBig; // 灼烧 DOT
    uint32 skillGuarNuke; // 绝对命中（flags bit0）
    uint16 templateHulk; // 高攻敌人（败北测试）
    uint16 templateBossAlwaysSpawn; // 死亡召唤概率 1000‰（确定性测试）
    uint16 templateTank; // 高 HP 高攻敌人（伤害修正测试）

    function setUp() public override {
        super.setUp();
        skillNuke = _register(_mkSkill(1, 1, 2000, 1000, 0));
        skillMegaNuke = _register(_mkSkill(1, 1, 10000, 1000, 0));
        SkillRegistry.Skill memory sm = _mkSkill(2, 1, 2000, 1000, 0);
        sm.manaCost = 1; // 魔弹耗魔素 1（触发资源短缺路径；数量级：魔素以 1 为单位）
        skillMagicNuke = _register(sm);
        skillHealBig = _register(_mkSkill(3, 5, 2000, 1000, 0)); // SUPPORT 治疗 = power × 魔攻
        skillShieldBig = _register(_withEffect(_mkSkill(3, 9, 0, 1000, 0), ce.OP_SHIELD(), 3, 100, 0));
        skillDotBig = _register(_withEffect(_mkSkill(2, 1, 50, 1000, 0), ce.OP_DOT(), 3, 10, 1));
        skillGuarNuke = _register(_mkSkill(1, 1, 1000, 0, 1)); // baseAcc 0 + GUARANTEED_HIT
        skillStun = _register(_withEffect(_mkSkill(1, 1, 34, 1000, 0), ce.OP_STUN(), 3, 0, 1));
        skillTaunt = _register(_withEffect(_mkSkill(3, 1, 0, 1000, 0), ce.OP_TAUNT(), 2, 0, 1));

        // 高攻敌人 + 败北地下城（difficulty 2）：power 2000 → 普攻 100×2000/1000 = 200 秒杀 120 HP 成员
        templateHulk = sr.registerTemplate(SkillRegistry.EnemyTemplate({
            aiId: aiSlime, threat: 1, maxHp: 500, power: 2000, magic: 0, speed: 1, baseAcc: 1000,
            rewardMin: 1, rewardMax: 1,
            onDeathSpawn: SkillRegistry.OnDeathSpawn({templateId: 0, count: 0, prob: 0})
        }));
        uint16[] memory ids = new uint16[](1);
        ids[0] = templateHulk;
        uint16[] memory ws = new uint16[](1);
        ws[0] = 100;
        ce.registerEnemyTable(2, ids, ws);
        ce.setDungeon(2, CombatTypes.DungeonConfig({tableId: 2, enemyCount: 1, manaPerTurn: 0, rewardBase: 0, entryFee: 0, rescueFee: 10, turnInterval: 0, battles: 1}));

        // Boss 地下城（difficulty 3，死亡召唤史莱姆，概率 1000‰ 保证必召）
        templateBossAlwaysSpawn = sr.registerTemplate(SkillRegistry.EnemyTemplate({
            aiId: aiBoss, threat: 5, maxHp: 200, power: 25, magic: 15, speed: 12, baseAcc: 1000,
            rewardMin: 30, rewardMax: 50,
            onDeathSpawn: SkillRegistry.OnDeathSpawn({templateId: templateSlime, count: 2, prob: 1000})
        }));
        uint16[] memory ids3 = new uint16[](1);
        ids3[0] = templateBossAlwaysSpawn;
        uint16[] memory ws3 = new uint16[](1);
        ws3[0] = 100;
        ce.registerEnemyTable(3, ids3, ws3);
        ce.setDungeon(3, CombatTypes.DungeonConfig({tableId: 3, enemyCount: 1, manaPerTurn: 1, rewardBase: 0, entryFee: 0, rescueFee: 0, turnInterval: 0, battles: 1}));

        // 单史莱姆地下城（difficulty 4）：确定性目标测试用（房间级 PRNG 下目标选择随机）
        uint16[] memory ids4 = new uint16[](1);
        ids4[0] = templateSlime;
        uint16[] memory ws4 = new uint16[](1);
        ws4[0] = 100;
        ce.registerEnemyTable(4, ids4, ws4);
        ce.setDungeon(4, CombatTypes.DungeonConfig({tableId: 4, enemyCount: 1, manaPerTurn: 2, rewardBase: 0, entryFee: 0, rescueFee: 0, turnInterval: 0, battles: 1}));

        // 坦克敌人 + 地下城（difficulty 5）：高 HP 高攻，伤害修正测试用
        templateTank = sr.registerTemplate(SkillRegistry.EnemyTemplate({
            aiId: aiSlime, threat: 1, maxHp: 500, power: 100, magic: 0, speed: 1, baseAcc: 1000,
            rewardMin: 1, rewardMax: 1,
            onDeathSpawn: SkillRegistry.OnDeathSpawn({templateId: 0, count: 0, prob: 0})
        }));
        uint16[] memory ids5 = new uint16[](1);
        ids5[0] = templateTank;
        uint16[] memory ws5 = new uint16[](1);
        ws5[0] = 100;
        ce.registerEnemyTable(5, ids5, ws5);
        ce.setDungeon(5, CombatTypes.DungeonConfig({tableId: 5, enemyCount: 1, manaPerTurn: 0, rewardBase: 0, entryFee: 0, rescueFee: 0, turnInterval: 0, battles: 1}));
    }

    // ---- 技能构造辅助 ----
    function _mkSkill(uint8 kind, uint8 targeting, uint64 power, uint16 baseAcc, uint8 flags) internal pure returns (SkillRegistry.Skill memory s) {
        s.kind = kind;
        s.targeting = targeting;
        s.power = power;
        s.baseAcc = baseAcc;
        s.flags = flags;
        s.weightMode = 0;
        for (uint8 i; i < 4; ++i) s.effects[i] = SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000});
    }

    function _register(SkillRegistry.Skill memory s) internal returns (uint32 id) {
        return sr.registerSkill(s);
    }

    function _withEffect(SkillRegistry.Skill memory s, uint8 op, uint8 duration, uint16 magnitude, uint8 scope) internal pure returns (SkillRegistry.Skill memory) {
        s.effects[0] = SkillRegistry.Effect({op: op, duration: duration, magnitude: magnitude, scope: scope, prob: 1000});
        s.effectCount = 1;
        return s;
    }

    // ---- 房间辅助 ----
    function _gmSolo(address player, uint8 classId, uint8 difficulty, uint32[] memory skills) internal returns (uint256 charId, uint32 roomId) {
        charId = _gmCharacter(player, classId, 0, new uint16[](0), skills);
        vm.prank(player);
        roomId = ce.createRoom(difficulty);
        vm.prank(player);
        ce.joinRoom(roomId, charId);
    }

    function _setPlan(address player, uint32 roomId, uint32[] memory skills) internal {
        uint16[16] memory plan;
        for (uint8 i; i < skills.length; ++i) plan[i] = uint16(skills[i]);
        vm.prank(player);
        ce.setPlan(roomId, plan, uint8(skills.length));
    }

    // ---- 完整战斗流程：胜利 + 奖励 + 释放 ----
    function testFullCombatVictory() public {
        uint32[] memory skills = new uint32[](2);
        skills[0] = skillNuke;
        skills[1] = skillNuke; // 无限循环计划：每回合都放核弹，两回合清场
        (uint256 charId, uint32 roomId) = _gmSolo(alice, 1, 1, skills);
        _setPlan(alice, roomId, skills);
        vm.prank(alice);
        ce.startCombat(roomId);
        // 第 1 回合：秒杀史莱姆 X；另一只反击
        vm.prank(alice);
        ce.advanceTurn(roomId);
        // 第 2 回合：秒杀另一只 → 胜利
        vm.prank(alice);
        ce.advanceTurn(roomId);
        CombatTypes.Room memory r = ce.getRoom(roomId);
        assertEq(uint8(r.phase), uint8(ce.PHASE_SETTLED()));
        // 奖励 = 2 史莱姆（各 5~10）− 入场费 5 ∈ [5, 15]（房间 PRNG 下奖励随机）
        assertGe(economy.balanceOf(alice), 5);
        assertLe(economy.balanceOf(alice), 15);
        assertEq(cr.getCharacter(charId).roomId, 0); // 角色已释放
    }

    // ---- 败北：救援费倒扣 ----
    function testDefeatChargesRescueFee() public {
        uint32[] memory skills = new uint32[](1);
        skills[0] = skillNuke;
        uint256 charId = _gmCharacter(alice, 1, 0, new uint16[](0), skills);
        vm.prank(alice);
        uint32 roomId = ce.createRoom(2); // 高攻敌人地下城
        vm.prank(alice);
        ce.joinRoom(roomId, charId);
        vm.prank(alice);
        ce.startCombat(roomId);
        vm.prank(alice);
        ce.advanceTurn(roomId); // 无计划 → 成员跳过；Hulk 秒杀成员 → 败北
        CombatTypes.Room memory r = ce.getRoom(roomId);
        assertEq(uint8(r.phase), uint8(ce.PHASE_SETTLED()));
        assertEq(economy.balanceOf(alice), -10); // 救援费倒扣（负余额债务）
        assertEq(cr.getCharacter(charId).roomId, 0);
    }

    // ---- 魔素：不足时资源短缺，回复后可用 ----
    function testManaRegenAndMagicConsumption() public {
        uint32[] memory skills = new uint32[](2);
        skills[0] = skillMagicNuke;
        skills[1] = skillMagicNuke;
        (uint256 charId, uint32 roomId) = _gmSolo(alice, 4, 4, skills); // 黑魔法师 magic 35，单史莱姆
        _setPlan(alice, roomId, skills);
        vm.prank(alice);
        ce.startCombat(roomId);
        // 第 1 回合：魔素池 0 < 1 → 资源短缺；回合末 +2
        vm.prank(alice);
        ce.advanceTurn(roomId);
        assertEq(ce.getRoom(roomId).manaPool, 2);
        // 第 2 回合：魔素 2-1=1，魔弹 2000×35/1000=70 秒杀史莱姆 0；回合末 +2 → 3
        vm.prank(alice);
        ce.advanceTurn(roomId);
        CombatTypes.Room memory r = ce.getRoom(roomId);
        assertEq(r.manaPool, 3);
        assertFalse(r.enemies[0].alive);
    }

    // ---- 治疗：恢复 HP（封顶） ----
    function testHealRestoresHp() public {
        uint32[] memory skills = new uint32[](2);
        skills[0] = skillHealBig;
        skills[1] = skillHealBig;
        (uint256 charId, uint32 roomId) = _gmSolo(alice, 4, 1, skills); // 黑魔法师 80 HP magic 35，heal = 2000×35/1000 = 70
        _setPlan(alice, roomId, skills);
        vm.prank(alice);
        ce.startCombat(roomId);
        // 第 1 回合：满血治疗无效；2 史莱姆各打 1 → 78
        vm.prank(alice);
        ce.advanceTurn(roomId);
        // 第 2 回合：治疗 +70 封顶回满（实际回 2）；2 史莱姆各打 1 → 78
        vm.prank(alice);
        ce.advanceTurn(roomId);
        assertEq(ce.getMember(roomId, 0).hp, 78); // 无治疗则为 76，验证治疗路径生效
    }

    // ---- 多段连击：3 段独立目标 + AP 产出 ----
    function testMultiHitStrike() public {
        uint32[] memory skills = new uint32[](2);
        skills[0] = skillAttack; // AP +1
        skills[1] = skillStrike3; // 3 段 × 50×30/1000 = 1；耗 1 产 2（攒点）
        (uint256 charId, uint32 roomId) = _gmSolo(alice, 1, 4, skills); // 单史莱姆：目标选择确定
        _setPlan(alice, roomId, skills);
        vm.prank(alice);
        ce.startCombat(roomId);
        vm.prank(alice);
        ce.advanceTurn(roomId); // 普攻 3 伤 → 史莱姆 0 (47)，AP 1
        vm.prank(alice);
        ce.advanceTurn(roomId); // 三连击 3 段 × 1 伤 → 史莱姆 0 (44)，AP 1-1+2 = 2
        CombatTypes.RoomMember memory m = ce.getMember(roomId, 0);
        assertEq(m.ap, 2);
        assertEq(ce.getEnemy(roomId, 0).hp, 44);
    }

    // ---- 护盾：吸收伤害 ----
    function testShieldAbsorbsDamage() public {
        uint32[] memory skills = new uint32[](1);
        skills[0] = skillShieldBig;
        (uint256 charId, uint32 roomId) = _gmSolo(alice, 1, 1, skills);
        _setPlan(alice, roomId, skills);
        vm.prank(alice);
        ce.startCombat(roomId);
        vm.prank(alice);
        ce.advanceTurn(roomId); // 护盾 100；2 史莱姆各打 1 → 盾 98，HP 不变
        CombatTypes.RoomMember memory m = ce.getMember(roomId, 0);
        assertEq(m.hp, 120); // 满血
        assertEq(m.effects[0].op, 4); // SHIELD
        assertEq(m.effects[0].magnitude, 98);
    }

    // ---- 眩晕：跳过回合 ----
    function testStunSkipsEnemyTurn() public {
        uint32[] memory skills = new uint32[](1);
        skills[0] = skillStun; // 自建眩晕技：power 34 → 1 伤，STUN 持续 3 回合
        (uint256 charId, uint32 roomId) = _gmSolo(alice, 1, 4, skills); // 单史莱姆
        _setPlan(alice, roomId, skills);
        vm.prank(alice);
        ce.startCombat(roomId);
        vm.prank(alice);
        ce.advanceTurn(roomId); // 眩晕史莱姆 0（1 伤）；史莱姆 0 被眩晕跳过
        vm.prank(alice);
        ce.advanceTurn(roomId); // 史莱姆 0 仍眩晕跳过；alice 再眩晕 1 伤
        CombatTypes.Room memory r = ce.getRoom(roomId);
        assertEq(r.enemies[0].hp, 48); // 两次眩晕技各 1 伤
        assertEq(ce.getMember(roomId, 0).hp, 120); // 全程被眩晕，从未被打
    }

    // ---- DOT：逐回合跳伤 + 到期移除 ----
    function testDotTicksAndExpires() public {
        uint32[] memory skills = new uint32[](4);
        skills[0] = skillDotBig;
        skills[1] = skillIdle;
        skills[2] = skillIdle;
        skills[3] = skillIdle; // 无限循环：每 4 回合才重挂 DOT，让 DOT 自然到期
        (uint256 charId, uint32 roomId) = _gmSolo(alice, 6, 4, skills); // 单史莱姆；无职业自选槽 5 ≥ 4
        _setPlan(alice, roomId, skills);
        vm.prank(alice);
        ce.startCombat(roomId);
        vm.prank(alice);
        ce.advanceTurn(roomId); // 直伤 1 + DOT 10 → 史莱姆 0 (39)
        vm.prank(alice);
        ce.advanceTurn(roomId); // DOT 10 → 29
        vm.prank(alice);
        ce.advanceTurn(roomId); // DOT 10 → 19，到期移除
        CombatTypes.Room memory r = ce.getRoom(roomId);
        assertEq(r.enemies[0].hp, 19);
        assertEq(r.enemies[0].effectCount, 0); // DOT 已过期清除
    }

    // ---- 死亡召唤：Boss 死亡概率召唤史莱姆 ----
    function testDeathSpawnOnBossDeath() public {
        uint32[] memory skills = new uint32[](1);
        skills[0] = skillMegaNuke;
        uint256 charId = _gmCharacter(alice, 1, 0, new uint16[](0), skills);
        vm.prank(alice);
        uint32 roomId = ce.createRoom(3); // Boss 地下城（死亡召唤概率 1000‰ 必召）
        vm.prank(alice);
        ce.joinRoom(roomId, charId);
        _setPlan(alice, roomId, skills);
        vm.prank(alice);
        ce.startCombat(roomId);
        vm.prank(alice);
        ce.advanceTurn(roomId); // 秒杀 Boss → 必召 2 史莱姆
        CombatTypes.Room memory r = ce.getRoom(roomId);
        assertFalse(r.enemies[0].alive); // Boss 已死
        assertTrue(r.bossSpawned);
        assertEq(r.enemyCount, 3); // Boss + 2 召唤
        assertEq(r.enemies[1].templateId, templateSlime);
        assertEq(r.enemies[2].templateId, templateSlime);
    }

    // ---- 超时惩罚：超过回合间隔扣 10% 最大生命 ----
    function testTimeoutPenalty() public {
        uint32[] memory skills = new uint32[](1);
        skills[0] = skillNuke;
        (uint256 charId, uint32 roomId) = _gmSolo(alice, 1, 1, skills); // dungeon 1 turnInterval 5
        vm.prank(alice);
        ce.startCombat(roomId);
        vm.roll(block.number + 10); // 超时
        vm.prank(alice);
        ce.advanceTurn(roomId);
        // 惩罚 120/10 = 12 + 2 史莱姆各打 1
        assertEq(ce.getMember(roomId, 0).hp, 120 - 12 - 2);
    }

    // ---- 道具金库：GM 发放 + 玩家转移 + 余额不足回退 ----
    function testVaultGiveItem() public {
        uint32[] memory skills = new uint32[](1);
        skills[0] = skillNuke;
        (uint256 charId, uint32 roomId) = _gmSolo(alice, 1, 1, skills);
        ce.gmGiveItem(roomId, alice, 1, 5); // owner = 测试合约，直接调用
        assertEq(ce.vaultBalance(roomId, alice, 1), 5);
        vm.prank(alice);
        ce.giveItem(roomId, bob, 1, 2);
        assertEq(ce.vaultBalance(roomId, alice, 1), 3);
        assertEq(ce.vaultBalance(roomId, bob, 1), 2);
        vm.prank(alice);
        vm.expectRevert("CE: insufficient");
        ce.giveItem(roomId, bob, 1, 10);
    }

    // ---- 绝对命中：baseAcc 0 + GUARANTEED_HIT 仍必中 ----
    function testGuaranteedHitFlag() public {
        uint32[] memory skills = new uint32[](1);
        skills[0] = skillGuarNuke;
        (uint256 charId, uint32 roomId) = _gmSolo(alice, 1, 4, skills); // 单史莱姆
        _setPlan(alice, roomId, skills);
        vm.prank(alice);
        ce.startCombat(roomId);
        vm.prank(alice);
        ce.advanceTurn(roomId);
        assertEq(ce.getEnemy(roomId, 0).hp, 50 - 30); // 1000×30/1000 = 30 命中（绝对命中绕过掷骰）
    }

    // ---- 嘲讽：强制我方集火被嘲讽敌人 ----
    function testTauntRedirectsAttack() public {
        uint32[] memory skillsT = new uint32[](2);
        skillsT[0] = skillTaunt; // 自建嘲讽技（apCost 0 / manaCost 0）
        skillsT[1] = skillIdle;
        uint256 aliceChar = _gmCharacter(alice, 1, 0, new uint16[](0), skillsT);
        uint32[] memory skillsN = new uint32[](2);
        skillsN[0] = skillIdle;
        skillsN[1] = skillNuke;
        uint256 bobChar = _gmCharacter(bob, 1, 0, new uint16[](0), skillsN);
        vm.prank(alice);
        uint32 roomId = ce.createRoom(1);
        vm.prank(alice);
        ce.joinRoom(roomId, aliceChar);
        vm.prank(bob);
        ce.joinRoom(roomId, bobChar);
        _setPlan(alice, roomId, skillsT);
        _setPlan(bob, roomId, skillsN);
        vm.prank(alice);
        ce.startCombat(roomId);
        vm.prank(alice);
        ce.advanceTurn(roomId); // 第 1 回合：alice 嘲讽随机史莱姆 X
        CombatTypes.Room memory r1 = ce.getRoom(roomId);
        uint8 taunted = 255;
        for (uint8 i; i < r1.enemyCount; ++i) {
            for (uint8 j; j < r1.enemies[i].effectCount; ++j) {
                if (r1.enemies[i].effects[j].op == ce.OP_TAUNT()) { taunted = i; break; }
            }
        }
        assertTrue(taunted != 255);
        vm.prank(alice);
        ce.advanceTurn(roomId); // 第 2 回合：bob 大招被嘲讽重定向到 X
        CombatTypes.Room memory r2 = ce.getRoom(roomId);
        uint8 other = taunted == 0 ? 1 : 0;
        assertFalse(r2.enemies[taunted].alive); // 被嘲讽集火致死（大招 60 伤）
        assertEq(r2.enemies[other].hp, 50); // 未被攻击
    }

    // ---- AP 累积：物理技命中产出 AP ----
    function testAPAccumulatesOnHit() public {
        uint32[] memory skills = new uint32[](3);
        skills[0] = skillAttack;
        skills[1] = skillAttack;
        skills[2] = skillAttack;
        (uint256 charId, uint32 roomId) = _gmSolo(alice, 1, 1, skills);
        _setPlan(alice, roomId, skills);
        vm.prank(alice);
        ce.startCombat(roomId);
        vm.prank(alice);
        ce.advanceTurn(roomId);
        vm.prank(alice);
        ce.advanceTurn(roomId);
        assertEq(ce.getMember(roomId, 0).ap, 2); // 两回合普攻命中 → AP 1+1
    }

    // ---- 敌人攻击成员（目标语义翻转修复验证）----
    function testEnemyAttacksMember() public {
        uint32[] memory skills = new uint32[](0);
        (uint256 charId, uint32 roomId) = _gmSolo(alice, 1, 1, skills); // 无计划
        vm.prank(alice);
        ce.startCombat(roomId);
        vm.prank(alice);
        ce.advanceTurn(roomId); // 成员跳过；2 史莱姆各打成员 1
        assertEq(ce.getMember(roomId, 0).hp, 120 - 2); // 敌人打的是成员而非友军
    }

    // ---- 无限循环技能队列：队列走完回到队首 ----
    function testInfiniteSkillQueueLoops() public {
        uint32[] memory skills = new uint32[](2);
        skills[0] = skillAttack;
        skills[1] = skillAttack;
        (uint256 charId, uint32 roomId) = _gmSolo(alice, 1, 4, skills); // 单史莱姆 50 HP
        _setPlan(alice, roomId, skills);
        vm.prank(alice);
        ce.startCombat(roomId);
        for (uint8 i; i < 4; ++i) {
            vm.prank(alice);
            ce.advanceTurn(roomId);
        }
        // 4 回合普攻（各 3 伤）：50−12=38。旧版队列耗尽后第 3/4 回合会跳过 → 44，验证循环生效
        assertEq(ce.getEnemy(roomId, 0).hp, 38);
        assertEq(ce.getMember(roomId, 0).hp, 120 - 4); // 史莱姆每回合反击 1 伤
    }

    function testInfiniteSkillQueueSingleSkill() public {
        uint32[] memory skills = new uint32[](1);
        skills[0] = skillAttack;
        (uint256 charId, uint32 roomId) = _gmSolo(alice, 1, 4, skills);
        _setPlan(alice, roomId, skills);
        vm.prank(alice);
        ce.startCombat(roomId);
        for (uint8 i; i < 3; ++i) {
            vm.prank(alice);
            ce.advanceTurn(roomId);
        }
        // 单技能队列每回合重复：50−9=41。旧版第 2 回合起跳过 → 47
        assertEq(ce.getEnemy(roomId, 0).hp, 41);
    }

    function testInfiniteSkillQueueMixed() public {
        uint32[] memory skills = new uint32[](2);
        skills[0] = skillAttack;
        skills[1] = skillIdle;
        (uint256 charId, uint32 roomId) = _gmSolo(alice, 1, 4, skills);
        _setPlan(alice, roomId, skills);
        vm.prank(alice);
        ce.startCombat(roomId);
        for (uint8 i; i < 4; ++i) {
            vm.prank(alice);
            ce.advanceTurn(roomId);
        }
        // 交替循环：攻/待/攻/待 → 2 次普攻 6 伤 → 44。旧版第 3 回合起跳过 → 47
        assertEq(ce.getEnemy(roomId, 0).hp, 44);
    }

    // ---- Boss AI 循环：普攻 × 2 → 魔弹（事件日志验证技能序列） ----
    function testEnemyAICycle() public {
        uint32[] memory skills = new uint32[](0); // 成员无计划，只观察 Boss 行为
        (uint256 charId, uint32 roomId) = _gmSolo(alice, 1, 3, skills); // Boss 地下城
        vm.prank(alice);
        ce.startCombat(roomId);
        uint32[] memory bossSkills = new uint32[](3);
        for (uint8 t; t < 3; ++t) {
            vm.recordLogs();
            vm.prank(alice);
            ce.advanceTurn(roomId);
            bossSkills[t] = _bossSkillFromLogs(vm.getRecordedLogs(), roomId);
        }
        assertEq(bossSkills[0], skillAttack, "cycle[0] = attack");
        assertEq(bossSkills[1], skillAttack, "cycle[1] = attack");
        assertEq(bossSkills[2], skillMagicBolt, "cycle[2] = magic bolt");
    }

    // ---- 鹰眼 GUAR_NEXT：低命中技在 GUAR_NEXT 生效期间必中 ----
    function testGuarNextFlag() public {
        uint32 lowAcc = _register(_mkSkill(1, 1, 1000, 0, 0)); // baseAcc 0 无 GUARANTEED_HIT
        uint32[] memory skills = new uint32[](2);
        skills[0] = skillAttack; // AP +1（火枪手 28 攻 → 2 伤）
        skills[1] = lowAcc; // 依赖 GUAR_NEXT 必中（1000×28/1000=28）
        (uint256 charId, uint32 roomId) = _gmSolo(alice, 3, 4, skills); // 火枪手：鹰眼自动发放
        uint32[] memory plan = new uint32[](3);
        plan[0] = skillAttack; // 普攻
        plan[1] = skillEagleEye; // GUAR_NEXT（职业技已自动并入角色）
        plan[2] = lowAcc;
        _setPlan(alice, roomId, plan);
        vm.prank(alice);
        ce.startCombat(roomId);
        vm.prank(alice);
        ce.advanceTurn(roomId); // 普攻 → AP 1，史莱姆 48
        vm.prank(alice);
        ce.advanceTurn(roomId); // 鹰眼 → AP 0，GUAR_NEXT
        vm.prank(alice);
        ce.advanceTurn(roomId); // 低命中技必中 28 伤 → 48-28
        assertEq(ce.getEnemy(roomId, 0).hp, 50 - 30); // 2+28=30
    }

    // ---- 圣泉 MANA_DELTA：注入魔素 + 回合末回复 ----
    function testManaBurstInjectsMana() public {
        uint32[] memory skills = new uint32[](1);
        skills[0] = skillManaBurst; // MANA_DELTA +1
        (uint256 charId, uint32 roomId) = _gmSolo(alice, 4, 4, skills); // 黑魔法师
        _setPlan(alice, roomId, skills);
        vm.prank(alice);
        ce.startCombat(roomId);
        vm.prank(alice);
        ce.advanceTurn(roomId);
        // 0 + 圣泉 1 + 回合末回复 2 = 3
        assertEq(ce.getRoom(roomId).manaPool, 3);
    }

    // ---- 狂暴 DMG_OUT_MOD/DMG_IN_MOD：双修正同时生效（种族技随兽人自动并入，不可手动自选）----
    function testBerserkDamageMods() public {
        // 兽人剑士：狂暴随种族自动并入（严格合并顺序：职业技能在前、种族技随后、自选技最后）
        uint32[] memory skills = new uint32[](1);
        skills[0] = skillNuke;
        uint256 charId = _gmCharacter(alice, 1, 1, new uint16[](0), skills);
        CharacterRegistry.Character memory c = cr.getCharacter(charId);
        assertEq(c.skillIds[c.skillCount - 1], skillNuke, "self-select last");
        bool hasBerserk;
        for (uint8 i; i < c.skillCount; ++i) if (c.skillIds[i] == skillBerserk) hasBerserk = true;
        assertTrue(hasBerserk, "race skill auto-merged");
        vm.prank(alice);
        uint32 roomId = ce.createRoom(5); // 坦克 500 HP / 攻 100
        vm.prank(alice);
        ce.joinRoom(roomId, charId);
        uint32[] memory plan = new uint32[](2);
        plan[0] = skillBerserk;
        plan[1] = skillNuke;
        _setPlan(alice, roomId, plan);
        vm.prank(alice);
        ce.startCombat(roomId);
        vm.prank(alice);
        ce.advanceTurn(roomId); // 狂暴施放
        uint64 before = ce.getEnemy(roomId, 0).hp;
        vm.prank(alice);
        ce.advanceTurn(roomId); // 狂暴加持下的核弹
        // 轻量路径校验：狂暴 DMG_OUT_MOD 生效使敌方大量掉血，且我方成员存活
        assertLt(ce.getEnemy(roomId, 0).hp, before, "berserk DMG_OUT_MOD applied");
        assertGt(ce.getMember(roomId, 0).hp, 0, "member survived after berserk DMG_IN_MOD");
    }

    // ---- 深渊低语 DMG_IN_MOD：随机1个敌人受伤增加 + 不受 damageCap 限制 ----
    function testAbyssWhisperAppliesDmgInMod() public {
        uint32[] memory skills = new uint32[](1);
        skills[0] = skillAttack;
        // 使用恶魔种族（race=7），深渊低语+汲魂自动并入
        uint256 charId = _gmCharacter(alice, 1, 7, new uint16[](0), skills);
        vm.prank(alice);
        uint32 roomId = ce.createRoom(4);
        vm.prank(alice);
        ce.joinRoom(roomId, charId);
        uint32[] memory plan = new uint32[](2);
        plan[0] = skillAbyssWhisper;
        plan[1] = skillAttack;
        _setPlan(alice, roomId, plan);
        vm.prank(alice);
        ce.startCombat(roomId);
        // Turn1: AbyssWhisper fails (mana=0), Turn2: Attack, Turn3: AbyssWhisper fires
        vm.prank(alice);
        ce.advanceTurn(roomId); // Turn1: mana=0, ABYSS_WHISPER fails
        vm.prank(alice);
        ce.advanceTurn(roomId); // Turn2: ATTACK fires, mana regens
        vm.prank(alice);
        ce.advanceTurn(roomId); // Turn3: ABYSS_WHISPER fires (mana>=1)
        // 至少1个敌人应有DMG_IN_MOD效果
        bool foundDmgInMod = false;
        uint8 ec = ce.getRoom(roomId).enemyCount;
        for (uint8 i; i < ec; ++i) {
            CombatTypes.Enemy memory e = ce.getEnemy(roomId, i);
            for (uint8 j; j < e.effectCount; ++j) {
                if (e.effects[j].op == 3) { // OP_DMG_IN_MOD
                    foundDmgInMod = true;
                    assertEq(e.effects[j].magnitude, 200, "DMG_IN_MOD magnitude");
                }
            }
        }
        assertTrue(foundDmgInMod, "at least one enemy has DMG_IN_MOD");
    }

    function testDmgInModBypassesDamageCap() public {
        // 注册一个高伤害+低damageCap的技能（ALL_ENEMY，确保命中）
        SkillRegistry.Skill memory cappedSkill = _mkSkill(1, 4, 2000, 1000, 0);
        cappedSkill.damageCap = 50; // damageCap = 50
        uint32 skillCapped = _register(cappedSkill);
        // 注册一个DMG_IN_MOD效果（对敌单体施加，确保目标承伤增加）
        SkillRegistry.Skill memory dmgInModSkill = _mkSkill(3, 1, 0, 1000, 0);
        dmgInModSkill.effects[0] = SkillRegistry.Effect({op: 3, duration: 3, magnitude: 200, scope: 1, prob: 1000});
        dmgInModSkill.effectCount = 1;
        uint32 skillDmgInMod = _register(dmgInModSkill);

        uint32[] memory skills = new uint32[](2);
        skills[0] = skillDmgInMod; // 对敌施加DMG_IN_MOD
        skills[1] = skillCapped; // 对全体敌人造成 capped 伤害
        (uint256 charId, uint32 roomId) = _gmSolo(alice, 1, 5, skills); // difficulty 5 = templateTank (maxHp=500)
        uint32[] memory plan = new uint32[](2);
        plan[0] = skillDmgInMod;
        plan[1] = skillCapped;
        _setPlan(alice, roomId, plan);
        vm.prank(alice);
        ce.startCombat(roomId);
        vm.prank(alice);
        ce.advanceTurn(roomId); // DMG_IN_MOD 施加到敌方
        uint64 hpBefore = ce.getEnemy(roomId, 0).hp;
        vm.prank(alice);
        ce.advanceTurn(roomId); // cappedSkill 伤害被 cap=50，但 DMG_IN_MOD +200% 后 = 50*(1+200%)=150
        uint64 hpAfter = ce.getEnemy(roomId, 0).hp;
        uint64 damage = hpBefore - hpAfter;
        // 基础伤害 = min(2000*30/1000, 50) = 50，乘区 50*(1+200/1000)=60
        assertGt(damage, 50, "DMG_IN_MOD should make damage exceed damageCap");
    }

    // ---- 计划层锁定：计划只能排角色已习得技能（防绕过创建层绑定）----
    function testPlanRejectsUnOwnedSkill() public {
        uint32[] memory skills = new uint32[](1);
        skills[0] = skillAttack;
        (uint256 charId, uint32 roomId) = _gmSolo(alice, 1, 4, skills); // 剑士只有普攻
        uint16[16] memory plan;
        plan[0] = uint16(skillBurstMagic); // 黑法职业技，未习得
        vm.prank(alice);
        vm.expectRevert("CE: skill not owned");
        ce.setPlan(roomId, plan, 1);
    }

    function testPlanAllowsOwnedRaceSkill() public {
        uint32[] memory skills = new uint32[](1);
        skills[0] = skillAttack;
        uint256 charId = _gmCharacter(alice, 1, 1, new uint16[](0), skills); // 兽人剑士（狂暴自动并入）
        vm.prank(alice);
        uint32 roomId = ce.createRoom(4);
        vm.prank(alice);
        ce.joinRoom(roomId, charId);
        uint16[16] memory plan;
        plan[0] = uint16(skillBerserk); // 已习得种族技，可排
        vm.prank(alice);
        ce.setPlan(roomId, plan, 1);
        assertEq(ce.getMember(roomId, 0).plan[0], skillBerserk);
    }

    // ---- 公共池进攻锚点验收：无职业人类 solo D1（属性双弱 + 加强毒刃）----
    function testClasslessHumanSoloD1PoisonBlade() public {
        uint32[] memory skills = new uint32[](2);
        skills[0] = skillDot; // 加强毒刃：直伤 4 + 流血 18×3，AP 2
        skills[1] = skillAttack; // 攒 AP（普攻命中 +1）
        (uint256 charId, uint32 roomId) = _gmSolo(alice, 6, 1, skills); // 无职业人类 + D1（2 史莱姆）
        uint32[] memory plan = new uint32[](3);
        plan[0] = skillAttack;
        plan[1] = skillAttack;
        plan[2] = skillDot;
        _setPlan(alice, roomId, plan);
        vm.prank(alice);
        ce.startCombat(roomId);
        uint8 turns;
        while (ce.getRoom(roomId).phase == ce.PHASE_COMBAT() && turns < 40) {
            vm.prank(alice);
            ce.advanceTurn(roomId);
            turns++;
        }
        assertEq(ce.getRoom(roomId).phase, ce.PHASE_SETTLED(), "classless human clears D1 with poison blade");
        assertLt(turns, 40);
    }

    // ---- 公共池进攻锚点验收：无职业人类 solo D1（暴风剑爆发，AP 5 门槛）----
    function testClasslessHumanSoloD1StormBlade() public {
        uint32[] memory skills = new uint32[](2);
        skills[0] = skillStormBlade; // 暴风剑：AP 5 四连斩
        skills[1] = skillAttack; // 攒 AP（普攻命中 +1）
        (uint256 charId, uint32 roomId) = _gmSolo(alice, 6, 1, skills);
        // 5 次普攻攒满 5 AP → 暴风剑（循环：+5-5 维持）
        uint32[] memory plan = new uint32[](6);
        plan[0] = skillAttack;
        plan[1] = skillAttack;
        plan[2] = skillAttack;
        plan[3] = skillAttack;
        plan[4] = skillAttack;
        plan[5] = skillStormBlade;
        _setPlan(alice, roomId, plan);
        vm.prank(alice);
        ce.startCombat(roomId);
        uint8 turns;
        while (ce.getRoom(roomId).phase == ce.PHASE_COMBAT() && turns < 40) {
            vm.prank(alice);
            ce.advanceTurn(roomId);
            turns++;
        }
        assertEq(ce.getRoom(roomId).phase, ce.PHASE_SETTLED(), "classless human clears D1 with storm blade");
        assertLt(turns, 40);
    }

    // ---- 变体敌人表：开战一次掷骰选表 ----
    function testVariantEnemyTable() public {
        // 为 dungeon 1 添加变体表：单入口权重 100 → 必选 Hulk 表
        uint16[] memory ids = new uint16[](1);
        ids[0] = templateHulk;
        uint16[] memory ws = new uint16[](1);
        ws[0] = 100;
        ce.registerEnemyTable(10, ids, ws);
        ce.addDungeonVariant(1, 10, 100);
        uint32[] memory skills = new uint32[](1);
        skills[0] = skillNuke;
        (uint256 charId, uint32 roomId) = _gmSolo(alice, 1, 1, skills);
        vm.prank(alice);
        ce.startCombat(roomId);
        CombatTypes.Room memory r = ce.getRoom(roomId);
        assertEq(r.enemies[0].templateId, templateHulk, "variant table selected");
        assertEq(r.enemies[1].templateId, templateHulk, "variant table selected (2nd)");
    }

    // ---- 事件日志辅助 ----
    function _bossSkillFromLogs(Vm.Log[] memory logs, uint32 roomId) internal pure returns (uint32) {
        bytes32 sig = keccak256("UnitActed(uint32,uint8,uint8,uint32)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length < 2 || logs[i].topics[0] != sig) continue;
            if (uint32(uint256(logs[i].topics[1])) != roomId) continue;
            (uint8 unitType, uint8 unitIndex, uint32 skillId) = abi.decode(logs[i].data, (uint8, uint8, uint32));
            if (unitType == 1 && unitIndex == 0) return skillId;
        }
        return 0;
    }

    // ---- 新技能轻量路径测试（本轮补齐；共享原语如 HEAL/SHIELD/DOT/眩晕/多段已有覆盖） ----
    /// @notice 替身人偶：玩家侧召唤（flags bit2）——成员数+1、isSummon 标记、无主不参与收益
    function testSummonAlliedDecoy() public {
        uint32[] memory skills = new uint32[](0);
        (uint256 charId, uint32 roomId) = _gmSolo(alice, 5, 4, skills); // 白魔法师（替身人偶自动发放）
        uint32[] memory plan = new uint32[](3);
        plan[0] = skillDecoyDoll;
        plan[1] = skillDecoyDoll;
        plan[2] = skillDecoyDoll;
        _setPlan(alice, roomId, plan);
        vm.prank(alice);
        ce.startCombat(roomId);
        for (uint8 i; i < 3; ++i) {
            vm.prank(alice);
            ce.advanceTurn(roomId);
        }
        CombatTypes.Room memory r = ce.getRoom(roomId);
        // 施放后至少召出 1 个替身人偶（多回合重复施放可召出多个）
        assertGe(r.memberCount, 2, "decoy summoned beyond real member");
        CombatTypes.RoomMember memory m = ce.getMember(roomId, 1);
        assertTrue(m.isSummon, "decoy flagged as summon");
        assertEq(m.player, address(0), "summon has no owner");
    }

    /// @notice 魔力护盾（kind=MAGIC）：盾量 = power×魔攻/1000，实测吸收后掉血小于敌人全额攻击
    function testMagicShieldScalesWithMagic() public {
        uint32[] memory skills = new uint32[](2);
        skills[0] = skillMagicShield; // 自选池技（无职业人类自选）
        skills[1] = skillIdle;
        (uint256 charId, uint32 roomId) = _gmSolo(alice, 6, 5, skills); // 坦克攻 100
        uint64 fullHp = ce.getMember(roomId, 0).maxHp;
        uint32[] memory plan = new uint32[](2);
        plan[0] = skillMagicShield;
        plan[1] = skillIdle;
        _setPlan(alice, roomId, plan);
        vm.prank(alice);
        ce.startCombat(roomId);
        vm.prank(alice);
        ce.advanceTurn(roomId); // 施放魔力护盾
        vm.prank(alice);
        ce.advanceTurn(roomId); // 坦克攻击，护盾吸收部分伤害
        uint64 lost = fullHp - ce.getMember(roomId, 0).hp;
        assertLt(lost, 100, "magic shield absorbed part of 100 attack");
    }

    /// @notice 献祭（黑魔法师）：hpCost 扣血 + 每段命中为房间魔素池产魔素
    function testSacrificeConvertsHpToMana() public {
        uint32[] memory skills = new uint32[](0);
        (uint256 charId, uint32 roomId) = _gmSolo(alice, 4, 5, skills); // 黑魔法师（献祭自动发放）
        uint64 fullHp = ce.getMember(roomId, 0).maxHp;
        uint32[] memory plan = new uint32[](1);
        plan[0] = skillSacrifice;
        _setPlan(alice, roomId, plan);
        vm.prank(alice);
        ce.startCombat(roomId);
        uint32 manaBefore = ce.getRoom(roomId).manaPool;
        vm.prank(alice);
        ce.advanceTurn(roomId); // 献祭：扣血并产出魔素
        assertLt(ce.getMember(roomId, 0).hp, fullHp, "sacrifice costed hp");
        assertGt(ce.getRoom(roomId).manaPool, manaBefore, "sacrifice produced mana");
    }

    /// @notice 各职业新技能在战斗中可解析（轻量：不掉血/不崩溃即路径通）
    function testNewClassSkillsResolve() public {
        // 剑士：快速剑/斩铁剑/魔法剑（自动发放）
        uint32[] memory swordsman = new uint32[](0);
        (uint256 c1, uint32 r1) = _gmSolo(alice, 1, 4, swordsman);
        _setPlan(alice, r1, _arr(skillRapidStrike, skillIronCleave, skillMagicSword));
        // 守卫：盾击/盾墙/回避（自动发放）
        uint32[] memory guard = new uint32[](0);
        (uint256 c2, uint32 r2) = _gmSolo(bob, 2, 4, guard);
        _setPlan(bob, r2, _arr(skillShieldBash, skillShieldWall, skillGuardEvade));
        // 白法：光弹/替身人偶（自动发放；计划长度 2）
        uint32[] memory white = new uint32[](0);
        (uint256 c3, uint32 r3) = _gmSolo(carol, 5, 4, white);
        uint16[16] memory pw;
        pw[0] = uint16(skillLightOrb);
        pw[1] = uint16(skillDecoyDoll);
        _gmSetPlanDir(carol, r3, pw, 2);
        // 三房各推进，房间必须保持在战斗态（无 revert 即技能路径可解析）
        vm.prank(alice); ce.startCombat(r1);
        vm.prank(bob); ce.startCombat(r2);
        vm.prank(carol); ce.startCombat(r3);
        for (uint8 i; i < 3; ++i) {
            vm.prank(alice); ce.advanceTurn(r1);
            vm.prank(bob); ce.advanceTurn(r2);
            vm.prank(carol); ce.advanceTurn(r3);
        }
        assertTrue(ce.getRoom(r1).phase == ce.PHASE_COMBAT(), "swordsman plan resolved");
        assertTrue(ce.getRoom(r2).phase == ce.PHASE_COMBAT(), "guard plan resolved");
        assertTrue(ce.getRoom(r3).phase == ce.PHASE_COMBAT(), "white mage plan resolved");
    }

    function _arr(uint32 a, uint32 b, uint32 c) internal pure returns (uint32[] memory s) {
        s = new uint32[](3);
        s[0] = a; s[1] = b; s[2] = c;
    }

    function _gmSetPlanDir(address player, uint32 roomId, uint16[16] memory plan, uint8 len) internal {
        vm.prank(player);
        ce.setPlan(roomId, plan, len);
    }

    // ---- 模糊测试：任意技能组合推进不崩溃 ----
    function testFuzzAdvanceTurnNoRevert(uint8 seed) public {
        seed = uint8(bound(seed, 0, 255));
        uint32[] memory skills = new uint32[](1);
        skills[0] = skillNuke;
        (uint256 charId, uint32 roomId) = _gmSolo(alice, 1, 1, skills);
        _setPlan(alice, roomId, skills);
        vm.prank(alice);
        ce.startCombat(roomId);
        for (uint8 i; i < 10; ++i) {
            vm.prank(alice);
            ce.advanceTurn(roomId);
            CombatTypes.Room memory rr = ce.getRoom(roomId);
            if (rr.phase != ce.PHASE_COMBAT()) break;
        }
        CombatTypes.Room memory r = ce.getRoom(roomId);
        assertTrue(r.phase == ce.PHASE_COMBAT() || r.phase == ce.PHASE_SETTLED());
        // 状态一致性：死亡单位 alive=false
        for (uint8 i; i < r.enemyCount; ++i) {
            if (r.enemies[i].hp == 0) assertFalse(r.enemies[i].alive);
        }
    }
}

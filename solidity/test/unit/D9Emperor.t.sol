// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../BaseTest.sol";
import {SkillRegistry} from "../../src/core/SkillRegistry.sol";
import {CombatTypes} from "../../src/libs/CombatTypes.sol";
import {CharacterRegistry} from "../../src/core/CharacterRegistry.sol";

/// @notice 本地接口按 selector 匹配调用又老又新的 prevrandao cheatcode（EIP-4399）
interface IPrevrandao {
    function prevrandao(bytes32 newPrevrandao) external;
}

/// @title D9EmperorTest - 机神帝座（D9）怪物技能行为测试
/// @notice 用「探针地下城」（难度 7，仅 1 场战斗）把 D9 已注册的炉/皇帝/宝箱模板单独抛出，
///         验证行动效果符合 content-design.md §8.2：魔素双向操纵、召唤、火花炮/幻光轮/威压、
///         以及炉毁/宝箱毁后的机神皇帝召唤概率分支。数值层未定档，只做定性 + 确定性账目断言。
contract D9EmperorTest is BaseTest {
    uint32 skillTestNuke; // 测试用单体高伤（物理，功率 3000：剑士 300 级 ≈ 2.7 万/击，可速拆炉/宝箱/皇帝）

    // ---- 探针地下城（难度 7）：单场战斗，队长或任意成员清场即结算 ----
    // 701 炉 / 702 皇帝 / 703 宝箱 / 704 士兵（均复用 BaseTest._seedD9 已注册的真实模板）
    function setUp() public override {
        super.setUp();
        _registerProbe();
    }

    function _registerProbe() internal {
        skillTestNuke = _registerNuke(3000);
        _probeTable(701, templateFurnace);
        _probeTable(702, templateEmperor);
        _probeTable(703, templateChest);
        _probeTable(704, templateSoldier);
    }

    function _registerNuke(uint64 power) internal returns (uint32 id) {
        SkillRegistry.Skill memory s = SkillRegistry.Skill({
            id: 0, kind: 1, apCost: 0, apGain: 1, ammoId: 0, ammoCost: 0, manaCost: 0, hpCost: 0,
            targeting: 1, weightMode: 0, targetCount: 0, power: power, damageCap: 0, baseAcc: 1000, flags: 0,
            effects: [_emptyE(), _emptyE(), _emptyE(), _emptyE()], effectCount: 0,
            summon: SkillRegistry.SummonRule({templateId: 0, maxCount: 0, enemyHeadroom: 0})
        });
        id = sr.registerSkill(s);
    }

    function _emptyE() internal pure returns (SkillRegistry.Effect memory e) {
        return SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000});
    }

    function _probeTable(uint16 tableId, uint16 templateId) internal {
        uint16[] memory ids = new uint16[](1); ids[0] = templateId;
        uint16[] memory ws = new uint16[](1); ws[0] = 100;
        ce.registerEnemyTable(tableId, ids, ws);
    }

    function _setProbe(uint16 tableId) internal {
        ce.setDungeon(7, CombatTypes.DungeonConfig({
            tableId: tableId, enemyCount: 1, manaPerTurn: 6, rewardBase: 0, entryFee: 0, rescueFee: 0, turnInterval: 0, battles: 1
        }));
    }

    function _planOf(uint32[] memory skills) internal pure returns (uint16[16] memory p) {
        for (uint256 i; i < skills.length; ++i) p[i] = uint16(skills[i]);
    }

    function _setPlan(address who, uint32 roomId, uint32[] memory skills) internal {
        vm.prank(who);
        ce.setPlan(roomId, _planOf(skills), uint8(skills.length));
    }

    /// @notice 造角色并开房（探针难度 7），队长入房、设计划、开战；返回 roomId
    function _openSolo(address who, uint256 cid, uint32[] memory skills) internal returns (uint32 roomId) {
        vm.prank(who);
        roomId = ce.createRoom(7);
        vm.prank(who);
        ce.joinRoom(roomId, cid);
        _setPlan(who, roomId, skills);
        vm.prank(who);
        ce.startCombat(roomId);
    }

    function _openDuo(address who1, uint256 c1, address who2, uint256 c2) internal returns (uint32 roomId) {
        vm.prank(who1);
        roomId = ce.createRoom(7);
        vm.prank(who1);
        ce.joinRoom(roomId, c1);
        vm.prank(who2);
        ce.joinRoom(roomId, c2);
        _setPlan(who1, roomId, _single(skillAttack));
        _setPlan(who2, roomId, _single(skillAttack));
        vm.prank(who1);
        ce.startCombat(roomId);
    }

    function _single(uint32 skillId) internal pure returns (uint32[] memory s) {
        s = new uint32[](1);
        s[0] = skillId;
    }

    function _driveTurns(uint32 roomId, uint16 n) internal {
        for (uint16 i; i < n; ++i) ce.advanceTurn(roomId);
    }

    function _settle(uint32 roomId) internal {
        uint16 g = 0;
        while (ce.getRoom(roomId).phase != ce.PHASE_SETTLED() && g < 40) {
            ce.advanceTurn(roomId);
            g++;
        }
        assertEq(uint8(ce.getRoom(roomId).phase), uint8(ce.PHASE_SETTLED()), "should settle");
    }

    /// @notice 任意效用扫描：成员为单位 unitIdx 是否存在 op 效果
    function _memberHasEffect(uint32 roomId, uint8 idx, uint8 op) internal view returns (bool) {
        uint8 n = ce.getMember(roomId, idx).effectCount;
        for (uint8 i; i < n; ++i) if (ce.getMember(roomId, idx).effects[i].op == op) return true;
        return false;
    }

    // =====================================================================
    // ① 机神魔素炉：泄漏(+100) / 虹吸(-80) / 召唤(士兵)
    // =====================================================================
    // 炉 AI = [leak, siphon, summon, leak, siphon]；慢速(5) → 每回合先手。
    // 双人房间使 p(2)>e(1) → 召唤(敌人)有空位刷新 1 名士兵。
    function test_Furnace_LeakSiphonSummon() public {
        _setProbe(701);
        // 普通双剑士（技能=普攻 900/刀，不拆炉），300 级 HP 3.6 万，抗住士兵挠痒
        IPrevrandao(address(vm)).prevrandao(bytes32(uint256(0x99)));
        uint256 c1 = cr.gmMintCharacterAtLevel(alice, 1, 0, new uint16[](0), _single(skillAttack), 300);
        uint256 c2 = cr.gmMintCharacterAtLevel(bob, 1, 0, new uint16[](0), _single(skillAttack), 300);
        uint32 roomId = _openDuo(alice, c1, bob, c2);
        ce.advanceTurn(roomId); // t1：炉先手 leak +100，回魔 +6 → 106
        assertGt(ce.getRoom(roomId).manaPool, 0, "leak adds mana");
        uint32 p1 = ce.getRoom(roomId).manaPool;
        ce.advanceTurn(roomId); // t2：siphon -80 → 明显回落
        uint32 p2 = ce.getRoom(roomId).manaPool;
        assertTrue(p2 < p1, "siphon cuts mana");
        ce.advanceTurn(roomId); // t3：summon → 士兵入场
        assertGt(ce.getRoom(roomId).enemyCount, 1, "summon spawns soldier");
        assertEq(ce.getEnemy(roomId, 1).templateId, templateSoldier, "summoned template = soldier");
    }

    // =====================================================================
    // ② 机神皇帝完整 AI 循环（确定账目）
    //    [wheel(耗12)→cannon(耗40)→pressure(耗2)→summon(耗0)→leak(+100)→cannon]
    // =====================================================================
    function test_Emperor_SkillCycleMana() public {
        _setProbe(702);
        // 坦克剑卫：守卫×巨人 + 双血词条 ×300，HP≈16.95 万，能扛住火花炮(5.1万)+幻光轮(≤8万)
        uint16[] memory aff = new uint16[](2); aff[0] = 1; aff[1] = 1;
        uint256 tank = cr.gmMintCharacterAtLevel(alice, 2, 2, aff, _single(skillAttack), 300);
        (uint64 tpH,,,,) = cr.getStats(tank);
        assertGt(tpH, 140_000, "tank hp enough");

        IPrevrandao(address(vm)).prevrandao(bytes32(uint256(0x77)));
        uint32 roomId = _openSolo(alice, tank, _single(skillAttack));
        assertEq(ce.getRoom(roomId).manaPool, 0, "start mana 0");

        ce.advanceTurn(roomId); // t1 wheel 耗12，魔素不足 → 哑火，仅回魔 → 6
        assertEq(ce.getRoom(roomId).manaPool, 6, "wheel short on mana (t1)");
        ce.advanceTurn(roomId); // t2 cannon 耗40，仍不足 → 哑火 → 12
        assertEq(ce.getRoom(roomId).manaPool, 12, "cannon short on mana (t2)");
        ce.advanceTurn(roomId); // t3 pressure 耗2 → 释放，全体降命中 + 概率眩晕 → 16
        assertEq(ce.getRoom(roomId).manaPool, 16, "pressure cast (t3)");
        assertTrue(_memberHasEffect(roomId, 0, ce.OP_ACC_DOWN()), "pressure ACC_DOWN applied");
        ce.advanceTurn(roomId); // t4 summon 耗0 → 1v1 无刷新空位，不召唤 → 22
        assertEq(ce.getRoom(roomId).manaPool, 22, "summon cost 0 (t4)");
        ce.advanceTurn(roomId); // t5 leak +100 → 128
        assertEq(ce.getRoom(roomId).manaPool, 128, "leak adds 100 (t5)");
        ce.advanceTurn(roomId); // t6 cannon 耗40 → 火！→ 128-40+6 = 94
        assertEq(ce.getRoom(roomId).manaPool, 94, "cannon fired, -40 (t6)");
        ce.advanceTurn(roomId); // t7 wheel 耗12 → 火！→ 94-12+6 = 88
        assertEq(ce.getRoom(roomId).manaPool, 88, "wheel fired, -12 (t7)");
    }

    // 皇帝亦能召唤：入房人数(2) > 存活敌人(1) → summon 有空位 → 士兵入场
    function test_Emperor_Summon_SpawnsSoldier() public {
        _setProbe(702);
        uint16[] memory aff = new uint16[](2); aff[0] = 1; aff[1] = 1;
        uint256 t1 = cr.gmMintCharacterAtLevel(alice, 2, 2, aff, _single(skillAttack), 300);
        uint256 t2 = cr.gmMintCharacterAtLevel(bob, 2, 2, aff, _single(skillAttack), 300);
        IPrevrandao(address(vm)).prevrandao(bytes32(uint256(0x55)));
        uint32 roomId = _openDuo(alice, t1, bob, t2);
        // t1..t3：(wheel/cannon 哑火) + pressure(无伤)；双人 p=2 使 t4 summon 有空位
        _driveTurns(roomId, 4);
        assertGt(ce.getRoom(roomId).enemyCount, 1, "emperor summon spawns");
        bool found;
        for (uint8 i; i < ce.getRoom(roomId).enemyCount; ++i) {
            if (ce.getEnemy(roomId, i).templateId == templateSoldier) { found = true; break; }
        }
        assertTrue(found, "emperor summoned soldier");
    }

    // =====================================================================
    // ③ 炉毁 60% 召唤机神皇帝（同场不间断再战）/ 不触发则本场直接清场
    // =====================================================================
    function test_Furnace_DestroySpawn_BothBranchesReachable() public {
        _setProbe(701); // 模板 templateFurnace：onDeathSpawn.prob = 600‰
        uint256 nuker = cr.gmMintCharacterAtLevel(alice, 1, 0, new uint16[](0), _single(skillTestNuke), 300);
        uint16 spawned = 0;
        uint16 cleared = 0;
        for (uint i; i < 40; ++i) {
            IPrevrandao(address(vm)).prevrandao(bytes32(uint256(i + 1)));
            uint32 roomId = _openSolo(alice, nuker, _single(skillTestNuke));
            assertEq(ce.getRoom(roomId).enemyCount, 1, "one furnace");
            ce.advanceTurn(roomId); // t1 速拆炉 → 死亡调用掷骰
            if (ce.getRoom(roomId).bossSpawned) spawned++; else cleared++;
            _settle(roomId);
        }
        assertTrue(spawned > 0 && cleared > 0, "furnace 60%: emperor-spawn AND direct-clear both reachable");
    }

    // =====================================================================
    // ④ 王座宝箱：HP1、无攻击，被毁后 20% 召唤皇帝 / 否则直接胜利
    // =====================================================================
    function test_Chest_Destroy_SpawnOrVictory_BothBranchesReachable() public {
        _setProbe(703); // 模板 templateChest：HP=1，onDeathSpawn.prob = 200‰
        uint256 nuker = cr.gmMintCharacterAtLevel(alice, 1, 0, new uint16[](0), _single(skillTestNuke), 300);
        uint16 spawned = 0;
        uint16 victory = 0;
        for (uint i; i < 40; ++i) {
            IPrevrandao(address(vm)).prevrandao(bytes32(uint256(i + 1000)));
            uint32 roomId = _openSolo(alice, nuker, _single(skillTestNuke));
            assertEq(ce.getEnemy(roomId, 0).maxHp, 1, "chest hp 1");
            ce.advanceTurn(roomId); // t1 一击碎盒 → 死亡调用掷骰
            if (ce.getRoom(roomId).bossSpawned) spawned++; else victory++;
            _settle(roomId);
        }
        assertTrue(spawned > 0 && victory > 0, "chest 20%: emperor-spawn AND instant-victory both reachable");
    }
}
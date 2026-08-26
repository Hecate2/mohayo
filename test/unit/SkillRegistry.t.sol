// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../BaseTest.sol";
import {SkillRegistry} from "../../src/core/SkillRegistry.sol";

contract SkillRegistryTest is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    function testRegisterSkillAssignsId() public {
        assertEq(sr.skillCount(), 22); // 14 通用 + 1 职业技（鹰眼）+ 8 种族技
        assertTrue(skillAttack > 0);
        assertTrue(skillIdle > skillAttack);
    }

    function testGetSkillRoundTrip() public {
        SkillRegistry.Skill memory s = sr.getSkill(skillAttack);
        assertEq(s.id, skillAttack);
        assertEq(s.kind, 1);
        assertEq(s.power, 100);
        assertEq(s.targeting, 1);
    }

    function testEffectCountCap() public {
        SkillRegistry.Effect[4] memory effects;
        for (uint8 i; i < 4; ++i) {
            effects[i] = SkillRegistry.Effect({op: 1, duration: 1, magnitude: 1, scope: 0, prob: 1000});
        }
        SkillRegistry.Skill memory s = _baseSkill();
        s.effectCount = 5; // 超上限
        vm.expectRevert("SR: too many effects");
        sr.registerSkill(s);
    }

    function testTargetCountCap() public {
        SkillRegistry.Skill memory s = _baseSkill();
        s.targetCount = 9; // 超 8 上限
        vm.expectRevert("SR: targetCount cap");
        sr.registerSkill(s);
    }

    function testBaseAccCap() public {
        SkillRegistry.Skill memory s = _baseSkill();
        s.baseAcc = 1001;
        vm.expectRevert("SR: baseAcc cap");
        sr.registerSkill(s);
    }

    function testGuarNextClassOnly() public {
        // 通用注册路径拒绝 GUAR_NEXT（红线）
        SkillRegistry.Skill memory s = _baseSkill();
        s.effects[0] = SkillRegistry.Effect({op: 7, duration: 2, magnitude: 0, scope: 0, prob: 1000});
        s.effectCount = 1;
        vm.expectRevert("SR: guar_next class-only");
        sr.registerSkill(s);
        // 职业绑定路径允许
        uint32 id = sr.registerClassSkill(s, 2);
        assertTrue(sr.classSkill(2, id));
    }

    function testRegisterAIAndTemplate() public {
        assertTrue(aiSlime > 0);
        assertTrue(templateSlime > 0);
        SkillRegistry.EnemyTemplate memory t = sr.getTemplate(templateSlime);
        assertEq(t.maxHp, 50);
        assertEq(t.aiId, aiSlime);
    }

    function testRegisterTemplateUnknownAIRejected() public {
        SkillRegistry.EnemyTemplate memory t;
        t.aiId = 999;
        vm.expectRevert("SR: unknown ai");
        sr.registerTemplate(t);
    }

    function _baseSkill() internal pure returns (SkillRegistry.Skill memory s) {
        s.kind = 1;
        s.targeting = 1;
        s.weightMode = 0;
        s.baseAcc = 1000;
        s.power = 10;
        for (uint8 i; i < 4; ++i) {
            s.effects[i] = SkillRegistry.Effect({op: 0, duration: 0, magnitude: 0, scope: 0, prob: 1000});
        }
    }
}

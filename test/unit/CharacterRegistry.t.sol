// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../BaseTest.sol";
import {CharacterRegistry} from "../../src/core/CharacterRegistry.sol";

/// @title CharacterRegistryTest - 角色创建/种族词条随机/ERC-721 钩子/GM 入口
/// @notice 用 MockRNG.setFixed 强制特定掷骰结果，验证种族三层加权、词条方向分布、
///         资源流词条上限、种族/词条直接修正、转移锁定与等级重置、首角色重掷计数器。
contract CharacterRegistryTest is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    // ---- 基础创建 ----
    function testCreateCharacterBasic() public {
        uint32[] memory skills = new uint32[](0);
        vm.prank(alice);
        uint256 tokenId = cr.createCharacter(1, skills);
        assertEq(tokenId, 1);
        assertEq(cr.ownerOf(tokenId), alice);
        CharacterRegistry.Character memory c = cr.getCharacter(tokenId);
        assertEq(c.classId, 1);
        assertTrue(c.race < 8); // 种族必为合法值（8 种族）
        assertEq(c.level, 1);
        assertEq(c.affixCount, 2);
        assertEq(c.hp, c.maxHp);
        assertEq(cr.freeRerolls(alice), 3); // 首角色福利
    }

    function testCreateCharacterUnknownClassRejected() public {
        uint32[] memory skills = new uint32[](0);
        vm.prank(alice);
        vm.expectRevert("CR: unknown class");
        cr.createCharacter(99, skills);
    }

    function testCreateCharacterTooManySkillsRejected() public {
        uint32[] memory skills = new uint32[](9);
        for (uint8 i; i < 9; ++i) skills[i] = skillAttack;
        vm.prank(alice);
        vm.expectRevert("CR: too many skills");
        cr.createCharacter(1, skills);
    }

    // ---- 技能绑定强制：跨职业职业技 / 种族技不可自选 ----
    function testOwnClassSkillAllowed() public {
        uint32[] memory skills = new uint32[](1);
        skills[0] = skillMagicSword; // 剑士职业技
        uint256 tokenId = _createCharacter(alice, 1, skills); // 剑士自选本职业技
        assertEq(cr.getCharacter(tokenId).skillIds[0], skillMagicSword);
    }

    function testClassSkillLockedForOtherClass() public {
        uint32[] memory skills = new uint32[](1);
        skills[0] = skillMagicSword; // 剑士职业技
        vm.prank(alice);
        vm.expectRevert("CR: class skill locked");
        cr.createCharacter(3, skills); // 火枪手不可选
    }

    function testClassSkillLockedForClassless() public {
        uint32[] memory skills = new uint32[](1);
        skills[0] = skillBurstMagic; // 黑魔法师职业技
        vm.prank(alice);
        vm.expectRevert("CR: class skill locked");
        cr.createCharacter(6, skills); // 无职业不可选任何职业技
    }

    function testRaceSkillLocked() public {
        uint32[] memory skills = new uint32[](1);
        skills[0] = skillBerserk; // 兽人种族技
        vm.prank(alice);
        vm.expectRevert("CR: race skill locked");
        cr.createCharacter(1, skills); // 种族技一律不可手动自选（随种族自动并入）
    }

    function testRaceSkillAutoMergedStillWorks() public {
        // GM 铸造兽人剑士：狂暴自动并入，无需手动传入
        uint32[] memory skills = new uint32[](1);
        skills[0] = skillAttack;
        uint256 tokenId = cr.gmMintCharacter(alice, 1, 1, new uint16[](0), skills); // race 1 = 兽人
        CharacterRegistry.Character memory c = cr.getCharacter(tokenId);
        assertEq(c.skillIds[0], skillAttack);
        assertEq(c.skillIds[1], skillBerserk);
        assertEq(c.skillCount, 2);
    }

    // ---- 种族三层加权（setFixed 强制各层）----
    function testRaceTier0Human() public {
        mockRng.setFixed(0); // 0 < 850 → tier0 → 人类
        uint256 tokenId = _createCharacter(alice, 1, new uint32[](0));
        assertEq(cr.getCharacter(tokenId).race, cr.RACE_HUMAN());
    }

    function testRaceTier1Elf() public {
        mockRng.setFixed(900); // 850 ≤ 900 < 970 → tier1；sub=0 < 50 → 精灵
        uint256 tokenId = _createCharacter(alice, 1, new uint32[](0));
        assertEq(cr.getCharacter(tokenId).race, cr.RACE_ELF());
    }

    function testRaceTier2Demon() public {
        mockRng.setFixed(990); // 990 ≥ 970 → tier2；sub=90 ≥ 50 → 恶魔
        uint256 tokenId = _createCharacter(alice, 1, new uint32[](0));
        assertEq(cr.getCharacter(tokenId).race, cr.RACE_DEMON());
    }

    // ---- 词条方向分布 ----
    function testAffixDirectionPositive() public {
        mockRng.setFixed(0); // 0 < 200 → 正面
        uint256 tokenId = _createCharacter(alice, 1, new uint32[](0));
        CharacterRegistry.Character memory c = cr.getCharacter(tokenId);
        assertEq(cr.getAffixTemplate(c.affixIds[0]).direction, cr.AFFIX_POSITIVE());
        assertEq(cr.getAffixTemplate(c.affixIds[1]).direction, cr.AFFIX_POSITIVE());
    }

    function testAffixDirectionDoubleEdged() public {
        mockRng.setFixed(680); // 200 ≤ 680 < 880 → 双刃
        uint256 tokenId = _createCharacter(alice, 1, new uint32[](0));
        CharacterRegistry.Character memory c = cr.getCharacter(tokenId);
        assertEq(cr.getAffixTemplate(c.affixIds[0]).direction, cr.AFFIX_DOUBLE_EDGED());
        assertEq(cr.getAffixTemplate(c.affixIds[1]).direction, cr.AFFIX_DOUBLE_EDGED());
    }

    function testAffixDirectionNegative() public {
        mockRng.setFixed(990); // 990 ≥ 880 → 负面
        uint256 tokenId = _createCharacter(alice, 1, new uint32[](0));
        CharacterRegistry.Character memory c = cr.getCharacter(tokenId);
        assertEq(cr.getAffixTemplate(c.affixIds[0]).direction, cr.AFFIX_NEGATIVE());
        assertEq(cr.getAffixTemplate(c.affixIds[1]).direction, cr.AFFIX_NEGATIVE());
    }

    // ---- 属性计算与直接修正（无封顶）----
    function testStatsNoCapHumanPositiveAffixes() public {
        mockRng.setFixed(0); // 人类 + 正面词条 1（攻击 +10%）
        uint256 tokenId = _createCharacter(alice, 1, new uint32[](0));
        (uint64 hp, uint64 maxHp, uint64 attack, uint64 magic, uint64 speed) = cr.getStats(tokenId);
        // 剑士 base：120/30/10/10；双词条攻击 +20% → 36（人类无修正、无封顶）
        assertEq(maxHp, 120);
        assertEq(attack, 36);
        assertEq(magic, 10);
        assertEq(speed, 10);
        assertEq(hp, maxHp);
    }

    function testStatsDemonDirectModifiers() public {
        // GM 铸造：恶魔（物攻+30%/魔攻-10%/敏捷+20%/生命-15%）+ 双刃词条 8（蛮力觉醒：攻击 +25% 魔攻 -15%）
        uint16[] memory affixes = new uint16[](1);
        affixes[0] = 8;
        uint32[] memory skills = new uint32[](0);
        uint256 tokenId = cr.gmMintCharacter(alice, 1, 7, affixes, skills);
        (,, uint64 attack,, uint64 speed) = cr.getStats(tokenId);
        // 攻击 = 30×(1+0.30+0.25) = 46；速度 = 10×(1+0.20) = 12（直接修正叠加，无封顶）
        assertEq(attack, 46);
        assertEq(speed, 12);
    }

    // ---- 资源流词条（默诵/好战本能）----
    function testResourceAffixManaDiscount() public {
        mockRng.setFixed(204); // 双刃方向；204 % 9 = 6 → 词条 12（默诵 manaDiscount=1）
        uint256 tokenId = _createCharacter(alice, 1, new uint32[](0));
        CharacterRegistry.Character memory c = cr.getCharacter(tokenId);
        assertEq(c.manaDiscount, 2); // 两槽都是词条 12 → 1+1
        assertEq(c.apBonus, 0);
    }

    function testResourceAffixApBonus() public {
        mockRng.setFixed(205); // 205 % 9 = 7 → 词条 13（好战本能 apBonus=1）
        uint256 tokenId = _createCharacter(alice, 1, new uint32[](0));
        CharacterRegistry.Character memory c = cr.getCharacter(tokenId);
        assertEq(c.apBonus, 2); // 两槽都是词条 13 → 1+1
        assertEq(c.manaDiscount, 0);
        assertEq(c.manaGainBonus, -2); // 好战本能池修正 -1 × 2
    }

    // ---- GM 入口 ----
    function testGmMintCharacter() public {
        uint16[] memory affixes = new uint16[](1);
        affixes[0] = 3;
        uint32[] memory skills = new uint32[](1);
        skills[0] = skillAttack;
        uint256 tokenId = cr.gmMintCharacter(bob, 1, 4, affixes, skills);
        CharacterRegistry.Character memory c = cr.getCharacter(tokenId);
        assertEq(cr.ownerOf(tokenId), bob);
        assertEq(c.classId, 1);
        assertEq(c.race, 4);
        assertEq(c.affixCount, 1);
        assertEq(c.affixIds[0], 3);
        assertEq(c.skillCount, 2); // 自选技 + 精灵种族技（暴风术）
        assertEq(c.skillIds[0], skillAttack);
        assertEq(c.skillIds[1], skillStorm);
        assertEq(cr.freeRerolls(bob), 0); // GM 铸造不触发首角色福利
    }

    function testGmDisabledReverts() public {
        CharacterRegistry crNoGm = new CharacterRegistry(rng, sr, false);
        uint16[] memory affixes = new uint16[](0);
        uint32[] memory skills = new uint32[](0);
        vm.expectRevert("CR: GM disabled");
        crNoGm.gmMintCharacter(alice, 1, 0, affixes, skills);
    }

    // ---- ERC-721 转移钩子 ----
    function testTransferChangesOwner() public {
        uint256 tokenId = _createCharacter(alice, 1, new uint32[](0));
        vm.prank(alice);
        cr.transferFrom(alice, bob, tokenId);
        assertEq(cr.ownerOf(tokenId), bob);
        assertEq(cr.getCharacter(tokenId).level, 1); // 等级重置
    }

    function testTransferLockedInRoom() public {
        uint256 tokenId = _createCharacter(alice, 1, new uint32[](0));
        vm.prank(address(ce));
        cr.setInRoom(tokenId, 7);
        vm.prank(alice);
        vm.expectRevert("CR: in room");
        cr.transferFrom(alice, bob, tokenId);
    }

    // ---- 首角色重掷计数器 ----
    function testRerollExhaustsFreeCount() public {
        uint256 tokenId = _createCharacter(alice, 1, new uint32[](0));
        assertEq(cr.freeRerolls(alice), 3);
        vm.prank(alice);
        cr.rerollCharacter(tokenId);
        assertEq(cr.freeRerolls(alice), 2);
        assertEq(cr.balanceOf(alice), 0); // 已销毁
        // 每次重掷需新 token（销毁后不可再掷）
        uint256 tokenId2 = _createCharacter(alice, 1, new uint32[](0));
        vm.prank(alice);
        cr.rerollCharacter(tokenId2);
        assertEq(cr.freeRerolls(alice), 1);
        uint256 tokenId3 = _createCharacter(alice, 1, new uint32[](0));
        vm.prank(alice);
        cr.rerollCharacter(tokenId3);
        assertEq(cr.freeRerolls(alice), 0);
    }

    /// @notice 生产语义（gmEnabled=false）：计数器耗尽后重掷必须回退
    function testRerollRevertsWhenGmDisabled() public {
        CharacterRegistry crProd = new CharacterRegistry(rng, sr, false);
        crProd.registerClass(1, cr.getClassDef(1));
        crProd.registerAffixTemplate(1, cr.getAffixTemplate(1)); // 正面词条（方向 0）
        mockRng.setFixed(0); // 人类 + 正面词条
        vm.prank(alice);
        uint256 tokenId = crProd.createCharacter(1, new uint32[](0));
        assertEq(crProd.freeRerolls(alice), 3);
        for (uint8 i; i < 3; ++i) {
            vm.prank(alice);
            crProd.rerollCharacter(tokenId);
            tokenId = _createOn(crProd, alice, 1);
        }
        vm.expectRevert("CR: no reroll");
        vm.prank(alice);
        crProd.rerollCharacter(tokenId);
    }

    function _createOn(CharacterRegistry reg, address player, uint8 classId) internal returns (uint256 tokenId) {
        vm.prank(player);
        tokenId = reg.createCharacter(classId, new uint32[](0));
    }

    // ---- 模糊测试：任意职业创建不变量 ----
    function testFuzzCreateCharacterInvariants(uint8 classId) public {
        classId = uint8(bound(classId, 1, 6));
        uint256 tokenId = _createCharacter(alice, classId, new uint32[](0));
        CharacterRegistry.Character memory c = cr.getCharacter(tokenId);
        assertTrue(c.race < 8);
        assertEq(c.affixCount, 2);
        assertEq(c.level, 1);
        assertLe(c.hp, c.maxHp);
        // 无封顶：直接修正叠加，仅保证非负（_calcStat 钳制）
        assertGe(c.attack, 0);
        assertGe(c.magic, 0);
        assertGe(c.speed, 0);
    }
}

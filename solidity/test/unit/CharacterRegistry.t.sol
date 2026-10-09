// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../BaseTest.sol";
import {CharacterRegistry} from "../../src/core/CharacterRegistry.sol";

/// @title CharacterRegistryTest - 角色创建/能力词条档位/资源词条数量与种类/GM 入口
/// @notice 用 MockRNG.setFixed 强制特定掷骰结果，验证四项能力独立十档加成、
///         资源词条先抽数量（0~4）再抽四种固定效果之一、转移锁定与等级重置、首角色重掷计数器。
contract CharacterRegistryTest is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    // ---- 基础创建 ----
    function testCreateCharacterBasic() public {
        mockRng.setSeed(42);
        uint32[] memory skills = new uint32[](0);
        vm.prank(alice);
        uint256 tokenId = cr.createCharacter(1, skills);
        assertEq(tokenId, 1);
        assertEq(cr.ownerOf(tokenId), alice);
        CharacterRegistry.Character memory c = cr.getCharacter(tokenId);
        assertEq(c.classId, 1);
        assertTrue(c.race < 8); // 种族必为合法值（8 种族）
        assertEq(c.level, 1);
        assertEq(c.resourceCount, _sumResourceFields(c)); // 资源字段总和 = 词条数量
        assertLe(c.resourceCount, cr.MAX_RESOURCE_AFFIX_PER_CHAR());
        for (uint8 i; i < 4; ++i) {
            assertGe(c.affixTiers[i], 1); // 四项能力必有档位（1~10）
            assertLe(c.affixTiers[i], cr.MAX_AFFIX_TIER());
            assertLe(c.abilityBonuses[i], cr.MAX_AFFIX_MOD());
        }
        assertEq(c.hp, c.maxHp);
        assertGt(c.maxHp, 0);
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

    // ---- 技能绑定强制：职业/种族技自动发放，跨职业/种族技不可自选 ----
    function testOwnClassSkillAutoGranted() public {
        mockRng.setSeed(7);
        uint256 tokenId = _createCharacter(alice, 1, new uint32[](0)); // 剑士
        CharacterRegistry.Character memory c = cr.getCharacter(tokenId);
        // 剑士职业技自动并入，无需手动传入
        assertTrue(_hasSkill(c, skillMagicSword), "magic sword auto-granted");
    }

    function _hasSkill(CharacterRegistry.Character memory c, uint32 sid) internal pure returns (bool) {
        for (uint8 i; i < c.skillCount; ++i) if (c.skillIds[i] == sid) return true;
        return false;
    }

    function testClassSkillLockedForOtherClass() public {
        uint32[] memory skills = new uint32[](1);
        skills[0] = skillMagicSword; // 剑士职业技
        vm.prank(alice);
        vm.expectRevert("CR: class skill auto");
        cr.createCharacter(3, skills); // 火枪手不可选
    }

    function testClassSkillLockedForClassless() public {
        uint32[] memory skills = new uint32[](1);
        skills[0] = skillBurstMagic; // 黑魔法师职业技
        vm.prank(alice);
        vm.expectRevert("CR: class skill auto");
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
        // GM 铸造兽人剑士：狂暴自动并入，无需手动传入；剑士职业技同样自动发放
        uint32[] memory skills = new uint32[](1);
        skills[0] = skillGuardEvade; // 守卫职业技（剑士不可自选 → 必须被拒）
        // gmMintCharacter 为 onlyOwner，测试合约即 owner，无需 prank
        vm.expectRevert("CR: class skill auto");
        cr.gmMintCharacter(alice, 1, 1, new uint16[](0), skills);
    }

    function testAutoGrantKeepsOrder() public {
        // GM 铸造兽人剑士（race 1 = 兽人），自选仅限公共技
        uint32[] memory skills = new uint32[](1);
        skills[0] = skillAttack; // 公共自选池技
        uint256 tokenId = cr.gmMintCharacter(alice, 1, 1, new uint16[](0), skills);
        CharacterRegistry.Character memory c = cr.getCharacter(tokenId);
        assertEq(c.skillCount, 5); // 剑士职业技 3（魔法剑/快速剑/斩铁剑）+ 兽人技 1 + 自选 1
        assertTrue(_hasSkill(c, skillMagicSword), "auto class magic sword");
        assertTrue(_hasSkill(c, skillBerserk), "auto race berserk");
        assertTrue(_hasSkill(c, skillAttack), "self-select attack");
        assertTrue(!_hasSkill(c, skillGuardEvade), "no foreign class skill");
    }

    // ---- 种族三层加权（setFixed 强制各层）----
    function testRaceTier0Human() public {
        mockRng.setFixed(0); // 0 < 850 → tier0 → 人类
        uint256 tokenId = _createCharacter(alice, 1, new uint32[](0));
        assertEq(cr.getCharacter(tokenId).race, cr.RACE_HUMAN());
    }

    function testRaceTier1Elf() public {
        mockRng.setFixed(900); // 900 ∈ [850, 970) → tier1；sub=0 < 50 → 精灵
        uint256 tokenId = _createCharacter(alice, 1, new uint32[](0));
        assertEq(cr.getCharacter(tokenId).race, cr.RACE_ELF());
    }

    function testRaceTier2Demon() public {
        mockRng.setFixed(990); // 990 ≥ 970 → tier2；sub=90 ≥ 50 → 恶魔
        uint256 tokenId = _createCharacter(alice, 1, new uint32[](0));
        assertEq(cr.getCharacter(tokenId).race, cr.RACE_DEMON());
    }

    // ---- 能力词条：四项独立十档，加成已生效 ----
    /// setFixed(999999) 时每次掷骰都返回 999999：
    /// 种族 999999%1000=999 → tier2、sub%100=99 → 恶魔；能力档位 %1000=999 → 第 10 档；
    /// 资源数量 %5=4 → 4 条；资源种类 %4=3 → 全部为魔素产量 +1。
    function testAbilityBonusesAppliedAtTopTier() public {
        mockRng.setFixed(999999);
        uint256 tokenId = _createCharacter(alice, 1, new uint32[](0)); // 恶魔剑士
        CharacterRegistry.Character memory c = cr.getCharacter(tokenId);
        (uint64 hp, uint64 maxHp, uint64 attack, uint64 magic, uint64 speed) = cr.getStats(tokenId);

        assertEq(c.affixTiers[0], 10);
        assertEq(c.affixTiers[1], 10);
        assertEq(c.affixTiers[2], 10);
        assertEq(c.affixTiers[3], 10);
        assertEq(c.abilityBonuses[cr.ABILITY_HP()], 2000);
        assertEq(c.abilityBonuses[cr.ABILITY_ATTACK()], 2000);
        assertEq(c.abilityBonuses[cr.ABILITY_MAGIC()], 2000);
        assertEq(c.abilityBonuses[cr.ABILITY_SPEED()], 2000);

        // 线性相加（千分比）：hp 100×(1000+200-150+2000)/1000=305、攻 10×(1000+2000+300+2000)/1000=53
        assertEq(maxHp, 305);
        assertEq(hp, maxHp);
        assertEq(attack, 53);
        // 魔 10×(1000-100+2000)/1000=29、速 10×(1000+200+2000)/1000=32
        assertEq(magic, 29);
        assertEq(speed, 32);
    }

    // ---- 资源词条：先抽数量（0~4），再为每条抽一种固定效果 ----
    function testResourceAffixesCountThenType() public {
        mockRng.setFixed(999999); // 数量 4；种类全部 %4=3 → 魔素产量 +1 ×4
        uint256 tokenId = _createCharacter(alice, 1, new uint32[](0));
        CharacterRegistry.Character memory c = cr.getCharacter(tokenId);
        assertEq(c.resourceCount, 4);
        assertEq(c.manaGainBonus, 4); // 魔素产量 +1 ×4
        assertEq(c.apDiscount, 0);
        assertEq(c.apBonus, 0);
        assertEq(c.manaDiscount, 0);
        for (uint8 i; i < 4; ++i) assertEq(c.resourceTypes[i], cr.RESOURCE_MANA_PRODUCTION());

        // setFixed(4)：资源数量 %5=4？否——4%5=4 → 仍 4 条；种类 %4=0 → 全部 AP 消耗 -1
        mockRng.setFixed(24); // 24%5=4 → 4 条；24%4=0 → AP 消耗
        tokenId = _createCharacter(bob, 1, new uint32[](0));
        c = cr.getCharacter(tokenId);
        assertEq(c.resourceCount, 4);
        assertEq(c.apDiscount, 4); // AP 消耗 -1 ×4
        assertEq(c.apBonus, 0);
        assertEq(c.manaDiscount, 0);
        assertEq(c.manaGainBonus, 0);
    }

    /// 不变量：四个资源字段之和恒等于 resourceCount（每条固定 ±1 效果）。
    function testFuzzResourceAffixInvariant(uint256 seed) public {
        seed = bound(seed, 1, type(uint128).max);
        mockRng.setSeed(seed);
        uint256 tokenId = _createCharacter(alice, 1, new uint32[](0));
        CharacterRegistry.Character memory c = cr.getCharacter(tokenId);
        assertEq(_sumResourceFields(c), c.resourceCount);
        assertLe(c.resourceCount, 4);
    }

    function _sumResourceFields(CharacterRegistry.Character memory c) internal pure returns (uint16) {
        return c.apDiscount + c.apBonus + c.manaDiscount + uint16(c.manaGainBonus);
    }

    // ---- GM 入口：指定能力词条按最高档生效 ----
    function testGmMintAppliesTopTierAffixes() public {
        uint16[] memory affixes = new uint16[](2);
        affixes[0] = 1; // 生命模板
        affixes[1] = 2; // 物攻模板
        uint32[] memory skills = new uint32[](1);
        skills[0] = skillAttack;
        uint256 tokenId = cr.gmMintCharacter(alice, 1, 0, affixes, skills); // 人类剑士
        CharacterRegistry.Character memory c = cr.getCharacter(tokenId);
        assertEq(c.affixTiers[0], cr.MAX_AFFIX_TIER()); // GM 词条一律最高档
        assertEq(c.affixTiers[1], cr.MAX_AFFIX_TIER());
        assertEq(c.affixIds[0], 1);
        assertEq(c.affixIds[1], 2);
        assertEq(c.abilityBonuses[cr.ABILITY_HP()], 2000);
        assertEq(c.abilityBonuses[cr.ABILITY_ATTACK()], 2000);
        assertEq(c.resourceCount, 0); // GM 不发资源词条
        (uint64 hp,, uint64 attack,,) = cr.getStats(tokenId);
        // hp 100×(1000+200+2000)/1000=320；攻 10×(1000+2000+2000)/1000=50
        assertEq(hp, 320);
        assertEq(attack, 50);
        assertEq(cr.freeRerolls(alice), 0); // GM 铸造不触发首角色福利
    }

    function testGmMintUnknownAffixRejected() public {
        uint16[] memory affixes = new uint16[](1);
        affixes[0] = 99;
        vm.expectRevert("CR: unknown affix");
        cr.gmMintCharacter(alice, 1, 0, affixes, new uint32[](0));
    }

    function testGmMintTooManyAffixesRejected() public {
        uint16[] memory affixes = new uint16[](5);
        for (uint8 i; i < 5; ++i) affixes[i] = 1;
        vm.expectRevert("CR: too many affixes");
        cr.gmMintCharacter(alice, 1, 0, affixes, new uint32[](0));
    }

    // ---- 模板注册校验（expectRevert 后紧跟目标调用，参数用字面量避免中间外部调用）----
    function testRegisterAffixValidation() public {
        CharacterRegistry crNew = new CharacterRegistry(rng, sr, true);
        vm.expectRevert("CR: tier values not ordered");
        crNew.registerAffixTemplate(
            1,
            CharacterRegistry.AffixTemplate({
                statType: 1,
                exists: false,
                tierWeights: [uint16(400), 220, 140, 90, 60, 35, 25, 15, 10, 5],
                tierValues: [uint16(0), 250, 100, 450, 700, 950, 1200, 1450, 1700, 2000]
            })
        );

        vm.expectRevert("CR: empty tier weights");
        crNew.registerAffixTemplate(
            1,
            CharacterRegistry.AffixTemplate({
                statType: 1,
                exists: false,
                tierWeights: [uint16(0), 0, 0, 0, 0, 0, 0, 0, 0, 0],
                tierValues: [uint16(0), 100, 250, 450, 700, 950, 1200, 1450, 1700, 2000]
            })
        );

        vm.expectRevert("CR: bad stat type");
        crNew.registerAffixTemplate(
            1,
            CharacterRegistry.AffixTemplate({
                statType: 9,
                exists: false,
                tierWeights: [uint16(400), 220, 140, 90, 60, 35, 25, 15, 10, 5],
                tierValues: [uint16(0), 100, 250, 450, 700, 950, 1200, 1450, 1700, 2000]
            })
        );
    }

    // ---- GM 入口 ----
    function testGmDisabledReverts() public {
        CharacterRegistry crNoGm = new CharacterRegistry(rng, sr, false);
        uint16[] memory affixes = new uint16[](0);
        uint32[] memory skills = new uint32[](0);
        vm.expectRevert("CR: GM disabled");
        crNoGm.gmMintCharacter(alice, 1, 0, affixes, skills);
    }

    // ---- 等级公式：满级 = 1 级 × 300，线性插值，先乘后除 ----
    function testLevelFormulaLinear() public {
        uint256 tokenId = _gmCharacter(alice, 1, 0, new uint16[](0), new uint32[](0)); // 人类剑士：1 级攻 30 / hp 120
        (,, uint64 attack1,,) = cr.getStats(tokenId);
        assertEq(attack1, 30);
        cr.gmSetLevel(tokenId, cr.MAX_LEVEL());
        (uint64 hp300, uint64 maxHp300, uint64 attack300,,) = cr.getStats(tokenId);
        assertEq(attack300, 9000); // 30×300
        assertEq(maxHp300, 36000); // 120×300
        assertEq(hp300, maxHp300);
        cr.gmSetLevel(tokenId, 150);
        (,, uint64 attack150,,) = cr.getStats(tokenId);
        assertEq(attack150, 4500);
        vm.expectRevert("CR: bad level");
        cr.gmSetLevel(tokenId, 301);
    }

    // ---- 转移重置等级：属性按等级 1 重算（_computeStats 幂等）----
    function testTransferResetsStatsToLevel1() public {
        uint256 tokenId = _gmCharacter(alice, 1, 0, new uint16[](0), new uint32[](0));
        cr.gmSetLevel(tokenId, 300);
        (,, uint64 attack300,,) = cr.getStats(tokenId);
        assertEq(attack300, 9000);
        vm.prank(alice);
        cr.transferFrom(alice, bob, tokenId);
        CharacterRegistry.Character memory c = cr.getCharacter(tokenId);
        assertEq(c.level, 1);
        assertEq(c.attack, 30); // 属性回落等级 1
        assertEq(c.hp, c.maxHp);
    }

    // ---- ERC-721 转移钩子 ----
    function testTransferChangesOwner() public {
        mockRng.setSeed(11);
        uint256 tokenId = _createCharacter(alice, 1, new uint32[](0));
        vm.prank(alice);
        cr.transferFrom(alice, bob, tokenId);
        assertEq(cr.ownerOf(tokenId), bob);
        assertEq(cr.getCharacter(tokenId).level, 1); // 等级重置
    }

    function testTransferLockedInRoom() public {
        mockRng.setSeed(12);
        uint256 tokenId = _createCharacter(alice, 1, new uint32[](0));
        vm.prank(address(ce));
        cr.setInRoom(tokenId, 7);
        vm.prank(alice);
        vm.expectRevert("CR: in room");
        cr.transferFrom(alice, bob, tokenId);
    }

    // ---- 首角色重掷计数器 ----
    function testRerollExhaustsFreeCount() public {
        mockRng.setSeed(13);
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
        for (uint16 id = 1; id <= 4; ++id) {
            crProd.registerAffixTemplate(id, cr.getAffixTemplate(id)); // 四个能力模板
        }
        mockRng.setSeed(14); // 正常随机序列
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
        mockRng.setSeed(uint256(classId) + 100);
        uint256 tokenId = _createCharacter(alice, classId, new uint32[](0));
        CharacterRegistry.Character memory c = cr.getCharacter(tokenId);
        assertTrue(c.race < 8);
        assertLe(c.resourceCount, 4);
        assertEq(c.level, 1);
        assertLe(c.hp, c.maxHp);
        for (uint8 i; i < 4; ++i) {
            assertGe(c.affixTiers[i], 1);
            assertLe(c.affixTiers[i], 10);
            assertLe(c.abilityBonuses[i], 2000); // 单档上限 2000‰
        }
        // 无封顶：直接修正线性叠加，仅保证非负（_calcStat 钳制）
        assertGe(c.attack, 0);
        assertGe(c.magic, 0);
        assertGe(c.speed, 0);
    }
}

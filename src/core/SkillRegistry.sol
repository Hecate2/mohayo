// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title SkillRegistry - 技能/效果/怪物AI/敌人模板的数据化注册表
/// @notice 复杂度封在数据层：结算器只实现有限原语，新技能 = 注册一条新数据（技术设计 §2.5）。
///         注册总数硬上限防垃圾注册（§6.3）；红线 op（GUAR_NEXT）仅职业绑定技能表可配。
contract SkillRegistry is Ownable {
    // ---- Effect op 枚举（首版；可经合约升级追加，每个 op 的叠加/驱散规则随枚举固化）----
    uint8 public constant OP_STUN = 1;
    uint8 public constant OP_DMG_OUT_MOD = 2;
    uint8 public constant OP_DMG_IN_MOD = 3;
    uint8 public constant OP_SHIELD = 4;
    uint8 public constant OP_EVADE_UP = 5;
    uint8 public constant OP_ACC_DOWN = 6;
    uint8 public constant OP_GUAR_NEXT = 7;
    uint8 public constant OP_DOT = 8;
    uint8 public constant OP_HEAL = 9;
    uint8 public constant OP_DISPEL = 10;
    uint8 public constant OP_TAUNT = 11;
    uint8 public constant OP_LIFESTEAL = 12;
    uint8 public constant OP_MANA_DELTA = 13;
    uint8 public constant OP_SUMMON = 14;

    // ---- Skill kind ----
    uint8 public constant KIND_PHYSICAL = 1;
    uint8 public constant KIND_MAGIC = 2;
    uint8 public constant KIND_SUPPORT = 3;
    uint8 public constant KIND_SUMMON = 4;

    // ---- targeting 模式（目标一律由结算器决定，玩家不可指定）----
    uint8 public constant TGT_RAND_SINGLE_ENEMY = 1;
    uint8 public constant TGT_RAND_MULTI_ENEMY = 2;
    uint8 public constant TGT_RAND_STRIKE_ENEMY = 3;
    uint8 public constant TGT_ALL_ENEMY = 4;
    uint8 public constant TGT_RAND_SINGLE_ALLY = 5;
    uint8 public constant TGT_RAND_MULTI_ALLY = 6;
    uint8 public constant TGT_ALL_ALLY = 7;
    uint8 public constant TGT_ROOM_ALL = 8;
    uint8 public constant TGT_SELF = 9;
    uint8 public constant TGT_MOST_WOUNDED_ALLY = 10; // 治疗血量亏空绝对值最高者（圣愈之光）

    // ---- weightMode（加权随机目标抽取）----
    uint8 public constant WT_UNIFORM = 0;
    uint8 public constant WT_HP_DEFICIT_ALLY = 1;
    uint8 public constant WT_THREAT_ENEMY = 2;

    // ---- flags 位掩码 ----
    uint8 public constant FLAG_GUARANTEED_HIT = 1; // bit0
    uint8 public constant FLAG_MANA_ALL = 2; // bit1：耗光房间魔素池，伤害 = power × 消耗魔素 / 1000（爆裂魔法）
    uint8 public constant FLAG_SUMMON_ALLY = 4; // bit2：SUMMON 召唤己方单位（替身人偶；默认 0 = 敌方召唤）

    // ---- Effect scope ----
    uint8 public constant SCOPE_SELF = 0;
    uint8 public constant SCOPE_TARGET = 1;
    uint8 public constant SCOPE_ALL_ALLY = 2;
    uint8 public constant SCOPE_ALL_ENEMY = 3;

    // ---- 种族（CharacterRegistry 复用）----
    uint8 public constant RACE_HUMAN = 0;
    uint8 public constant RACE_ORC = 1;
    uint8 public constant RACE_GIANT = 2;
    uint8 public constant RACE_DWARF = 3;
    uint8 public constant RACE_ELF = 4;
    uint8 public constant RACE_DRAGONKIN = 5;
    uint8 public constant RACE_ANGEL = 6;
    uint8 public constant RACE_DEMON = 7;

    struct Effect {
        uint8 op; // OP_* 枚举
        uint8 duration; // 持续回合数（控制类）
        uint16 magnitude; // 数值（千分比/盾量/每跳量等按 op 语义）
        uint8 scope; // 作用目标（SCOPE_*）
        uint16 prob; // 概率（千分比，1000 = 必发；默认 1000）
    }

    struct SummonRule {
        uint16 templateId; // 召唤出的敌人模板
        uint8 maxCount; // 单次召唤上限
        uint8 enemyHeadroom; // 场上允许的「敌人超出角色数」裕量
    }

    struct Skill {
        uint32 id;
        uint8 kind; // KIND_*
        uint16 apCost; // 物理技：施放所需 AP
        uint16 apGain; // 物理技：命中后产出 AP
        uint16 ammoId; // 弹药类技能消耗的道具 id（0 = 无弹药需求）
        uint16 ammoCost; // 弹药消耗数量（每次行动固定烧 N 发）
        uint32 manaCost; // 魔素消耗（房间级魔素池）
        uint16 hpCost; // 以命换输出（黑魔法师「献祭」）
        uint8 targeting; // TGT_*
        uint8 weightMode; // WT_*
        uint8 targetCount; // RAND_MULTI_* 不重复目标数 / RAND_STRIKE_ENEMY 段数（≤8）
        uint64 power; // 伤害/治疗基数
        uint64 damageCap; // 单目标单次伤害上限；0 = 无上限（仅管理员破墙技）
        uint16 baseAcc; // 基础命中率（千分比，≤1000）
        uint8 flags; // 位掩码（bit0 = GUARANTEED_HIT）
        Effect[4] effects; // 固定长度，配 effectCount 使用
        uint8 effectCount; // 实际 effects 数量（0~4）
        SummonRule summon; // 仅 SUMMON
    }

    struct MonsterAI {
        uint16[8] skillCycle; // 技能循环表（按回合数取模；0 = 普攻占位；待机怪放空技能）
        uint8 cycleLen; // 循环长度（1~8）
    }

    struct OnDeathSpawn {
        uint16 templateId; // 死亡时召唤的敌人模板
        uint8 count; // 召唤数量
        uint16 prob; // 概率（千分比；1000 = 必召）；全零 = 无死亡召唤
    }

    struct EnemyTemplate {
        uint16 aiId; // 关联 MonsterAI
        uint8 threat; // 威胁权重（THREAT_ENEMY 抽取权重；1 = 均匀等价）
        uint64 maxHp;
        uint64 power;
        uint64 magic;
        uint64 speed;
        uint16 baseAcc;
        uint16 rewardMin; // 掉落烬晶下限
        uint16 rewardMax; // 掉落烬晶上限
        OnDeathSpawn onDeathSpawn;
    }

    uint256 public constant MAX_SKILLS = 1024;
    uint256 public constant MAX_AI = 256;
    uint256 public constant MAX_TEMPLATES = 512;

    mapping(uint32 => Skill) public skills;
    mapping(uint16 => MonsterAI) public ais;
    mapping(uint16 => EnemyTemplate) public templates;
    uint32 public skillCount;
    uint16 public aiCount;
    uint16 public templateCount;

    /// @notice 职业绑定技能表：classId => skillId => allowed（红线 op 仅此表可配）
    mapping(uint8 => mapping(uint32 => bool)) public classSkill;
    /// @notice 职业技能枚举：classId => 技能 id 列表（CharacterRegistry 据此在创建时自动发放职业专属技）
    mapping(uint8 => uint32[]) public classSkillIds;

    event SkillRegistered(uint32 indexed id, uint8 kind);
    event AIRegistered(uint16 indexed id);
    event TemplateRegistered(uint16 indexed id);
    event ClassSkillBound(uint8 indexed classId, uint32 indexed skillId, bool allowed);

    constructor() Ownable(msg.sender) {}

    /// @notice 通用注册（自选池/道具来源）：红线 op（GUAR_NEXT）在此路径被拒
    function registerSkill(Skill calldata s) external onlyOwner returns (uint32 id) {
        _validateSkill(s);
        require(!_hasOp(s, OP_GUAR_NEXT), "SR: guar_next class-only");
        id = _storeSkill(s);
        emit SkillRegistered(id, s.kind);
    }

    /// @notice 职业绑定注册：允许红线 op，并记录 classSkill 白名单 + 枚举列表
    function registerClassSkill(Skill calldata s, uint8 classId) external onlyOwner returns (uint32 id) {
        _validateSkill(s);
        id = _storeSkill(s);
        classSkill[classId][id] = true;
        _pushClassSkill(classId, id);
        emit SkillRegistered(id, s.kind);
        emit ClassSkillBound(classId, id, true);
    }

    function bindClassSkill(uint8 classId, uint32 skillId, bool allowed) external onlyOwner {
        require(skills[skillId].id != 0, "SR: unknown skill");
        classSkill[classId][skillId] = allowed;
        if (allowed) _pushClassSkill(classId, skillId);
        emit ClassSkillBound(classId, skillId, allowed);
    }

    /// @dev 追加职业技 id 到枚举列表（注册期首次出现才追加；重复绑定允许=true 时幂等跳过）
    function _pushClassSkill(uint8 classId, uint32 skillId) private {
        uint32[] storage list = classSkillIds[classId];
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == skillId) return;
        }
        list.push(skillId);
    }

    /// @notice 返回某职业已绑定的技能 id 列表（创建时自动发放职业专属技）
    function getClassSkillIds(uint8 classId) external view returns (uint32[] memory) {
        return classSkillIds[classId];
    }

    function registerAI(MonsterAI calldata ai) external onlyOwner returns (uint16 id) {
        require(aiCount < MAX_AI, "SR: ai cap");
        require(ai.cycleLen >= 1 && ai.cycleLen <= 8, "SR: bad cycleLen");
        id = ++aiCount;
        ais[id] = ai;
        emit AIRegistered(id);
    }

    function registerTemplate(EnemyTemplate calldata t) external onlyOwner returns (uint16 id) {
        require(templateCount < MAX_TEMPLATES, "SR: template cap");
        require(t.aiId == 0 || ais[t.aiId].cycleLen != 0, "SR: unknown ai");
        id = ++templateCount;
        templates[id] = t;
        emit TemplateRegistered(id);
    }

    function _validateSkill(Skill memory s) private pure {
        require(s.effectCount <= 4, "SR: too many effects");
        require(s.targetCount <= 8, "SR: targetCount cap");
        require(s.baseAcc <= 1000, "SR: baseAcc cap");
        require(s.targeting >= 1 && s.targeting <= 10, "SR: bad targeting");
        require(s.weightMode <= 2, "SR: bad weightMode");
        for (uint8 i; i < s.effectCount; ++i) {
            require(s.effects[i].op >= 1 && s.effects[i].op <= 14, "SR: bad op");
            require(s.effects[i].prob <= 1000 && s.effects[i].prob != 0, "SR: bad prob");
        }
    }

    function _hasOp(Skill memory s, uint8 op) private pure returns (bool) {
        for (uint8 i; i < s.effectCount; ++i) {
            if (s.effects[i].op == op) return true;
        }
        return false;
    }

    function _storeSkill(Skill calldata s) private returns (uint32 id) {
        require(skillCount < MAX_SKILLS, "SR: skill cap");
        id = ++skillCount;
        Skill storage st = skills[id];
        st.id = id;
        st.kind = s.kind;
        st.apCost = s.apCost;
        st.apGain = s.apGain;
        st.ammoId = s.ammoId;
        st.ammoCost = s.ammoCost;
        st.manaCost = s.manaCost;
        st.hpCost = s.hpCost;
        st.targeting = s.targeting;
        st.weightMode = s.weightMode;
        st.targetCount = s.targetCount;
        st.power = s.power;
        st.damageCap = s.damageCap;
        st.baseAcc = s.baseAcc;
        st.flags = s.flags;
        st.effectCount = s.effectCount;
        for (uint8 i; i < s.effectCount; ++i) {
            st.effects[i] = s.effects[i];
        }
        st.summon = s.summon;
    }

    // ---- 显式 getter（含嵌套数组的结构体无法用默认 public getter 访问字段）----
    function getSkill(uint32 id) external view returns (Skill memory) {
        return skills[id];
    }

    function getAI(uint16 id) external view returns (MonsterAI memory) {
        return ais[id];
    }

    function getTemplate(uint16 id) external view returns (EnemyTemplate memory) {
        return templates[id];
    }
}

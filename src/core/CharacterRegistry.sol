// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {RNGRouter} from "./RNGRouter.sol";
import {SkillRegistry} from "./SkillRegistry.sol";

/// @title CharacterRegistry - 角色 CRUD + 种族/词条随机 + ERC-721 转移钩子
/// @notice 创建流程：职业 → 种族三层加权（85/12/3）→ 词条（方向 20/68/12 → 词条 → 档位）。
///         种族创建时随机生成、永久不可改；种族/词条以直接修正（千分比）作用于基础属性，无任何封顶。
///         资源流词条（默诵 manaDiscount / 好战本能 apBonus）每角色 ≤2 条。
///         ERC-721 transfer 钩子：等级重置 + 房间内锁定（技术设计 §2.1 / §6.0）。
contract CharacterRegistry is ERC721, Ownable {
    RNGRouter public immutable rng;
    SkillRegistry public immutable skillRegistry;
    bytes32 public constant CATEGORY_AFFIX = keccak256("AFFIX");

    uint256 public constant MAX_AFFIXES = 256;
    uint256 public constant MAX_CLASSES = 32;
    uint256 public constant MAX_RACES = 16;
    uint8 public constant MAX_AFFIX_PER_CHAR = 2;
    uint8 public constant MAX_SKILL_PER_CHAR = 8;

    // ---- 种族/词条方向常量（与 SkillRegistry 对齐；本地定义避免跨合约常量解析）----
    uint8 public constant RACE_HUMAN = 0;
    uint8 public constant RACE_ORC = 1;
    uint8 public constant RACE_GIANT = 2;
    uint8 public constant RACE_DWARF = 3;
    uint8 public constant RACE_ELF = 4;
    uint8 public constant RACE_DRAGONKIN = 5;
    uint8 public constant RACE_ANGEL = 6;
    uint8 public constant RACE_DEMON = 7;
    uint8 public constant AFFIX_POSITIVE = 0;
    uint8 public constant AFFIX_DOUBLE_EDGED = 1;
    uint8 public constant AFFIX_NEGATIVE = 2;

    // ---- 种族三层加权（千分比）----
    uint16[3] public raceTierWeights = [850, 120, 30]; // 常见/略稀有/最稀有
    // ---- 词条方向加权（千分比）----
    uint16[3] public affixDirectionWeights = [200, 680, 120]; // 正面/双刃/负面

    struct Character {
        uint8 classId;
        uint8 race;
        uint8 level;
        uint16[4] affixIds; // 词条（≤2 条，数组留余量）
        uint8 affixCount;
        uint32[8] skillIds; // 职业技 + 种族技 + 自选技
        uint8 skillCount;
        uint64 hp;
        uint64 maxHp;
        uint64 attack;
        uint64 magic;
        uint64 speed;
        uint16 manaDiscount; // 默诵
        uint16 apDiscount; // 战术素养：自身技能 AP 消耗折扣
        uint16 apBonus; // 好战本能
        int16 manaGainBonus; // 聚魔/好战本能/散魔：房间魔素池每回合增量修正（可为负）
        uint16 apCapBonus; // 斗魂：个人 AP 上限加成
        uint32 roomId; // 所在房间（0 = 不在房间）
    }
    mapping(uint256 => Character) public characters;
    uint256 public nextTokenId = 1;

    struct ClassDef {
        uint64 baseHp;
        uint64 baseAttack;
        uint64 baseMagic;
        uint64 baseSpeed;
        uint8 skillSlots; // 职业额外自选槽（无职业 3 / 职业 1）
    }
    mapping(uint8 => ClassDef) public classDefs;
    uint8 public classCount;

    struct RaceDef {
        int16[3] statMods; // 攻击/魔法/速度 直接修正（千分比，可为负）
        int16 hpMod; // HP 直接修正（千分比）
        uint32 raceSkillId; // 种族技 1（0 = 无，人类）
        uint32 raceSkillId2; // 种族技 2（仅天使/恶魔双种族技；0 = 无）
        uint8 selfSelectBonus; // 人类 +2 自选槽
        bool exists; // 注册标记（人类全零修正时用于区分未注册）
    }
    mapping(uint8 => RaceDef) public raceDefs;
    uint8 public raceCount;

    struct AffixTemplate {
        uint8 direction; // AFFIX_*（正面/双刃/负面）
        uint8 resourceType; // 0=非资源流 1=资源流（魔素/AP 类，受 ≤2 条上限约束）
        uint16 manaDiscount; // 默诵：魔素折扣
        uint16 apDiscount; // 战术素养：AP 消耗折扣
        uint16 apBonus; // 好战本能：每回合 AP 加成
        int16 manaGainBonus; // 聚魔/好战本能/散魔：房间魔素池每回合增量修正（可为负）
        uint16 apCapBonus; // 斗魂：个人 AP 上限加成
        int64[3] statMods; // 攻击/魔法/速度 修正（千分比，可为负）
        int64 hpMod; // HP 修正（千分比）
        uint16[5] tierWeights; // 档位 1~5 权重（千分比）
    }
    mapping(uint16 => AffixTemplate) public affixTemplates;
    uint16 public affixCount;

    /// @notice 首角色免费重掷计数器（playerId => 剩余次数；非道具、不可转移）
    mapping(address => uint8) public freeRerolls;
    /// @notice 首角色福利一次性领取标记（防「耗尽后新建角色再领」白嫖）
    mapping(address => bool) public firstRerollClaimed;

    /// @notice GM 测试入口开关（主网部署传 false 物理移除）
    bool public immutable gmEnabled;

    event CharacterCreated(uint256 indexed tokenId, address indexed owner, uint8 classId, uint8 race, uint8 level);
    event CharacterRerolled(uint256 indexed tokenId, address indexed owner);
    event AffixTemplateRegistered(uint16 indexed id, uint8 direction);
    event ClassRegistered(uint8 indexed id);
    event RaceRegistered(uint8 indexed id);

    constructor(RNGRouter rng_, SkillRegistry skillRegistry_, bool gmEnabled_) ERC721("Mohayo Character", "MOHC") Ownable(msg.sender) {
        rng = rng_;
        skillRegistry = skillRegistry_;
        gmEnabled = gmEnabled_;
    }

    // ---- 模板注册（治理/部署）----
    function registerClass(uint8 classId, ClassDef calldata def) external onlyOwner {
        require(classId > 0 && classId <= MAX_CLASSES, "CR: bad classId");
        require(classDefs[classId].baseHp == 0, "CR: class exists");
        classDefs[classId] = def;
        if (classId > classCount) classCount = classId;
        emit ClassRegistered(classId);
    }

    function registerRace(uint8 race, RaceDef calldata def) external onlyOwner {
        require(race < MAX_RACES, "CR: bad race");
        require(!raceDefs[race].exists, "CR: race exists");
        raceDefs[race] = def;
        raceDefs[race].exists = true;
        if (race >= raceCount) raceCount = race + 1;
        emit RaceRegistered(race);
    }

    function registerAffixTemplate(uint16 id, AffixTemplate calldata t) external onlyOwner {
        require(id > 0 && id <= MAX_AFFIXES, "CR: bad affixId");
        require(t.direction <= 2, "CR: bad direction");
        require(affixTemplates[id].direction == 0 && affixTemplates[id].statMods[0] == 0, "CR: affix exists");
        affixTemplates[id] = t;
        if (id > affixCount) affixCount = id;
        emit AffixTemplateRegistered(id, t.direction);
    }

    function setRaceTierWeights(uint16[3] calldata w) external onlyOwner {
        raceTierWeights = w;
    }

    function setAffixDirectionWeights(uint16[3] calldata w) external onlyOwner {
        affixDirectionWeights = w;
    }

    // ---- 创建 ----
    /// @notice 正常创建：种族/词条全部走 AFFIX RNG；自选技由玩家指定
    function createCharacter(uint8 classId, uint32[] calldata skillIds) external returns (uint256 tokenId) {
        require(classDefs[classId].baseHp != 0, "CR: unknown class");
        uint8 race = _rollRace(tokenId);
        uint16[4] memory affixIds;
        uint8 affixCount_ = _rollAffixes(affixIds);
        tokenId = _mintCharacter(msg.sender, classId, race, affixIds, affixCount_, skillIds);
        if (!firstRerollClaimed[msg.sender]) {
            firstRerollClaimed[msg.sender] = true;
            freeRerolls[msg.sender] = 3; // 首角色福利（一次性）
        }
        emit CharacterCreated(tokenId, msg.sender, classId, race, characters[tokenId].level);
    }

    /// @notice GM 测试入口：指定全属性，绕过 RNG/费用/限额/首角色判定（技术设计 §6.7）
    function gmMintCharacter(address to, uint8 classId, uint8 race, uint16[] calldata affixIds_, uint32[] calldata skillIds)
        external
        onlyOwner
        returns (uint256 tokenId)
    {
        require(gmEnabled, "CR: GM disabled");
        require(classDefs[classId].baseHp != 0, "CR: unknown class");
        require(race < raceCount, "CR: unknown race");
        uint16[4] memory affixIds;
        uint8 n = uint8(affixIds_.length);
        require(n <= MAX_AFFIX_PER_CHAR, "CR: too many affixes");
        for (uint8 i; i < n; ++i) affixIds[i] = affixIds_[i];
        tokenId = _mintCharacter(to, classId, race, affixIds, n, skillIds);
        emit CharacterCreated(tokenId, to, classId, race, characters[tokenId].level);
    }

    function _mintCharacter(address to, uint8 classId, uint8 race, uint16[4] memory affixIds, uint8 affixCount_, uint32[] calldata skillIds)
        private
        returns (uint256 tokenId)
    {
        require(skillIds.length <= MAX_SKILL_PER_CHAR, "CR: too many skills");
        tokenId = nextTokenId++;
        _safeMint(to, tokenId);
        Character storage c = characters[tokenId];
        c.classId = classId;
        c.race = race;
        c.level = 1;
        c.affixCount = affixCount_;
        for (uint8 i; i < affixCount_; ++i) c.affixIds[i] = affixIds[i];
        _computeStats(c, classId, race, affixIds, affixCount_);
        _mergeSkills(c, classId, race, skillIds);
        c.hp = c.maxHp;
    }

    function _computeStats(Character storage c, uint8 classId, uint8 race, uint16[4] memory affixIds, uint8 affixCount_) private {
        ClassDef memory def = classDefs[classId];
        RaceDef memory rd = raceDefs[race];
        int64[3] memory mods = [int64(rd.statMods[0]), int64(rd.statMods[1]), int64(rd.statMods[2])];
        int64 hpMod = int64(rd.hpMod);
        uint8 resourceCount;
        for (uint8 i; i < affixCount_; ++i) {
            AffixTemplate memory t = affixTemplates[affixIds[i]];
            for (uint8 j; j < 3; ++j) mods[j] += t.statMods[j];
            hpMod += t.hpMod;
            if (t.resourceType != 0) {
                c.manaDiscount += t.manaDiscount;
                c.apDiscount += t.apDiscount;
                c.apBonus += t.apBonus;
                c.manaGainBonus += t.manaGainBonus;
                c.apCapBonus += t.apCapBonus;
                resourceCount++;
            }
        }
        // 资源流词条 ≤2 条（创建时已保证，此处冗余防御）
        require(resourceCount <= MAX_AFFIX_PER_CHAR, "CR: resource affix cap");

        c.maxHp = _calcStat(def.baseHp, hpMod);
        c.attack = _calcStat(def.baseAttack, mods[0]);
        c.magic = _calcStat(def.baseMagic, mods[1]);
        c.speed = _calcStat(def.baseSpeed, mods[2]);
    }

    function _calcStat(uint64 base, int64 mod) private pure returns (uint64) {
        int256 v = int256(uint256(base)) * (1000 + mod) / 1000;
        if (v < 0) v = 0;
        return uint64(uint256(v));
    }

    function _mergeSkills(Character storage c, uint8 classId, uint8 race, uint32[] calldata skillIds) private {
        uint8 n = 0;
        // 自选技校验：仅允许公共池技与本职业技；跨职业职业技拒绝（红线 op 仅本职业可用）；
        // 种族技一律拒绝（随种族自动并入，手动传入会重复并破坏种族绑定）
        for (uint256 i; i < skillIds.length; ++i) {
            uint32 sid = skillIds[i];
            require(skillRegistry.getSkill(sid).id != 0, "CR: unknown skill");
            require(!_isRaceSkill(sid), "CR: race skill locked");
            uint8 boundClass = _isClassSkill(sid);
            require(boundClass == 0 || boundClass == classId, "CR: class skill locked");
            c.skillIds[n++] = sid;
        }
        // 种族技并入（天使/恶魔双种族技）
        uint32 raceSkill = raceDefs[race].raceSkillId;
        if (raceSkill != 0) {
            require(skillRegistry.getSkill(raceSkill).id != 0, "CR: unknown race skill");
            c.skillIds[n++] = raceSkill;
        }
        uint32 raceSkill2 = raceDefs[race].raceSkillId2;
        if (raceSkill2 != 0) {
            require(skillRegistry.getSkill(raceSkill2).id != 0, "CR: unknown race skill");
            c.skillIds[n++] = raceSkill2;
        }
        c.skillCount = n;
    }

    /// @notice 技能是否被某职业绑定；返回绑定职业 id，0 = 公共池技
    function _isClassSkill(uint32 skillId) private view returns (uint8) {
        for (uint8 i = 1; i <= classCount; ++i) {
            if (skillRegistry.classSkill(i, skillId)) return i;
        }
        return 0;
    }

    /// @notice 技能是否为任一种族技（种族技只能随种族自动并入，不可自选）
    function _isRaceSkill(uint32 skillId) private view returns (bool) {
        for (uint8 i; i < raceCount; ++i) {
            RaceDef storage rd = raceDefs[i];
            if (rd.raceSkillId == skillId || rd.raceSkillId2 == skillId) return true;
        }
        return false;
    }

    // ---- 种族/词条随机 ----
    function _rollRace(uint256 context) private returns (uint8 race) {
        uint256 r = rng.next(CATEGORY_AFFIX, keccak256(abi.encodePacked("race", context)));
        uint16[3] memory w = raceTierWeights;
        uint256 total = uint256(w[0]) + uint256(w[1]) + uint256(w[2]);
        uint256 roll = r % total;
        uint8 tier;
        if (roll < w[0]) tier = 0;
        else if (roll < w[0] + w[1]) tier = 1;
        else tier = 2;
        // 层内均匀：tier0=人类/兽人/巨人/矮人；tier1=精灵/龙人；tier2=天使/恶魔
        uint256 sub = rng.next(CATEGORY_AFFIX, keccak256(abi.encodePacked("raceSub", context))) % 100;
        if (tier == 0) {
            if (sub < 25) return RACE_HUMAN;
            if (sub < 50) return RACE_ORC;
            if (sub < 75) return RACE_GIANT;
            return RACE_DWARF;
        }
        if (tier == 1) return sub < 50 ? RACE_ELF : RACE_DRAGONKIN;
        return sub < 50 ? RACE_ANGEL : RACE_DEMON;
    }

    function _rollAffixes(uint16[4] memory out) private returns (uint8 count) {
        uint8 resourceCount;
        for (uint8 slot; slot < MAX_AFFIX_PER_CHAR; ++slot) {
            uint8 direction = _rollDirection(slot);
            uint16 affixId = _pickAffix(direction, slot);
            // 资源流词条 ≤2 条：已满则在同方向内重掷其他词条
            if (affixTemplates[affixId].resourceType != 0) {
                if (resourceCount >= MAX_AFFIX_PER_CHAR) {
                    affixId = _pickAffixNonResource(direction, slot);
                } else {
                    resourceCount++;
                }
            }
            out[count++] = affixId;
        }
    }

    function _rollDirection(uint8 slot) private returns (uint8) {
        uint16[3] memory w = affixDirectionWeights;
        uint256 total = uint256(w[0]) + uint256(w[1]) + uint256(w[2]);
        uint256 roll = rng.next(CATEGORY_AFFIX, keccak256(abi.encodePacked("dir", slot))) % total;
        if (roll < w[0]) return AFFIX_POSITIVE;
        if (roll < w[0] + w[1]) return AFFIX_DOUBLE_EDGED;
        return AFFIX_NEGATIVE;
    }

    function _pickAffix(uint8 direction, uint8 slot) private returns (uint16) {
        // 收集该方向全部词条，按权重抽取
        uint16[] memory pool = new uint16[](affixCount);
        uint8 n;
        for (uint16 i = 1; i <= affixCount; ++i) {
            if (affixTemplates[i].direction == direction) pool[n++] = i;
        }
        require(n > 0, "CR: no affix in direction");
        uint256 roll = rng.next(CATEGORY_AFFIX, keccak256(abi.encodePacked("affix", slot))) % n;
        return pool[roll];
    }

    function _pickAffixNonResource(uint8 direction, uint8 slot) private returns (uint16) {
        uint16[] memory pool = new uint16[](affixCount);
        uint8 n;
        for (uint16 i = 1; i <= affixCount; ++i) {
            if (affixTemplates[i].direction == direction && affixTemplates[i].resourceType == 0) pool[n++] = i;
        }
        require(n > 0, "CR: no non-resource affix");
        uint256 roll = rng.next(CATEGORY_AFFIX, keccak256(abi.encodePacked("affixNR", slot))) % n;
        return pool[roll];
    }

    // ---- 重掷（首角色免费计数器；付费路径待道具层落地）----
    function rerollCharacter(uint256 tokenId) external {
        address owner = _ownerOf(tokenId);
        require(owner != address(0), "CR: nonexistent");
        require(_isAuthorized(owner, msg.sender, tokenId), "CR: not authorized");
        require(freeRerolls[msg.sender] > 0 || gmEnabled, "CR: no reroll");
        if (freeRerolls[msg.sender] > 0) freeRerolls[msg.sender]--;
        _burn(tokenId);
        delete characters[tokenId];
        emit CharacterRerolled(tokenId, msg.sender);
    }

    // ---- ERC-721 转移钩子：房间内锁定 + 等级重置（技术设计 §2.1 / §7.4）----
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0)) {
            Character storage c = characters[tokenId];
            require(c.roomId == 0, "CR: in room");
            // 所有权变更 → 等级重置为 1（属性按等级 1 重算）
            c.level = 1;
            c.hp = c.maxHp;
        }
        return super._update(to, tokenId, auth);
    }

    // ---- 房间状态联动（CombatEngine 调用）----
    function setInRoom(uint256 tokenId, uint32 roomId) external {
        require(msg.sender == combatEngine || owner() == msg.sender, "CR: not engine");
        characters[tokenId].roomId = roomId;
    }

    address public combatEngine;

    function setCombatEngine(address engine) external onlyOwner {
        combatEngine = engine;
    }

    // ---- 查询 ----
    function getStats(uint256 tokenId) external view returns (uint64 hp, uint64 maxHp, uint64 attack, uint64 magic, uint64 speed) {
        Character storage c = characters[tokenId];
        return (c.hp, c.maxHp, c.attack, c.magic, c.speed);
    }

    function getCharacter(uint256 tokenId) external view returns (Character memory) {
        return characters[tokenId];
    }

    function getAffixTemplate(uint16 id) external view returns (AffixTemplate memory) {
        return affixTemplates[id];
    }

    function getClassDef(uint8 id) external view returns (ClassDef memory) {
        return classDefs[id];
    }

    function getRaceDef(uint8 id) external view returns (RaceDef memory) {
        return raceDefs[id];
    }
}

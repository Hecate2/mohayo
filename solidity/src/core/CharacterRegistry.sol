// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {RNGRouter} from "./RNGRouter.sol";
import {SkillRegistry} from "./SkillRegistry.sol";

/// @title CharacterRegistry - 角色 CRUD + 种族/词条随机 + ERC-721 转移钩子
/// @notice 创建流程：职业 → 种族三层加权（85/12/3）→ 四项能力词条 → 资源词条。
///         生命、物攻、魔攻、敏捷各自独立抽取 1~10 档，档位值 0~2000‰、高档更稀有；
///         随后抽取 0~4 条资源词条，每条固定为 AP 消耗-1 / AP 产量+1 / 魔素消耗-1 / 魔素产量+1 之一。
///         词条不再有正面/双刃/负面方向，词条加成均为非负。
///         ERC-721 transfer 钩子：等级重置 + 房间内锁定（技术设计 §2.1 / §6.0）。
contract CharacterRegistry is ERC721, Ownable {
    RNGRouter public immutable rng;
    SkillRegistry public immutable skillRegistry;
    bytes32 public constant CATEGORY_AFFIX = keccak256("AFFIX");

    uint256 public constant MAX_AFFIXES = 256;
    uint256 public constant MAX_CLASSES = 32;
    uint256 public constant MAX_RACES = 16;
    uint8 public constant MAX_AFFIX_TIER = 10;
    uint8 public constant MAX_RESOURCE_AFFIX_PER_CHAR = 4;
    uint8 public constant MAX_SKILL_PER_CHAR = 8;

    // ---- 数量级基准（用户定案）：1 级基准 / 满级 300 / 词条上限 ×3 ----
    uint64 public constant BASE_HP = 100;
    uint64 public constant BASE_ATTACK = 10;
    uint64 public constant BASE_MAGIC = 10;
    uint64 public constant BASE_SPEED = 10;
    uint16 public constant MAX_LEVEL = 300; // 满级；能力值 = 1 级基准 × level（线性插值，满级 = 1 级 × 300）
    uint16 public constant MAX_AFFIX_MOD = 2000; // 能力词条单档加成上限（千分比）：最高档 +2000‰

    // ---- 能力索引与资源效果枚举 ----
    uint8 public constant ABILITY_HP = 0;
    uint8 public constant ABILITY_ATTACK = 1;
    uint8 public constant ABILITY_MAGIC = 2;
    uint8 public constant ABILITY_SPEED = 3;
    uint8 public constant RESOURCE_AP_COST = 0; // AP 消耗 -1
    uint8 public constant RESOURCE_AP_PRODUCTION = 1; // AP 产量 +1
    uint8 public constant RESOURCE_MANA_COST = 2; // 魔素消耗 -1
    uint8 public constant RESOURCE_MANA_PRODUCTION = 3; // 魔素产量 +1

    // ---- 种族常量 ----
    uint8 public constant RACE_HUMAN = 0;
    uint8 public constant RACE_ORC = 1;
    uint8 public constant RACE_GIANT = 2;
    uint8 public constant RACE_DWARF = 3;
    uint8 public constant RACE_ELF = 4;
    uint8 public constant RACE_DRAGONKIN = 5;
    uint8 public constant RACE_ANGEL = 6;
    uint8 public constant RACE_DEMON = 7;

    // ---- 种族三层加权（千分比）----
    uint16[3] public raceTierWeights = [850, 120, 30]; // 常见/略稀有/最稀有

    struct Character {
        uint8 classId;
        uint8 race;
        uint16 level; // 等级（满级 MAX_LEVEL=300；能力值 = 1 级基准 × level 线性插值）
        uint16[4] affixIds; // 四项能力词条模板 id
        uint8[4] affixTiers; // 每条能力词条的 1~10 档
        uint8[4] resourceTypes; // 已抽到的资源效果（RESOURCE_*）
        uint8 resourceCount; // 资源词条数量（0~4）
        uint32[8] skillIds; // 职业技 + 种族技 + 自选技
        uint8 skillCount;
        uint64 hp;
        uint64 maxHp;
        uint64 attack;
        uint64 magic;
        uint64 speed;
        uint16[4] abilityBonuses; // HP/物攻/魔攻/敏捷词条最终非负修正（千分比）
        uint16 manaDiscount; // 魔素消耗折扣
        uint16 apDiscount; // AP 消耗折扣
        uint16 apBonus; // 每回合 AP 产量加成
        int16 manaGainBonus; // 每回合魔素产量加成
        uint32 roomId; // 所在房间（0 = 不在房间）
    }
    mapping(uint256 => Character) public characters;
    uint256 public nextTokenId = 1;

    struct ClassDef {
        int64 baseHpPct; // 职业 HP 加成（千分比**增量**，与种族同约定：1000+mod 为乘数）
        int64 baseAttackPct; // 职业物攻加成（千分比增量）
        int64 baseMagicPct; // 职业魔攻加成（千分比增量）
        int64 baseSpeedPct; // 职业敏捷加成（千分比增量）
        uint8 skillSlots; // 职业额外自选槽（无职业 3 / 职业 1）
        bool exists; // 注册标记（职业增量可为 0，用 exists 区分未注册）
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

    /// @dev 一个模板对应一种能力；具体数值由 10 档表承载，第 1 档允许为 0（无加成）。
    struct AffixTemplate {
        uint8 statType; // ABILITY_HP / ABILITY_ATTACK / ABILITY_MAGIC / ABILITY_SPEED
        bool exists;
        uint16[10] tierWeights; // 档位 1~10 权重（千分比），高档应更低
        uint16[10] tierValues; // 档位 1~10 的加成值，上限 MAX_AFFIX_MOD
    }
    mapping(uint16 => AffixTemplate) public affixTemplates;
    uint16[4] public abilityAffixTemplateIds; // 按 ABILITY_* 索引

    /// @notice 首角色免费重掷计数器（playerId => 剩余次数；非道具、不可转移）
    mapping(address => uint8) public freeRerolls;
    /// @notice 首角色福利一次性领取标记（防「耗尽后新建角色再领」白嫖）
    mapping(address => bool) public firstRerollClaimed;

    /// @notice GM 测试入口开关（主网部署传 false 物理移除）
    bool public immutable gmEnabled;

    event CharacterCreated(uint256 indexed tokenId, address indexed owner, uint8 classId, uint8 race, uint16 level);
    event CharacterRerolled(uint256 indexed tokenId, address indexed owner);
    event AffixTemplateRegistered(uint16 indexed id, uint8 indexed statType);
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
        require(!classDefs[classId].exists, "CR: class exists");
        classDefs[classId] = def;
        classDefs[classId].exists = true;
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
        require(!affixTemplates[id].exists, "CR: affix exists");
        require(t.statType <= ABILITY_SPEED, "CR: bad stat type");

        uint256 totalWeight;
        for (uint8 i; i < MAX_AFFIX_TIER; ++i) {
            totalWeight += t.tierWeights[i];
            if (i > 0) require(t.tierValues[i] >= t.tierValues[i - 1], "CR: tier values not ordered");
            require(t.tierValues[i] <= MAX_AFFIX_MOD, "CR: ability bonus too high");
        }
        require(totalWeight > 0, "CR: empty tier weights");

        affixTemplates[id] = t;
        affixTemplates[id].exists = true;
        require(abilityAffixTemplateIds[t.statType] == 0, "CR: stat template exists");
        abilityAffixTemplateIds[t.statType] = id;
        emit AffixTemplateRegistered(id, t.statType);
    }

    function setRaceTierWeights(uint16[3] calldata w) external onlyOwner {
        raceTierWeights = w;
    }

    // ---- 创建 ----
    /// @notice 正常创建：种族、四项能力档位、资源词条数量与种类全部走 AFFIX RNG。
    function createCharacter(uint8 classId, uint32[] calldata skillIds) external returns (uint256 tokenId) {
        require(classDefs[classId].exists, "CR: unknown class");
        uint8 race = _rollRace(tokenId);
        uint16[4] memory affixIds;
        uint8[4] memory affixTiers;
        uint8[4] memory resourceTypes;
        uint8 resourceCount_ = _rollResourceAffixes(resourceTypes);
        _rollAbilityAffixes(affixIds, affixTiers);
        tokenId = _mintCharacter(msg.sender, classId, race, affixIds, affixTiers, resourceTypes, resourceCount_, skillIds);
        if (!firstRerollClaimed[msg.sender]) {
            firstRerollClaimed[msg.sender] = true;
            freeRerolls[msg.sender] = 3; // 首角色福利（一次性）
        }
        emit CharacterCreated(tokenId, msg.sender, classId, race, characters[tokenId].level);
    }

    /// @notice GM 测试入口：显式指定能力词条（按最高档计算），绕过 RNG/费用/限额/首角色判定（技术设计 §6.7）
    function gmMintCharacter(address to, uint8 classId, uint8 race, uint16[] calldata affixIds_, uint32[] calldata skillIds)
        external
        onlyOwner
        returns (uint256 tokenId)
    {
        require(gmEnabled, "CR: GM disabled");
        require(classDefs[classId].exists, "CR: unknown class");
        require(race < raceCount, "CR: unknown race");
        require(affixIds_.length <= 4, "CR: too many affixes");
        uint16[4] memory affixIds;
        uint8[4] memory affixTiers;
        for (uint8 i; i < affixIds_.length; ++i) {
            require(affixTemplates[affixIds_[i]].exists, "CR: unknown affix");
            affixIds[i] = affixIds_[i];
            affixTiers[i] = MAX_AFFIX_TIER;
        }
        uint8[4] memory noResources;
        tokenId = _mintCharacter(to, classId, race, affixIds, affixTiers, noResources, 0, skillIds);
        emit CharacterCreated(tokenId, to, classId, race, characters[tokenId].level);
    }

    /// @notice GM 测试入口：一次调用直接制造任意等级角色（能力值 = 1 级基准 × 等级线性插值；
    ///         满级 300 → 无加成角色 HP=30,000）。主网物理移除。
    function gmMintCharacterAtLevel(address to, uint8 classId, uint8 race, uint16[] calldata affixIds_, uint32[] calldata skillIds, uint16 level)
        external
        onlyOwner
        returns (uint256 tokenId)
    {
        require(gmEnabled, "CR: GM disabled");
        require(level >= 1 && level <= MAX_LEVEL, "CR: bad level");
        require(classDefs[classId].exists, "CR: unknown class");
        require(race < raceCount, "CR: unknown race");
        require(affixIds_.length <= 4, "CR: too many affixes");
        uint16[4] memory affixIds;
        uint8[4] memory affixTiers;
        for (uint8 i; i < affixIds_.length; ++i) {
            require(affixTemplates[affixIds_[i]].exists, "CR: unknown affix");
            affixIds[i] = affixIds_[i];
            affixTiers[i] = MAX_AFFIX_TIER;
        }
        uint8[4] memory noResources;
        tokenId = _mintCharacter(to, classId, race, affixIds, affixTiers, noResources, 0, skillIds);
        Character storage c = characters[tokenId];
        c.level = level;
        _computeStats(c, c.classId, c.race);
        c.hp = c.maxHp;
        emit CharacterCreated(tokenId, to, classId, race, c.level);
    }

    /// @notice GM 测试入口：设置等级并按等级公式重算属性（满级 = 1 级 × MAX_LEVEL 线性插值；主网物理移除）
    function gmSetLevel(uint256 tokenId, uint16 level) external onlyOwner {
        require(gmEnabled, "CR: GM disabled");
        require(level >= 1 && level <= MAX_LEVEL, "CR: bad level");
        Character storage c = characters[tokenId];
        c.level = level;
        _computeStats(c, c.classId, c.race);
        c.hp = c.maxHp;
    }

    function _mintCharacter(
        address to,
        uint8 classId,
        uint8 race,
        uint16[4] memory affixIds,
        uint8[4] memory affixTiers,
        uint8[4] memory resourceTypes,
        uint8 resourceCount_,
        uint32[] calldata skillIds
    ) private returns (uint256 tokenId) {
        require(skillIds.length <= MAX_SKILL_PER_CHAR, "CR: too many skills");
        tokenId = nextTokenId++;
        _safeMint(to, tokenId);
        Character storage c = characters[tokenId];
        c.classId = classId;
        c.race = race;
        c.level = 1;
        for (uint8 i; i < 4; ++i) {
            c.affixIds[i] = affixIds[i];
            c.affixTiers[i] = affixTiers[i];
            c.resourceTypes[i] = resourceTypes[i];
        }
        c.resourceCount = resourceCount_;
        _computeStats(c, classId, race);
        // 统一严格路径：职业/种族专属技自动并入，自选技仅限公共池且受槽数上限约束
        _mergeSkills(c, classId, race, skillIds);
        c.hp = c.maxHp;
    }

    /// @dev 属性从已存储的词条字段重算（幂等：transfer 重置等级时复用同一函数）。
    function _computeStats(Character storage c, uint8 classId, uint8 race) private {
        ClassDef memory def = classDefs[classId];
        RaceDef memory rd = raceDefs[race];
        // 职业/种族仍可有正负修正；词条能力修正保证非负（单档 0~2000‰，多条叠加不设个人封顶）。
        int64[3] memory mods = [int64(rd.statMods[0]), int64(rd.statMods[1]), int64(rd.statMods[2])];
        int64 hpMod = int64(rd.hpMod);

        for (uint8 j; j < 4; ++j) c.abilityBonuses[j] = 0;
        c.manaDiscount = 0;
        c.apDiscount = 0;
        c.apBonus = 0;
        c.manaGainBonus = 0;

        for (uint8 i; i < 4; ++i) {
            uint8 tier = c.affixTiers[i];
            if (tier == 0) continue; // GM 铸造未指定的槽位无词条
            require(tier <= MAX_AFFIX_TIER, "CR: bad affix tier");
            AffixTemplate memory t = affixTemplates[c.affixIds[i]];
            require(t.exists, "CR: unknown affix");
            // 同一能力多条词条时线性叠加，不设个人封顶
            c.abilityBonuses[t.statType] += t.tierValues[tier - 1];
        }
        for (uint8 i; i < c.resourceCount; ++i) {
            if (c.resourceTypes[i] == RESOURCE_AP_COST) c.apDiscount += 1;
            else if (c.resourceTypes[i] == RESOURCE_AP_PRODUCTION) c.apBonus += 1;
            else if (c.resourceTypes[i] == RESOURCE_MANA_COST) c.manaDiscount += 1;
            else c.manaGainBonus += 1;
        }

        hpMod += int64(int256(uint256(c.abilityBonuses[ABILITY_HP])));
        mods[0] += int64(int256(uint256(c.abilityBonuses[ABILITY_ATTACK])));
        mods[1] += int64(int256(uint256(c.abilityBonuses[ABILITY_MAGIC])));
        mods[2] += int64(int256(uint256(c.abilityBonuses[ABILITY_SPEED])));

        // 等级公式（先乘后除）：总加成 = 职业 + 种族 + 词条（千分比线性相加）
        c.maxHp = _calcStat(BASE_HP, def.baseHpPct + hpMod, c.level);
        c.attack = _calcStat(BASE_ATTACK, def.baseAttackPct + mods[0], c.level);
        c.magic = _calcStat(BASE_MAGIC, def.baseMagicPct + mods[1], c.level);
        c.speed = _calcStat(BASE_SPEED, def.baseSpeedPct + mods[2], c.level);
    }

    function _calcStat(uint64 base, int64 mod, uint16 level) internal pure returns (uint64) {
        int256 totalPct = 1000 + int256(mod);
        if (totalPct <= 0) return 0;
        uint256 full = uint256(base) * uint256(totalPct) * uint256(MAX_LEVEL) / 1000;
        uint256 v = full * uint256(level) / uint256(MAX_LEVEL);
        return uint64(v);
    }

    /// @dev 技能合并（统一严格路径）：先自动并入职业专属技（createCharacter 与 GM 铸造共用同一规则，
    ///     GM 只任意指定种族/词条等属性，技能合并无宽松路径），再并入种族技；
    ///     自选技仅允许公共池技（任何职业/种族专属技均自动发放，自选重复即拒绝），
    ///     数量受自选槽上限约束（职业 skillSlots + 人类 selfSelectBonus）。
    function _mergeSkills(Character storage c, uint8 classId, uint8 race, uint32[] calldata skillIds) private {
        uint8 n = 0;
        uint32[] memory cls = skillRegistry.getClassSkillIds(classId);
        for (uint256 i; i < cls.length; ++i) {
            require(skillRegistry.getSkill(cls[i]).id != 0, "CR: unknown class skill");
            c.skillIds[n++] = cls[i];
        }
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
        uint16 selfSelectMax = uint16(classDefs[classId].skillSlots) + uint16(raceDefs[race].selfSelectBonus);
        require(skillIds.length <= selfSelectMax, "CR: too many skills");
        for (uint256 i; i < skillIds.length; ++i) {
            uint32 sid = skillIds[i];
            require(skillRegistry.getSkill(sid).id != 0, "CR: unknown skill");
            require(!_isRaceSkill(sid), "CR: race skill locked");
            require(_isClassSkill(sid) == 0, "CR: class skill auto");
            c.skillIds[n++] = sid;
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

    /// @notice 四项能力各自独立抽取一条模板的档位（1~10，高档更稀有；第 1 档可为 0 加成）。
    function _rollAbilityAffixes(uint16[4] memory outIds, uint8[4] memory outTiers) private {
        for (uint8 stat; stat < 4; ++stat) {
            uint16 templateId = abilityAffixTemplateIds[stat];
            require(templateId != 0, "CR: missing ability template");
            outIds[stat] = templateId;
            outTiers[stat] = _rollTier(templateId, keccak256(abi.encodePacked("ability", stat)));
        }
    }

    /// @notice 先抽资源词条数量（0~MAX_RESOURCE_AFFIX_PER_CHAR 均匀），再为每条独立抽一种资源效果。
    function _rollResourceAffixes(uint8[4] memory outTypes) private returns (uint8 count) {
        count = uint8(rng.next(CATEGORY_AFFIX, keccak256("resourceCount")) % (MAX_RESOURCE_AFFIX_PER_CHAR + 1));
        for (uint8 slot; slot < count; ++slot) {
            outTypes[slot] = uint8(rng.next(CATEGORY_AFFIX, keccak256(abi.encodePacked("resourceType", slot))) % 4);
        }
    }

    function _rollTier(uint16 templateId, bytes32 context) private returns (uint8 tier) {
        AffixTemplate memory t = affixTemplates[templateId];
        uint256 total;
        for (uint8 i; i < MAX_AFFIX_TIER; ++i) total += t.tierWeights[i];
        uint256 roll = rng.next(CATEGORY_AFFIX, context) % total;
        for (uint8 i; i < MAX_AFFIX_TIER; ++i) {
            if (roll < t.tierWeights[i]) return i + 1;
            roll -= t.tierWeights[i];
        }
        return MAX_AFFIX_TIER;
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
            // 所有权变更 → 等级重置为 1，属性按等级 1 重算（幂等：_computeStats 先清零词条聚合字段）
            c.level = 1;
            _computeStats(c, c.classId, c.race);
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

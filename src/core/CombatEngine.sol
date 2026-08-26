// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SkillRegistry} from "./SkillRegistry.sol";
import {CharacterRegistry} from "./CharacterRegistry.sol";
import {Economy} from "./Economy.sol";
import {CombatTypes} from "../libs/CombatTypes.sol";
import {CombatLib} from "../libs/CombatLib.sol";

/// @title CombatEngine - 地下城/战斗核心结算器（入口层）
/// @notice 数据驱动：技能/敌人全部来自 SkillRegistry。战斗结算逻辑在 CombatLib/CombatEndLib
///         （EIP-170 拆库，DELEGATECALL 共享本合约存储，事件归属本合约地址）。
///         房间级魔素池与角色 AP 均跨战斗继承；命中判定三层管线（豁免/掷骰/未命中）；
///         死亡召唤（OnDeathSpawn）在胜利判定之前；道具金库为引擎内部账本（零 ERC 调用）。
///         房间内随机数采用房间级链式 PRNG（room.seed + PREVRANDAO，见 CombatTypes.nextRandom
///         与 docs/randomness-design.md）；高价值随机（抽卡/词条）走 RNGRouter（未来 VRF）。
contract CombatEngine is Ownable {
    SkillRegistry public immutable skillRegistry;
    CharacterRegistry public immutable characterRegistry;
    Economy public immutable economy;
    bytes32 public constant CATEGORY_COMBAT = keccak256("COMBAT");
    bytes32 public constant CATEGORY_DROP = keccak256("DROP");

    // ---- 常量（CombatTypes 同值副本，供 ABI/测试引用）----
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
    uint8 public constant KIND_MAGIC = 2;
    uint8 public constant KIND_SUPPORT = 3;
    uint8 public constant TGT_RAND_SINGLE_ENEMY = 1;
    uint8 public constant TGT_RAND_MULTI_ENEMY = 2;
    uint8 public constant TGT_RAND_STRIKE_ENEMY = 3;
    uint8 public constant TGT_ALL_ENEMY = 4;
    uint8 public constant TGT_RAND_SINGLE_ALLY = 5;
    uint8 public constant TGT_RAND_MULTI_ALLY = 6;
    uint8 public constant TGT_ALL_ALLY = 7;
    uint8 public constant TGT_ROOM_ALL = 8;
    uint8 public constant TGT_SELF = 9;
    uint8 public constant TGT_MOST_WOUNDED_ALLY = 10;
    uint8 public constant WT_UNIFORM = 0;
    uint8 public constant WT_HP_DEFICIT_ALLY = 1;
    uint8 public constant WT_THREAT_ENEMY = 2;
    uint8 public constant FLAG_GUARANTEED_HIT = 1;
    uint8 public constant SCOPE_SELF = 0;
    uint8 public constant SCOPE_TARGET = 1;
    uint8 public constant SCOPE_ALL_ALLY = 2;
    uint8 public constant SCOPE_ALL_ENEMY = 3;
    uint8 public constant PHASE_LOBBY = 0;
    uint8 public constant PHASE_COMBAT = 1;
    uint8 public constant PHASE_SETTLED = 2;
    uint8 public constant MAX_MEMBERS = 10;
    uint8 public constant MAX_ENEMIES = 10;
    uint8 public constant MAX_EFFECTS = 6;
    uint16 public constant MAX_PLAN = 16;

    /// @notice 全局命中下限（千分比，官方可调）
    uint16 public minHitRate = 50;

    /// @notice 全局基础 AP 上限（个人上限 = apCapBase + 角色 apCapBonus；官方可调）
    uint16 public apCapBase = 110;

    // ---- 运行时状态 ----
    mapping(uint32 => CombatTypes.Room) public rooms;
    uint32 public nextRoomId = 1;
    uint256 public constant MAX_ROOMS = 1000;

    // ---- 地下城配置 ----
    mapping(uint8 => CombatTypes.DungeonConfig) public dungeons;

    /// @notice 敌人构成表：tableId => 模板 id 列表 + 权重
    mapping(uint16 => uint16[]) public enemyTableTemplates;
    mapping(uint16 => uint16[]) public enemyTableWeights;

    /// @notice 变体敌人表：difficulty => (tableId, weight) 数组；开战一次掷骰选表
    mapping(uint8 => CombatTypes.VariantEntry[]) public dungeonVariants;

    // ---- 道具金库（引擎内部账本，零 ERC 调用）----
    mapping(uint32 => mapping(address => mapping(uint16 => uint32))) public vault;

    // ---- 事件（CombatLib 同签名重声明以补全 ABI；实际由库经 DELEGATECALL 发出）----
    event RoomCreated(uint32 indexed roomId, address indexed leader, uint8 difficulty);
    event MemberJoined(uint32 indexed roomId, address indexed player, uint256 characterId);
    event MemberLeft(uint32 indexed roomId, address indexed player);
    event CombatStarted(uint32 indexed roomId, uint32 turnId);
    event PlanSet(uint32 indexed roomId, address indexed player);
    event TurnAdvanced(uint32 indexed roomId, uint32 turnId);
    event UnitActed(uint32 indexed roomId, uint8 unitType, uint8 unitIndex, uint32 skillId);
    event DamageDealt(uint32 indexed roomId, uint8 targetType, uint8 targetIndex, uint64 amount, uint64 hpLeft, bool guaranteed);
    event Healed(uint32 indexed roomId, uint8 targetType, uint8 targetIndex, uint64 amount);
    event EffectApplied(uint32 indexed roomId, uint8 targetType, uint8 targetIndex, uint8 op, uint16 magnitude, uint8 duration);
    event UnitDied(uint32 indexed roomId, uint8 unitType, uint8 unitIndex);
    event EnemySpawned(uint32 indexed roomId, uint8 enemyIndex, uint16 templateId);
    event ManaChanged(uint32 indexed roomId, int32 delta, uint32 pool);
    event ResourceShort(uint32 indexed roomId, uint8 unitType, uint8 unitIndex, uint32 skillId);
    event Victory(uint32 indexed roomId);
    event Defeat(uint32 indexed roomId);
    event RewardDistributed(uint32 indexed roomId, address indexed player, uint256 amount);
    event ItemGiven(uint32 indexed roomId, address indexed from, address indexed to, uint16 itemId, uint32 count);
    event TimeoutPenalty(uint32 indexed roomId, uint8 unitType, uint8 unitIndex, uint64 amount);

    constructor(SkillRegistry skillRegistry_, CharacterRegistry characterRegistry_, Economy economy_) Ownable(msg.sender) {
        skillRegistry = skillRegistry_;
        characterRegistry = characterRegistry_;
        economy = economy_;
    }

    function _ctx() private view returns (CombatTypes.Ctx memory) {
        return CombatTypes.Ctx({skillRegistry: skillRegistry, characterRegistry: characterRegistry, economy: economy, minHitRate: minHitRate, apCapBase: apCapBase});
    }

    function setMinHitRate(uint16 rate) external onlyOwner {
        require(rate <= 1000, "CE: bad rate");
        minHitRate = rate;
    }

    function setApCapBase(uint16 cap) external onlyOwner {
        apCapBase = cap;
    }

    // ---- 地下城配置 ----
    function registerEnemyTable(uint16 tableId, uint16[] calldata templateIds, uint16[] calldata weights) external onlyOwner {
        require(templateIds.length > 0 && templateIds.length == weights.length, "CE: bad table");
        require(templateIds.length <= MAX_ENEMIES, "CE: table too big");
        delete enemyTableTemplates[tableId];
        delete enemyTableWeights[tableId];
        for (uint256 i; i < templateIds.length; ++i) {
            require(skillRegistry.getTemplate(templateIds[i]).aiId != 0 || skillRegistry.getTemplate(templateIds[i]).maxHp != 0, "CE: unknown template");
            enemyTableTemplates[tableId].push(templateIds[i]);
            enemyTableWeights[tableId].push(weights[i]);
        }
    }

    function setDungeon(uint8 difficulty, CombatTypes.DungeonConfig calldata cfg) external onlyOwner {
        require(difficulty >= 1 && difficulty <= 5, "CE: bad difficulty");
        require(enemyTableTemplates[cfg.tableId].length > 0, "CE: unknown table");
        dungeons[difficulty] = cfg;
    }

    function addDungeonVariant(uint8 difficulty, uint16 tableId, uint16 weight) external onlyOwner {
        require(enemyTableTemplates[tableId].length > 0, "CE: unknown table");
        dungeonVariants[difficulty].push(CombatTypes.VariantEntry({tableId: tableId, weight: weight}));
    }

    // ---- 房间生命周期 ----
    function createRoom(uint8 difficulty) external returns (uint32 roomId) {
        require(nextRoomId <= MAX_ROOMS, "CE: room cap");
        CombatTypes.DungeonConfig storage cfg = dungeons[difficulty];
        require(cfg.tableId != 0, "CE: unknown difficulty");
        roomId = nextRoomId++;
        CombatTypes.Room storage r = rooms[roomId];
        r.id = roomId;
        r.difficulty = difficulty;
        r.phase = PHASE_LOBBY;
        r.leader = msg.sender;
        r.manaPerTurn = cfg.manaPerTurn;
        r.turnInterval = cfg.turnInterval;
        r.createdAt = uint32(block.timestamp);
        r.lastTurnAt = uint32(block.number);
        // 房间随机种子：PREVRANDAO + 时间戳 + 创建者 + 房间号混合初始化（首次抽数会再混入 PREVRANDAO）
        r.seed = keccak256(abi.encodePacked(block.prevrandao, block.timestamp, msg.sender, roomId));
        emit RoomCreated(roomId, msg.sender, difficulty);
    }

    function joinRoom(uint32 roomId, uint256 characterId) external {
        CombatTypes.Room storage r = rooms[roomId];
        require(r.phase == PHASE_LOBBY, "CE: not lobby");
        require(r.memberCount < MAX_MEMBERS, "CE: room full");
        require(characterRegistry.ownerOf(characterId) == msg.sender, "CE: not owner");
        CharacterRegistry.Character memory c = characterRegistry.getCharacter(characterId);
        require(c.roomId == 0, "CE: char in room");
        CombatTypes.DungeonConfig storage cfg = dungeons[r.difficulty];
        if (cfg.entryFee > 0) economy.spend(msg.sender, cfg.entryFee); // 入场费销毁

        uint8 idx = r.memberCount;
        CombatTypes.RoomMember storage m = r.members[idx];
        m.characterId = characterId;
        m.player = msg.sender;
        m.hp = c.hp;
        m.maxHp = c.maxHp;
        m.attack = c.attack;
        m.magic = c.magic;
        m.speed = c.speed;
        m.ap = 0; // 加入房间时初始化 0（跨战斗继承从加入起算）
        m.manaDiscount = c.manaDiscount;
        m.apBonus = c.apBonus;
        m.manaGainBonus = c.manaGainBonus;
        m.apCapBonus = c.apCapBonus;
        m.classId = c.classId;
        m.alive = true;
        r.memberCount++;
        characterRegistry.setInRoom(characterId, roomId);
        emit MemberJoined(roomId, msg.sender, characterId);
    }

    function leaveRoom(uint32 roomId) external {
        CombatTypes.Room storage r = rooms[roomId];
        uint8 idx = CombatLib.findMember(r, msg.sender);
        require(idx != 255, "CE: not in room");
        CombatTypes.RoomMember storage m = r.members[idx];
        characterRegistry.setInRoom(m.characterId, 0);
        uint8 last = r.memberCount - 1;
        if (idx != last) r.members[idx] = r.members[last];
        delete r.members[last];
        r.memberCount--;
        emit MemberLeft(roomId, msg.sender);
    }

    function startCombat(uint32 roomId) external {
        CombatTypes.Room storage r = rooms[roomId];
        require(msg.sender == r.leader, "CE: not leader");
        require(r.phase == PHASE_LOBBY, "CE: not lobby");
        require(r.memberCount > 0, "CE: no members");
        CombatLib.spawnEnemies(_ctx(), r, enemyTableTemplates, enemyTableWeights, dungeons, dungeonVariants);
        r.phase = PHASE_COMBAT;
        r.turnId = 1;
        emit CombatStarted(roomId, r.turnId);
    }

    // ---- 技能计划 ----
    function setPlan(uint32 roomId, uint16[16] calldata plan, uint8 len) external {
        require(len <= MAX_PLAN, "CE: plan too long");
        CombatTypes.Room storage r = rooms[roomId];
        uint8 idx = CombatLib.findMember(r, msg.sender);
        require(idx != 255, "CE: not in room");
        CombatTypes.RoomMember storage m = r.members[idx];
        for (uint8 i; i < len; ++i) m.plan[i] = plan[i];
        m.planLen = len;
        m.planStart = 0;
        emit PlanSet(roomId, msg.sender);
    }

    function cancelPlan(uint32 roomId) external {
        CombatTypes.Room storage r = rooms[roomId];
        uint8 idx = CombatLib.findMember(r, msg.sender);
        require(idx != 255, "CE: not in room");
        r.members[idx].planLen = 0;
    }

    // ---- 道具金库 ----
    function giveItem(uint32 roomId, address to, uint16 itemId, uint32 count) external {
        CombatTypes.Room storage r = rooms[roomId];
        uint8 idx = CombatLib.findMember(r, msg.sender);
        require(idx != 255, "CE: giver not in room");
        require(count > 0, "CE: zero count");
        require(vault[roomId][msg.sender][itemId] >= count, "CE: insufficient");
        vault[roomId][msg.sender][itemId] -= count;
        vault[roomId][to][itemId] += count;
        emit ItemGiven(roomId, msg.sender, to, itemId, count);
    }

    function gmGiveItem(uint32 roomId, address to, uint16 itemId, uint32 count) external onlyOwner {
        vault[roomId][to][itemId] += count;
        emit ItemGiven(roomId, address(0), to, itemId, count);
    }

    function vaultBalance(uint32 roomId, address player, uint16 itemId) external view returns (uint32) {
        return vault[roomId][player][itemId];
    }

    // ---- 回合推进（Keeper/队长调用）----
    function advanceTurn(uint32 roomId) external {
        CombatTypes.Room storage r = rooms[roomId];
        require(r.phase == PHASE_COMBAT, "CE: not combat");
        CombatLib.advanceTurn(_ctx(), r, vault, dungeons);
    }

    // ---- 查询 ----
    function getRoom(uint32 roomId) external view returns (CombatTypes.Room memory) {
        return rooms[roomId];
    }

    function getMember(uint32 roomId, uint8 index) external view returns (CombatTypes.RoomMember memory) {
        return rooms[roomId].members[index];
    }

    function getEnemy(uint32 roomId, uint8 index) external view returns (CombatTypes.Enemy memory) {
        return rooms[roomId].enemies[index];
    }
}

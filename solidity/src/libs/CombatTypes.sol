// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SkillRegistry} from "../core/SkillRegistry.sol";
import {CharacterRegistry} from "../core/CharacterRegistry.sol";
import {Economy} from "../core/Economy.sol";

/// @title CombatTypes - 战斗结算共享类型与常量
/// @notice 由 CombatEngine 与 CombatLib/CombatEndLib 共享，保证存储布局一致（EIP-170 拆库）。
library CombatTypes {
    /// @notice 战斗上下文：外部依赖（CombatEngine 的 immutable/状态）经此传入
    struct Ctx {
        SkillRegistry skillRegistry;
        CharacterRegistry characterRegistry;
        Economy economy;
        uint16 minHitRate;
        uint16 apCapBase; // 全局 AP 上限（词条不再提供个人上限加成）
    }
    // ---- Effect op 枚举 ----
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

    // ---- targeting 模式 ----
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

    // ---- weightMode ----
    uint8 public constant WT_UNIFORM = 0;
    uint8 public constant WT_HP_DEFICIT_ALLY = 1;
    uint8 public constant WT_THREAT_ENEMY = 2;

    uint8 public constant FLAG_GUARANTEED_HIT = 1;
    uint8 public constant FLAG_MANA_ALL = 2; // 耗光房间魔素池，伤害 = power × 消耗魔素 / 1000（爆裂魔法）
    uint8 public constant FLAG_SUMMON_ALLY = 4; // bit2：SUMMON 召唤己方单位（替身人偶；默认 0 = 敌方召唤）

    // ---- Effect scope ----
    uint8 public constant SCOPE_SELF = 0;
    uint8 public constant SCOPE_TARGET = 1;
    uint8 public constant SCOPE_ALL_ALLY = 2;
    uint8 public constant SCOPE_ALL_ENEMY = 3;

    // ---- 房间阶段 ----
    uint8 public constant PHASE_LOBBY = 0;
    uint8 public constant PHASE_COMBAT = 1;
    uint8 public constant PHASE_SETTLED = 2;
    uint8 public constant PHASE_INTERMISSION = 3; // 一场战斗获胜后、下一场开战前（队长触发 advanceBattle 进入下一场）

    uint8 public constant MAX_MEMBERS = 10;
    uint8 public constant MAX_ENEMIES = 10;
    uint8 public constant MAX_EFFECTS = 6;
    uint16 public constant MAX_PLAN = 16;

    struct ActiveEffect {
        uint8 op;
        uint8 duration;
        uint16 magnitude;
        uint32 sourceId;
    }

    struct RoomMember {
        uint256 characterId;
        address player;
        uint64 hp;
        uint64 maxHp;
        uint64 attack;
        uint64 magic;
        uint64 speed;
        uint16 ap;
        uint16 manaDiscount; // 词条：魔素消耗折扣
        uint16 apDiscount; // 词条：AP 消耗折扣
        uint16 apBonus; // 词条：每回合 AP 产量加成
        int16 manaGainBonus; // 词条：每回合魔素产量加成
        uint8 classId;
        ActiveEffect[6] effects;
        uint8 effectCount;
        uint16[16] plan;
        uint8 planLen;
        uint8 planStart;
        bool alive;
        bool isSummon;
    }

    struct Enemy {
        uint16 templateId;
        uint64 hp;
        uint64 maxHp;
        uint64 attack;
        uint64 magic;
        uint64 speed;
        uint16 baseAcc;
        uint8 threat;
        uint16 aiId;
        uint8 turnCounter;
        ActiveEffect[6] effects;
        uint8 effectCount;
        bool alive;
    }

    struct Room {
        uint32 id;
        uint8 difficulty;
        uint8 phase;
        uint8 battleIndex; // 当前战斗（1-based；startCombat 后 = 1，advanceBattle 递增）
        uint8 totalBattles; // 本地下城总战斗场数（≥1；单场地下城 = 1，沿用旧语义直接进入 SETTLED）
        uint32 turnId;
        bytes32 seed;
        uint32 manaPool;
        uint32 manaPerTurn;
        uint16 rewardPool;
        uint8 memberCount;
        uint8 enemyCount;
        address leader;
        uint32 joinSeq;
        bool bossSpawned;
        uint32 createdAt;
        uint32 lastTurnAt;
        uint32 turnInterval;
        RoomMember[10] members;
        Enemy[10] enemies;
    }

    /// @notice 房间级链式随机数：newSeed = keccak256(seed, roomId, turnId, prevrandao)
    /// @dev 每次抽数推进一次种子，同回合多次抽数因链式递进而互不相同；
    ///      PREVRANDAO 提供区块级新鲜熵（低成本、可预测但不可操纵的信任模型，见 randomness-design）。
    function nextRandom(CombatTypes.Room storage r) internal returns (uint256) {
        r.seed = keccak256(abi.encodePacked(r.seed, r.id, r.turnId, block.prevrandao));
        return uint256(r.seed);
    }

    struct DungeonConfig {
        uint16 tableId;
        uint8 enemyCount;
        uint32 manaPerTurn;
        uint16 rewardBase;
        uint32 entryFee;
        uint32 rescueFee;
        uint32 turnInterval;
        uint8 battles; // 本地下城总战斗场数（0/1 = 单场，沿用旧语义）；>1 时逐场用 dungeonBattles
    }

    /// @notice 单场战斗配置（仅多场地下城用）：每场可覆盖敌人构成表与数量；全零 = 回退 DungeonConfig
    struct BattleConfig {
        uint16 tableId; // 本场敌人构成表（0 = 回退 DungeonConfig.tableId）
        uint8 enemyCount; // 本场敌人数量（0 = 回退 DungeonConfig.enemyCount）
    }

    struct VariantEntry {
        uint16 tableId;
        uint16 weight;
    }

    struct Target {
        uint8 kind;
        uint8 index;
    }
}

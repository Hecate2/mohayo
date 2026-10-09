// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SkillRegistry} from "../core/SkillRegistry.sol";
import {CombatTypes} from "./CombatTypes.sol";

/// @title CombatTargetLib - 目标选择逻辑库（EIP-170 拆库）
/// @notice 经 DELEGATECALL 在 CombatEngine 存储上下文执行。加权随机目标抽取、
///         嘲讽重定向、多段不重复抽取。计数辅助为内部副本（库间不可调用 internal）。
library CombatTargetLib {
    function selectTargets(CombatTypes.Room storage r, SkillRegistry.Skill memory s, uint8 actorType, uint8 actorIndex, bool actorIsEnemy) external returns (uint8 count, CombatTypes.Target[10] memory out) {
        uint8 targeting = s.targeting;
        if (targeting == CombatTypes.TGT_SELF) {
            out[count++] = CombatTypes.Target({kind: actorType, index: actorIndex});
            return (count, out);
        }
        if (targeting == CombatTypes.TGT_MOST_WOUNDED_ALLY) {
            uint8 best = pickMostWoundedAlly(r);
            if (best == 255) {
                if (actorType == 0) best = actorIndex; // 全员满血 → 施放者自己（空转）
                else return (count, out);
            }
            out[count++] = CombatTypes.Target({kind: 0, index: best});
            return (count, out);
        }
        if (targeting == CombatTypes.TGT_ROOM_ALL) {
            for (uint8 i; i < r.memberCount; ++i) if (r.members[i].alive) out[count++] = CombatTypes.Target({kind: 0, index: i});
            for (uint8 i; i < r.enemyCount; ++i) if (r.enemies[i].alive) out[count++] = CombatTypes.Target({kind: 1, index: i});
            return (count, out);
        }
        bool targetsEnemy = targeting == CombatTypes.TGT_RAND_SINGLE_ENEMY || targeting == CombatTypes.TGT_RAND_MULTI_ENEMY || targeting == CombatTypes.TGT_RAND_STRIKE_ENEMY || targeting == CombatTypes.TGT_ALL_ENEMY;
        bool enemyTarget = actorIsEnemy ? !targetsEnemy : targetsEnemy;
        if (targeting == CombatTypes.TGT_ALL_ENEMY || targeting == CombatTypes.TGT_ALL_ALLY) {
            if (enemyTarget) {
                for (uint8 i; i < r.enemyCount; ++i) if (r.enemies[i].alive) out[count++] = CombatTypes.Target({kind: 1, index: i});
            } else {
                for (uint8 i; i < r.memberCount; ++i) if (r.members[i].alive) out[count++] = CombatTypes.Target({kind: 0, index: i});
            }
            return (count, out);
        }
        uint8 need = 1;
        if (targeting == CombatTypes.TGT_RAND_MULTI_ENEMY || targeting == CombatTypes.TGT_RAND_MULTI_ALLY) need = s.targetCount;
        uint8 poolCount = enemyTarget ? aliveEnemyCount(r) : aliveMemberCount(r);
        if (need > poolCount) need = poolCount;
        for (uint8 k; k < need; ++k) {
            uint8 picked = pickWeighted(r, enemyTarget, s.weightMode);
            bool dup;
            for (uint8 j; j < count; ++j) {
                if (out[j].kind == (enemyTarget ? 1 : 0) && out[j].index == picked) { dup = true; break; }
            }
            if (dup) { k--; continue; }
            out[count++] = CombatTypes.Target({kind: enemyTarget ? 1 : 0, index: picked});
        }
        return (count, out);
    }

    function pickWeighted(CombatTypes.Room storage r, bool enemyTarget, uint8 weightMode) internal returns (uint8) {
        uint8 poolCount = enemyTarget ? aliveEnemyCount(r) : aliveMemberCount(r);
        require(poolCount > 0, "CE: empty pool");
        if (enemyTarget) {
            uint8 taunter = findTaunter(r);
            if (taunter != 255) return taunter;
        }
        uint256 total;
        uint256[10] memory weights;
        uint8 k;
        for (uint8 i; i < (enemyTarget ? r.enemyCount : r.memberCount); ++i) {
            if (enemyTarget) {
                if (!r.enemies[i].alive) continue;
                uint256 w = weightMode == CombatTypes.WT_THREAT_ENEMY ? r.enemies[i].threat : 1;
                weights[k++] = w;
                total += w;
            } else {
                if (!r.members[i].alive) continue;
                uint256 w = 1;
                if (weightMode == CombatTypes.WT_HP_DEFICIT_ALLY) w = r.members[i].maxHp - r.members[i].hp + 1;
                weights[k++] = w;
                total += w;
            }
        }
        uint256 roll = CombatTypes.nextRandom(r) % total;
        uint8 idx = 0;
        for (uint8 i; i < (enemyTarget ? r.enemyCount : r.memberCount); ++i) {
            if (enemyTarget) {
                if (!r.enemies[i].alive) continue;
                if (roll < weights[idx]) return i;
                roll -= weights[idx];
                idx++;
            } else {
                if (!r.members[i].alive) continue;
                if (roll < weights[idx]) return i;
                roll -= weights[idx];
                idx++;
            }
        }
        return 0;
    }

    function findTaunter(CombatTypes.Room storage r) internal view returns (uint8) {
        for (uint8 i; i < r.enemyCount; ++i) {
            if (!r.enemies[i].alive) continue;
            for (uint8 j; j < r.enemies[i].effectCount; ++j) {
                if (r.enemies[i].effects[j].op == CombatTypes.OP_TAUNT) return i;
            }
        }
        return 255;
    }

    /// @notice 治疗血量亏空绝对值最高者：绝对亏空 → 加入序（线性 argmax，零 RNG）
    function pickMostWoundedAlly(CombatTypes.Room storage r) internal view returns (uint8) {
        uint8 best = 255;
        uint64 bestDeficit;
        for (uint8 i; i < r.memberCount; ++i) {
            CombatTypes.RoomMember storage m = r.members[i];
            if (!m.alive) continue;
            uint64 deficit = m.maxHp - m.hp;
            if (deficit == 0) continue; // 满血跳过
            if (best == 255 || deficit > bestDeficit) {
                best = i;
                bestDeficit = deficit;
            }
        }
        return best;
    }

    function aliveMemberCount(CombatTypes.Room storage r) internal view returns (uint8) {
        uint8 n;
        for (uint8 i; i < r.memberCount; ++i) if (r.members[i].alive) n++;
        return n;
    }

    function aliveEnemyCount(CombatTypes.Room storage r) internal view returns (uint8) {
        uint8 n;
        for (uint8 i; i < r.enemyCount; ++i) if (r.enemies[i].alive) n++;
        return n;
    }
}

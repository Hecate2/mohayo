// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SkillRegistry} from "../core/SkillRegistry.sol";
import {CharacterRegistry} from "../core/CharacterRegistry.sol";
import {Economy} from "../core/Economy.sol";
import {CombatTypes} from "./CombatTypes.sol";
import {CombatLib} from "./CombatLib.sol";

/// @title CombatEndLib - 战斗结算逻辑库（胜负/奖励/释放/魔素回复）
/// @notice 经 DELEGATECALL 在 CombatEngine 存储上下文执行；事件归属 CombatEngine 地址。
library CombatEndLib {
    using CombatTypes for CombatTypes.Room;

    event Victory(uint32 indexed roomId);
    event Defeat(uint32 indexed roomId);
    event RewardDistributed(uint32 indexed roomId, address indexed player, uint256 amount);
    event ManaChanged(uint32 indexed roomId, int32 delta, uint32 pool);

    function regenMana(CombatTypes.Ctx memory ctx, CombatTypes.Room storage r) external {
        // int32 算术：魔素产量加成为非负小值，逐成员累加避免 uint32 溢出
        int32 gain = int32(uint32(r.manaPerTurn));
        for (uint8 i; i < r.memberCount; ++i) {
            if (r.members[i].alive) gain += int32(r.members[i].manaGainBonus);
        }
        if (gain > 0) {
            r.manaPool += uint32(gain);
            emit ManaChanged(r.id, gain, r.manaPool);
        }
    }

    function checkEnd(
        CombatTypes.Ctx memory ctx,
        CombatTypes.Room storage r,
        mapping(uint8 => CombatTypes.DungeonConfig) storage dungeons
    ) external {
        uint8 aliveEnemies;
        for (uint8 i; i < r.enemyCount; ++i) if (r.enemies[i].alive) aliveEnemies++;
        if (aliveEnemies == 0) {
            onVictory(ctx, r);
            return;
        }
        uint8 aliveMembers;
        for (uint8 i; i < r.memberCount; ++i) if (r.members[i].alive) aliveMembers++;
        if (aliveMembers == 0) {
            onDefeat(ctx, r, dungeons);
        }
    }

    function onVictory(CombatTypes.Ctx memory ctx, CombatTypes.Room storage r) internal {
        r.phase = CombatTypes.PHASE_SETTLED;
        emit Victory(r.id);
        uint8 n = CombatLib.aliveMemberCount(r);
        if (n > 0 && r.rewardPool > 0) {
            uint256 totalW;
            uint256[10] memory weights;
            uint8 k;
            for (uint8 i; i < r.memberCount; ++i) {
                if (!r.members[i].alive) continue;
                uint256 w = 1 + (CombatTypes.nextRandom(r) % 1000);
                weights[k++] = w;
                totalW += w;
            }
            uint256 distributed;
            for (uint8 i; i < k; ++i) {
                uint256 share = uint256(r.rewardPool) * weights[i] / totalW;
                ctx.economy.mint(r.members[i].player, share);
                distributed += share;
                emit RewardDistributed(r.id, r.members[i].player, share);
            }
            if (distributed < r.rewardPool) {
                ctx.economy.mint(r.leader, r.rewardPool - distributed);
                emit RewardDistributed(r.id, r.leader, r.rewardPool - distributed);
            }
        }
        releaseAll(ctx, r);
    }

    function onDefeat(
        CombatTypes.Ctx memory ctx,
        CombatTypes.Room storage r,
        mapping(uint8 => CombatTypes.DungeonConfig) storage dungeons
    ) internal {
        r.phase = CombatTypes.PHASE_SETTLED;
        emit Defeat(r.id);
        CombatTypes.DungeonConfig storage cfg = dungeons[r.difficulty];
        if (cfg.rescueFee > 0) {
            for (uint8 i; i < r.memberCount; ++i) {
                if (r.members[i].characterId != 0) ctx.economy.chargeRescueFee(r.members[i].player, cfg.rescueFee);
            }
        }
        releaseAll(ctx, r);
    }

    function releaseAll(CombatTypes.Ctx memory ctx, CombatTypes.Room storage r) internal {
        for (uint8 i; i < r.memberCount; ++i) {
            if (r.members[i].characterId != 0) ctx.characterRegistry.setInRoom(r.members[i].characterId, 0);
        }
    }
}

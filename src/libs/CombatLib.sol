// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SkillRegistry} from "../core/SkillRegistry.sol";
import {CharacterRegistry} from "../core/CharacterRegistry.sol";
import {Economy} from "../core/Economy.sol";
import {CombatTypes} from "./CombatTypes.sol";
import {CombatEndLib} from "./CombatEndLib.sol";
import {CombatTargetLib} from "./CombatTargetLib.sol";

/// @title CombatLib - 战斗结算逻辑库（EIP-170 拆库）
/// @notice 经 DELEGATECALL 在 CombatEngine 存储上下文执行；事件归属 CombatEngine 地址。
///         常量/结构体见 CombatTypes；结算（胜负/奖励/释放）见 CombatEndLib。
///         敌人表/地下城/金库等 CombatEngine 存储以 storage 指针参数传入。
library CombatLib {
    using CombatTypes for CombatTypes.Room;

    // ---- 事件（CombatEngine 同签名重声明以补全 ABI）----
    event RoomCreated(uint32 indexed roomId, address indexed leader, uint8 difficulty);
    event MemberJoined(uint32 indexed roomId, address indexed player, uint256 characterId);
    event MemberLeft(uint32 indexed roomId, address indexed player);
    event CombatStarted(uint32 indexed roomId, uint32 turnId, uint8 battleIndex);
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
    event BattleCleared(uint32 indexed roomId, uint8 battleIndex, uint8 totalBattles);
    event RewardDistributed(uint32 indexed roomId, address indexed player, uint256 amount);
    event ItemGiven(uint32 indexed roomId, address indexed from, address indexed to, uint16 itemId, uint32 count);
    event TimeoutPenalty(uint32 indexed roomId, uint8 unitType, uint8 unitIndex, uint64 amount);
    event MemberSummoned(uint32 indexed roomId, uint8 memberIndex, uint16 templateId);

    // ---- 敌人生成 ----
    function spawnEnemies(
        CombatTypes.Ctx memory ctx,
        CombatTypes.Room storage r,
        mapping(uint16 => uint16[]) storage templates,
        mapping(uint16 => uint16[]) storage weights,
        mapping(uint8 => CombatTypes.DungeonConfig) storage dungeons,
        mapping(uint8 => CombatTypes.BattleConfig[]) storage battleConfigs,
        mapping(uint8 => CombatTypes.VariantEntry[]) storage variants,
        mapping(uint8 => mapping(uint8 => CombatTypes.VariantEntry[])) storage battleVariants,
        uint8 battleIndex
    ) external {
        (uint16 tableId, uint8 count) = battleComposition(ctx, r, templates, dungeons, battleConfigs, variants, battleVariants, battleIndex);
        uint16[] storage tpl = templates[tableId];
        uint16[] storage wgt = weights[tableId];
        for (uint8 i; i < count && r.enemyCount < CombatTypes.MAX_ENEMIES; ++i) {
            uint16 templateId = weightedPick(tpl, wgt, ctx, r);
            spawnEnemy(ctx, r, templateId);
        }
    }

    /// @notice 解析某场战斗的敌人构成：优先逐场配置 dungeonsBattles，其次回退 DungeonConfig；
    ///         变体表优先逐场 battleVariants，其次第 1 场的 dungeonVariants，再回退默认表。
    function battleComposition(
        CombatTypes.Ctx memory ctx,
        CombatTypes.Room storage r,
        mapping(uint16 => uint16[]) storage templates,
        mapping(uint8 => CombatTypes.DungeonConfig) storage dungeons,
        mapping(uint8 => CombatTypes.BattleConfig[]) storage battleConfigs,
        mapping(uint8 => CombatTypes.VariantEntry[]) storage variants,
        mapping(uint8 => mapping(uint8 => CombatTypes.VariantEntry[])) storage battleVariants,
        uint8 battleIndex
    ) internal returns (uint16 tableId, uint8 count) {
        CombatTypes.DungeonConfig storage cfg = dungeons[r.difficulty];
        CombatTypes.BattleConfig memory bc;
        uint256 bcLen = battleConfigs[r.difficulty].length;
        if (bcLen > 0) {
            uint256 bi = battleIndex == 0 ? 0 : battleIndex - 1;
            if (bi < bcLen) bc = battleConfigs[r.difficulty][bi];
        }
        uint16 defaultTable = bc.tableId != 0 ? bc.tableId : cfg.tableId;
        count = bc.enemyCount != 0 ? bc.enemyCount : cfg.enemyCount;
        if (count == 0) count = uint8(templates[defaultTable].length);

        CombatTypes.VariantEntry[] storage v = battleVariants[r.difficulty][battleIndex];
        if (v.length == 0 && battleIndex == 1) v = variants[r.difficulty];
        if (v.length == 0) return (defaultTable, count);
        uint256 total;
        for (uint256 i; i < v.length; ++i) total += v[i].weight;
        uint256 roll = CombatTypes.nextRandom(r) % total;
        for (uint256 i; i < v.length; ++i) {
            if (roll < v[i].weight) return (v[i].tableId, count);
            roll -= v[i].weight;
        }
        return (defaultTable, count);
    }

    function spawnEnemy(CombatTypes.Ctx memory ctx, CombatTypes.Room storage r, uint16 templateId) internal returns (uint8 idx) {
        SkillRegistry.EnemyTemplate memory t = ctx.skillRegistry.getTemplate(templateId);
        idx = r.enemyCount;
        CombatTypes.Enemy storage e = r.enemies[idx];
        e.templateId = templateId;
        e.hp = t.maxHp;
        e.maxHp = t.maxHp;
        e.attack = t.power;
        e.magic = t.magic;
        e.speed = t.speed;
        e.baseAcc = t.baseAcc;
        e.threat = t.threat;
        e.aiId = t.aiId;
        e.alive = true;
        r.enemyCount++;
        emit EnemySpawned(r.id, idx, templateId);
    }

    // ---- 回合推进 ----
    function advanceTurn(
        CombatTypes.Ctx memory ctx,
        CombatTypes.Room storage r,
        mapping(uint32 => mapping(address => mapping(uint16 => uint32))) storage vault,
        mapping(uint8 => CombatTypes.DungeonConfig) storage dungeons
    ) external {
        checkTimeout(ctx, r);
        buildOrderAndAct(ctx, r, vault);
        CombatEndLib.regenMana(ctx, r);
        r.turnId++;
        r.lastTurnAt = uint32(block.number);
        emit TurnAdvanced(r.id, r.turnId);
        CombatEndLib.checkEnd(ctx, r, dungeons);
    }

    function checkTimeout(CombatTypes.Ctx memory ctx, CombatTypes.Room storage r) internal {
        if (r.turnInterval == 0) return;
        if (block.number - r.lastTurnAt > r.turnInterval) {
            for (uint8 i; i < r.memberCount; ++i) {
                CombatTypes.RoomMember storage m = r.members[i];
                if (!m.alive) continue;
                uint64 dmg = m.maxHp / 10;
                m.hp = m.hp > dmg ? m.hp - dmg : 0;
                emit TimeoutPenalty(r.id, 0, i, dmg);
                if (m.hp == 0) onMemberDeath(ctx, r, i);
            }
        }
    }

    function buildOrderAndAct(
        CombatTypes.Ctx memory ctx,
        CombatTypes.Room storage r,
        mapping(uint32 => mapping(address => mapping(uint16 => uint32))) storage vault
    ) internal {
        uint8[20] memory order;
        uint8 n;
        for (uint8 i; i < r.memberCount; ++i) if (r.members[i].alive) order[n++] = i;
        for (uint8 i; i < r.enemyCount; ++i) if (r.enemies[i].alive) order[n++] = 100 + i;
        for (uint8 i = 1; i < n; ++i) {
            uint8 key = order[i];
            uint64 keySpeed = speedOf(r, key);
            uint8 j = i;
            while (j > 0) {
                uint8 prev = order[j - 1];
                uint64 prevSpeed = speedOf(r, prev);
                if (prevSpeed >= keySpeed) break;
                order[j] = prev;
                j--;
            }
            order[j] = key;
        }
        for (uint8 i; i < n; ++i) {
            uint8 u = order[i];
            if (u < 100) {
                CombatTypes.RoomMember storage m = r.members[u];
                if (!m.alive) continue;
                (m.hp, m.effectCount) = tickEffects(ctx, r, m.effects, m.effectCount, m.hp, m.maxHp, m.attack, m.speed, 0, u);
                if (m.hp == 0) onMemberDeath(ctx, r, u);
                if (!m.alive) continue;
                if (isStunned(m.effects, m.effectCount)) continue;
                // 资源词条：每回合 AP 产量加成（行动前结算，受全局上限钳制；被控时暂停）
                if (m.apBonus > 0) {
                    m.ap += m.apBonus;
                    if (m.ap > ctx.apCapBase) m.ap = ctx.apCapBase;
                }
                if (m.planLen == 0) continue;
                uint16 skillId = m.plan[m.planStart];
                m.planStart = (m.planStart + 1) % m.planLen; // 无限循环：队列走完回到队首
                executeMemberSkill(ctx, r, m, u, skillId, vault);
            } else {
                uint8 ei = u - 100;
                CombatTypes.Enemy storage e = r.enemies[ei];
                if (!e.alive) continue;
                (e.hp, e.effectCount) = tickEffects(ctx, r, e.effects, e.effectCount, e.hp, e.maxHp, e.attack, e.speed, 1, ei);
                if (e.hp == 0) onEnemyDeath(ctx, r, ei);
                if (!e.alive) continue;
                if (isStunned(e.effects, e.effectCount)) continue;
                SkillRegistry.MonsterAI memory ai = ctx.skillRegistry.getAI(e.aiId);
                if (ai.cycleLen == 0) continue;
                uint16 skillId = ai.skillCycle[e.turnCounter % ai.cycleLen];
                e.turnCounter++;
                executeEnemySkill(ctx, r, e, ei, skillId);
            }
        }
    }

    function speedOf(CombatTypes.Room storage r, uint8 u) internal view returns (uint64) {
        if (u < 100) return r.members[u].speed;
        return r.enemies[u - 100].speed;
    }

    // ---- 效果结算 ----
    function tickEffects(
        CombatTypes.Ctx memory ctx,
        CombatTypes.Room storage r,
        CombatTypes.ActiveEffect[6] storage effects,
        uint8 effectCount,
        uint64 hp,
        uint64 maxHp,
        uint64 attack,
        uint64 speed,
        uint8 unitType,
        uint8 unitIndex
    ) internal returns (uint64 newHp, uint8 newCount) {
        newHp = hp;
        newCount = effectCount;
        uint8 i = 0;
        while (i < newCount) {
            CombatTypes.ActiveEffect storage e = effects[i];
            if (e.op == CombatTypes.OP_DOT) {
                uint64 dmg = e.magnitude;
                newHp = newHp > dmg ? newHp - dmg : 0;
                emit DamageDealt(r.id, unitType, unitIndex, dmg, newHp, true);
            }
            if (e.duration > 0) e.duration--;
            if (e.duration == 0) {
                removeEffect(effects, newCount, i);
                newCount--;
            } else {
                i++;
            }
        }
    }

    function isStunned(CombatTypes.ActiveEffect[6] storage effects, uint8 effectCount) internal view returns (bool) {
        for (uint8 i; i < effectCount; ++i) {
            if (effects[i].op == CombatTypes.OP_STUN && effects[i].duration > 0) return true;
        }
        return false;
    }

    function removeEffect(CombatTypes.ActiveEffect[6] storage effects, uint8 effectCount, uint8 index) internal {
        for (uint8 i = index; i + 1 < effectCount; ++i) effects[i] = effects[i + 1];
        delete effects[effectCount - 1];
    }

    function applyEffect(
        CombatTypes.ActiveEffect[6] storage effects,
        uint8 effectCount,
        uint8 op,
        uint8 duration,
        uint16 magnitude,
        uint32 sourceId
    ) internal returns (uint8 newCount) {
        if (op == CombatTypes.OP_ACC_DOWN || op == CombatTypes.OP_EVADE_UP || op == CombatTypes.OP_DMG_OUT_MOD || op == CombatTypes.OP_DMG_IN_MOD) {
            for (uint8 i; i < effectCount; ++i) {
                if (effects[i].op == op) {
                    effects[i].magnitude += magnitude;
                    if (duration > effects[i].duration) effects[i].duration = duration;
                    return effectCount;
                }
            }
        }
        if (op == CombatTypes.OP_GUAR_NEXT) {
            for (uint8 i; i < effectCount; ++i) {
                if (effects[i].op == op) {
                    effects[i].duration = duration;
                    return effectCount;
                }
            }
        }
        if (op == CombatTypes.OP_TAUNT) {
            for (uint8 i; i < effectCount; ++i) {
                if (effects[i].op == op) {
                    effects[i].magnitude = magnitude;
                    effects[i].duration = duration;
                    effects[i].sourceId = sourceId;
                    return effectCount;
                }
            }
        }
        if (effectCount >= CombatTypes.MAX_EFFECTS) return effectCount;
        effects[effectCount] = CombatTypes.ActiveEffect({op: op, duration: duration, magnitude: magnitude, sourceId: sourceId});
        return effectCount + 1;
    }

    // ---- 技能执行 ----
    function executeMemberSkill(
        CombatTypes.Ctx memory ctx,
        CombatTypes.Room storage r,
        CombatTypes.RoomMember storage m,
        uint8 mi,
        uint16 skillId,
        mapping(uint32 => mapping(address => mapping(uint16 => uint32))) storage vault
    ) internal {
        SkillRegistry.Skill memory s = ctx.skillRegistry.getSkill(skillId);
        if (s.id == 0) return;
        (bool ok, uint32 manaConsumed) = checkAndDeductMember(ctx, r, m, s, vault);
        if (!ok) {
            emit ResourceShort(r.id, 0, mi, skillId);
            return;
        }
        resolveSkill(ctx, r, m.effects, m.effectCount, m.hp, m.maxHp, m.attack, m.magic, m.speed, 0, mi, s, m.player, false, manaConsumed);
    }

    function checkAndDeductMember(
        CombatTypes.Ctx memory ctx,
        CombatTypes.Room storage r,
        CombatTypes.RoomMember storage m,
        SkillRegistry.Skill memory s,
        mapping(uint32 => mapping(address => mapping(uint16 => uint32))) storage vault
    ) internal returns (bool ok, uint32 manaConsumed) {
        uint16 apCost = s.apCost;
        uint16 effApCost = apCost > m.apDiscount ? apCost - m.apDiscount : 0;
        uint32 manaCost = s.manaCost;
        uint32 effMana;
        if ((s.flags & CombatTypes.FLAG_MANA_ALL) != 0) {
            effMana = r.manaPool; // 耗光整个房间魔素池
        } else {
            effMana = manaCost > m.manaDiscount ? manaCost - m.manaDiscount : 0;
        }
        if (m.ap < effApCost) return (false, 0);
        if (r.manaPool < effMana) return (false, 0);
        if (s.ammoId != 0 && vault[r.id][m.player][s.ammoId] < s.ammoCost) return (false, 0);
        if (s.hpCost > 0 && m.hp <= s.hpCost) return (false, 0);
        m.ap -= effApCost;
        r.manaPool -= effMana;
        if (s.ammoId != 0) vault[r.id][m.player][s.ammoId] -= s.ammoCost;
        if (s.hpCost > 0) m.hp -= s.hpCost;
        return (true, effMana);
    }

    function executeEnemySkill(CombatTypes.Ctx memory ctx, CombatTypes.Room storage r, CombatTypes.Enemy storage e, uint8 ei, uint16 skillId) internal {
        SkillRegistry.Skill memory s = ctx.skillRegistry.getSkill(skillId);
        if (s.id == 0) return;
        if (s.manaCost > 0 && r.manaPool < s.manaCost) {
            emit ResourceShort(r.id, 1, ei, skillId);
            return;
        }
        if (s.manaCost > 0) r.manaPool -= s.manaCost;
        resolveSkill(ctx, r, e.effects, e.effectCount, e.hp, e.maxHp, e.attack, e.magic, e.speed, 1, ei, s, address(0), true, 0);
    }

    // ---- 技能统一结算 ----
    function resolveSkill(
        CombatTypes.Ctx memory ctx,
        CombatTypes.Room storage r,
        CombatTypes.ActiveEffect[6] storage actorEffects,
        uint8 actorEffectCount,
        uint64 hp,
        uint64 maxHp,
        uint64 attack,
        uint64 magic,
        uint64 speed,
        uint8 actorType,
        uint8 actorIndex,
        SkillRegistry.Skill memory s,
        address actorPlayer,
        bool actorIsEnemy,
        uint32 manaConsumed
    ) internal {
        emit UnitActed(r.id, actorType, actorIndex, s.id);

        bool allyTargeting = isAllyTargeting(s.targeting, actorIsEnemy);
        bool guaranteed = allyTargeting || s.targeting == CombatTypes.TGT_ROOM_ALL || (s.flags & CombatTypes.FLAG_GUARANTEED_HIT) != 0 || hasGuarNext(actorEffects, actorEffectCount);

        uint8 strikes = (s.targeting == CombatTypes.TGT_RAND_STRIKE_ENEMY) ? s.targetCount : 1;
        uint64 totalDamage;
        bool anyHit;
        for (uint8 st; st < strikes; ++st) {
            (uint8 tCount, CombatTypes.Target[10] memory targets) = CombatTargetLib.selectTargets(r, s, actorType, actorIndex, actorIsEnemy);
            for (uint8 k; k < tCount; ++k) {
                CombatTypes.Target memory t = targets[k];
                uint64 dealt = resolveTarget(ctx, r, actorEffects, actorEffectCount, hp, maxHp, attack, magic, speed, actorType, actorIndex, s, actorPlayer, t, guaranteed, allyTargeting, manaConsumed);
                totalDamage += dealt;
                if (dealt > 0) anyHit = true;
            }
        }
        if (anyHit && s.apGain > 0) {
            if (actorType == 0) r.members[actorIndex].ap += s.apGain;
        }
    }

    function resolveTarget(
        CombatTypes.Ctx memory ctx,
        CombatTypes.Room storage r,
        CombatTypes.ActiveEffect[6] storage actorEffects,
        uint8 actorEffectCount,
        uint64 hp,
        uint64 maxHp,
        uint64 attack,
        uint64 magic,
        uint64 speed,
        uint8 actorType,
        uint8 actorIndex,
        SkillRegistry.Skill memory s,
        address actorPlayer,
        CombatTypes.Target memory t,
        bool guaranteed,
        bool allyTargeting,
        uint32 manaConsumed
    ) internal returns (uint64 dealt) {
        if (!guaranteed) {
            uint256 acc = s.baseAcc;
            acc = subAccDown(actorEffects, actorEffectCount, acc);
            if (t.kind == 0) acc = subEvadeUp(r.members[t.index].effects, r.members[t.index].effectCount, acc);
            else acc = subEvadeUp(r.enemies[t.index].effects, r.enemies[t.index].effectCount, acc);
            if (acc < ctx.minHitRate) acc = ctx.minHitRate;
            uint256 roll = CombatTypes.nextRandom(r) % 1000;
            if (roll >= acc) return 0;
        }

        uint64 tHp;
        uint64 tMaxHp;
        CombatTypes.ActiveEffect[6] storage tEffects;
        uint8 tEffectCount;
        if (t.kind == 0) {
            CombatTypes.RoomMember storage tm = r.members[t.index];
            if (!tm.alive) return 0;
            tHp = tm.hp;
            tMaxHp = tm.maxHp;
            tEffects = tm.effects;
            tEffectCount = tm.effectCount;
        } else {
            CombatTypes.Enemy storage te = r.enemies[t.index];
            if (!te.alive) return 0;
            tHp = te.hp;
            tMaxHp = te.maxHp;
            tEffects = te.effects;
            tEffectCount = te.effectCount;
        }

        if (s.power > 0) {
            if (allyTargeting && s.kind == CombatTypes.KIND_SUPPORT) {
                uint64 heal = uint64(uint256(s.power) * magic / 1000);
                healTarget(ctx, r, t, tHp, tMaxHp, heal);
                dealt = heal;
            } else {
                uint64 stat;
                if ((s.flags & CombatTypes.FLAG_MANA_ALL) != 0) {
                    stat = uint64(manaConsumed); // 伤害基数 = 本次耗光的魔素量
                } else {
                    stat = (s.kind == CombatTypes.KIND_MAGIC) ? magic : attack;
                }
                dealt = computeDamage(ctx, r, s, stat, actorEffects, actorEffectCount, tEffects, tEffectCount);
                dealDamage(ctx, r, t, dealt, guaranteed);
            }
        }

        for (uint8 i; i < s.effectCount; ++i) {
            SkillRegistry.Effect memory e = s.effects[i];
            if (e.prob < 1000) {
                uint256 pr = CombatTypes.nextRandom(r) % 1000;
                if (pr >= e.prob) continue;
            }
            applySkillEffect(ctx, r, actorEffects, actorEffectCount, actorType, actorIndex, s, t, tEffects, tEffectCount, attack, magic, e, dealt, actorPlayer);
            // 刷新计数：同一技能多个效果可能作用于同一单位，计数需与存储同步（否则后效果覆盖前效果）
            actorEffectCount = (actorType == 0) ? r.members[actorIndex].effectCount : r.enemies[actorIndex].effectCount;
            tEffectCount = (t.kind == 0) ? r.members[t.index].effectCount : r.enemies[t.index].effectCount;
        }

        if (t.kind == 0) {
            if (r.members[t.index].hp == 0) onMemberDeath(ctx, r, t.index);
        } else {
            if (r.enemies[t.index].hp == 0) onEnemyDeath(ctx, r, t.index);
        }
    }

    function applySkillEffect(
        CombatTypes.Ctx memory ctx,
        CombatTypes.Room storage r,
        CombatTypes.ActiveEffect[6] storage actorEffects,
        uint8 actorEffectCount,
        uint8 actorType,
        uint8 actorIndex,
        SkillRegistry.Skill memory s,
        CombatTypes.Target memory t,
        CombatTypes.ActiveEffect[6] storage tEffects,
        uint8 tEffectCount,
        uint64 attack,
        uint64 magic,
        SkillRegistry.Effect memory e,
        uint64 dealt,
        address actorPlayer
    ) internal {
        uint8 op = e.op;
        uint8 duration = e.duration;
        uint16 magnitude = e.magnitude;
        uint8 scope = e.scope;

        // 魔力护盾：kind=MAGIC 的 SHIELD 盾量 = power × 魔攻 / 1000（法系越强盾越厚）
        if (op == CombatTypes.OP_SHIELD && s.kind == CombatTypes.KIND_MAGIC) {
            magnitude = uint16(uint256(s.power) * magic / 1000);
        }

        if (op == CombatTypes.OP_HEAL) {
            if (scope == CombatTypes.SCOPE_SELF) {
                healTarget(ctx, r, CombatTypes.Target({kind: actorType, index: actorIndex}), hpOf(r, actorType, actorIndex), maxHpOf(r, actorType, actorIndex), magnitude);
            } else {
                healTarget(ctx, r, t, hpOf(r, t.kind, t.index), maxHpOf(r, t.kind, t.index), magnitude);
            }
            return;
        }
        if (op == CombatTypes.OP_MANA_DELTA) {
            int32 delta = int32(uint32(magnitude));
            if (scope == CombatTypes.SCOPE_TARGET) delta = -delta;
            manaDelta(ctx, r, delta);
            return;
        }
        if (op == CombatTypes.OP_DISPEL) {
            dispel(tEffects, tEffectCount);
            return;
        }
        if (op == CombatTypes.OP_LIFESTEAL) {
            if (dealt > 0) {
                uint64 heal = uint64(uint256(dealt) * magnitude / 1000);
                healTarget(ctx, r, CombatTypes.Target({kind: actorType, index: actorIndex}), hpOf(r, actorType, actorIndex), maxHpOf(r, actorType, actorIndex), heal);
            }
            return;
        }
        if (op == CombatTypes.OP_SUMMON) {
            doSummon(ctx, r, s, actorType, actorIndex);
            return;
        }

        if (scope == CombatTypes.SCOPE_SELF) {
            setEffect(ctx, r, actorEffects, actorEffectCount, actorType, actorIndex, op, duration, magnitude, s.id);
        } else if (scope == CombatTypes.SCOPE_TARGET) {
            setEffect(ctx, r, tEffects, tEffectCount, t.kind, t.index, op, duration, magnitude, s.id);
        } else if (scope == CombatTypes.SCOPE_ALL_ALLY) {
            if (actorType == 0) {
                for (uint8 i; i < r.memberCount; ++i) if (r.members[i].alive) setEffect(ctx, r, r.members[i].effects, r.members[i].effectCount, 0, i, op, duration, magnitude, s.id);
            } else {
                for (uint8 i; i < r.enemyCount; ++i) if (r.enemies[i].alive) setEffect(ctx, r, r.enemies[i].effects, r.enemies[i].effectCount, 1, i, op, duration, magnitude, s.id);
            }
        } else if (scope == CombatTypes.SCOPE_ALL_ENEMY) {
            if (actorType == 0) {
                for (uint8 i; i < r.enemyCount; ++i) if (r.enemies[i].alive) setEffect(ctx, r, r.enemies[i].effects, r.enemies[i].effectCount, 1, i, op, duration, magnitude, s.id);
            } else {
                for (uint8 i; i < r.memberCount; ++i) if (r.members[i].alive) setEffect(ctx, r, r.members[i].effects, r.members[i].effectCount, 0, i, op, duration, magnitude, s.id);
            }
        }
    }

    function setEffect(CombatTypes.Ctx memory ctx, CombatTypes.Room storage r, CombatTypes.ActiveEffect[6] storage effects, uint8 effectCount, uint8 unitType, uint8 unitIndex, uint8 op, uint8 duration, uint16 magnitude, uint32 sourceId) internal {
        uint8 nc = applyEffect(effects, effectCount, op, duration, magnitude, sourceId);
        if (unitType == 0) r.members[unitIndex].effectCount = nc;
        else r.enemies[unitIndex].effectCount = nc;
        emit EffectApplied(r.id, unitType, unitIndex, op, magnitude, duration);
    }

    function doSummon(CombatTypes.Ctx memory ctx, CombatTypes.Room storage r, SkillRegistry.Skill memory s, uint8 actorType, uint8 actorIndex) internal {
        SkillRegistry.SummonRule memory rule = s.summon;
        if (rule.templateId == 0) return;
        if ((s.flags & CombatTypes.FLAG_SUMMON_ALLY) != 0) {
            doSummonAllied(ctx, r, rule);
            return;
        }
        uint8 e = aliveEnemyCount(r);
        uint8 p = aliveMemberCount(r);
        if (e >= p + rule.enemyHeadroom || r.enemyCount >= CombatTypes.MAX_ENEMIES) return;
        uint8 toSpawn = rule.maxCount;
        uint8 headroom = p + rule.enemyHeadroom > e ? p + rule.enemyHeadroom - e : 0;
        if (toSpawn > headroom) toSpawn = headroom;
        for (uint8 i; i < toSpawn && r.enemyCount < CombatTypes.MAX_ENEMIES; ++i) {
            spawnEnemy(ctx, r, rule.templateId);
        }
    }

    /// @dev 玩家侧召唤（替身人偶）：有血量、无行动的己方假目标，计入我方随机目标集、
    ///     不参与收益分配、无主（player=0）、无法被 setPlan；上限 MAX_MEMBERS 封顶 gas。
    function doSummonAllied(CombatTypes.Ctx memory ctx, CombatTypes.Room storage r, SkillRegistry.SummonRule memory rule) internal {
        uint8 toSpawn = rule.maxCount;
        for (uint8 i; i < toSpawn && r.memberCount < CombatTypes.MAX_MEMBERS; ++i) {
            SkillRegistry.EnemyTemplate memory t = ctx.skillRegistry.getTemplate(rule.templateId);
            CombatTypes.RoomMember storage m = r.members[r.memberCount];
            m.characterId = 0;
            m.player = address(0); // 无主召唤物，不参与收益分配
            m.hp = t.maxHp;
            m.maxHp = t.maxHp;
            m.attack = t.power;
            m.magic = t.magic;
            m.speed = t.speed;
            m.ap = 0;
            m.classId = 0;
            m.effectCount = 0;
            m.planLen = 0;
            m.alive = true;
            m.isSummon = true;
            r.memberCount++;
            emit MemberSummoned(r.id, r.memberCount - 1, rule.templateId);
        }
    }

    // ---- 伤害 ----
    function computeDamage(
        CombatTypes.Ctx memory ctx,
        CombatTypes.Room storage r,
        SkillRegistry.Skill memory s,
        uint64 stat,
        CombatTypes.ActiveEffect[6] storage actorEffects,
        uint8 actorEffectCount,
        CombatTypes.ActiveEffect[6] storage tEffects,
        uint8 tEffectCount
    ) internal returns (uint64) {
        uint256 dmg = uint256(s.power) * stat / 1000;
        // 钳制先于乘区：damageCap 只压基础伤害，狂暴/龙鳞的乘区加成可突破单次伤害上限（用户定案）
        if (s.damageCap != 0 && dmg > s.damageCap) dmg = s.damageCap;
        uint256 outMod = sumMod(actorEffects, actorEffectCount, CombatTypes.OP_DMG_OUT_MOD);
        if (outMod != 0) dmg = dmg * (1000 + outMod) / 1000;
        uint256 inMod = sumMod(tEffects, tEffectCount, CombatTypes.OP_DMG_IN_MOD);
        if (inMod != 0) dmg = dmg * (1000 + inMod) / 1000;
        return uint64(dmg);
    }

    function dealDamage(CombatTypes.Ctx memory ctx, CombatTypes.Room storage r, CombatTypes.Target memory t, uint64 dmg, bool guaranteed) internal {
        if (t.kind == 0) {
            CombatTypes.RoomMember storage m = r.members[t.index];
            if (!m.alive) return;
            dmg = applyShield(m.effects, m.effectCount, dmg);
            m.hp = m.hp > dmg ? m.hp - dmg : 0;
            emit DamageDealt(r.id, 0, t.index, dmg, m.hp, guaranteed);
        } else {
            CombatTypes.Enemy storage e = r.enemies[t.index];
            if (!e.alive) return;
            dmg = applyShield(e.effects, e.effectCount, dmg);
            e.hp = e.hp > dmg ? e.hp - dmg : 0;
            emit DamageDealt(r.id, 1, t.index, dmg, e.hp, guaranteed);
        }
    }

    function applyShield(CombatTypes.ActiveEffect[6] storage effects, uint8 effectCount, uint64 dmg) internal returns (uint64 remaining) {
        remaining = dmg;
        for (uint8 i; i < effectCount; ++i) {
            if (effects[i].op != CombatTypes.OP_SHIELD) continue;
            if (effects[i].magnitude >= remaining) {
                effects[i].magnitude -= uint16(remaining);
                remaining = 0;
                break;
            } else {
                remaining -= effects[i].magnitude;
                effects[i].magnitude = 0;
            }
        }
        return remaining;
    }

    function healTarget(CombatTypes.Ctx memory ctx, CombatTypes.Room storage r, CombatTypes.Target memory t, uint64 hp, uint64 maxHp, uint64 amount) internal {
        if (t.kind == 0) {
            CombatTypes.RoomMember storage m = r.members[t.index];
            if (!m.alive) return;
            uint64 heal = maxHp - hp > amount ? amount : maxHp - hp;
            m.hp += heal;
            emit Healed(r.id, 0, t.index, heal);
        } else {
            CombatTypes.Enemy storage e = r.enemies[t.index];
            if (!e.alive) return;
            uint64 heal = maxHp - hp > amount ? amount : maxHp - hp;
            e.hp += heal;
            emit Healed(r.id, 1, t.index, heal);
        }
    }

    function manaDelta(CombatTypes.Ctx memory ctx, CombatTypes.Room storage r, int32 delta) internal {
        if (delta > 0) {
            r.manaPool += uint32(delta);
        } else {
            uint32 d = uint32(-delta);
            r.manaPool = r.manaPool > d ? r.manaPool - d : 0;
        }
        emit ManaChanged(r.id, delta, r.manaPool);
    }

    function dispel(CombatTypes.ActiveEffect[6] storage effects, uint8 effectCount) internal {
        uint8 i = 0;
        while (i < effectCount) {
            uint8 op = effects[i].op;
            if (isDispellable(op)) {
                removeEffect(effects, effectCount, i);
                effectCount--;
            } else {
                i++;
            }
        }
    }

    function isDispellable(uint8 op) internal pure returns (bool) {
        return op == CombatTypes.OP_STUN || op == CombatTypes.OP_SHIELD || op == CombatTypes.OP_ACC_DOWN || op == CombatTypes.OP_EVADE_UP || op == CombatTypes.OP_GUAR_NEXT || op == CombatTypes.OP_TAUNT || op == CombatTypes.OP_DOT || op == CombatTypes.OP_DMG_OUT_MOD || op == CombatTypes.OP_DMG_IN_MOD;
    }

    // ---- 死亡结算 ----
    /// @notice 队长接任：取数组序最小的存活真人成员（非傀儡）为队长；
    ///         summoned 单位（isSummon）与无主召唤物不参与，即使全部阵亡也保持原队长（房间已宣告Defeat）。
    function reassignLeader(CombatTypes.Room storage r) external {
        for (uint8 i; i < r.memberCount; ++i) {
            CombatTypes.RoomMember storage m = r.members[i];
            if (m.alive && !m.isSummon && m.player != address(0) && m.characterId != 0) {
                r.leader = m.player;
                return;
            }
        }
    }

    /// @notice 战斗间清场：清除本场全部敌人与成员身上跨越战斗不应保留的增益/减益/控制效果；
    ///         保留成员生命/AP、房间魔素池与累计 rewardPool（跨战斗继承资源）。
    function clearBattleField(CombatTypes.Room storage r) external {
        r.enemyCount = 0;
        for (uint8 i; i < CombatTypes.MAX_ENEMIES; ++i) delete r.enemies[i];
        for (uint8 i; i < r.memberCount; ++i) {
            for (uint8 j; j < r.members[i].effectCount; ++j) delete r.members[i].effects[j];
            r.members[i].effectCount = 0;
        }
    }

    function onMemberDeath(CombatTypes.Ctx memory ctx, CombatTypes.Room storage r, uint8 mi) internal {
        CombatTypes.RoomMember storage m = r.members[mi];
        if (!m.alive) return;
        bool wasLeader = !m.isSummon && m.player == r.leader;
        m.alive = false;
        m.effectCount = 0;
        emit UnitDied(r.id, 0, mi);
        // 队长战死 → 按进入地下城的顺序（数组序）在存活真人中自动接任；傀儡不可当队长
        if (wasLeader) {
            for (uint8 i; i < r.memberCount; ++i) {
                CombatTypes.RoomMember storage nm = r.members[i];
                if (nm.alive && !nm.isSummon && nm.player != address(0) && nm.characterId != 0) {
                    r.leader = nm.player;
                    return;
                }
            }
        }
    }

    function onEnemyDeath(CombatTypes.Ctx memory ctx, CombatTypes.Room storage r, uint8 ei) internal {
        CombatTypes.Enemy storage e = r.enemies[ei];
        if (!e.alive) return;
        e.alive = false;
        e.effectCount = 0;
        emit UnitDied(r.id, 1, ei);
        SkillRegistry.EnemyTemplate memory t = ctx.skillRegistry.getTemplate(e.templateId);
        uint256 reward = t.rewardMin;
        if (t.rewardMax > t.rewardMin) {
            reward += CombatTypes.nextRandom(r) % (t.rewardMax - t.rewardMin + 1);
        }
        r.rewardPool += uint16(reward);
        SkillRegistry.OnDeathSpawn memory ods = t.onDeathSpawn;
        if (ods.templateId != 0 && ods.prob != 0) {
            uint256 roll = CombatTypes.nextRandom(r) % 1000;
            if (roll < ods.prob) {
                r.bossSpawned = true;
                for (uint8 i; i < ods.count && r.enemyCount < CombatTypes.MAX_ENEMIES; ++i) {
                    spawnEnemy(ctx, r, ods.templateId);
                }
            }
        }
    }

    // ---- 命中辅助 ----
    function isAllyTargeting(uint8 targeting, bool actorIsEnemy) internal pure returns (bool) {
        if (targeting == CombatTypes.TGT_SELF || targeting == CombatTypes.TGT_ROOM_ALL || targeting == CombatTypes.TGT_MOST_WOUNDED_ALLY) return true;
        // 目标落在施法方侧（我方）= 必中管道（治疗/增益豁免命中掷骰）；否则按 baseAcc 掷骰（可 miss）。
        // 注意：targeting 枚举以玩家视角命名（ENEMY = 玩家敌人 = 怪物侧）。怪物用 ENEMY 系技能实际命中玩家，
        // 此时目标在怪物对侧 → 非 allyTargeting → 允许因 baseAcc<1000 而 miss（机神火花炮 baseAcc 900）。
        return !(targeting == CombatTypes.TGT_RAND_SINGLE_ENEMY || targeting == CombatTypes.TGT_RAND_MULTI_ENEMY || targeting == CombatTypes.TGT_RAND_STRIKE_ENEMY || targeting == CombatTypes.TGT_ALL_ENEMY);
    }

    function hasGuarNext(CombatTypes.ActiveEffect[6] storage effects, uint8 effectCount) internal view returns (bool) {
        for (uint8 i; i < effectCount; ++i) {
            if (effects[i].op == CombatTypes.OP_GUAR_NEXT && effects[i].duration > 0) return true;
        }
        return false;
    }

    function subAccDown(CombatTypes.ActiveEffect[6] storage effects, uint8 effectCount, uint256 acc) internal view returns (uint256) {
        for (uint8 i; i < effectCount; ++i) {
            if (effects[i].op == CombatTypes.OP_ACC_DOWN) acc = acc > effects[i].magnitude ? acc - effects[i].magnitude : 0;
        }
        return acc;
    }

    function subEvadeUp(CombatTypes.ActiveEffect[6] storage effects, uint8 effectCount, uint256 acc) internal view returns (uint256) {
        for (uint8 i; i < effectCount; ++i) {
            if (effects[i].op == CombatTypes.OP_EVADE_UP) acc = acc > effects[i].magnitude ? acc - effects[i].magnitude : 0;
        }
        return acc;
    }

    function sumMod(CombatTypes.ActiveEffect[6] storage effects, uint8 effectCount, uint8 op) internal view returns (uint256) {
        uint256 sum;
        for (uint8 i; i < effectCount; ++i) {
            if (effects[i].op == op) sum += effects[i].magnitude;
        }
        return sum;
    }

    // ---- 计数 ----
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

    function findMember(CombatTypes.Room storage r, address player) internal view returns (uint8) {
        for (uint8 i; i < r.memberCount; ++i) {
            if (r.members[i].player == player) return i;
        }
        return 255;
    }

    function hpOf(CombatTypes.Room storage r, uint8 kind, uint8 index) internal view returns (uint64) {
        return kind == 0 ? r.members[index].hp : r.enemies[index].hp;
    }

    function maxHpOf(CombatTypes.Room storage r, uint8 kind, uint8 index) internal view returns (uint64) {
        return kind == 0 ? r.members[index].maxHp : r.enemies[index].maxHp;
    }

    function weightedPick(uint16[] storage ids, uint16[] storage weights, CombatTypes.Ctx memory ctx, CombatTypes.Room storage r) internal returns (uint16) {
        uint256 total;
        for (uint256 i; i < weights.length; ++i) total += weights[i];
        uint256 roll = CombatTypes.nextRandom(r) % total;
        for (uint256 i; i < ids.length; ++i) {
            if (roll < weights[i]) return ids[i];
            roll -= weights[i];
        }
        return ids[ids.length - 1];
    }
}

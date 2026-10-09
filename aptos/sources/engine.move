/// Mohayo combat engine — Aptos Move rewrite.
/// Uses types, skill_registry, character, economy modules.
module mohayo::engine {
    use aptos_framework::event;
    use aptos_framework::randomness;
    use aptos_std::table::{Self, Table};
    use std::option::{Self, Option};
    use std::signer;
    use std::vector;
    use mohayo::types::{Self, Skill, Member, Enemy, Target};
    use mohayo::skill_registry;
    use mohayo::character;
    use mohayo::item;
    use mohayo::economy;
    use mohayo::use_item;

    const E_ROOM_NOT_FOUND: u64 = 3;
    const E_BAD_INDEX: u64 = 4;
    const E_NOT_LOBBY: u64 = 7;
    const E_NOT_COMBAT: u64 = 8;
    const E_NOT_JOINABLE: u64 = 9;
    const E_ROOM_FULL: u64 = 10;
    const E_NO_MEMBERS: u64 = 14;
    const E_NOT_LEADER: u64 = 6;
    const E_NOT_INTERMISSION: u64 = 17;
    const E_LAST_BATTLE: u64 = 18;
    const E_NOT_PLAN_OWNER: u64 = 19;
    const E_SKILL_NOT_OWNED: u64 = 20;
    const E_CANNOT_ESCAPE: u64 = 21;
    const E_ALREADY_GONE: u64 = 22;
    const E_SUMMON_NO_ESCAPE: u64 = 23;
    const E_TURN_MISMATCH: u64 = 24;
    const E_ADVANCE_COOLDOWN: u64 = 25;
    const E_NOT_EMERGENCY: u64 = 26;
    const E_ROOM_CLOSED: u64 = 27;
    const E_NOT_EXPIRED: u64 = 28;
    /// 该角色已在某个房间内(§2.6.11 复审: 防同一角色跨房双开覆盖角色锁)
    const E_CHAR_IN_ROOM: u64 = 29;
    /// 房间未进入终态、或终态保留窗口还没过(§2.6.12 房间回收)
    const E_NOT_RECLAIMABLE: u64 = 30;

    /// 个人逃离的延迟回合数(§6.2「若干回合后」；数值层可调)
    const ESCAPE_DELAY: u64 = 3;
    /// 中途加入的到场延迟回合数(§4.5-5；数值层可调)
    const JOIN_DELAY: u64 = 3;
    /// 一个自然周 = 604800 秒(§3.4 周常变异按周快照)
    const WEEK_SECS: u64 = 604800;
    /// 推进冷却(秒)：§3.1「距上次推进 ≥ 2 区块」——等价为 ≥2 秒的墙钟冷却
    const TURN_COOLDOWN_SECS: u64 = 2;
    /// 兜底推进门槛(秒)：§3.1「距上次推进 ≥ 30 区块」后任何人都可解卡
    const EMERGENCY_SECS: u64 = 30;
    /// 慷慨周(MUT_DROP)单次结算最多额外掷骰次数(防 GM 误配置把结算循环拉爆)
    const MAX_DROP_ROLLS: u64 = 100;
    /// 房间进入终态后的**保留窗口**(秒)：窗口内仍可读结算结果，过后任何人可回收(§2.6.12)
    const DEFAULT_RECLAIM_DELAY: u64 = 3600;

    // ---- 房间结果(room_result) ----
    public fun RESULT_NONE(): u8 { 0 }     // 未结算
    public fun RESULT_VICTORY(): u8 { 1 }  // 通关整座地下城
    public fun RESULT_DEFEAT(): u8 { 2 }   // 全队被击败 / 超时清退 / 停摆过期
    public fun RESULT_RETREAT(): u8 { 3 }  // 队长在间歇期发起全员逃离（提前收工，不算通关）

    // ---- 周常变异种类(§3.4「只采纳便宜实现」) ----
    public fun MUT_NONE(): u8 { 0 }
    public fun MUT_MANA(): u8 { 1 }   // 魔素丰潮: 每回合魔素增量 +value
    public fun MUT_FOG(): u8 { 2 }    // 迷雾周: 敌人命中 −value‰
    public fun MUT_STORM(): u8 { 3 }  // 疾风连击: 多段技 +value 段(封顶 8)
    public fun MUT_HP(): u8 { 4 }     // 巨物/脆皮: 敌人生命 ±value‰(带符号)
    public fun MUT_DROP(): u8 { 5 }   // 慷慨/吝啬: value>0 额外掉落掷骰次数; <0 不掉落

    // ============================ resource ============================

    struct RoomStore has key {
        rooms: Table<u64, Room>,
        /// 存活房间 id 列表（回收时 swap-remove）。链上 Table 不可遍历，
        /// 客户端靠这个列表 + 分页视图枚举房间（§2.6.14）。
        active: vector<u64>,
        /// room_id → 在 `active` 里的下标（swap-remove 用）
        active_index: Table<u64, u64>,
        /// 未开始房间的闲置过期时长(秒, §3.1 默认 2 小时, GM 可调)
        room_ttl: u64,
        /// 终态房间的保留窗口(秒, §2.6.12 默认 1 小时, GM 可调) —— 过后任何人可回收
        reclaim_delay: u64,
        /// 自然周 → 当周变异(§3.4: 创建房间时快照当周, 周中变更不影响已创建房间)
        weekly_mutators: Table<u64, Mutator>,
    }

    struct Mutator has copy, drop, store {
        kind: u8,
        value: i64,
    }

    /// 房间全部状态。`drop` 是必需的：`table::remove` 会把值交还给调用方，
    /// 而回收房间(§2.6.12)就是要显式销毁它。
    struct Room has drop, store {
        id: u64,
        difficulty: u8,
        phase: u8,
        battle_index: u64,
        total_battles: u64,
        battle_turns: u64,
        turn_id: u64,
        result: u8,
        mana_pool: u64,
        mana_per_turn: u64,
        mana_all_consumed: u64,
        reward_pool: u64,
        /// 创建时间(秒)与关闭标记(§3.1 闲置过期 / 队长解散)
        created_secs: u64,
        closed: bool,
        /// 进入终态的时刻(秒, §2.6.12)：closed 置位时或结算完成时写入，用于回收窗口计时
        end_secs: u64,
        mutator_kind: u8,
        mutator_value: i64,
        leader: address,
        /// 距上次推进的时间戳(秒) —— 推进冷却(§4.1 防重复推进)
        last_advance_secs: u64,
        rng_seed: u64,
        members: vector<Member>,
        enemies: vector<Enemy>,
    }

    // ============================ events ============================

    #[event]
    struct RoomCreated has drop, store { room_id: u64, leader: address }
    #[event]
    struct MemberJoined has drop, store { room_id: u64, player: address }
    #[event]
    struct MemberLeft has drop, store { room_id: u64, player: address }
    #[event]
    struct CombatStarted has drop, store { room_id: u64, turn_id: u64 }
    #[event]
    struct PlanSet has drop, store { room_id: u64, player: address }

    #[event]
    struct ItemUsed has drop, store {
        room_id: u64,
        player: address,
        item_type: u64,
        effect_kind: u8,
        value: u64,
    }

    #[event]
    struct TurnAdvanced has drop, store { room_id: u64, turn_id: u64, seed: u64 }
    #[event]
    struct UnitActed has drop, store { room_id: u64, is_enemy: bool, index: u64, skill_id: u64 }
    #[event]
    struct DamageDealt has drop, store { room_id: u64, is_enemy: bool, index: u64, amount: u64, hp_left: u64 }
    #[event]
    struct HealedEvt has drop, store { room_id: u64, is_enemy: bool, index: u64, amount: u64 }
    #[event]
    struct EffectApplied has drop, store { room_id: u64, is_enemy: bool, index: u64, op: u8, magnitude: u16, duration: u8 }
    #[event]
    struct UnitDied has drop, store { room_id: u64, is_enemy: bool, index: u64 }
    #[event]
    struct EnemySpawned has drop, store { room_id: u64, index: u64, template_id: u64 }
    #[event]
    struct ManaChanged has drop, store { room_id: u64, pool: u64 }
    #[event]
    struct VictoryEvt has drop, store { room_id: u64 }
    #[event]
    struct DefeatEvt has drop, store { room_id: u64 }
    #[event]
    struct BattleCleared has drop, store { room_id: u64, battle_index: u64, total_battles: u64 }
    #[event]
    struct BattleAdvanced has drop, store { room_id: u64, new_battle_index: u64 }
    #[event]
    struct SmokeApplied has drop, store { room_id: u64, magnitude: u64, duration: u8 }
    #[event]
    struct UnitRevived has drop, store { room_id: u64, index: u64, hp: u64 }
    #[event]
    struct MemberEscaped has drop, store { room_id: u64, player: address }
    #[event]
    struct LeaderChanged has drop, store { room_id: u64, new_leader: address }
    #[event]
    struct RewardPaid has drop, store { room_id: u64, player: address, amount: u64 }
    #[event]
    struct RewardForfeited has drop, store { room_id: u64, amount: u64 }
    #[event]
    struct RescuePaid has drop, store { room_id: u64, player: address, amount: u64 }
    #[event]
    struct RunRetreated has drop, store { room_id: u64 }
    #[event]
    struct ItemDropped has drop, store { room_id: u64, player: address, item_type: u64, amount: u64 }
    #[event]
    struct MemberArrived has drop, store { room_id: u64, index: u64 }
    #[event]
    struct MutatorSnapshot has drop, store { room_id: u64, kind: u8, value: i64 }
    #[event]
    struct RoomClosed has drop, store { room_id: u64, reason: u8 }
    #[event]
    struct RoomReclaimed has drop, store { room_id: u64 }

    // ============================ init ============================

    fun init_module(account: &signer) {
        move_to(account, RoomStore {
            rooms: table::new(),
            active: vector::empty(),
            active_index: table::new(),
            room_ttl: 7200,
            reclaim_delay: DEFAULT_RECLAIM_DELAY,
            weekly_mutators: table::new(),
        });
    }

    // ============================ 房间关闭 / 回收(§3.1, §2.6.12) ============================

    /// 房间进入终态(结算完成)：置 phase/result，并记录终态时刻供回收窗口计时(§2.6.12)。
    fun mark_settled(room: &mut Room, result: u8) {
        room.phase = 2;
        room.result = result;
        room.end_secs = aptos_framework::timestamp::now_seconds();
    }

    /// 释放房间内所有**玩家成员**的角色锁，不记履历 —— 用于关房/回收这类「这一局还没打完」的场景。
    fun unlock_members(room: &Room) {
        let n = vector::length(&room.members);
        let i = 0;
        while (i < n) {
            let m = vector::borrow(&room.members, i);
            if (!types::member_is_summon(m)) {
                let cid = types::member_char_id(m);
                if (cid != 0) { character::lock_room(cid, 0); };
            };
            i = i + 1;
        };
    }

    /// 房间是否已过终态保留窗口、可被回收(§2.6.12)。
    fun is_reclaimable(room: &Room, delay: u64): bool {
        (room.closed || room.phase == 2)
            && aptos_framework::timestamp::now_seconds() >= room.end_secs + delay
    }

    /// 队长在**大厅期**解散房间(§3.1)。关房即释放成员角色锁，成员不必再自己调 `leave_room`。
    public entry fun disband_room(account: &signer, room_id: u64) acquires RoomStore {
        let addr = signer::address_of(account);
        let rs = borrow_global_mut<RoomStore>(@mohayo);
        let room = table::borrow_mut(&mut rs.rooms, room_id);
        assert!(room.phase == 0, E_NOT_LOBBY);
        ensure_leader(room, room_id);
        assert!(can_advance(room, addr), E_NOT_LEADER);
        // 幂等(§2.6.15): 重复解散不刷新 end_secs, 避免回收窗口被无限推迟
        if (room.closed) { return; };
        room.closed = true;
        room.end_secs = aptos_framework::timestamp::now_seconds();
        unlock_members(room);
        event::emit(RoomClosed { room_id, reason: 1 }); // 1 = 队长解散
    }

    /// 闲置过期(§3.1 / §2.6.12)：**任何人**可触发（与 Keeper 同权限，无特权）。两种情形：
    /// - 大厅期(phase 0)：开房后一直未开始、闲置超过 `room_ttl` → 关闭并释放成员角色锁。
    /// - 战斗期(phase 1)：距上次推进超过 `room_ttl`（Keeper 长期停摆 / 全队弃房）→
    ///   按既有**超时规则**收尾（扣救援费 + 记未通关履历），房间进入终态。
    /// 已结算房间不走这里，等回收窗口过后直接 `reclaim_room`。
    public entry fun expire_room(account: &signer, room_id: u64) acquires RoomStore {
        let _ = account;
        let now = aptos_framework::timestamp::now_seconds();
        let rs = borrow_global_mut<RoomStore>(@mohayo);
        let ttl = rs.room_ttl;
        let room = table::borrow_mut(&mut rs.rooms, room_id);
        if (room.phase == 0) {
            assert!(now >= room.created_secs + ttl, E_NOT_EXPIRED);
            // 幂等(§2.6.15): 已关闭的房间不再刷新 end_secs
            if (!room.closed) {
                room.closed = true;
                room.end_secs = now;
                unlock_members(room);
                event::emit(RoomClosed { room_id, reason: 2 }); // 2 = 大厅闲置过期
            };
        } else if (room.phase == 1) {
            assert!(now >= room.last_advance_secs + ttl, E_NOT_EXPIRED);
            settle_timeout(room, room_id);                  // 与回合上限清退同一条路径
            room.closed = true;
            event::emit(RoomClosed { room_id, reason: 3 }); // 3 = 战斗期停摆过期
        } else {
            assert!(false, E_NOT_EXPIRED);                  // 已结算 → 走 reclaim_room
        };
    }

    /// 回收一个已过终态保留窗口的房间(§2.6.12)。**任何人**可触发。
    /// 先从表里摘除，房间号**不重用**（`Registry.next_room_id` 只增），
    /// 因此客户端缓存与 `rng_seed` 派生规则都不会错位。
    public entry fun reclaim_room(account: &signer, room_id: u64) acquires RoomStore {
        let _ = account;
        let rs = borrow_global_mut<RoomStore>(@mohayo);
        assert!(table::contains(&rs.rooms, room_id), E_ROOM_NOT_FOUND);
        let delay = rs.reclaim_delay;
        {
            let room = table::borrow_mut(&mut rs.rooms, room_id);
            assert!(is_reclaimable(room, delay), E_NOT_RECLAIMABLE);
            unlock_members(room); // 兜底：终态房间理论上已解锁，重复置 0 无害
        };
        table::remove(&mut rs.rooms, room_id);
        room_list_remove(rs, room_id);
        event::emit(RoomReclaimed { room_id });
    }

    /// GM 调整闲置过期时长(秒)
    public entry fun set_room_ttl(account: &signer, secs: u64) acquires RoomStore {
        assert!(signer::address_of(account) == @mohayo, E_NOT_LEADER);
        borrow_global_mut<RoomStore>(@mohayo).room_ttl = secs;
    }

    /// GM 调整终态房间的保留窗口(秒)
    public entry fun set_reclaim_delay(account: &signer, secs: u64) acquires RoomStore {
        assert!(signer::address_of(account) == @mohayo, E_NOT_LEADER);
        borrow_global_mut<RoomStore>(@mohayo).reclaim_delay = secs;
    }

    #[view]
    public fun room_closed(room_id: u64): bool acquires RoomStore {
        let rs = borrow_global<RoomStore>(@mohayo);
        assert!(table::contains(&rs.rooms, room_id), E_ROOM_NOT_FOUND);
        table::borrow(&rs.rooms, room_id).closed
    }

    #[view]
    public fun room_ttl(): u64 acquires RoomStore {
        borrow_global<RoomStore>(@mohayo).room_ttl
    }

    /// 把房间登记进活跃列表
    fun room_list_add(rs: &mut RoomStore, room_id: u64) {
        let i = vector::length(&rs.active);
        vector::push_back(&mut rs.active, room_id);
        table::add(&mut rs.active_index, room_id, i);
    }

    /// 从活跃列表摘除（swap-remove，O(1)）。房间号不重用，所以列表只减不增地淘汰旧的。
    fun room_list_remove(rs: &mut RoomStore, room_id: u64) {
        let i = *table::borrow(&rs.active_index, room_id);
        let last = vector::length(&rs.active) - 1;
        if (i != last) {
            let moved = *vector::borrow(&rs.active, last);
            *vector::borrow_mut(&mut rs.active, i) = moved;
            *table::borrow_mut(&mut rs.active_index, moved) = i;
        };
        vector::pop_back(&mut rs.active);
        table::remove(&mut rs.active_index, room_id);
    }

    /// 存活房间数（含已结算但还没被回收的）
    #[view]
    public fun active_room_count(): u64 acquires RoomStore {
        vector::length(&borrow_global<RoomStore>(@mohayo).active)
    }

    /// 分页枚举存活房间 id：先读 `active_room_count()`，再逐下标取(§2.6.14)
    #[view]
    public fun active_room_at(i: u64): u64 acquires RoomStore {
        let rs = borrow_global<RoomStore>(@mohayo);
        assert!(i < vector::length(&rs.active), E_BAD_INDEX);
        *vector::borrow(&rs.active, i)
    }

    /// 该房间号是否还在链上（回收后为 false）
    #[view]
    public fun room_exists(room_id: u64): bool acquires RoomStore {
        table::contains(&borrow_global<RoomStore>(@mohayo).rooms, room_id)
    }

    /// 该房间是否已过终态保留窗口、可被 `reclaim_room` 回收(§2.6.12)
    #[view]
    public fun room_reclaimable(room_id: u64): bool acquires RoomStore {
        let rs = borrow_global<RoomStore>(@mohayo);
        assert!(table::contains(&rs.rooms, room_id), E_ROOM_NOT_FOUND);
        is_reclaimable(table::borrow(&rs.rooms, room_id), rs.reclaim_delay)
    }

    #[view]
    public fun reclaim_delay(): u64 acquires RoomStore {
        borrow_global<RoomStore>(@mohayo).reclaim_delay
    }

    // ============================ 周常变异(§3.4) ============================

    /// 设定某一自然周的变异(GM 专用; 运营方每周经短时间锁切换一次)。
    /// kind 见 MUT_*; value 语义随 kind(增量/千分比/段数/额外掷骰次数, 带符号)。
    public entry fun set_weekly_mutator(account: &signer, week: u64, kind: u8, value: i64) acquires RoomStore {
        assert!(signer::address_of(account) == @mohayo, E_NOT_LEADER);
        let rs = borrow_global_mut<RoomStore>(@mohayo);
        let m = Mutator { kind, value };
        if (table::contains(&rs.weekly_mutators, week)) {
            *table::borrow_mut(&mut rs.weekly_mutators, week) = m;
        } else {
            table::add(&mut rs.weekly_mutators, week, m);
        };
    }

    public fun week_of(secs: u64): u64 { secs / WEEK_SECS }

    fun mutator_for_week(week: u64): Mutator acquires RoomStore {
        let rs = borrow_global<RoomStore>(@mohayo);
        if (!table::contains(&rs.weekly_mutators, week)) {
            return Mutator { kind: MUT_NONE(), value: 0 }
        };
        *table::borrow(&rs.weekly_mutators, week)
    }

    #[view]
    public fun current_mutator(): (u8, i64) acquires RoomStore {
        let m = mutator_for_week(week_of(aptos_framework::timestamp::now_seconds()));
        (m.kind, m.value)
    }

    #[view]
    public fun room_mutator(room_id: u64): (u8, i64) acquires RoomStore {
        let rs = borrow_global<RoomStore>(@mohayo);
        assert!(table::contains(&rs.rooms, room_id), E_ROOM_NOT_FOUND);
        let r = table::borrow(&rs.rooms, room_id);
        (r.mutator_kind, r.mutator_value)
    }

    // ============================ room lifecycle ============================

    public entry fun create_room(account: &signer, difficulty: u64) acquires RoomStore {
        let addr = signer::address_of(account);
        let dungeon = skill_registry::get_dungeon(difficulty);
        // 参与次数门控(§2.6.14 用户定案): **开房直接计为一次加入** —— 同一账号 24h 内
        // 「开房 + 加入」的总次数受限, 创建泛滥因此也被窗口封顶。
        // 入场费(§3.1): 付费图开房即扣、直接销毁；余额不足则整笔交易回滚
        use_item::consume_entry(addr);
        let entry_fee = types::dungeon_entry_fee(&dungeon);
        economy::charge_entry(addr, entry_fee);
        let rid = skill_registry::consume_next_room_id();
        let mut = mutator_for_week(week_of(aptos_framework::timestamp::now_seconds()));
        let rs = borrow_global_mut<RoomStore>(@mohayo);
        let room = Room {
            id: rid,
            difficulty: difficulty as u8,
            phase: 0,
            battle_index: 0,
            total_battles: if (types::dungeon_battles(&dungeon) >= 1) { types::dungeon_battles(&dungeon) as u64 } else { 1 },
            battle_turns: 0,
            turn_id: 0,
            result: 0,
            mana_pool: 0,
            mana_per_turn: types::dungeon_mana_per_turn(&dungeon),
            mana_all_consumed: 0,
            reward_pool: 0,
            created_secs: aptos_framework::timestamp::now_seconds(),
            closed: false,
            end_secs: 0,
            mutator_kind: mut.kind,
            mutator_value: mut.value,
            leader: addr,
            last_advance_secs: aptos_framework::timestamp::now_seconds(),
            rng_seed: rid * 1000 + 1,
            members: vector::empty(),
            enemies: vector::empty(),
        };
        table::add(&mut rs.rooms, rid, room);
        room_list_add(rs, rid);
        event::emit(RoomCreated { room_id: rid, leader: addr });
    }

    /// Test/sim panel join: a bare stat block with NO character binding
    /// (char_id = 0 → plan skill-ownership checks are skipped). #[test_only] so it
    /// can never be a production entry: real players must go through
    /// `join_room_as_char`, which binds the Character (owner + skill set).
    #[test_only]
    public fun join_room(
        account: &signer, room_id: u64,
        max_hp: u64, attack: u64, magic: u64, speed: u64,
    ) acquires RoomStore {
        let rs = borrow_global_mut<RoomStore>(@mohayo);
        let room = table::borrow_mut(&mut rs.rooms, room_id);
        assert!(!room.closed, E_ROOM_CLOSED);
        assert!(room.phase == 0 || room.phase == 1 || room.phase == 3, E_NOT_JOINABLE);
        assert!(vector::length(&room.members) < types::MAX_MEMBERS(), E_ROOM_FULL);
        let member = types::make_member(
            max_hp, max_hp, attack, magic, speed,
            0, 0, 0, 0, 0, 0,
            vector::empty(), vector::empty(), 0,
            true, false, signer::address_of(account), 0,
        );
        vector::push_back(&mut room.members, member);
        if (room.phase == 1) {
            let idx = vector::length(&room.members) - 1;
            types::member_set_arrive_delay(vector::borrow_mut(&mut room.members, idx), JOIN_DELAY as u8);
        };
        ensure_leader(room, room_id);   // 队长必须是在场队员(§2.6.14)
        event::emit(MemberJoined { room_id, player: signer::address_of(account) });
    }

    // Test-only join that also sets the character's resource-affix fields
    // (mana/ap discount, ap bonus, mana regen) so the simulator can model a
    // "talented" build independently of its flat stats. Production join copies
    // these from Character via the normal path.
    #[test_only]
    public fun join_room_affixed(
        account: &signer, room_id: u64,
        max_hp: u64, attack: u64, magic: u64, speed: u64,
        mana_discount: u16, ap_discount: u16, ap_bonus: u16, mana_gain_bonus: i64,
    ) acquires RoomStore {
        let rs = borrow_global_mut<RoomStore>(@mohayo);
        let room = table::borrow_mut(&mut rs.rooms, room_id);
        assert!(!room.closed, E_ROOM_CLOSED);
        assert!(room.phase == 0 || room.phase == 1 || room.phase == 3, E_NOT_JOINABLE);
        assert!(vector::length(&room.members) < types::MAX_MEMBERS(), E_ROOM_FULL);
        let member = types::make_member(
            max_hp, max_hp, attack, magic, speed,
            0, mana_discount, ap_discount, ap_bonus, mana_gain_bonus,
            0, vector::empty(), vector::empty(), 0, true, false,
            signer::address_of(account), 0,
        );
        vector::push_back(&mut room.members, member);
        if (room.phase == 1) {
            let idx = vector::length(&room.members) - 1;
            types::member_set_arrive_delay(vector::borrow_mut(&mut room.members, idx), JOIN_DELAY as u8);
        };
        ensure_leader(room, room_id);   // 队长必须是在场队员(§2.6.14)
        event::emit(MemberJoined { room_id, player: signer::address_of(account) });
    }

    /// Production join: binds this room slot to `char_id`. The caller must own
    /// the character (技能权威源 = Character.skill_ids, 存在角色自身存储)。成员只携带
    /// owner + char_id 引用 —— 不复制技能集进房间(省 gas)，计划提交时按需校验。
    public entry fun join_room_as_char(
        account: &signer, room_id: u64, char_id: u64,
    ) acquires RoomStore {
        assert!(character::char_owner(char_id) == signer::address_of(account), E_NOT_PLAN_OWNER);
        // §2.6.11: 已在别的房间的角色不得再入房 —— 否则 room_id 被覆盖, 退房时会提前解锁
        // (人在旧房战斗中), §7.4「关卡内禁止转移」被绕过。
        assert!(character::get_room_id(char_id) == 0, E_CHAR_IN_ROOM);
        let (_hp, max_hp, atk, mag, spd) = character::get_stats(char_id);
        // §2.6.11: 资源词条(class_id/ap_discount/…/mana_gain_bonus)必须随角色进 Member。
        // 此前这里硬写 0，导致四条资源词条即使解析出来也永远到不了引擎。
        let (class_id, mana_disc, ap_disc, ap_bon, mana_gain) = character::member_fields(char_id);
        let rs = borrow_global_mut<RoomStore>(@mohayo);
        let room = table::borrow_mut(&mut rs.rooms, room_id);
        assert!(!room.closed, E_ROOM_CLOSED);
        assert!(room.phase == 0 || room.phase == 1 || room.phase == 3, E_NOT_JOINABLE);
        assert!(vector::length(&room.members) < types::MAX_MEMBERS(), E_ROOM_FULL);
        // §2.6.14 审计: 同一角色**逃离后**会解锁(room_id=0), 若不查本房成员表,
        // 可以在间歇期「逃离 → 立刻重进同一房间」白拿一个满血槽位并规避救援费。
        let mi = 0;
        while (mi < vector::length(&room.members)) {
            assert!(types::member_char_id(vector::borrow(&room.members, mi)) != char_id, E_CHAR_IN_ROOM);
            mi = mi + 1;
        };
        // 参与次数门控(§2.6.14 用户定案): **加入计一次窗口额度**(开房也已计一次)。
        // 放在房间状态检查之后 —— 被拒的加入不消耗名额。
        use_item::consume_entry(signer::address_of(account));
        let member = types::make_member(
            max_hp, max_hp, atk, mag, spd,
            0, mana_disc, ap_disc, ap_bon, mana_gain, class_id,
            vector::empty(), vector::empty(), 0,
            true, false, signer::address_of(account), char_id,
        );
        vector::push_back(&mut room.members, member);
        // §4.5-5 中途加入: 战斗进行中入队 → 延迟到场; 间歇期/大厅 → 立即
        if (room.phase == 1) {
            let idx = vector::length(&room.members) - 1;
            types::member_set_arrive_delay(vector::borrow_mut(&mut room.members, idx), JOIN_DELAY as u8);
        };
        character::lock_room(char_id, room_id); // §7.4: 关卡内禁止角色转移
        ensure_leader(room, room_id);   // 队长必须是在场队员(§2.6.14)
        event::emit(MemberJoined { room_id, player: signer::address_of(account) });
    }

    /// 大厅期离房(§3.1 解散前的自由加入/退出)。开战后改用 `request_escape`。
    public entry fun leave_room(account: &signer, room_id: u64) acquires RoomStore {
        let addr = signer::address_of(account);
        let rs = borrow_global_mut<RoomStore>(@mohayo);
        let room = table::borrow_mut(&mut rs.rooms, room_id);
        assert!(room.phase == 0, E_NOT_LOBBY);
        let n = vector::length(&room.members);
        let i = 0;
        let found = false;
        while (i < n) {
            let m = vector::borrow(&room.members, i);
            if (types::member_owner(m) == addr && !types::member_is_summon(m)) {
                let cid = types::member_char_id(m);
                vector::remove(&mut room.members, i);
                if (cid != 0) { character::lock_room(cid, 0); }; // 大厅退房: 解绑, 不记履历
                found = true;
                break;
            };
            i = i + 1;
        };
        assert!(found, E_BAD_INDEX);
        ensure_leader(room, room_id);
        event::emit(MemberLeft { room_id, player: addr });
    }

    // ============================ escape & retreat (§6.2) ============================

    /// 个人逃离：任何队员(含队长)在关卡内任意时刻可发起。
    /// - 战斗进行中(phase 1)：**延迟 ESCAPE_DELAY 回合**后离场；
    /// - 战斗间歇(phase 3)：**立即离场**。
    /// 离场者无收益、不再参战、不占活人名额、**不吃救援费**(§6.2/§6.3)。
    /// 队长离场时按加入顺序自动继任(§3.2/§6.2)。
    public entry fun request_escape(account: &signer, room_id: u64, member_index: u64) acquires RoomStore {
        let addr = signer::address_of(account);
        let rs = borrow_global_mut<RoomStore>(@mohayo);
        let room = table::borrow_mut(&mut rs.rooms, room_id);
        assert!(room.phase == 1 || room.phase == 3, E_CANNOT_ESCAPE);
        assert!(member_index < vector::length(&room.members), E_BAD_INDEX);
        {
            let m = vector::borrow(&room.members, member_index);
            assert!(types::member_owner(m) == addr, E_NOT_PLAN_OWNER);
            assert!(!types::member_is_summon(m), E_SUMMON_NO_ESCAPE);
            assert!(types::member_alive(m) && !types::member_escaped(m), E_ALREADY_GONE);
        };
        if (room.phase == 3) {
            do_escape(room, room_id, member_index);
            check_end(room, room_id);
        } else {
            types::member_set_escape_delay(vector::borrow_mut(&mut room.members, member_index), ESCAPE_DELAY as u8);
        };
    }

    /// 队长全员逃离(§6.1/§6.2)：**仅在战斗获胜后的间歇期**可发起。
    /// 提前结束关卡，存活者按随机权重分配收益。
    public entry fun leader_retreat(account: &signer, room_id: u64) acquires RoomStore {
        let addr = signer::address_of(account);
        let rs = borrow_global_mut<RoomStore>(@mohayo);
        let room = table::borrow_mut(&mut rs.rooms, room_id);
        assert!(room.phase == 3, E_NOT_INTERMISSION);
        ensure_leader(room, room_id);
        assert!(can_advance(room, addr), E_NOT_LEADER);
        settle_rewards(room, room_id);   // 奖励照发(§6.1)
        // §2.6.14: 打到一半全员逃离**不算通关** —— 原先记 cleared=true 会把履历刷高
        release_all(room, false);
        mark_settled(room, RESULT_RETREAT());
        event::emit(RunRetreated { room_id });
    }

    // ============================ combat start ============================

    /// 开战（生产入口）。**私有 `entry` + `#[randomness]`**：从 Aptos 协议随机数（AIP-41）取本局
    /// 初始种子，玩家无法预判也无法挑房号(§2.6.14)。
    #[randomness]
    entry fun start_combat(account: &signer, room_id: u64) acquires RoomStore {
        do_start_combat(account, room_id, randomness::u64_integer());
    }

    /// 开战（测试/仿真入口）：不注入协议熵，沿用 `room_id` 派生的旧种子，既有标定因此可复现。
    #[test_only]
    public entry fun start_combat_test(account: &signer, room_id: u64) acquires RoomStore {
        do_start_combat(account, room_id, room_id * 1000 + 1);
    }

    fun do_start_combat(account: &signer, room_id: u64, seed: u64) acquires RoomStore {
        let addr = signer::address_of(account);
        let rs = borrow_global_mut<RoomStore>(@mohayo);
        let room = table::borrow_mut(&mut rs.rooms, room_id);
        assert!(room.phase == 0, E_NOT_LOBBY);
        assert!(!room.closed, E_ROOM_CLOSED);
        assert!(vector::length(&room.members) > 0, E_NO_MEMBERS);
        ensure_leader(room, room_id);                  // 队长必须是在场队员(§2.6.14)
        assert!(can_advance(room, addr), E_NOT_LEADER);
        room.phase = 1;
        room.turn_id = 1;
        room.last_advance_secs = aptos_framework::timestamp::now_seconds();
        room.rng_seed = seed;
        room.mana_pool = room.mana_per_turn + mutator_mana_bonus(room);
        spawn_battle(room, room_id);
        event::emit(CombatStarted { room_id, turn_id: room.turn_id });
    }

    // ============================ plan ============================

    public entry fun set_plan(account: &signer, room_id: u64, member_index: u64, plan: vector<u64>) acquires RoomStore {
        let rs = borrow_global_mut<RoomStore>(@mohayo);
        let room = table::borrow_mut(&mut rs.rooms, room_id);
        assert!(room.phase == 1, E_NOT_COMBAT);
        assert!(member_index < vector::length(&room.members), E_BAD_INDEX);
        {
            let m = vector::borrow(&room.members, member_index);
            // 只能给自己排(队长也不能替别人排, gameplay-design §4.3)
            assert!(signer::address_of(account) == types::member_owner(m), E_NOT_PLAN_OWNER);
            // 只用自己拥有的技能: 权威源 = Character.skill_ids(角色自身存储)。
            // 提交时刻一次性校验, 回合执行零额外检查(省 gas)。char_id=0 为 test-only 面板通道。
            let cid = types::member_char_id(m);
            if (cid != 0) {
                let pi = 0;
                while (pi < vector::length(&plan)) {
                    let sid = *vector::borrow(&plan, pi);
                    if (sid >= item::ITEM_SKILL_BASE) {
                        // 道具项: 必须是"战斗中可使用"的道具
                        assert!(item::is_combat_usable(sid - item::ITEM_SKILL_BASE), E_SKILL_NOT_OWNED);
                    } else {
                        assert!(character::char_owns_skill(cid, sid), E_SKILL_NOT_OWNED);
                    };
                    pi = pi + 1;
                };
            };
        };
        let m = vector::borrow_mut(&mut room.members, member_index);
        types::member_set_plan(m, plan);
        types::member_set_plan_start(m, 0);
        event::emit(PlanSet { room_id, player: signer::address_of(account) });
    }

    public entry fun cancel_plan(account: &signer, room_id: u64, member_index: u64) acquires RoomStore {
        let rs = borrow_global_mut<RoomStore>(@mohayo);
        let room = table::borrow_mut(&mut rs.rooms, room_id);
        assert!(member_index < vector::length(&room.members), E_BAD_INDEX);
        {
            let m = vector::borrow(&room.members, member_index);
            assert!(signer::address_of(account) == types::member_owner(m), E_NOT_PLAN_OWNER);
        };
        let m = vector::borrow_mut(&mut room.members, member_index);
        types::member_set_plan(m, vector::empty());
        types::member_set_plan_start(m, 0);
    }

    // ============================ advance turn ============================

    /// 推进一回合（生产入口，§4.1：自动/手动**同一入口**）。私有 `entry` + `#[randomness]`：
    /// **每笔推进交易换一次协议熵**，因此下一回合的随机结果在玩家排计划时不可预判(§2.6.14)。
    /// 防重复推进（§3.1）：① `expected_turn_id` 必须等于当前 `turn_id` —— 同一回合只有第一笔
    /// 成功交易能推进，并发/重放的后来者在断言上失败、状态零变更；② 距上次推进 ≥ `TURN_COOLDOWN_SECS`。
    #[randomness]
    entry fun advance_turn(account: &signer, room_id: u64, expected_turn_id: u64) acquires RoomStore {
        do_advance_turn(account, room_id, expected_turn_id, option::some(randomness::u64_integer()));
    }

    /// 推进一回合（测试/仿真入口）：`none` = 不刷新随机流，保持既有标定可复现。
    #[test_only]
    public entry fun advance_turn_test(account: &signer, room_id: u64, expected_turn_id: u64) acquires RoomStore {
        do_advance_turn(account, room_id, expected_turn_id, option::none());
    }

    fun do_advance_turn(
        account: &signer, room_id: u64, expected_turn_id: u64, seed: Option<u64>,
    ) acquires RoomStore {
        let caller = signer::address_of(account);
        let rs = borrow_global_mut<RoomStore>(@mohayo);
        let room = table::borrow_mut(&mut rs.rooms, room_id);
        assert!(room.phase == 1, E_NOT_COMBAT);
        assert!(can_advance(room, caller), E_NOT_LEADER);       // 只有队长能推进(§2.6.14)
        assert!(room.turn_id == expected_turn_id, E_TURN_MISMATCH);
        let now = aptos_framework::timestamp::now_seconds();
        assert!(now >= room.last_advance_secs + TURN_COOLDOWN_SECS, E_ADVANCE_COOLDOWN);
        room.last_advance_secs = now;
        let used_seed = apply_seed(room, &seed);
        advance_turn_inner(room, room_id, used_seed);
    }

    /// Keeper 单点故障兜底（§3.1）：距上次推进 ≥ `EMERGENCY_SECS` 时允许解卡。
    /// 同样走 `#[randomness]`，因为推进本身会消耗随机数。
    #[randomness]
    entry fun emergency_advance(account: &signer, room_id: u64) acquires RoomStore {
        do_emergency_advance(account, room_id, option::some(randomness::u64_integer()));
    }

    #[test_only]
    public entry fun emergency_advance_test(account: &signer, room_id: u64) acquires RoomStore {
        do_emergency_advance(account, room_id, option::none());
    }

    fun do_emergency_advance(account: &signer, room_id: u64, seed: Option<u64>) acquires RoomStore {
        let caller = signer::address_of(account);
        let rs = borrow_global_mut<RoomStore>(@mohayo);
        let room = table::borrow_mut(&mut rs.rooms, room_id);
        assert!(room.phase == 1, E_NOT_COMBAT);
        assert!(can_emergency_advance(room, caller), E_NOT_LEADER);
        let now = aptos_framework::timestamp::now_seconds();
        assert!(now >= room.last_advance_secs + EMERGENCY_SECS, E_NOT_EMERGENCY);
        room.last_advance_secs = now;
        let used_seed = apply_seed(room, &seed);
        advance_turn_inner(room, room_id, used_seed);
    }

    /// 把本次推进要用的种子写进房间，并返回它（`none` = 不刷新，沿用当前链值）。
    /// 返回值同时进 `TurnAdvanced` 事件，便于事后审计这一回合的随机流。
    fun apply_seed(room: &mut Room, seed: &Option<u64>): u64 {
        if (option::is_some(seed)) { room.rng_seed = *option::borrow(seed); };
        room.rng_seed
    }

    /// 该房间距上次推进是否已达冷却（客户端/Keeper 判可用性用）
    #[view]
    public fun advance_ready(room_id: u64): bool acquires RoomStore {
        let rs = borrow_global<RoomStore>(@mohayo);
        assert!(table::contains(&rs.rooms, room_id), E_ROOM_NOT_FOUND);
        let r = table::borrow(&rs.rooms, room_id);
        aptos_framework::timestamp::now_seconds() >= r.last_advance_secs + TURN_COOLDOWN_SECS
    }

    fun advance_turn_inner(room: &mut Room, room_id: u64, seed_used: u64) {
        room.turn_id = room.turn_id + 1;
        room.battle_turns = room.battle_turns + 1;
        tick_escapes(room, room_id);   // 先结算个人逃离(离场者本回合起不参战)
        tick_arrivals(room, room_id);  // 中途加入者的到场倒计时(§4.5-5)
        tick_all_effects(room, room_id);
        act_all(room, room_id);
        let mut_delta = room.mana_per_turn + mutator_mana_bonus(room);
        let mlen = vector::length(&room.members);
        let mi = 0;
        while (mi < mlen) {
            let m = vector::borrow(&room.members, mi);
            if (types::member_alive(m)) {
                let g = types::member_mana_gain_bonus(m);
                if (g > 0) { mut_delta = mut_delta + (g as u64); }
            };
            mi = mi + 1;
        };
        room.mana_pool = room.mana_pool + mut_delta;
        event::emit(ManaChanged { room_id, pool: room.mana_pool });
        check_end(room, room_id);
        event::emit(TurnAdvanced { room_id, turn_id: room.turn_id, seed: seed_used });
    }

    // ============================ battle advancement ============================

    /// 进入下一场（生产入口）。也要换熵：本场的敌人构成 / 变体掷骰都用房间随机流，
    /// 不刷新的话旁观者能从上回合的种子推出这一场是「宝箱」还是「皇帝」(§2.6.14)。
    #[randomness]
    entry fun advance_battle(account: &signer, room_id: u64) acquires RoomStore {
        do_advance_battle(account, room_id, option::some(randomness::u64_integer()));
    }

    #[test_only]
    public entry fun advance_battle_test(account: &signer, room_id: u64) acquires RoomStore {
        do_advance_battle(account, room_id, option::none());
    }

    fun do_advance_battle(account: &signer, room_id: u64, seed: Option<u64>) acquires RoomStore {
        let addr = signer::address_of(account);
        let rs = borrow_global_mut<RoomStore>(@mohayo);
        let room = table::borrow_mut(&mut rs.rooms, room_id);
        assert!(room.phase == 3, E_NOT_INTERMISSION);
        ensure_leader(room, room_id);                  // 队长不在场时先继任, 免得整队卡在间歇期
        assert!(can_advance(room, addr), E_NOT_LEADER);
        assert!(room.battle_index < room.total_battles, E_LAST_BATTLE);
        apply_seed(room, &seed);
        room.phase = 1;
        spawn_battle(room, room_id);
        event::emit(BattleAdvanced { room_id, new_battle_index: room.battle_index });
    }

    // ============================ view functions ============================

    #[view]
    public fun room_phase(room_id: u64): u8 acquires RoomStore {
        let rs = borrow_global<RoomStore>(@mohayo);
        assert!(table::contains(&rs.rooms, room_id), E_ROOM_NOT_FOUND);
        table::borrow(&rs.rooms, room_id).phase
    }

    #[view]
    public fun room_result(room_id: u64): u8 acquires RoomStore {
        // 0 = 未结算, 1 = 通关, 2 = 败北/清退, 3 = 全员逃离(提前收工, §2.6.14)
        let rs = borrow_global<RoomStore>(@mohayo);
        assert!(table::contains(&rs.rooms, room_id), E_ROOM_NOT_FOUND);
        table::borrow(&rs.rooms, room_id).result
    }

    #[view]
    public fun room_turn(room_id: u64): u64 acquires RoomStore {
        let rs = borrow_global<RoomStore>(@mohayo);
        assert!(table::contains(&rs.rooms, room_id), E_ROOM_NOT_FOUND);
        table::borrow(&rs.rooms, room_id).turn_id
    }

    #[view]
    public fun room_battle(room_id: u64): (u64, u64) acquires RoomStore {
        let rs = borrow_global<RoomStore>(@mohayo);
        assert!(table::contains(&rs.rooms, room_id), E_ROOM_NOT_FOUND);
        let r = table::borrow(&rs.rooms, room_id);
        (r.battle_index, r.total_battles)
    }

    #[view]
    public fun room_mana(room_id: u64): u64 acquires RoomStore {
        let rs = borrow_global<RoomStore>(@mohayo);
        assert!(table::contains(&rs.rooms, room_id), E_ROOM_NOT_FOUND);
        table::borrow(&rs.rooms, room_id).mana_pool
    }

    #[view]
    public fun member_count(room_id: u64): u64 acquires RoomStore {
        let rs = borrow_global<RoomStore>(@mohayo);
        assert!(table::contains(&rs.rooms, room_id), E_ROOM_NOT_FOUND);
        vector::length(&table::borrow(&rs.rooms, room_id).members)
    }

    #[view]
    public fun member_state(room_id: u64, index: u64): (u64, u64, u64, u64, u64, u64) acquires RoomStore {
        let rs = borrow_global<RoomStore>(@mohayo);
        assert!(table::contains(&rs.rooms, room_id), E_ROOM_NOT_FOUND);
        let r = table::borrow(&rs.rooms, room_id);
        assert!(index < vector::length(&r.members), E_BAD_INDEX);
        let m = vector::borrow(&r.members, index);
        (types::member_hp(m), types::member_max_hp(m), types::member_attack(m),
         types::member_magic(m), types::member_speed(m),
         if (types::member_alive(m)) { 1 } else { 0 })
    }

    /// 成员的 AP(§4.6；此前没有任何入口能读到成员 AP)
    #[view]
    public fun member_ap(room_id: u64, member_index: u64): u16 acquires RoomStore {
        let rs = borrow_global<RoomStore>(@mohayo);
        assert!(table::contains(&rs.rooms, room_id), E_ROOM_NOT_FOUND);
        let r = table::borrow(&rs.rooms, room_id);
        assert!(member_index < vector::length(&r.members), E_BAD_INDEX);
        types::member_ap(vector::borrow(&r.members, member_index))
    }

    /// 成员的资源词条加成 (AP消耗−1, 魔素消耗−1, AP产量+1, 魔素产量+1)(§2.6.11)
    #[view]
    public fun member_resources(room_id: u64, index: u64): (u16, u16, u16, i64) acquires RoomStore {
        let rs = borrow_global<RoomStore>(@mohayo);
        assert!(table::contains(&rs.rooms, room_id), E_ROOM_NOT_FOUND);
        let r = table::borrow(&rs.rooms, room_id);
        assert!(index < vector::length(&r.members), E_BAD_INDEX);
        let m = vector::borrow(&r.members, index);
        (types::member_ap_discount(m), types::member_mana_discount(m),
         types::member_ap_bonus(m), types::member_mana_gain_bonus(m))
    }

    /// 当前队长地址(§3.2 继承后由合约自动更新)
    #[view]
    public fun room_leader(room_id: u64): address acquires RoomStore {
        let rs = borrow_global<RoomStore>(@mohayo);
        assert!(table::contains(&rs.rooms, room_id), E_ROOM_NOT_FOUND);
        table::borrow(&rs.rooms, room_id).leader
    }

    /// 该成员是否已个人逃离(§6.2)
    #[view]
    public fun member_escaped(room_id: u64, member_index: u64): bool acquires RoomStore {
        let rs = borrow_global<RoomStore>(@mohayo);
        assert!(table::contains(&rs.rooms, room_id), E_ROOM_NOT_FOUND);
        let r = table::borrow(&rs.rooms, room_id);
        assert!(member_index < vector::length(&r.members), E_BAD_INDEX);
        types::member_escaped(vector::borrow(&r.members, member_index))
    }

    /// 中途加入者的到场倒计时(0 = 已在场)(§4.5-5)
    #[view]
    public fun member_arrive_delay(room_id: u64, member_index: u64): u64 acquires RoomStore {
        let rs = borrow_global<RoomStore>(@mohayo);
        assert!(table::contains(&rs.rooms, room_id), E_ROOM_NOT_FOUND);
        let r = table::borrow(&rs.rooms, room_id);
        assert!(member_index < vector::length(&r.members), E_BAD_INDEX);
        (types::member_arrive_delay(vector::borrow(&r.members, member_index)) as u64)
    }

    /// 待处理逃离的剩余回合数(0 = 无)
    #[view]
    public fun member_escape_delay(room_id: u64, member_index: u64): u64 acquires RoomStore {
        let rs = borrow_global<RoomStore>(@mohayo);
        assert!(table::contains(&rs.rooms, room_id), E_ROOM_NOT_FOUND);
        let r = table::borrow(&rs.rooms, room_id);
        assert!(member_index < vector::length(&r.members), E_BAD_INDEX);
        (types::member_escape_delay(vector::borrow(&r.members, member_index)) as u64)
    }

    #[view]
    public fun member_effect_count(room_id: u64, member_index: u64): u64 acquires RoomStore {
        let rs = borrow_global<RoomStore>(@mohayo);
        let r = table::borrow(&rs.rooms, room_id);
        types::member_effect_count(vector::borrow(&r.members, member_index))
    }

    #[view]
    public fun member_effect(room_id: u64, member_index: u64, effect_index: u64): (u8, u8, u16) acquires RoomStore {
        let rs = borrow_global<RoomStore>(@mohayo);
        let r = table::borrow(&rs.rooms, room_id);
        let m = vector::borrow(&r.members, member_index);
        types::member_get_effect(m, effect_index)
    }

    #[view]
    public fun enemy_count(room_id: u64): u64 acquires RoomStore {
        let rs = borrow_global<RoomStore>(@mohayo);
        assert!(table::contains(&rs.rooms, room_id), E_ROOM_NOT_FOUND);
        vector::length(&table::borrow(&rs.rooms, room_id).enemies)
    }

    #[view]
    public fun enemy_state(room_id: u64, index: u64): (u64, u64, u64, u64, u64, u64) acquires RoomStore {
        let rs = borrow_global<RoomStore>(@mohayo);
        assert!(table::contains(&rs.rooms, room_id), E_ROOM_NOT_FOUND);
        let r = table::borrow(&rs.rooms, room_id);
        assert!(index < vector::length(&r.enemies), E_BAD_INDEX);
        let e = vector::borrow(&r.enemies, index);
        (types::enemy_hp(e), types::enemy_max_hp(e), types::enemy_attack(e),
         types::enemy_magic(e), types::enemy_speed(e),
         if (types::enemy_alive(e)) { 1 } else { 0 })
    }

    /// 该敌人槽位由哪个模板实例化而来（测试/客户端展示用）
    #[view]
    public fun enemy_template(room_id: u64, enemy_index: u64): u64 acquires RoomStore {
        let rs = borrow_global<RoomStore>(@mohayo);
        assert!(table::contains(&rs.rooms, room_id), E_ROOM_NOT_FOUND);
        let r = table::borrow(&rs.rooms, room_id);
        assert!(enemy_index < vector::length(&r.enemies), E_BAD_INDEX);
        types::enemy_template_id(vector::borrow(&r.enemies, enemy_index))
    }

    #[view]
    public fun enemy_effect_count(room_id: u64, enemy_index: u64): u64 acquires RoomStore {
        let rs = borrow_global<RoomStore>(@mohayo);
        let r = table::borrow(&rs.rooms, room_id);
        types::enemy_effect_count(vector::borrow(&r.enemies, enemy_index))
    }

    #[view]
    public fun enemy_effect(room_id: u64, enemy_index: u64, effect_index: u64): (u8, u8, u16) acquires RoomStore {
        let rs = borrow_global<RoomStore>(@mohayo);
        let r = table::borrow(&rs.rooms, room_id);
        let e = vector::borrow(&r.enemies, enemy_index);
        types::enemy_get_effect(e, effect_index)
    }

    #[view]
    public fun reward_pool(room_id: u64): u64 acquires RoomStore {
        let rs = borrow_global<RoomStore>(@mohayo);
        assert!(table::contains(&rs.rooms, room_id), E_ROOM_NOT_FOUND);
        table::borrow(&rs.rooms, room_id).reward_pool
    }

    // ============================ internal: spawning ============================

    fun spawn_battle(room: &mut Room, room_id: u64) {
        room.battle_index = room.battle_index + 1;
        room.battle_turns = 0;
        room.enemies = vector::empty();

        let difficulty = room.difficulty as u64;
        let bi = room.battle_index;

        let table_id: u64;
        let enemy_count: u64;

        let battle_count = skill_registry::get_battle_count(difficulty);
        if (bi <= battle_count && battle_count > 0) {
            let battles = skill_registry::get_battles(difficulty);
            let cfg = vector::borrow(&battles, (bi - 1) as u64);
            table_id = types::battle_config_table_id(cfg);
            enemy_count = types::battle_config_enemy_count(cfg);
        } else {
            let dungeon = skill_registry::get_dungeon(difficulty);
            table_id = types::dungeon_table_id(&dungeon);
            enemy_count = types::dungeon_enemy_count(&dungeon);
        };

        // 变体可以自带敌人数（§8.2 的混编变体）；0 = 沿用本场配置的敌人数
        let variant_count: u64 = 0;
        let variants = skill_registry::get_variants(difficulty, bi);
        if (vector::length(&variants) > 0) {
            let total_weight: u64 = 0;
            let vi = 0;
            while (vi < vector::length(&variants)) {
                let v = vector::borrow(&variants, vi);
                total_weight = total_weight + (types::variant_weight(v) as u64);
                vi = vi + 1;
            };
            let mut_rng = mohayo::rng::new(room.rng_seed + bi);
            let roll = mohayo::rng::below(&mut mut_rng, total_weight);
            room.rng_seed = room.rng_seed + 100;
            let acc: u64 = 0;
            vi = 0;
            while (vi < vector::length(&variants)) {
                let v = vector::borrow(&variants, vi);
                let new_acc = acc + (types::variant_weight(v) as u64);
                if (roll < new_acc) {
                    table_id = types::variant_table_id(v);
                    variant_count = types::variant_enemy_count(v);
                    break;
                };
                acc = new_acc;   // 必须累加, 否则只有第一个变体可达、其余情况静默回落到本场配置表
                vi = vi + 1;
            };
        };

        if (variant_count > 0) { enemy_count = variant_count; };

        let entries = skill_registry::get_table(table_id);
        let total_weight: u64 = 0;
        let ei = 0;
        while (ei < vector::length(&entries)) {
            let e = vector::borrow(&entries, ei);
            total_weight = total_weight + (types::table_entry_weight(e) as u64);
            ei = ei + 1;
        };

        let mut_rng2 = mohayo::rng::new(room.rng_seed + bi * 10);
        let spawned: u64 = 0;
        while (spawned < enemy_count && vector::length(&room.enemies) < types::MAX_ENEMIES()) {
            let roll = mohayo::rng::below(&mut mut_rng2, total_weight);
            let acc: u64 = 0;
            ei = 0;
            while (ei < vector::length(&entries)) {
                let e = vector::borrow(&entries, ei);
                let new_acc = acc + (types::table_entry_weight(e) as u64);
                if (roll < new_acc) {
                    let tid = types::table_entry_template_id(e);
                    let enemy = spawn_enemy_with(tid);
                    let idx = vector::length(&room.enemies);
                    vector::push_back(&mut room.enemies, enemy);
                    if (room.mutator_kind == MUT_HP() && room.mutator_value != 0) {
                        scale_enemy_hp(vector::borrow_mut(&mut room.enemies, idx), room.mutator_value);
                    };
                    event::emit(EnemySpawned { room_id, index: idx, template_id: tid });
                    break;
                };
                acc = new_acc;
                ei = ei + 1;
            };
            spawned = spawned + 1;
        };
        room.rng_seed = room.rng_seed + 1000;
    }

    /// 周常变异「魔素丰潮周」: 每回合魔素增量加成(§3.4)
    fun mutator_mana_bonus(room: &Room): u64 {
        if (room.mutator_kind == MUT_MANA() && room.mutator_value > 0) { (room.mutator_value as u64) } else { 0 }
    }

    /// 周常变异「巨物/脆皮周」(§3.4)：生成时对敌人生命做一次千分比修正(value 带符号)。
    fun scale_enemy_hp(e: &mut Enemy, v: i64) {
        let base = types::enemy_max_hp(e);
        let scaled = if (v > 0) {
            base * (1000 + (v as u64)) / 1000
        } else {
            let dec = base * (((0 - v) as u64)) / 1000;
            if (dec >= base) { 1 } else { base - dec }
        };
        types::enemy_set_max_hp(e, scaled);
        types::enemy_set_hp(e, scaled);
    }

    fun spawn_enemy_with(template_id: u64): Enemy {
        let tmpl = skill_registry::get_template(template_id);
        types::make_enemy(
            template_id,
            types::template_max_hp(&tmpl),
            types::template_max_hp(&tmpl),
            types::template_power(&tmpl),
            types::template_magic(&tmpl),
            types::template_speed(&tmpl),
            types::template_base_acc(&tmpl),
            types::template_threat(&tmpl),
            types::template_ai_id(&tmpl),
            vector::empty(),
            true,
        )
    }

    // ============================ internal: turn loop ============================

    fun tick_all_effects(room: &mut Room, room_id: u64) {
        let mlen = vector::length(&room.members);
        let i = 0;
        while (i < mlen) {
            if (types::member_alive(vector::borrow(&room.members, i))) {
                // DOT(op8): 回合初先造成伤害(固定 magnitude/跳, 先扣护盾再扣血,
                // 走正常死亡管线——DOT 致死同样触发死亡召唤等既有结算), 再递减 duration。
                let dot = (types::member_sum_effect_mag(vector::borrow(&room.members, i), 8) as u64);
                if (dot > 0) { deal_damage(room, room_id, false, i, dot); };
                types::member_tick_effects(vector::borrow_mut(&mut room.members, i));
            };
            i = i + 1;
        };
        let elen = vector::length(&room.enemies);
        let j = 0;
        while (j < elen) {
            if (types::enemy_alive(vector::borrow(&room.enemies, j))) {
                let dot = (types::enemy_sum_effect_mag(vector::borrow(&room.enemies, j), 8) as u64);
                if (dot > 0) { deal_damage(room, room_id, true, j, dot); };
                types::enemy_tick_effects(vector::borrow_mut(&mut room.enemies, j));
            };
            j = j + 1;
        };
    }

    // ============================ internal: turn loop ============================

    /// 本回合行动顺序（§4.2：全体在场单位按**敏捷降序**）。
    /// 同速时**玩家优先**、同侧按索引升序。打包成 key = speed × 64 + priority 后插入排序：
    /// priority 玩家 = 40 − idx（31..40）、敌人 = 20 − idx（11..20），两段互不重叠且可反解。
    /// 召唤物（替身人偶）不行动、不进序列。n ≤ 20，插入排序 O(n²) 且无额外存储结构。
    fun action_order(room: &Room): vector<u64> {
        let keys = vector::empty<u64>();
        let mlen = vector::length(&room.members);
        let i = 0;
        while (i < mlen) {
            let m = vector::borrow(&room.members, i);
            if (types::member_alive(m) && !types::member_escaped(m) && !types::member_is_summon(m)
                && types::member_arrive_delay(m) == 0) {
                vector::push_back(&mut keys, types::member_speed(m) * 64 + (40 - i));
            };
            i = i + 1;
        };
        let elen = vector::length(&room.enemies);
        let j = 0;
        while (j < elen) {
            let e = vector::borrow(&room.enemies, j);
            if (types::enemy_alive(e)) {
                vector::push_back(&mut keys, types::enemy_speed(e) * 64 + (20 - j));
            };
            j = j + 1;
        };
        let n = vector::length(&keys);
        let a = 1;
        while (a < n) {
            let v = *vector::borrow(&keys, a);
            let b = a;
            while (b > 0 && *vector::borrow(&keys, b - 1) > v) {
                *vector::borrow_mut(&mut keys, b) = *vector::borrow(&keys, b - 1);
                b = b - 1;
            };
            *vector::borrow_mut(&mut keys, b) = v;
            a = a + 1;
        };
        keys
    }

    fun act_all(room: &mut Room, room_id: u64) {
        let keys = action_order(room);
        let n = vector::length(&keys);
        let k = n;
        while (k > 0) {
            k = k - 1; // 从最大 key 起 = 敏捷最高者先动
            let key = *vector::borrow(&keys, k);
            let p = key % 64;
            if (p <= 20) {
                let idx = 20 - p;
                if (types::enemy_alive(vector::borrow(&room.enemies, idx))
                    && !types::enemy_has_effect(vector::borrow(&room.enemies, idx), 1)) {
                    act_enemy(room, room_id, idx);
                };
            } else {
                let idx = 40 - p;
                if (types::member_alive(vector::borrow(&room.members, idx))
                    && !types::member_escaped(vector::borrow(&room.members, idx))
                    && !types::member_has_effect(vector::borrow(&room.members, idx), 1)) {
                    act_member(room, room_id, idx);
                };
            };
        };
    }

    fun act_member(room: &mut Room, room_id: u64, idx: u64) {
        let plan_len = vector::length(types::member_plan(vector::borrow(&room.members, idx)));
        if (plan_len == 0) return;
        let m = vector::borrow_mut(&mut room.members, idx);
        let cur_ap = (types::member_ap(m) as u64);
        let bonus_ap = (types::member_ap_bonus(m) as u64);
        let new_ap = cur_ap + 1 + bonus_ap;
        types::member_set_ap(m, if (new_ap > types::AP_CAP_BASE()) { (types::AP_CAP_BASE() as u16) } else { new_ap as u16 });
        let cur_plan_start = types::member_plan_start(m);
        let plan_idx = cur_plan_start % (plan_len as u64);
        let plan_ref = types::member_plan(m);
        let skill_id = *vector::borrow(plan_ref, plan_idx);
        types::member_set_plan_start(m, cur_plan_start + 1);
        if (skill_id >= item::ITEM_SKILL_BASE) {
            // 道具使用(文档 §2.6: 排进计划队列, 占 1 回合行动位)
            //
            // 「先判定有没有合法目标, 再扣库存」: 此前 combat_use 先扣 1 整份再分发效果, 于是
            // 全队满血时放治疗药水、无人倒地时放不死鸟之羽, 都会**库存已扣、效果为零、事件照发**。
            // 现在先 peek(不扣), 确认场上有目标才 consume; 没有目标就整回合空过, 道具留在背包。
            let item_type = skill_id - item::ITEM_SKILL_BASE;
            let owner = types::member_owner(vector::borrow(&room.members, idx));
            let (ok, kind, value) = item::combat_peek(item_type, owner);
            if (!ok) return; // 非战斗道具/无库存/配置非法 → 空过
            if (!item_has_valid_target(room, kind)) return; // 无合法目标 → 空过, **不扣道具**
            if (!item::combat_consume(item_type, owner)) return; // 竞态(理论上不会): 扣失败则空过
            if (kind == item::EFFECT_MANA_BOOST) {
                room.mana_pool = room.mana_pool + value;
            } else if (kind == item::EFFECT_HEAL) {
                item_heal_most_wounded(room, room_id, value);
            } else if (kind == item::EFFECT_SMOKE_ALL) {
                item_smoke_all(room, room_id, value);
            } else if (kind == item::EFFECT_REVIVE) {
                item_revive(room, room_id, value);
            };
            event::emit(ItemUsed { room_id, player: owner, item_type, effect_kind: kind, value });
            return;
        };
        let s = skill_registry::get_skill(skill_id);
        execute_skill(room, room_id, idx, false, &s);
    }

    fun act_enemy(room: &mut Room, room_id: u64, idx: u64) {
        let ai_id = types::enemy_ai_id(vector::borrow(&room.enemies, idx));
        if (ai_id == 0) return;
        let ai = skill_registry::get_ai(ai_id);
        let cycle_len = types::ai_cycle_len(&ai) as u64;
        if (cycle_len == 0) return;
        // Randomized move selection: each turn the enemy picks a uniformly random skill
        // from its cycle. Repeating a skill in the cycle raises its weight. Seeded from
        // room rng so combat stays deterministic per room_id/turn (repeatable for tests).
        let cyc = types::ai_skill_cycle(&ai);
        let mut_rng = mohayo::rng::new(room.rng_seed + idx + room.turn_id);
        let pick = mohayo::rng::below(&mut mut_rng, cycle_len);
        room.rng_seed = room.rng_seed + 1;
        let skill_id = *vector::borrow(cyc, pick);
        let s = skill_registry::get_skill(skill_id);
        execute_skill(room, room_id, idx, true, &s);
    }

    fun execute_skill(room: &mut Room, room_id: u64, actor_idx: u64, actor_is_enemy: bool, s: &Skill) {
        // 两段式门槛(technical-design §2.5「Phase1 只读检查、Phase2 全部通过才依次扣减」):
        // Phase1 —— 弹药余额 / 魔素 / AP **只读检查**; 任一不足 → 整次施放失败, 什么都不扣。
        //   此前的实现把弹药扣减放在魔素/AP 门槛之前, 会出现「技能没放出去、子弹先没了」。
        let ammo_id = (types::skill_ammo_id(s) as u64);
        let has_ammo = (ammo_id == 0) || actor_is_enemy
            || (item::balance_raw(
                    ammo_id,
                    types::member_owner(vector::borrow(&room.members, actor_idx)),
                ) >= ((types::skill_ammo_cost(s) as u128) * item::one()));
        let mana_cost = apply_mana_discount(room, actor_idx, actor_is_enemy, types::skill_mana_cost(s));
        let ap_cost = apply_ap_discount(room, actor_idx, actor_is_enemy, types::skill_ap_cost(s));
        if (!has_ammo) return;
        if (mana_cost > room.mana_pool) return;
        if (!actor_is_enemy) {
            let m = vector::borrow(&room.members, actor_idx);
            if ((types::member_ap(m) as u64) < (ap_cost as u64)) return;
        };
        // Phase2 —— 全部门槛通过, 依次扣减(魔素 → AP → 生命 → 弹药)
        room.mana_pool = room.mana_pool - mana_cost;
        if (!actor_is_enemy) {
            let m = vector::borrow_mut(&mut room.members, actor_idx);
            let cur_ap = types::member_ap(m);
            types::member_set_ap(m, cur_ap - ap_cost);
            let hp_cost = types::skill_hp_cost(s) as u64;
            let cur_hp = types::member_hp(m);
            if (hp_cost > 0 && cur_hp > hp_cost) {
                types::member_set_hp(m, cur_hp - hp_cost);
            } else if (hp_cost > 0) {
                types::member_set_hp(m, 1);
            };
        };
        if (ammo_id > 0 && !actor_is_enemy) {
            let owner = types::member_owner(vector::borrow(&room.members, actor_idx));
            let need = (types::skill_ammo_cost(s) as u128) * item::one();
            item::consume_raw(ammo_id, owner, need);   // 确定性扣减(已通过 Phase1 检查)
        };
        resolve_skill(room, room_id, actor_idx, actor_is_enemy, s);
    }

    /// Only players carry resource-discount entries; enemies pay full cost.
    fun apply_mana_discount(room: &Room, actor_idx: u64, actor_is_enemy: bool, cost: u64): u64 {
        if (actor_is_enemy) { return cost; };
        let m = vector::borrow(&room.members, actor_idx);
        let disc = types::member_mana_discount(m) as u64;
        if (cost > disc) { cost - disc } else { 0 }
    }

    fun apply_ap_discount(room: &Room, actor_idx: u64, actor_is_enemy: bool, cost: u16): u16 {
        if (actor_is_enemy) { return cost; };
        let m = vector::borrow(&room.members, actor_idx);
        let disc = types::member_ap_discount(m);
        if (cost > disc) { cost - disc } else { 0 }
    }

    fun resolve_skill(room: &mut Room, room_id: u64, actor_idx: u64, actor_is_enemy: bool, s: &Skill) {
        event::emit(UnitActed { room_id, is_enemy: actor_is_enemy, index: actor_idx, skill_id: types::skill_id(s) });

        let targeting = types::skill_targeting(s);
        let is_ally = targeting == 5 || targeting == 6 || targeting == 7 || targeting == 9 || targeting == 10;
        let guaranteed = is_ally || targeting == 8 || (types::skill_flags(s) & 1) != 0;
        // GUAR_NEXT(op7, 火枪手鹰眼): 攻击方自身带该效果时其所有技能跳过命中掷骰。
        // 施放回合挂上 dur2, 下一回合初 tick 后仍生效 → "空放一回合换下回合绝对命中"。
        if (!guaranteed && !actor_is_enemy) {
            let guar_holder = vector::borrow(&room.members, actor_idx);
            if (types::member_sum_effect_mag(guar_holder, 7) > 0) { guaranteed = true; };
        };

        // FLAG_MANA_ALL(bit1): spend the entire room mana pool; damage scales with the amount consumed.
        if ((types::skill_flags(s) & 2) != 0) {
            room.mana_all_consumed = room.mana_pool;
            room.mana_pool = 0;
        } else {
            room.mana_all_consumed = 0;
        };

        // 多段连击(targeting 3)：**每段独立抽取随机目标**（§4.2）——可能重复命中同一目标，
        // 也可能分摊给不同目标；每段独立命中掷骰。非多段技 strikes=1，等价于只抽一次。
        let storm: u64 = if (room.mutator_kind == MUT_STORM() && room.mutator_value > 0) {
            (room.mutator_value as u64)
        } else { 0 };
        let strikes = if (targeting == 3) {
            let base_strikes = (types::skill_target_count(s) as u64) + storm;
            let cap = types::MAX_STRIKES();
            if (base_strikes > cap) { cap } else { base_strikes }
        } else { 1 };
        let mut_strike = 0;
        while (mut_strike < strikes) {
            let ts = select_targets(room, targeting, types::skill_target_count(s), actor_is_enemy, actor_idx,
                types::skill_weight_mode(s));
            let tlen = vector::length(&ts);
            let k = 0;
            while (k < tlen) {
                let t = vector::borrow(&ts, k);
                resolve_target(room, room_id, actor_idx, actor_is_enemy, s, t, guaranteed);
                k = k + 1;
            };
            mut_strike = mut_strike + 1;
        };

        let sr = types::skill_summon(s);
        if (types::summon_rule_template_id(sr) != 0) {
            resolve_summon(room, room_id, s);
        };

        let ap_gain = types::skill_ap_gain(s);
        if (ap_gain > 0 && !actor_is_enemy) {
            let m = vector::borrow_mut(&mut room.members, actor_idx);
            let new_ap = types::member_ap(m) + ap_gain;
            let ap_cap = (types::AP_CAP_BASE() as u16);
            if (new_ap > ap_cap) {
                types::member_set_ap(m, ap_cap);
            } else {
                types::member_set_ap(m, new_ap);
            };
        };
    }

    fun resolve_target(
        room: &mut Room, room_id: u64,
        actor_idx: u64, actor_is_enemy: bool,
        s: &Skill, t: &Target, guaranteed: bool,
    ) {
        let t_is_enemy = types::target_is_enemy(t);
        let t_idx = types::target_index(t);

        if (!guaranteed) {
            // Accuracy pipeline: hit = baseAcc − Σ(attacker ACC_DOWN) − Σ(defender EVADE_UP),
            // clamped to MIN_HIT_RATE. Pure additive; values are per-mille.
            // 周常变异「迷雾周」: 敌人命中 −value‰(§3.4)
            let fog: i64 = if (room.mutator_kind == MUT_FOG() && actor_is_enemy) { room.mutator_value } else { 0 };
            let base_acc = (types::skill_base_acc(s) as i64) - fog;
            let acc_down = if (actor_is_enemy) {
                types::enemy_sum_effect_mag(vector::borrow(&room.enemies, actor_idx), 6)
            } else {
                types::member_sum_effect_mag(vector::borrow(&room.members, actor_idx), 6)
            } as u64;
            let evade = if (t_is_enemy) {
                types::enemy_sum_effect_mag(vector::borrow(&room.enemies, t_idx), 5)
            } else {
                types::member_sum_effect_mag(vector::borrow(&room.members, t_idx), 5)
            } as u64;
            let mut_hit: i64 = base_acc - (acc_down as i64) - (evade as i64);
            let min_hit = (types::MIN_HIT_RATE() as i64);
            if (mut_hit < min_hit) { mut_hit = min_hit; };
            let mut_rng = mohayo::rng::new(room.rng_seed + t_idx + room.turn_id);
            let roll = mohayo::rng::below(&mut mut_rng, 1000);
            room.rng_seed = room.rng_seed + 1;
            if ((roll as i64) >= mut_hit) return;
        };

        if (t_is_enemy) {
            if (!types::enemy_alive(vector::borrow(&room.enemies, t_idx))) return;
        } else {
            if (!types::member_alive(vector::borrow(&room.members, t_idx))) return;
        };

        let power = types::skill_power(s);
        let dealt: u64 = 0;
        // Only attack-type skills (physical/magic) resolve `power` as hit damage.
        // Support skills (heal/shield/buff) carry non-zero power too (e.g. heal
        // scales by it) but must NOT strike their own target with it.
        let s_kind = types::skill_kind(s);
        if (power > 0 && (s_kind == 1 || s_kind == 2 || s_kind == 5)) {
            let stat = if (s_kind == 2) {
                if (actor_is_enemy) { types::enemy_magic(vector::borrow(&room.enemies, actor_idx)) }
                else { types::member_magic(vector::borrow(&room.members, actor_idx)) }
            } else if (s_kind == 5) {
                // 双修(火枪子弹): power × (ATK + MAG) —— 随总属性成长, 不偏向单一属性
                if (actor_is_enemy) {
                    types::enemy_attack(vector::borrow(&room.enemies, actor_idx))
                        + types::enemy_magic(vector::borrow(&room.enemies, actor_idx))
                } else {
                    types::member_attack(vector::borrow(&room.members, actor_idx))
                        + types::member_magic(vector::borrow(&room.members, actor_idx))
                }
            } else {
                if (actor_is_enemy) { types::enemy_attack(vector::borrow(&room.enemies, actor_idx)) }
                else { types::member_attack(vector::borrow(&room.members, actor_idx)) }
            };
            let hp_before = if (t_is_enemy) { types::enemy_hp(vector::borrow(&room.enemies, t_idx)) }
                            else { types::member_hp(vector::borrow(&room.members, t_idx)) };
            let mut_dmg = compute_damage(room, s, stat, actor_is_enemy, actor_idx, t_is_enemy, t_idx);
            deal_damage(room, room_id, t_is_enemy, t_idx, mut_dmg);
            let hp_after = if (t_is_enemy) { types::enemy_hp(vector::borrow(&room.enemies, t_idx)) }
                           else { types::member_hp(vector::borrow(&room.members, t_idx)) };
            if (hp_before > hp_after) { dealt = hp_before - hp_after; };
        };

        let effects = types::skill_effects(s);
        let eflen = vector::length(effects);
        let mut_e = 0;
        while (mut_e < eflen) {
            let eff_spec = vector::borrow(effects, mut_e);
            let op = types::effect_op(eff_spec);
            if (op == 0) { mut_e = mut_e + 1; continue; };
            let prob = types::effect_prob(eff_spec) as u64;
            let mut_rng_e = mohayo::rng::new(room.rng_seed + mut_e + room.turn_id);
            let roll = mohayo::rng::below(&mut mut_rng_e, 1000);
            room.rng_seed = room.rng_seed + 1;
            if (roll >= prob) { mut_e = mut_e + 1; continue; };

            let dur = types::effect_duration(eff_spec);
            let mag = types::effect_magnitude(eff_spec);
            let scope = types::effect_scope(eff_spec);

            if (op == 9) { // HEAL
                let heal_amount = if (power > 0) {
                    let m_magic = if (actor_is_enemy) { types::enemy_magic(vector::borrow(&room.enemies, actor_idx)) }
                                 else { types::member_magic(vector::borrow(&room.members, actor_idx)) };
                    power * m_magic / 1000
                } else { mag as u64 };
                heal_target(room, room_id, t_is_enemy, t_idx, heal_amount);
            } else if (op == 12) { // LIFESTEAL: heal the caster by a pct of damage dealt this hit
                let ls = (mag as u64) * dealt / 1000;
                if (ls > 0) {
                    if (actor_is_enemy) {
                        heal_target(room, room_id, true, actor_idx, ls);
                    } else {
                        heal_target(room, room_id, false, actor_idx, ls);
                    };
                };
            } else if (op == 13) { // MANA_DELTA
                let delta = mag as u64;
                if (delta > 0) { room.mana_pool = room.mana_pool + delta; }
                else if (delta <= room.mana_pool) { room.mana_pool = room.mana_pool - delta; }
                else { room.mana_pool = 0; };
            } else if (op == 15) { // MANA_DRAIN: pull a flat amount from the room pool
                let drain = mag as u64;
                if (drain >= room.mana_pool) { room.mana_pool = 0; }
                else { room.mana_pool = room.mana_pool - drain; };
            } else if (op == 10) { // DISPEL
                if (t_is_enemy) {
                    types::enemy_dispel(vector::borrow_mut(&mut room.enemies, t_idx));
                } else {
                    types::member_dispel(vector::borrow_mut(&mut room.members, t_idx));
                };
            } else {
                // SHIELD(op4): kind=MAGIC 且 power>0 时护盾量走 power × 魔攻（魔力护盾，§5）；
                // 否则用效果条的固定 magnitude（岩石壁垒等）。
                let eff_mag = if (op == 4 && power > 0 && s_kind == 2) {
                    let m_magic = if (actor_is_enemy) { types::enemy_magic(vector::borrow(&room.enemies, actor_idx)) }
                                 else { types::member_magic(vector::borrow(&room.members, actor_idx)) };
                    ((power * m_magic / 1000) as u16)
                } else { mag };
                let ae = types::make_active_effect(op, dur, eff_mag, types::skill_id(s));
                // SCOPE_SELF(0) = 作用于施放者本人（致盲粉的「双刃」：自降命中换对敌压制）；
                // 其余一律作用于选中的目标。
                if (scope == 0) {
                    if (actor_is_enemy) {
                        types::enemy_add_effect(vector::borrow_mut(&mut room.enemies, actor_idx), ae);
                    } else {
                        types::member_add_effect(vector::borrow_mut(&mut room.members, actor_idx), ae);
                    };
                    event::emit(EffectApplied { room_id, is_enemy: actor_is_enemy, index: actor_idx, op, magnitude: eff_mag, duration: dur });
                } else if (t_is_enemy) {
                    types::enemy_add_effect(vector::borrow_mut(&mut room.enemies, t_idx), ae);
                    event::emit(EffectApplied { room_id, is_enemy: true, index: t_idx, op, magnitude: eff_mag, duration: dur });
                } else {
                    types::member_add_effect(vector::borrow_mut(&mut room.members, t_idx), ae);
                    event::emit(EffectApplied { room_id, is_enemy: false, index: t_idx, op, magnitude: eff_mag, duration: dur });
                };
            };
            mut_e = mut_e + 1;
        };
    }

    // ============================ internal: summon ============================

    /// Spawns the minion(s) declared by a skill's SummonRule.
    /// FLAG_SUMMON_ALLY(bit2) spawns a friendly decoy into `members`; otherwise it
    /// spawns an enemy minion into `enemies`. Capped by the room unit limit.
    fun resolve_summon(room: &mut Room, room_id: u64, s: &Skill) {
        let sr = types::skill_summon(s);
        let stid = types::summon_rule_template_id(sr);
        if (stid == 0) return;
        if ((types::skill_flags(s) & 4) != 0) {
            if (vector::length(&room.members) < types::MAX_MEMBERS()) {
                let t = skill_registry::get_template(stid);
                let idx = vector::length(&room.members);
                let minion = types::make_member(
                    types::template_max_hp(&t), types::template_max_hp(&t),
                    types::template_power(&t), types::template_magic(&t), types::template_speed(&t),
                    0, 0, 0, 0, 0, 0,
                    vector::empty(), vector::empty(), 0, true, true, @mohayo, 0,
                );
                vector::push_back(&mut room.members, minion);
                event::emit(EnemySpawned { room_id, index: idx, template_id: stid });
            };
        } else {
            // §4.5-1 缺口公式: 先读场上存活数 —— 存活敌人数 < 存活角色数 + 2 时,
            // 召唤 min(缺口, 技能上限); 否则本次召唤落空(防敌人无限膨胀)。
            let alive_enemies: u64 = 0;
            let ei = 0;
            while (ei < vector::length(&room.enemies)) {
                if (types::enemy_alive(vector::borrow(&room.enemies, ei))) { alive_enemies = alive_enemies + 1; };
                ei = ei + 1;
            };
            let alive_players: u64 = 0;
            let mi = 0;
            while (mi < vector::length(&room.members)) {
                let m = vector::borrow(&room.members, mi);
                if (types::member_alive(m) && !types::member_is_summon(m) && !types::member_escaped(m)
                    && types::member_arrive_delay(m) == 0) {
                    alive_players = alive_players + 1;
                };
                mi = mi + 1;
            };
            let target_total = alive_players + 2;
            if (alive_enemies >= target_total) { return; };
            let gap = target_total - alive_enemies;
            let rule_count = types::summon_rule_max_count(sr) as u64;
            let count = if (gap < rule_count) { gap } else { rule_count };
            let j = 0;
            while (j < count && vector::length(&room.enemies) < types::MAX_ENEMIES()) {
                let idx = vector::length(&room.enemies);
                let e = spawn_enemy_with(stid);
                vector::push_back(&mut room.enemies, e);
                if (room.mutator_kind == MUT_HP() && room.mutator_value != 0) {
                    scale_enemy_hp(vector::borrow_mut(&mut room.enemies, idx), room.mutator_value);
                };
                event::emit(EnemySpawned { room_id, index: idx, template_id: stid });
                j = j + 1;
            };
        };
    }

    // ============================ internal: damage ============================

    fun compute_damage(
        room: &Room, s: &Skill, stat: u64,
        _actor_is_enemy: bool, actor_idx: u64,
        t_is_enemy: bool, t_idx: u64,
    ): u64 {
        let power = types::skill_power(s);
        let mut_dmg: u64 = 0;
        if ((types::skill_flags(s) & 2) != 0) {
            // FLAG_MANA_ALL: base damage on the mana consumed this cast, not on the stat.
            mut_dmg = power * room.mana_all_consumed / 1000;
        } else {
            mut_dmg = power * stat / 1000;
        };
        let cap = types::skill_damage_cap(s);
        if (cap != 0 && mut_dmg > cap) { mut_dmg = cap; };

        let out_mod = if (_actor_is_enemy) {
            types::enemy_sum_effect_mag(vector::borrow(&room.enemies, actor_idx), 2)
        } else {
            types::member_sum_effect_mag(vector::borrow(&room.members, actor_idx), 2)
        };
        if (out_mod > 0) { mut_dmg = mut_dmg * (1000 + (out_mod as u64)) / 1000; };

        let in_mod = if (t_is_enemy) {
            types::enemy_sum_effect_mag(vector::borrow(&room.enemies, t_idx), 3)
        } else {
            types::member_sum_effect_mag(vector::borrow(&room.members, t_idx), 3)
        };
        if (in_mod > 0) { mut_dmg = mut_dmg * (1000 + (in_mod as u64)) / 1000; };

        mut_dmg
    }

    fun deal_damage(room: &mut Room, room_id: u64, t_is_enemy: bool, t_idx: u64, raw_dmg: u64) {
        if (t_is_enemy) {
            let mut_dmg = types::enemy_absorb_shield(vector::borrow_mut(&mut room.enemies, t_idx), raw_dmg);
            let hp_val = types::enemy_hp(vector::borrow(&room.enemies, t_idx));
            if (mut_dmg > hp_val) { mut_dmg = hp_val; };
            types::enemy_set_hp(vector::borrow_mut(&mut room.enemies, t_idx), hp_val - mut_dmg);
            let hp_left = types::enemy_hp(vector::borrow(&room.enemies, t_idx));
            event::emit(DamageDealt { room_id, is_enemy: true, index: t_idx, amount: mut_dmg, hp_left });
            if (hp_left == 0) { handle_enemy_death(room, room_id, t_idx); };
        } else {
            let mut_dmg = types::member_absorb_shield(vector::borrow_mut(&mut room.members, t_idx), raw_dmg);
            let hp_val = types::member_hp(vector::borrow(&room.members, t_idx));
            if (mut_dmg > hp_val) { mut_dmg = hp_val; };
            types::member_set_hp(vector::borrow_mut(&mut room.members, t_idx), hp_val - mut_dmg);
            let hp_left = types::member_hp(vector::borrow(&room.members, t_idx));
            event::emit(DamageDealt { room_id, is_enemy: false, index: t_idx, amount: mut_dmg, hp_left });
            if (hp_left == 0) { handle_member_death(room, room_id, t_idx); };
        };
    }

    fun heal_target(room: &mut Room, room_id: u64, t_is_enemy: bool, t_idx: u64, amount: u64) {
        if (t_is_enemy) {
            let e = vector::borrow_mut(&mut room.enemies, t_idx);
            let before = types::enemy_hp(e);
            let new_hp = before + amount;
            let cap = types::enemy_max_hp(e);
            if (new_hp > cap) {
                types::enemy_set_hp(e, cap);
            } else {
                types::enemy_set_hp(e, new_hp);
            };
            let healed = types::enemy_hp(e) - before;
            event::emit(HealedEvt { room_id, is_enemy: true, index: t_idx, amount: healed });
        } else {
            let m = vector::borrow_mut(&mut room.members, t_idx);
            let before = types::member_hp(m);
            let new_hp = before + amount;
            let cap = types::member_max_hp(m);
            if (new_hp > cap) {
                types::member_set_hp(m, cap);
            } else {
                types::member_set_hp(m, new_hp);
            };
            let healed = types::member_hp(m) - before;
            event::emit(HealedEvt { room_id, is_enemy: false, index: t_idx, amount: healed });
        };
    }

    // ============================ internal: item effects ============================

    /// 该效果此刻是否有合法目标(与下面各 item_* 的目标判定**必须同口径**, 否则会出现
    /// 「这里判有、那边判无 → 白扣一次」)。判定口径:
    /// - HEAL   : 存在存活真人且血量未满(否则治疗量会溢出为 0)
    /// - REVIVE : 存在被击败且未逃离的真人(召唤物不可复活, 与 item_revive 一致)
    /// - 其余(MANA_BOOST / SMOKE_ALL): 恒有目标 —— 魔素池与场上单位数无关, 烟幕总能施加。
    fun item_has_valid_target(room: &Room, kind: u8): bool {
        if (kind == item::EFFECT_HEAL) { return item_has_wounded(room) };
        if (kind == item::EFFECT_REVIVE) { return item_has_downed(room) };
        true
    }

    /// 是否有存活真人血量未满。
    fun item_has_wounded(room: &Room): bool {
        let n = vector::length(&room.members);
        let i = 0;
        while (i < n) {
            let m = vector::borrow(&room.members, i);
            if (types::member_alive(m) && !types::member_is_summon(m)
                && types::member_hp(m) < types::member_max_hp(m)) { return true };
            i = i + 1;
        };
        false
    }

    /// 是否有可被复活的真人(被击败 ∧ 未逃离 ∧ 非召唤)。
    fun item_has_downed(room: &Room): bool {
        let n = vector::length(&room.members);
        let i = 0;
        while (i < n) {
            let m = vector::borrow(&room.members, i);
            if (!types::member_alive(m) && !types::member_escaped(m) && !types::member_is_summon(m)) {
                return true
            };
            i = i + 1;
        };
        false
    }

    /// 治疗我方血量亏空绝对值最高的存活真人(非召唤)。无存活者则无效果
    /// (调用方已用 item_has_valid_target 拦过, 这里是防御式分支)。
    fun item_heal_most_wounded(room: &mut Room, room_id: u64, amount: u64) {
        let best: i64 = -1;
        let best_idx: u64 = 0;
        let n = vector::length(&room.members);
        let i = 0;
        while (i < n) {
            let m = vector::borrow(&room.members, i);
            if (types::member_alive(m) && !types::member_is_summon(m)) {
                let deficit = (types::member_max_hp(m) - types::member_hp(m)) as i64;
                if (deficit > best) { best = deficit; best_idx = i; };
            };
            i = i + 1;
        };
        if (best > 0) { heal_target(room, room_id, false, best_idx, amount); };
    }

    /// 烟幕弹: 为场上全体(敌我双方所有存活单位)施加 ACC_DOWN(op 6), 幅度 = value 千分比, 持续 3 回合。
    fun item_smoke_all(room: &mut Room, room_id: u64, mag: u64) {
        let smk = types::make_active_effect(6, 3, (mag as u16), item::ITEM_SKILL_BASE);
        let n = vector::length(&room.members);
        let i = 0;
        while (i < n) {
            if (types::member_alive(vector::borrow(&room.members, i))) {
                types::member_add_effect(vector::borrow_mut(&mut room.members, i), smk);
            };
            i = i + 1;
        };
        let ne = vector::length(&room.enemies);
        let j = 0;
        while (j < ne) {
            if (types::enemy_alive(vector::borrow(&room.enemies, j))) {
                types::enemy_add_effect(vector::borrow_mut(&mut room.enemies, j), smk);
            };
            j = j + 1;
        };
        event::emit(SmokeApplied { room_id, magnitude: mag, duration: 3 });
    }

    /// 不死鸟之羽: 复活本场第一名被击败的真人队友(非召唤), 回到 max(value, max_hp 封顶)。
    /// 无被击败者则不消耗(调用方已用 item_has_valid_target 拦过)。
    fun item_revive(room: &mut Room, room_id: u64, hp: u64) {
        let n = vector::length(&room.members);
        let i = 0;
        while (i < n) {
            let m = vector::borrow_mut(&mut room.members, i);
            // §2.6.14 审计: 逃离者也是 !alive, 不排除的话羽毛会「复活」一个已离场的人
            if (!types::member_alive(m) && !types::member_escaped(m) && !types::member_is_summon(m)) {
                let cap = types::member_max_hp(m);
                types::member_set_alive(m, true);
                types::member_set_hp(m, if (hp < cap) { hp } else { cap });
                types::member_clear_effects(m);
                event::emit(UnitRevived { room_id, index: i, hp: types::member_hp(m) });
                return;
            };
            i = i + 1;
        };
    }

    // ============================ internal: death ============================

    fun handle_enemy_death(room: &mut Room, room_id: u64, idx: u64) {
        let tmpl_id = {
            let e = vector::borrow_mut(&mut room.enemies, idx);
            types::enemy_set_alive(e, false);
            types::enemy_clear_effects(e);
            types::enemy_template_id(e)
        };
        event::emit(UnitDied { room_id, is_enemy: true, index: idx });

        let tmpl = skill_registry::get_template(tmpl_id);
        let reward_min = types::template_reward_min(&tmpl) as u64;
        let reward_max = types::template_reward_max(&tmpl) as u64;
        let mut_rng = mohayo::rng::new(room.rng_seed + idx);
        let reward = if (reward_max <= reward_min) { reward_min }
                     else { mohayo::rng::range(&mut mut_rng, reward_min, reward_max + 1) };
        room.rng_seed = room.rng_seed + 1;
        room.reward_pool = room.reward_pool + reward;

        let ods = types::template_on_death_spawn(&tmpl);
        let ods_tid = types::on_death_spawn_template_id(ods);
        let ods_count = types::on_death_spawn_count(ods);
        let ods_prob = types::on_death_spawn_prob(ods);
        if (ods_tid != 0 && ods_count > 0) {
            let mut_rng2 = mohayo::rng::new(room.rng_seed + idx + 50);
            let roll = mohayo::rng::below(&mut mut_rng2, 1000);
            room.rng_seed = room.rng_seed + 1;
            if (roll < (ods_prob as u64)) {
                let j = 0;
                while (j < (ods_count as u64) && vector::length(&room.enemies) < types::MAX_ENEMIES()) {
                    let new_e = spawn_enemy_with(ods_tid);
                    let new_idx = vector::length(&room.enemies);
                    vector::push_back(&mut room.enemies, new_e);
                    if (room.mutator_kind == MUT_HP() && room.mutator_value != 0) {
                        scale_enemy_hp(vector::borrow_mut(&mut room.enemies, new_idx), room.mutator_value);
                    };
                    event::emit(EnemySpawned { room_id, index: new_idx, template_id: ods_tid });
                    j = j + 1;
                };
            };
        };
    }

    fun handle_member_death(room: &mut Room, room_id: u64, idx: u64) {
        {
            let m = vector::borrow_mut(&mut room.members, idx);
            types::member_set_alive(m, false);
            types::member_clear_effects(m);
        };
        event::emit(UnitDied { room_id, is_enemy: false, index: idx });
        ensure_leader(room, room_id); // 队长阵亡 → 按加入顺序自动继任(§3.2/§6.2)
    }

    // ============================ internal: escape / leader / 结算 ============================

    /// 该槽位是否为「在场的玩家成员」（存活、未逃离、非召唤物）。
    fun is_active_player(room: &Room, i: u64): bool {
        let m = vector::borrow(&room.members, i);
        types::member_alive(m) && !types::member_escaped(m) && !types::member_is_summon(m)
            && types::member_arrive_delay(m) == 0
    }

    /// 回合初推进逃离倒计时；归零者当场离场（§6.2 战斗中的延迟逃离）。
    fun tick_escapes(room: &mut Room, room_id: u64) {
        let n = vector::length(&room.members);
        let i = 0;
        while (i < n) {
            let d = types::member_escape_delay(vector::borrow(&room.members, i));
            if (d > 0) {
                let nd = d - 1;
                types::member_set_escape_delay(vector::borrow_mut(&mut room.members, i), nd);
                if (nd == 0) { do_escape(room, room_id, i); };
            };
            i = i + 1;
        };
    }

    /// 中途加入者的到场倒计时（§4.5-5）：归零即入队参战。
    fun tick_arrivals(room: &mut Room, room_id: u64) {
        let n = vector::length(&room.members);
        let i = 0;
        while (i < n) {
            let d = types::member_arrive_delay(vector::borrow(&room.members, i));
            if (d > 0) {
                let nd = d - 1;
                types::member_set_arrive_delay(vector::borrow_mut(&mut room.members, i), nd);
                if (nd == 0) { event::emit(MemberArrived { room_id, index: i }); };
            };
            i = i + 1;
        };
    }

    /// 离场状态置位：无收益、不再参战、不占活人名额、不吃救援费（§6.2/§6.3）。
    fun do_escape(room: &mut Room, room_id: u64, idx: u64) {
        let owner = types::member_owner(vector::borrow(&room.members, idx));
        let cid = types::member_char_id(vector::borrow(&room.members, idx));
        {
            let m = vector::borrow_mut(&mut room.members, idx);
            types::member_set_escaped(m, true);
            types::member_set_alive(m, false);
            types::member_set_escape_delay(m, 0);
            types::member_set_plan(m, vector::empty());
            types::member_clear_effects(m);
        };
        // 离场即释放角色锁并记一次未通关履历（§2.4/§7.4）—— 结算时不再重复计入
        if (cid != 0) {
            character::lock_room(cid, 0);
            character::record_run(cid, false, room.difficulty);
        };
        event::emit(MemberEscaped { room_id, player: owner });
        ensure_leader(room, room_id);
    }

    /// 关卡结束时释放所有玩家角色的房间锁并记履历（已逃离者不重复结算）。
    fun release_all(room: &Room, cleared: bool) {
        let n = vector::length(&room.members);
        let i = 0;
        while (i < n) {
            let m = vector::borrow(&room.members, i);
            if (!types::member_is_summon(m) && !types::member_escaped(m)) {
                let cid = types::member_char_id(m);
                if (cid != 0) {
                    character::lock_room(cid, 0);
                    character::record_run(cid, cleared, room.difficulty);
                };
            };
            i = i + 1;
        };
    }

    /// 队长去位（阵亡 / 逃离 / 退房）后的自动继任：
    /// 按**加入房间的先后顺序**（members 向量序 = push_back 序）取第一个仍在场者（§3.2/§6.2）。
    /// 召唤物（替身人偶）永远跳过 —— 继承链只走玩家角色。
    /// 队长**必须是在场队员**（§2.6.14）：`ensure_leader` 现在在多处入口被主动调用，
    /// 因此「队长是不在队伍里的地址」不会再出现，也就不会再有「打赢第一场后被卡在间歇期」。
    /// 现任队长只要还是可带队成员就不换人，否则按加入序取第一个可带队成员。
    fun ensure_leader(room: &mut Room, room_id: u64) {
        let n = vector::length(&room.members);
        // 现队长仍是可带队成员 → 不变
        let i = 0;
        while (i < n) {
            if (types::member_owner(vector::borrow(&room.members, i)) == room.leader
                && can_lead(room, i, true)) {
                return;
            };
            i = i + 1;
        };
        // 换人：先找已到场者，再放宽到还没到场的成员
        let pick = find_leader(room, false);
        if (pick == n) { pick = find_leader(room, true); };
        if (pick < n) {
            let owner = types::member_owner(vector::borrow(&room.members, pick));
            room.leader = owner;
            event::emit(LeaderChanged { room_id, new_leader: owner });
        };
    }

    /// 该槽位能否带队。`include_pending = false` 只认**已到场**的在场玩家，
    /// `true` 放宽到「存活且未逃离」（含还在到场倒计时里的成员），用于没有已到场者时兜底。
    fun can_lead(room: &Room, i: u64, include_pending: bool): bool {
        let m = vector::borrow(&room.members, i);
        if (!types::member_alive(m) || types::member_escaped(m) || types::member_is_summon(m)) {
            return false
        };
        include_pending || types::member_arrive_delay(m) == 0
    }

    /// 返回第一个可带队的成员下标；没有则返回 `vector::length(members)`。
    fun find_leader(room: &Room, include_pending: bool): u64 {
        let n = vector::length(&room.members);
        let i = 0;
        while (i < n) {
            if (can_lead(room, i, include_pending)) { return i; };
            i = i + 1;
        };
        n
    }

    // ---- 推进权限（策略集中在这两个函数里，以后要改多签 / 白名单 / 成员投票只动这里）----

    /// 常规推进权限：**只有队长**。此前 `advance_turn` 不校验调用者，任何人都能把别人的房间
    /// 按最快节奏推到回合上限并触发超时扣款（§2.6.14）。
    fun can_advance(room: &Room, who: address): bool {
        room.leader == who
    }

    /// 兜底推进权限：队长长时间不在时**任何人**可解卡。另受 `EMERGENCY_SECS` 门槛约束，
    /// 因此不构成刷房间节奏的通道。
    fun can_emergency_advance(room: &Room, who: address): bool {
        let _ = room;
        let _ = who;
        true
    }

    /// 有资格分享收益的成员槽位：存活、未逃离、非召唤物（§6.1）。
    fun eligible_survivors(room: &Room): vector<u64> {
        let out = vector::empty<u64>();
        let n = vector::length(&room.members);
        let i = 0;
        while (i < n) {
            if (is_active_player(room, i)) { vector::push_back(&mut out, i); };
            i = i + 1;
        };
        out
    }

    /// 收益发放（§6.1）：对每个存活者独立抽取随机权重（1..=1000），按权重分配奖池；
    /// 期望均衡、实际有波动。余数归最后一人，保证账目守恒。
    /// 无人可领（全灭/全逃离）则整池作废。
    /// 同时为每个存活者掷一次掉落表（§7.2）。
    fun settle_rewards(room: &mut Room, room_id: u64) {
        let pool = room.reward_pool;
        room.reward_pool = 0;
        // 注意: 奖池为 0 时不提前返回 —— 掉落掷骰与奖池无关(§7.2「每个存活者独立掷一次」)
        let idxs = eligible_survivors(room);
        let n = vector::length(&idxs);
        if (n == 0) {
            event::emit(RewardForfeited { room_id, amount: pool });
            return;
        };
        let r = mohayo::rng::new(room.rng_seed);
        let weights = vector::empty<u64>();
        let total: u128 = 0;
        let i = 0;
        while (i < n) {
            let w = mohayo::rng::range(&mut r, 1, 1001);
            vector::push_back(&mut weights, w);
            total = total + (w as u128);
            i = i + 1;
        };
        room.rng_seed = mohayo::rng::next(&mut r);
        let remaining = pool;
        let k = 0;
        while (k < n) {
            let share = if (k == n - 1) { remaining } else {
                (((pool as u128) * (*vector::borrow(&weights, k) as u128) / total) as u64)
            };
            remaining = remaining - share;
            let idx = *vector::borrow(&idxs, k);
            let owner = types::member_owner(vector::borrow(&room.members, idx));
            economy::credit(owner, share);
            event::emit(RewardPaid { room_id, player: owner, amount: share });
            // 掉落(§7.2): 每个存活者独立掷一次本难度的掉落表(GM 可动态调整; item_type 0 = 空手)。
            // 周常变异「慷慨/吝啬周」(§3.4): 额外掷骰次数(取第一个非空) / 完全不掉落。
            let skip_drop = room.mutator_kind == MUT_DROP() && room.mutator_value < 0;
            if (!skip_drop) {
                let extra = if (room.mutator_kind == MUT_DROP() && room.mutator_value > 0) {
                    // 钳制上限: GM 误配置超大 value 时, 结算循环不至于无法完成(§2.6.15)
                    let v = (room.mutator_value as u64);
                    if (v > MAX_DROP_ROLLS) { MAX_DROP_ROLLS } else { v }
                } else { 0 };
                let rolls = extra + 1;
                let ri = 0;
                while (ri < rolls) {
                    let dseed = room.rng_seed;
                    room.rng_seed = room.rng_seed + 1;
                    let (drop_item, drop_amt) = item::pick_drop(room.difficulty as u64, dseed);
                    if (drop_item > 0 && drop_amt > 0) {
                        item::credit_raw(drop_item, owner, (drop_amt as u128) * item::one());
                        event::emit(ItemDropped { room_id, player: owner, item_type: drop_item, amount: drop_amt });
                        break;
                    };
                    ri = ri + 1;
                };
            };
            k = k + 1;
        };
    }

    /// 救援费（§6.3）：全队被击败 / 超时 → 每个仍在局内的玩家成员按难度固定费扣款，
    /// **允许扣成负数、负余额无上限**；已个人逃离者与召唤物不扣（§6.2）。
    fun charge_rescue_fees(room: &mut Room, room_id: u64) {
        let dungeon = skill_registry::get_dungeon(room.difficulty as u64);
        let fee = types::dungeon_rescue_fee(&dungeon);
        if (fee == 0) return;
        let n = vector::length(&room.members);
        let i = 0;
        while (i < n) {
            {
                let m = vector::borrow(&room.members, i);
                if (!types::member_is_summon(m) && !types::member_escaped(m)) {
                    let owner = types::member_owner(m);
                    economy::charge_rescue(owner, fee);
                    event::emit(RescuePaid { room_id, player: owner, amount: fee });
                };
            };
            i = i + 1;
        };
    }

    // ============================ internal: end check ============================

    /// 超时清退(§6.3)：按「全队被击败」同一套规则收尾。
    /// 回合上限清退(`check_end`)与战斗期停摆过期(`expire_room`)共用这一条路径。
    fun settle_timeout(room: &mut Room, room_id: u64) {
        charge_rescue_fees(room, room_id); // 超时按全队被击败处理(§6.3)
        release_all(room, false);
        mark_settled(room, RESULT_DEFEAT());
        event::emit(DefeatEvt { room_id });
    }

    fun check_end(room: &mut Room, room_id: u64) {
        // Defeat is checked FIRST: a mutual wipe (party dies the same action the
        // last enemy dies) is a loss, never a victory — the party must SURVIVE to win.
        // 「全队被击败」= 没有任何**玩家成员**仍在场(存活且未逃离)。
        // 召唤物(替身人偶)不算玩家单位：它们活者也不能阻止败北判定(§3.2)。
        let any_player_alive = false;
        let player_count: u64 = 0;
        let mlen = vector::length(&room.members);
        let j = 0;
        while (j < mlen) {
            let m = vector::borrow(&room.members, j);
            if (!types::member_is_summon(m)) {
                player_count = player_count + 1;
                if (types::member_alive(m) && !types::member_escaped(m)) { any_player_alive = true; };
            };
            j = j + 1;
        };
        if (!any_player_alive && player_count > 0) {
            charge_rescue_fees(room, room_id); // 全队被击败 → 全员倒扣救援费(可负)
            release_all(room, false);          // 释放角色锁 + 履历(未通关)
            mark_settled(room, RESULT_DEFEAT());
            event::emit(DefeatEvt { room_id });
            return;
        };

        let all_enemies_dead = true;
        let elen = vector::length(&room.enemies);
        let i = 0;
        while (i < elen) {
            let alive = types::enemy_alive(vector::borrow(&room.enemies, i));
            if (alive) { all_enemies_dead = false; break; };
            i = i + 1;
        };

        if (all_enemies_dead && elen > 0) {
            if (room.battle_index < room.total_battles) {
                room.phase = 3;
                event::emit(BattleCleared { room_id, battle_index: room.battle_index, total_battles: room.total_battles });
            } else {
                settle_rewards(room, room_id); // 存活者按随机权重分配奖池(§6.1)
                release_all(room, true);       // 释放角色锁 + 履历(通关)
                mark_settled(room, RESULT_VICTORY());
                event::emit(VictoryEvt { room_id });
            };
            return;
        };

        // Turn-limit timeout: the room is cleared (party evicted) if a battle
        // drags past the dungeon's per-battle turn budget without resolution.
        let dungeon = skill_registry::get_dungeon(room.difficulty as u64);
        let turn_budget = types::dungeon_turn_interval(&dungeon);
        if (turn_budget > 0 && room.battle_turns > turn_budget) {
            settle_timeout(room, room_id);
        };
    }

    // ============================ internal: targeting ============================

    /// 可被选为目标的玩家成员：存活且**已到场**。§2.6.8 迟到成员在倒计时归零前不参与任何
    /// 目标选择（含 AoE/ROOM_ALL）—— 此前只有加权随机池过滤了 arrive_delay, 三个全体分支漏了(§2.6.11)。
    fun selectable_member(room: &Room, i: u64): bool {
        let m = vector::borrow(&room.members, i);
        types::member_alive(m) && types::member_arrive_delay(m) == 0
    }

    fun select_targets(
        room: &mut Room, targeting: u8, target_count: u8,
        actor_is_enemy: bool, actor_idx: u64, weight_mode: u8,
    ): vector<Target> {
        let targets = vector::empty<Target>();

        if (targeting == 9) { // SELF
            vector::push_back(&mut targets, types::make_target(actor_is_enemy, actor_idx));
        } else if (targeting == 4) { // ALL_ENEMY
            if (actor_is_enemy) {
                // Enemy's enemies are members
                let len = vector::length(&room.members);
                let i = 0;
                while (i < len) {
                    if (selectable_member(room, i)) {
                        vector::push_back(&mut targets, types::make_target(false, i));
                    };
                    i = i + 1;
                };
            } else {
                let len = vector::length(&room.enemies);
                let i = 0;
                while (i < len) {
                    if (types::enemy_alive(vector::borrow(&room.enemies, i))) {
                        vector::push_back(&mut targets, types::make_target(true, i));
                    };
                    i = i + 1;
                };
            };
        } else if (targeting == 7) { // ALL_ALLY
            if (actor_is_enemy) {
                let len = vector::length(&room.enemies);
                let i = 0;
                while (i < len) {
                    if (types::enemy_alive(vector::borrow(&room.enemies, i))) {
                        vector::push_back(&mut targets, types::make_target(true, i));
                    };
                    i = i + 1;
                };
            } else {
                let len = vector::length(&room.members);
                let i = 0;
                while (i < len) {
                    if (selectable_member(room, i)) {
                        vector::push_back(&mut targets, types::make_target(false, i));
                    };
                    i = i + 1;
                };
            };
        } else if (targeting == 8) { // ROOM_ALL
            let mlen = vector::length(&room.members);
            let i = 0;
            while (i < mlen) {
                if (selectable_member(room, i)) {
                    vector::push_back(&mut targets, types::make_target(false, i));
                };
                i = i + 1;
            };
            let elen = vector::length(&room.enemies);
            let j = 0;
            while (j < elen) {
                if (types::enemy_alive(vector::borrow(&room.enemies, j))) {
                    vector::push_back(&mut targets, types::make_target(true, j));
                };
                j = j + 1;
            };
        } else if (targeting == 10) { // MOST_WOUNDED_ALLY
            if (actor_is_enemy) {
                let best_idx: u64 = 0;
                let best_deficit: u64 = 0;
                let found = false;
                let len = vector::length(&room.enemies);
                let i = 0;
                while (i < len) {
                    let e = vector::borrow(&room.enemies, i);
                    if (types::enemy_alive(e)) {
                        let deficit = types::enemy_max_hp(e) - types::enemy_hp(e);
                        if (deficit > best_deficit || !found) {
                            best_deficit = deficit;
                            best_idx = i;
                            found = true;
                        };
                    };
                    i = i + 1;
                };
                if (found) {
                    vector::push_back(&mut targets, types::make_target(true, best_idx));
                };
            } else {
                let best_idx: u64 = 0;
                let best_deficit: u64 = 0;
                let found = false;
                let len = vector::length(&room.members);
                let i = 0;
                while (i < len) {
                    let m = vector::borrow(&room.members, i);
                    let alive = types::member_alive(m);
                    let summon = types::member_is_summon(m);
                    if (alive && !summon) {
                        let deficit = types::member_max_hp(m) - types::member_hp(m);
                        if (deficit > best_deficit || !found) {
                            best_deficit = deficit;
                            best_idx = i;
                            found = true;
                        };
                    };
                    i = i + 1;
                };
                if (found) {
                    vector::push_back(&mut targets, types::make_target(false, best_idx));
                };
            };
        } else {
            // TAUNT(op11, 守卫盾击拉怪): 敌方单体攻击(RAND_SINGLE, targeting==1)的目标选择
            // 先扫描我方存活嘲讽者, 取最早者强制重定向; 多体/全体/我方技能不受影响。
            if (actor_is_enemy && targeting == 1) {
                let tl = vector::length(&room.members);
                let ti = 0;
                while (ti < tl) {
                    let tm = vector::borrow(&room.members, ti);
                    if (types::member_alive(tm) && types::member_has_effect(tm, 11)) {
                        vector::push_back(&mut targets, types::make_target(false, ti));
                        return targets;
                    };
                    ti = ti + 1;
                };
            };
            // Random targeting: 1-3 = enemy side, 5-6 = ally side
            let targets_enemies = if (actor_is_enemy) {
                targeting >= 5 && targeting <= 7
            } else {
                targeting >= 1 && targeting <= 4
            };
            // 候选池 + 权重（§4.2 权重随机，玩家仍不可指定目标）：
            //   默认均匀(权重 1)；治疗/辅助可声明按**生命亏空**加权(weight=亏空+1，满血也可能被抽中)；
            //   敌人可带**威胁权重**(weight=threat+1，Boss/召唤师更易被抽中但不保证)。
            let len = if (targets_enemies) { vector::length(&room.enemies) } else { vector::length(&room.members) };
            let cand = vector::empty<u64>();
            let wts = vector::empty<u64>();
            let i = 0;
            while (i < len) {
                if (targets_enemies) {
                    let e = vector::borrow(&room.enemies, i);
                    if (types::enemy_alive(e)) {
                        let w = if (weight_mode == 2) { (types::enemy_threat(e) as u64) + 1 } else { 1 };
                        vector::push_back(&mut cand, i);
                        vector::push_back(&mut wts, w);
                    };
                } else {
                    if (selectable_member(room, i)) {
                        let m = vector::borrow(&room.members, i);
                        let w = if (weight_mode == 1) {
                            types::member_max_hp(m) - types::member_hp(m) + 1
                        } else { 1 };
                        vector::push_back(&mut cand, i);
                        vector::push_back(&mut wts, w);
                    };
                };
                i = i + 1;
            };
            // 多体技能抽 N 个**不重复**目标
            let count = if (targeting == 2 || targeting == 6) { target_count as u64 } else { 1 };
            let mut_c = 0;
            while (mut_c < count && vector::length(&cand) > 0) {
                let total: u64 = 0;
                let k = 0;
                while (k < vector::length(&wts)) { total = total + *vector::borrow(&wts, k); k = k + 1; };
                let mut_rng_t = mohayo::rng::new(room.rng_seed + mut_c * 7 + room.turn_id * 100);
                let roll = mohayo::rng::below(&mut mut_rng_t, total);
                room.rng_seed = room.rng_seed + 1;
                let acc: u64 = 0;
                let pick: u64 = 0;
                let found = false;
                let j = 0;
                while (j < vector::length(&cand)) {
                    acc = acc + *vector::borrow(&wts, j);
                    if (roll < acc) { pick = j; found = true; break; };
                    j = j + 1;
                };
                if (!found) { pick = vector::length(&cand) - 1; };
                let idx = *vector::borrow(&cand, pick);
                vector::push_back(&mut targets, types::make_target(targets_enemies, idx));
                vector::remove(&mut cand, pick);
                vector::remove(&mut wts, pick);
                mut_c = mut_c + 1;
            };
        };
        targets
    }

    // ============================ test helpers ============================

    /// 测试钩子: 直接设定某成员当前 HP(用于构造"残血"场景验证治疗加权目标)。
    #[test_only]
    public fun test_set_member_hp(account: &signer, room_id: u64, index: u64, hp: u64) acquires RoomStore {
        let _ = account;
        let rs = borrow_global_mut<RoomStore>(@mohayo);
        let room = table::borrow_mut(&mut rs.rooms, room_id);
        types::member_set_hp(vector::borrow_mut(&mut room.members, index), hp);
    }

    /// 测试钩子: 给某成员直接挂一条效果(用于构造命中率被压低的场景)。
    #[test_only]
    public fun test_add_member_effect(
        account: &signer, room_id: u64, index: u64, op: u8, dur: u8, mag: u16,
    ) acquires RoomStore {
        let _ = account;
        let rs = borrow_global_mut<RoomStore>(@mohayo);
        let room = table::borrow_mut(&mut rs.rooms, room_id);
        types::member_add_effect(
            vector::borrow_mut(&mut room.members, index),
            types::make_active_effect(op, dur, mag, 0),
        );
    }

    #[test_only]
    public fun init_for_test(account: &signer) {
        if (!exists<RoomStore>(signer::address_of(account))) {
            move_to(account, RoomStore {
                rooms: table::new(),
                active: vector::empty(),
                active_index: table::new(),
                room_ttl: 7200,
                reclaim_delay: DEFAULT_RECLAIM_DELAY,
                weekly_mutators: table::new(),
            });
        };
    }

    /// 测试钩子: 初始化 aptos_framework 时间戳（推进冷却与参与次数窗口都读它）。
    /// 放在 engine 是为了让 tests / sim 共用一份 —— 此前两边各有一份逐字相同的实现。
    #[test_only]
    public fun init_timestamp_for_test() {
        let f = &std::account::create_account_for_test(@aptos_framework);
        aptos_framework::timestamp::set_time_has_started_for_testing(f);
        aptos_framework::timestamp::update_global_time_for_test_secs(1760000000);
    }

    /// 测试钩子: 过掉 ≥2 秒的推进冷却后, 以**当前 turn_id** 推进一回合
    /// —— 同时覆盖 §4.1 自动/手动同入口与 §3.1 的「turnId 单调 + 冷却」两道防重。
    #[test_only]
    public fun step_for_test(who: &signer, room_id: u64) acquires RoomStore {
        let t = aptos_framework::timestamp::now_seconds();
        aptos_framework::timestamp::update_global_time_for_test_secs(t + 2);
        advance_turn_test(who, room_id, room_turn(room_id));
    }

    /// 测试钩子：走**生产入口**（私有 `#[randomness] entry`）开战，用于验证真实随机数路径能跑通。
    /// 测试环境下 `is_unbiasable` 为真，所以模块内可以直接调用自己的 entry(§2.6.14)。
    /// `#[lint::allow_unsafe_randomness]` 只为绕过「public 函数不得暴露随机数」的 lint ——
    /// 这两个钩子是 `#[test_only]`，不会进发布产物。
    #[test_only]
    #[lint::allow_unsafe_randomness]
    public fun test_production_start_combat(account: &signer, room_id: u64) acquires RoomStore {
        start_combat(account, room_id);
    }

    /// 测试钩子：走生产入口推进一回合（同样消费协议随机数）。
    #[test_only]
    #[lint::allow_unsafe_randomness]
    public fun test_production_advance_turn(
        account: &signer, room_id: u64, expected_turn_id: u64,
    ) acquires RoomStore {
        advance_turn(account, room_id, expected_turn_id);
    }
}

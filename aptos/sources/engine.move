/// Mohayo combat engine — Aptos Move rewrite.
/// Uses types, skill_registry, character, economy modules.
module mohayo::engine {
    use aptos_framework::event;
    use aptos_std::table::{Self, Table};
    use std::signer;
    use std::vector;
    use mohayo::types::{Self, Skill, Member, Enemy, Target};
    use mohayo::skill_registry;
    use mohayo::character;

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

    // ============================ resource ============================

    struct RoomStore has key {
        rooms: Table<u64, Room>,
    }

    struct Room has store {
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
        leader: address,
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
    struct TurnAdvanced has drop, store { room_id: u64, turn_id: u64 }
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

    // ============================ init ============================

    fun init_module(account: &signer) {
        move_to(account, RoomStore { rooms: table::new() });
    }

    // ============================ room lifecycle ============================

    public entry fun create_room(account: &signer, difficulty: u64) acquires RoomStore {
        let addr = signer::address_of(account);
        let dungeon = skill_registry::get_dungeon(difficulty);
        let rid = skill_registry::consume_next_room_id();
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
            leader: addr,
            rng_seed: rid * 1000 + 1,
            members: vector::empty(),
            enemies: vector::empty(),
        };
        table::add(&mut rs.rooms, rid, room);
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
        assert!(room.phase == 0 || room.phase == 3, E_NOT_JOINABLE);
        assert!(vector::length(&room.members) < 10, E_ROOM_FULL);
        let member = types::make_member(
            max_hp, max_hp, attack, magic, speed,
            0, 0, 0, 0, 0, 0,
            vector::empty(), vector::empty(), 0,
            true, false, signer::address_of(account), 0,
        );
        vector::push_back(&mut room.members, member);
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
        assert!(room.phase == 0 || room.phase == 3, E_NOT_JOINABLE);
        assert!(vector::length(&room.members) < 10, E_ROOM_FULL);
        let member = types::make_member(
            max_hp, max_hp, attack, magic, speed,
            0, mana_discount, ap_discount, ap_bonus, mana_gain_bonus,
            0, vector::empty(), vector::empty(), 0, true, false,
            signer::address_of(account), 0,
        );
        vector::push_back(&mut room.members, member);
        event::emit(MemberJoined { room_id, player: signer::address_of(account) });
    }

    /// Production join: binds this room slot to `char_id`. The caller must own
    /// the character (技能权威源 = Character.skill_ids, 存在角色自身存储)。成员只携带
    /// owner + char_id 引用 —— 不复制技能集进房间(省 gas)，计划提交时按需校验。
    public entry fun join_room_as_char(
        account: &signer, room_id: u64, char_id: u64,
    ) acquires RoomStore {
        assert!(character::char_owner(char_id) == signer::address_of(account), E_NOT_PLAN_OWNER);
        let (_hp, max_hp, atk, mag, spd) = character::get_stats(char_id);
        let rs = borrow_global_mut<RoomStore>(@mohayo);
        let room = table::borrow_mut(&mut rs.rooms, room_id);
        assert!(room.phase == 0 || room.phase == 3, E_NOT_JOINABLE);
        assert!(vector::length(&room.members) < 10, E_ROOM_FULL);
        let member = types::make_member(
            max_hp, max_hp, atk, mag, spd,
            0, 0, 0, 0, 0, 0,
            vector::empty(), vector::empty(), 0,
            true, false, signer::address_of(account), char_id,
        );
        vector::push_back(&mut room.members, member);
        event::emit(MemberJoined { room_id, player: signer::address_of(account) });
    }

    public entry fun leave_room(account: &signer, room_id: u64) acquires RoomStore {
        let addr = signer::address_of(account);
        let rs = borrow_global_mut<RoomStore>(@mohayo);
        let room = table::borrow_mut(&mut rs.rooms, room_id);
        assert!(room.phase == 0, E_NOT_LOBBY);
        event::emit(MemberLeft { room_id, player: addr });
    }

    // ============================ combat start ============================

    public entry fun start_combat(account: &signer, room_id: u64) acquires RoomStore {
        let addr = signer::address_of(account);
        let rs = borrow_global_mut<RoomStore>(@mohayo);
        let room = table::borrow_mut(&mut rs.rooms, room_id);
        assert!(room.phase == 0, E_NOT_LOBBY);
        assert!(vector::length(&room.members) > 0, E_NO_MEMBERS);
        assert!(room.leader == addr, E_NOT_LEADER);
        room.phase = 1;
        room.turn_id = 1;
        room.rng_seed = room_id * 1000 + 1;
        room.mana_pool = room.mana_per_turn;
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
                    assert!(character::char_owns_skill(cid, *vector::borrow(&plan, pi)), E_SKILL_NOT_OWNED);
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

    public entry fun advance_turn(account: &signer, room_id: u64) acquires RoomStore {
        let rs = borrow_global_mut<RoomStore>(@mohayo);
        let room = table::borrow_mut(&mut rs.rooms, room_id);
        assert!(room.phase == 1, E_NOT_COMBAT);
        advance_turn_inner(room, room_id);
    }

    fun advance_turn_inner(room: &mut Room, room_id: u64) {
        room.turn_id = room.turn_id + 1;
        room.battle_turns = room.battle_turns + 1;
        tick_all_effects(room, room_id);
        act_all(room, room_id);
        let mut_delta = room.mana_per_turn;
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
        event::emit(TurnAdvanced { room_id, turn_id: room.turn_id });
    }

    // ============================ battle advancement ============================

    public entry fun advance_battle(account: &signer, room_id: u64) acquires RoomStore {
        let addr = signer::address_of(account);
        let rs = borrow_global_mut<RoomStore>(@mohayo);
        let room = table::borrow_mut(&mut rs.rooms, room_id);
        assert!(room.phase == 3, E_NOT_INTERMISSION);
        assert!(room.leader == addr, E_NOT_LEADER);
        assert!(room.battle_index < room.total_battles, E_LAST_BATTLE);
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
        // 0 = unresolved, 1 = victory, 2 = defeat/evicted
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
                    break;
                };
                vi = vi + 1;
            };
        };

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
        while (spawned < enemy_count && vector::length(&room.enemies) < 10) {
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
            0,
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

    fun act_all(room: &mut Room, room_id: u64) {
        let mlen = vector::length(&room.members);
        let i = 0;
        while (i < mlen) {
            let alive = types::member_alive(vector::borrow(&room.members, i));
            let is_summon = types::member_is_summon(vector::borrow(&room.members, i));
            let stunned = types::member_has_effect(vector::borrow(&room.members, i), 1);
            if (alive && !is_summon && !stunned) {
                act_member(room, room_id, i);
            };
            i = i + 1;
        };
        let elen = vector::length(&room.enemies);
        let j = 0;
        while (j < elen) {
            let alive = types::enemy_alive(vector::borrow(&room.enemies, j));
            let stunned = types::enemy_has_effect(vector::borrow(&room.enemies, j), 1);
            if (alive && !stunned) {
                act_enemy(room, room_id, j);
            };
            j = j + 1;
        };
    }

    fun act_member(room: &mut Room, room_id: u64, idx: u64) {
        let plan_len = vector::length(types::member_plan(vector::borrow(&room.members, idx)));
        if (plan_len == 0) return;
        let m = vector::borrow_mut(&mut room.members, idx);
        let cur_ap = (types::member_ap(m) as u64);
        let bonus_ap = (types::member_ap_bonus(m) as u64);
        let new_ap = cur_ap + 1 + bonus_ap;
        types::member_set_ap(m, if (new_ap > 22) { 22 } else { new_ap as u16 });
        let cur_plan_start = types::member_plan_start(m);
        let plan_idx = cur_plan_start % (plan_len as u64);
        let plan_ref = types::member_plan(m);
        let skill_id = *vector::borrow(plan_ref, plan_idx);
        types::member_set_plan_start(m, cur_plan_start + 1);
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
        let e_mut = vector::borrow_mut(&mut room.enemies, idx);
        let cur_turn = types::enemy_turn_counter(e_mut);
        types::enemy_set_turn_counter(e_mut, cur_turn + 1);
        let s = skill_registry::get_skill(skill_id);
        execute_skill(room, room_id, idx, true, &s);
    }

    fun execute_skill(room: &mut Room, room_id: u64, actor_idx: u64, actor_is_enemy: bool, s: &Skill) {
        let mana_cost = apply_mana_discount(room, actor_idx, actor_is_enemy, types::skill_mana_cost(s));
        let ap_cost = apply_ap_discount(room, actor_idx, actor_is_enemy, types::skill_ap_cost(s));
        if (mana_cost > room.mana_pool) return;
        if (!actor_is_enemy) {
            let m = vector::borrow(&room.members, actor_idx);
            if ((types::member_ap(m) as u64) < (ap_cost as u64)) return;
        };
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

        let targets = select_targets(room, targeting, types::skill_target_count(s), actor_is_enemy, actor_idx);

        let strikes = if (targeting == 3) { types::skill_target_count(s) as u64 } else { 1 };
        let mut_strike = 0;
        while (mut_strike < strikes) {
            let tlen = vector::length(&targets);
            let k = 0;
            while (k < tlen) {
                let t = vector::borrow(&targets, k);
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
            if (new_ap > 22) {
                types::member_set_ap(m, 22);
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
            let base_acc = (types::skill_base_acc(s) as i64);
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
        if (power > 0 && (s_kind == 1 || s_kind == 2)) {
            let stat = if (s_kind == 2) {
                if (actor_is_enemy) { types::enemy_magic(vector::borrow(&room.enemies, actor_idx)) }
                else { types::member_magic(vector::borrow(&room.members, actor_idx)) }
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
            let _scope = types::effect_scope(eff_spec);

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
                let ae = types::make_active_effect(op, dur, mag, types::skill_id(s));
                if (t_is_enemy) {
                    types::enemy_add_effect(vector::borrow_mut(&mut room.enemies, t_idx), ae);
                } else {
                    types::member_add_effect(vector::borrow_mut(&mut room.members, t_idx), ae);
                };
                event::emit(EffectApplied { room_id, is_enemy: t_is_enemy, index: t_idx, op, magnitude: mag, duration: dur });
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
            if (vector::length(&room.members) < 10) {
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
            let count = types::summon_rule_max_count(sr) as u64;
            let j = 0;
            while (j < count && vector::length(&room.enemies) < 10) {
                let idx = vector::length(&room.enemies);
                let e = spawn_enemy_with(stid);
                vector::push_back(&mut room.enemies, e);
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
                while (j < (ods_count as u64) && vector::length(&room.enemies) < 10) {
                    let new_e = spawn_enemy_with(ods_tid);
                    let new_idx = vector::length(&room.enemies);
                    vector::push_back(&mut room.enemies, new_e);
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
    }

    // ============================ internal: end check ============================

    fun check_end(room: &mut Room, room_id: u64) {
        // Defeat is checked FIRST: a mutual wipe (party dies the same action the
        // last enemy dies) is a loss, never a victory — the party must SURVIVE to win.
        let all_members_dead = true;
        let mlen = vector::length(&room.members);
        let j = 0;
        while (j < mlen) {
            let alive = types::member_alive(vector::borrow(&room.members, j));
            if (alive) { all_members_dead = false; break; };
            j = j + 1;
        };
        if (all_members_dead && mlen > 0) {
            room.phase = 2;
            room.result = 2;
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
                room.phase = 2;
                room.result = 1;
                let share = room.reward_pool;
                room.reward_pool = 0;
                event::emit(VictoryEvt { room_id });
                let _ = share;
            };
            return;
        };

        // Turn-limit timeout: the room is cleared (party evicted) if a battle
        // drags past the dungeon's per-battle turn budget without resolution.
        let dungeon = skill_registry::get_dungeon(room.difficulty as u64);
        let turn_budget = types::dungeon_turn_interval(&dungeon);
        if (turn_budget > 0 && room.battle_turns > turn_budget) {
            room.phase = 2;
            room.result = 2;
            event::emit(DefeatEvt { room_id });
        };
    }

    // ============================ internal: targeting ============================

    fun select_targets(
        room: &mut Room, targeting: u8, target_count: u8,
        actor_is_enemy: bool, actor_idx: u64,
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
                    if (types::member_alive(vector::borrow(&room.members, i))) {
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
                    if (types::member_alive(vector::borrow(&room.members, i))) {
                        vector::push_back(&mut targets, types::make_target(false, i));
                    };
                    i = i + 1;
                };
            };
        } else if (targeting == 8) { // ROOM_ALL
            let mlen = vector::length(&room.members);
            let i = 0;
            while (i < mlen) {
                if (types::member_alive(vector::borrow(&room.members, i))) {
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
            let len = if (targets_enemies) { vector::length(&room.enemies) } else { vector::length(&room.members) };
            let count = if (targeting == 2 || targeting == 6) { target_count as u64 } else { 1 };
            let mut_c = 0;
            while (mut_c < count && mut_c < len) {
                let mut_tries = 0;
                while (mut_tries < 20) {
                    let mut_rng_t = mohayo::rng::new(room.rng_seed + mut_c + mut_tries + room.turn_id * 100);
                    let idx = mohayo::rng::below(&mut mut_rng_t, len);
                    room.rng_seed = room.rng_seed + 1;
                    if (targets_enemies) {
                        if (types::enemy_alive(vector::borrow(&room.enemies, idx))) {
                            vector::push_back(&mut targets, types::make_target(true, idx));
                            break;
                        };
                    } else {
                        if (types::member_alive(vector::borrow(&room.members, idx))) {
                            vector::push_back(&mut targets, types::make_target(false, idx));
                            break;
                        };
                    };
                    mut_tries = mut_tries + 1;
                };
                mut_c = mut_c + 1;
            };
        };
        targets
    }

    // ============================ test helpers ============================

    #[test_only]
    public fun init_for_test(account: &signer) {
        if (!exists<RoomStore>(signer::address_of(account))) {
            move_to(account, RoomStore { rooms: table::new() });
        };
    }
}

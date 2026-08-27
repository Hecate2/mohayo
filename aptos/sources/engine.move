// Mohayo combat engine — Aptos Move port
// Architecture:
//   Registry  @0x88080  — static data (skills, AIs, templates, tables, dungeons)
//   RoomStore @0x88080  — mutable rooms table (separate type allows simultaneous borrow)
//   RNG is stored in Room and threaded via &mut Room.rng through all internal functions.
//   Tests inject a fixed seed via start_combat_test / set_room_rng.

module mohayo::engine {
    use aptos_framework::event;
    use aptos_framework::randomness;
    use aptos_std::table::{Self, Table};
    use std::signer;
    use std::vector;
    use mohayo::rng::{Self, Rng};

    // ============================ errors ============================
    const E_NOT_INITIALIZED: u64 = 1;
    const E_ROOM_NOT_FOUND: u64 = 3;
    const E_BAD_INDEX: u64 = 4;
    const E_NOT_IN_ROOM: u64 = 5;
    const E_NOT_LEADER: u64 = 6;
    const E_NOT_LOBBY: u64 = 7;
    const E_NOT_COMBAT: u64 = 8;
    const E_NOT_JOINABLE: u64 = 9;
    const E_ROOM_FULL: u64 = 10;
    const E_UNKNOWN_SKILL: u64 = 11;
    const E_UNKNOWN_TEMPLATE: u64 = 12;
    const E_UNKNOWN_DIFFICULTY: u64 = 13;
    const E_NO_MEMBERS: u64 = 14;
    const E_BAD_CONFIG: u64 = 16;
    const E_NOT_INTERMISSION: u64 = 17;
    const E_LAST_BATTLE: u64 = 18;
    const E_UNKNOWN_TABLE: u64 = 20;
    const E_UNKNOWN_AI: u64 = 21;

    // ============================ enums ============================
    const KIND_PHYSICAL: u8 = 1;
    const KIND_MAGIC: u8 = 2;
    const KIND_SUPPORT: u8 = 3;
    const KIND_SUMMON: u8 = 4;

    const TGT_RAND_SINGLE_ENEMY: u8 = 1;
    const TGT_RAND_MULTI_ENEMY: u8 = 2;
    const TGT_RAND_STRIKE_ENEMY: u8 = 3;
    const TGT_ALL_ENEMY: u8 = 4;
    const TGT_RAND_SINGLE_ALLY: u8 = 5;
    const TGT_RAND_MULTI_ALLY: u8 = 6;
    const TGT_ALL_ALLY: u8 = 7;
    const TGT_ROOM_ALL: u8 = 8;
    const TGT_SELF: u8 = 9;
    const TGT_MOST_WOUNDED_ALLY: u8 = 10;

    const WT_UNIFORM: u8 = 0;
    const WT_HP_DEFICIT_ALLY: u8 = 1;
    const WT_THREAT_ENEMY: u8 = 2;

    const FLAG_GUARANTEED_HIT: u8 = 1;
    const FLAG_MANA_ALL: u8 = 2;
    const FLAG_SUMMON_ALLY: u8 = 4;

    const SCOPE_SELF: u8 = 0;
    const SCOPE_TARGET: u8 = 1;
    const SCOPE_ALL_ALLY: u8 = 2;
    const SCOPE_ALL_ENEMY: u8 = 3;

    const OP_STUN: u8 = 1;
    const OP_DMG_OUT_MOD: u8 = 2;
    const OP_DMG_IN_MOD: u8 = 3;
    const OP_SHIELD: u8 = 4;
    const OP_EVADE_UP: u8 = 5;
    const OP_ACC_DOWN: u8 = 6;
    const OP_GUAR_NEXT: u8 = 7;
    const OP_DOT: u8 = 8;
    const OP_HEAL: u8 = 9;
    const OP_DISPEL: u8 = 10;
    const OP_TAUNT: u8 = 11;
    const OP_LIFESTEAL: u8 = 12;
    const OP_MANA_DELTA: u8 = 13;
    const OP_SUMMON: u8 = 14;

    const PHASE_LOBBY: u8 = 0;
    const PHASE_COMBAT: u8 = 1;
    const PHASE_SETTLED: u8 = 2;
    const PHASE_INTERMISSION: u8 = 3;

    // ============================ constants ============================
    const MAX_MEMBERS: u64 = 10;
    const MAX_ENEMIES: u64 = 10;
    const MAX_EFFECTS: u64 = 6;
    const MAX_PLAN: u64 = 16;
    const MAX_SKILL_EFFECTS: u64 = 4;
    const MAX_STRIKES: u64 = 8;
    const MAX_DIFFICULTY: u64 = 10;
    const MAX_ROOMS: u64 = 1000;
    const MAX_PLAN_SKILLS: u64 = 8;
    const AP_CAP_BASE: u64 = 22;
    const MIN_HIT_RATE: u64 = 50;
    const TIMEOUT_HP_PCT: u64 = 10;

    // ============================ constructors (for tests/external callers) ============================
    public fun make_effect_spec(op: u8, duration: u8, magnitude: u64, scope: u8, prob: u64): EffectSpec {
        EffectSpec { op, duration, magnitude, scope, prob }
    }
    public fun make_summon_rule(template_id: u64, max_count: u64, enemy_headroom: u64): SummonRule {
        SummonRule { template_id, max_count, enemy_headroom }
    }
    public fun make_skill(
        id: u64, kind: u8, ap_cost: u64, ap_gain: u64,
        ammo_id: u64, ammo_cost: u64, mana_cost: u64, hp_cost: u64,
        targeting: u8, weight_mode: u8, target_count: u64,
        power: u64, damage_cap: u64, base_acc: u64, flags: u8,
        effects: vector<EffectSpec>, summon: SummonRule
    ): Skill {
        Skill { id, kind, ap_cost, ap_gain, ammo_id, ammo_cost, mana_cost, hp_cost,
                targeting, weight_mode, target_count, power, damage_cap, base_acc, flags,
                effects, summon }
    }
    public fun make_on_death_spawn(template_id: u64, count: u64, prob: u64): OnDeathSpawn {
        OnDeathSpawn { template_id, count, prob }
    }
    public fun make_enemy_template(
        ai_id: u64, threat: u64, max_hp: u64, power: u64, magic: u64,
        speed: u64, base_acc: u64, reward_min: u64, reward_max: u64,
        on_death_spawn: OnDeathSpawn
    ): EnemyTemplate {
        EnemyTemplate { ai_id, threat, max_hp, power, magic, speed, base_acc,
                        reward_min, reward_max, on_death_spawn }
    }
    public fun make_table_entry(template_id: u64, weight: u64): TableEntry {
        TableEntry { template_id, weight }
    }
    public fun make_variant_entry(table_id: u64, weight: u64): VariantEntry {
        VariantEntry { table_id, weight }
    }
    public fun make_battle_config(table_id: u64, enemy_count: u64): BattleConfig {
        BattleConfig { table_id, enemy_count }
    }
    public fun make_dungeon_config(
        table_id: u64, enemy_count: u64, mana_per_turn: u64, reward_base: u64,
        entry_fee: u64, rescue_fee: u64, turn_interval: u64, battles: u64
    ): DungeonConfig {
        DungeonConfig { table_id, enemy_count, mana_per_turn, reward_base,
                        entry_fee, rescue_fee, turn_interval, battles }
    }

    // ============================ data types ============================
    struct EffectSpec has copy, drop, store {
        op: u8, duration: u8, magnitude: u64, scope: u8, prob: u64,
    }
    struct SummonRule has copy, drop, store {
        template_id: u64, max_count: u64, enemy_headroom: u64,
    }
    struct Skill has copy, drop, store {
        id: u64, kind: u8, ap_cost: u64, ap_gain: u64,
        ammo_id: u64, ammo_cost: u64, mana_cost: u64, hp_cost: u64,
        targeting: u8, weight_mode: u8, target_count: u64,
        power: u64, damage_cap: u64, base_acc: u64, flags: u8,
        effects: vector<EffectSpec>, summon: SummonRule,
    }
    struct MonsterAI has copy, drop, store { skill_cycle: vector<u64> }
    struct OnDeathSpawn has copy, drop, store {
        template_id: u64, count: u64, prob: u64,
    }
    struct EnemyTemplate has copy, drop, store {
        ai_id: u64, threat: u64, max_hp: u64, power: u64, magic: u64,
        speed: u64, base_acc: u64, reward_min: u64, reward_max: u64,
        on_death_spawn: OnDeathSpawn,
    }
    struct TableEntry has copy, drop, store { template_id: u64, weight: u64 }
    struct VariantEntry has copy, drop, store { table_id: u64, weight: u64 }
    struct BattleConfig has copy, drop, store { table_id: u64, enemy_count: u64 }
    struct DungeonConfig has copy, drop, store {
        table_id: u64, enemy_count: u64, mana_per_turn: u64, reward_base: u64,
        entry_fee: u64, rescue_fee: u64, turn_interval: u64, battles: u64,
    }
    struct ActiveEffect has copy, drop, store {
        op: u8, duration: u8, magnitude: u64, source_id: u64,
    }
    struct Member has copy, drop, store {
        owner: address, hp: u64, max_hp: u64, attack: u64, magic: u64,
        speed: u64, ap: u64, mana_discount: u64, ap_discount: u64,
        ap_bonus: u64, mana_gain_bonus: i64,
        is_summon: bool, alive: bool,
        effects: vector<ActiveEffect>, plan: vector<u64>, plan_start: u64,
    }
    struct Enemy has copy, drop, store {
        template_id: u64, hp: u64, max_hp: u64, attack: u64, magic: u64,
        speed: u64, base_acc: u64, threat: u64, ai_id: u64,
        turn_counter: u64, alive: bool, effects: vector<ActiveEffect>,
    }
    struct Target has copy, drop, store { is_enemy: bool, index: u64 }
    struct Room has store {
        id: u64, difficulty: u64, phase: u8, battle_index: u64,
        total_battles: u64, turn_id: u64, mana_pool: u64, mana_per_turn: u64,
        reward_pool: u64, leader: address, boss_spawned: bool,
        turn_interval: u64, rng: Rng,
        members: vector<Member>, enemies: vector<Enemy>,
        vault: Table<u64, Table<u64, u64>>,
    }

    // Two resources at @mohayo — different types, simultaneous borrow allowed.
    struct Registry has key {
        skills: Table<u64, Skill>,
        ais: Table<u64, MonsterAI>,
        templates: Table<u64, EnemyTemplate>,
        tables: Table<u64, vector<TableEntry>>,
        dungeons: Table<u64, DungeonConfig>,
        battles: Table<u64, vector<BattleConfig>>,
        variants: Table<u64, vector<VariantEntry>>,
        battle_variants: Table<u64, Table<u64, vector<VariantEntry>>>,
        next_room_id: u64,
    }
    struct RoomStore has key {
        rooms: Table<u64, Room>,
    }

    // ============================ events ============================
    #[event]
    struct RoomCreated has copy, drop, store { room_id: u64, leader: address }
    #[event]
    struct MemberJoined has copy, drop, store { room_id: u64, player: address }
    #[event]
    struct MemberLeft has copy, drop, store { room_id: u64, player: address }
    #[event]
    struct CombatStarted has copy, drop, store { room_id: u64, battle_index: u64 }
    #[event]
    struct PlanSet has copy, drop, store { room_id: u64, player: address }
    #[event]
    struct TurnAdvanced has copy, drop, store { room_id: u64, turn_id: u64 }
    #[event]
    struct UnitActed has copy, drop, store { room_id: u64, is_enemy: bool, index: u64, skill_id: u64 }
    #[event]
    struct DamageDealt has copy, drop, store { room_id: u64, is_enemy: bool, index: u64, amount: u64, hp_left: u64 }
    #[event]
    struct HealedEvt has copy, drop, store { room_id: u64, is_enemy: bool, index: u64, amount: u64 }
    #[event]
    struct EffectApplied has copy, drop, store { room_id: u64, is_enemy: bool, index: u64, op: u8, magnitude: u64, duration: u8 }
    #[event]
    struct UnitDied has copy, drop, store { room_id: u64, is_enemy: bool, index: u64 }
    #[event]
    struct EnemySpawned has copy, drop, store { room_id: u64, index: u64, template_id: u64 }
    #[event]
    struct MemberSummoned has copy, drop, store { room_id: u64, index: u64, template_id: u64 }
    #[event]
    struct ManaChanged has copy, drop, store { room_id: u64, pool: u64 }
    #[event]
    struct VictoryEvt has copy, drop, store { room_id: u64 }
    #[event]
    struct DefeatEvt has copy, drop, store { room_id: u64 }
    #[event]
    struct BattleCleared has copy, drop, store { room_id: u64, battle_index: u64, total_battles: u64 }
    #[event]
    struct BattleAdvanced has copy, drop, store { room_id: u64, new_battle_index: u64 }
    #[event]
    struct RewardDistributed has copy, drop, store { room_id: u64, player: address, amount: u64 }
    #[event]
    struct ItemGiven has copy, drop, store { room_id: u64, from: address, to: address, item_id: u64, count: u64 }

    // ============================ init ============================
    fun init_module(account: &signer) {
        let addr = signer::address_of(account);
        move_to(account, Registry {
            skills: table::new(), ais: table::new(), templates: table::new(),
            tables: table::new(), dungeons: table::new(), battles: table::new(),
            variants: table::new(), battle_variants: table::new(), next_room_id: 1,
        });
        move_to(account, RoomStore { rooms: table::new() });
    }

    #[test_only]
    public fun init_for_test(account: &signer) {
        let addr = signer::address_of(account);
        // Resources must live at @mohayo for all functions to find them.
        // If the signer is not @mohayo, we still need to publish there.
        // In tests, we call this with a signer at @mohayo.
        if (!exists<Registry>(@mohayo)) {
            move_to(account, Registry {
                skills: table::new(), ais: table::new(), templates: table::new(),
                tables: table::new(), dungeons: table::new(), battles: table::new(),
                variants: table::new(), battle_variants: table::new(), next_room_id: 1,
            });
        };
        if (!exists<RoomStore>(@mohayo)) {
            move_to(account, RoomStore { rooms: table::new() });
        };
    }

    // ============================ registration ============================
    public fun register_skill(account: &signer, skill: Skill) acquires Registry {
        let r = borrow_global_mut<Registry>(@mohayo);
        assert!(skill.id != 0, E_BAD_CONFIG);
        assert!(vector::length(&skill.effects) <= MAX_SKILL_EFFECTS, E_BAD_CONFIG);
        assert!(skill.target_count <= MAX_STRIKES, E_BAD_CONFIG);
        assert!(skill.base_acc <= 1000, E_BAD_CONFIG);
        assert!(skill.targeting >= TGT_RAND_SINGLE_ENEMY && skill.targeting <= TGT_MOST_WOUNDED_ALLY, E_BAD_CONFIG);
        assert!(skill.weight_mode <= WT_THREAT_ENEMY, E_BAD_CONFIG);
        assert!(skill.ap_cost <= AP_CAP_BASE, E_BAD_CONFIG);
        let i = 0;
        while (i < vector::length(&skill.effects)) {
            let e = vector::borrow(&skill.effects, i);
            if (e.op != 0) {
                assert!(e.op >= OP_STUN && e.op <= OP_SUMMON, E_BAD_CONFIG);
                assert!(e.prob >= 1 && e.prob <= 1000, E_BAD_CONFIG);
            };
            i = i + 1;
        };
        table::upsert(&mut r.skills, skill.id, skill);
    }

    public fun register_ai(account: &signer, ai_id: u64, cycle: vector<u64>) acquires Registry {
        let r = borrow_global_mut<Registry>(@mohayo);
        assert!(vector::length(&cycle) >= 1 && vector::length(&cycle) <= MAX_PLAN_SKILLS, E_BAD_CONFIG);
        let i = 0;
        while (i < vector::length(&cycle)) {
            let sid = *vector::borrow(&cycle, i);
            if (sid != 0) assert!(table::contains(&r.skills, sid), E_UNKNOWN_SKILL);
            i = i + 1;
        };
        table::upsert(&mut r.ais, ai_id, MonsterAI { skill_cycle: cycle });
    }

    public fun register_template(account: &signer, template_id: u64, t: EnemyTemplate) acquires Registry {
        let r = borrow_global_mut<Registry>(@mohayo);
        assert!(t.ai_id == 0 || table::contains(&r.ais, t.ai_id), E_UNKNOWN_AI);
        table::upsert(&mut r.templates, template_id, t);
    }

    public fun register_table(account: &signer, table_id: u64, entries: vector<TableEntry>) acquires Registry {
        let r = borrow_global_mut<Registry>(@mohayo);
        assert!(vector::length(&entries) >= 1 && vector::length(&entries) <= MAX_ENEMIES, E_BAD_CONFIG);
        let i = 0;
        while (i < vector::length(&entries)) {
            let e = vector::borrow(&entries, i);
            assert!(table::contains(&r.templates, e.template_id), E_UNKNOWN_TEMPLATE);
            assert!(e.weight >= 1, E_BAD_CONFIG);
            i = i + 1;
        };
        table::upsert(&mut r.tables, table_id, entries);
    }

    public fun set_dungeon(account: &signer, difficulty: u64, cfg: DungeonConfig) acquires Registry {
        let r = borrow_global_mut<Registry>(@mohayo);
        assert!(difficulty >= 1 && difficulty <= MAX_DIFFICULTY, E_BAD_CONFIG);
        assert!(table::contains(&r.tables, cfg.table_id), E_UNKNOWN_TABLE);
        table::upsert(&mut r.dungeons, difficulty, cfg);
    }

    public fun set_dungeon_battles(account: &signer, difficulty: u64, bcs: vector<BattleConfig>) acquires Registry {
        let r = borrow_global_mut<Registry>(@mohayo);
        assert!(difficulty >= 1 && difficulty <= MAX_DIFFICULTY, E_BAD_CONFIG);
        assert!(vector::length(&bcs) >= 1, E_BAD_CONFIG);
        let i = 0;
        while (i < vector::length(&bcs)) {
            let b = vector::borrow(&bcs, i);
            if (b.table_id != 0) assert!(table::contains(&r.tables, b.table_id), E_UNKNOWN_TABLE);
            i = i + 1;
        };
        let cfg = table::borrow_mut(&mut r.dungeons, difficulty);
        cfg.battles = vector::length(&bcs);
        table::upsert(&mut r.battles, difficulty, bcs);
    }

    public fun add_battle_variant(account: &signer, difficulty: u64, battle_index: u64, table_id: u64, weight: u64) acquires Registry {
        let r = borrow_global_mut<Registry>(@mohayo);
        assert!(difficulty >= 1 && difficulty <= MAX_DIFFICULTY, E_BAD_CONFIG);
        assert!(battle_index >= 1, E_BAD_CONFIG);
        assert!(table::contains(&r.tables, table_id), E_UNKNOWN_TABLE);
        assert!(weight >= 1, E_BAD_CONFIG);
        if (!table::contains(&r.battle_variants, difficulty)) {
            table::add(&mut r.battle_variants, difficulty, table::new<u64, vector<VariantEntry>>());
        };
        let per_battle = table::borrow_mut(&mut r.battle_variants, difficulty);
        if (!table::contains(per_battle, battle_index)) {
            table::add(per_battle, battle_index, vector::empty());
        };
        vector::push_back(table::borrow_mut(per_battle, battle_index), VariantEntry { table_id, weight });
    }

    // ============================ room lifecycle ============================
    public entry fun create_room(account: &signer, difficulty: u64) acquires Registry, RoomStore {
        let r = borrow_global_mut<Registry>(@mohayo);
        let rs = borrow_global_mut<RoomStore>(@mohayo);
        assert!(r.next_room_id <= MAX_ROOMS, E_BAD_CONFIG);
        assert!(table::contains(&r.dungeons, difficulty), E_UNKNOWN_DIFFICULTY);
        let cfg = *table::borrow(&r.dungeons, difficulty);
        let room_id = r.next_room_id;
        r.next_room_id = r.next_room_id + 1;
        let total_battles = if (cfg.battles >= 1) { cfg.battles } else { 1 };
        table::add(&mut rs.rooms, room_id, Room {
            id: room_id, difficulty, phase: PHASE_LOBBY, battle_index: 0,
            total_battles, turn_id: 0, mana_pool: 0, mana_per_turn: cfg.mana_per_turn,
            reward_pool: 0, leader: signer::address_of(account), boss_spawned: false,
            turn_interval: cfg.turn_interval, rng: rng::new(0),
            members: vector::empty(), enemies: vector::empty(), vault: table::new(),
        });
        event::emit(RoomCreated { room_id, leader: signer::address_of(account) });
    }

    public entry fun join_room(
        account: &signer, room_id: u64,
        max_hp: u64, attack: u64, magic: u64, speed: u64,
        mana_discount: u64, ap_discount: u64, ap_bonus: u64, mana_gain_bonus: i64
    ) acquires RoomStore {
        let rs = borrow_global_mut<RoomStore>(@mohayo);
        let room = table::borrow_mut(&mut rs.rooms, room_id);
        assert!(room.phase == PHASE_LOBBY || room.phase == PHASE_INTERMISSION, E_NOT_JOINABLE);
        assert!(vector::length(&room.members) < MAX_MEMBERS, E_ROOM_FULL);
        vector::push_back(&mut room.members, Member {
            owner: signer::address_of(account),
            hp: max_hp, max_hp, attack, magic, speed,
            ap: 0, mana_discount, ap_discount, ap_bonus, mana_gain_bonus,
            is_summon: false, alive: true,
            effects: vector::empty(), plan: vector::empty(), plan_start: 0,
        });
        event::emit(MemberJoined { room_id, player: signer::address_of(account) });
    }

    public entry fun leave_room(account: &signer, room_id: u64) acquires RoomStore {
        let rs = borrow_global_mut<RoomStore>(@mohayo);
        let room = table::borrow_mut(&mut rs.rooms, room_id);
        let idx = find_member_index(room, signer::address_of(account));
        assert!(idx < MAX_MEMBERS + 1, E_NOT_IN_ROOM);
        let was_leader = room.leader == signer::address_of(account);
        vector::remove(&mut room.members, idx);
        if (was_leader) reassign_leader(room);
        event::emit(MemberLeft { room_id, player: signer::address_of(account) });
    }

    // ============================ combat entry (uses randomness API) ============================
    #[randomness]
    entry fun start_combat(account: &signer, room_id: u64) acquires Registry, RoomStore {
        let r = borrow_global<Registry>(@mohayo);
        let rs = borrow_global_mut<RoomStore>(@mohayo);
        let room = table::borrow_mut(&mut rs.rooms, room_id);
        assert!(room.leader == signer::address_of(account), E_NOT_LEADER);
        assert!(room.phase == PHASE_LOBBY, E_NOT_LOBBY);
        assert!(vector::length(&room.members) > 0, E_NO_MEMBERS);
        room.battle_index = 1;
        let seed = randomness::u64_range(1, 0xFFFFFFFFFFFFFFFF);
        room.rng = rng::new(seed);
        spawn_battle(r, room);
        room.phase = PHASE_COMBAT;
        room.turn_id = 1;
        event::emit(CombatStarted { room_id, battle_index: room.battle_index });
    }

    public entry fun advance_battle(account: &signer, room_id: u64) acquires Registry, RoomStore {
        let r = borrow_global<Registry>(@mohayo);
        let rs = borrow_global_mut<RoomStore>(@mohayo);
        let room = table::borrow_mut(&mut rs.rooms, room_id);
        assert!(room.leader == signer::address_of(account), E_NOT_LEADER);
        assert!(room.phase == PHASE_INTERMISSION, E_NOT_INTERMISSION);
        assert!(room.battle_index < room.total_battles, E_LAST_BATTLE);
        room.enemies = vector::empty();
        let i = 0;
        while (i < vector::length(&room.members)) {
            vector::borrow_mut(&mut room.members, i).effects = vector::empty();
            i = i + 1;
        };
        room.battle_index = room.battle_index + 1;
        let _ = rng::next(&mut room.rng); // advance stream for new battle
        spawn_battle(r, room);
        room.phase = PHASE_COMBAT;
        room.turn_id = 1;
        event::emit(BattleAdvanced { room_id, new_battle_index: room.battle_index });
    }

    // ============================ plans ============================
    public entry fun set_plan(account: &signer, room_id: u64, plan: vector<u64>) acquires Registry, RoomStore {
        let r = borrow_global<Registry>(@mohayo);
        let rs = borrow_global_mut<RoomStore>(@mohayo);
        assert!(vector::length(&plan) <= MAX_PLAN, E_BAD_CONFIG);
        let room = table::borrow_mut(&mut rs.rooms, room_id);
        let idx = find_member_index(room, signer::address_of(account));
        assert!(idx < MAX_MEMBERS + 1, E_NOT_IN_ROOM);
        let i = 0;
        while (i < vector::length(&plan)) {
            let sid = *vector::borrow(&plan, i);
            if (sid != 0) assert!(table::contains(&r.skills, sid), E_UNKNOWN_SKILL);
            i = i + 1;
        };
        let m = vector::borrow_mut(&mut room.members, idx);
        m.plan = plan;
        m.plan_start = 0;
        event::emit(PlanSet { room_id, player: signer::address_of(account) });
    }

    public entry fun cancel_plan(account: &signer, room_id: u64) acquires RoomStore {
        let rs = borrow_global_mut<RoomStore>(@mohayo);
        let room = table::borrow_mut(&mut rs.rooms, room_id);
        let idx = find_member_index(room, signer::address_of(account));
        assert!(idx < MAX_MEMBERS + 1, E_NOT_IN_ROOM);
        let m = vector::borrow_mut(&mut room.members, idx);
        m.plan = vector::empty();
        m.plan_start = 0;
    }

    // ============================ item vault ============================
    public entry fun gm_give_item(account: &signer, room_id: u64, to_index: u64, item_id: u64, count: u64) acquires RoomStore {
        let rs = borrow_global_mut<RoomStore>(@mohayo);
        let room = table::borrow_mut(&mut rs.rooms, room_id);
        assert!(to_index < vector::length(&room.members), E_BAD_INDEX);
        vault_add(room, to_index, item_id, count);
        event::emit(ItemGiven { room_id, from: @0x0, to: vector::borrow(&room.members, to_index).owner, item_id, count });
    }

    public entry fun give_item(account: &signer, room_id: u64, to_index: u64, item_id: u64, count: u64) acquires RoomStore {
        let rs = borrow_global_mut<RoomStore>(@mohayo);
        let room = table::borrow_mut(&mut rs.rooms, room_id);
        let from_index = find_member_index(room, signer::address_of(account));
        assert!(from_index < MAX_MEMBERS + 1, E_NOT_IN_ROOM);
        assert!(count >= 1, E_BAD_CONFIG);
        let have = vault_count(room, from_index, item_id);
        assert!(have >= count, E_BAD_CONFIG);
        vault_take(room, from_index, item_id, count);
        vault_add(room, to_index, item_id, count);
        event::emit(ItemGiven { room_id, from: signer::address_of(account), to: vector::borrow(&room.members, to_index).owner, item_id, count });
    }

    // ============================ turn loop ============================
    #[randomness]
    entry fun advance_turn(account: &signer, room_id: u64) acquires Registry, RoomStore {
        let reg = borrow_global<Registry>(@mohayo);
        let rs = borrow_global_mut<RoomStore>(@mohayo);
        let room = table::borrow_mut(&mut rs.rooms, room_id);
        assert!(room.phase == PHASE_COMBAT, E_NOT_COMBAT);
        let _ = rng::next(&mut room.rng);
        check_timeout(room);
        act_all_in_speed_order(reg, room);
        regen_mana(room);
        room.turn_id = room.turn_id + 1;
        event::emit(TurnAdvanced { room_id, turn_id: room.turn_id });
        check_end(room);
    }

    #[test_only]
    public entry fun advance_turn_test(account: &signer, room_id: u64) acquires Registry, RoomStore {
        let reg = borrow_global<Registry>(@mohayo);
        let rs = borrow_global_mut<RoomStore>(@mohayo);
        let room = table::borrow_mut(&mut rs.rooms, room_id);
        assert!(room.phase == PHASE_COMBAT, E_NOT_COMBAT);
        check_timeout(room);
        act_all_in_speed_order(reg, room);
        regen_mana(room);
        room.turn_id = room.turn_id + 1;
        event::emit(TurnAdvanced { room_id, turn_id: room.turn_id });
        check_end(room);
    }

    #[test_only]
    public entry fun start_combat_test(account: &signer, room_id: u64, seed: u64) acquires Registry, RoomStore {
        let r = borrow_global<Registry>(@mohayo);
        let rs = borrow_global_mut<RoomStore>(@mohayo);
        let room = table::borrow_mut(&mut rs.rooms, room_id);
        assert!(room.leader == signer::address_of(account), E_NOT_LEADER);
        assert!(room.phase == PHASE_LOBBY, E_NOT_LOBBY);
        assert!(vector::length(&room.members) > 0, E_NO_MEMBERS);
        room.battle_index = 1;
        room.rng = rng::new(seed);
        spawn_battle(r, room);
        room.phase = PHASE_COMBAT;
        room.turn_id = 1;
        event::emit(CombatStarted { room_id, battle_index: room.battle_index });
    }

    #[test_only]
    public fun set_room_rng(room_id: u64, seed: u64) acquires RoomStore {
        let rs = borrow_global_mut<RoomStore>(@mohayo);
        table::borrow_mut(&mut rs.rooms, room_id).rng = rng::new(seed);
    }

    // ============================ internal: timeout ============================
    fun check_timeout(room: &mut Room) {
        if (room.turn_interval == 0) return;
        if (room.turn_id > room.turn_interval * 2 && room.turn_id % 5 == 0) {
            let i = 0;
            while (i < vector::length(&room.members)) {
                let m = vector::borrow_mut(&mut room.members, i);
                if (m.alive && !m.is_summon) {
                    let dmg = m.max_hp * TIMEOUT_HP_PCT / 100;
                    if (dmg >= m.hp) { m.hp = 0; m.alive = false }
                    else { m.hp = m.hp - dmg; };
                };
                i = i + 1;
            };
        };
    }

    // ============================ internal: speed order ============================
    fun act_all_in_speed_order(reg: &Registry, room: &mut Room) {
        let order_side = vector::empty<bool>();
        let order_idx = vector::empty<u64>();
        let order_speed = vector::empty<u64>();
        let mc = vector::length(&room.members);
        let ec = vector::length(&room.enemies);
        let i = 0;
        while (i < mc) {
            if (vector::borrow(&room.members, i).alive) {
                vector::push_back(&mut order_side, false);
                vector::push_back(&mut order_idx, i);
                vector::push_back(&mut order_speed, vector::borrow(&room.members, i).speed);
            };
            i = i + 1;
        };
        let i = 0;
        while (i < ec) {
            if (vector::borrow(&room.enemies, i).alive) {
                vector::push_back(&mut order_side, true);
                vector::push_back(&mut order_idx, i);
                vector::push_back(&mut order_speed, vector::borrow(&room.enemies, i).speed);
            };
            i = i + 1;
        };
        // stable insertion sort desc by speed
        let n = vector::length(&order_speed);
        let k = 1;
        while (k < n) {
            let s_side = *vector::borrow(&order_side, k);
            let s_idx = *vector::borrow(&order_idx, k);
            let s_sp = *vector::borrow(&order_speed, k);
            let j = k;
            while (j > 0) {
                let prev_sp = *vector::borrow(&order_speed, j - 1);
                if (prev_sp >= s_sp) break;
                *vector::borrow_mut(&mut order_side, j) = *vector::borrow(&order_side, j - 1);
                *vector::borrow_mut(&mut order_idx, j) = *vector::borrow(&order_idx, j - 1);
                *vector::borrow_mut(&mut order_speed, j) = prev_sp;
                j = j - 1;
            };
            *vector::borrow_mut(&mut order_side, j) = s_side;
            *vector::borrow_mut(&mut order_idx, j) = s_idx;
            *vector::borrow_mut(&mut order_speed, j) = s_sp;
            k = k + 1;
        };
        let p = 0;
        while (p < n) {
            let side = *vector::borrow(&order_side, p);
            let index = *vector::borrow(&order_idx, p);
            if (side_alive(room, side, index)) {
                tick_effects_common(room, Target { is_enemy: side, index });
                if (side_alive(room, side, index)) {
                    let stunned = has_effect(get_effects(room, side, index), OP_STUN);
                    if (!stunned) {
                        if (side) { act_enemy(reg, room, index) }
                        else { act_member(reg, room, index) };
                    };
                };
            };
            p = p + 1;
        };
    }

    fun regen_mana(room: &mut Room) {
        let gain: i64 = room.mana_per_turn as i64;
        let i = 0;
        while (i < vector::length(&room.members)) {
            let m = vector::borrow(&room.members, i);
            if (m.alive) gain = gain + m.mana_gain_bonus;
            i = i + 1;
        };
        if (gain > 0) {
            room.mana_pool = room.mana_pool + (gain as u64);
            event::emit(ManaChanged { room_id: room.id, pool: room.mana_pool });
        };
    }

    // ============================ member action ============================
    fun act_member(reg: &Registry, room: &mut Room, mi: u64) {
        let ap_bonus = vector::borrow(&room.members, mi).ap_bonus;
        if (ap_bonus > 0) {
            let m = vector::borrow_mut(&mut room.members, mi);
            m.ap = if (m.ap + ap_bonus > AP_CAP_BASE) { AP_CAP_BASE } else { m.ap + ap_bonus };
        };
        let skill_id = next_plan_skill(room, mi);
        if (skill_id == 0) return;
        execute_member_skill(reg, room, mi, skill_id);
    }

    fun next_plan_skill(room: &mut Room, mi: u64): u64 {
        let m = vector::borrow(&room.members, mi);
        let len = vector::length(&m.plan);
        if (len == 0) return 0;
        let sid = *vector::borrow(&m.plan, m.plan_start);
        let next = (m.plan_start + 1) % len;
        vector::borrow_mut(&mut room.members, mi).plan_start = next;
        sid
    }

    fun execute_member_skill(reg: &Registry, room: &mut Room, mi: u64, skill_id: u64) {
        if (!table::contains(&reg.skills, skill_id)) return;
        let skill = *table::borrow(&reg.skills, skill_id);
        let (ok, mana_consumed) = check_and_deduct_member(room, mi, &skill);
        if (!ok) return;
        resolve_skill(reg, room, &skill, false, mi, mana_consumed);
    }

    fun check_and_deduct_member(room: &mut Room, mi: u64, skill: &Skill): (bool, u64) {
        let m = vector::borrow(&room.members, mi);
        let eff_ap_cost = if (skill.ap_cost > m.ap_discount) { skill.ap_cost - m.ap_discount } else { 0 };
        let eff_mana_cost = if ((skill.flags & FLAG_MANA_ALL) != 0) {
            room.mana_pool
        } else if (skill.mana_cost > m.mana_discount) {
            skill.mana_cost - m.mana_discount
        } else { 0 };
        if (skill.hp_cost > 0 && m.hp <= skill.hp_cost) return (false, 0);
        if (m.ap < eff_ap_cost) return (false, 0);
        if (room.mana_pool < eff_mana_cost) return (false, 0);
        if (skill.ammo_id != 0) {
            if (vault_count(room, mi, skill.ammo_id) < skill.ammo_cost) return (false, 0);
        };
        let m = vector::borrow_mut(&mut room.members, mi);
        m.ap = m.ap - eff_ap_cost;
        if (skill.hp_cost > 0) m.hp = m.hp - skill.hp_cost;
        room.mana_pool = room.mana_pool - eff_mana_cost;
        if (skill.ammo_id != 0) vault_take(room, mi, skill.ammo_id, skill.ammo_cost);
        (true, eff_mana_cost)
    }

    fun vault_count(room: &Room, member_index: u64, item_id: u64): u64 {
        if (!table::contains(&room.vault, item_id)) return 0;
        let bucket = table::borrow(&room.vault, item_id);
        if (table::contains(bucket, member_index)) *table::borrow(bucket, member_index) else 0
    }
    fun vault_take(room: &mut Room, member_index: u64, item_id: u64, count: u64) {
        let bucket = table::borrow_mut(&mut room.vault, item_id);
        let have = *table::borrow(bucket, member_index);
        *table::borrow_mut(bucket, member_index) = have - count;
    }
    fun vault_add(room: &mut Room, member_index: u64, item_id: u64, count: u64) {
        if (!table::contains(&room.vault, item_id)) {
            table::add(&mut room.vault, item_id, table::new());
        };
        let bucket = table::borrow_mut(&mut room.vault, item_id);
        if (table::contains(bucket, member_index)) {
            let have = *table::borrow(bucket, member_index);
            *table::borrow_mut(bucket, member_index) = have + count;
        } else {
            table::add(bucket, member_index, count);
        };
    }

    // ============================ enemy action ============================
    fun act_enemy(reg: &Registry, room: &mut Room, ei: u64) {
        let ai_id = vector::borrow(&room.enemies, ei).ai_id;
        if (ai_id == 0) return;
        if (!table::contains(&reg.ais, ai_id)) return;
        let ai = *table::borrow(&reg.ais, ai_id);
        let cycle_len = vector::length(&ai.skill_cycle);
        if (cycle_len == 0) return;
        let tc = vector::borrow(&room.enemies, ei).turn_counter;
        let skill_id = *vector::borrow(&ai.skill_cycle, tc % cycle_len);
        vector::borrow_mut(&mut room.enemies, ei).turn_counter = tc + 1;
        if (skill_id == 0) return;
        if (!table::contains(&reg.skills, skill_id)) return;
        let skill = *table::borrow(&reg.skills, skill_id);
        if (skill.mana_cost > room.mana_pool) return;
        room.mana_pool = room.mana_pool - skill.mana_cost;
        resolve_skill(reg, room, &skill, true, ei, 0);
    }

    // ============================ skill resolution ============================
    fun resolve_skill(reg: &Registry, room: &mut Room, skill: &Skill, actor_enemy: bool, actor_index: u64, mana_consumed: u64) {
        event::emit(UnitActed { room_id: room.id, is_enemy: actor_enemy, index: actor_index, skill_id: skill.id });
        let ally_targeting = is_ally_targeting(skill.targeting, actor_enemy);
        let guaranteed = ally_targeting
            || skill.targeting == TGT_ROOM_ALL
            || (skill.flags & FLAG_GUARANTEED_HIT) != 0
            || has_effect(get_effects(room, actor_enemy, actor_index), OP_GUAR_NEXT);
        let strikes = if (skill.targeting == TGT_RAND_STRIKE_ENEMY) { skill.target_count } else { 1 };
        let st = 0;
        let any_hit = false;
        while (st < strikes) {
            let targets = select_targets(room, skill, actor_enemy, actor_index);
            let k = 0;
            while (k < vector::length(&targets)) {
                let t = *vector::borrow(&targets, k);
                let dealt = resolve_target(reg, room, skill, actor_enemy, actor_index, t, guaranteed, ally_targeting, mana_consumed);
                if (dealt > 0) any_hit = true;
                k = k + 1;
            };
            st = st + 1;
        };
        if (any_hit && skill.ap_gain > 0 && !actor_enemy) {
            let m = vector::borrow_mut(&mut room.members, actor_index);
            m.ap = if (m.ap + skill.ap_gain > AP_CAP_BASE) { AP_CAP_BASE } else { m.ap + skill.ap_gain };
        };
    }

    fun resolve_target(
        reg: &Registry, room: &mut Room, skill: &Skill, actor_enemy: bool, actor_index: u64,
        t: Target, guaranteed: bool, ally_targeting: bool, mana_consumed: u64
    ): u64 {
        if (!target_alive(room, t)) return 0;
        if (!guaranteed) {
            let acc = skill.base_acc;
            let acc = acc - sum_effect_mag(get_effects(room, actor_enemy, actor_index), OP_ACC_DOWN, acc);
            let acc = acc - sum_effect_mag(get_effects(room, t.is_enemy, t.index), OP_EVADE_UP, acc);
            let acc = if (acc < MIN_HIT_RATE) { MIN_HIT_RATE } else { acc };
            let roll = rng::below(&mut room.rng, 1000);
            if (roll >= acc) return 0;
        };
        let actor_attack = stat_of(room, actor_enemy, actor_index, true);
        let actor_magic = stat_of(room, actor_enemy, actor_index, false);
        let dealt: u64 = 0;
        if (skill.power > 0) {
            if (ally_targeting && skill.kind == KIND_SUPPORT) {
                let heal = skill.power * actor_magic / 1000;
                heal_target(room, t, heal);
                dealt = heal;
            } else {
                let stat = if ((skill.flags & FLAG_MANA_ALL) != 0) { mana_consumed }
                    else if (skill.kind == KIND_MAGIC) { actor_magic }
                    else { actor_attack };
                dealt = compute_damage(room, skill, stat, actor_enemy, actor_index, t);
                deal_damage(room, t, dealt);
            };
        };
        let i = 0;
        while (i < vector::length(&skill.effects)) {
            let e = *vector::borrow(&skill.effects, i);
            if (e.prob >= 1000 || rng::below(&mut room.rng, 1000) < e.prob) {
                apply_skill_effect(reg, room, skill, actor_enemy, actor_index, t, e, dealt);
            };
            i = i + 1;
        };
        if (target_died(room, t)) handle_death(reg, room, t);
        dealt
    }

    fun compute_damage(room: &mut Room, skill: &Skill, stat: u64, actor_enemy: bool, actor_index: u64, t: Target): u64 {
        let dmg = skill.power * stat / 1000;
        let dmg = if (skill.damage_cap != 0 && dmg > skill.damage_cap) { skill.damage_cap } else { dmg };
        let out_mod = sum_effect_mag(get_effects(room, actor_enemy, actor_index), OP_DMG_OUT_MOD, 0);
        let dmg = if (out_mod != 0) { dmg * (1000 + out_mod) / 1000 } else { dmg };
        let in_mod = sum_effect_mag(get_effects(room, t.is_enemy, t.index), OP_DMG_IN_MOD, 0);
        if (in_mod != 0) { dmg * (1000 + in_mod) / 1000 } else { dmg }
    }

    fun apply_skill_effect(
        reg: &Registry, room: &mut Room, skill: &Skill, actor_enemy: bool, actor_index: u64,
        t: Target, e: EffectSpec, dealt: u64
    ) {
        let op = e.op;
        if (op == OP_HEAL) {
            if (e.scope == SCOPE_SELF) { heal_target(room, Target { is_enemy: actor_enemy, index: actor_index }, e.magnitude) }
            else { heal_target(room, t, e.magnitude) };
            return
        };
        if (op == OP_MANA_DELTA) {
            if (e.scope == SCOPE_TARGET) {
                room.mana_pool = if (room.mana_pool > e.magnitude) { room.mana_pool - e.magnitude } else { 0 };
            } else { room.mana_pool = room.mana_pool + e.magnitude; };
            event::emit(ManaChanged { room_id: room.id, pool: room.mana_pool });
            return
        };
        if (op == OP_DISPEL) { dispel_effects(room, t); return };
        if (op == OP_LIFESTEAL) {
            if (dealt > 0) { heal_target(room, Target { is_enemy: actor_enemy, index: actor_index }, dealt * e.magnitude / 1000) };
            return
        };
        if (op == OP_SUMMON) { do_summon(reg, room, skill); return };
        if (e.scope == SCOPE_SELF) {
            set_effect(room, Target { is_enemy: actor_enemy, index: actor_index }, op, e.duration, e.magnitude, skill.id);
        } else if (e.scope == SCOPE_TARGET) {
            set_effect(room, t, op, e.duration, e.magnitude, skill.id);
        } else if (e.scope == SCOPE_ALL_ALLY) {
            add_effect_side(room, !actor_enemy, op, e.duration, e.magnitude, skill.id);
        } else if (e.scope == SCOPE_ALL_ENEMY) {
            add_effect_side(room, actor_enemy, op, e.duration, e.magnitude, skill.id);
        };
    }

    fun do_summon(reg: &Registry, room: &mut Room, skill: &Skill) {
        let rule = skill.summon;
        if (rule.template_id == 0) return;
        if (!table::contains(&reg.templates, rule.template_id)) return;
        let tpl = *table::borrow(&reg.templates, rule.template_id);
        if ((skill.flags & FLAG_SUMMON_ALLY) != 0) {
            let n = 0;
            while (n < rule.max_count && vector::length(&room.members) < MAX_MEMBERS) {
                vector::push_back(&mut room.members, Member {
                    owner: @0x0, hp: tpl.max_hp, max_hp: tpl.max_hp,
                    attack: tpl.power, magic: tpl.magic, speed: tpl.speed,
                    ap: 0, mana_discount: 0, ap_discount: 0, ap_bonus: 0, mana_gain_bonus: 0,
                    is_summon: true, alive: true,
                    effects: vector::empty(), plan: vector::empty(), plan_start: 0,
                });
                event::emit(MemberSummoned { room_id: room.id, index: vector::length(&room.members) - 1, template_id: rule.template_id });
                n = n + 1;
            };
            return
        };
        let alive_e = alive_enemy_count(room);
        let alive_p = alive_member_count(room);
        if (alive_e >= alive_p + rule.enemy_headroom || vector::length(&room.enemies) >= MAX_ENEMIES) return;
        let to_spawn = rule.max_count;
        let headroom = if (alive_p + rule.enemy_headroom > alive_e) { alive_p + rule.enemy_headroom - alive_e } else { 0 };
        let to_spawn = if (to_spawn > headroom) { headroom } else { to_spawn };
        let n = 0;
        while (n < to_spawn && vector::length(&room.enemies) < MAX_ENEMIES) {
            spawn_enemy_with(room, rule.template_id, &tpl);
            n = n + 1;
        };
    }

    // ============================ targeting ============================
    fun select_targets(room: &mut Room, skill: &Skill, actor_enemy: bool, actor_index: u64): vector<Target> {
        let targets = vector::empty();
        let targeting = skill.targeting;
        if (targeting == TGT_SELF) {
            vector::push_back(&mut targets, Target { is_enemy: actor_enemy, index: actor_index });
            return targets
        };
        if (targeting == TGT_MOST_WOUNDED_ALLY) {
            let best = pick_most_wounded(room);
            if (best < MAX_MEMBERS + 1) {
                vector::push_back(&mut targets, Target { is_enemy: false, index: best });
            } else if (!actor_enemy) {
                vector::push_back(&mut targets, Target { is_enemy: false, index: actor_index });
            };
            return targets
        };
        let targets_enemy_side = targeting == TGT_RAND_SINGLE_ENEMY || targeting == TGT_RAND_MULTI_ENEMY
            || targeting == TGT_RAND_STRIKE_ENEMY || targeting == TGT_ALL_ENEMY;
        let enemy_target = if (actor_enemy) { !targets_enemy_side } else { targets_enemy_side };
        if (targeting == TGT_ALL_ENEMY || targeting == TGT_ALL_ALLY) {
            append_alive(room, &mut targets, enemy_target);
            return targets
        };
        if (targeting == TGT_ROOM_ALL) {
            append_alive(room, &mut targets, false);
            append_alive(room, &mut targets, true);
            return targets
        };
        let need = if (targeting == TGT_RAND_MULTI_ENEMY || targeting == TGT_RAND_MULTI_ALLY) { skill.target_count } else { 1 };
        let pool = alive_count(room, enemy_target);
        if (pool == 0) return targets;
        let k = 0;
        while (k < need && k < pool) {
            let picked = pick_weighted(room, enemy_target, skill.weight_mode);
            if (!contains_target(&targets, enemy_target, picked)) {
                vector::push_back(&mut targets, Target { is_enemy: enemy_target, index: picked });
                k = k + 1;
            };
        };
        targets
    }

    fun append_alive(room: &Room, targets: &mut vector<Target>, enemy_side: bool) {
        let count = side_len(room, enemy_side);
        let i = 0;
        while (i < count) {
            if (side_alive(room, enemy_side, i)) vector::push_back(targets, Target { is_enemy: enemy_side, index: i });
            i = i + 1;
        };
    }

    fun pick_weighted(room: &mut Room, enemy_target: bool, mode: u8): u64 {
        let pool = alive_count(room, enemy_target);
        if (pool == 0) return 0;
        if (enemy_target) {
            let taunter = find_taunter(room);
            if (taunter < MAX_ENEMIES + 1) return taunter;
        };
        let count = side_len(room, enemy_target);
        let weights = vector::empty();
        let total = 0;
        let i = 0;
        while (i < count) {
            if (side_alive(room, enemy_target, i)) {
                let w = if (enemy_target) {
                    if (mode == WT_THREAT_ENEMY) {
                        let th = vector::borrow(&room.enemies, i).threat;
                        if (th == 0) { 1 } else { th }
                    } else { 1 }
                } else if (mode == WT_HP_DEFICIT_ALLY) {
                    let m = vector::borrow(&room.members, i);
                    (m.max_hp - m.hp) + 1
                } else { 1 };
                vector::push_back(&mut weights, w);
                total = total + w;
            };
            i = i + 1;
        };
        let roll = rng::below(&mut room.rng, total);
        let remaining = roll;
        let idx: u64 = 0;
        let i = 0;
        while (i < count) {
            if (side_alive(room, enemy_target, i)) {
                let w = *vector::borrow(&weights, idx);
                if (remaining < w) return i;
                remaining = remaining - w;
                idx = idx + 1;
            };
            i = i + 1;
        };
        0
    }

    fun find_taunter(room: &Room): u64 {
        let count = vector::length(&room.enemies);
        let i = 0;
        while (i < count) {
            if (vector::borrow(&room.enemies, i).alive && has_effect(&vector::borrow(&room.enemies, i).effects, OP_TAUNT)) return i;
            i = i + 1;
        };
        MAX_ENEMIES + 2
    }

    fun pick_most_wounded(room: &Room): u64 {
        let best: u64 = MAX_MEMBERS + 2;
        let best_deficit = 0;
        let i = 0;
        while (i < vector::length(&room.members)) {
            let m = vector::borrow(&room.members, i);
            if (m.alive) {
                let deficit = m.max_hp - m.hp;
                if (deficit > 0 && (best >= MAX_MEMBERS + 2 || deficit > best_deficit)) {
                    best = i;
                    best_deficit = deficit;
                };
            };
            i = i + 1;
        };
        best
    }

    fun contains_target(targets: &vector<Target>, enemy_side: bool, index: u64): bool {
        let i = 0;
        while (i < vector::length(targets)) {
            let t = vector::borrow(targets, i);
            if (t.is_enemy == enemy_side && t.index == index) return true;
            i = i + 1;
        };
        false
    }

    // ============================ ActiveEffect engine ============================
    fun set_effect(room: &mut Room, t: Target, op: u8, duration: u8, magnitude: u64, source_id: u64) {
        let effects = effects_mut(room, t);
        let i = 0;
        while (i < vector::length(effects)) {
            let e = vector::borrow_mut(effects, i);
            if (e.op != op) { i = i + 1; continue };
            if (op == OP_ACC_DOWN || op == OP_EVADE_UP || op == OP_DMG_OUT_MOD || op == OP_DMG_IN_MOD) {
                e.magnitude = e.magnitude + magnitude;
                if (duration > e.duration) e.duration = duration;
                return
            };
            if (op == OP_GUAR_NEXT) { e.duration = duration; return };
            if (op == OP_TAUNT) { e.magnitude = magnitude; e.duration = duration; e.source_id = source_id; return };
            i = i + 1;
        };
        if (vector::length(effects) >= MAX_EFFECTS) return;
        vector::push_back(effects, ActiveEffect { op, duration, magnitude, source_id });
        event::emit(EffectApplied { room_id: room.id, is_enemy: t.is_enemy, index: t.index, op, magnitude, duration });
    }

    fun add_effect_side(room: &mut Room, enemy_side: bool, op: u8, duration: u8, magnitude: u64, source_id: u64) {
        let count = side_len(room, enemy_side);
        let i = 0;
        while (i < count) {
            if (side_alive(room, enemy_side, i)) {
                set_effect(room, Target { is_enemy: enemy_side, index: i }, op, duration, magnitude, source_id);
            };
            i = i + 1;
        };
    }

    fun tick_effects_common(room: &mut Room, t: Target) {
        let dot_total = 0;
        {
            let effects = get_effects(room, t.is_enemy, t.index);
            let i = 0;
            while (i < vector::length(effects)) {
                let e = vector::borrow(effects, i);
                if (e.op == OP_DOT) dot_total = dot_total + e.magnitude;
                i = i + 1;
            };
        };
        if (dot_total > 0) raw_damage(room, t, dot_total);
        let i = 0;
        let count = vector::length(get_effects(room, t.is_enemy, t.index));
        while (i < count) {
            let dur = vector::borrow(get_effects(room, t.is_enemy, t.index), i).duration;
            let effects = effects_mut(room, t);
            if (dur <= 1) { vector::remove(effects, i); count = count - 1; }
            else { vector::borrow_mut(effects, i).duration = dur - 1; i = i + 1; };
        };
    }

    fun dispel_effects(room: &mut Room, t: Target) {
        let i = 0;
        let count = vector::length(get_effects(room, t.is_enemy, t.index));
        while (i < count) {
            let op = vector::borrow(get_effects(room, t.is_enemy, t.index), i).op;
            if (is_dispellable(op)) {
                vector::remove(effects_mut(room, t), i);
                count = count - 1;
            } else { i = i + 1; };
        };
    }

    fun is_dispellable(op: u8): bool {
        op == OP_STUN || op == OP_SHIELD || op == OP_ACC_DOWN || op == OP_EVADE_UP
            || op == OP_GUAR_NEXT || op == OP_TAUNT || op == OP_DOT
            || op == OP_DMG_OUT_MOD || op == OP_DMG_IN_MOD
    }

    fun has_effect(effects: &vector<ActiveEffect>, op: u8): bool {
        let i = 0;
        while (i < vector::length(effects)) {
            let e = vector::borrow(effects, i);
            if (e.op == op && e.duration > 0) return true;
            i = i + 1;
        };
        false
    }

    fun sum_effect_mag(effects: &vector<ActiveEffect>, op: u8, cap: u64): u64 {
        let sum = 0;
        let i = 0;
        while (i < vector::length(effects)) {
            let e = vector::borrow(effects, i);
            if (e.op == op) sum = sum + e.magnitude;
            i = i + 1;
        };
        if (cap == 0) sum else if (sum > cap) { cap } else { sum }
    }

    // ============================ damage / heal / death ============================
    fun deal_damage(room: &mut Room, t: Target, amount: u64) {
        if (!target_alive(room, t)) return;
        let remaining = absorb_shield(room, t, amount);
        raw_damage(room, t, remaining);
        event::emit(DamageDealt { room_id: room.id, is_enemy: t.is_enemy, index: t.index, amount: remaining, hp_left: hp_of(room, t) });
    }

    fun absorb_shield(room: &mut Room, t: Target, amount: u64): u64 {
        let remaining = amount;
        let effects = effects_mut(room, t);
        let i = 0;
        while (i < vector::length(effects)) {
            let e = vector::borrow_mut(effects, i);
            if (e.op != OP_SHIELD) { i = i + 1; continue };
            if (e.magnitude >= remaining) { e.magnitude = e.magnitude - remaining; remaining = 0; break }
            else { remaining = remaining - e.magnitude; e.magnitude = 0; };
            i = i + 1;
        };
        remaining
    }

    fun raw_damage(room: &mut Room, t: Target, amount: u64) {
        if (t.is_enemy) {
            let e = vector::borrow_mut(&mut room.enemies, t.index);
            if (!e.alive) return;
            if (amount >= e.hp) { e.hp = 0; e.alive = false } else { e.hp = e.hp - amount; };
        } else {
            let m = vector::borrow_mut(&mut room.members, t.index);
            if (!m.alive) return;
            if (amount >= m.hp) { m.hp = 0; m.alive = false } else { m.hp = m.hp - amount; };
        };
    }

    fun heal_target(room: &mut Room, t: Target, amount: u64) {
        if (!target_alive(room, t)) return;
        let missing = max_hp_of(room, t) - hp_of(room, t);
        let actual = if (amount > missing) { missing } else { amount };
        if (t.is_enemy) { vector::borrow_mut(&mut room.enemies, t.index).hp = vector::borrow(&room.enemies, t.index).hp + actual; }
        else { vector::borrow_mut(&mut room.members, t.index).hp = vector::borrow(&room.members, t.index).hp + actual; };
        event::emit(HealedEvt { room_id: room.id, is_enemy: t.is_enemy, index: t.index, amount: actual });
    }

    fun handle_death(reg: &Registry, room: &mut Room, t: Target) {
        event::emit(UnitDied { room_id: room.id, is_enemy: t.is_enemy, index: t.index });
        if (t.is_enemy) {
            let e = vector::borrow_mut(&mut room.enemies, t.index);
            e.effects = vector::empty();
            let template_id = e.template_id;
            if (!table::contains(&reg.templates, template_id)) return;
            let tpl = *table::borrow(&reg.templates, template_id);
            let reward = if (tpl.reward_max > tpl.reward_min) {
                tpl.reward_min + rng::below(&mut room.rng, tpl.reward_max - tpl.reward_min + 1)
            } else { tpl.reward_min };
            room.reward_pool = room.reward_pool + reward;
            let ods = tpl.on_death_spawn;
            if (ods.template_id != 0 && ods.prob != 0) {
                let roll = rng::below(&mut room.rng, 1000);
                if (roll < ods.prob && table::contains(&reg.templates, ods.template_id)) {
                    room.boss_spawned = true;
                    let tpl2 = *table::borrow(&reg.templates, ods.template_id);
                    let n = 0;
                    while (n < ods.count && vector::length(&room.enemies) < MAX_ENEMIES) {
                        spawn_enemy_with(room, ods.template_id, &tpl2);
                        n = n + 1;
                    };
                };
            };
        } else {
            vector::borrow_mut(&mut room.members, t.index).effects = vector::empty();
        };
    }

    // ============================ end of battle ============================
    fun check_end(room: &mut Room) {
        if (room.phase != PHASE_COMBAT) return;
        if (alive_enemy_count(room) == 0) {
            if (room.battle_index < room.total_battles) {
                room.phase = PHASE_INTERMISSION;
                event::emit(BattleCleared { room_id: room.id, battle_index: room.battle_index, total_battles: room.total_battles });
            } else { settle_victory(room) };
            return
        };
        if (alive_real_member_count(room) == 0) {
            room.phase = PHASE_SETTLED;
            event::emit(DefeatEvt { room_id: room.id });
        };
    }

    fun settle_victory(room: &mut Room) {
        room.phase = PHASE_SETTLED;
        event::emit(VictoryEvt { room_id: room.id });
        let n = vector::length(&room.members);
        let winners_owner = vector::empty();
        let winners_w = vector::empty();
        let total_w = 0;
        let i = 0;
        while (i < n) {
            let m = vector::borrow(&room.members, i);
            if (m.alive && !m.is_summon) {
                let w = 1 + rng::below(&mut room.rng, 1000);
                vector::push_back(&mut winners_owner, m.owner);
                vector::push_back(&mut winners_w, w);
                total_w = total_w + w;
            };
            i = i + 1;
        };
        let k = 0;
        let distributed = 0;
        while (k < vector::length(&winners_owner)) {
            let player = *vector::borrow(&winners_owner, k);
            let w = *vector::borrow(&winners_w, k);
            let share = room.reward_pool * w / total_w;
            distributed = distributed + share;
            event::emit(RewardDistributed { room_id: room.id, player, amount: share });
            k = k + 1;
        };
        if (distributed < room.reward_pool) {
            event::emit(RewardDistributed { room_id: room.id, player: room.leader, amount: room.reward_pool - distributed });
        };
    }

    // ============================ spawning ============================
    fun spawn_battle(reg: &Registry, room: &mut Room) {
        let difficulty = room.difficulty;
        let battle_index = room.battle_index;
        let cfg = *table::borrow(&reg.dungeons, difficulty);
        let table_id = cfg.table_id;
        let count = cfg.enemy_count;
        // per-battle config override
        let table_id = if (table::contains(&reg.battles, difficulty)) {
            let bcs = table::borrow(&reg.battles, difficulty);
            if (battle_index >= 1 && battle_index <= vector::length(bcs)) {
                let b = vector::borrow(bcs, battle_index - 1);
                if (b.table_id != 0) { b.table_id } else { table_id }
            } else { table_id }
        } else { table_id };
        let count = if (table::contains(&reg.battles, difficulty)) {
            let bcs = table::borrow(&reg.battles, difficulty);
            if (battle_index >= 1 && battle_index <= vector::length(bcs)) {
                let b = vector::borrow(bcs, battle_index - 1);
                if (b.enemy_count != 0) { b.enemy_count } else { count }
            } else { count }
        } else { count };
        // variant roll
        let table_id = if (table::contains(&reg.battle_variants, difficulty)) {
            let per_battle = table::borrow(&reg.battle_variants, difficulty);
            if (table::contains(per_battle, battle_index)) {
                let list = table::borrow(per_battle, battle_index);
                if (vector::length(list) > 0) { variant_roll(room, list, table_id) } else { table_id }
            } else { table_id }
        } else if (battle_index == 1 && table::contains(&reg.variants, difficulty)) {
            let list = table::borrow(&reg.variants, difficulty);
            if (vector::length(list) > 0) { variant_roll(room, list, table_id) } else { table_id }
        } else { table_id };
        // spawn from table
        if (table::contains(&reg.tables, table_id)) {
            let entries = table::borrow(&reg.tables, table_id);
            let spawned = 0;
            while (spawned < count && vector::length(&room.enemies) < MAX_ENEMIES) {
                let tid = weighted_table_pick(room, entries);
                if (table::contains(&reg.templates, tid)) {
                    let tpl = *table::borrow(&reg.templates, tid);
                    spawn_enemy_with(room, tid, &tpl);
                };
                spawned = spawned + 1;
            };
        };
    }

    fun variant_roll(room: &mut Room, list: &vector<VariantEntry>, fallback: u64): u64 {
        let total = 0;
        let i = 0;
        while (i < vector::length(list)) {
            total = total + vector::borrow(list, i).weight;
            i = i + 1;
        };
        let roll = rng::below(&mut room.rng, total);
        let remaining = roll;
        let i = 0;
        while (i < vector::length(list)) {
            let v = vector::borrow(list, i);
            if (remaining < v.weight) return v.table_id;
            remaining = remaining - v.weight;
            i = i + 1;
        };
        fallback
    }

    fun weighted_table_pick(room: &mut Room, entries: &vector<TableEntry>): u64 {
        let total = 0;
        let i = 0;
        while (i < vector::length(entries)) {
            total = total + vector::borrow(entries, i).weight;
            i = i + 1;
        };
        let roll = rng::below(&mut room.rng, total);
        let remaining = roll;
        let i = 0;
        while (i < vector::length(entries)) {
            let e = vector::borrow(entries, i);
            if (remaining < e.weight) return e.template_id;
            remaining = remaining - e.weight;
            i = i + 1;
        };
        vector::borrow(entries, vector::length(entries) - 1).template_id
    }

    fun spawn_enemy_with(room: &mut Room, template_id: u64, t: &EnemyTemplate) {
        vector::push_back(&mut room.enemies, Enemy {
            template_id,
            hp: t.max_hp, max_hp: t.max_hp,
            attack: t.power, magic: t.magic, speed: t.speed,
            base_acc: t.base_acc, threat: t.threat, ai_id: t.ai_id,
            turn_counter: 0, alive: true, effects: vector::empty(),
        });
        event::emit(EnemySpawned { room_id: room.id, index: vector::length(&room.enemies) - 1, template_id });
    }

    // ============================ accessors ============================
    fun side_len(room: &Room, enemy_side: bool): u64 {
        if (enemy_side) vector::length(&room.enemies) else vector::length(&room.members)
    }
    fun side_alive(room: &Room, enemy_side: bool, index: u64): bool {
        if (enemy_side) vector::borrow(&room.enemies, index).alive else vector::borrow(&room.members, index).alive
    }
    fun target_alive(room: &Room, t: Target): bool { side_alive(room, t.is_enemy, t.index) }
    fun target_died(room: &Room, t: Target): bool { !side_alive(room, t.is_enemy, t.index) }
    fun hp_of(room: &Room, t: Target): u64 {
        if (t.is_enemy) vector::borrow(&room.enemies, t.index).hp else vector::borrow(&room.members, t.index).hp
    }
    fun max_hp_of(room: &Room, t: Target): u64 {
        if (t.is_enemy) vector::borrow(&room.enemies, t.index).max_hp else vector::borrow(&room.members, t.index).max_hp
    }
    fun stat_of(room: &Room, enemy_side: bool, index: u64, attack: bool): u64 {
        if (enemy_side) { let e = vector::borrow(&room.enemies, index); if (attack) e.attack else e.magic }
        else { let m = vector::borrow(&room.members, index); if (attack) m.attack else m.magic }
    }
    fun get_effects(room: &Room, enemy_side: bool, index: u64): &vector<ActiveEffect> {
        if (enemy_side) &vector::borrow(&room.enemies, index).effects
        else &vector::borrow(&room.members, index).effects
    }
    fun effects_mut(room: &mut Room, t: Target): &mut vector<ActiveEffect> {
        if (t.is_enemy) &mut vector::borrow_mut(&mut room.enemies, t.index).effects
        else &mut vector::borrow_mut(&mut room.members, t.index).effects
    }
    fun alive_member_count(room: &Room): u64 {
        let n = 0; let i = 0;
        while (i < vector::length(&room.members)) {
            if (vector::borrow(&room.members, i).alive) n = n + 1;
            i = i + 1;
        }; n
    }
    fun alive_real_member_count(room: &Room): u64 {
        let n = 0; let i = 0;
        while (i < vector::length(&room.members)) {
            let m = vector::borrow(&room.members, i);
            if (m.alive && !m.is_summon) n = n + 1;
            i = i + 1;
        }; n
    }
    fun alive_enemy_count(room: &Room): u64 {
        let n = 0; let i = 0;
        while (i < vector::length(&room.enemies)) {
            if (vector::borrow(&room.enemies, i).alive) n = n + 1;
            i = i + 1;
        }; n
    }
    fun alive_count(room: &Room, enemy_side: bool): u64 {
        if (enemy_side) alive_enemy_count(room) else alive_member_count(room)
    }
    fun find_member_index(room: &Room, player: address): u64 {
        let i = 0;
        while (i < vector::length(&room.members)) {
            if (vector::borrow(&room.members, i).owner == player) return i;
            i = i + 1;
        };
        MAX_MEMBERS + 2
    }
    fun reassign_leader(room: &mut Room) {
        let i = 0;
        while (i < vector::length(&room.members)) {
            let m = vector::borrow(&room.members, i);
            if (m.alive && !m.is_summon && m.owner != @0x0) { room.leader = m.owner; return };
            i = i + 1;
        };
    }
    fun is_ally_targeting(targeting: u8, actor_enemy: bool): bool {
        if (targeting == TGT_SELF || targeting == TGT_ROOM_ALL || targeting == TGT_MOST_WOUNDED_ALLY) return true;
        !(targeting == TGT_RAND_SINGLE_ENEMY || targeting == TGT_RAND_MULTI_ENEMY
            || targeting == TGT_RAND_STRIKE_ENEMY || targeting == TGT_ALL_ENEMY)
    }

    // ============================ views ============================
    #[view]
    public fun room_phase(room_id: u64): u8 acquires RoomStore {
        table::borrow(&borrow_global<RoomStore>(@mohayo).rooms, room_id).phase
    }
    #[view]
    public fun room_turn(room_id: u64): u64 acquires RoomStore {
        table::borrow(&borrow_global<RoomStore>(@mohayo).rooms, room_id).turn_id
    }
    #[view]
    public fun room_battle(room_id: u64): (u64, u64) acquires RoomStore {
        let room = table::borrow(&borrow_global<RoomStore>(@mohayo).rooms, room_id);
        (room.battle_index, room.total_battles)
    }
    #[view]
    public fun room_mana(room_id: u64): u64 acquires RoomStore {
        table::borrow(&borrow_global<RoomStore>(@mohayo).rooms, room_id).mana_pool
    }
    #[view]
    public fun room_rewards(room_id: u64): (u64, bool) acquires RoomStore {
        let room = table::borrow(&borrow_global<RoomStore>(@mohayo).rooms, room_id);
        (room.reward_pool, room.boss_spawned)
    }
    #[view]
    public fun member_state(room_id: u64, index: u64): (u64, u64, u64, u64, u64, bool, bool) acquires RoomStore {
        let room = table::borrow(&borrow_global<RoomStore>(@mohayo).rooms, room_id);
        let m = vector::borrow(&room.members, index);
        (m.hp, m.max_hp, m.ap, m.speed, vector::length(&m.effects), m.alive, m.is_summon)
    }
    #[view]
    public fun member_effect(room_id: u64, member_index: u64, effect_index: u64): (u8, u8, u64) acquires RoomStore {
        let room = table::borrow(&borrow_global<RoomStore>(@mohayo).rooms, room_id);
        let e = vector::borrow(&vector::borrow(&room.members, member_index).effects, effect_index);
        (e.op, e.duration, e.magnitude)
    }
    #[view]
    public fun enemy_state(room_id: u64, index: u64): (u64, u64, u64, u64, u64, u64, bool) acquires RoomStore {
        let room = table::borrow(&borrow_global<RoomStore>(@mohayo).rooms, room_id);
        let e = vector::borrow(&room.enemies, index);
        (e.hp, e.max_hp, e.attack, e.magic, e.speed, e.template_id, e.alive)
    }
    #[view]
    public fun enemy_effect(room_id: u64, enemy_index: u64, effect_index: u64): (u8, u8, u64) acquires RoomStore {
        let room = table::borrow(&borrow_global<RoomStore>(@mohayo).rooms, room_id);
        let f = vector::borrow(&vector::borrow(&room.enemies, enemy_index).effects, effect_index);
        (f.op, f.duration, f.magnitude)
    }
    #[view]
    public fun enemy_count(room_id: u64): u64 acquires RoomStore {
        vector::length(&table::borrow(&borrow_global<RoomStore>(@mohayo).rooms, room_id).enemies)
    }
    #[view]
    public fun member_count(room_id: u64): u64 acquires RoomStore {
        vector::length(&table::borrow(&borrow_global<RoomStore>(@mohayo).rooms, room_id).members)
    }
    #[view]
    public fun vault_balance(room_id: u64, member_index: u64, item_id: u64): u64 acquires RoomStore {
        let room = table::borrow(&borrow_global<RoomStore>(@mohayo).rooms, room_id);
        if (!table::contains(&room.vault, item_id)) return 0;
        let bucket = table::borrow(&room.vault, item_id);
        if (table::contains(bucket, member_index)) *table::borrow(bucket, member_index) else 0
    }
    #[view]
    public fun skill_registered(skill_id: u64): bool acquires Registry {
        table::contains(&borrow_global<Registry>(@mohayo).skills, skill_id)
    }
}

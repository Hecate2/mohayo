/// Skill, AI, template, and dungeon registration.
/// Owns the `Registry` resource at @mohayo.
module mohayo::skill_registry {
    use aptos_std::table::{Self, Table};
    use std::signer;
    use std::vector;
    use mohayo::types::{Self, Skill, MonsterAI, EnemyTemplate, TableEntry, BattleConfig,
                         DungeonConfig, VariantEntry};

    const E_NOT_OWNER: u64 = 1;
    const E_SKILL_EXISTS: u64 = 2;
    const E_SKILL_NOT_FOUND: u64 = 3;
    const E_AI_EXISTS: u64 = 4;
    const E_TEMPLATE_EXISTS: u64 = 5;
    const E_TABLE_EXISTS: u64 = 6;
    const E_DUNGEON_EXISTS: u64 = 7;
    const E_BAD_SKILL: u64 = 8;
    const E_EFFECT_COUNT: u64 = 9;
    const E_TARGET_COUNT: u64 = 10;
    const E_BASE_ACC: u64 = 11;
    const E_BAD_TARGETING: u64 = 12;
    const E_BAD_WEIGHT_MODE: u64 = 13;
    const E_BAD_EFFECT_OP: u64 = 14;
    const E_BAD_PROB: u64 = 15;
    const E_GUAR_NEXT_FORBIDDEN: u64 = 16;
    const E_SKILL_CAP: u64 = 17;
    const E_AI_CAP: u64 = 18;
    const E_TEMPLATE_CAP: u64 = 19;
    const E_TABLE_CAP: u64 = 20;
    const E_VARIANT_CAP: u64 = 21;
    const E_BATTLE_CAP: u64 = 22;
    const E_CLASS_SKILL_BOUND: u64 = 23;
    const E_UNKNOWN_AI: u64 = 24;

    const MAX_SKILLS: u64 = 1024;
    const MAX_AI: u64 = 256;
    const MAX_TEMPLATES: u64 = 512;
    const MAX_TABLES: u64 = 256;
    const MAX_DUNGEONS: u64 = 16;
    const MAX_VARIANTS: u64 = 8;
    const MAX_BATTLES: u64 = 8;

    struct Registry has key {
        skill_count: u64,
        skills: Table<u64, Skill>,
        ai_count: u64,
        ais: Table<u64, MonsterAI>,
        template_count: u64,
        templates: Table<u64, EnemyTemplate>,
        table_count: u64,
        tables: Table<u64, vector<TableEntry>>,
        dungeon_count: u64,
        dungeons: Table<u64, DungeonConfig>,
        battle_count: Table<u64, u64>,
        battles: Table<u64, vector<BattleConfig>>,
        variant_count: Table<u64, u64>,
        variants: Table<u64, vector<VariantEntry>>,
        class_skills: Table<u8, vector<u64>>,
        next_room_id: u64,
    }

    fun init_module(account: &signer) {
        move_to(account, Registry {
            skill_count: 0,
            skills: table::new(),
            ai_count: 0,
            ais: table::new(),
            template_count: 0,
            templates: table::new(),
            table_count: 0,
            tables: table::new(),
            dungeon_count: 0,
            dungeons: table::new(),
            battle_count: table::new(),
            battles: table::new(),
            variant_count: table::new(),
            variants: table::new(),
            class_skills: table::new(),
            next_room_id: 1,
        });
    }

    // ---- validation ----

    fun validate_skill(s: &Skill, allow_guar_next: bool) {
        let ef = types::skill_effects(s);
        assert!(vector::length(ef) <= 4, E_EFFECT_COUNT);
        assert!(types::skill_target_count(s) <= 8, E_TARGET_COUNT);
        assert!(types::skill_base_acc(s) <= 1000, E_BASE_ACC);
        assert!(types::skill_targeting(s) >= 1 && types::skill_targeting(s) <= 10, E_BAD_TARGETING);
        assert!(types::skill_weight_mode(s) <= 2, E_BAD_WEIGHT_MODE);
        if (!allow_guar_next) {
            let i = 0;
            while (i < vector::length(ef)) {
                let e = vector::borrow(ef, i);
                assert!(types::effect_op(e) != 7, E_GUAR_NEXT_FORBIDDEN); // OP_GUAR_NEXT = 7
                i = i + 1;
            };
        };
        let i = 0;
        while (i < vector::length(ef)) {
            let e = vector::borrow(ef, i);
            assert!(types::effect_op(e) >= 1 && types::effect_op(e) <= 15, E_BAD_EFFECT_OP);
            assert!(types::effect_prob(e) >= 1 && types::effect_prob(e) <= 1000, E_BAD_PROB);
            i = i + 1;
        };
    }

    fun reconstruct_skill_with_id(s: &Skill, new_id: u64): Skill {
        let summon = types::skill_summon(s);
        types::make_skill(
            new_id,
            types::skill_kind(s),
            types::skill_ap_cost(s),
            types::skill_ap_gain(s),
            0, // ammo_id
            0, // ammo_cost
            types::skill_mana_cost(s),
            types::skill_hp_cost(s),
            types::skill_targeting(s),
            types::skill_weight_mode(s),
            types::skill_target_count(s),
            types::skill_power(s),
            types::skill_damage_cap(s),
            types::skill_base_acc(s),
            types::skill_flags(s),
            *types::skill_effects(s),
            types::make_summon_rule(
                types::summon_rule_template_id(summon),
                types::summon_rule_max_count(summon),
                types::summon_rule_enemy_headroom(summon),
            ),
        )
    }

    // ---- registration ----

    public fun register_skill(account: &signer, s: Skill) acquires Registry {
        let addr = signer::address_of(account);
        assert!(addr == @mohayo, E_NOT_OWNER);
        let r = borrow_global_mut<Registry>(@mohayo);
        validate_skill(&s, false);
        let id = r.skill_count + 1;
        assert!(id <= MAX_SKILLS, E_SKILL_CAP);
        let new_s = reconstruct_skill_with_id(&s, id);
        table::add(&mut r.skills, id, new_s);
        r.skill_count = id;
    }

    public fun register_class_skill(account: &signer, s: Skill, class_id: u8) acquires Registry {
        let addr = signer::address_of(account);
        assert!(addr == @mohayo, E_NOT_OWNER);
        let r = borrow_global_mut<Registry>(@mohayo);
        validate_skill(&s, true);
        let id = r.skill_count + 1;
        assert!(id <= MAX_SKILLS, E_SKILL_CAP);
        let new_s = reconstruct_skill_with_id(&s, id);
        table::add(&mut r.skills, id, new_s);
        r.skill_count = id;
        if (!table::contains(&r.class_skills, class_id)) {
            table::add(&mut r.class_skills, class_id, vector::empty());
        };
        let list = table::borrow_mut(&mut r.class_skills, class_id);
        vector::push_back(list, id);
    }

    public fun register_ai(account: &signer, ai: MonsterAI) acquires Registry {
        let addr = signer::address_of(account);
        assert!(addr == @mohayo, E_NOT_OWNER);
        let r = borrow_global_mut<Registry>(@mohayo);
        let id = r.ai_count + 1;
        assert!(id <= MAX_AI, E_AI_CAP);
        table::add(&mut r.ais, id, ai);
        r.ai_count = id;
    }

    public fun register_template(account: &signer, t: EnemyTemplate) acquires Registry {
        let addr = signer::address_of(account);
        assert!(addr == @mohayo, E_NOT_OWNER);
        let r = borrow_global_mut<Registry>(@mohayo);
        assert!(table::contains(&r.ais, types::template_ai_id(&t)), E_UNKNOWN_AI);
        let id = r.template_count + 1;
        assert!(id <= MAX_TEMPLATES, E_TEMPLATE_CAP);
        table::add(&mut r.templates, id, t);
        r.template_count = id;
    }

    public fun register_table(account: &signer, entries: vector<TableEntry>) acquires Registry {
        let addr = signer::address_of(account);
        assert!(addr == @mohayo, E_NOT_OWNER);
        let r = borrow_global_mut<Registry>(@mohayo);
        let id = r.table_count + 1;
        assert!(id <= MAX_TABLES, E_TABLE_CAP);
        table::add(&mut r.tables, id, entries);
        r.table_count = id;
    }

    public fun set_dungeon(account: &signer, difficulty: u64, cfg: DungeonConfig) acquires Registry {
        let addr = signer::address_of(account);
        assert!(addr == @mohayo, E_NOT_OWNER);
        let r = borrow_global_mut<Registry>(@mohayo);
        assert!(difficulty <= 16, E_DUNGEON_EXISTS);
        if (table::contains(&r.dungeons, difficulty)) {
            *table::borrow_mut(&mut r.dungeons, difficulty) = cfg;
        } else {
            table::add(&mut r.dungeons, difficulty, cfg);
            r.dungeon_count = r.dungeon_count + 1;
        };
    }

    public fun set_dungeon_battles(account: &signer, difficulty: u64, configs: vector<BattleConfig>) acquires Registry {
        let addr = signer::address_of(account);
        assert!(addr == @mohayo, E_NOT_OWNER);
        let r = borrow_global_mut<Registry>(@mohayo);
        let len = vector::length(&configs);
        assert!(len <= MAX_BATTLES, E_BATTLE_CAP);
        if (table::contains(&r.battles, difficulty)) {
            *table::borrow_mut(&mut r.battles, difficulty) = configs;
        } else {
            table::add(&mut r.battles, difficulty, configs);
        };
        if (table::contains(&r.battle_count, difficulty)) {
            *table::borrow_mut(&mut r.battle_count, difficulty) = len as u64;
        } else {
            table::add(&mut r.battle_count, difficulty, len as u64);
        };
    }

    public entry fun add_battle_variant(account: &signer, difficulty: u64, battle_index: u64, table_id: u64, weight: u16) acquires Registry {
        let addr = signer::address_of(account);
        assert!(addr == @mohayo, E_NOT_OWNER);
        let r = borrow_global_mut<Registry>(@mohayo);
        let key = difficulty * 100 + battle_index;
        if (!table::contains(&r.variants, key)) {
            table::add(&mut r.variants, key, vector::empty());
        };
        let list = table::borrow_mut(&mut r.variants, key);
        assert!(vector::length(list) < MAX_VARIANTS, E_VARIANT_CAP);
        vector::push_back(list, types::make_variant_entry(table_id, weight));
    }

    // ---- view functions ----

    #[view]
    public fun get_skill(id: u64): Skill acquires Registry {
        let r = borrow_global<Registry>(@mohayo);
        assert!(table::contains(&r.skills, id), E_SKILL_NOT_FOUND);
        *table::borrow(&r.skills, id)
    }

    #[view]
    public fun skill_registered(id: u64): bool acquires Registry {
        let r = borrow_global<Registry>(@mohayo);
        table::contains(&r.skills, id)
    }

    #[view]
    public fun get_ai(id: u64): MonsterAI acquires Registry {
        let r = borrow_global<Registry>(@mohayo);
        assert!(table::contains(&r.ais, id), E_UNKNOWN_AI);
        *table::borrow(&r.ais, id)
    }

    #[view]
    public fun get_template(id: u64): EnemyTemplate acquires Registry {
        let r = borrow_global<Registry>(@mohayo);
        assert!(table::contains(&r.templates, id), E_TEMPLATE_EXISTS);
        *table::borrow(&r.templates, id)
    }

    #[view]
    public fun get_table(id: u64): vector<TableEntry> acquires Registry {
        let r = borrow_global<Registry>(@mohayo);
        assert!(table::contains(&r.tables, id), E_TABLE_EXISTS);
        *table::borrow(&r.tables, id)
    }

    #[view]
    public fun get_dungeon(difficulty: u64): DungeonConfig acquires Registry {
        let r = borrow_global<Registry>(@mohayo);
        assert!(table::contains(&r.dungeons, difficulty), E_DUNGEON_EXISTS);
        *table::borrow(&r.dungeons, difficulty)
    }

    #[view]
    public fun get_battle_count(difficulty: u64): u64 acquires Registry {
        let r = borrow_global<Registry>(@mohayo);
        if (!table::contains(&r.battle_count, difficulty)) return 0;
        *table::borrow(&r.battle_count, difficulty)
    }

    #[view]
    public fun get_battles(difficulty: u64): vector<BattleConfig> acquires Registry {
        let r = borrow_global<Registry>(@mohayo);
        if (!table::contains(&r.battles, difficulty)) return vector::empty();
        *table::borrow(&r.battles, difficulty)
    }

    #[view]
    public fun get_variants(difficulty: u64, battle_index: u64): vector<VariantEntry> acquires Registry {
        let r = borrow_global<Registry>(@mohayo);
        let key = difficulty * 100 + battle_index;
        if (!table::contains(&r.variants, key)) return vector::empty();
        *table::borrow(&r.variants, key)
    }

    #[view]
    public fun get_class_skill_ids(class_id: u8): vector<u64> acquires Registry {
        let r = borrow_global<Registry>(@mohayo);
        if (!table::contains(&r.class_skills, class_id)) return vector::empty();
        *table::borrow(&r.class_skills, class_id)
    }

    #[view]
    public fun next_room_id(): u64 acquires Registry {
        let r = borrow_global<Registry>(@mohayo);
        r.next_room_id
    }

    public fun bump_room_id(r: &mut Registry): u64 {
        let id = r.next_room_id;
        r.next_room_id = id + 1;
        id
    }

    public fun consume_next_room_id(): u64 acquires Registry {
        let r = borrow_global_mut<Registry>(@mohayo);
        let id = r.next_room_id;
        r.next_room_id = id + 1;
        id
    }

    // ---- test helper ----

    #[test_only]
    public fun init_for_test(account: &signer) {
        if (!exists<Registry>(signer::address_of(account))) {
            init_module(account);
        };
    }
}

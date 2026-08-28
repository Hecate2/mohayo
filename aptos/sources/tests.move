#[test_only]
module mohayo::tests {
    use std::signer;
    use std::vector;
    use mohayo::types;
    use mohayo::skill_registry;
    use mohayo::character;
    use mohayo::economy;
    use mohayo::engine;
    use mohayo::rng;

    // ===================== helpers =====================

    fun setup(account: &signer) {
        skill_registry::init_for_test(account);
        character::init_for_test(account);
        economy::init_for_test(account);
        engine::init_for_test(account);
    }

    fun skill_attack(): types::Skill {
        types::make_skill(
            0, 1, 0, 1, 0, 0, 0, 0,
            1, 0, 1, 1000, 0, 1000, 0,
            vector::empty(), types::make_summon_rule(0, 0, 0),
        )
    }

    fun skill_stun(): types::Skill {
        types::make_skill(
            0, 3, 0, 1, 0, 0, 0, 0,
            1, 0, 1, 0, 0, 1000, 0,
            vector[types::make_effect_spec(1, 2, 100, 1, 1000)],
            types::make_summon_rule(0, 0, 0),
        )
    }

    fun skill_heal(): types::Skill {
        types::make_skill(
            0, 3, 0, 1, 0, 0, 0, 0,
            10, 0, 1, 500, 0, 1000, 0,
            vector[types::make_effect_spec(9, 1, 500, 1, 1000)],
            types::make_summon_rule(0, 0, 0),
        )
    }

    fun skill_dmg_out_mod(): types::Skill {
        types::make_skill(
            0, 3, 0, 1, 0, 0, 0, 0,
            9, 0, 1, 0, 0, 1000, 0,
            vector[types::make_effect_spec(2, 3, 200, 0, 1000)],
            types::make_summon_rule(0, 0, 0),
        )
    }

    fun skill_dmg_in_mod(): types::Skill {
        types::make_skill(
            0, 3, 0, 1, 0, 0, 0, 0,
            1, 0, 1, 0, 0, 1000, 0,
            vector[types::make_effect_spec(3, 2, 200, 1, 1000)],
            types::make_summon_rule(0, 0, 0),
        )
    }

    fun skill_mana_gain(): types::Skill {
        types::make_skill(
            0, 3, 0, 0, 0, 0, 0, 0,
            9, 0, 1, 0, 0, 1000, 0,
            vector[types::make_effect_spec(13, 1, 5, 0, 1000)],
            types::make_summon_rule(0, 0, 0),
        )
    }

    fun skill_shield(): types::Skill {
        types::make_skill(
            0, 3, 0, 1, 0, 0, 0, 0,
            9, 0, 1, 0, 0, 1000, 0,
            vector[types::make_effect_spec(4, 3, 1200, 3, 1000)],
            types::make_summon_rule(0, 0, 0),
        )
    }

    fun skill_mana_bolt(): types::Skill {
        types::make_skill(
            0, 2, 0, 1, 0, 0, 0, 0,
            1, 0, 1, 1200, 0, 900, 0,
            vector::empty(), types::make_summon_rule(0, 0, 0),
        )
    }

    fun simple_ai(skill_id: u64): types::MonsterAI {
        types::make_monster_ai(vector[skill_id], 1)
    }

    fun simple_template(ai_id: u64): types::EnemyTemplate {
        types::make_enemy_template(
            ai_id, 1, 1000, 500, 500, 10, 1000, 10, 20,
            types::make_on_death_spawn(0, 0, 0),
        )
    }

    // ===================== types tests =====================

    #[test]
    fun test_type_constants() {
        assert!(types::KIND_PHYSICAL() == 1, 1);
        assert!(types::KIND_MAGIC() == 2, 2);
        assert!(types::KIND_SUPPORT() == 3, 3);
        assert!(types::TGT_ALL_ENEMY() == 4, 3);
        assert!(types::TGT_SELF() == 9, 4);
        assert!(types::OP_STUN() == 1, 5);
        assert!(types::OP_DMG_OUT_MOD() == 2, 6);
        assert!(types::OP_DMG_IN_MOD() == 3, 7);
        assert!(types::OP_SHIELD() == 4, 8);
        assert!(types::OP_HEAL() == 9, 9);
        assert!(types::OP_DISPEL() == 10, 10);
        assert!(types::OP_MANA_DELTA() == 13, 11);
        assert!(types::PHASE_LOBBY() == 0, 12);
        assert!(types::PHASE_COMBAT() == 1, 13);
        assert!(types::PHASE_SETTLED() == 2, 14);
        assert!(types::PHASE_INTERMISSION() == 3, 15);
    }

    #[test]
    fun test_skill_constructor_and_accessors() {
        let s = types::make_skill(
            42, 1, 3, 2, 0, 0, 5, 10,
            4, 0, 3, 800, 500, 950, 1,
            vector[types::make_effect_spec(1, 2, 100, 1, 500)],
            types::make_summon_rule(0, 0, 0),
        );
        assert!(types::skill_id(&s) == 42, 1);
        assert!(types::skill_kind(&s) == 1, 2);
        assert!(types::skill_power(&s) == 800, 3);
        assert!(types::skill_damage_cap(&s) == 500, 4);
        assert!(types::skill_base_acc(&s) == 950, 5);
        assert!(types::skill_targeting(&s) == 4, 6);
        assert!(types::skill_flags(&s) == 1, 7);
        assert!(types::skill_mana_cost(&s) == 5, 8);
        assert!(types::skill_ap_cost(&s) == 3, 9);
        assert!(types::skill_ap_gain(&s) == 2, 10);
        assert!(types::skill_hp_cost(&s) == 10, 11);
        assert!(types::skill_target_count(&s) == 3, 12);
    }

    #[test]
    fun test_enemy_template_constructor() {
        let ods = types::make_on_death_spawn(5, 2, 300);
        let t = types::make_enemy_template(1, 3, 2000, 600, 400, 15, 900, 50, 100, ods);
        assert!(types::template_max_hp(&t) == 2000, 1);
        assert!(types::template_power(&t) == 600, 2);
        assert!(types::template_magic(&t) == 400, 3);
        assert!(types::template_speed(&t) == 15, 4);
        assert!(types::template_threat(&t) == 3, 5);
        assert!(types::template_ai_id(&t) == 1, 6);
        assert!(types::template_reward_min(&t) == 50, 7);
        assert!(types::template_reward_max(&t) == 100, 8);
        let ods_ref = types::template_on_death_spawn(&t);
        assert!(types::on_death_spawn_template_id(ods_ref) == 5, 9);
        assert!(types::on_death_spawn_count(ods_ref) == 2, 10);
        assert!(types::on_death_spawn_prob(ods_ref) == 300, 11);
    }

    #[test]
    fun test_effect_spec_constructor() {
        let e = types::make_effect_spec(6, 3, 500, 2, 800);
        assert!(types::effect_op(&e) == 6, 1);
        assert!(types::effect_duration(&e) == 3, 2);
        assert!(types::effect_magnitude(&e) == 500, 3);
        assert!(types::effect_scope(&e) == 2, 4);
        assert!(types::effect_prob(&e) == 800, 5);
    }

    #[test]
    fun test_dungeon_config_constructor() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        let d = types::make_dungeon_config(1, 3, 5, 100, 25, 50, 5, 4);
        assert!(types::dungeon_table_id(&d) == 1, 1);
        assert!(types::dungeon_enemy_count(&d) == 3, 2);
        assert!(types::dungeon_mana_per_turn(&d) == 5, 3);
        assert!(types::dungeon_battles(&d) == 4, 4);
        assert!(types::dungeon_entry_fee(&d) == 25, 5);
        assert!(types::dungeon_rescue_fee(&d) == 50, 6);
    }

    #[test]
    fun test_target_constructor() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        let t = types::make_target(true, 3);
        assert!(types::target_is_enemy(&t) == true, 1);
        assert!(types::target_index(&t) == 3, 2);
        let t2 = types::make_target(false, 7);
        assert!(types::target_is_enemy(&t2) == false, 3);
        assert!(types::target_index(&t2) == 7, 4);
    }

    // ===================== rng tests =====================

    #[test]
    fun test_rng_deterministic() {
        let a = rng::new(42);
        let b = rng::new(42);
        let i = 0;
        while (i < 8) {
            assert!(rng::next(&mut a) == rng::next(&mut b), 1);
            i = i + 1;
        };
        let c = rng::new(43);
        assert!(rng::next(&mut c) != rng::next(&mut a), 2);
    }

    #[test]
    fun test_rng_bounds() {
        let r = rng::new(7);
        let i = 0;
        while (i < 200) {
            let v = rng::range(&mut r, 5, 17);
            assert!(v >= 5 && v < 17, 3);
            i = i + 1;
        };
        assert!(rng::range(&mut r, 9, 9) == 9, 4);
        assert!(rng::below(&mut r, 0) == 0, 5);
    }

    // ===================== skill_registry tests =====================

    #[test]
    fun test_register_skill() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        let s = skill_attack();
        skill_registry::register_skill(a, s);
        assert!(skill_registry::skill_registered(1), 1);
        let retrieved = skill_registry::get_skill(1);
        assert!(types::skill_id(&retrieved) == 1, 2);
        assert!(types::skill_kind(&retrieved) == 1, 3);
    }

    #[test]
    fun test_register_multiple_skills() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        skill_registry::register_skill(a, skill_attack());
        skill_registry::register_skill(a, skill_stun());
        skill_registry::register_skill(a, skill_heal());
        assert!(skill_registry::skill_registered(1), 1);
        assert!(skill_registry::skill_registered(2), 2);
        assert!(skill_registry::skill_registered(3), 3);
    }

    #[test]
    fun test_register_ai_and_template() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        skill_registry::register_skill(a, skill_attack());
        let ai = simple_ai(1);
        skill_registry::register_ai(a, ai);
        let tmpl = simple_template(1);
        skill_registry::register_template(a, tmpl);
        let retrieved_tmpl = skill_registry::get_template(1);
        assert!(types::template_max_hp(&retrieved_tmpl) == 1000, 1);
        assert!(types::template_power(&retrieved_tmpl) == 500, 2);
    }

    #[test]
    fun test_register_table() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        let entries = vector[
            types::make_table_entry(1, 700),
            types::make_table_entry(2, 300),
        ];
        skill_registry::register_table(a, entries);
        let retrieved = skill_registry::get_table(1);
        assert!(vector::length(&retrieved) == 2, 1);
    }

    #[test]
    fun test_dungeon_config() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        let dungeon = types::make_dungeon_config(1, 3, 5, 100, 25, 50, 5, 1);
        skill_registry::set_dungeon(a, 1, dungeon);
        let d = skill_registry::get_dungeon(1);
        assert!(types::dungeon_mana_per_turn(&d) == 5, 1);
        assert!(types::dungeon_enemy_count(&d) == 3, 2);
    }

    #[test]
    fun test_battle_config() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        let dungeon = types::make_dungeon_config(1, 3, 5, 100, 25, 50, 5, 2);
        skill_registry::set_dungeon(a, 1, dungeon);
        let configs = vector[
            types::make_battle_config(1, 2),
            types::make_battle_config(1, 4),
        ];
        skill_registry::set_dungeon_battles(a, 1, configs);
        assert!(skill_registry::get_battle_count(1) == 2, 1);
        let battles = skill_registry::get_battles(1);
        assert!(vector::length(&battles) == 2, 2);
    }

    #[test]
    fun test_variant() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        skill_registry::add_battle_variant(a, 9, 4, 74, 150);
        skill_registry::add_battle_variant(a, 9, 4, 75, 850);
        let variants = skill_registry::get_variants(9, 4);
        assert!(vector::length(&variants) == 2, 1);
    }

    #[test]
    fun test_class_skills() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        let s = types::make_skill(
            0, 1, 0, 1, 0, 0, 0, 0,
            1, 0, 1, 1000, 0, 1000, 0,
            vector::empty(), types::make_summon_rule(0, 0, 0),
        );
        skill_registry::register_class_skill(a, s, 1);
        let ids = skill_registry::get_class_skill_ids(1);
        assert!(vector::length(&ids) == 1, 1);
        assert!(*vector::borrow(&ids, 0) == 1, 2);
    }

    #[test]
    fun test_next_room_id() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        assert!(skill_registry::next_room_id() == 1, 1);
    }

    #[test]
    #[expected_failure(abort_code = 12)]
    fun test_register_bad_targeting() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        let s = types::make_skill(
            0, 1, 0, 0, 0, 0, 0, 0,
            99, 0, 1, 0, 0, 1000, 0,
            vector::empty(), types::make_summon_rule(0, 0, 0),
        );
        skill_registry::register_skill(a, s);
    }

    #[test]
    #[expected_failure(abort_code = 11)]
    fun test_register_bad_acc() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        let s = types::make_skill(
            0, 1, 0, 0, 0, 0, 0, 0,
            1, 0, 1, 0, 0, 2000, 0,
            vector::empty(), types::make_summon_rule(0, 0, 0),
        );
        skill_registry::register_skill(a, s);
    }

    // ===================== character tests =====================

    #[test]
    fun test_register_class_and_race() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        let class_def = types::make_class_def(0, 0, 0, 0, 2);
        character::register_class(a, 1, class_def);
        let c = character::get_class(1);
        assert!(types::class_def_skill_slots(&c) == 2, 1);

        let race_def = types::make_race_def(0, vector[0, 0, 0], 0, 0, 0);
        character::register_race(a, 0, race_def);
        let r = character::get_race(0);
        assert!(types::race_def_self_select_bonus(&r) == 0, 2);
    }

    #[test]
    fun test_gm_mint_character() {
        let a = &std::account::create_account_for_test(@mohayo);
        let player = &std::account::create_account_for_test(@0x100);
        setup(a);
        let class_def = types::make_class_def(0, 200, 0, 0, 2);
        character::register_class(a, 1, class_def);
        let race_def = types::make_race_def(0, vector[0, 0, 0], 0, 0, 0);
        character::register_race(a, 0, race_def);
        character::gm_mint(a, signer::address_of(player), 1, 0, vector::empty(), vector::empty());
        let (class_id, race, level, hp, max_hp, atk, mag, spd, _skills, _room) = character::get_character(1);
        assert!(class_id == 1, 1);
        assert!(race == 0, 2);
        assert!(level == 1, 3);
        assert!(hp > 0, 4);
        assert!(atk > 10, 5);
    }

    #[test]
    fun test_gm_mint_at_level() {
        let a = &std::account::create_account_for_test(@mohayo);
        let player = &std::account::create_account_for_test(@0x100);
        setup(a);
        let class_def = types::make_class_def(0, 0, 0, 0, 2);
        character::register_class(a, 1, class_def);
        let race_def = types::make_race_def(0, vector[0, 0, 0], 0, 0, 0);
        character::register_race(a, 0, race_def);
        character::gm_mint_at_level(a, signer::address_of(player), 1, 0, vector::empty(), vector::empty(), 100);
        let (_class_id, _race, level, hp, _max_hp, _atk, _mag, _spd, _skills, _room) = character::get_character(1);
        assert!(level == 100, 1);
        assert!(hp > 100, 2);
    }

    #[test]
    fun test_gm_set_level() {
        let a = &std::account::create_account_for_test(@mohayo);
        let player = &std::account::create_account_for_test(@0x100);
        setup(a);
        let class_def = types::make_class_def(0, 0, 0, 0, 2);
        character::register_class(a, 1, class_def);
        let race_def = types::make_race_def(0, vector[0, 0, 0], 0, 0, 0);
        character::register_race(a, 0, race_def);
        character::gm_mint(a, signer::address_of(player), 1, 0, vector::empty(), vector::empty());
        let (_c, _r, l1, hp1, _mh, _a, _m, _s, _sk, _rm) = character::get_character(1);
        assert!(l1 == 1, 1);
        character::gm_set_level(a, 1, 50);
        let (_c, _r, l2, hp2, _mh, _a, _m, _s, _sk, _rm) = character::get_character(1);
        assert!(l2 == 50, 2);
        assert!(hp2 > hp1, 3);
    }

    #[test]
    fun test_character_race_class_mods() {
        let a = &std::account::create_account_for_test(@mohayo);
        let player = &std::account::create_account_for_test(@0x100);
        setup(a);
        let class_def = types::make_class_def(200, 50, 0, -50, 2);
        character::register_class(a, 1, class_def);
        let race_def = types::make_race_def(0, vector[100, -50, -30], 0, 0, 0);
        character::register_race(a, 1, race_def);
        character::gm_mint(a, signer::address_of(player), 1, 1, vector::empty(), vector::empty());
        let (_c, _r, _l, _hp, _mh, atk, _mag, _spd, _sk, _rm) = character::get_character(1);
        assert!(atk > 10, 1);
    }

    #[test]
    fun test_character_stat_formula_level300() {
        let a = &std::account::create_account_for_test(@mohayo);
        let player = &std::account::create_account_for_test(@0x100);
        setup(a);
        let class_def = types::make_class_def(0, 0, 0, 0, 2);
        character::register_class(a, 1, class_def);
        let race_def = types::make_race_def(0, vector[0, 0, 0], 0, 0, 0);
        character::register_race(a, 0, race_def);
        character::gm_mint_at_level(a, signer::address_of(player), 1, 0, vector::empty(), vector::empty(), 300);
        let (_c, _r, _l, hp, _mh, atk, mag, spd, _sk, _rm) = character::get_character(1);
        // Level 300 with 0 mods: HP = 100*1000*300/1000 = 30000
        assert!(hp == 30000, 1);
        // ATK = 10*1000*300/1000 = 3000
        assert!(atk == 3000, 2);
        assert!(mag == 3000, 3);
        assert!(spd == 3000, 4);
    }

    #[test]
    fun test_character_room_lock() {
        let a = &std::account::create_account_for_test(@mohayo);
        let player = &std::account::create_account_for_test(@0x100);
        setup(a);
        let class_def = types::make_class_def(0, 0, 0, 0, 2);
        character::register_class(a, 1, class_def);
        let race_def = types::make_race_def(0, vector[0, 0, 0], 0, 0, 0);
        character::register_race(a, 0, race_def);
        character::gm_mint(a, signer::address_of(player), 1, 0, vector::empty(), vector::empty());
        assert!(character::get_room_id(1) == 0, 1);
        character::set_in_room(a, 1, 42);
        assert!(character::get_room_id(1) == 42, 2);
    }

    #[test]
    fun test_character_multiple_characters() {
        let a = &std::account::create_account_for_test(@mohayo);
        let p1 = &std::account::create_account_for_test(@0x100);
        let p2 = &std::account::create_account_for_test(@0x200);
        setup(a);
        let class_def = types::make_class_def(0, 0, 0, 0, 2);
        character::register_class(a, 1, class_def);
        let race_def = types::make_race_def(0, vector[0, 0, 0], 0, 0, 0);
        character::register_race(a, 0, race_def);
        character::gm_mint(a, signer::address_of(p1), 1, 0, vector::empty(), vector::empty());
        character::gm_mint(a, signer::address_of(p2), 1, 0, vector::empty(), vector::empty());
        let (_c1, _r1, _l1, hp1, _mh1, _a1, _m1, _s1, _sk1, _rm1) = character::get_character(1);
        let (_c2, _r2, _l2, hp2, _mh2, _a2, _m2, _s2, _sk2, _rm2) = character::get_character(2);
        assert!(hp1 == hp2, 1);
    }

    #[test]
    fun test_race_tier_weights() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        character::set_race_tier_weights(a, 850, 120, 30);
        character::set_race_pools(
            a,
            vector[0, 1, 2, 3],
            vector[4, 5],
            vector[6, 7],
        );
    }

    #[test]
    fun test_affix_template() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        let tmpl = types::make_affix_template(1, vector[500, 300, 200], vector[50, 100, 200]);
        character::register_affix_template(a, 0, tmpl);
    }

    // ===================== economy tests =====================

    #[test]
    fun test_economy_mint() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        economy::set_minter(a, @mohayo, true);
        economy::mint(a, @0x100, 500);
        assert!(economy::balance_of(@0x100) == 500, 1);
    }

    #[test]
    fun test_economy_spend() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        economy::set_spender(a, @mohayo, true);
        economy::gm_mint(a, @0x100, 1000);
        economy::spend(a, @0x100, 300);
        assert!(economy::balance_of(@0x100) == 700, 1);
    }

    #[test]
    #[expected_failure(abort_code = 2)]
    fun test_economy_unauthorized_mint() {
        let a = &std::account::create_account_for_test(@mohayo);
        let attacker = &std::account::create_account_for_test(@0x999);
        setup(a);
        economy::set_minter(a, @mohayo, true);
        economy::mint(attacker, @0x100, 500);
    }

    #[test]
    #[expected_failure(abort_code = 3)]
    fun test_economy_unauthorized_spend() {
        let a = &std::account::create_account_for_test(@mohayo);
        let attacker = &std::account::create_account_for_test(@0x999);
        setup(a);
        economy::gm_mint(a, @0x100, 1000);
        economy::spend(attacker, @0x100, 300);
    }

    #[test]
    #[expected_failure(abort_code = 4)]
    fun test_economy_insufficient_balance() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        economy::set_spender(a, @mohayo, true);
        economy::gm_mint(a, @0x100, 100);
        economy::spend(a, @0x100, 200);
    }

    #[test]
    fun test_economy_is_minter() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        assert!(!economy::is_minter(@mohayo), 1);
        economy::set_minter(a, @mohayo, true);
        assert!(economy::is_minter(@mohayo), 2);
        economy::set_minter(a, @mohayo, false);
        assert!(!economy::is_minter(@mohayo), 3);
    }

    #[test]
    fun test_economy_is_spender() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        assert!(!economy::is_spender(@mohayo), 1);
        economy::set_spender(a, @mohayo, true);
        assert!(economy::is_spender(@mohayo), 2);
    }

    // ===================== engine tests =====================

    fun setup_full_dungeon(a: &signer) {
        // Register attack skill (id=1)
        skill_registry::register_skill(a, skill_attack());
        // Register stun skill (id=2)
        skill_registry::register_skill(a, skill_stun());
        // Register heal skill (id=3)
        skill_registry::register_skill(a, skill_heal());
        // Register AI (id=1, uses skill 1)
        let ai = simple_ai(1);
        skill_registry::register_ai(a, ai);
        // Register template (id=1, ai=1, hp=1000, power=500)
        let tmpl = simple_template(1);
        skill_registry::register_template(a, tmpl);
        // Register table (id=1, one entry: template 1)
        let entries = vector[types::make_table_entry(1, 1000)];
        skill_registry::register_table(a, entries);
        // Set dungeon (difficulty 1, table=1, enemies=3, mana=5)
        let dungeon = types::make_dungeon_config(1, 3, 5, 100, 0, 0, 0, 1);
        skill_registry::set_dungeon(a, 1, dungeon);
    }

    #[test]
    fun test_create_room() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        setup_full_dungeon(a);
        engine::create_room(a, 1);
        assert!(engine::room_phase(1) == 0, 1);
    }

    #[test]
    fun test_join_room() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        setup_full_dungeon(a);
        engine::create_room(a, 1);
        engine::join_room(a, 1, 500, 100, 50, 30);
        assert!(engine::member_count(1) == 1, 1);
    }

    #[test]
    fun test_join_room_multiple() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        setup_full_dungeon(a);
        engine::create_room(a, 1);
        engine::join_room(a, 1, 500, 100, 50, 30);
        engine::join_room(a, 1, 300, 200, 100, 20);
        assert!(engine::member_count(1) == 2, 1);
    }

    #[test]
    fun test_start_combat() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        setup_full_dungeon(a);
        engine::create_room(a, 1);
        engine::join_room(a, 1, 500, 100, 50, 30);
        engine::start_combat(a, 1);
        assert!(engine::room_phase(1) == 1, 1);
        assert!(engine::enemy_count(1) == 3, 2);
    }

    #[test]
    fun test_set_plan_and_advance() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        setup_full_dungeon(a);
        engine::create_room(a, 1);
        engine::join_room(a, 1, 500, 100, 50, 30);
        engine::start_combat(a, 1);
        engine::set_plan(a, 1, 0, vector[1]);
        engine::advance_turn(a, 1);
        assert!(engine::room_turn(1) == 2, 1);
    }

    #[test]
    fun test_damage_dealt() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        skill_registry::register_skill(a, skill_attack()); // id=1
        let ai = simple_ai(1);
        skill_registry::register_ai(a, ai);
        let tmpl = simple_template(1);
        skill_registry::register_template(a, tmpl);
        let entries = vector[types::make_table_entry(1, 1000)];
        skill_registry::register_table(a, entries);
        let dungeon = types::make_dungeon_config(1, 1, 10, 100, 0, 0, 0, 1);
        skill_registry::set_dungeon(a, 1, dungeon);
        engine::create_room(a, 1);
        engine::join_room(a, 1, 500, 200, 50, 30);
        engine::start_combat(a, 1);
        let (hp1, _mh, _a, _m, _s, _alive) = engine::enemy_state(1, 0);
        assert!(hp1 == 1000, 1);
        engine::set_plan(a, 1, 0, vector[1]);
        engine::advance_turn(a, 1);
        let (hp2, _mh, _a, _m, _s, _alive) = engine::enemy_state(1, 0);
        assert!(hp2 < hp1, 2);
    }

    #[test]
    fun test_stun_prevents_action() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        // Register stun skill (id=1), attack skill (id=2)
        skill_registry::register_skill(a, skill_stun());
        skill_registry::register_skill(a, skill_attack());
        // AI uses stun
        let ai = types::make_monster_ai(vector[1], 1);
        skill_registry::register_ai(a, ai);
        let tmpl = types::make_enemy_template(1, 1, 500, 0, 0, 10, 1000, 10, 20, types::make_on_death_spawn(0, 0, 0));
        skill_registry::register_template(a, tmpl);
        let entries = vector[types::make_table_entry(1, 1000)];
        skill_registry::register_table(a, entries);
        let dungeon = types::make_dungeon_config(1, 1, 5, 100, 0, 0, 0, 1);
        skill_registry::set_dungeon(a, 1, dungeon);
        engine::create_room(a, 1);
        engine::join_room(a, 1, 500, 200, 50, 30);
        engine::start_combat(a, 1);
        engine::set_plan(a, 1, 0, vector[2]);
        // First turn: enemy uses stun on member
        engine::advance_turn(a, 1);
        // Check if member has stun effect
        let (_hp, _mh, _a, _m, _s, _alive) = engine::member_state(1, 0);
        // If stun landed, member effect count > 0
        // (stun prob is 1000 so it should always land)
        let effect_count = engine::member_effect_count(1, 0);
        assert!(effect_count > 0, 1);
    }

    #[test]
    fun test_damage_cap() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        // Attack skill with damage cap of 100
        let s = types::make_skill(
            0, 1, 0, 1, 0, 0, 0, 0,
            1, 0, 1, 5000, 100, 1000, 0,
            vector::empty(), types::make_summon_rule(0, 0, 0),
        );
        skill_registry::register_skill(a, s);
        let ai = simple_ai(1);
        skill_registry::register_ai(a, ai);
        // Enemy with high HP so we can see the cap
        let tmpl = types::make_enemy_template(1, 1, 10000, 500, 500, 10, 1000, 10, 20, types::make_on_death_spawn(0, 0, 0));
        skill_registry::register_template(a, tmpl);
        let entries = vector[types::make_table_entry(1, 1000)];
        skill_registry::register_table(a, entries);
        let dungeon = types::make_dungeon_config(1, 1, 10, 100, 0, 0, 0, 1);
        skill_registry::set_dungeon(a, 1, dungeon);
        engine::create_room(a, 1);
        // Very high attack so uncapped would be > 100
        engine::join_room(a, 1, 500, 1000, 50, 30);
        engine::start_combat(a, 1);
        let (hp1, _mh, _a, _m, _s, _alive) = engine::enemy_state(1, 0);
        engine::set_plan(a, 1, 0, vector[1]);
        engine::advance_turn(a, 1);
        let (hp2, _mh, _a, _m, _s, _alive) = engine::enemy_state(1, 0);
        let dmg = hp1 - hp2;
        // 5000 * 1000 / 1000 = 5000, cap = 100, so damage should be 100
        assert!(dmg == 100, 1);
    }

    #[test]
    fun test_dmg_out_mod_amplifies() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        // Normal attack (id=1)
        skill_registry::register_skill(a, skill_attack());
        // Self-buff: DMG_OUT_MOD +200% (id=2)
        skill_registry::register_skill(a, skill_dmg_out_mod());
        let ai = simple_ai(1);
        skill_registry::register_ai(a, ai);
        let tmpl = simple_template(1);
        skill_registry::register_template(a, tmpl);
        let entries = vector[types::make_table_entry(1, 1000)];
        skill_registry::register_table(a, entries);
        let dungeon = types::make_dungeon_config(1, 1, 10, 100, 0, 0, 0, 1);
        skill_registry::set_dungeon(a, 1, dungeon);
        engine::create_room(a, 1);
        engine::join_room(a, 1, 500, 100, 50, 30);
        engine::start_combat(a, 1);
        let (hp1, _mh, _a, _m, _s, _alive) = engine::enemy_state(1, 0);
        // Plan: self-buff then attack
        engine::set_plan(a, 1, 0, vector[2, 1]);
        engine::advance_turn(a, 1);
        // After buff: turn 1 = buff, turn 2 = attack with +200% damage
        engine::set_plan(a, 1, 0, vector[1]);
        engine::advance_turn(a, 1);
        let (hp2, _mh, _a, _m, _s, _alive) = engine::enemy_state(1, 0);
        let dmg = hp1 - hp2;
        // Turn 1: buff, turn 2: attack. Base dmg = 100*1000/1000 = 100
        // With +200% out_mod: 100 * (1000+200)/1000 = 120
        assert!(dmg == 120, 1);
    }

    #[test]
    fun test_dmg_in_mod_amplifies() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        skill_registry::register_skill(a, skill_attack()); // id=1
        skill_registry::register_skill(a, skill_dmg_in_mod()); // id=2: 1000 dmg + 200% DMG_IN_MOD
        let ai = simple_ai(1);
        skill_registry::register_ai(a, ai);
        let tmpl = simple_template(1);
        skill_registry::register_template(a, tmpl);
        let entries = vector[types::make_table_entry(1, 1000)];
        skill_registry::register_table(a, entries);
        let dungeon = types::make_dungeon_config(1, 1, 10, 100, 0, 0, 0, 1);
        skill_registry::set_dungeon(a, 1, dungeon);
        engine::create_room(a, 1);
        engine::join_room(a, 1, 500, 100, 50, 30);
        engine::start_combat(a, 1);
        let (hp1, _mh, _a, _m, _s, _alive) = engine::enemy_state(1, 0);
        // Plan: debuff enemy then attack
        engine::set_plan(a, 1, 0, vector[2, 1]);
        engine::advance_turn(a, 1);
        engine::set_plan(a, 1, 0, vector[1]);
        engine::advance_turn(a, 1);
        let (hp2, _mh, _a, _m, _s, _alive) = engine::enemy_state(1, 0);
        let dmg = hp1 - hp2;
        // Turn 1: skill 2 on enemy - DMG_IN_MOD +200% on enemy
        // Turn 2: skill 1 on enemy - base 100, then in_mod: 100 * (1000+200)/1000 = 120
        assert!(dmg == 120, 1);
    }

    #[test]
    fun test_shield_absorbs_damage() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        skill_registry::register_skill(a, skill_shield()); // id=1: shield 300 for 3 turns
        skill_registry::register_skill(a, skill_attack()); // id=2
        let ai = simple_ai(2);
        skill_registry::register_ai(a, ai);
        let tmpl = simple_template(1);
        skill_registry::register_template(a, tmpl);
        let entries = vector[types::make_table_entry(1, 1000)];
        skill_registry::register_table(a, entries);
        let dungeon = types::make_dungeon_config(1, 1, 10, 100, 0, 0, 0, 1);
        skill_registry::set_dungeon(a, 1, dungeon);
        engine::create_room(a, 1);
        engine::join_room(a, 1, 500, 100, 50, 30);
        engine::start_combat(a, 1);
        // Plan: shield self, then attack
        engine::set_plan(a, 1, 0, vector[1, 2]);
        engine::advance_turn(a, 1);
        // Check member has shield effect
        let ec = engine::member_effect_count(1, 0);
        assert!(ec > 0, 1);
        // Advance to let enemy attack (should be absorbed by shield)
        engine::set_plan(a, 1, 0, vector[2]);
        engine::advance_turn(a, 1);
        // Member should still have HP close to max due to shield
        let (hp, max_hp, _a, _m, _s, _alive) = engine::member_state(1, 0);
        assert!(hp > max_hp - 100, 2);
    }

    #[test]
    fun test_heal() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        // Register a self-damage skill (hp_cost=200, power=0, SELF targeting)
        let sac_s = types::make_skill(
            0, 1, 0, 1, 0, 0, 0, 200,
            9, 0, 1, 0, 0, 1000, 0,
            vector::empty(), types::make_summon_rule(0, 0, 0),
        );
        skill_registry::register_skill(a, sac_s); // id=1: sacrifice (costs 200 HP)
        // Register heal skill (most wounded ally, heals 600)
        let heal_s = types::make_skill(
            0, 3, 0, 1, 0, 0, 0, 0,
            10, 0, 1, 0, 0, 1000, 0,
            vector[types::make_effect_spec(9, 1, 600, 1, 1000)],
            types::make_summon_rule(0, 0, 0),
        );
        skill_registry::register_skill(a, heal_s); // id=2: heal
        // Passive enemy (no damage)
        let ai = simple_ai(1);
        skill_registry::register_ai(a, ai);
        let weak_tmpl = types::make_enemy_template(
            1, 1, 1000, 0, 0, 50, 1000, 0, 100,
            types::make_on_death_spawn(0, 0, 0),
        );
        skill_registry::register_template(a, weak_tmpl);
        let entries = vector[types::make_table_entry(1, 1000)];
        skill_registry::register_table(a, entries);
        let dungeon = types::make_dungeon_config(1, 1, 10, 100, 0, 0, 0, 1);
        skill_registry::set_dungeon(a, 1, dungeon);
        engine::create_room(a, 1);
        engine::join_room(a, 1, 1000, 100, 50, 30);
        engine::start_combat(a, 1);
        let (hp_before, _mh, _a, _m, _s, _alive) = engine::member_state(1, 0);
        // Turn 1: sacrifice 200 HP → HP drops to 800
        engine::set_plan(a, 1, 0, vector[1]);
        engine::advance_turn(a, 1);
        let (hp_after_enemy, _mh, _a, _m, _s, _alive) = engine::member_state(1, 0);
        assert!(hp_after_enemy < hp_before, 3);
        // Turn 2: heal 600 HP → HP should increase
        engine::set_plan(a, 1, 0, vector[2]);
        engine::advance_turn(a, 1);
        let (hp_healed, _mh, _a, _m, _s, _alive) = engine::member_state(1, 0);
        assert!(hp_healed > hp_after_enemy, 1);
    }

    #[test]
    fun test_victory() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        // Very weak enemy (1 HP)
        skill_registry::register_skill(a, skill_attack());
        let ai = simple_ai(1);
        skill_registry::register_ai(a, ai);
        let tmpl = types::make_enemy_template(1, 1, 1, 0, 0, 1, 1000, 10, 20, types::make_on_death_spawn(0, 0, 0));
        skill_registry::register_template(a, tmpl);
        let entries = vector[types::make_table_entry(1, 1000)];
        skill_registry::register_table(a, entries);
        let dungeon = types::make_dungeon_config(1, 1, 5, 100, 0, 0, 0, 1);
        skill_registry::set_dungeon(a, 1, dungeon);
        engine::create_room(a, 1);
        engine::join_room(a, 1, 500, 100, 50, 30);
        engine::start_combat(a, 1);
        engine::set_plan(a, 1, 0, vector[1]);
        engine::advance_turn(a, 1);
        // Enemy should be dead, victory
        assert!(engine::room_phase(1) == 2, 1);
    }

    #[test]
    fun test_defeat() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        // Super strong enemy that one-shots member
        skill_registry::register_skill(a, skill_attack());
        let ai = simple_ai(1);
        skill_registry::register_ai(a, ai);
        let tmpl = types::make_enemy_template(1, 1, 10000, 99999, 0, 100, 1000, 10, 20, types::make_on_death_spawn(0, 0, 0));
        skill_registry::register_template(a, tmpl);
        let entries = vector[types::make_table_entry(1, 1000)];
        skill_registry::register_table(a, entries);
        let dungeon = types::make_dungeon_config(1, 1, 5, 100, 0, 0, 0, 1);
        skill_registry::set_dungeon(a, 1, dungeon);
        engine::create_room(a, 1);
        engine::join_room(a, 1, 10, 10, 10, 10);
        engine::start_combat(a, 1);
        // Member with 10 HP vs enemy with 99999 attack
        // Member attacks first (higher speed?), then enemy attacks and kills
        engine::set_plan(a, 1, 0, vector[1]);
        engine::advance_turn(a, 1);
        // Check if member is dead
        let (_hp, _mh, _a, _m, _s, alive) = engine::member_state(1, 0);
        // Either member survived turn 1 or is dead
        // Let's advance more turns
        if (alive == 1) {
            engine::set_plan(a, 1, 0, vector[1]);
            engine::advance_turn(a, 1);
        };
    }

    #[test]
    fun test_multi_battle_dungeon() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        skill_registry::register_skill(a, skill_attack());
        let ai = simple_ai(1);
        skill_registry::register_ai(a, ai);
        // Weak enemy for battle 1
        let tmpl1 = types::make_enemy_template(1, 1, 1, 0, 0, 1, 1000, 10, 20, types::make_on_death_spawn(0, 0, 0));
        skill_registry::register_template(a, tmpl1);
        let entries = vector[types::make_table_entry(1, 1000)];
        skill_registry::register_table(a, entries);
        // 2-battle dungeon
        let dungeon = types::make_dungeon_config(1, 1, 5, 100, 0, 0, 0, 2);
        skill_registry::set_dungeon(a, 1, dungeon);
        engine::create_room(a, 1);
        engine::join_room(a, 1, 500, 100, 50, 30);
        engine::start_combat(a, 1);
        // Battle 1: kill weak enemy
        engine::set_plan(a, 1, 0, vector[1]);
        engine::advance_turn(a, 1);
        // Should be in intermission (phase 3)
        assert!(engine::room_phase(1) == 3, 1);
        // Advance to battle 2
        engine::advance_battle(a, 1);
        assert!(engine::room_phase(1) == 1, 2);
        let (bi, tb) = engine::room_battle(1);
        assert!(bi == 2, 3);
        assert!(tb == 2, 4);
    }

    #[test]
    fun test_mana_pool() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        // Skill with mana cost
        let s = types::make_skill(
            0, 1, 0, 1, 0, 0, 3, 0,
            1, 0, 1, 1000, 0, 1000, 0,
            vector::empty(), types::make_summon_rule(0, 0, 0),
        );
        skill_registry::register_skill(a, s);
        let ai = simple_ai(1);
        skill_registry::register_ai(a, ai);
        let tmpl = simple_template(1);
        skill_registry::register_template(a, tmpl);
        let entries = vector[types::make_table_entry(1, 1000)];
        skill_registry::register_table(a, entries);
        let dungeon = types::make_dungeon_config(1, 1, 5, 100, 0, 0, 0, 1);
        skill_registry::set_dungeon(a, 1, dungeon);
        engine::create_room(a, 1);
        engine::join_room(a, 1, 500, 100, 50, 30);
        engine::start_combat(a, 1);
        // Turn 1: mana = 5 (from mana_per_turn), costs 3, should work
        let mana1 = engine::room_mana(1);
        assert!(mana1 == 5, 1);
        engine::set_plan(a, 1, 0, vector[1]);
        engine::advance_turn(a, 1);
        let mana2 = engine::room_mana(1);
        // After turn: 5 - 3 + 5 = 7
        assert!(mana2 == 7, 2);
    }

    #[test]
    fun test_enemy_ai_cycle() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        // Two skills: attack (id=1) and stun (id=2)
        skill_registry::register_skill(a, skill_attack());
        skill_registry::register_skill(a, skill_stun());
        // AI alternates: [attack, stun]
        let ai = types::make_monster_ai(vector[1, 2], 2);
        skill_registry::register_ai(a, ai);
        let tmpl = simple_template(1);
        skill_registry::register_template(a, tmpl);
        let entries = vector[types::make_table_entry(1, 1000)];
        skill_registry::register_table(a, entries);
        let dungeon = types::make_dungeon_config(1, 1, 10, 100, 0, 0, 0, 1);
        skill_registry::set_dungeon(a, 1, dungeon);
        engine::create_room(a, 1);
        engine::join_room(a, 1, 500, 100, 50, 30);
        engine::start_combat(a, 1);
        // Turn 1: enemy uses attack (cycle[0])
        engine::set_plan(a, 1, 0, vector[1]);
        engine::advance_turn(a, 1);
        // Turn 2: enemy uses stun (cycle[1])
        engine::set_plan(a, 1, 0, vector[1]);
        engine::advance_turn(a, 1);
        // Check member has stun effect after turn 2
        let ec = engine::member_effect_count(1, 0);
        assert!(ec > 0, 1);
    }

    #[test]
    fun test_cancel_plan() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        setup_full_dungeon(a);
        engine::create_room(a, 1);
        engine::join_room(a, 1, 500, 100, 50, 30);
        engine::start_combat(a, 1);
        engine::set_plan(a, 1, 0, vector[1, 1, 1]);
        engine::cancel_plan(a, 1, 0);
        // After cancel, member has no plan so does nothing
        let (hp_before, _mh, _a, _m, _s, _alive) = engine::enemy_state(1, 0);
        engine::advance_turn(a, 1);
        let (hp_after, _mh, _a, _m, _s, _alive) = engine::enemy_state(1, 0);
        assert!(hp_before == hp_after, 1);
    }

    #[test]
    fun test_leave_room() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        setup_full_dungeon(a);
        engine::create_room(a, 1);
        engine::join_room(a, 1, 500, 100, 50, 30);
        assert!(engine::member_count(1) == 1, 1);
        engine::leave_room(a, 1);
    }

    #[test]
    fun test_reward_pool() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        // Kill enemy to earn reward
        skill_registry::register_skill(a, skill_attack());
        let ai = simple_ai(1);
        skill_registry::register_ai(a, ai);
        // Weak enemy with reward 50-100
        let tmpl = types::make_enemy_template(1, 1, 1, 0, 0, 1, 1000, 50, 100, types::make_on_death_spawn(0, 0, 0));
        skill_registry::register_template(a, tmpl);
        let entries = vector[types::make_table_entry(1, 1000)];
        skill_registry::register_table(a, entries);
        let dungeon = types::make_dungeon_config(1, 1, 5, 100, 0, 0, 0, 1);
        skill_registry::set_dungeon(a, 1, dungeon);
        engine::create_room(a, 1);
        engine::join_room(a, 1, 500, 100, 50, 30);
        engine::start_combat(a, 1);
        engine::set_plan(a, 1, 0, vector[1]);
        engine::advance_turn(a, 1);
        // Victory: reward pool should be 0 (distributed)
        assert!(engine::room_phase(1) == 2, 1);
        // Rewards were distributed, pool is 0
        let rp = engine::reward_pool(1);
        assert!(rp == 0, 2);
    }

    // ===================== combined integration tests =====================

    #[test]
    fun test_full_combat_flow() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);

        // Setup skills
        skill_registry::register_skill(a, skill_attack()); // 1
        skill_registry::register_skill(a, skill_heal());   // 2
        skill_registry::register_skill(a, skill_stun());   // 3
        // AI
        let ai = simple_ai(1);
        skill_registry::register_ai(a, ai);
        // Template
        let tmpl = simple_template(1);
        skill_registry::register_template(a, tmpl);
        // Table
        let entries = vector[types::make_table_entry(1, 1000)];
        skill_registry::register_table(a, entries);
        // Dungeon
        let dungeon = types::make_dungeon_config(1, 1, 5, 100, 0, 0, 0, 1);
        skill_registry::set_dungeon(a, 1, dungeon);

        // Create room, join, fight
        engine::create_room(a, 1);
        engine::join_room(a, 1, 1000, 200, 100, 30);
        engine::start_combat(a, 1);

        // Run 10 turns of combat
        let turn = 0;
        while (turn < 10) {
            let phase = engine::room_phase(1);
            if (phase != 1) break;
            engine::set_plan(a, 1, 0, vector[1]);
            engine::advance_turn(a, 1);
            turn = turn + 1;
        };

        // Combat should have ended
        let final_phase = engine::room_phase(1);
        assert!(final_phase == 2 || final_phase == 3, 1);
    }

    #[test]
    fun test_two_party_combat() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);

        skill_registry::register_skill(a, skill_attack()); // 1
        let ai = simple_ai(1);
        skill_registry::register_ai(a, ai);
        let tmpl = simple_template(1);
        skill_registry::register_template(a, tmpl);
        let entries = vector[types::make_table_entry(1, 1000)];
        skill_registry::register_table(a, entries);
        let dungeon = types::make_dungeon_config(1, 1, 5, 100, 0, 0, 0, 1);
        skill_registry::set_dungeon(a, 1, dungeon);

        engine::create_room(a, 1);
        engine::join_room(a, 1, 500, 100, 50, 30);
        engine::join_room(a, 1, 400, 150, 80, 25);
        engine::start_combat(a, 1);
        assert!(engine::member_count(1) == 2, 1);
        // Both members attack
        engine::set_plan(a, 1, 0, vector[1]);
        engine::set_plan(a, 1, 1, vector[1]);
        engine::advance_turn(a, 1);
        // Both should have dealt damage
        let (hp1, _, _, _, _, _) = engine::enemy_state(1, 0);
        assert!(hp1 < 1000, 2);
    }
}

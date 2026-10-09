#[test_only]
module mohayo::tests {
    use aptos_framework::randomness;
    use std::signer;
    use std::vector;
    use mohayo::types;
    use mohayo::skill_registry;
    use mohayo::character;
    use mohayo::economy;
    use mohayo::engine;
    use mohayo::rng;
    use mohayo::content_registration;
    use mohayo::use_item;
    use mohayo::item;

    // ===================== helpers =====================

    fun setup(account: &signer) {
        skill_registry::init_for_test(account);
        character::init_for_test(account);
        economy::init_for_test(account);
        engine::init_for_test(account);
        use_item::init_for_test(account); // 入场次数门控(create_room → consume_entry)
        use_item::set_window_limit(account, 1000); // 测试需大量开房; 次数规则由专门用例验证
        engine::init_timestamp_for_test();

        // 测试钱包：覆盖入场费/救援费/收益结算链路
        economy::gm_mint(account, @mohayo, 1000000000);
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

    fun skill_shield(): types::Skill {
        types::make_skill(
            0, 3, 0, 1, 0, 0, 0, 0,
            9, 0, 1, 0, 0, 1000, 0,
            vector[types::make_effect_spec(4, 3, 1200, 3, 1000)],
            types::make_summon_rule(0, 0, 0),
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
        let d = types::make_dungeon_config(1, 3, 5, 25, 50, 5, 4);
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
        let dungeon = types::make_dungeon_config(1, 3, 5, 25, 50, 5, 1);
        skill_registry::set_dungeon(a, 1, dungeon);
        let d = skill_registry::get_dungeon(1);
        assert!(types::dungeon_mana_per_turn(&d) == 5, 1);
        assert!(types::dungeon_enemy_count(&d) == 3, 2);
    }

    #[test]
    fun test_battle_config() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        let dungeon = types::make_dungeon_config(1, 3, 5, 25, 50, 5, 2);
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
        skill_registry::add_battle_variant(a, 9, 4, 74, 150, 0);
        skill_registry::add_battle_variant(a, 9, 4, 75, 850, 0);
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
    #[expected_failure(abort_code = 12, location = mohayo::skill_registry)]
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
    #[expected_failure(abort_code = 11, location = mohayo::skill_registry)]
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

    /// §2.6.11 复审: 资源词条必须端到端生效 —— ① `compute_affixes` 解析出四项加成
    /// ② `join_room_as_char` 把它们拷进 Member(此前分别因循环初值写错、入房硬写 0 而全线失效)。
    #[test]
    fun test_resource_affixes_reach_member() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        let addr = std::signer::address_of(a);
        // 4 个能力档 + 4 条资源词条(0=AP消耗−1, 1=AP产量+1, 2=魔素消耗−1, 3=魔素产量+1)
        character::gm_mint(a, addr, 1, 0, vector[1, 1, 1, 1, 0, 1, 2, 3], vector::empty());
        let cid = character::owner_latest_char(addr);
        assert!(character::get_ap_discount(cid) == 1, 1);
        assert!(character::get_ap_bonus(cid) == 1, 2);
        assert!(character::get_mana_discount(cid) == 1, 3);
        assert!(character::get_mana_gain_bonus(cid) == 1, 4);
        engine::create_room(a, 1);
        engine::join_room_as_char(a, 1, cid);
        let (ap_disc, mana_disc, ap_bon, mana_gain) = engine::member_resources(1, 0);
        assert!(ap_disc == 1, 5);
        assert!(mana_disc == 1, 6);
        assert!(ap_bon == 1, 7);
        assert!(mana_gain == 1, 8);
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
        // set_race_pools 现在要求池内每个 race_id 都已注册（否则 pick_race 越界 abort）
        let i = 0;
        while (i < 8) {
            character::register_race(a, (i as u8), types::make_race_def(0, vector[0, 0, 0], 0, 0, 0));
            i = i + 1;
        };
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
        // tier_values 必须给满 10 档（compute_affixes 按 (tier-1) 索引，玩家掷出高 tier 时会越界）
        let tmpl = types::make_affix_template(
            1,
            vector[500, 300, 200, 100, 50, 30, 20, 10, 5, 2],
            vector[50, 100, 200, 300, 400, 500, 600, 700, 800, 900],
        );
        character::register_affix_template(a, 0, tmpl);
    }

    // ===================== GM 注册入口校验（防一笔交易瘫痪全网） =====================

    /// set_race_pools 传空池 → 此后每次建号都在 pick_race 的 vector::borrow 越界 abort。
    #[test]
    #[expected_failure(abort_code = 26, location = mohayo::character)]   // E_RACE_POOL_BAD
    fun test_set_race_pools_rejects_empty_pool() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        character::register_race(a, 0, types::make_race_def(0, vector[0, 0, 0], 0, 0, 0));
        character::set_race_pools(a, vector[0], vector[0], vector[]);
    }

    /// set_race_pools 传未注册的 race_id → 建号时 get_race 的 E_UNKNOWN_RACE。
    #[test]
    #[expected_failure(abort_code = 26, location = mohayo::character)]   // E_RACE_POOL_BAD
    fun test_set_race_pools_rejects_unregistered_race() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        character::register_race(a, 0, types::make_race_def(0, vector[0, 0, 0], 0, 0, 0));
        character::set_race_pools(a, vector[0], vector[0], vector[99]);
    }

    /// stat_type >= ABILITY_SLOTS(4) → compute_affixes 索引长度 4 的 bonuses 时越界。
    #[test]
    #[expected_failure(abort_code = 24, location = mohayo::character)]   // E_AFFIX_STAT_TYPE
    fun test_register_affix_rejects_bad_stat_type() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        let tmpl = types::make_affix_template(
            7,
            vector[500, 300, 200, 100, 50, 30, 20, 10, 5, 2],
            vector[50, 100, 200, 300, 400, 500, 600, 700, 800, 900],
        );
        character::register_affix_template(a, 0, tmpl);
    }

    /// tier_values 不足 10 档 → 玩家掷出高 tier 时 compute_affixes 越界 abort。
    #[test]
    #[expected_failure(abort_code = 25, location = mohayo::character)]   // E_AFFIX_TIERS
    fun test_register_affix_rejects_short_tier_values() {
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
    #[expected_failure(abort_code = 2, location = mohayo::economy)]
    fun test_economy_unauthorized_mint() {
        let a = &std::account::create_account_for_test(@mohayo);
        let attacker = &std::account::create_account_for_test(@0x999);
        setup(a);
        economy::set_minter(a, @mohayo, true);
        economy::mint(attacker, @0x100, 500);
    }

    #[test]
    #[expected_failure(abort_code = 3, location = mohayo::economy)]
    fun test_economy_unauthorized_spend() {
        let a = &std::account::create_account_for_test(@mohayo);
        let attacker = &std::account::create_account_for_test(@0x999);
        setup(a);
        economy::gm_mint(a, @0x100, 1000);
        economy::spend(attacker, @0x100, 300);
    }

    #[test]
    #[expected_failure(abort_code = 4, location = mohayo::economy)]
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
        let dungeon = types::make_dungeon_config(1, 3, 5, 0, 0, 0, 1);
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
        engine::start_combat_test(a, 1);
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
        engine::start_combat_test(a, 1);
        engine::set_plan(a, 1, 0, vector[1]);
        engine::step_for_test(a, 1);
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
        let dungeon = types::make_dungeon_config(1, 1, 10, 0, 0, 0, 1);
        skill_registry::set_dungeon(a, 1, dungeon);
        engine::create_room(a, 1);
        engine::join_room(a, 1, 500, 200, 50, 30);
        engine::start_combat_test(a, 1);
        let (hp1, _mh, _a, _m, _s, _alive) = engine::enemy_state(1, 0);
        assert!(hp1 == 1000, 1);
        engine::set_plan(a, 1, 0, vector[1]);
        engine::step_for_test(a, 1);
        let (hp2, _mh, _a, _m, _s, _alive) = engine::enemy_state(1, 0);
        assert!(hp2 < hp1, 2);
    }

    #[test]
    fun test_dot_ticks_damage() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        // skill id1 = 毒刃类: 低直伤 + DOT(mag40, dur3 → 3 跳 ×40)
        skill_registry::register_skill(a, types::make_skill(
            0, 1, 0, 1, 0, 0, 0, 0, 1, 0, 1, 30, 0, 1000, 0,
            vector[types::make_effect_spec(8, 3, 40, 1, 1000)],
            types::make_summon_rule(0, 0, 0)));
        // skill id2 = 待机(敌人用, 不打人)
        skill_registry::register_skill(a, types::make_skill(
            0, 3, 0, 0, 0, 0, 0, 0, 9, 0, 1, 0, 0, 1000, 0,
            vector::empty(), types::make_summon_rule(0, 0, 0)));
        skill_registry::register_ai(a, simple_ai(2));             // ai1 = 待机
        skill_registry::register_template(a, simple_template(1)); // 敌人 hp1000
        skill_registry::register_table(a, vector[types::make_table_entry(1, 1000)]);
        skill_registry::set_dungeon(a, 1, types::make_dungeon_config(1, 1, 10, 0, 0, 0, 1));
        engine::create_room(a, 1);
        engine::join_room(a, 1, 2000, 200, 100, 30);
        engine::start_combat_test(a, 1);
        engine::set_plan(a, 1, 0, vector[1]);
        engine::step_for_test(a, 1); // r1: 直伤 30×200/1000=6 → 994; DOT dur3 挂上
        let (h1, _, _, _, _, _) = engine::enemy_state(1, 0);
        assert!(h1 == 994, 1);
        engine::set_plan(a, 1, 0, vector[]); // 玩家空过 → 之后全靠 DOT 跳血
        engine::step_for_test(a, 1);          // r2 初: 跳 40 → 954; dur 3→2
        let (h2, _, _, _, _, _) = engine::enemy_state(1, 0);
        assert!(h2 == 954, 2);
        engine::step_for_test(a, 1); // r3: 跳 40 → 914; 2→1
        let (h3, _, _, _, _, _) = engine::enemy_state(1, 0);
        assert!(h3 == 914, 3);
        engine::step_for_test(a, 1); // r4: 跳 40 → 874; 1→0 移除
        let (h4, _, _, _, _, _) = engine::enemy_state(1, 0);
        assert!(h4 == 874, 4);
        engine::step_for_test(a, 1); // r5: 无 DOT → 血量不再变
        let (h5, _, _, _, _, _) = engine::enemy_state(1, 0);
        assert!(h5 == 874, 5);
    }

    #[test]
    fun test_guar_next_grants_hit() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        // skill1 = 鹰眼(自施, GUAR_NEXT op7 dur2) —— 走职业技注册(op7 仅职业技可配);
        // skill2 = 低命中攻击(acc300)
        skill_registry::register_class_skill(a, types::make_skill(
            0, 3, 0, 0, 0, 0, 0, 0, 9, 0, 1, 0, 0, 1000, 0,
            vector[types::make_effect_spec(7, 2, 1, 0, 1000)],
            types::make_summon_rule(0, 0, 0)), 5);
        skill_registry::register_skill(a, types::make_skill(
            0, 1, 0, 1, 0, 0, 0, 0, 1, 0, 1, 100, 0, 300, 0,
            vector::empty(), types::make_summon_rule(0, 0, 0)));
        skill_registry::register_ai(a, simple_ai(2));             // ai1 = 敌人低命中普攻(干扰项)
        skill_registry::register_template(a, simple_template(1)); // 敌人 hp1000
        skill_registry::register_table(a, vector[types::make_table_entry(1, 1000)]);
        skill_registry::set_dungeon(a, 1, types::make_dungeon_config(1, 1, 10, 0, 0, 0, 1));
        engine::create_room(a, 1);
        engine::join_room(a, 1, 2000, 200, 100, 30);
        engine::start_combat_test(a, 1);
        engine::set_plan(a, 1, 0, vector[1, 2]); // 鹰眼 → 攻击 循环
        engine::step_for_test(a, 1);              // r1: 鹰眼
        engine::step_for_test(a, 1);              // r2: 攻击(acc300) 因 GUAR_NEXT 必中 → 100×200/1000=20
        let (h1, _, _, _, _, _) = engine::enemy_state(1, 0);
        assert!(h1 == 980, 1); // 若 op7 未生效则大概率 1000(miss)
    }

    #[test]
    fun test_taunt_redirects_single_attack() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        // skill1 = 敌人单体攻击(必中); skill2 = 玩家自嘲(TAUNT op11 dur9)
        skill_registry::register_skill(a, types::make_skill(
            0, 1, 0, 0, 0, 0, 0, 0, 1, 0, 1, 100, 0, 1000, 0,
            vector::empty(), types::make_summon_rule(0, 0, 0)));
        skill_registry::register_skill(a, types::make_skill(
            0, 3, 0, 0, 0, 0, 0, 0, 9, 0, 1, 0, 0, 1000, 0,
            vector[types::make_effect_spec(11, 9, 1, 0, 1000)],
            types::make_summon_rule(0, 0, 0)));
        skill_registry::register_ai(a, simple_ai(1));             // ai1 = 敌人单体攻击
        skill_registry::register_template(a, simple_template(1)); // 敌人 hp1000 atk500 → 50/击
        skill_registry::register_table(a, vector[types::make_table_entry(1, 1000)]);
        skill_registry::set_dungeon(a, 1, types::make_dungeon_config(1, 1, 10, 0, 0, 0, 1));
        engine::create_room(a, 1);
        engine::join_room(a, 1, 2000, 10, 10, 30); // 成员0(非嘲讽者)
        engine::join_room(a, 1, 2000, 10, 10, 30); // 成员1(嘲讽者)
        engine::start_combat_test(a, 1);
        engine::set_plan(a, 1, 0, vector[]); // 成员0 空过
        engine::set_plan(a, 1, 1, vector[2]); // 成员1 每回合同步施放嘲讽
        let guard = 0;
        while (guard < 6) { engine::step_for_test(a, 1); guard = guard + 1; };
        let (h0, _, _, _, _, _) = engine::member_state(1, 0);
        let (h1, _, _, _, _, _) = engine::member_state(1, 1);
        assert!(h0 == 2000, 1); // 成员0 全程未被单体攻击打中
        assert!(h1 < 2000, 2);  // 成员1(嘲讽者)承受了全部单体火力
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
        let dungeon = types::make_dungeon_config(1, 1, 5, 0, 0, 0, 1);
        skill_registry::set_dungeon(a, 1, dungeon);
        engine::create_room(a, 1);
        engine::join_room(a, 1, 500, 200, 50, 30);
        engine::start_combat_test(a, 1);
        engine::set_plan(a, 1, 0, vector[2]);
        // First turn: enemy uses stun on member
        engine::step_for_test(a, 1);
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
        let dungeon = types::make_dungeon_config(1, 1, 10, 0, 0, 0, 1);
        skill_registry::set_dungeon(a, 1, dungeon);
        engine::create_room(a, 1);
        // Very high attack so uncapped would be > 100
        engine::join_room(a, 1, 500, 1000, 50, 30);
        engine::start_combat_test(a, 1);
        let (hp1, _mh, _a, _m, _s, _alive) = engine::enemy_state(1, 0);
        engine::set_plan(a, 1, 0, vector[1]);
        engine::step_for_test(a, 1);
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
        let dungeon = types::make_dungeon_config(1, 1, 10, 0, 0, 0, 1);
        skill_registry::set_dungeon(a, 1, dungeon);
        engine::create_room(a, 1);
        engine::join_room(a, 1, 10000, 100, 50, 30);
        engine::start_combat_test(a, 1);
        let (hp1, _mh, _a, _m, _s, _alive) = engine::enemy_state(1, 0);
        // Plan: self-buff then attack
        engine::set_plan(a, 1, 0, vector[2, 1]);
        engine::step_for_test(a, 1);
        // After buff: turn 1 = buff, turn 2 = attack with +200% damage
        engine::set_plan(a, 1, 0, vector[1]);
        engine::step_for_test(a, 1);
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
        let dungeon = types::make_dungeon_config(1, 1, 10, 0, 0, 0, 1);
        skill_registry::set_dungeon(a, 1, dungeon);
        engine::create_room(a, 1);
        engine::join_room(a, 1, 10000, 100, 50, 30);
        engine::start_combat_test(a, 1);
        let (hp1, _mh, _a, _m, _s, _alive) = engine::enemy_state(1, 0);
        // Plan: debuff enemy then attack
        engine::set_plan(a, 1, 0, vector[2, 1]);
        engine::step_for_test(a, 1);
        engine::set_plan(a, 1, 0, vector[1]);
        engine::step_for_test(a, 1);
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
        let dungeon = types::make_dungeon_config(1, 1, 10, 0, 0, 0, 1);
        skill_registry::set_dungeon(a, 1, dungeon);
        engine::create_room(a, 1);
        engine::join_room(a, 1, 500, 100, 50, 30);
        engine::start_combat_test(a, 1);
        // Plan: shield self, then attack
        engine::set_plan(a, 1, 0, vector[1, 2]);
        engine::step_for_test(a, 1);
        // Check member has shield effect
        let ec = engine::member_effect_count(1, 0);
        assert!(ec > 0, 1);
        // Advance to let enemy attack (should be absorbed by shield)
        engine::set_plan(a, 1, 0, vector[2]);
        engine::step_for_test(a, 1);
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
        let dungeon = types::make_dungeon_config(1, 1, 10, 0, 0, 0, 1);
        skill_registry::set_dungeon(a, 1, dungeon);
        engine::create_room(a, 1);
        engine::join_room(a, 1, 1000, 100, 50, 30);
        engine::start_combat_test(a, 1);
        let (hp_before, _mh, _a, _m, _s, _alive) = engine::member_state(1, 0);
        // Turn 1: sacrifice 200 HP → HP drops to 800
        engine::set_plan(a, 1, 0, vector[1]);
        engine::step_for_test(a, 1);
        let (hp_after_enemy, _mh, _a, _m, _s, _alive) = engine::member_state(1, 0);
        assert!(hp_after_enemy < hp_before, 3);
        // Turn 2: heal 600 HP → HP should increase
        engine::set_plan(a, 1, 0, vector[2]);
        engine::step_for_test(a, 1);
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
        let dungeon = types::make_dungeon_config(1, 1, 5, 0, 0, 0, 1);
        skill_registry::set_dungeon(a, 1, dungeon);
        engine::create_room(a, 1);
        engine::join_room(a, 1, 500, 100, 50, 30);
        engine::start_combat_test(a, 1);
        engine::set_plan(a, 1, 0, vector[1]);
        engine::step_for_test(a, 1);
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
        let dungeon = types::make_dungeon_config(1, 1, 5, 0, 0, 0, 1);
        skill_registry::set_dungeon(a, 1, dungeon);
        engine::create_room(a, 1);
        engine::join_room(a, 1, 10, 10, 10, 10);
        engine::start_combat_test(a, 1);
        // Member with 10 HP vs enemy with 99999 attack
        // Member attacks first (higher speed?), then enemy attacks and kills
        engine::set_plan(a, 1, 0, vector[1]);
        engine::step_for_test(a, 1);
        // Check if member is dead
        let (_hp, _mh, _a, _m, _s, alive) = engine::member_state(1, 0);
        // Either member survived turn 1 or is dead
        // Let's advance more turns
        if (alive == 1) {
            engine::set_plan(a, 1, 0, vector[1]);
            engine::step_for_test(a, 1);
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
        let dungeon = types::make_dungeon_config(1, 1, 5, 0, 0, 0, 2);
        skill_registry::set_dungeon(a, 1, dungeon);
        engine::create_room(a, 1);
        engine::join_room(a, 1, 500, 100, 50, 30);
        engine::start_combat_test(a, 1);
        // Battle 1: kill weak enemy
        engine::set_plan(a, 1, 0, vector[1]);
        engine::step_for_test(a, 1);
        // Should be in intermission (phase 3)
        assert!(engine::room_phase(1) == 3, 1);
        // Advance to battle 2
        engine::advance_battle_test(a, 1);
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
        let dungeon = types::make_dungeon_config(1, 1, 5, 0, 0, 0, 1);
        skill_registry::set_dungeon(a, 1, dungeon);
        engine::create_room(a, 1);
        engine::join_room(a, 1, 500, 100, 50, 30);
        engine::start_combat_test(a, 1);
        // Turn 1: mana = 5 (from mana_per_turn), costs 3, should work
        let mana1 = engine::room_mana(1);
        assert!(mana1 == 5, 1);
        engine::set_plan(a, 1, 0, vector[1]);
        engine::step_for_test(a, 1);
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
        let dungeon = types::make_dungeon_config(1, 1, 10, 0, 0, 0, 1);
        skill_registry::set_dungeon(a, 1, dungeon);
        engine::create_room(a, 1);
        engine::join_room(a, 1, 10000, 100, 50, 30);
        engine::start_combat_test(a, 1);
        // AI picks a skill uniformly at random each turn. With a [attack, stun] cycle the
        // enemy must use stun (the only effect-producer) at least once across a 10-turn
        // window (P(never) = 1/2^10), proving selection is randomized, not fixed-order.
        engine::set_plan(a, 1, 0, vector[1]);
        let saw_stun = false;
        let hi = 0;
        while (hi < 10) {
            engine::step_for_test(a, 1);
            if (!saw_stun && engine::member_effect_count(1, 0) > 0) {
                saw_stun = true;
            };
            hi = hi + 1;
        };
        assert!(saw_stun, 1);
    }

    #[test]
    fun test_cancel_plan() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        setup_full_dungeon(a);
        engine::create_room(a, 1);
        engine::join_room(a, 1, 500, 100, 50, 30);
        engine::start_combat_test(a, 1);
        engine::set_plan(a, 1, 0, vector[1, 1, 1]);
        engine::cancel_plan(a, 1, 0);
        // After cancel, member has no plan so does nothing
        let (hp_before, _mh, _a, _m, _s, _alive) = engine::enemy_state(1, 0);
        engine::step_for_test(a, 1);
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
        let dungeon = types::make_dungeon_config(1, 1, 5, 0, 0, 0, 1);
        skill_registry::set_dungeon(a, 1, dungeon);
        engine::create_room(a, 1);
        engine::join_room(a, 1, 500, 100, 50, 30);
        engine::start_combat_test(a, 1);
        engine::set_plan(a, 1, 0, vector[1]);
        engine::step_for_test(a, 1);
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
        let dungeon = types::make_dungeon_config(1, 1, 5, 0, 0, 0, 1);
        skill_registry::set_dungeon(a, 1, dungeon);

        // Create room, join, fight
        engine::create_room(a, 1);
        engine::join_room(a, 1, 1000, 200, 100, 30);
        engine::start_combat_test(a, 1);

        // Run 10 turns of combat
        let turn = 0;
        while (turn < 10) {
            let phase = engine::room_phase(1);
            if (phase != 1) break;
            engine::set_plan(a, 1, 0, vector[1]);
            engine::step_for_test(a, 1);
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
        let dungeon = types::make_dungeon_config(1, 1, 5, 0, 0, 0, 1);
        skill_registry::set_dungeon(a, 1, dungeon);

        engine::create_room(a, 1);
        engine::join_room(a, 1, 500, 100, 50, 30);
        engine::join_room(a, 1, 400, 150, 80, 25);
        engine::start_combat_test(a, 1);
        assert!(engine::member_count(1) == 2, 1);
        // Both members attack
        engine::set_plan(a, 1, 0, vector[1]);
        engine::set_plan(a, 1, 1, vector[1]);
        engine::step_for_test(a, 1);
        // Both should have dealt damage
        let (hp1, _, _, _, _, _) = engine::enemy_state(1, 0);
        assert!(hp1 < 1000, 2);
    }

    // ===================== content_registration integration tests =====================
    // These load the full production content via register_all_content and verify the
    // wired templates/tables/dungeons actually run in the engine.

    #[test]
    fun test_content_d1_stones_do_not_attack() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        // D1 = free mining; all stones are idle (AI 1), they must never hurt the player.
        engine::create_room(a, 1);
        engine::join_room(a, 1, 5000, 200, 100, 30);
        engine::start_combat_test(a, 1);
        let (hp0, max_hp, _atk, _mag, _spd, _alive) = engine::member_state(1, 0);
        assert!(hp0 == max_hp, 1);
        // No plan: player idles too. Advance a few turns below the D1 turn budget (8).
        let i = 0;
        while (i < 5) {
            engine::step_for_test(a, 1);
            i = i + 1;
        };
        let (hp1, _mh, _a, _m, _s, _alive) = engine::member_state(1, 0);
        // Player HP untouched === stones never strike.
        assert!(hp1 == max_hp, 2);
    }

    #[test]
    fun test_content_registry_wiring() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        // --- skills ---
        assert!(skill_registry::skill_registered(810), 1);   // 尘幕(自选池 key 810; 基础技已删除)
        assert!(skill_registry::skill_registered(190), 2);  // 待机(基础区 key 190)
        assert!(skill_registry::skill_registered(1655), 3); // 皇帝召唤(D9 区 key 1655)
        // --- dungeon 9 has 4 battles, battle-4 has the 70/30 variant ---
        let bi_count = skill_registry::get_battle_count(9);
        assert!(bi_count == 4, 4);
        let variants = skill_registry::get_variants(9, 4);
        assert!(vector::length(&variants) == 2, 5);
        // --- furnace(30) on-death-spawn == Emperor(34) @60% ---
        let furnace = skill_registry::get_template(30);
        let ods = types::template_on_death_spawn(&furnace);
        assert!(types::on_death_spawn_template_id(ods) == 34, 6);
        assert!(types::on_death_spawn_prob(ods) == 600, 7);
        // --- D5 overseer(17) exists and battle-3 carries the 80/20 variant set ---
        let overseer = skill_registry::get_template(17);
        assert!(types::template_ai_id(&overseer) == 13, 8);
        // §2.6.11: 必须是 2 条(基准表 16 + 混沌表 17) —— 只登记 1 条会让混沌变体变成 100%
        assert!(vector::length(&skill_registry::get_variants(5, 3)) == 2, 9);
    }

    #[test]
    fun test_content_d9_spawns_enemies() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        // D9 卫兵走廊: create at difficulty 9, battle 1 spawns from table 28 (4 mech guards).
        // Room id is auto-incremented (1 for the first room), independent of difficulty.
        engine::create_room(a, 9);
        engine::join_room(a, 1, 90000, 3000, 3000, 2000);
        engine::start_combat_test(a, 1);
        assert!(engine::room_phase(1) == 1, 1);
        assert!(engine::enemy_count(1) == 4, 2);
    }

    #[test]
    fun test_content_d5_spawns_enemies() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        // D5 battle 1: 3 地狱猎犬. Room id = 1 (first auto-incremented id).
        engine::create_room(a, 5);
        engine::join_room(a, 1, 50000, 1500, 1200, 1000);
        engine::start_combat_test(a, 1);
        assert!(engine::room_phase(1) == 1, 1);
        assert!(engine::enemy_count(1) == 3, 2);
    }

    #[test]
    fun test_content_d1_miner_clears_first_battle() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        // A low-fitted miner should clear D1 battle 1 (two 碎石, 80 HP each) inside the
        // 8-turn budget and pocket the reward at intermission. (The true weakest-player
        // guarantee is fine-tuned later by the Phase-5 sim harness.)
        engine::create_room(a, 1);
        engine::join_room(a, 1, 4000, 400, 400, 30);
        engine::start_combat_test(a, 1);
        assert!(engine::enemy_count(1) == 2, 1);
        engine::set_plan(a, 1, 0, vector[820]);
        let guard = 0;
        while (guard < 30 && engine::room_phase(1) == 1) {
            engine::step_for_test(a, 1);
            guard = guard + 1;
        };
        // Miner must reach intermission (3), not be evicted by timeout (2).
        assert!(engine::room_phase(1) == 3, 2);
        // Reward accumulated from killing both stones.
        assert!(engine::reward_pool(1) > 0, 3);
    }

    // ===================== P0: 经济闭环（入场费/救援费/收益发放） =====================

    #[test]
    fun test_economy_negative_balance_and_debt_repayment() {
        let a = &std::account::create_account_for_test(@mohayo);
        economy::init_for_test(a);
        economy::gm_charge_rescue(a, @0xD001, 50);
        assert!(economy::balance_of(@0xD001) == -50, 1);   // 救援费允许负余额
        assert!(economy::is_debtor(@0xD001), 2);
        economy::gm_charge_rescue(a, @0xD001, 30);         // 负余额无上限
        assert!(economy::balance_of(@0xD001) == -80, 3);
        economy::gm_credit(a, @0xD001, 30);                // 收益先自动偿债
        assert!(economy::balance_of(@0xD001) == -50, 4);
        economy::gm_credit(a, @0xD001, 90);
        assert!(economy::balance_of(@0xD001) == 40, 5);    // 还清后才形成可支配余额
        assert!(!economy::is_debtor(@0xD001), 6);
    }

    #[test]
    fun test_entry_fee_charged_on_create_room() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        let p = &std::account::create_account_for_test(@0xAA11);
        let paddr = std::signer::address_of(p);
        economy::gm_mint(a, paddr, 100);
        engine::create_room(p, 2);                          // D2 入场费 5
        assert!(economy::balance_of(paddr) == 95, 1);
        engine::create_room(p, 1);                          // D1 免费
        assert!(economy::balance_of(paddr) == 95, 2);
    }

    #[test]
    #[expected_failure(abort_code = 4, location = mohayo::economy)]
    fun test_entry_fee_insufficient_rejected() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        let p = &std::account::create_account_for_test(@0xAA12);
        economy::gm_mint(a, std::signer::address_of(p), 4);  // < D2 入场费 5
        engine::create_room(p, 2);
    }

    #[test]
    fun test_victory_reward_credited_to_survivor() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        let addr = std::signer::address_of(a);
        let before = economy::balance_of(addr);
        engine::create_room(a, 1);
        engine::join_room(a, 1, 4000, 100000, 100, 100);
        engine::start_combat_test(a, 1);
        engine::set_plan(a, 1, 0, vector[820]);
        run_room(a, 1);
        assert!(engine::room_result(1) == 1, 1);      // 通关 D1 全部四场
        assert!(engine::reward_pool(1) == 0, 2);      // 奖池已一次性发放
        assert!(economy::balance_of(addr) > before, 3);
    }

    #[test]
    fun test_rescue_fee_defeat_drives_negative_balance() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        let addr = std::signer::address_of(a);
        engine::create_room(a, 2);                          // D2 入场费 5
        let after_entry = economy::balance_of(addr);
        assert!(after_entry == 1000000000 - 5, 1);
        engine::join_room(a, 1, 1, 1, 1, 1);                // 1 HP 玻璃人
        engine::start_combat_test(a, 1);
        engine::set_plan(a, 1, 0, vector[820]);
        run_room(a, 1);
        assert!(engine::room_result(1) == 2, 2);            // 败北 / 超时
        assert!(economy::balance_of(addr) == after_entry - 15, 3); // 救援费 15
        assert!(economy::balance_of(addr) == 1000000000 - 20, 4);
    }

    // ===================== P0: 逃离与队长继承（§6.2 / §3.2） =====================

    #[test]
    #[expected_failure(abort_code = 21, location = mohayo::engine)]
    fun test_escape_rejected_in_lobby() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        engine::create_room(a, 1);
        engine::join_room(a, 1, 4000, 100, 100, 100);
        engine::request_escape(a, 1, 0);                    // 未开战 → E_CANNOT_ESCAPE
    }

    #[test]
    fun test_escape_in_combat_delayed_then_exempt_from_rescue() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        let addr = std::signer::address_of(a);
        engine::create_room(a, 2);
        let after_entry = economy::balance_of(addr);
        engine::join_room(a, 1, 100000, 1, 1, 1);           // 肉盾: 保证活到逃离完成
        engine::start_combat_test(a, 1);
        engine::set_plan(a, 1, 0, vector[820]);
        engine::request_escape(a, 1, 0);
        assert!(engine::member_escape_delay(1, 0) == 3, 1);
        engine::step_for_test(a, 1);
        assert!(engine::member_escape_delay(1, 0) == 2, 2);
        engine::step_for_test(a, 1);
        assert!(engine::member_escape_delay(1, 0) == 1, 3);
        engine::step_for_test(a, 1);
        assert!(engine::member_escaped(1, 0), 4);           // 三回合后离场
        assert!(engine::room_result(1) == 2, 5);            // 无人留守 → 关卡结束
        assert!(economy::balance_of(addr) == after_entry, 6); // 逃离者免救援费(§6.2)
    }

    #[test]
    fun test_lobby_leave_removes_member_and_succeeds_leader() {
        let a = &std::account::create_account_for_test(@mohayo);
        let b = &std::account::create_account_for_test(@0xBB10);
        setup(a);
        content_registration::register_all_content(a);
        engine::create_room(a, 1);
        engine::join_room(a, 1, 4000, 100, 100, 100);
        engine::join_room(b, 1, 4000, 100, 100, 100);
        assert!(engine::member_count(1) == 2, 1);
        engine::leave_room(a, 1);
        assert!(engine::member_count(1) == 1, 2);
        assert!(engine::room_leader(1) == std::signer::address_of(b), 3);
    }

    #[test]
    fun test_intermission_escape_immediate_and_leader_succeeds() {
        let a = &std::account::create_account_for_test(@mohayo);
        let b = &std::account::create_account_for_test(@0xBB11);
        setup(a);
        content_registration::register_all_content(a);
        engine::create_room(a, 1);
        engine::join_room(a, 1, 4000, 100000, 100, 100);
        engine::join_room(b, 1, 4000, 100000, 100, 100);
        engine::start_combat_test(a, 1);
        engine::set_plan(a, 1, 0, vector[820]);
        engine::set_plan(b, 1, 1, vector[820]);
        let guard = 0;
        while (guard < 40 && engine::room_phase(1) == 1) {
            engine::step_for_test(a, 1);
            guard = guard + 1;
        };
        assert!(engine::room_phase(1) == 3, 1);
        assert!(engine::room_leader(1) == std::signer::address_of(a), 2);
        engine::request_escape(a, 1, 0);                    // 间歇期 → 立即离场
        assert!(engine::member_escaped(1, 0), 3);
        assert!(engine::room_leader(1) == std::signer::address_of(b), 4); // 自动继任
        engine::advance_battle_test(b, 1);                       // 新队长可推进下一场
        assert!(engine::room_phase(1) == 1, 5);
    }

    #[test]
    fun test_leader_succession_on_death() {
        let a = &std::account::create_account_for_test(@mohayo);
        let b = &std::account::create_account_for_test(@0xBB12);
        setup(a);
        content_registration::register_all_content(a);
        engine::create_room(a, 2);
        engine::join_room(a, 1, 1, 1, 1, 1);                // 队长: 1 HP
        engine::join_room(b, 1, 100000, 1, 1, 1);           // 肉盾(后加入)
        engine::start_combat_test(a, 1);
        engine::set_plan(a, 1, 0, vector[820]);
        engine::set_plan(b, 1, 1, vector[820]);
        let aaddr = std::signer::address_of(a);
        assert!(engine::room_leader(1) == aaddr, 1);
        let guard = 0;
        while (guard < 80 && engine::room_phase(1) == 1 && engine::room_leader(1) == aaddr) {
            engine::step_for_test(a, 1);
            guard = guard + 1;
        };
        assert!(engine::room_leader(1) == std::signer::address_of(b), 2); // 队长阵亡 → 继任
    }

    #[test]
    fun test_leader_retreat_shares_reward() {
        let a = &std::account::create_account_for_test(@mohayo);
        let b = &std::account::create_account_for_test(@0xBB13);
        setup(a);
        content_registration::register_all_content(a);
        let aaddr = std::signer::address_of(a);
        let baddr = std::signer::address_of(b);
        engine::create_room(a, 1);
        engine::join_room(a, 1, 4000, 100000, 100, 100);
        engine::join_room(b, 1, 4000, 100000, 100, 100);
        engine::start_combat_test(a, 1);
        engine::set_plan(a, 1, 0, vector[820]);
        engine::set_plan(b, 1, 1, vector[820]);
        let guard = 0;
        while (guard < 40 && engine::room_phase(1) == 1) {
            engine::step_for_test(a, 1);
            guard = guard + 1;
        };
        assert!(engine::room_phase(1) == 3, 1);
        let pool = engine::reward_pool(1);
        assert!(pool > 0, 2);
        let ba = economy::balance_of(aaddr);
        let bb = economy::balance_of(baddr);
        engine::leader_retreat(a, 1);                       // 队长全员逃离(§6.1)
        assert!(engine::room_phase(1) == 2, 3);
        assert!(engine::room_result(1) == engine::RESULT_RETREAT(), 4);  // §2.6.14: 逃离 ≠ 通关
        assert!(engine::reward_pool(1) == 0, 5);
        let da = economy::balance_of(aaddr) - ba;
        let db = economy::balance_of(baddr) - bb;
        assert!(da + db == (pool as i128), 6);              // 账目守恒
        assert!(da > 0 && db > 0, 7);                       // 存活者都分到
    }

    /// §2.6.14: 打到一半全员逃离**不计通关** —— 履历只记 runs=1, clears 与 best 保持 0。
    #[test]
    fun test_retreat_does_not_count_as_clear() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        let addr = std::signer::address_of(a);
        character::gm_mint_at_level(a, addr, 2, 0, vector[0, 0, 0, 0], vector[820], 300);
        let cid = character::owner_latest_char(addr);
        engine::create_room(a, 1);
        engine::join_room_as_char(a, 1, cid);
        engine::start_combat_test(a, 1);
        engine::set_plan(a, 1, 0, vector[820]);
        let guard = 0;
        while (guard < 200 && engine::room_phase(1) == 1) {
            engine::step_for_test(a, 1);
            guard = guard + 1;
        };
        assert!(engine::room_phase(1) == 3, 1);                 // 第一场打完, 进间歇期
        engine::leader_retreat(a, 1);
        assert!(engine::room_result(1) == engine::RESULT_RETREAT(), 2);
        let (runs, clears, best) = character::get_history(cid);
        assert!(runs == 1 && clears == 0 && best == 0, 3);
    }

    #[test]
    #[expected_failure(abort_code = 6, location = mohayo::engine)]
    fun test_retreat_rejected_for_non_leader() {
        let a = &std::account::create_account_for_test(@mohayo);
        let b = &std::account::create_account_for_test(@0xBB14);
        setup(a);
        content_registration::register_all_content(a);
        engine::create_room(a, 1);
        engine::join_room(a, 1, 4000, 100000, 100, 100);
        engine::join_room(b, 1, 4000, 100000, 100, 100);
        engine::start_combat_test(a, 1);
        engine::set_plan(a, 1, 0, vector[820]);
        engine::set_plan(b, 1, 1, vector[820]);
        let guard = 0;
        while (guard < 40 && engine::room_phase(1) == 1) {
            engine::step_for_test(a, 1);
            guard = guard + 1;
        };
        assert!(engine::room_phase(1) == 3, 1);
        engine::leader_retreat(b, 1);                       // 非队长 → E_NOT_LEADER
    }

    /// 推进一步(测试/仿真用): 先过 ≥2 秒推进冷却, 再以**当前 turn_id** 作为期望值调用
    /// —— 同时覆盖 §4.1 的自动/手动同入口与 §3.1 的「turnId 单调 + 冷却」两道防重。
    /// 初始化 aptos_framework 时间戳(入场次数门控读 timestamp::now_seconds)
    // 房间跑到底: 战斗 → 间歇 → 下一战 … 直到结算
    fun run_room(a: &signer, room_id: u64) {
        let guard = 0;
        while (guard < 400) {
            let ph = engine::room_phase(room_id);
            if (ph == 1) { engine::step_for_test(a, room_id); }
            else if (ph == 3) { engine::advance_battle_test(a, room_id); }
            else { break; };
            guard = guard + 1;
        };
    }

    // ===================== P1: 敏捷行动顺序与逐段随机目标（§4.2） =====================

    #[test]
    fun test_agility_order_decides_who_acts_first() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        // 覆写 D2 战斗 1 为单只残破机仆(110hp, spd 90)
        skill_registry::set_dungeon(a, 2, types::make_dungeon_config(5, 1, 10, 0, 0, 120, 1));
        skill_registry::set_dungeon_battles(a, 2, vector[types::make_battle_config(5, 1)]);
        // ① 高速(spd 1000)先手秒杀 → 全程零受击
        engine::create_room(a, 2);
        engine::join_room(a, 1, 100, 1000, 100, 1000);
        engine::start_combat_test(a, 1);
        engine::set_plan(a, 1, 0, vector[820]);
        engine::step_for_test(a, 1);
        assert!(engine::room_result(1) == 1, 1);
        let (fhp, _, _, _, _, _) = engine::member_state(1, 0);
        assert!(fhp == 100, 2);
        // ② 低速(spd 1): 机仆(spd 90)先动 → 必然吃到攻击
        engine::create_room(a, 2);
        engine::join_room(a, 2, 1000000, 10, 10, 1);
        engine::start_combat_test(a, 2);
        // 不排计划(空过): 只观察「谁先动手」——低速者必经敌人的行动
        let guard = 0;
        while (guard < 30 && engine::room_phase(2) == 1) {
            engine::step_for_test(a, 2);
            guard = guard + 1;
        };
        let (shp, _, _, _, _, _) = engine::member_state(2, 0);
        assert!(shp < 1000000, 3);
    }

    #[test]
    fun test_multi_strike_redraws_random_targets() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        // 暴风剑(840) = 4 段连击。若四段锁死同一目标, 一回合内只会有 1 只敌人掉血;
        // 逐段独立抽目标(§4.2)才会出现「分摊到 ≥2 只敌人」。
        let any_split = false;
        let s = 0;
        while (s < 10) {
            let rid = s + 1;
            engine::create_room(a, 5);                              // D5 b1 = 机神哨兵 ×3 (1100hp)
            engine::join_room_affixed(a, rid, 1000000, 100, 100, 200, 5, 3, 0, 0);
            engine::start_combat_test(a, rid);
            engine::set_plan(a, rid, 0, vector[840]);
            engine::step_for_test(a, rid);
            let hits = 0;
            let e = 0;
            while (e < 3) {
                let (hp, max_hp, _, _, _, _) = engine::enemy_state(rid, e);
                if (hp < max_hp) { hits = hits + 1; };
                e = e + 1;
            };
            if (hits >= 2) { any_split = true; };
            s = s + 1;
        };
        assert!(any_split, 1);
    }

    // ===================== P1b: 入场次数门控与掉落 =====================

    /// §2.6.14 用户定案: **开房计为一次加入, 加入也计一次** —— 同一账号 24h 内
    /// 「开房 + 加入」的总次数受限。房间必须有人加入才能开战, 所以创建泛滥最终也被加入封顶。
    /// 下面用 4 个角色把「开房 + 加入」跑满 3 个名额, 第 4 次加入被拒。
    #[test]
    #[expected_failure(abort_code = 3, location = mohayo::use_item)]   // E_NO_ENTRIES
    fun test_window_limit_counts_joins_and_creates() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        use_item::set_window_limit(a, 3);
        let p = &std::account::create_account_for_test(@0xCC01);
        let i = 0;
        while (i < 4) {
            character::create_character_test(p, 1, vector::empty(), (i + 1) * 7);
            i = i + 1;
        };
        // 房 1: 开房计 1, 队员加入再计 1
        engine::create_room(p, 1);
        engine::join_room_as_char(p, 1, character::owner_latest_char(std::signer::address_of(p)) - 3);
        assert!(use_item::entries_left(std::signer::address_of(p)) == 1, 1);
        // 房 2: 加入第 3 次 → 名额用满
        engine::create_room(p, 1);
        engine::join_room_as_char(p, 1, character::owner_latest_char(std::signer::address_of(p)) - 2);
        assert!(use_item::entries_left(std::signer::address_of(p)) == 0, 2);
        // 名额已满: 房 3 的开房(第 4 次参与)本身就会被拒
        engine::create_room(p, 1);
        engine::join_room_as_char(p, 1, character::owner_latest_char(std::signer::address_of(p)) - 1);
    }

    /// 窗口是**滑动**的: 24 小时前的记录过期, 名额随之释放。
    #[test]
    fun test_window_limit_slides() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        use_item::set_window_limit(a, 2);
        let p = &std::account::create_account_for_test(@0xCC03);
        let paddr = std::signer::address_of(p);
        let i = 0;
        while (i < 3) {
            character::create_character_test(p, 1, vector::empty(), (i + 1) * 11);
            i = i + 1;
        };
        let c1 = character::owner_latest_char(paddr) - 2;
        let c2 = character::owner_latest_char(paddr) - 1;
        let c3 = character::owner_latest_char(paddr);
        let t0 = aptos_framework::timestamp::now_seconds();
        engine::create_room(p, 1);
        engine::join_room_as_char(p, 1, c1);
        assert!(use_item::entries_left(paddr) == 0, 1);       // 2/2 用满
        aptos_framework::timestamp::update_global_time_for_test_secs(t0 + 12 * 3600);
        assert!(use_item::entries_left(paddr) == 0, 2);       // 12h: 还没滑出
        aptos_framework::timestamp::update_global_time_for_test_secs(t0 + 25 * 3600);
        assert!(use_item::entries_left(paddr) == 2, 3);       // 25h: 两条都已滑出窗口(名额全额释放)
        engine::create_room(p, 1);
        engine::join_room_as_char(p, 1, c2);
        assert!(use_item::entries_left(paddr) == 0, 4);
        aptos_framework::timestamp::update_global_time_for_test_secs(t0 + 49 * 3600);
        assert!(use_item::entries_left(paddr) == 2, 5);       // 两条都滑出
        engine::create_room(p, 1);
        engine::join_room_as_char(p, 1, c3);
        assert!(use_item::entries_left(paddr) == 0, 6);       // 2/2 用满
    }

    /// GM 不能把窗口上限调到离谱的值（每账号要按上限存时间戳）。
    #[test]
    #[expected_failure(abort_code = 4, location = mohayo::use_item)]                       // E_LIMIT_TOO_BIG
    fun test_window_limit_capped() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        use_item::set_window_limit(a, 100000);
    }

    #[test]
    fun test_drop_table_grants_item_on_victory() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        let addr = std::signer::address_of(a);
        // 覆写 D1 掉落表: 必掉 1 份魔素礼花(消除随机性以便断言)
        item::register_drop_table(a, 1,
            vector[item::ITEM_MANA_FIREWORK], vector[1000], vector[1]);
        let before = item::balance_whole(item::ITEM_MANA_FIREWORK, addr);
        engine::create_room(a, 1);
        engine::join_room(a, 1, 4000, 100000, 100, 100);
        engine::start_combat_test(a, 1);
        engine::set_plan(a, 1, 0, vector[820]);
        run_room(a, 1);
        assert!(engine::room_result(1) == 1, 1);
        // 存活者(仅一人)通关时掷一次掉落 → +1
        assert!(item::balance_whole(item::ITEM_MANA_FIREWORK, addr) == before + 1, 2);
    }

    // ===================== P2: 加权目标 / 池技语义 / 双修公式 =====================

    /// 急救包扎(850) = 随机我方 + 按生命亏空加权(§4.2): 残血者更可能被抽中, 满血者也可能。
    #[test]
    fun test_heal_weighting_favors_wounded() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        let split = 0;
        let s = 0;
        while (s < 5) {
            let rid = s + 1;
            engine::create_room(a, 1);                                    // D1 待机怪, 不会打断
            engine::join_room(a, rid, 5000, 10, 1000, 100);               // 成员0(重伤)
            engine::join_room(a, rid, 5000, 10, 1000, 100);               // 成员1(轻伤)
            engine::start_combat_test(a, rid);
            engine::test_set_member_hp(a, rid, 0, 1000);                  // 亏空 4000
            engine::test_set_member_hp(a, rid, 1, 4999);                  // 亏空 1
            engine::set_plan(a, rid, 0, vector[850]);
            engine::set_plan(a, rid, 1, vector[850]);
            engine::step_for_test(a, rid);
            let (h0, _, _, _, _, _) = engine::member_state(rid, 0);
            if (h0 > 1000) { split = split + 1; };                        // 第一口奶给了重伤者
            s = s + 1;
        };
        assert!(split == 5, 1); // 权重 4001 : 2 → 五个房间全部先奶重伤者
    }

    /// 致盲粉(860) = 双刃: 单体随机敌人 + 自降命中(SCOPE_SELF)。
    #[test]
    fun test_blinding_powder_debuffs_self_and_enemy() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        engine::create_room(a, 1);
        engine::join_room_affixed(a, 1, 50000, 10, 10, 100, 3, 0, 0, 0); // 魔素-3 → 致盲粉 0 费
        engine::start_combat_test(a, 1);
        engine::set_plan(a, 1, 0, vector[860]);
        engine::step_for_test(a, 1);
        assert!(engine::member_effect_count(1, 0) > 0, 1);              // 自己吃到 ACC_DOWN
        let e0 = engine::enemy_effect_count(1, 0);
        let e1 = engine::enemy_effect_count(1, 1);
        assert!(e0 + e1 == 1, 2);                                       // 恰好一只敌人被压制
    }

    /// 岩石壁垒(870) = 自施小额固定盾; 魔力护盾(880) = 自施、盾量 power×魔攻。
    #[test]
    fun test_bulwark_and_magic_shield_are_self_only() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        engine::create_room(a, 1);
        engine::join_room_affixed(a, 1, 50000, 10, 500, 100, 5, 2, 0, 0); // 5 费 → 0
        engine::join_room(a, 1, 50000, 10, 500, 100);
        engine::start_combat_test(a, 1);
        engine::set_plan(a, 1, 0, vector[870, 880, 870, 880]);
        engine::step_for_test(a, 1);                                    // 岩石壁垒
        assert!(engine::member_effect_count(1, 0) == 1, 1);            // 只有自己
        assert!(engine::member_effect_count(1, 1) == 0, 2);
        let (op, dur, mag) = engine::member_effect(1, 0, 0);
        assert!(op == 4 && dur == 3 && mag == 500, 3);                 // 固定小额
        engine::step_for_test(a, 1);                                    // 魔力护盾
        let (op2, _d2, mag2) = engine::member_effect(1, 0, 1);
        assert!(op2 == 4, 4);
        assert!(mag2 == ((900 * 500 / 1000) as u16), 5);               // power × 魔攻
        assert!(engine::member_effect_count(1, 1) == 0, 6);            // 仍不波及队友
    }

    /// 敌人威胁权重(§4.2): 高威胁目标更容易被单体攻击抽中, 但小怪也可能吃刀。
    #[test]
    fun test_threat_weight_favors_high_threat_enemy() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        // 自建表: 高威胁(threat 9) vs 低威胁(threat 0), 都打不死
        skill_registry::register_template(a, types::make_enemy_template(1, 9, 100000, 0, 0, 10, 0, 0, 0,
            types::make_on_death_spawn(0, 0, 0)));
        skill_registry::register_template(a, types::make_enemy_template(1, 0, 100000, 0, 0, 10, 0, 0, 0,
            types::make_on_death_spawn(0, 0, 0)));
        skill_registry::register_table(a, vector[
            types::make_table_entry(36, 1000), types::make_table_entry(37, 1000)]); // 表 32
        skill_registry::set_dungeon(a, 2, types::make_dungeon_config(32, 2, 20, 0, 0, 120, 1));
        skill_registry::set_dungeon_battles(a, 2, vector[types::make_battle_config(32, 2)]);
        let boss_hits = 0;
        let s = 0;
        while (s < 10) {
            let rid = s + 1;
            engine::create_room(a, 2);
            engine::join_room(a, rid, 50000, 10, 10, 100);
            engine::start_combat_test(a, rid);
            engine::set_plan(a, rid, 0, vector[820]);                  // 单体毒刃(WT_THREAT_ENEMY)
            engine::step_for_test(a, rid);
            // 按模板 id 判定谁挨打(索引顺序由实例化掷骰决定): 模板 36 = 高威胁
            let e = 0;
            while (e < 2) {
                if (engine::enemy_template(rid, e) == 36) {
                    let (hp, _, _, _, _, _) = engine::enemy_state(rid, e);
                    if (hp < 100000) { boss_hits = boss_hits + 1; };
                };
                e = e + 1;
            };
            s = s + 1;
        };
        assert!(boss_hits >= 6, 1); // 权重 10:1 → 十个种子里高威胁目标至少被抽中 6 次
    }

    // ===================== Q1: 升级 / 角色转移 / 履历（§2.4 / §7.4） =====================

    #[test]
    fun test_upgrade_level_charges_char() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        let addr = std::signer::address_of(a);
        character::gm_mint(a, addr, 1, 0, vector[0, 0, 0, 0], vector[850]);
        let cid = character::owner_latest_char(addr);
        assert!(character::get_level(cid) == 1, 1);
        let before = economy::balance_of(addr);
        // 1 → 10 级: 费用 = Σ(100 × 新等级) = 100×(2+10)×9/2 = 5400
        character::upgrade_level(a, cid, 9);
        assert!(character::get_level(cid) == 10, 2);
        assert!(economy::balance_of(addr) == before - 5400, 3);
    }

    #[test]
    #[expected_failure(abort_code = 4, location = mohayo::economy)]
    fun test_upgrade_level_rejected_when_broke() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        let p = &std::account::create_account_for_test(@0xDD01);   // 身无分文
        let paddr = std::signer::address_of(p);
        character::gm_mint(a, paddr, 1, 0, vector[0, 0, 0, 0], vector[850]);
        let cid = character::owner_latest_char(paddr);
        character::upgrade_level(p, cid, 1);                       // E_INSUFFICIENT_BALANCE(4)
    }

    #[test]
    #[expected_failure(abort_code = 11, location = mohayo::character)]
    fun test_upgrade_level_capped() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        let addr = std::signer::address_of(a);
        character::gm_mint(a, addr, 1, 0, vector[0, 0, 0, 0], vector[850]);
        let cid = character::owner_latest_char(addr);
        character::upgrade_level(a, cid, 300);                     // 超过 MAX_LEVEL → E_MAX_LEVEL(11)
    }

    #[test]
    fun test_transfer_resets_level_keeps_identity() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        let addr = std::signer::address_of(a);
        let buyer = &std::account::create_account_for_test(@0xDD02);
        let baddr = std::signer::address_of(buyer);
        character::gm_mint_at_level(a, addr, 2, 4, vector[0, 0, 0, 0], vector[850, 860], 300);
        let cid = character::owner_latest_char(addr);
        assert!(character::get_level(cid) == 300, 1);
        let (_c0, race_before, _l0, _h0, _mh0, _at0, _mg0, _sp0, _sk0, _r0) = character::get_character(cid);
        character::transfer_character(a, cid, baddr);
        // ① 等级重置为 1; ② 所有权变更; ③ 种族/词条/自选技随角色走
        assert!(character::get_level(cid) == 1, 2);
        assert!(character::char_owner(cid) == baddr, 3);
        let (_c2, race_after, _l2, _h2, _mh2, _at2, _mg2, _sp2, skills2, _r2) = character::get_character(cid);
        assert!(race_after == race_before, 4);
        assert!(vector::length(&skills2) == vector::length(&character::get_skill_ids(cid)), 5);
        // 买家成为该角色的 owner_latest_char
        assert!(character::owner_latest_char(baddr) == cid, 6);
    }

    #[test]
    #[expected_failure(abort_code = 13, location = mohayo::character)]
    fun test_transfer_blocked_while_in_room() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        let addr = std::signer::address_of(a);
        character::gm_mint(a, addr, 1, 0, vector[0, 0, 0, 0], vector[850]);
        let cid = character::owner_latest_char(addr);
        engine::create_room(a, 1);
        engine::join_room_as_char(a, 1, cid);          // 关卡内 → 锁
        character::transfer_character(a, cid, @0xDD03); // E_IN_ROOM(13)
    }

    /// §2.6.11 复审: 已在某房间的角色不得再进第二个房间 —— 否则 room_id 被覆盖,
    /// 退掉旧房会把角色提前解锁(人还在新房战斗中), §7.4「关卡内禁止转移」被绕过。
    #[test]
    #[expected_failure(abort_code = 29, location = mohayo::engine)]   // E_CHAR_IN_ROOM
    fun test_same_character_cannot_join_two_rooms() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        let addr = std::signer::address_of(a);
        character::gm_mint(a, addr, 1, 0, vector[0, 0, 0, 0], vector::empty());
        let cid = character::owner_latest_char(addr);
        engine::create_room(a, 1);
        engine::create_room(a, 1);
        engine::join_room_as_char(a, 1, cid);
        assert!(character::get_room_id(cid) == 1, 1);
        engine::join_room_as_char(a, 2, cid);            // 同一角色跨房双开 → 拒绝
    }

    #[test]
    fun test_history_recorded_on_clear_and_survives_transfer() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        let addr = std::signer::address_of(a);
        // 人类(race 0) = 自选槽 +2, 容得下 [毒刃, 急救] 两个自选技
        character::gm_mint_at_level(a, addr, 2, 0, vector[0, 0, 0, 0], vector[820, 850], 300);
        let cid = character::owner_latest_char(addr);
        engine::create_room(a, 1);
        engine::join_room_as_char(a, 1, cid);
        engine::start_combat_test(a, 1);
        engine::set_plan(a, 1, 0, vector[820]);
        run_room(a, 1);
        assert!(engine::room_result(1) == 1, 1);
        let (runs, clears, best) = character::get_history(cid);
        assert!(runs == 1 && clears == 1 && best == 1, 2);
        // 关卡结束后角色解锁, 可以转移; 履历随角色保留
        character::transfer_character(a, cid, @0xDD04);
        let (runs2, clears2, best2) = character::get_history(cid);
        assert!(runs2 == 1 && clears2 == 1 && best2 == 1, 3);
    }

    // ===================== Q2: 周常变异 / 中途加入 / 召唤缺口 =====================

    fun set_mutator_now(a: &signer, kind: u8, value: i64) {
        let week = engine::week_of(aptos_framework::timestamp::now_seconds());
        engine::set_weekly_mutator(a, week, kind, value);
    }

    #[test]
    fun test_mutator_mana_flood_snapshot() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        set_mutator_now(a, engine::MUT_MANA(), 5);
        engine::create_room(a, 1);                                 // 创建时快照当周变异
        let (k, v) = engine::room_mutator(1);
        assert!(k == engine::MUT_MANA() && v == 5, 1);
        engine::join_room(a, 1, 1000, 10, 10, 100);
        engine::start_combat_test(a, 1);
        // D1 基础魔素 2/回合 + 变异 5 = 7
        assert!(engine::room_mana(1) == 7, 2);
        engine::step_for_test(a, 1);
        assert!(engine::room_mana(1) == 14, 3);
        // 周中改变异不影响已创建房间(快照)
        set_mutator_now(a, engine::MUT_NONE(), 0);
        let (k2, _v2) = engine::room_mutator(1);
        assert!(k2 == engine::MUT_MANA(), 4);
    }

    #[test]
    fun test_mutator_hp_and_stingy_drop() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        // 巨物周: D1 碎晶岩 35 → 70
        set_mutator_now(a, engine::MUT_HP(), 1000);
        engine::create_room(a, 1);
        engine::join_room(a, 1, 1000, 10, 10, 100);
        engine::start_combat_test(a, 1);
        let (_hp, max_hp, _, _, _, _) = engine::enemy_state(1, 0);
        assert!(max_hp == 70, 1); // 35 × (1000+1000)/1000
        // 吝啬周: 必掉表也不掉
        set_mutator_now(a, engine::MUT_DROP(), -1);
        item::register_drop_table(a, 1, vector[item::ITEM_MANA_FIREWORK], vector[1000], vector[1]);
        let addr = std::signer::address_of(a);
        engine::create_room(a, 1);                                  // 第二个房间 → id 2
        engine::join_room(a, 2, 4000, 100000, 100, 100);
        engine::start_combat_test(a, 2);
        engine::set_plan(a, 2, 0, vector[820]);
        run_room(a, 2);
        assert!(engine::room_result(2) == 1, 2);
        assert!(item::balance_whole(item::ITEM_MANA_FIREWORK, addr) == 0, 3);
    }

    #[test]
    fun test_mutator_storm_adds_strike() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        // 覆写 D2 战斗 1 为单只 60000hp 炉(不还手), 便于比较段数
        skill_registry::set_dungeon(a, 2, types::make_dungeon_config(29, 1, 20, 0, 0, 120, 1));
        skill_registry::set_dungeon_battles(a, 2, vector[types::make_battle_config(29, 1)]);
        // 基准: 无变异, 暴风剑 4 段
        set_mutator_now(a, engine::MUT_NONE(), 0);
        engine::create_room(a, 2);
        engine::join_room_affixed(a, 1, 100000, 100, 100, 100, 5, 3, 0, 0);
        engine::start_combat_test(a, 1);
        engine::set_plan(a, 1, 0, vector[840]);
        engine::step_for_test(a, 1);
        let (h1, max1, _, _, _, _) = engine::enemy_state(1, 0);
        let dmg_plain = max1 - h1;
        // 疾风连击周: +4 段 → 8 段(封顶)
        set_mutator_now(a, engine::MUT_STORM(), 4);
        engine::create_room(a, 2);
        engine::join_room_affixed(a, 2, 100000, 100, 100, 100, 5, 3, 0, 0);
        engine::start_combat_test(a, 2);
        engine::set_plan(a, 2, 0, vector[840]);
        engine::step_for_test(a, 2);
        let (h2, max2, _, _, _, _) = engine::enemy_state(2, 0);
        let dmg_storm = max2 - h2;
        std::debug::print(&vector[dmg_plain, dmg_storm]);
        assert!(dmg_storm > dmg_plain, 1);
        assert!(dmg_storm <= dmg_plain * 3, 2);   // 8 段 vs 4 段, 不会离谱
    }

    #[test]
    fun test_join_during_combat_arrives_late() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        let addr = std::signer::address_of(a);
        character::gm_mint_at_level(a, addr, 2, 0, vector[0, 0, 0, 0], vector[820], 300);
        let cid = character::owner_latest_char(addr);
        engine::create_room(a, 1);
        engine::join_room(a, 1, 4000, 100000, 100, 100);        // 成员 0(大厅)
        engine::start_combat_test(a, 1);
        assert!(engine::member_arrive_delay(1, 0) == 0, 1);      // 开局成员立即在场
        engine::join_room_as_char(a, 1, cid);                    // 战斗中入队 → 延迟
        assert!(engine::member_count(1) == 2, 2);
        assert!(engine::member_arrive_delay(1, 1) == 3, 3);
        engine::step_for_test(a, 1);
        assert!(engine::member_arrive_delay(1, 1) == 2, 4);
        engine::step_for_test(a, 1);
        engine::step_for_test(a, 1);
        assert!(engine::member_arrive_delay(1, 1) == 0, 5);      // 到场
    }

    #[test]
    fun test_mutator_fog_reduces_enemy_hits() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        // 覆写 D2 战斗 1 为单只机仆(不排计划, 只挨打), 魔素充足
        skill_registry::set_dungeon(a, 2, types::make_dungeon_config(5, 1, 20, 0, 0, 120, 1));
        skill_registry::set_dungeon_battles(a, 2, vector[types::make_battle_config(5, 1)]);
        set_mutator_now(a, engine::MUT_NONE(), 0);
        engine::create_room(a, 2);
        engine::join_room(a, 1, 1000000, 10, 10, 1);
        engine::start_combat_test(a, 1);
        let g = 0;
        while (g < 30 && engine::room_phase(1) == 1) { engine::step_for_test(a, 1); g = g + 1; };
        let (hp0, _, _, _, _, _) = engine::member_state(1, 0);
        // 迷雾周: 敌人命中 −900‰ → 基本打不中
        set_mutator_now(a, engine::MUT_FOG(), 900);
        engine::create_room(a, 2);
        engine::join_room(a, 2, 1000000, 10, 10, 1);
        engine::start_combat_test(a, 2);
        let g2 = 0;
        while (g2 < 30 && engine::room_phase(2) == 1) { engine::step_for_test(a, 2); g2 = g2 + 1; };
        let (hp1, _, _, _, _, _) = engine::member_state(2, 0);
        let taken_plain = 1000000 - hp0;
        let taken_fog = 1000000 - hp1;
        std::debug::print(&vector[taken_plain, taken_fog]);
        assert!(taken_fog < taken_plain, 1);
    }

    #[test]
    fun test_summon_gap_caps_enemy_count() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        // 自建表: 单只机神祭司(召唤师, 召唤机仆×2)
        skill_registry::register_table(a, vector[types::make_table_entry(10, 1000)]); // 表 32
        skill_registry::set_dungeon(a, 3, types::make_dungeon_config(32, 1, 30, 0, 0, 120, 1));
        skill_registry::set_dungeon_battles(a, 3, vector[types::make_battle_config(32, 1)]);
        engine::create_room(a, 3);
        engine::join_room(a, 1, 1000000, 10, 10, 1);   // 1 名玩家 → 上限 = 1+2 = 3
        engine::start_combat_test(a, 1);
        let g = 0;
        while (g < 20 && engine::room_phase(1) == 1) { engine::step_for_test(a, 1); g = g + 1; };
        let ec = engine::enemy_count(1);
        std::debug::print(&vector[ec]);
        assert!(ec <= 3, 1);   // §4.5-1: 存活敌人数不超过「存活角色数 + 2」
    }

    // ===================== Q3: 回合驱动防护（§3.1 竞态与滥用） =====================

    #[test]
    #[expected_failure(abort_code = 24, location = mohayo::engine)]
    fun test_advance_turn_rejects_stale_turn_id() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        engine::create_room(a, 1);
        engine::join_room(a, 1, 4000, 100, 100, 100);
        engine::start_combat_test(a, 1);
        // 同一回合的第二笔交易(或重放)带着过期的 turn_id → E_TURN_MISMATCH(24), 状态零变更
        engine::advance_turn_test(a, 1, 999);
    }

    #[test]
    #[expected_failure(abort_code = 25, location = mohayo::engine)]
    fun test_advance_turn_enforces_cooldown() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        engine::create_room(a, 1);
        engine::join_room(a, 1, 4000, 100, 100, 100);
        engine::start_combat_test(a, 1);
        // 开战后立刻再推进(距上次 < 2 秒) → E_ADVANCE_COOLDOWN(25)
        engine::advance_turn_test(a, 1, engine::room_turn(1));
    }

    #[test]
    #[expected_failure(abort_code = 26, location = mohayo::engine)]
    fun test_emergency_advance_requires_gap() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        engine::create_room(a, 1);
        engine::join_room(a, 1, 4000, 100, 100, 100);
        engine::start_combat_test(a, 1);
        engine::emergency_advance_test(a, 1); // 未达 30 秒 → E_NOT_EMERGENCY(26)
    }

    #[test]
    fun test_emergency_advance_unblocks_after_gap() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        engine::create_room(a, 1);
        engine::join_room(a, 1, 4000, 100, 100, 100);
        engine::start_combat_test(a, 1);
        let t0 = aptos_framework::timestamp::now_seconds();
        aptos_framework::timestamp::update_global_time_for_test_secs(t0 + 30);
        engine::emergency_advance_test(a, 1);            // Keeper 挂掉后任何人都能解卡
        assert!(engine::room_turn(1) == 2, 1);
    }

    // ===================== Q4: 首号免费重掷 / 房间解散与过期（§2.3 / §3.1） =====================

    #[test]
    fun test_free_rerolls_granted_once_per_player() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        let addr = std::signer::address_of(a);
        character::gm_mint(a, addr, 1, 0, vector[0, 0, 0, 0], vector[850]);   // 首角色
        assert!(character::free_rerolls(addr) == 3, 1);
        character::gm_mint(a, addr, 2, 0, vector[0, 0, 0, 0], vector[850]);   // 第二个角色不再发
        assert!(character::free_rerolls(addr) == 3, 2);
        // 卖掉首号也拿不到第二次(created_before 判定) —— 计数器也不随角色走
        let cid = character::owner_latest_char(addr);
        character::transfer_character(a, cid, @0xEE01);
        assert!(character::free_rerolls(@0xEE01) == 0, 3);
        assert!(character::free_rerolls(addr) == 3, 4);
    }

    #[test]
    #[expected_failure(abort_code = 6, location = mohayo::engine)]
    fun test_disband_room_leader_only() {
        let a = &std::account::create_account_for_test(@mohayo);
        let b = &std::account::create_account_for_test(@0xEE02);
        setup(a);
        content_registration::register_all_content(a);
        engine::create_room(a, 1);
        // §2.6.14 起队长必须是在场队员, 所以让 a 自己入房当队长, 再让非队长的 b 试图解散
        engine::join_room(a, 1, 4000, 100, 100, 100);
        engine::disband_room(b, 1);     // 非队长 → E_NOT_LEADER(6)
    }

    /// §2.6.14: 队长必须是在场队员 —— 建房者不入房就不再是队长, 队长落到唯一队员身上。
    /// 也因此不会出现「打赢第一场后被非队员队长卡在间歇期」。
    #[test]
    fun test_leader_falls_to_a_member_and_can_advance_battle() {
        let a = &std::account::create_account_for_test(@mohayo);
        let b = &std::account::create_account_for_test(@0xEE10);
        setup(a);
        content_registration::register_all_content(a);
        engine::create_room(a, 1);
        assert!(engine::room_leader(1) == std::signer::address_of(a), 1);
        engine::join_room(b, 1, 30000, 26000, 13000, 600);   // b 是唯一队员
        assert!(engine::room_leader(1) == std::signer::address_of(b), 2);  // 队长转给队员
        engine::start_combat_test(b, 1);
        engine::set_plan(b, 1, 0, vector[820]);
        // 队长是队员, 所以能自己推完整座 D1(含 3 次间歇期推进)
        run_room(b, 1);
        assert!(engine::room_phase(1) == 2, 3);
    }

    /// 建房者不入房时不再是队长, 也就开不了战。
    #[test]
    #[expected_failure(abort_code = 6, location = mohayo::engine)]   // E_NOT_LEADER
    fun test_non_member_creator_cannot_start() {
        let a = &std::account::create_account_for_test(@mohayo);
        let b = &std::account::create_account_for_test(@0xEE11);
        setup(a);
        content_registration::register_all_content(a);
        engine::create_room(a, 1);
        engine::join_room(b, 1, 4000, 100, 100, 100);
        engine::start_combat_test(a, 1);
    }

    /// §2.6.14: 只有队长能推进回合（此前任何人都能把别人的房间刷到回合上限）。
    #[test]
    #[expected_failure(abort_code = 6, location = mohayo::engine)]   // E_NOT_LEADER
    fun test_only_leader_can_advance_turn() {
        let a = &std::account::create_account_for_test(@mohayo);
        let c = &std::account::create_account_for_test(@0xEE12);
        setup(a);
        content_registration::register_all_content(a);
        engine::create_room(a, 1);
        engine::join_room(a, 1, 5000, 100, 100, 99);
        engine::start_combat_test(a, 1);
        let t = aptos_framework::timestamp::now_seconds();
        aptos_framework::timestamp::update_global_time_for_test_secs(t + 2);
        engine::advance_turn_test(c, 1, engine::room_turn(1));      // 外人 → 拒绝
    }

    /// 兜底推进仍对任何人开放（队长掉线时房间不能死），门槛是 30 秒。
    #[test]
    fun test_emergency_advance_open_to_anyone() {
        let a = &std::account::create_account_for_test(@mohayo);
        let c = &std::account::create_account_for_test(@0xEE13);
        setup(a);
        content_registration::register_all_content(a);
        engine::create_room(a, 1);
        engine::join_room(a, 1, 5000, 100, 100, 99);
        engine::start_combat_test(a, 1);
        let t0 = aptos_framework::timestamp::now_seconds();
        aptos_framework::timestamp::update_global_time_for_test_secs(t0 + 31);
        engine::emergency_advance_test(c, 1);                       // 外人也能解卡
        assert!(engine::room_turn(1) == 2, 1);
    }

    #[test]
    #[expected_failure(abort_code = 27, location = mohayo::engine)]
    fun test_disbanded_room_rejects_join() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        engine::create_room(a, 1);
        engine::disband_room(a, 1);
        assert!(engine::room_closed(1), 1);
        engine::join_room(a, 1, 4000, 100, 100, 100);   // E_ROOM_CLOSED(27)
    }

    #[test]
    #[expected_failure(abort_code = 28, location = mohayo::engine)]
    fun test_room_expire_requires_ttl() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        engine::create_room(a, 1);
        engine::expire_room(a, 1);     // 未满 TTL(默认 7200s) → E_NOT_EXPIRED(28)
    }

    #[test]
    fun test_room_expires_after_ttl() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        engine::set_room_ttl(a, 60);                        // 测试用短 TTL
        engine::create_room(a, 1);
        let t0 = aptos_framework::timestamp::now_seconds();
        aptos_framework::timestamp::update_global_time_for_test_secs(t0 + 61);
        engine::expire_room(a, 1);                          // 任何人可触发
        assert!(engine::room_closed(1), 1);
    }

    /// §2.6.11/§8.2: 变体表是**完整候选集**(权重和 = 概率分母) —— 漏登记基准条目会让「变体」
    /// 变成 100%(D5 b3 曾如此)。实测对照: 缺基准时 35 个到达 b3 的房间出现 8 魔像 + 3 哨兵,
    /// 补齐基准后 35/35 为督军。
    #[test]
    fun test_variant_tables_are_complete_candidate_sets() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        // D5 b3: 基准(督军表 16) 80% + 混沌变体(表 17) 20%
        let v5 = skill_registry::get_variants(5, 3);
        assert!(vector::length(&v5) == 2, 1);
        assert!(types::variant_table_id(vector::borrow(&v5, 0)) == 16, 2);
        assert!((types::variant_weight(vector::borrow(&v5, 0)) as u64) == 800, 3);
        assert!(types::variant_table_id(vector::borrow(&v5, 1)) == 17, 4);
        assert!((types::variant_weight(vector::borrow(&v5, 1)) as u64) == 200, 5);
        // D9 b4: 宝箱表 30 @700 + 皇帝备用机体表 31 @300
        let v9 = skill_registry::get_variants(9, 4);
        assert!(vector::length(&v9) == 2, 6);
        assert!(
            (types::variant_weight(vector::borrow(&v9, 0)) as u64)
            + (types::variant_weight(vector::borrow(&v9, 1)) as u64) == 1000, 7);
        // 变体自带的敌人数: D5 b3 混沌变体出 3 只混编(§8.2), 基准变体沿用本场配置
        assert!(types::variant_enemy_count(vector::borrow(&v5, 0)) == 0, 8);
        assert!(types::variant_enemy_count(vector::borrow(&v5, 1)) == 3, 9);
    }

    // ===================== §2.6.11 复审修正 =====================

    /// 爆裂魔法(430) 必须同时带 FLAG_GUARANTEED_HIT(bit0) 与 FLAG_MANA_ALL(bit1) —— §4.9 固有绝对命中。
    #[test]
    fun test_burst_magic_is_guaranteed_hit() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        let s = skill_registry::get_skill(430);
        assert!((types::skill_flags(&s) & 1) != 0, 1);   // GUARANTEED_HIT
        assert!((types::skill_flags(&s) & 2) != 0, 2);   // FLAG_MANA_ALL
    }

    /// 端到端: 施法者命中率被压到下限时, 爆裂魔法仍必须每发必中(免掷骰)。
    /// 缺 bit0 时命中率只有 MIN_HIT_RATE=5‰, 12 个房间不可能全中。
    #[test]
    fun test_burst_magic_hits_through_accuracy_penalty() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        let hits = 0;
        let i = 0;
        while (i < 12) {
            engine::create_room(a, 1);
            let rid = i + 1;
            engine::join_room(a, rid, 5000, 100, 100, 99);   // 面板通道(char_id=0)
            engine::start_combat_test(a, rid);
            // ACC_DOWN(op6) 1500‰ → 命中阈值被压到 MIN_HIT_RATE=50
            engine::test_add_member_effect(a, rid, 0, 6, 9, 1500);
            engine::set_plan(a, rid, 0, vector[430]);
            engine::step_for_test(a, rid);                                    // 玩家 spd 99 先手
            let (ehp, _, _, _, _, _) = engine::enemy_state(rid, 0);   // D1b1 碎晶岩 hp 35
            if (ehp < 35) { hits = hits + 1; };
            i = i + 1;
        };
        assert!(hits == 12, 1);
    }

    /// §2.6.8/§2.6.11: 迟到成员(arrive_delay>0)在到场前不吃任何 AoE。
    /// 三个全体目标分支此前只查 alive, 会让未到场者照样掉血。
    #[test]
    fun test_late_joiner_not_hit_by_aoe() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        // 敌方全体攻击(targeting 4) + AI + 模板 + 表 + 地牢
        skill_registry::register_skill(a, types::make_skill(1701, types::KIND_PHYSICAL(), 0, 0, 0, 0, 0, 0,
            types::TGT_ALL_ENEMY(), types::WT_UNIFORM(), 1, 500, 0, 1000, 0,
            vector::empty(), types::make_summon_rule(0, 0, 0)));
        skill_registry::register_ai(a, types::make_monster_ai(vector[1701], 1));
        skill_registry::register_template(a, types::make_enemy_template(1, 0, 5000, 100, 0, 99, 1000, 0, 0,
            types::make_on_death_spawn(0, 0, 0)));
        skill_registry::register_table(a, vector[types::make_table_entry(1, 1000)]);
        skill_registry::set_dungeon(a, 1, types::make_dungeon_config(1, 1, 5, 0, 0, 120, 1));
        skill_registry::set_dungeon_battles(a, 1, vector[types::make_battle_config(1, 1)]);

        engine::create_room(a, 1);
        engine::join_room(a, 1, 1000, 10, 0, 1);       // A: 大厅期入场 → 立即到场
        engine::start_combat_test(a, 1);
        engine::join_room(a, 1, 1000, 10, 0, 1);       // B: 战斗中入队 → 延迟到场
        assert!(engine::member_arrive_delay(1, 1) == 3, 1);
        engine::step_for_test(a, 1);                                    // 敌 spd 99 先手放全体攻击
        let (b_hp, _, _, _, _, _) = engine::member_state(1, 1);
        let (a_hp, _, _, _, _, _) = engine::member_state(1, 0);
        assert!(b_hp == 1000, 2);                      // 未到场 → 不被 AoE 命中
        assert!(a_hp < 1000, 3);                       // 已在场 → 照常吃 AoE
    }

    // ===================== §2.6.12 房间回收 =====================

    /// 未进入终态的房间（大厅期、开着）不可回收。
    #[test]
    #[expected_failure(abort_code = 30, location = mohayo::engine)]   // E_NOT_RECLAIMABLE
    fun test_reclaim_rejected_when_not_terminal() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        engine::set_reclaim_delay(a, 0);
        engine::create_room(a, 1);
        engine::reclaim_room(a, 1);
    }

    /// 已结算房间在保留窗口内不可回收（客户端还要读结算结果）。
    #[test]
    #[expected_failure(abort_code = 30, location = mohayo::engine)]   // E_NOT_RECLAIMABLE
    fun test_reclaim_rejected_within_retention_window() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        engine::set_reclaim_delay(a, 3600);
        engine::create_room(a, 1);
        engine::join_room(a, 1, 30000, 26000, 13000, 600);
        engine::start_combat_test(a, 1);
        engine::set_plan(a, 1, 0, vector[820]);
        run_room(a, 1);
        assert!(engine::room_phase(1) == 2, 1);      // 已结算
        engine::reclaim_room(a, 1);                  // 窗口没到
    }

    /// §2.6.14: 变体抽选必须真的按权重遍历**所有**变体。
    /// 判据用「两个变体携带不同敌人数」: 若抽选循环忘了累加权重(曾经的 bug),
    /// 第二个变体永远不可达, 只会出现一种敌人数。两个变体等权, 20 个房间必然都出现。
    #[test]
    fun test_variant_selection_reaches_all_variants() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        // 最小内容: 一个技能/AI/模板/表 + 单场副本; 两个变体都指向同一张表, 但敌人数不同
        skill_registry::register_skill(a, types::make_skill(1801, types::KIND_PHYSICAL(), 0, 0, 0, 0, 0, 0,
            types::TGT_RAND_SINGLE_ENEMY(), types::WT_UNIFORM(), 1, 100, 0, 900, 0,
            vector::empty(), types::make_summon_rule(0, 0, 0)));
        skill_registry::register_ai(a, types::make_monster_ai(vector[1801], 1));
        skill_registry::register_template(a, types::make_enemy_template(1, 0, 100, 10, 0, 1, 900, 1, 1,
            types::make_on_death_spawn(0, 0, 0)));
        skill_registry::register_table(a, vector[types::make_table_entry(1, 1000)]);
        skill_registry::set_dungeon(a, 1, types::make_dungeon_config(1, 1, 5, 0, 0, 120, 1));
        skill_registry::set_dungeon_battles(a, 1, vector[types::make_battle_config(1, 1)]);
        skill_registry::add_battle_variant(a, 1, 1, 1, 500, 0);   // 基准: 沿用本场敌人数(1)
        skill_registry::add_battle_variant(a, 1, 1, 1, 500, 3);   // 变体: 出 3 只

        let one = false;
        let three = false;
        let i = 0;
        while (i < 20) {
            engine::create_room(a, 1);
            let rid = i + 1;
            engine::join_room(a, rid, 5000, 100, 100, 99);
            engine::start_combat_test(a, rid);
            let n = engine::enemy_count(rid);
            if (n == 1) { one = true; };
            if (n == 3) { three = true; };
            i = i + 1;
        };
        assert!(one, 1);
        assert!(three, 2);
    }

    /// §2.6.14: 房间可被枚举 —— 活跃列表 + 分页视图；回收后从列表里 swap-remove。
    #[test]
    fun test_rooms_are_enumerable() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        engine::set_reclaim_delay(a, 0);
        assert!(engine::active_room_count() == 0, 1);
        engine::create_room(a, 1);
        engine::create_room(a, 1);
        engine::create_room(a, 1);
        assert!(engine::active_room_count() == 3, 2);
        assert!(engine::active_room_at(0) == 1, 3);
        assert!(engine::active_room_at(1) == 2, 4);
        assert!(engine::active_room_at(2) == 3, 5);
        assert!(engine::room_exists(2), 6);
        // 回收中间那个：swap-remove 之后另外两个仍在列表里
        engine::disband_room(a, 2);
        engine::reclaim_room(a, 2);
        assert!(engine::active_room_count() == 2, 7);
        assert!(!engine::room_exists(2), 8);
        let seen_1 = false;
        let seen_3 = false;
        let i = 0;
        while (i < engine::active_room_count()) {
            let rid = engine::active_room_at(i);
            if (rid == 1) { seen_1 = true; };
            if (rid == 3) { seen_3 = true; };
            i = i + 1;
        };
        assert!(seen_1 && seen_3, 9);
    }

    /// 结算完成的房间在窗口过后可被回收。
    #[test]
    fun test_reclaim_settled_room() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        engine::set_reclaim_delay(a, 60);
        engine::create_room(a, 1);
        engine::join_room(a, 1, 30000, 26000, 13000, 600);
        engine::start_combat_test(a, 1);
        engine::set_plan(a, 1, 0, vector[820]);
        run_room(a, 1);
        assert!(engine::room_phase(1) == 2, 1);
        assert!(!engine::room_reclaimable(1), 2);
        let t0 = aptos_framework::timestamp::now_seconds();
        aptos_framework::timestamp::update_global_time_for_test_secs(t0 + 61);
        assert!(engine::room_reclaimable(1), 3);
        engine::reclaim_room(a, 1);                  // 任何人可触发
    }

    /// 回收后房间相关视图一律 E_ROOM_NOT_FOUND(3)。房间号不重用。
    #[test]
    #[expected_failure(abort_code = 3, location = mohayo::engine)]    // E_ROOM_NOT_FOUND
    fun test_reclaimed_room_views_report_not_found() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        engine::set_reclaim_delay(a, 0);             // 立即回收
        engine::create_room(a, 1);
        engine::disband_room(a, 1);
        engine::reclaim_room(a, 1);
        let _ = engine::room_phase(1);
    }

    /// §2.6.12: 关房应当释放成员角色锁 —— 此前要成员自己再调一次 leave_room 才能解锁，
    /// 带着锁的角色进不了别的房间(E_CHAR_IN_ROOM)。
    #[test]
    fun test_disband_releases_character_lock() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        engine::set_reclaim_delay(a, 60);
        let addr = std::signer::address_of(a);
        character::gm_mint(a, addr, 1, 0, vector[0, 0, 0, 0], vector::empty());
        let cid = character::owner_latest_char(addr);
        engine::create_room(a, 1);
        engine::join_room_as_char(a, 1, cid);
        assert!(character::get_room_id(cid) == 1, 1);
        engine::disband_room(a, 1);
        assert!(character::get_room_id(cid) == 0, 2);   // 关房即解锁
        // 解锁后同一角色可以立刻进别的房间
        engine::create_room(a, 1);
        engine::join_room_as_char(a, 2, cid);
        assert!(character::get_room_id(cid) == 2, 3);
        // 保留窗口过后回收 1 号房
        let t0 = aptos_framework::timestamp::now_seconds();
        aptos_framework::timestamp::update_global_time_for_test_secs(t0 + 61);
        assert!(engine::room_reclaimable(1), 4);
        engine::reclaim_room(a, 1);
    }

    /// §2.6.12: 战斗期长期无人推进(Keeper 停摆 / 全队弃房)时，任何人可让房间过期，
    /// 按既有超时规则收尾：扣救援费 + 记未通关履历 + 释放角色锁 + 进入终态。
    #[test]
    fun test_expire_combat_room_after_stall() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        engine::set_room_ttl(a, 60);
        let addr = std::signer::address_of(a);
        character::gm_mint(a, addr, 1, 0, vector[0, 0, 0, 0], vector::empty());
        let cid = character::owner_latest_char(addr);
        economy::gm_mint(a, addr, 1000);
        engine::create_room(a, 1);
        engine::join_room_as_char(a, 1, cid);
        engine::start_combat_test(a, 1);
        let bal_before = economy::balance_of(addr);
        let t0 = aptos_framework::timestamp::now_seconds();
        aptos_framework::timestamp::update_global_time_for_test_secs(t0 + 61);
        engine::expire_room(a, 1);
        assert!(engine::room_phase(1) == 2, 1);                 // 进入终态
        assert!(engine::room_result(1) == 2, 2);                // 按超时(败)结算
        assert!(character::get_room_id(cid) == 0, 3);           // 角色解锁
        assert!(economy::balance_of(addr) == bal_before - 10, 4); // D1 救援费 10
        let (runs, clears, _best) = character::get_history(cid);
        assert!(runs == 1 && clears == 0, 5);                    // 记了一次未通关
    }

    // ===================== §2.6.13 AP 实现口径 =====================

    /// AP 每回合行动开始时 +1（封顶 22）；**计划为空则整次行动被跳过，连这 1 点也不给**。
    #[test]
    fun test_ap_grants_per_turn_and_needs_a_plan() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        engine::create_room(a, 1);
        engine::join_room(a, 1, 5000, 10, 0, 99);
        engine::join_room(a, 1, 5000, 10, 0, 1);
        engine::start_combat_test(a, 1);
        engine::set_plan(a, 1, 0, vector[190]);   // 待机: ap_cost 0 / ap_gain 0 / 魔素 0
        engine::step_for_test(a, 1);
        engine::step_for_test(a, 1);
        engine::step_for_test(a, 1);
        assert!(engine::member_ap(1, 0) == 3, 1);   // 三个回合各 +1
        assert!(engine::member_ap(1, 1) == 0, 2);   // 计划为空 → 不涨 AP
    }

    /// AP 产出发生在**施放之后**，与是否命中无关（§2.6.13 记录：这一条与 §4.9 的
    /// 「未命中则拿不到 AP」表述不一致，属待定案项，此处按实现钉住行为）。
    /// 快速剑(310)：apCost 0 / apGain 2 / 魔素 3，且**没有**绝对命中。
    /// 第 1 回合魔素只有 2，技能施放失败 → AP = 1（只有回合那 1 点）。
    /// 第 2 回合魔素 4，施放成功 → AP = 1 + 1 + 2 = 4，命中率被压到下限也不影响。
    /// 若把 apGain 改成「命中才给」，约 95% 的房间只会停在 2，此用例即失败。
    #[test]
    fun test_ap_gain_applies_even_when_the_cast_misses() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        let i = 0;
        while (i < 12) {
            engine::create_room(a, 1);
            let rid = i + 1;
            engine::join_room(a, rid, 5000, 100, 100, 99);
            engine::start_combat_test(a, rid);
            // ACC_DOWN(op6) 1500‰ → 命中阈值被压到 MIN_HIT_RATE=50
            engine::test_add_member_effect(a, rid, 0, 6, 9, 1500);
            engine::set_plan(a, rid, 0, vector[310]);
            engine::step_for_test(a, rid);
            assert!(engine::member_ap(rid, 0) == 1, 1);   // 魔素不足, 施放失败
            engine::step_for_test(a, rid);
            assert!(engine::member_ap(rid, 0) == 4, 2);   // 回合 +1, 施放产出 +2
            i = i + 1;
        };
    }


    // ===================== §2.6.14 玩家建号入口 =====================

    /// 玩家建号：链上掷种族与词条，首次建号发启动资金 + 3 次免费重掷，第二次起只建号。
    #[test]
    fun test_create_character_grants_once() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        let p = &std::account::create_account_for_test(@0xC001);
        let paddr = std::signer::address_of(p);
        let bal0 = economy::balance_of(paddr);
        assert!(bal0 == 0, 1);
        character::create_character_test(p, 2, vector::empty(), 7);   // 剑士, 不选自选技
        let c1 = character::owner_latest_char(paddr);
        assert!(c1 != 0, 2);
        assert!(character::get_class_id(c1) == 2, 3);
        assert!(character::get_level(c1) == 1, 4);
        assert!(economy::balance_of(paddr) == bal0 + (economy::STARTING_GRANT() as i128), 5);
        assert!(character::free_rerolls(paddr) == 3, 6);    // 首号福利
        // 第二个角色：不再发启动资金，也不再有免费重掷
        character::create_character_test(p, 3, vector::empty(), 11);
        assert!(economy::balance_of(paddr) == bal0 + (economy::STARTING_GRANT() as i128), 7);
        assert!(character::free_rerolls(paddr) == 3, 8);
        assert!(character::owner_latest_char(paddr) != c1, 9);
    }

    /// §2.6: 建号时可以挑自选池技能 —— 进入 skill_ids, 且原样记进 self_select（重掷时要复用）。
    #[test]
    fun test_create_character_with_self_select() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        let p = &std::account::create_account_for_test(@0xC005);
        let paddr = std::signer::address_of(p);
        character::create_character_test(p, 2, vector[830, 850], 7);   // 剑士 + 一闪/急救
        let cid = character::owner_latest_char(paddr);
        let ss = character::get_self_select(cid);
        assert!(vector::length(&ss) == 2, 1);                          // 原样记下(重掷复用)
        let skills = character::get_skill_ids(cid);
        assert!(vector::contains(&skills, &830), 2);                    // 第一个自选技必然进槽
    }

    /// 自选槽只认白名单: 职业技不能当自选技(红线, §5)。
    #[test]
    #[expected_failure(abort_code = 4, location = mohayo::character)]   // E_SKILL_NOT_POOL
    fun test_create_character_rejects_non_pool_skill() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        let p = &std::account::create_account_for_test(@0xC006);
        character::create_character_test(p, 2, vector[310], 7);        // 310 是剑士职业技
    }

    /// 无职业路线（class 0）能用：中性模板 + 3 个自选槽，且没有任何职业技。
    /// 注意种族是随机掷的，所以这里只断言与种族无关的部分。
    #[test]
    fun test_create_classless_character() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        let p = &std::account::create_account_for_test(@0xC002);
        let paddr = std::signer::address_of(p);
        assert!(vector::length(&skill_registry::get_class_skill_ids(0)) == 0, 1);  // 无职业无职业技
        character::create_character_test(p, 0, vector::empty(), 3);
        let cid = character::owner_latest_char(paddr);
        assert!(character::get_class_id(cid) == 0, 2);
        let (_cls, _race, lvl, hp, _mhp, _atk, _mag, _spd, _skills, _rid) = character::get_character(cid);
        assert!(lvl == 1 && hp > 0, 3);
    }

    /// 负债者不得建号（§6.3）。
    #[test]
    #[expected_failure(abort_code = 22, location = mohayo::character)]   // E_DEBTOR
    fun test_create_character_rejected_when_debtor() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        let p = &std::account::create_account_for_test(@0xC003);
        economy::gm_charge_rescue(a, std::signer::address_of(p), 5);   // 先变负债
        character::create_character_test(p, 1, vector::empty(), 5);
    }

    /// 每账号角色数上限。
    #[test]
    #[expected_failure(abort_code = 23, location = mohayo::character)]   // E_CHAR_CAP
    fun test_create_character_cap() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        let p = &std::account::create_account_for_test(@0xC004);
        let i = 0;
        while (i < 11) {
            character::create_character_test(p, 1, vector::empty(), (i + 1) * 13);
            i = i + 1;
        };
    }

    // ===================== §2.6.14 生产随机数入口 =====================

    /// 生产入口是私有 `#[randomness] entry`，测试里用 engine 的 `#[test_only]` 钩子穿进去，
    /// 验证「真实协议随机数 → 开战 → 推进一回合」这条链路真的能跑通(§2.6.14)。
    /// 其余用例走 `*_test` 变体（不注入协议熵），所以既有标定值不受影响。
    #[test]
    fun test_production_randomness_entries_smoke() {
        let a = &std::account::create_account_for_test(@mohayo);
        setup(a);
        content_registration::register_all_content(a);
        let f = &std::account::create_account_for_test(@aptos_framework);
        randomness::initialize_for_testing(f);              // PerBlockRandomness 必须存在
        engine::create_room(a, 1);
        engine::join_room(a, 1, 5000, 100, 100, 99);
        engine::test_production_start_combat(a, 1);
        assert!(engine::room_phase(1) == 1, 1);
        assert!(engine::enemy_count(1) == 2, 2);            // D1 b1 出了怪
        let t = aptos_framework::timestamp::now_seconds();
        aptos_framework::timestamp::update_global_time_for_test_secs(t + 2);
        engine::test_production_advance_turn(a, 1, engine::room_turn(1));
        assert!(engine::room_turn(1) == 2, 3);
    }
}

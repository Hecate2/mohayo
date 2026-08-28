/// Character creation, stats, class/race management.
/// Owns `ClassStore`, `RaceStore`, `CharacterStore` at @mohayo.
module mohayo::character {
    use aptos_framework::event;
    use aptos_std::table::{Self, Table};
    use std::signer;
    use std::vector;
    use mohayo::types::{Self, ClassDef, RaceDef, AffixTemplate};

    const E_NOT_OWNER: u64 = 1;
    const E_UNKNOWN_CLASS: u64 = 2;
    const E_UNKNOWN_RACE: u64 = 3;
    const E_SKILL_NOT_POOL: u64 = 4;
    const E_TOO_MANY_SKILLS: u64 = 5;
    const E_CLASS_SKILL_REJECTED: u64 = 6;
    const E_RACE_SKILL_REJECTED: u64 = 7;
    const E_INVALID_RACE: u64 = 8;
    const E_INVALID_AFFIX: u64 = 9;
    const E_LEVEL_ZERO: u64 = 10;
    const E_MAX_LEVEL: u64 = 11;
    const E_NOT_FOUND: u64 = 12;
    const E_IN_ROOM: u64 = 13;
    const E_RACE_WEIGHTS_BAD: u64 = 14;
    const E_AFFIX_TEMPLATE_CAP: u64 = 15;
    const E_CLASS_CAP: u64 = 16;
    const E_RACE_CAP: u64 = 17;
    const E_GOLD_REQUIRED: u64 = 18;
    const E_LEVEL_REQUIRED: u64 = 19;

    const MAX_CLASSES: u64 = 32;
    const MAX_RACES: u64 = 16;
    const MAX_AFFIX_TEMPLATES: u64 = 64;
    const MAX_RESOURCE_AFFIX: u64 = 4;

    // ---- class/race/affix definitions (from types) ----

    struct ClassStore has key {
        count: u64,
        classes: Table<u8, ClassDef>,
    }

    struct RaceStore has key {
        count: u64,
        races: Table<u8, RaceDef>,
        race_tier_weights: vector<u16>,  // [common, rare, legendary] per-mille
        common_races: vector<u8>,
        rare_races: vector<u8>,
        legendary_races: vector<u8>,
    }

    struct AffixStore has key {
        count: u64,
        templates: Table<u8, AffixTemplate>,
    }

    struct Character has store {
        id: u64,
        class_id: u8,
        race: u8,
        level: u16,
        hp: u64,
        max_hp: u64,
        attack: u64,
        magic: u64,
        speed: u64,
        skill_ids: vector<u64>,
        ability_bonuses: vector<u16>,  // [HP, ATK, MAG, SPD]
        resource_types: vector<u8>,
        mana_discount: u16,
        ap_discount: u16,
        ap_bonus: u16,
        mana_gain_bonus: i64,
        room_id: u64,  // 0 = not in room
    }

    struct CharacterStore has key {
        count: u64,
        characters: Table<u64, Character>,
        owner_chars: Table<address, vector<u64>>,
    }

    // ---- events ----

    #[event]
    struct CharacterCreated has drop, store { id: u64, owner: address, class_id: u8, race: u8, level: u16 }

    #[event]
    struct ClassRegistered has drop, store { id: u8 }

    #[event]
    struct RaceRegistered has drop, store { id: u8 }

    // ---- init ----

    fun init_module(account: &signer) {
        move_to(account, ClassStore { count: 0, classes: table::new() });
        move_to(account, RaceStore {
            count: 0, races: table::new(),
            race_tier_weights: vector[850, 120, 30],
            common_races: vector[0, 1, 2, 3],
            rare_races: vector[4, 5],
            legendary_races: vector[6, 7],
        });
        move_to(account, AffixStore { count: 0, templates: table::new() });
        move_to(account, CharacterStore { count: 0, characters: table::new(), owner_chars: table::new() });
    }

    // ---- registration ----

    public fun register_class(account: &signer, id: u8, def: ClassDef) acquires ClassStore {
        assert!(signer::address_of(account) == @mohayo, E_NOT_OWNER);
        let store = borrow_global_mut<ClassStore>(@mohayo);
        assert!(store.count < MAX_CLASSES, E_CLASS_CAP);
        if (table::contains(&store.classes, id)) {
            *table::borrow_mut(&mut store.classes, id) = def;
        } else {
            table::add(&mut store.classes, id, def);
            store.count = store.count + 1;
        };
    }

    public fun register_race(account: &signer, id: u8, def: RaceDef) acquires RaceStore {
        assert!(signer::address_of(account) == @mohayo, E_NOT_OWNER);
        let store = borrow_global_mut<RaceStore>(@mohayo);
        assert!(store.count < MAX_RACES, E_RACE_CAP);
        if (table::contains(&store.races, id)) {
            *table::borrow_mut(&mut store.races, id) = def;
        } else {
            table::add(&mut store.races, id, def);
            store.count = store.count + 1;
        };
    }

    public fun register_affix_template(account: &signer, id: u8, tmpl: AffixTemplate) acquires AffixStore {
        assert!(signer::address_of(account) == @mohayo, E_NOT_OWNER);
        let store = borrow_global_mut<AffixStore>(@mohayo);
        assert!(store.count < MAX_AFFIX_TEMPLATES, E_AFFIX_TEMPLATE_CAP);
        if (table::contains(&store.templates, id)) {
            *table::borrow_mut(&mut store.templates, id) = tmpl;
        } else {
            table::add(&mut store.templates, id, tmpl);
            store.count = store.count + 1;
        };
    }

    public entry fun set_race_tier_weights(account: &signer, common: u16, rare: u16, legendary: u16) acquires RaceStore {
        assert!(signer::address_of(account) == @mohayo, E_NOT_OWNER);
        let store = borrow_global_mut<RaceStore>(@mohayo);
        assert!((common as u64) + (rare as u64) + (legendary as u64) == 1000, E_RACE_WEIGHTS_BAD);
        store.race_tier_weights = vector[common, rare, legendary];
    }

    public entry fun set_race_pools(
        account: &signer,
        common: vector<u8>,
        rare: vector<u8>,
        legendary: vector<u8>,
    ) acquires RaceStore {
        assert!(signer::address_of(account) == @mohayo, E_NOT_OWNER);
        let store = borrow_global_mut<RaceStore>(@mohayo);
        store.common_races = common;
        store.rare_races = rare;
        store.legendary_races = legendary;
    }

    // ---- character creation ----

    /// GM mint: specific race, specific affixes, specific skills.
    public entry fun gm_mint(
        account: &signer,
        owner: address,
        class_id: u8,
        race: u8,
        affix_tiers: vector<u8>,
        skill_ids: vector<u64>,
    ) acquires ClassStore, RaceStore, AffixStore, CharacterStore {
        assert!(signer::address_of(account) == @mohayo, E_NOT_OWNER);
        let class = get_class(class_id);
        let race_def = get_race(race);
        let skills = merge_skills(class_id, &class, race, &race_def, &skill_ids);
        let (ability_bonuses, resource_types, mana_disc, ap_disc, ap_bon, mana_gain) = compute_affixes(&affix_tiers);
        let (hp, atk, mag, spd) = compute_stats(class_id, &class, race, &race_def, &ability_bonuses, 1);
        let store = borrow_global_mut<CharacterStore>(@mohayo);
        let id = store.count + 1;
        let c = Character {
            id, class_id, race, level: 1,
            hp, max_hp: hp, attack: atk, magic: mag, speed: spd,
            skill_ids: skills,
            ability_bonuses,
            resource_types,
            mana_discount: mana_disc,
            ap_discount: ap_disc,
            ap_bonus: ap_bon,
            mana_gain_bonus: mana_gain,
            room_id: 0,
        };
        table::add(&mut store.characters, id, c);
        store.count = id;
        if (!table::contains(&store.owner_chars, owner)) {
            table::add(&mut store.owner_chars, owner, vector::empty());
        };
        let list = table::borrow_mut(&mut store.owner_chars, owner);
        vector::push_back(list, id);
        event::emit(CharacterCreated { id, owner, class_id, race, level: 1 });
    }

    /// GM mint at arbitrary level.
    public entry fun gm_mint_at_level(
        account: &signer,
        owner: address,
        class_id: u8,
        race: u8,
        affix_tiers: vector<u8>,
        skill_ids: vector<u64>,
        level: u16,
    ) acquires ClassStore, RaceStore, AffixStore, CharacterStore {
        assert!(signer::address_of(account) == @mohayo, E_NOT_OWNER);
        let class = get_class(class_id);
        let race_def = get_race(race);
        let skills = merge_skills(class_id, &class, race, &race_def, &skill_ids);
        let (ability_bonuses, resource_types, mana_disc, ap_disc, ap_bon, mana_gain) = compute_affixes(&affix_tiers);
        let (hp, atk, mag, spd) = compute_stats(class_id, &class, race, &race_def, &ability_bonuses, level);
        let store = borrow_global_mut<CharacterStore>(@mohayo);
        let id = store.count + 1;
        let c = Character {
            id, class_id, race, level,
            hp, max_hp: hp, attack: atk, magic: mag, speed: spd,
            skill_ids: skills,
            ability_bonuses,
            resource_types,
            mana_discount: mana_disc,
            ap_discount: ap_disc,
            ap_bonus: ap_bon,
            mana_gain_bonus: mana_gain,
            room_id: 0,
        };
        table::add(&mut store.characters, id, c);
        store.count = id;
        if (!table::contains(&store.owner_chars, owner)) {
            table::add(&mut store.owner_chars, owner, vector::empty());
        };
        let list = table::borrow_mut(&mut store.owner_chars, owner);
        vector::push_back(list, id);
        event::emit(CharacterCreated { id, owner, class_id, race, level });
    }

    /// GM set level + recompute stats.
    public entry fun gm_set_level(account: &signer, char_id: u64, level: u16) acquires ClassStore, RaceStore, CharacterStore {
        assert!(signer::address_of(account) == @mohayo, E_NOT_OWNER);
        let store = borrow_global_mut<CharacterStore>(@mohayo);
        assert!(table::contains(&store.characters, char_id), E_NOT_FOUND);
        let c = table::borrow_mut(&mut store.characters, char_id);
        c.level = level;
        let class = get_class(c.class_id);
        let race_def = get_race(c.race);
        let (hp, atk, mag, spd) = compute_stats(c.class_id, &class, c.race, &race_def, &c.ability_bonuses, level);
        c.hp = hp;
        c.max_hp = hp;
        c.attack = atk;
        c.magic = mag;
        c.speed = spd;
    }

    // ---- room lock ----

    public entry fun set_in_room(account: &signer, char_id: u64, room_id: u64) acquires CharacterStore {
        assert!(signer::address_of(account) == @mohayo, E_NOT_OWNER);
        let store = borrow_global_mut<CharacterStore>(@mohayo);
        assert!(table::contains(&store.characters, char_id), E_NOT_FOUND);
        let c = table::borrow_mut(&mut store.characters, char_id);
        c.room_id = room_id;
    }

    // ---- view functions ----

    #[view]
    public fun get_class(id: u8): ClassDef acquires ClassStore {
        let store = borrow_global<ClassStore>(@mohayo);
        assert!(table::contains(&store.classes, id), E_UNKNOWN_CLASS);
        *table::borrow(&store.classes, id)
    }

    #[view]
    public fun get_race(id: u8): RaceDef acquires RaceStore {
        let store = borrow_global<RaceStore>(@mohayo);
        assert!(table::contains(&store.races, id), E_UNKNOWN_RACE);
        *table::borrow(&store.races, id)
    }

    #[view]
    public fun get_character(id: u64): (u8, u8, u16, u64, u64, u64, u64, u64, vector<u64>, u64) acquires CharacterStore {
        let store = borrow_global<CharacterStore>(@mohayo);
        assert!(table::contains(&store.characters, id), E_NOT_FOUND);
        let c = table::borrow(&store.characters, id);
        (c.class_id, c.race, c.level, c.hp, c.max_hp, c.attack, c.magic, c.speed, c.skill_ids, c.room_id)
    }

    #[view]
    public fun get_stats(id: u64): (u64, u64, u64, u64, u64) acquires CharacterStore {
        let store = borrow_global<CharacterStore>(@mohayo);
        assert!(table::contains(&store.characters, id), E_NOT_FOUND);
        let c = table::borrow(&store.characters, id);
        (c.hp, c.max_hp, c.attack, c.magic, c.speed)
    }

    #[view]
    public fun get_skill_ids(id: u64): vector<u64> acquires CharacterStore {
        let store = borrow_global<CharacterStore>(@mohayo);
        assert!(table::contains(&store.characters, id), E_NOT_FOUND);
        let c = table::borrow(&store.characters, id);
        c.skill_ids
    }

    #[view]
    public fun get_class_id(id: u64): u8 acquires CharacterStore {
        let store = borrow_global<CharacterStore>(@mohayo);
        assert!(table::contains(&store.characters, id), E_NOT_FOUND);
        let c = table::borrow(&store.characters, id);
        c.class_id
    }

    #[view]
    public fun get_room_id(id: u64): u64 acquires CharacterStore {
        let store = borrow_global<CharacterStore>(@mohayo);
        assert!(table::contains(&store.characters, id), E_NOT_FOUND);
        let c = table::borrow(&store.characters, id);
        c.room_id
    }

    #[view]
    public fun get_mana_discount(id: u64): u16 acquires CharacterStore {
        let store = borrow_global<CharacterStore>(@mohayo);
        assert!(table::contains(&store.characters, id), E_NOT_FOUND);
        let c = table::borrow(&store.characters, id);
        c.mana_discount
    }

    #[view]
    public fun get_ap_discount(id: u64): u16 acquires CharacterStore {
        let store = borrow_global<CharacterStore>(@mohayo);
        assert!(table::contains(&store.characters, id), E_NOT_FOUND);
        let c = table::borrow(&store.characters, id);
        c.ap_discount
    }

    #[view]
    public fun get_ap_bonus(id: u64): u16 acquires CharacterStore {
        let store = borrow_global<CharacterStore>(@mohayo);
        assert!(table::contains(&store.characters, id), E_NOT_FOUND);
        let c = table::borrow(&store.characters, id);
        c.ap_bonus
    }

    #[view]
    public fun get_mana_gain_bonus(id: u64): i64 acquires CharacterStore {
        let store = borrow_global<CharacterStore>(@mohayo);
        assert!(table::contains(&store.characters, id), E_NOT_FOUND);
        let c = table::borrow(&store.characters, id);
        c.mana_gain_bonus
    }

    #[view]
    public fun get_resource_types(id: u64): vector<u8> acquires CharacterStore {
        let store = borrow_global<CharacterStore>(@mohayo);
        assert!(table::contains(&store.characters, id), E_NOT_FOUND);
        let c = table::borrow(&store.characters, id);
        c.resource_types
    }

    // ---- internal ----

    fun compute_affixes(affix_tiers: &vector<u8>): (vector<u16>, vector<u8>, u16, u16, u16, i64) {
        let store = borrow_global<AffixStore>(@mohayo);
        let bonuses = vector[0u16, 0, 0, 0];
        let resource_types = vector<u8>[];
        let mut_i = 0;
        while (mut_i < vector::length(affix_tiers)) {
            let tier = *vector::borrow(affix_tiers, mut_i);
            if (tier >= 1 && tier <= 10 && table::contains(&store.templates, (mut_i as u8))) {
                let tmpl = table::borrow(&store.templates, (mut_i as u8));
                let val = *vector::borrow(types::affix_tier_values(tmpl), (tier - 1) as u64);
                let slot = types::affix_stat_type(tmpl) as u64;
                let cur = *vector::borrow(&bonuses, slot);
                let new_val = cur + val;
                *vector::borrow_mut(&mut bonuses, slot) = new_val;
            };
            mut_i = mut_i + 1;
        };
        let mut_j = vector::length(affix_tiers);
        let mut_k = 0;
        while (mut_k < MAX_RESOURCE_AFFIX && mut_j < vector::length(affix_tiers)) {
            let rtype = *vector::borrow(affix_tiers, mut_j);
            if (rtype <= 3) {
                vector::push_back(&mut resource_types, rtype);
            };
            mut_j = mut_j + 1;
            mut_k = mut_k + 1;
        };
        let mut_md: u16 = 0;
        let mut_ad: u16 = 0;
        let mut_ab: u16 = 0;
        let mut_mg: i64 = 0;
        let mut_r = 0;
        while (mut_r < vector::length(&resource_types)) {
            let rt = *vector::borrow(&resource_types, mut_r);
            if (rt == 0) { mut_ad = mut_ad + 1; }
            else if (rt == 1) { mut_ab = mut_ab + 1; }
            else if (rt == 2) { mut_md = mut_md + 1; }
            else if (rt == 3) { mut_mg = mut_mg + 1; };
            mut_r = mut_r + 1;
        };
        (bonuses, resource_types, mut_md, mut_ad, mut_ab, mut_mg)
    }

    fun compute_stats(
        class_id: u8, class: &ClassDef, race: u8, race_def: &RaceDef,
        ability_bonuses: &vector<u16>, level: u16,
    ): (u64, u64, u64, u64) {
        let hp_mod = types::class_def_hp_pct(class) + types::race_def_hp_mod(race_def) + (*vector::borrow(ability_bonuses, 0) as i64);
        let atk_mod = types::class_def_attack_pct(class) + *vector::borrow(types::race_def_stat_mods(race_def), 0) + (*vector::borrow(ability_bonuses, 1) as i64);
        let mag_mod = types::class_def_magic_pct(class) + *vector::borrow(types::race_def_stat_mods(race_def), 1) + (*vector::borrow(ability_bonuses, 2) as i64);
        let spd_mod = types::class_def_speed_pct(class) + *vector::borrow(types::race_def_stat_mods(race_def), 2) + (*vector::borrow(ability_bonuses, 3) as i64);
        let hp = calc_stat(100, hp_mod, level);
        let atk = calc_stat(10, atk_mod, level);
        let mag = calc_stat(10, mag_mod, level);
        let spd = calc_stat(10, spd_mod, level);
        (hp, atk, mag, spd)
    }

    fun calc_stat(base: u64, mod: i64, level: u16): u64 {
        let total_pct: i64 = 1000 + mod;
        if (total_pct <= 0) return 0;
        let result = (base as i64) * total_pct * (level as i64) / 1000;
        if (result <= 0) { 0 } else { (result as u64) }
    }

    fun merge_skills(
        class_id: u8, class: &ClassDef, race: u8, race_def: &RaceDef,
        self_select: &vector<u64>,
    ): vector<u64> {
        let skills = vector::empty<u64>();
        let class_skills = get_class_skill_ids_for(class_id);
        let mut_i = 0;
        while (mut_i < vector::length(&class_skills)) {
            vector::push_back(&mut skills, *vector::borrow(&class_skills, mut_i));
            mut_i = mut_i + 1;
        };
        let race_skill_id = types::race_def_skill_id(race_def);
        let race_skill_id2 = types::race_def_skill_id2(race_def);
        if (race_skill_id != 0) {
            vector::push_back(&mut skills, race_skill_id);
        };
        if (race_skill_id2 != 0) {
            vector::push_back(&mut skills, race_skill_id2);
        };
        let max_self = (types::class_def_skill_slots(class) as u64) + (types::race_def_self_select_bonus(race_def) as u64);
        let mut_j = 0;
        let mut_k = 0;
        while (mut_j < vector::length(self_select) && mut_k < max_self) {
            let sid = *vector::borrow(self_select, mut_j);
            if (!vector::contains(&skills, &sid)) {
                vector::push_back(&mut skills, sid);
                mut_k = mut_k + 1;
            };
            mut_j = mut_j + 1;
        };
        skills
    }

    fun get_class_skill_ids_for(class_id: u8): vector<u64> {
        use mohayo::skill_registry;
        skill_registry::get_class_skill_ids(class_id)
    }

    // ---- test helper ----

    #[test_only]
    public fun init_for_test(account: &signer) {
        let addr = signer::address_of(account);
        if (!exists<ClassStore>(addr)) {
            move_to(account, ClassStore { count: 0, classes: table::new() });
        };
        if (!exists<RaceStore>(addr)) {
            move_to(account, RaceStore {
                count: 0, races: table::new(),
                race_tier_weights: vector[850, 120, 30],
                common_races: vector[0, 1, 2, 3],
                rare_races: vector[4, 5],
                legendary_races: vector[6, 7],
            });
        };
        if (!exists<AffixStore>(addr)) {
            move_to(account, AffixStore { count: 0, templates: table::new() });
        };
        if (!exists<CharacterStore>(addr)) {
            move_to(account, CharacterStore { count: 0, characters: table::new(), owner_chars: table::new() });
        };
    }
}

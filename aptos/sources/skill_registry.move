/// Skill, AI, template, and dungeon registration.
/// Owns the `Registry` resource at @mohayo.
module mohayo::skill_registry {
    use aptos_std::table::{Self, Table};

    friend mohayo::engine;
    use std::signer;
    use std::vector;
    use mohayo::types::{Self, Skill, MonsterAI, EnemyTemplate, TableEntry, BattleConfig,
                         DungeonConfig, VariantEntry};

    const E_NOT_OWNER: u64 = 1;
    const E_SKILL_EXISTS: u64 = 2;
    const E_SKILL_NOT_FOUND: u64 = 3;
    const E_TEMPLATE_EXISTS: u64 = 5;
    const E_TABLE_EXISTS: u64 = 6;
    const E_DUNGEON_EXISTS: u64 = 7;
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
    const E_UNKNOWN_AI: u64 = 24;

    const MAX_SKILLS: u64 = 4096;
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
        pool_skills: vector<u64>,
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
            pool_skills: vector::empty(),
            next_room_id: 1,
        });
    }

    // ---- validation ----

    fun validate_skill(s: &Skill, allow_guar_next: bool) {
        let ef = types::skill_effects(s);
        assert!(vector::length(ef) <= types::MAX_SKILL_EFFECTS(), E_EFFECT_COUNT);
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
            types::skill_ammo_id(s),
            types::skill_ammo_cost(s),
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

    // ===================== GM 链上入口（交易参数只能是基本类型） =====================
    //
    // 下面这一层 `entry` 包装是「上线后 GM 不必重新发布合约就能改内容」的落地形态。
    //
    // 为什么需要它：Aptos 的 `entry fun` **不能收结构体参数**（交易参数只支持基本类型与
    // vector thereof），而 Skill / MonsterAI / EnemyTemplate / TableEntry 全是结构体 ——
    // 所以真正的注册逻辑只能是 `public fun`，光那样它就无法作为交易入口被调用。
    // 于是每个注册函数配一个吃**扁平原始字段**的 entry 包装，在包装里组装结构体再调内核。
    //
    // 语义分层（刻意如此）：`register_*` 内核保持**追加**（id 撞了就 abort）—— 注册层
    // 需要这个防重复保证。而 GM 入口走 `upsert_*`：已存在则原地覆盖。这正是「上线后调
    // 数值」需要的 —— 否则每改一个数都要重发整份 content_registration，且中途失败无法续跑。
    // `register_ai/template/table` 是 auto-id 追加，没有「同一条」的概念，只能追加。

    /// 注册一条技能（**追加语义**：id 已存在则 `E_SKILL_EXISTS`）。
    /// 供本模块内部与 `content_registration` 批量注册用 —— 注册层需要这个「防重复」保证。
    /// GM 改数值请用下面的 `gm_register_skill`（upsert 语义）。
    public fun register_skill(account: &signer, s: Skill) acquires Registry {
        let addr = signer::address_of(account);
        assert!(addr == @mohayo, E_NOT_OWNER);
        let r = borrow_global_mut<Registry>(@mohayo);
        validate_skill(&s, false);
        let req = types::skill_id(&s);
        let id = if (req == 0) { r.skill_count + 1 } else { req };
        assert!(id <= MAX_SKILLS, E_SKILL_CAP);
        assert!(!table::contains(&r.skills, id), E_SKILL_EXISTS);
        let new_s = reconstruct_skill_with_id(&s, id);
        table::add(&mut r.skills, id, new_s);
        if (id > r.skill_count) { r.skill_count = id; };
    }

    /// upsert 一条技能：已存在则原地覆盖，不存在才走追加。
    /// GM 改数值走这里 —— `register_skill` 的「id 已存在就 abort」是注册层需要的防重复，
    /// 但对「上线后调数值」这个场景是障碍（每次改都要重发整个 content_registration）。
    fun upsert_skill(account: &signer, s: Skill) acquires Registry {
        let addr = signer::address_of(account);
        assert!(addr == @mohayo, E_NOT_OWNER);
        let id = types::skill_id(&s);
        if (id == 0) {
            // 自动分配 id 的调用没有「同一条」的语义, 只能追加
            register_skill(account, s);
            return
        };
        let r = borrow_global_mut<Registry>(@mohayo);
        validate_skill(&s, false);
        assert!(id <= MAX_SKILLS, E_SKILL_CAP);
        let new_s = reconstruct_skill_with_id(&s, id);
        if (table::contains(&r.skills, id)) {
            *table::borrow_mut(&mut r.skills, id) = new_s;
        } else {
            table::add(&mut r.skills, id, new_s);
            if (id > r.skill_count) { r.skill_count = id; };
        };
    }

    /// upsert 一个职业的职业技能：技能本身 upsert，且不会往 class_skills 里重复追加 id。
    fun upsert_class_skill(account: &signer, s: Skill, class_id: u8) acquires Registry {
        let addr = signer::address_of(account);
        assert!(addr == @mohayo, E_NOT_OWNER);
        let id = types::skill_id(&s);
        if (id == 0) {
            register_class_skill(account, s, class_id);
            return
        };
        let already = table::contains(&borrow_global<Registry>(@mohayo).skills, id);
        upsert_skill(account, s);
        if (already) { return };   // 已在池里, 不重复登记到职业技能列表
        let r = borrow_global_mut<Registry>(@mohayo);
        if (!table::contains(&r.class_skills, class_id)) {
            table::add(&mut r.class_skills, class_id, vector::empty());
        };
        let list = table::borrow_mut(&mut r.class_skills, class_id);
        vector::push_back(list, id);
    }

    public fun register_class_skill(account: &signer, s: Skill, class_id: u8) acquires Registry {
        let addr = signer::address_of(account);
        assert!(addr == @mohayo, E_NOT_OWNER);
        let r = borrow_global_mut<Registry>(@mohayo);
        validate_skill(&s, true);
        let req = types::skill_id(&s);
        let id = if (req == 0) { r.skill_count + 1 } else { req };
        assert!(id <= MAX_SKILLS, E_SKILL_CAP);
        assert!(!table::contains(&r.skills, id), E_SKILL_EXISTS);
        let new_s = reconstruct_skill_with_id(&s, id);
        table::add(&mut r.skills, id, new_s);
        if (id > r.skill_count) { r.skill_count = id; };
        if (!table::contains(&r.class_skills, class_id)) {
            table::add(&mut r.class_skills, class_id, vector::empty());
        };
        let list = table::borrow_mut(&mut r.class_skills, class_id);
        vector::push_back(list, id);
    }

    /// 将已注册技能 id 登记进「自选池」白名单(content-design.md §5)。
    /// 红线: 玩家自选技能只允许从该集合挑选 —— 职业技/种族技/敌技一律不在池内。
    public fun add_pool_skill(account: &signer, id: u64) acquires Registry {
        let addr = signer::address_of(account);
        assert!(addr == @mohayo, E_NOT_OWNER);
        let r = borrow_global_mut<Registry>(@mohayo);
        assert!(table::contains(&r.skills, id), E_SKILL_NOT_FOUND);
        assert!(!vector::contains(&r.pool_skills, &id), E_SKILL_EXISTS);
        vector::push_back(&mut r.pool_skills, id);
    }

    #[view]
    public fun is_pool_skill(id: u64): bool acquires Registry {
        let r = borrow_global<Registry>(@mohayo);
        vector::contains(&r.pool_skills, &id)
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
        assert!(difficulty <= MAX_DUNGEONS, E_DUNGEON_EXISTS);
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

    // ===================== GM 链上入口（扁平参数 → 组装结构体 → 调内核） =====================

    /// GM 注册/覆写一条技能（无效果、无召唤的纯数值技能）。
    ///
    /// 常用场景：改 power / damage_cap / base_acc / 费用。带效果或召唤的技能用
    /// `gm_register_skill_full`。
    #[allow(unused_parameter)]
    public entry fun gm_register_skill(
        account: &signer,
        id: u64,
        kind: u8,
        ap_cost: u16,
        ap_gain: u16,
        ammo_id: u16,
        ammo_cost: u16,
        mana_cost: u64,
        hp_cost: u16,
        targeting: u8,
        weight_mode: u8,
        target_count: u8,
        power: u64,
        damage_cap: u64,
        base_acc: u16,
        flags: u8,
    ) acquires Registry {
        upsert_skill(account, types::make_skill(
            id, kind, ap_cost, ap_gain, ammo_id, ammo_cost, mana_cost, hp_cost,
            targeting, weight_mode, target_count, power, damage_cap, base_acc, flags,
            vector::empty(), types::make_summon_rule(0, 0, 0),
        ));
    }

    /// GM 注册/覆写一条带效果与召唤规则的技能。
    /// 效果与召唤规则用**并行原始向量**表达（交易参数不能是结构体 vector）。
    public entry fun gm_register_skill_full(
        account: &signer,
        id: u64,
        kind: u8,
        ap_cost: u16,
        ap_gain: u16,
        ammo_id: u16,
        ammo_cost: u16,
        mana_cost: u64,
        hp_cost: u16,
        targeting: u8,
        weight_mode: u8,
        target_count: u8,
        power: u64,
        damage_cap: u64,
        base_acc: u16,
        flags: u8,
        effect_ops: vector<u8>,
        effect_durations: vector<u8>,
        effect_magnitudes: vector<u16>,
        effect_scopes: vector<u8>,
        effect_probs: vector<u16>,
        summon_template_id: u64,
        summon_max_count: u8,
        summon_enemy_headroom: u8,
    ) acquires Registry {
        let n = vector::length(&effect_ops);
        assert!(
            n == vector::length(&effect_durations)
                && n == vector::length(&effect_magnitudes)
                && n == vector::length(&effect_scopes)
                && n == vector::length(&effect_probs),
            E_SKILL_CAP,
        );
        let fx = vector::empty<types::EffectSpec>();
        let i = 0;
        while (i < n) {
            vector::push_back(&mut fx, types::make_effect_spec(
                *vector::borrow(&effect_ops, i),
                *vector::borrow(&effect_durations, i),
                *vector::borrow(&effect_magnitudes, i),
                *vector::borrow(&effect_scopes, i),
                *vector::borrow(&effect_probs, i),
            ));
            i = i + 1;
        };
        upsert_skill(account, types::make_skill(
            id, kind, ap_cost, ap_gain, ammo_id, ammo_cost, mana_cost, hp_cost,
            targeting, weight_mode, target_count, power, damage_cap, base_acc, flags,
            fx, types::make_summon_rule(summon_template_id, summon_max_count, summon_enemy_headroom),
        ));
    }

    /// GM 把一条技能登记为某职业的职业技能。
    public entry fun gm_register_class_skill(
        account: &signer,
        class_id: u8,
        id: u64,
        kind: u8,
        ap_cost: u16,
        ap_gain: u16,
        mana_cost: u64,
        hp_cost: u16,
        targeting: u8,
        weight_mode: u8,
        target_count: u8,
        power: u64,
        damage_cap: u64,
        base_acc: u16,
        flags: u8,
    ) acquires Registry {
        upsert_class_skill(account, types::make_skill(
            id, kind, ap_cost, ap_gain, 0, 0, mana_cost, hp_cost,
            targeting, weight_mode, target_count, power, damage_cap, base_acc, flags,
            vector::empty(), types::make_summon_rule(0, 0, 0),
        ), class_id);
    }

    /// GM 追加一条怪物 AI（技能循环）。
    public entry fun gm_register_ai(
        account: &signer, skill_cycle: vector<u64>,
    ) acquires Registry {
        register_ai(account, types::make_monster_ai(skill_cycle, (vector::length(&skill_cycle) as u8)));
    }

    /// GM 追加一个敌人模板。`on_death_*` 为 0 表示无死亡召唤。
    public entry fun gm_register_template(
        account: &signer,
        ai_id: u64,
        threat: u8,
        max_hp: u64,
        power: u64,
        magic: u64,
        speed: u64,
        base_acc: u16,
        reward_min: u16,
        reward_max: u16,
        on_death_template_id: u64,
        on_death_count: u8,
        on_death_prob: u16,
    ) acquires Registry {
        register_template(account, types::make_enemy_template(
            ai_id, threat, max_hp, power, magic, speed, base_acc, reward_min, reward_max,
            types::make_on_death_spawn(on_death_template_id, on_death_count, on_death_prob),
        ));
    }

    /// GM 追加一张敌人构成表（模板 + 权重）。
    public entry fun gm_register_table(
        account: &signer, template_ids: vector<u64>, weights: vector<u16>,
    ) acquires Registry {
        let n = vector::length(&template_ids);
        assert!(n == vector::length(&weights), E_TABLE_CAP);
        let entries = vector::empty<TableEntry>();
        let i = 0;
        while (i < n) {
            vector::push_back(&mut entries, types::make_table_entry(
                *vector::borrow(&template_ids, i), *vector::borrow(&weights, i),
            ));
            i = i + 1;
        };
        register_table(account, entries);
    }

    /// GM 注册/覆写一座地下城的配置。
    public entry fun gm_set_dungeon(
        account: &signer,
        difficulty: u64,
        table_id: u64,
        enemy_count: u64,
        mana_per_turn: u64,
        entry_fee: u64,
        rescue_fee: u64,
        turn_interval: u64,
        battles: u8,
    ) acquires Registry {
        set_dungeon(account, difficulty, types::make_dungeon_config(
            table_id, enemy_count, mana_per_turn, entry_fee, rescue_fee, turn_interval, battles,
        ));
    }

    /// GM 覆写某难度的战斗序列（表 id + 每场敌人数）。
    public entry fun gm_set_dungeon_battles(
        account: &signer,
        difficulty: u64,
        table_ids: vector<u64>,
        enemy_counts: vector<u64>,
    ) acquires Registry {
        let n = vector::length(&table_ids);
        assert!(n == vector::length(&enemy_counts), E_BATTLE_CAP);
        let configs = vector::empty<BattleConfig>();
        let i = 0;
        while (i < n) {
            vector::push_back(&mut configs, types::make_battle_config(
                *vector::borrow(&table_ids, i), *vector::borrow(&enemy_counts, i),
            ));
            i = i + 1;
        };
        set_dungeon_battles(account, difficulty, configs);
    }

    /// GM 把技能加入自选池白名单（content-design §5 红线：只有池内技能能被玩家自选）。
    public entry fun gm_add_pool_skill(account: &signer, id: u64) acquires Registry {
        add_pool_skill(account, id);
    }

    /// 给某场战斗挂一个变体（§8.2）。`enemy_count = 0` 表示沿用这场战斗配置的敌人数，
    /// 大于 0 时该变体自己决定出几只（「督军+魔像+哨兵」这类混编靠它表达）。
    public entry fun add_battle_variant(
        account: &signer, difficulty: u64, battle_index: u64,
        table_id: u64, weight: u16, enemy_count: u64,
    ) acquires Registry {
        let addr = signer::address_of(account);
        assert!(addr == @mohayo, E_NOT_OWNER);
        let r = borrow_global_mut<Registry>(@mohayo);
        let key = difficulty * 100 + battle_index;
        if (!table::contains(&r.variants, key)) {
            table::add(&mut r.variants, key, vector::empty());
        };
        let list = table::borrow_mut(&mut r.variants, key);
        assert!(vector::length(list) < MAX_VARIANTS, E_VARIANT_CAP);
        vector::push_back(list, types::make_variant_entry(table_id, weight, enemy_count));
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

    /// 推进房号计数器。`public(friend)`: 只有引擎能分配房号(§2.6.15), 防外部模块刷号段。
    public(friend) fun consume_next_room_id(): u64 acquires Registry {
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

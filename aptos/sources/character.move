/// Character creation, stats, class/race management.
/// Owns `ClassStore`, `RaceStore`, `CharacterStore` at @mohayo.
module mohayo::character {
    use aptos_framework::event;
    use aptos_framework::randomness;
    use aptos_std::table::{Self, Table};
    use std::signer;
    use std::vector;
    use mohayo::types::{Self, ClassDef, RaceDef, AffixTemplate};
    use mohayo::skill_registry;
    use mohayo::rng;
    use mohayo::economy;

    friend mohayo::engine;
    friend mohayo::use_item;

    const E_NOT_OWNER: u64 = 1;
    const E_UNKNOWN_CLASS: u64 = 2;
    const E_UNKNOWN_RACE: u64 = 3;
    const E_SKILL_NOT_POOL: u64 = 4;
    const E_MAX_LEVEL: u64 = 11;
    const E_NOT_FOUND: u64 = 12;
    const E_IN_ROOM: u64 = 13;
    const E_RACE_WEIGHTS_BAD: u64 = 14;
    const E_AFFIX_TEMPLATE_CAP: u64 = 15;
    const E_SELF_TRANSFER: u64 = 16;
    const E_BAD_LEVELS: u64 = 17;
    // 20/21: 原先误用 16/17 与上面两个撞码(§2.6.11 复审修正)
    const E_CLASS_CAP: u64 = 20;
    const E_RACE_CAP: u64 = 21;
    const E_DEBTOR: u64 = 22;
    const E_CHAR_CAP: u64 = 23;

    const MAX_CLASSES: u64 = 32;
    const MAX_RACES: u64 = 16;
    const MAX_AFFIX_TEMPLATES: u64 = 64;
    /// 每账号角色数上限（§2.6.14 加的防御性上限：建号免费，不设上限会成为存储增长口子）
    const MAX_CHARS_PER_PLAYER: u64 = 10;
    const MAX_RESOURCE_AFFIX: u64 = 4;
    /// 能力词条槽位数(HP/ATK/MAG/SPD)：资源词条从该下标之后开始(§2.3)
    const ABILITY_SLOTS: u64 = 4;

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
        owner: address,
        class_id: u8,
        race: u8,
        level: u16,
        hp: u64,
        max_hp: u64,
        attack: u64,
        magic: u64,
        speed: u64,
        skill_ids: vector<u64>,
        self_select: vector<u64>, // 自选池技能(未合并, 命运骰子重掷需保留)
        ability_bonuses: vector<u16>,  // [HP, ATK, MAG, SPD]
        resource_types: vector<u8>,
        mana_discount: u16,
        ap_discount: u16,
        ap_bonus: u16,
        mana_gain_bonus: i64,
        room_id: u64,  // 0 = not in room
        // ---- 履历(§2.4): 不提供任何数值, 纯荣誉载体; 随角色转移保留 ----
        runs: u32,          // 参与的关卡次数
        clears: u32,        // 通关次数
        best_difficulty: u8, // 最高通关难度
    }

    struct CharacterStore has key {
        count: u64,
        characters: Table<u64, Character>,
        owner_chars: Table<address, vector<u64>>,
        /// 首角色重掷包(§2.3/§7.6): playerId 级绑定计数器, **非道具、不可转移**。
        /// 一次性福利: 首号创建时置 3; 卖掉/删除首角色不返还、不重生(用 created_before 判定首号)。
        free_rerolls: Table<address, u8>,
        created_before: Table<address, bool>,
    }

    // ---- events ----

    #[event]
    struct CharacterCreated has drop, store { id: u64, owner: address, class_id: u8, race: u8, level: u16 }
    #[event]
    struct LevelUpgraded has drop, store { id: u64, level: u16, cost: u64 }
    #[event]
    struct CharacterTransferred has drop, store { id: u64, from: address, to: address, level_reset_to: u16 }

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
        move_to(account, CharacterStore {
            count: 0, characters: table::new(), owner_chars: table::new(),
            free_rerolls: table::new(), created_before: table::new(),
        });
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

    /// 建号内核：`gm_mint` / `gm_mint_at_level` / 玩家入口 `create_character` 共用。
    /// 返回新角色 id。`self_select` 是玩家从自选池挑的技能（会过白名单与槽位截断），
    /// 原样存进 `Character.self_select` 以便重掷时复用。
    fun mint_character(
        owner: address, class_id: u8, race: u8,
        affix_tiers: &vector<u8>, self_select: &vector<u64>, level: u16,
    ): u64 acquires ClassStore, RaceStore, AffixStore, CharacterStore {
        let class = get_class(class_id);
        let race_def = get_race(race);
        let skills = merge_skills(class_id, &class, race, &race_def, self_select);
        let (ability_bonuses, resource_types, mana_disc, ap_disc, ap_bon, mana_gain) = compute_affixes(affix_tiers);
        let (hp, atk, mag, spd) = compute_stats(class_id, &class, race, &race_def, &ability_bonuses, level);
        let store = borrow_global_mut<CharacterStore>(@mohayo);
        let id = store.count + 1;
        let c = Character {
            id, owner, class_id, race, level,
            hp, max_hp: hp, attack: atk, magic: mag, speed: spd,
            skill_ids: skills,
            self_select: *self_select,
            ability_bonuses,
            resource_types,
            mana_discount: mana_disc,
            ap_discount: ap_disc,
            ap_bonus: ap_bon,
            mana_gain_bonus: mana_gain,
            room_id: 0,
            runs: 0, clears: 0, best_difficulty: 0,
        };
        table::add(&mut store.characters, id, c);
        store.count = id;
        if (!table::contains(&store.owner_chars, owner)) {
            table::add(&mut store.owner_chars, owner, vector::empty());
        };
        vector::push_back(table::borrow_mut(&mut store.owner_chars, owner), id);
        event::emit(CharacterCreated { id, owner, class_id, race, level });
        id
    }

    /// 玩家建号入口（§2.2 / §2.5.1 / §2.6）。
    /// 玩家**只能自主决定两件事**：职业（`class_id = 0` 即「无职业」路线）与**自选池技能**
    /// （§2.6 创建流程：职业 1 个 / 无职业 3 个，人类各 +2；槽位外的会被截断）。
    /// 种族与词条由链上随机掷出。首次建号额外发放**启动资金**与 3 次免费重掷
    /// （`created_before` 判定，按账号只发一次）。
    /// 私有 `entry` + `#[randomness]`：掷骰用协议随机数，玩家无法预先挑选结果(§2.6.14)。
    #[randomness]
    entry fun create_character(
        account: &signer, class_id: u8, skill_ids: vector<u64>,
    ) acquires ClassStore, RaceStore, AffixStore, CharacterStore {
        do_create_character(account, class_id, skill_ids, randomness::u64_integer());
    }

    /// 建号（测试/仿真入口）：注入种子，便于复现固定的种族/词条组合。
    #[test_only]
    public entry fun create_character_test(
        account: &signer, class_id: u8, skill_ids: vector<u64>, seed: u64,
    ) acquires ClassStore, RaceStore, AffixStore, CharacterStore {
        do_create_character(account, class_id, skill_ids, seed);
    }

    fun do_create_character(
        account: &signer, class_id: u8, skill_ids: vector<u64>, seed: u64,
    ) acquires ClassStore, RaceStore, AffixStore, CharacterStore {
        let owner = signer::address_of(account);
        assert!(!economy::is_debtor(owner), E_DEBTOR);                        // §6.3 负债者不得创建角色
        assert!(owned_character_count(owner) < MAX_CHARS_PER_PLAYER, E_CHAR_CAP);
        let r = rng::new(seed);
        let race = roll_random_race(&mut r);
        let tiers = roll_random_affix_tiers(&mut r);
        let _id = mint_character(owner, class_id, race, &tiers, &skill_ids, 1);
        // 首号福利：启动资金（免费重掷在下面同一个判定里发）
        if (grant_first_char_bonus(owner)) {
            economy::credit(owner, economy::STARTING_GRANT());
        };
    }

    /// 该账号当前持有的角色数
    fun owned_character_count(owner: address): u64 acquires CharacterStore {
        let store = borrow_global<CharacterStore>(@mohayo);
        if (!table::contains(&store.owner_chars, owner)) { return 0 };
        vector::length(table::borrow(&store.owner_chars, owner))
    }

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
        let _id = mint_character(owner, class_id, race, &affix_tiers, &skill_ids, 1);
        let _first = grant_first_char_bonus(owner);
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
        let _id = mint_character(owner, class_id, race, &affix_tiers, &skill_ids, level);
        let _first = grant_first_char_bonus(owner);
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

    // ---- 重掷 / 重建(道具: 命运骰子 / 重生卷轴, content-design §7) ----

    /// 用 rng 掷出随机种族: 先按三层稀有度权重抽层, 再在层内均匀抽种族(读 RaceStore 池)。
    public fun roll_random_race(rng: &mut mohayo::rng::Rng): u8 acquires RaceStore {
        let store = borrow_global<RaceStore>(@mohayo);
        let w0 = (*vector::borrow(&store.race_tier_weights, 0)) as u64;
        let w1 = (*vector::borrow(&store.race_tier_weights, 1)) as u64;
        let w2 = (*vector::borrow(&store.race_tier_weights, 2)) as u64;
        let roll = rng::below(rng, w0 + w1 + w2);
        if (roll < w0) {
            pick_race(rng, &store.common_races)
        } else if (roll < w0 + w1) {
            pick_race(rng, &store.rare_races)
        } else {
            pick_race(rng, &store.legendary_races)
        }
    }

    fun pick_race(rng: &mut mohayo::rng::Rng, pool: &vector<u8>): u8 {
        let pick = rng::below(rng, vector::length(pool));
        *vector::borrow(pool, pick)
    }

    /// 用 rng 掷出词条档位+资源词条: 4 项能力各掷 1..10 档, 再均匀掷 0..4 条资源词条(类型 0..3)。
    public fun roll_random_affix_tiers(rng: &mut mohayo::rng::Rng): vector<u8> {
        let tiers = vector<u8>[];
        let i = 0;
        while (i < 4) {
            let t = rng::below(rng, 10) + 1;
            vector::push_back(&mut tiers, (t as u8));
            i = i + 1;
        };
        let nres = (rng::below(rng, 5) as u8); // 0..4 条资源词条
        let r = 0;
        while (r < nres) {
            let rt = rng::below(rng, 4);
            vector::push_back(&mut tiers, (rt as u8));
            r = r + 1;
        };
        tiers
    }

    /// 命运骰子: 换种族+词条, 保留职业/等级/已选自选技; 仅关卡外(room_id==0)可用。
    /// `public(friend)`: 必须由 `use_item` 核销道具/免费重掷后调用, 不可被任意模块直接白嫖(§2.6.11)。
    public(friend) fun reroll_character(char_id: u64, new_race: u8, new_affix_tiers: vector<u8>)
    acquires ClassStore, RaceStore, AffixStore, CharacterStore {
        let store = borrow_global_mut<CharacterStore>(@mohayo);
        assert!(table::contains(&store.characters, char_id), E_NOT_FOUND);
        let c = table::borrow_mut(&mut store.characters, char_id);
        assert!(c.room_id == 0, E_IN_ROOM);
        let class = get_class(c.class_id);
        let race_def = get_race(new_race);
        // 仅重掷词条(能力+资源), 自选技列表保留
        let (ability_bonuses, resource_types, mana_disc, ap_disc, ap_bon, mana_gain) = compute_affixes(&new_affix_tiers);
        let skills = merge_skills(c.class_id, &class, new_race, &race_def, &c.self_select);
        let (hp, atk, mag, spd) = compute_stats(c.class_id, &class, new_race, &race_def, &ability_bonuses, c.level);
        c.race = new_race;
        c.skill_ids = skills;
        c.ability_bonuses = ability_bonuses;
        c.resource_types = resource_types;
        c.mana_discount = mana_disc;
        c.ap_discount = ap_disc;
        c.ap_bonus = ap_bon;
        c.mana_gain_bonus = mana_gain;
        c.hp = hp;
        c.max_hp = hp;
        c.attack = atk;
        c.magic = mag;
        c.speed = spd;
    }

    /// 重生卷轴: 整体重建 —— 换种族+词条, 等级重置为 1, 自选技清空(技能=职业技+新种族技); 仅关卡外可用。
    /// `public(friend)`: 必须由 `use_item` 核销道具后调用(§2.6.11)。
    public(friend) fun rebuild_character(char_id: u64, new_race: u8, new_affix_tiers: vector<u8>)
    acquires ClassStore, RaceStore, AffixStore, CharacterStore {
        let store = borrow_global_mut<CharacterStore>(@mohayo);
        assert!(table::contains(&store.characters, char_id), E_NOT_FOUND);
        let c = table::borrow_mut(&mut store.characters, char_id);
        assert!(c.room_id == 0, E_IN_ROOM);
        let class = get_class(c.class_id);
        let race_def = get_race(new_race);
        let (ability_bonuses, resource_types, mana_disc, ap_disc, ap_bon, mana_gain) = compute_affixes(&new_affix_tiers);
        let skills = merge_skills(c.class_id, &class, new_race, &race_def, &vector::empty<u64>());
        let (hp, atk, mag, spd) = compute_stats(c.class_id, &class, new_race, &race_def, &ability_bonuses, 1);
        c.race = new_race;
        c.level = 1;
        c.skill_ids = skills;
        c.self_select = vector::empty();
        c.ability_bonuses = ability_bonuses;
        c.resource_types = resource_types;
        c.mana_discount = mana_disc;
        c.ap_discount = ap_disc;
        c.ap_bonus = ap_bon;
        c.mana_gain_bonus = mana_gain;
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

    /// 首角色重掷包(§2.3/§7.6): 每个 playerId 只在**首次创建角色**时获得 3 次免费重掷,
    /// 以 created_before 判定(卖掉首号再建也拿不到 —— 一次性福利, 防止「卖号→再建」循环领取)。
    /// 返回 true 表示这次正是首角色（调用方据此发放启动资金）。
    fun grant_first_char_bonus(owner: address): bool acquires CharacterStore {
        let store = borrow_global_mut<CharacterStore>(@mohayo);
        if (table::contains(&store.created_before, owner)) { return false };
        table::add(&mut store.created_before, owner, true);
        table::add(&mut store.free_rerolls, owner, 3u8);
        true
    }

    /// 重掷入口的资源检查(§2.3 二选一): 先扣免费重掷计数器, 没有则由调用方核销一枚命运骰子。
    public(friend) fun try_consume_free_reroll(owner: address): bool acquires CharacterStore {
        let store = borrow_global_mut<CharacterStore>(@mohayo);
        if (!table::contains(&store.free_rerolls, owner)) { return false; };
        let n = table::borrow_mut(&mut store.free_rerolls, owner);
        if (*n == 0) { return false; };
        *n = *n - 1;
        true
    }

    // ---- 升级 / 转移 / 履历（§2.4 / §7.4） ----

    /// 升级（§2.4）：**只消耗游戏币、无其他门槛**；不改变已锁定的自选技与词条。
    /// 费用 = Σ(100 × 新等级)（初值，数值层可调）。**余额不足（含负债者）直接拒绝**（§6.3）。
    public entry fun upgrade_level(account: &signer, char_id: u64, levels: u16)
    acquires CharacterStore, ClassStore, RaceStore {
        let owner = signer::address_of(account);
        assert!(levels > 0, E_BAD_LEVELS);
        let (class_id, race, cur_level, ability_bonuses) = {
            let store = borrow_global<CharacterStore>(@mohayo);
            assert!(table::contains(&store.characters, char_id), E_NOT_FOUND);
            let c = table::borrow(&store.characters, char_id);
            assert!(c.owner == owner, E_NOT_OWNER);
            (c.class_id, c.race, (c.level as u64), c.ability_bonuses)
        };
        let target = cur_level + (levels as u64);
        assert!(target <= types::MAX_LEVEL(), E_MAX_LEVEL);
        let cost = 100 * (cur_level + 1 + target) * (levels as u64) / 2;
        economy::charge_entry(owner, cost); // 严格扣款: 负债者不得升级
        let class = get_class(class_id);
        let race_def = get_race(race);
        let (hp, atk, mag, spd) = compute_stats(class_id, &class, race, &race_def, &ability_bonuses, (target as u16));
        let store = borrow_global_mut<CharacterStore>(@mohayo);
        let c = table::borrow_mut(&mut store.characters, char_id);
        c.level = (target as u16);
        c.hp = hp;
        c.max_hp = hp;
        c.attack = atk;
        c.magic = mag;
        c.speed = spd;
        event::emit(LevelUpgraded { id: char_id, level: (target as u16), cost });
    }

    /// 角色转移（§7.4，与价格无关的规则在转移函数内 100% 强制）：
    /// ① **等级重置为 1**（属性同步重算）；② **关卡内（未结算离场）禁止转移**；
    /// ③ 词条/种族/职业/自选技/履历随角色完整转移。不可强制的只有按成交价抽税（本设计不依赖）。
    public entry fun transfer_character(account: &signer, char_id: u64, to: address)
    acquires CharacterStore, ClassStore, RaceStore {
        let owner = signer::address_of(account);
        assert!(to != owner, E_SELF_TRANSFER);
        let (class_id, race, ability_bonuses) = {
            let store = borrow_global<CharacterStore>(@mohayo);
            assert!(table::contains(&store.characters, char_id), E_NOT_FOUND);
            let c = table::borrow(&store.characters, char_id);
            assert!(c.owner == owner, E_NOT_OWNER);
            assert!(c.room_id == 0, E_IN_ROOM);
            (c.class_id, c.race, c.ability_bonuses)
        };
        let class = get_class(class_id);
        let race_def = get_race(race);
        let (hp, atk, mag, spd) = compute_stats(class_id, &class, race, &race_def, &ability_bonuses, 1);
        let store = borrow_global_mut<CharacterStore>(@mohayo);
        remove_from_owner_list(store, owner, char_id);
        {
            let c = table::borrow_mut(&mut store.characters, char_id);
            c.owner = to;
            c.level = 1;
            c.hp = hp;
            c.max_hp = hp;
            c.attack = atk;
            c.magic = mag;
            c.speed = spd;
        };
        if (!table::contains(&store.owner_chars, to)) {
            table::add(&mut store.owner_chars, to, vector::empty());
        };
        let list = table::borrow_mut(&mut store.owner_chars, to);
        vector::push_back(list, char_id);
        event::emit(CharacterTransferred { id: char_id, from: owner, to, level_reset_to: 1 });
    }

    fun remove_from_owner_list(store: &mut CharacterStore, owner: address, char_id: u64) {
        if (!table::contains(&store.owner_chars, owner)) { return; };
        let list = table::borrow_mut(&mut store.owner_chars, owner);
        let n = vector::length(list);
        let i = 0;
        while (i < n) {
            if (*vector::borrow(list, i) == char_id) {
                vector::remove(list, i);
                return;
            };
            i = i + 1;
        };
    }

    /// 引擎回调：标记角色当前所在房间（0 = 不在任何房间）。§7.4「战斗中禁止转移」的依据。
    public(friend) fun lock_room(char_id: u64, room_id: u64) acquires CharacterStore {
        let store = borrow_global_mut<CharacterStore>(@mohayo);
        if (!table::contains(&store.characters, char_id)) { return; };
        let c = table::borrow_mut(&mut store.characters, char_id);
        c.room_id = room_id;
    }

    /// 引擎回调：结算时记一次履历（§2.4 纯荣誉、无数值）。
    public(friend) fun record_run(char_id: u64, cleared: bool, difficulty: u8) acquires CharacterStore {
        let store = borrow_global_mut<CharacterStore>(@mohayo);
        if (!table::contains(&store.characters, char_id)) { return; };
        let c = table::borrow_mut(&mut store.characters, char_id);
        c.runs = c.runs + 1;
        if (cleared) {
            c.clears = c.clears + 1;
            if (difficulty > c.best_difficulty) { c.best_difficulty = difficulty; };
        };
    }

    /// 引擎回调：建 Member 所需的角色派生字段 —— class_id + 四项资源词条加成
    /// (AP消耗−1 / AP产量+1 / 魔素消耗−1 / 魔素产量+1)，一次读出。
    /// §2.6.11 复审修正：此前 `join_room_as_char` 把这四项硬写成 0，资源词条即使解析出来也到不了 Member。
    public(friend) fun member_fields(char_id: u64): (u8, u16, u16, u16, i64) acquires CharacterStore {
        let store = borrow_global<CharacterStore>(@mohayo);
        if (!table::contains(&store.characters, char_id)) { return (0, 0, 0, 0, 0) };
        let c = table::borrow(&store.characters, char_id);
        (c.class_id, c.mana_discount, c.ap_discount, c.ap_bonus, c.mana_gain_bonus)
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
    public fun get_self_select(id: u64): vector<u64> acquires CharacterStore {
        let store = borrow_global<CharacterStore>(@mohayo);
        assert!(table::contains(&store.characters, id), E_NOT_FOUND);
        let c = table::borrow(&store.characters, id);
        c.self_select
    }

    #[view]
    public fun char_owner(id: u64): address acquires CharacterStore {
        let store = borrow_global<CharacterStore>(@mohayo);
        assert!(table::contains(&store.characters, id), E_NOT_FOUND);
        table::borrow(&store.characters, id).owner
    }

    /// Returns true iff `char_id` owns skill `sid` (权威源 = Character.skill_ids, 角色自身存储)。
    #[view]
    public fun char_owns_skill(char_id: u64, sid: u64): bool acquires CharacterStore {
        let store = borrow_global<CharacterStore>(@mohayo);
        if (!table::contains(&store.characters, char_id)) return false;
        let c = table::borrow(&store.characters, char_id);
        vector::contains(&c.skill_ids, &sid)
    }

    /// Latest char id created by `owner` (0 if none). 测试/工具链用: 模拟器取 mint 出的角色。
    #[view]
    public fun owner_latest_char(owner: address): u64 acquires CharacterStore {
        let store = borrow_global<CharacterStore>(@mohayo);
        if (!table::contains(&store.owner_chars, owner)) return 0;
        let list = table::borrow(&store.owner_chars, owner);
        if (vector::length(list) == 0) { 0 } else { *vector::borrow(list, vector::length(list) - 1) }
    }

    #[view]
    public fun get_class_id(id: u64): u8 acquires CharacterStore {
        let store = borrow_global<CharacterStore>(@mohayo);
        assert!(table::contains(&store.characters, id), E_NOT_FOUND);
        let c = table::borrow(&store.characters, id);
        c.class_id
    }

    /// 该 playerId 剩余免费重掷次数(§2.3)
    #[view]
    public fun free_rerolls(owner: address): u8 acquires CharacterStore {
        let store = borrow_global<CharacterStore>(@mohayo);
        if (!table::contains(&store.free_rerolls, owner)) { return 0; };
        *table::borrow(&store.free_rerolls, owner)
    }

    #[view]
    public fun get_level(id: u64): u16 acquires CharacterStore {
        let store = borrow_global<CharacterStore>(@mohayo);
        assert!(table::contains(&store.characters, id), E_NOT_FOUND);
        table::borrow(&store.characters, id).level
    }

    /// 履历（§2.4）：(参与次数, 通关次数, 最高通关难度)
    #[view]
    public fun get_history(id: u64): (u32, u32, u8) acquires CharacterStore {
        let store = borrow_global<CharacterStore>(@mohayo);
        assert!(table::contains(&store.characters, id), E_NOT_FOUND);
        let c = table::borrow(&store.characters, id);
        (c.runs, c.clears, c.best_difficulty)
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
        // 资源词条接在 4 个能力槽之后(§2.3)。此前初值误写成 vector::length(affix_tiers)
        // 导致条件恒假、四项资源加成恒为 0(§2.6.11 复审修正)。
        let mut_j = ABILITY_SLOTS;
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
        let hp = calc_stat(types::BASE_HP(), hp_mod, level);
        let atk = calc_stat(types::BASE_ATTACK(), atk_mod, level);
        let mag = calc_stat(types::BASE_MAGIC(), mag_mod, level);
        let spd = calc_stat(types::BASE_SPEED(), spd_mod, level);
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
        // No auto-granted base skills: every skill must come from the chosen
        // class, the character's race, or the shared pool picked at creation.
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
        // 红线: 自选池技能必须是 skill_registry 登记的自选池白名单(content-design §5)。
        // 基础技/占位/职业技/种族技/敌技一律拒绝 —— 玩家的技能只来自 职业/种族/自选池 三来源。
        let mut_p = 0;
        while (mut_p < vector::length(self_select)) {
            let sid = *vector::borrow(self_select, mut_p);
            assert!(skill_registry::is_pool_skill(sid), E_SKILL_NOT_POOL);
            mut_p = mut_p + 1;
        };
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
            move_to(account, CharacterStore {
            count: 0, characters: table::new(), owner_chars: table::new(),
            free_rerolls: table::new(), created_before: table::new(),
        });
        };
    }
}

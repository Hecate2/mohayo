/// 道具层（数据驱动，2026-09-02 架构复审定案）。
///
/// 设计要点：
/// 1. 每种道具 = item_type id + ItemDef 记录(name/group/combat_usable/effect_kind/effect_value/decimals)，
///    不引入 per-type struct —— GM 的常驻 entry `register_item` 可在**上线后动态添加新道具**
///    （一笔注册交易，零代码发布），无需发布新模块。
/// 2. fungible token 语义：Vault 中每个 item_type 一张独立的 address→u128 同质账本
///    （可拆散、可转移）；decimals=18 约定：1 整份 = ONE = 10^18 最小单位
///    （平时按整份消耗，允许拆散交易；u128 容量充足）。
/// 3. 每种道具标记「战斗中可使用 / 不可使用」；key-value 存储并按道具类型分组(group)。
/// 4. 战斗内使用道具 = 以特殊技能 id（ITEM_SKILL_BASE + item_type）排进技能计划队列，
///    占用 1 回合行动位（technical-design §2.6 道具入队定案）；弹尽/无库存 → 空过不炸交易。
/// 5. 掉落表（DropStore）：按难度登记「条目 + 权重」，通关/全员逃离时对每个存活者掷一次；
///    GM 常驻入口可动态调整，数值层不必改代码（gameplay-design §7.2）。
module mohayo::item {
    use std::signer;
    use std::table::{Self, Table};
    use std::vector;
    use mohayo::rng;

    // 余额写入口只对引擎与关卡外编排模块开放(§2.6.11 复审): 防止任意模块凭空铸道具/销毁他人道具。
    friend mohayo::engine;
    friend mohayo::use_item;

    // ===================== 道具类型 id（按组留区间: 组内小步长, 同组可扩展） =====================
    public const ITEM_LEAD_BULLET: u64 = 1;     // 铅弹(火枪左轮弹药, 战斗不可直接使用)
    public const ITEM_DRAGON_BULLET: u64 = 2;   // 龙击弹(火枪龙击弹弹药, 同上)
    public const ITEM_MANA_FIREWORK: u64 = 100; // 魔素礼花(战斗中使用: 大幅增加房间魔素)
    // ---- 战斗消耗品 (content-design §7 恢复/干扰类) ----
    public const ITEM_HEALING_POTION: u64 = 101;  // 疗伤药水(小额治疗, 占行动位)
    public const ITEM_SPRING_OF_LIFE: u64 = 102;  // 生命之泉(大额治疗, 仅掉落)
    public const ITEM_SMOKE_BOMB: u64 = 103;      // 烟幕弹(降全体命中率, 敌我双方, 占行动位)
    public const ITEM_PHOENIX_FEATHER: u64 = 104; // 不死鸟之羽(复活本场被击败的一名队友, 占行动位)
    // ---- 角色类(重生/重掷, 仅掉落, 关卡外使用) ----
    public const ITEM_REBIRTH_SCROLL: u64 = 200;  // 重生卷轴(整体重建角色)
    public const ITEM_DICE_OF_FATE: u64 = 201;    // 命运骰子(种族+词条全重掷)
    // ---- 入场类 ----
    public const ITEM_DAILY_TICKET: u64 = 300;    // 每日挑战券(每日免费领取, 绑定不可交易)
    public const ITEM_CHALLENGE_TICKET: u64 = 301; // 挑战券(无视当日入场次数限制, 可交易)

    // ===================== 分组 =====================
    public const GROUP_AMMO: u8 = 1;              // 弹药(战斗中不可直接使用, 技能自动消耗)
    public const GROUP_COMBAT_CONSUMABLE: u8 = 2; // 战斗消耗品(可入计划队列)
    public const GROUP_CHARACTER_META: u8 = 4;    // 角色类(重生/重掷, 关卡外)
    public const GROUP_ENTRY: u8 = 5;             // 入场类(挑战券/每日挑战券)

    // ===================== 效果种类(战斗内) =====================
    public const EFFECT_NONE: u8 = 0;
    public const EFFECT_MANA_BOOST: u8 = 1;       // 增加房间魔素池(effect_value 为增量)
    public const EFFECT_HEAL: u8 = 2;             // 治疗我方一名(取血量亏空最高的存活者, effect_value 为治疗量)
    public const EFFECT_SMOKE_ALL: u8 = 3;        // 降场上全体(敌我双方)命中率(effect_value = ACC_DOWN 千分比)
    public const EFFECT_REVIVE: u8 = 4;           // 复活本场一名被击败的队友(effect_value = 复活后 HP)

    // ===================== 计划队列中的道具技能段 =====================
    /// 道具占计划队列的技能 id 段: ITEM_SKILL_BASE + item_type (0xF000=61440, 文档 §2.6 保留段)
    public const ITEM_SKILL_BASE: u64 = 61440;

    /// 1 整份 = 10^18 最小单位 (decimals=18)
    public const ONE: u128 = 1000000000000000000;

    const E_NOT_OWNER: u64 = 1;
    const E_NOT_FOUND: u64 = 3;
    const E_NO_ITEM: u64 = 4;
    const E_ZERO: u64 = 5;
    const E_BOUND: u64 = 6;
    const E_BAD_TABLE: u64 = 7;

    /// 道具定义(key-value, 按类型分组)
    struct ItemDef has copy, drop, store {
        name: vector<u8>,
        group: u8,
        combat_usable: bool,
        effect_kind: u8,
        effect_value: u64,
        decimals: u8,
        bound: bool, // 绑定道具(不可转移, 如每日挑战券) —— technical-design §2.5 +10 绑定标志
    }

    struct DefStore has key {
        defs: Table<u64, ItemDef>,
    }

    /// vault: item_type → (address → raw 余额, u128)
    struct Vault has key {
        balances: Table<u64, Table<address, u128>>,
    }

    /// 掉落表条目：item_type = 0 表示「空手而归」（用一个条目表达"没掉东西"的权重）
    struct DropEntry has copy, drop, store {
        item_type: u64,
        weight: u16,
        amount: u64,
    }

    /// difficulty → 掉落表（通关/全员逃离时结算）
    struct DropStore has key {
        tables: Table<u64, vector<DropEntry>>,
    }

    // ===================== 初始化 =====================
    fun init_module(account: &signer) {
        move_to(account, DefStore { defs: table::new() });
        move_to(account, Vault { balances: table::new() });
        move_to(account, DropStore { tables: table::new() });
    }

    #[test_only]
    public fun init_for_test(account: &signer) {
        if (!exists<DefStore>(@mohayo)) { init_module(account); };
    }

    // ===================== 掉落表（数据驱动，GM 可随时调整） =====================

    /// 登记/覆写某难度的掉落表。weight 为千分比权重（同一张表内相对比例，无需凑满 1000）。
    /// item_type = 0 的条目代表「没掉东西」。
    ///
    /// 参数用**三条等长的并行原始向量**（entry 交易的参数不能是结构体），
    /// 因此上线后 GM 仍可一笔交易动态调整掉落，无需发布新代码。
    public entry fun register_drop_table(
        account: &signer, difficulty: u64,
        item_types: vector<u64>, weights: vector<u16>, amounts: vector<u64>,
    ) acquires DropStore {
        assert!(signer::address_of(account) == @mohayo, E_NOT_OWNER);
        let n = vector::length(&item_types);
        assert!(n == vector::length(&weights) && n == vector::length(&amounts), E_BAD_TABLE);
        if (!exists<DropStore>(@mohayo)) { init_module(account); };
        let entries = vector::empty<DropEntry>();
        let i = 0;
        while (i < n) {
            vector::push_back(&mut entries, DropEntry {
                item_type: *vector::borrow(&item_types, i),
                weight: *vector::borrow(&weights, i),
                amount: *vector::borrow(&amounts, i),
            });
            i = i + 1;
        };
        let ds = borrow_global_mut<DropStore>(@mohayo);
        if (table::contains(&ds.tables, difficulty)) {
            *table::borrow_mut(&mut ds.tables, difficulty) = entries;
        } else {
            table::add(&mut ds.tables, difficulty, entries);
        };
    }

    /// 按难度掉落表掷一次（确定性：seed 由调用方提供）。
    /// 返回 (item_type, amount)；item_type = 0 表示没掉东西；无表 → (0, 0)。
    public fun pick_drop(difficulty: u64, seed: u64): (u64, u64) acquires DropStore {
        if (!exists<DropStore>(@mohayo)) { return (0, 0); };
        let ds = borrow_global<DropStore>(@mohayo);
        if (!table::contains(&ds.tables, difficulty)) { return (0, 0); };
        let entries = table::borrow(&ds.tables, difficulty);
        let n = vector::length(entries);
        let total: u64 = 0;
        let i = 0;
        while (i < n) {
            total = total + (vector::borrow(entries, i).weight as u64);
            i = i + 1;
        };
        if (total == 0) { return (0, 0); };
        let r = rng::new(seed);
        let roll = rng::below(&mut r, total);
        let acc: u64 = 0;
        let j = 0;
        while (j < n) {
            let e = vector::borrow(entries, j);
            let w = (e.weight as u64);
            if (roll < acc + w) { return (e.item_type, e.amount); };
            acc = acc + w;
            j = j + 1;
        };
        (0, 0)
    }

    // ===================== 注册(数据驱动: 上线后亦可动态添加新道具) =====================
    /// GM 注册/更新一种道具定义。新增道具 = 一笔此交易, 无需发布新代码。
    /// decimals 约定 18(展示用; 1 整份 = ONE = 10^18 raw)。
    public entry fun register_item(
        account: &signer,
        item_type: u64,
        name: vector<u8>,
        group: u8,
        combat_usable: bool,
        effect_kind: u8,
        effect_value: u64,
        decimals: u8,
        bound: bool,
    ) acquires DefStore, Vault {
        assert!(signer::address_of(account) == @mohayo, E_NOT_OWNER);
        if (!exists<DefStore>(@mohayo)) { init_module(account); };
        let d = ItemDef { name, group, combat_usable, effect_kind, effect_value, decimals, bound };
        let ds = borrow_global_mut<DefStore>(@mohayo);
        if (table::contains(&ds.defs, item_type)) {
            *table::borrow_mut(&mut ds.defs, item_type) = d;
        } else {
            table::add(&mut ds.defs, item_type, d);
        };
        let v = borrow_global_mut<Vault>(@mohayo);
        if (!table::contains(&v.balances, item_type)) {
            table::add(&mut v.balances, item_type, table::new());
        };
    }

    // ===================== 铸造 / 消耗 / 转移 =====================
    /// GM 铸造 `whole_units` 整份给 `to`(raw = whole_units × 10^18)。
    public entry fun gm_mint(account: &signer, item_type: u64, to: address, whole_units: u64) acquires Vault {
        assert!(signer::address_of(account) == @mohayo, E_NOT_OWNER);
        assert!(whole_units > 0, E_ZERO);
        credit_raw(item_type, to, (whole_units as u128) * ONE);
    }

    /// 玩家转移(任意 raw 数量, 允许拆散交易; 绑定道具不可转移)
    public entry fun transfer(account: &signer, item_type: u64, to: address, raw: u128) acquires DefStore, Vault {
        let addr = signer::address_of(account);
        assert!(addr != to, E_ZERO);
        assert!(!is_bound(item_type), E_BOUND);
        assert!(try_consume_raw(item_type, addr, raw), E_NO_ITEM);
        credit_raw(item_type, to, raw);
    }

    /// 道具是否绑定(绑定 = 不可转移, 防止可交易资产汇聚后涌向同一强角色)
    #[view]
    public fun is_bound(item_type: u64): bool acquires DefStore {
        let ds = borrow_global<DefStore>(@mohayo);
        if (!table::contains(&ds.defs, item_type)) { return false; };
        table::borrow(&ds.defs, item_type).bound
    }

    /// 内部入账(raw 单位)。`public(friend)` —— 只有 engine / use_item 能铸造(§2.6.11)。
    public(friend) fun credit_raw(item_type: u64, to: address, raw: u128) acquires Vault {
        assert!(raw > 0, E_ZERO);
        let v = borrow_global_mut<Vault>(@mohayo);
        if (!table::contains(&v.balances, item_type)) {
            table::add(&mut v.balances, item_type, table::new());
        };
        let tbl = table::borrow_mut(&mut v.balances, item_type);
        if (table::contains(tbl, to)) {
            let b = table::borrow_mut(tbl, to);
            *b = *b + raw;
        } else {
            table::add(tbl, to, raw);
        };
    }

    /// 扣减(raw)。余额不足返回 false(战斗中弹尽 = 空过, 不炸交易)。`public(friend)`(§2.6.11)。
    public(friend) fun try_consume_raw(item_type: u64, owner: address, raw: u128): bool acquires Vault {
        let v = borrow_global_mut<Vault>(@mohayo);
        if (!table::contains(&v.balances, item_type)) { return false; };
        let tbl = table::borrow_mut(&mut v.balances, item_type);
        if (!table::contains(tbl, owner)) { return false; };
        let b = table::borrow_mut(tbl, owner);
        if (*b < raw) { return false; };
        *b = *b - raw;
        true
    }

    /// 确定性扣减(不足即 abort)。`public(friend)`(§2.6.11)。
    public(friend) fun consume_raw(item_type: u64, owner: address, raw: u128) acquires Vault {
        assert!(try_consume_raw(item_type, owner, raw), E_NO_ITEM);
    }

    /// 战斗内效果结算(engine 调用): 按 ItemDef.effect_kind 分发。返回 (是否消耗成功, 效果种类, 效果值)。
    /// `public(friend)` —— 只有 engine 能触发战斗消耗(§2.6.11)。
    public(friend) fun combat_use(item_type: u64, owner: address): (bool, u8, u64) acquires DefStore, Vault {
        let ds = borrow_global<DefStore>(@mohayo);
        if (!table::contains(&ds.defs, item_type)) { return (false, EFFECT_NONE, 0); };
        let d = *table::borrow(&ds.defs, item_type);
        if (!d.combat_usable) { return (false, EFFECT_NONE, 0); };
        if (!try_consume_raw(item_type, owner, ONE)) { return (false, EFFECT_NONE, 0); };
        (true, d.effect_kind, d.effect_value)
    }

    // ===================== 查询 =====================
    #[view]
    public fun balance_raw(item_type: u64, owner: address): u128 acquires Vault {
        let v = borrow_global<Vault>(@mohayo);
        if (!table::contains(&v.balances, item_type)) { return 0; };
        let tbl = table::borrow(&v.balances, item_type);
        if (!table::contains(tbl, owner)) { return 0; };
        *table::borrow(tbl, owner)
    }

    /// 整份余额(展示用: raw / 10^18)
    #[view]
    public fun balance_whole(item_type: u64, owner: address): u64 acquires Vault {
        ((balance_raw(item_type, owner) / ONE) as u64)
    }

    #[view]
    public fun is_combat_usable(item_type: u64): bool acquires DefStore {
        let ds = borrow_global<DefStore>(@mohayo);
        table::contains(&ds.defs, item_type) && table::borrow(&ds.defs, item_type).combat_usable
    }

    #[view]
    public fun def_of(item_type: u64): (vector<u8>, u8, bool, u8, u64, u8, bool) acquires DefStore {
        let ds = borrow_global<DefStore>(@mohayo);
        assert!(table::contains(&ds.defs, item_type), E_NOT_FOUND);
        let d = table::borrow(&ds.defs, item_type);
        (d.name, d.group, d.combat_usable, d.effect_kind, d.effect_value, d.decimals, d.bound)
    }

    #[view]
    public fun one(): u128 { ONE }
}

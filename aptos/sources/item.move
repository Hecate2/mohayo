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
module mohayo::item {
    use std::signer;
    use std::table::{Self, Table};
    use std::vector;

    // ===================== 道具类型 id（按组留区间: 组内小步长, 同组可扩展） =====================
    public const ITEM_LEAD_BULLET: u64 = 1;     // 铅弹(火枪左轮弹药, 战斗不可直接使用)
    public const ITEM_DRAGON_BULLET: u64 = 2;   // 龙击弹(火枪龙击弹弹药, 同上)
    public const ITEM_MANA_FIREWORK: u64 = 100; // 魔素礼花(战斗中使用: 大幅增加房间魔素)

    // ===================== 分组 =====================
    public const GROUP_AMMO: u8 = 1;              // 弹药(战斗中不可直接使用, 技能自动消耗)
    public const GROUP_COMBAT_CONSUMABLE: u8 = 2; // 战斗消耗品(可入计划队列)
    public const GROUP_MISC: u8 = 3;              // 其它/材料(预留)

    // ===================== 效果种类(战斗内) =====================
    public const EFFECT_NONE: u8 = 0;
    public const EFFECT_MANA_BOOST: u8 = 1;       // 增加房间魔素池(effect_value 为增量)

    // ===================== 计划队列中的道具技能段 =====================
    /// 道具占计划队列的技能 id 段: ITEM_SKILL_BASE + item_type (0xF000=61440, 文档 §2.6 保留段)
    public const ITEM_SKILL_BASE: u64 = 61440;

    /// 1 整份 = 10^18 最小单位 (decimals=18)
    public const ONE: u128 = 1000000000000000000;

    const E_NOT_OWNER: u64 = 1;
    const E_ALREADY: u64 = 2;
    const E_NOT_FOUND: u64 = 3;
    const E_NO_ITEM: u64 = 4;
    const E_ZERO: u64 = 5;

    /// 道具定义(key-value, 按类型分组)
    struct ItemDef has copy, drop, store {
        name: vector<u8>,
        group: u8,
        combat_usable: bool,
        effect_kind: u8,
        effect_value: u64,
        decimals: u8,
    }

    struct DefStore has key {
        defs: Table<u64, ItemDef>,
    }

    /// vault: item_type → (address → raw 余额, u128)
    struct Vault has key {
        balances: Table<u64, Table<address, u128>>,
    }

    // ===================== 初始化 =====================
    fun init_module(account: &signer) {
        move_to(account, DefStore { defs: table::new() });
        move_to(account, Vault { balances: table::new() });
    }

    #[test_only]
    public fun init_for_test(account: &signer) {
        if (!exists<DefStore>(@mohayo)) { init_module(account); };
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
    ) acquires DefStore, Vault {
        assert!(signer::address_of(account) == @mohayo, E_NOT_OWNER);
        if (!exists<DefStore>(@mohayo)) { init_module(account); };
        let d = ItemDef { name, group, combat_usable, effect_kind, effect_value, decimals };
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

    /// 玩家转移(任意 raw 数量, 允许拆散交易)
    public entry fun transfer(account: &signer, item_type: u64, to: address, raw: u128) acquires Vault {
        let addr = signer::address_of(account);
        assert!(addr != to, E_ZERO);
        assert!(try_consume_raw(item_type, addr, raw), E_NO_ITEM);
        credit_raw(item_type, to, raw);
    }

    /// 内部入账(raw 单位)
    public fun credit_raw(item_type: u64, to: address, raw: u128) acquires Vault {
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

    /// 扣减(raw)。余额不足返回 false(战斗中弹尽 = 空过, 不炸交易)。
    public fun try_consume_raw(item_type: u64, owner: address, raw: u128): bool acquires Vault {
        let v = borrow_global_mut<Vault>(@mohayo);
        if (!table::contains(&v.balances, item_type)) { return false; };
        let tbl = table::borrow_mut(&mut v.balances, item_type);
        if (!table::contains(tbl, owner)) { return false; };
        let b = table::borrow_mut(tbl, owner);
        if (*b < raw) { return false; };
        *b = *b - raw;
        true
    }

    /// 确定性扣减(不足即 abort)
    public fun consume_raw(item_type: u64, owner: address, raw: u128) acquires Vault {
        assert!(try_consume_raw(item_type, owner, raw), E_NO_ITEM);
    }

    /// 战斗内效果结算(engine 调用): 按 ItemDef.effect_kind 分发。返回 (是否消耗成功, 效果种类, 效果值)。
    public fun combat_use(item_type: u64, owner: address): (bool, u8, u64) acquires DefStore, Vault {
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
    public fun def_of(item_type: u64): (vector<u8>, u8, bool, u8, u64, u8) acquires DefStore {
        let ds = borrow_global<DefStore>(@mohayo);
        assert!(table::contains(&ds.defs, item_type), E_NOT_FOUND);
        let d = table::borrow(&ds.defs, item_type);
        (d.name, d.group, d.combat_usable, d.effect_kind, d.effect_value, d.decimals)
    }

    #[view]
    public fun one(): u128 { ONE }
}

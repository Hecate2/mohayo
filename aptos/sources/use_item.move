/// 道具的关卡外用途编排(content-design §7 角色类 / 入场类)。
///
/// - 命运骰子 / 重生卷轴: 消耗道具 → 用链上可推进的确定性种子掷出新种族与词条,
///   再交给 character 模块做 重掷 / 重建(仅关卡外 room_id==0)。
///   (创建层随机正式方案走 RNGRouter/VRF, 见 randomness-design §5; 此处先用
///   每道具一递增计数器作种子, 保证"每次消耗结果不同、测试可复现" —— 基本效果实现。)
/// - 每日挑战券: 每日免费领取一券(绑定不可交易), 每日限一次。
/// - 挑战券 / 每日挑战券: 兑成「额外入场额度」(credits, 突破当日入场次数限制)。
/// - 入场次数门控(§7.2): `engine::create_room` 调用 `consume_entry` —— 先扣额外额度,
///   再计当日次数; 超额则拒入。**免费地下城不消耗次数**(§6.3 负债者仍可进免费图打工)。
module mohayo::use_item {
    use aptos_framework::event;
    use aptos_framework::randomness;
    use aptos_framework::timestamp;
    use aptos_std::table::{Self, Table};
    use std::signer;
    use mohayo::item;
    use mohayo::character;
    use mohayo::rng;

    friend mohayo::engine;

    const E_NOT_OWNER: u64 = 1;
    const E_ALREADY_CLAIMED: u64 = 2;
    const E_NO_ENTRIES: u64 = 3;

    const DAY_SECS: u64 = 86400;
    /// 每自然日的免费入场次数（数值层参数，GM 可改）
    const DEFAULT_DAILY_ENTRIES: u64 = 3;

    #[event]
    struct EntryCreditAdded has drop, store { player: address, amount: u64, source: u64 }

    struct EntryGate has key {
        last_claimed_day: Table<address, u64>,
        credits: Table<address, u64>,      // 额外入场额度(挑战券/每日券兑出)
        daily_limit: u64,                  // 每自然日免费入场次数
        entry_day: Table<address, u64>,    // 上次计次所在自然日
        entry_count: Table<address, u64>,  // 该自然日已用次数
    }

    fun init_module(account: &signer) {
        move_to(account, EntryGate {
            last_claimed_day: table::new(),
            credits: table::new(),
            daily_limit: DEFAULT_DAILY_ENTRIES,
            entry_day: table::new(),
            entry_count: table::new(),
        });
    }

    #[test_only]
    public fun init_for_test(account: &signer) {
        if (!exists<EntryGate>(@mohayo)) { init_module(account); };
    }

    // ===================== 重掷 / 重建 =====================

    /// 命运骰子: 种族+词条全重掷(保留职业/等级/已选自选技); 仅关卡外。
    /// 私有 `entry` + `#[randomness]`: 掷骰用协议随机数(§2.6.14)。
    /// 此前用全局自增计数器当种子, 结果可以被任何人预先算出 —— 等于「重掷前先看答案」。
    #[randomness]
    entry fun dice_of_fate(account: &signer, char_id: u64) {
        do_dice_of_fate(account, char_id, randomness::u64_integer());
    }

    #[test_only]
    public entry fun dice_of_fate_test(account: &signer, char_id: u64, seed: u64) {
        do_dice_of_fate(account, char_id, seed);
    }

    fun do_dice_of_fate(account: &signer, char_id: u64, seed: u64) {
        let owner = signer::address_of(account);
        assert!(character::char_owner(char_id) == owner, E_NOT_OWNER);
        // §2.3 二选一: 先扣 playerId 级免费重掷计数器, 没有才核销一枚命运骰子
        if (!character::try_consume_free_reroll(owner)) {
            item::consume_raw(item::ITEM_DICE_OF_FATE, owner, item::one());
        };
        let r = rng::new(seed);
        let race = character::roll_random_race(&mut r);
        let tiers = character::roll_random_affix_tiers(&mut r);
        character::reroll_character(char_id, race, tiers);
    }

    /// 重生卷轴: 整体重建角色(换种族+词条, 等级重置为 1, 自选技清空); 仅关卡外。
    #[randomness]
    entry fun rebirth_scroll(account: &signer, char_id: u64) {
        do_rebirth_scroll(account, char_id, randomness::u64_integer());
    }

    #[test_only]
    public entry fun rebirth_scroll_test(account: &signer, char_id: u64, seed: u64) {
        do_rebirth_scroll(account, char_id, seed);
    }

    fun do_rebirth_scroll(account: &signer, char_id: u64, seed: u64) {
        let owner = signer::address_of(account);
        assert!(character::char_owner(char_id) == owner, E_NOT_OWNER);
        item::consume_raw(item::ITEM_REBIRTH_SCROLL, owner, item::one());
        let r = rng::new(seed);
        let race = character::roll_random_race(&mut r);
        let tiers = character::roll_random_affix_tiers(&mut r);
        character::rebuild_character(char_id, race, tiers);
    }

    // ===================== 入场类 =====================

    fun today(): u64 { timestamp::now_seconds() / DAY_SECS }

    /// 每日免费领取一张绑定每日挑战券(每日限一次)。
    public entry fun claim_daily_ticket(account: &signer)
    acquires EntryGate {
        if (!exists<EntryGate>(@mohayo)) { init_module(account); };
        let owner = signer::address_of(account);
        let day = today();
        let gate = borrow_global_mut<EntryGate>(@mohayo);
        let claimed = table::borrow_mut_with_default(&mut gate.last_claimed_day, owner, 0u64);
        assert!(*claimed != day, E_ALREADY_CLAIMED);
        *claimed = day;
        item::credit_raw(item::ITEM_DAILY_TICKET, owner, item::one());
    }

    /// 消耗绑定每日挑战券 → +1 额外入场额度(绑定券只能自己用: 不可转移, 防多账号囤积套利)。
    public entry fun use_daily_ticket(account: &signer)
    acquires EntryGate {
        if (!exists<EntryGate>(@mohayo)) { init_module(account); };
        let owner = signer::address_of(account);
        item::consume_raw(item::ITEM_DAILY_TICKET, owner, item::one());
        add_credit(owner, item::ITEM_DAILY_TICKET);
    }

    /// 消耗可交易挑战券 → +1 额外入场额度(无视当日入场次数限制)。
    public entry fun use_challenge_ticket(account: &signer)
    acquires EntryGate {
        if (!exists<EntryGate>(@mohayo)) { init_module(account); };
        let owner = signer::address_of(account);
        item::consume_raw(item::ITEM_CHALLENGE_TICKET, owner, item::one());
        add_credit(owner, item::ITEM_CHALLENGE_TICKET);
    }

    fun add_credit(owner: address, source: u64) acquires EntryGate {
        let gate = borrow_global_mut<EntryGate>(@mohayo);
        let cur = table::borrow_mut_with_default(&mut gate.credits, owner, 0u64);
        *cur = *cur + 1;
        event::emit(EntryCreditAdded { player: owner, amount: 1, source });
    }

    /// 当前玩家的"额外入场额度"(join 门控读此值豁免当日次数)。
    #[view]
    public fun entry_credits(player: address): u64 acquires EntryGate {
        if (!exists<EntryGate>(@mohayo)) { return 0; };
        let gate = borrow_global<EntryGate>(@mohayo);
        if (!table::contains(&gate.credits, player)) { return 0; };
        *table::borrow(&gate.credits, player)
    }

    // ===================== 入场次数门控(§7.2) =====================

    /// 消耗一次入场机会：**先扣额外额度**（挑战券/每日券，突破当日限制），
    /// 否则计入当日次数，达到 `daily_limit` 则拒绝。由 `engine::create_room` 调用。
    public(friend) fun consume_entry(player: address) acquires EntryGate {
        let gate = borrow_global_mut<EntryGate>(@mohayo);
        let credits = table::borrow_mut_with_default(&mut gate.credits, player, 0u64);
        if (*credits > 0) { *credits = *credits - 1; return; };
        let day = today();
        let d = table::borrow_mut_with_default(&mut gate.entry_day, player, 0u64);
        let c = table::borrow_mut_with_default(&mut gate.entry_count, player, 0u64);
        if (*d != day) { *d = day; *c = 0; };
        assert!(*c < gate.daily_limit, E_NO_ENTRIES);
        *c = *c + 1;
    }

    /// 今日剩余免费入场次数（不含挑战券额度）
    #[view]
    public fun entries_left(player: address): u64 acquires EntryGate {
        if (!exists<EntryGate>(@mohayo)) { return DEFAULT_DAILY_ENTRIES; };
        let gate = borrow_global<EntryGate>(@mohayo);
        let day = today();
        if (!table::contains(&gate.entry_day, player)) { return gate.daily_limit; };
        if (*table::borrow(&gate.entry_day, player) != day) { return gate.daily_limit; };
        let used = *table::borrow(&gate.entry_count, player);
        if (used >= gate.daily_limit) { 0 } else { gate.daily_limit - used }
    }

    #[view]
    public fun daily_limit(): u64 acquires EntryGate {
        if (!exists<EntryGate>(@mohayo)) { return DEFAULT_DAILY_ENTRIES; };
        borrow_global<EntryGate>(@mohayo).daily_limit
    }

    /// GM 调整每日免费入场次数（数值层参数，无需改代码）
    public entry fun set_daily_limit(account: &signer, limit: u64) acquires EntryGate {
        assert!(signer::address_of(account) == @mohayo, E_NOT_OWNER);
        let gate = borrow_global_mut<EntryGate>(@mohayo);
        gate.daily_limit = limit;
    }

    /// 玩家能否再领取每日挑战券(今日已领 → false)。
    #[view]
    public fun daily_available(player: address): bool acquires EntryGate {
        if (!exists<EntryGate>(@mohayo)) { return true; };
        let gate = borrow_global<EntryGate>(@mohayo);
        if (!table::contains(&gate.last_claimed_day, player)) { return true; };
        *table::borrow(&gate.last_claimed_day, player) != today()
    }
}
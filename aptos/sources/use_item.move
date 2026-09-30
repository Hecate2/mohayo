/// 道具的关卡外用途编排(content-design §7 角色类)。
///
/// - 命运骰子 / 重生卷轴: 消耗道具 → 用**协议随机数**(Aptos randomness)掷出新种族与词条,
///   再交给 character 模块做 重掷 / 重建(仅关卡外 room_id==0)。见 technical-design §2.6.14。
/// - 参与次数门控(§2.6.14): `engine::create_room`(开房)与 `engine::join_room_as_char`(加入)
///   各调用一次 `consume_entry` —— **24 小时滑动窗口**内限次，
///   **所有难度都计次(免费图也不例外)**。取代原先「挑战券兑出的额度」那种可无限堆积的账本。
module mohayo::use_item {
    use aptos_framework::randomness;
    use aptos_framework::timestamp;
    use aptos_std::table::{Self, Table};
    use std::signer;
    use std::vector;
    use mohayo::item;
    use mohayo::character;
    use mohayo::rng;

    friend mohayo::engine;

    const E_NOT_OWNER: u64 = 1;
    const E_NO_ENTRIES: u64 = 3;
    const E_LIMIT_TOO_BIG: u64 = 4;

    /// 参与次数的统计窗口：24 小时滑动窗口
    const WINDOW_SECS: u64 = 86400;
    /// 窗口内默认参与次数（数值层参数，GM 可改）
    const DEFAULT_WINDOW_LIMIT: u64 = 3;
    /// GM 可设的窗口次数上限（防止把限额调成天文数字, 那样每账号要存一堆时间戳）
    const MAX_WINDOW_LIMIT: u64 = 1000;

    /// 参与次数门控（§2.6.14）：每账号只保留**最近若干次参与的时间戳**（长度 ≤ 窗口上限），
    /// 过期即丢、满则拒绝。存储量与窗口上限同阶，不会像额度账本那样无限堆积。
    struct EntryGate has key {
        /// 24 小时窗口内的参与次数上限
        window_limit: u64,
        /// 账号 → 最近若干次参与的时间戳（升序）
        recent: Table<address, vector<u64>>,
    }

    fun init_module(account: &signer) {
        move_to(account, EntryGate {
            window_limit: DEFAULT_WINDOW_LIMIT,
            recent: table::new(),
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

    // ===================== 参与次数：24 小时滑动窗口 =====================

    /// 窗口起点 = `now - 24h`（now 不足 24 小时时取 0，避免下溢）。
    fun window_start(now: u64): u64 {
        if (now > WINDOW_SECS) { now - WINDOW_SECS } else { 0 }
    }

    /// 窗口内已计数的参与次数（只读，供视图用）。
    fun window_used(list: &vector<u64>, now: u64): u64 {
        let cutoff = window_start(now);
        let n = vector::length(list);
        let i = 0;
        let used = 0;
        while (i < n) {
            if (*vector::borrow(list, i) > cutoff) { used = used + 1; };
            i = i + 1;
        };
        used
    }

    /// 消耗一次参与机会：先清掉滑出窗口的时间戳，未满窗口上限则记下当前时间。
    /// 由 `engine::create_room`(开房)与 `engine::join_room_as_char`(加入)调用，**所有难度都计次**（免费图也不例外）。
    public(friend) fun consume_entry(player: address) acquires EntryGate {
        let gate = borrow_global_mut<EntryGate>(@mohayo);
        let limit = gate.window_limit;
        let now = timestamp::now_seconds();
        let cutoff = window_start(now);
        let list = table::borrow_mut_with_default(&mut gate.recent, player, vector::empty<u64>());
        while (vector::length(list) > 0 && *vector::borrow(list, 0) <= cutoff) {
            vector::remove(list, 0);
        };
        assert!(vector::length(list) < limit, E_NO_ENTRIES);
        vector::push_back(list, now);
    }

    /// 该账号在当前 24 小时窗口内还能参与几次
    #[view]
    public fun entries_left(player: address): u64 acquires EntryGate {
        if (!exists<EntryGate>(@mohayo)) { return DEFAULT_WINDOW_LIMIT; };
        let gate = borrow_global<EntryGate>(@mohayo);
        if (!table::contains(&gate.recent, player)) { return gate.window_limit };
        let used = window_used(table::borrow(&gate.recent, player), timestamp::now_seconds());
        if (used >= gate.window_limit) { 0 } else { gate.window_limit - used }
    }

    #[view]
    public fun window_limit(): u64 acquires EntryGate {
        if (!exists<EntryGate>(@mohayo)) { return DEFAULT_WINDOW_LIMIT };
        borrow_global<EntryGate>(@mohayo).window_limit
    }

    /// GM 调整窗口内的参与次数上限（数值层参数，无需改代码）
    public entry fun set_window_limit(account: &signer, limit: u64) acquires EntryGate {
        assert!(signer::address_of(account) == @mohayo, E_NOT_OWNER);
        assert!(limit <= MAX_WINDOW_LIMIT, E_LIMIT_TOO_BIG);
        borrow_global_mut<EntryGate>(@mohayo).window_limit = limit;
    }
}
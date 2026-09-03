/// 道具的关卡外用途编排(content-design §7 角色类 / 入场类)。
///
/// - 命运骰子 / 重生卷轴: 消耗道具 → 用链上可推进的确定性种子掷出新种族与词条,
///   再交给 character 模块做 重掷 / 重建(仅关卡外 room_id==0)。
///   (创建层随机正式方案走 RNGRouter/VRF, 见 randomness-design §5; 此处先用
///   每道具一递增计数器作种子, 保证"每次消耗结果不同、测试可复现" —— 基本效果实现。)
/// - 每日挑战券: 每日免费领取一券(绑定不可交易), 每日限一次。
/// - 挑战券 / 每日挑战券: 兑成「额外入场额度」(credits, 抵消当日入场次数限制)。
///   入场次数系统落地后, join 门控读 `entry_credits(player)` 即可豁免次数。
module mohayo::use_item {
    use aptos_framework::event;
    use aptos_framework::timestamp;
    use aptos_std::table::{Self, Table};
    use std::signer;
    use mohayo::item;
    use mohayo::character;
    use mohayo::rng;

    const E_NOT_OWNER: u64 = 1;
    const E_ALREADY_CLAIMED: u64 = 2;

    const DAY_SECS: u64 = 86400;

    #[event]
    struct EntryCreditAdded has drop, store { player: address, amount: u64, source: u64 }

    struct RerollSeq has key { counter: u64 }

    struct EntryGate has key {
        last_claimed_day: Table<address, u64>,
        credits: Table<address, u64>, // 额外入场额度(挑战券/每日券兑出)
    }

    fun init_module(account: &signer) {
        move_to(account, RerollSeq { counter: 0 });
        move_to(account, EntryGate {
            last_claimed_day: table::new(),
            credits: table::new(),
        });
    }

    #[test_only]
    public fun init_for_test(account: &signer) {
        if (!exists<RerollSeq>(@mohayo)) { init_module(account); };
    }

    // ===================== 重掷 / 重建 =====================

    /// 命运骰子: 种族+词条全重掷(保留职业/等级/已选自选技); 仅关卡外。
    public entry fun dice_of_fate(account: &signer, char_id: u64)
    acquires RerollSeq {
        let owner = signer::address_of(account);
        assert!(character::char_owner(char_id) == owner, E_NOT_OWNER);
        item::consume_raw(item::ITEM_DICE_OF_FATE, owner, item::one());
        let seed = next_seed();
        let r = rng::new(seed);
        let race = character::roll_random_race(&mut r);
        let tiers = character::roll_random_affix_tiers(&mut r);
        character::reroll_character(char_id, race, tiers);
    }

    /// 重生卷轴: 整体重建角色(换种族+词条, 等级重置为 1, 自选技清空); 仅关卡外。
    public entry fun rebirth_scroll(account: &signer, char_id: u64)
    acquires RerollSeq {
        let owner = signer::address_of(account);
        assert!(character::char_owner(char_id) == owner, E_NOT_OWNER);
        item::consume_raw(item::ITEM_REBIRTH_SCROLL, owner, item::one());
        let seed = next_seed();
        let r = rng::new(seed);
        let race = character::roll_random_race(&mut r);
        let tiers = character::roll_random_affix_tiers(&mut r);
        character::rebuild_character(char_id, race, tiers);
    }

    fun next_seed(): u64 acquires RerollSeq {
        let s = borrow_global_mut<RerollSeq>(@mohayo);
        s.counter = s.counter + 1;
        s.counter
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

    /// 玩家能否再领取每日挑战券(今日已领 → false)。
    #[view]
    public fun daily_available(player: address): bool acquires EntryGate {
        if (!exists<EntryGate>(@mohayo)) { return true; };
        let gate = borrow_global<EntryGate>(@mohayo);
        if (!table::contains(&gate.last_claimed_day, player)) { return true; };
        *table::borrow(&gate.last_claimed_day, player) != today()
    }
}
/// Game currency (Char) — cannot be transferred between players.
/// Only minted by authorized modules, spent through authorized sinks.
///
/// 余额为 **i128 有符号**：救援费允许把余额扣成负数、且负余额无上限
/// (gameplay-design §6.3/§10-13)。收益入账走 `credit`，天然「先还债、剩余才入账」
/// （同一本账，余额从负数往上加即自动偿债）。
module mohayo::economy {
    use aptos_framework::event;
    use aptos_std::table::{Self, Table};
    use std::signer;

    friend mohayo::engine;
    friend mohayo::character;

    const E_NOT_OWNER: u64 = 1;
    const E_NOT_MINTER: u64 = 2;
    const E_NOT_SPENDER: u64 = 3;
    const E_INSUFFICIENT_BALANCE: u64 = 4;

    /// 首次建号发放的启动资金（§2.6.14：「很少一点」，刚好够在低难度付费图试几次）。
    /// 按账号只发一次，见 `character::create_character`。数值层参数。
    public fun STARTING_GRANT(): u64 { 20 }

    struct CoinStore has key {
        balances: Table<address, i128>,
        minters: Table<address, bool>,
        spenders: Table<address, bool>,
    }

    #[event]
    struct Minted has drop, store { player: address, amount: u64 }
    #[event]
    struct Spent has drop, store { player: address, amount: u64 }
    #[event]
    struct Credited has drop, store { player: address, amount: u64, balance: i128 }
    #[event]
    struct RescueCharged has drop, store { player: address, amount: u64, balance: i128 }
    #[event]
    struct MinterSet has drop, store { minter: address, enabled: bool }
    #[event]
    struct SpenderSet has drop, store { spender: address, enabled: bool }

    fun init_module(account: &signer) {
        move_to(account, CoinStore {
            balances: table::new(),
            minters: table::new(),
            spenders: table::new(),
        });
    }

    // ---- internal balance helpers ----

    fun get_balance(store: &CoinStore, player: address): i128 {
        if (table::contains(&store.balances, player)) {
            *table::borrow(&store.balances, player)
        } else { 0 }
    }

    fun put_balance(store: &mut CoinStore, player: address, v: i128) {
        if (table::contains(&store.balances, player)) {
            *table::borrow_mut(&mut store.balances, player) = v;
        } else {
            table::add(&mut store.balances, player, v);
        };
    }

    // ---- admin ----

    public entry fun set_minter(account: &signer, minter: address, enabled: bool) acquires CoinStore {
        assert!(signer::address_of(account) == @mohayo, E_NOT_OWNER);
        let store = borrow_global_mut<CoinStore>(@mohayo);
        if (table::contains(&store.minters, minter)) {
            *table::borrow_mut(&mut store.minters, minter) = enabled;
        } else {
            table::add(&mut store.minters, minter, enabled);
        };
        event::emit(MinterSet { minter, enabled });
    }

    public entry fun set_spender(account: &signer, spender: address, enabled: bool) acquires CoinStore {
        assert!(signer::address_of(account) == @mohayo, E_NOT_OWNER);
        let store = borrow_global_mut<CoinStore>(@mohayo);
        if (table::contains(&store.spenders, spender)) {
            *table::borrow_mut(&mut store.spenders, spender) = enabled;
        } else {
            table::add(&mut store.spenders, spender, enabled);
        };
        event::emit(SpenderSet { spender, enabled });
    }

    // ---- authorized operations (minter/spender allowlist, for external sinks) ----

    /// Mint Char to a player. Caller must be an authorized minter.
    public entry fun mint(account: &signer, player: address, amount: u64) acquires CoinStore {
        let caller = signer::address_of(account);
        let store = borrow_global_mut<CoinStore>(@mohayo);
        assert!(table::contains(&store.minters, caller) && *table::borrow(&store.minters, caller), E_NOT_MINTER);
        let bal = get_balance(store, player) + (amount as i128);
        put_balance(store, player, bal);
        event::emit(Minted { player, amount });
    }

    /// Spend Char from a player. Caller must be an authorized spender.
    /// **必须余额充足**（购买/入场等常规消费不允许透支，§6.3 负债者的受限行为集）。
    public entry fun spend(account: &signer, player: address, amount: u64) acquires CoinStore {
        let caller = signer::address_of(account);
        let store = borrow_global_mut<CoinStore>(@mohayo);
        assert!(table::contains(&store.spenders, caller) && *table::borrow(&store.spenders, caller), E_NOT_SPENDER);
        let bal = get_balance(store, player);
        assert!(bal >= (amount as i128), E_INSUFFICIENT_BALANCE);
        put_balance(store, player, bal - (amount as i128));
        event::emit(Spent { player, amount });
    }

    // ---- engine hooks (friend module) ----

    /// 收益入账（§6.1）。余额为负时先自动偿债，剩余部分才形成可支配余额。
    public(friend) fun credit(player: address, amount: u64) acquires CoinStore {
        let store = borrow_global_mut<CoinStore>(@mohayo);
        let bal = get_balance(store, player) + (amount as i128);
        put_balance(store, player, bal);
        event::emit(Credited { player, amount, balance: bal });
    }

    /// 入场费（§3.1）：**余额必须充足**，扣款即销毁（水槽）。
    public(friend) fun charge_entry(player: address, amount: u64) acquires CoinStore {
        if (amount == 0) return;
        let store = borrow_global_mut<CoinStore>(@mohayo);
        let bal = get_balance(store, player);
        assert!(bal >= (amount as i128), E_INSUFFICIENT_BALANCE);
        put_balance(store, player, bal - (amount as i128));
        event::emit(Spent { player, amount });
    }

    /// 救援费（§6.3）：**允许把余额扣成负数、负余额无上限**。
    public(friend) fun charge_rescue(player: address, amount: u64) acquires CoinStore {
        if (amount == 0) return;
        let store = borrow_global_mut<CoinStore>(@mohayo);
        let bal = get_balance(store, player) - (amount as i128);
        put_balance(store, player, bal);
        event::emit(RescueCharged { player, amount, balance: bal });
    }

    // ---- view functions ----

    #[view]
    public fun balance_of(player: address): i128 acquires CoinStore {
        let store = borrow_global<CoinStore>(@mohayo);
        get_balance(store, player)
    }

    /// 负债判定（§6.3：负债者不得创建角色/升级/购物/开房/付费入场，仍可进免费图）。
    #[view]
    public fun is_debtor(player: address): bool acquires CoinStore {
        let store = borrow_global<CoinStore>(@mohayo);
        get_balance(store, player) < 0
    }

    #[view]
    public fun is_minter(account: address): bool acquires CoinStore {
        let store = borrow_global<CoinStore>(@mohayo);
        if (!table::contains(&store.minters, account)) return false;
        *table::borrow(&store.minters, account)
    }

    #[view]
    public fun is_spender(account: address): bool acquires CoinStore {
        let store = borrow_global<CoinStore>(@mohayo);
        if (!table::contains(&store.spenders, account)) return false;
        *table::borrow(&store.spenders, account)
    }

    // ---- test helpers ----

    #[test_only]
    public fun init_for_test(account: &signer) {
        if (!exists<CoinStore>(signer::address_of(account))) {
            init_module(account);
        };
    }

    #[test_only]
    public fun gm_charge_rescue(_account: &signer, player: address, amount: u64) acquires CoinStore {
        charge_rescue(player, amount);
    }

    #[test_only]
    public fun gm_credit(_account: &signer, player: address, amount: u64) acquires CoinStore {
        credit(player, amount);
    }

    #[test_only]
    public fun gm_mint(account: &signer, player: address, amount: u64) acquires CoinStore {
        let store = borrow_global_mut<CoinStore>(@mohayo);
        let bal = get_balance(store, player) + (amount as i128);
        put_balance(store, player, bal);
    }
}

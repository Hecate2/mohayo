/// Game currency (Char) — cannot be transferred between players.
/// Only minted by authorized modules, spent through authorized sinks.
module mohayo::economy {
    use aptos_framework::event;
    use aptos_std::table::{Self, Table};
    use std::signer;

    const E_NOT_OWNER: u64 = 1;
    const E_NOT_MINTER: u64 = 2;
    const E_NOT_SPENDER: u64 = 3;
    const E_INSUFFICIENT_BALANCE: u64 = 4;
    const E_RESTRICTED: u64 = 5;

    struct CoinStore has key {
        balances: Table<address, u64>,
        minters: Table<address, bool>,
        spenders: Table<address, bool>,
    }

    #[event]
    struct Minted has drop, store { player: address, amount: u64 }

    #[event]
    struct Spent has drop, store { player: address, amount: u64 }

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

    // ---- authorized operations ----

    /// Mint Char to a player. Caller must be an authorized minter.
    public entry fun mint(account: &signer, player: address, amount: u64) acquires CoinStore {
        let caller = signer::address_of(account);
        let store = borrow_global_mut<CoinStore>(@mohayo);
        assert!(table::contains(&store.minters, caller) && *table::borrow(&store.minters, caller), E_NOT_MINTER);
        let bal = if (table::contains(&store.balances, player)) {
            *table::borrow(&store.balances, player)
        } else { 0 };
        let new_bal = bal + amount;
        if (table::contains(&store.balances, player)) {
            *table::borrow_mut(&mut store.balances, player) = new_bal;
        } else {
            table::add(&mut store.balances, player, new_bal);
        };
        event::emit(Minted { player, amount });
    }

    /// Spend Char from a player. Caller must be an authorized spender.
    public entry fun spend(account: &signer, player: address, amount: u64) acquires CoinStore {
        let caller = signer::address_of(account);
        let store = borrow_global_mut<CoinStore>(@mohayo);
        assert!(table::contains(&store.spenders, caller) && *table::borrow(&store.spenders, caller), E_NOT_SPENDER);
        let bal = if (table::contains(&store.balances, player)) {
            *table::borrow(&store.balances, player)
        } else { 0 };
        assert!(bal >= amount, E_INSUFFICIENT_BALANCE);
        let new_bal = bal - amount;
        if (table::contains(&store.balances, player)) {
            *table::borrow_mut(&mut store.balances, player) = new_bal;
        } else {
            table::add(&mut store.balances, player, new_bal);
        };
        event::emit(Spent { player, amount });
    }

    // ---- view functions ----

    #[view]
    public fun balance_of(player: address): u64 acquires CoinStore {
        let store = borrow_global<CoinStore>(@mohayo);
        if (!table::contains(&store.balances, player)) return 0;
        *table::borrow(&store.balances, player)
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

    // ---- test helper ----

    #[test_only]
    public fun init_for_test(account: &signer) {
        if (!exists<CoinStore>(signer::address_of(account))) {
            init_module(account);
        };
    }

    #[test_only]
    public fun gm_mint(account: &signer, player: address, amount: u64) acquires CoinStore {
        let store = borrow_global_mut<CoinStore>(@mohayo);
        let bal = if (table::contains(&store.balances, player)) {
            *table::borrow(&store.balances, player)
        } else { 0 };
        let new_bal = bal + amount;
        if (table::contains(&store.balances, player)) {
            *table::borrow_mut(&mut store.balances, player) = new_bal;
        } else {
            table::add(&mut store.balances, player, new_bal);
        };
    }
}

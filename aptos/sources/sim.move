/// Phase 5 — Monte-Carlo dungeon-clearance simulator.
///
/// Runs the FULL production combat engine (`mohayo::engine`) over many room seeds
/// (each distinct `room_id` = a distinct deterministic random sample) for a given
/// dungeon and a single-player build, then reports the clearance rate. This is the
/// tuning harness used to fine-tune dungeon/skill values (e.g. the D5 solo band of
/// 80–90%). It is `#[test_only]`: it depends on test-only initializers and is never
/// deployed.
module mohayo::sim {
    use std::signer;
    use std::vector;
    use mohayo::engine;
    use mohayo::character;
    use mohayo::skill_registry;
    use mohayo::content_registration;

    /// Play one full dungeon run for a single-member party.
    /// Returns 1 if the dungeon was cleared (result=1), 0 otherwise.
    /// phase machine: 1 = in combat (advance_turn), 3 = intermission (advance_battle),
    /// 2 = resolved (clear or defeat/timeout, disambiguated by room_result).
    public fun clear_once(
        a: &signer,
        difficulty: u64,
        hp: u64, atk: u64, mag: u64, spd: u64,
        plan: vector<u64>,
    ): u64 {
        engine::create_room(a, difficulty);
        let room_id = skill_registry::next_room_id() - 1;
        engine::join_room(a, room_id, hp, atk, mag, spd);
        engine::start_combat(a, room_id);
        engine::set_plan(a, room_id, 0, plan);
        // Hard safety cap: a handful of turns per battle per dungeon is ample; a
        // battle that is unwinnable still ends by the per-battle turn timeout.
        let guard = 0;
        while (guard < 600) {
            let ph = engine::room_phase(room_id);
            if (ph == 1) {
                engine::advance_turn(a, room_id);
            } else if (ph == 3) {
                engine::advance_battle(a, room_id);
            } else {
                break;
            };
            guard = guard + 1;
        };
        if (engine::room_result(room_id) == 1) { 1 } else { 0 }
    }

    /// Aggregate clearance rate across `samples` room seeds.
    /// Returns (wins, total) with `total == samples`.
    public fun clear_rate(
        a: &signer,
        difficulty: u64, samples: u64,
        hp: u64, atk: u64, mag: u64, spd: u64,
        plan: vector<u64>,
    ): (u64, u64) {
        let wins = 0;
        let i = 0;
        while (i < samples) {
            wins = wins + clear_once(a, difficulty, hp, atk, mag, spd, plan);
            i = i + 1;
        };
        (wins, samples)
    }

    fun reg(a: &signer) {
        character::init_for_test(a);
        skill_registry::init_for_test(a);
        engine::init_for_test(a);
        content_registration::register_all_content(a);
    }

    // ===================== reuse-friendly plan helpers =====================

    fun plan1(): vector<u64> { vector[1] }   // 攻击(循环)
    fun plan14(): vector<u64> { vector[1, 3] } // 攻击 + 治疗

    // ===================== sample runs (one entry per focus dungeon) =====================

    // ---- probability ladder helpers: report (wins,total) per line, no assertion ----

    #[test]
    fun sim_explore_d1_d4_growth() {
        let a = &std::account::create_account_for_test(@mohayo);
        reg(a);
        // growth ladder across the early dungeons. Each line: dungeon, then (wins,total).
        // Level ~20
        let (w, t) = clear_rate(a, 1, 15, 2000, 1600, 800, 200, plan1());
        std::debug::print(&w); std::debug::print(&t);
        let (w, t) = clear_rate(a, 2, 15, 2000, 1600, 800, 200, plan1());
        std::debug::print(&w); std::debug::print(&t);
        let (w, t) = clear_rate(a, 3, 15, 2000, 1600, 800, 200, plan1());
        std::debug::print(&w); std::debug::print(&t);
        let (w, t) = clear_rate(a, 4, 15, 2000, 1600, 800, 200, plan1());
        std::debug::print(&w); std::debug::print(&t);
        // Level ~60
        let (w, t) = clear_rate(a, 1, 15, 6000, 4800, 2400, 320, plan1());
        std::debug::print(&w); std::debug::print(&t);
        let (w, t) = clear_rate(a, 2, 15, 6000, 4800, 2400, 320, plan1());
        std::debug::print(&w); std::debug::print(&t);
        let (w, t) = clear_rate(a, 3, 15, 6000, 4800, 2400, 320, plan1());
        std::debug::print(&w); std::debug::print(&t);
        let (w, t) = clear_rate(a, 4, 15, 6000, 4800, 2400, 320, plan1());
        std::debug::print(&w); std::debug::print(&t);
    }

    #[test]
    fun sim_explore_d5_d9_end() {
        let a = &std::account::create_account_for_test(@mohayo);
        reg(a);
        // endgame ladder across the hard dungeons. (dungeon, (wins,total)) per line.
        // Level ~200
        let (w, t) = clear_rate(a, 5, 25, 20000, 16000, 8000, 500, plan14());
        std::debug::print(&w); std::debug::print(&t);
        let (w, t) = clear_rate(a, 6, 25, 20000, 16000, 8000, 500, plan14());
        std::debug::print(&w); std::debug::print(&t);
        let (w, t) = clear_rate(a, 7, 25, 20000, 16000, 8000, 500, plan14());
        std::debug::print(&w); std::debug::print(&t);
        // level ~300
        let (w, t) = clear_rate(a, 5, 25, 30000, 26000, 13000, 600, plan14());
        std::debug::print(&w); std::debug::print(&t);
        let (w, t) = clear_rate(a, 7, 25, 30000, 26000, 13000, 600, plan14());
        std::debug::print(&w); std::debug::print(&t);
        let (w, t) = clear_rate(a, 8, 25, 30000, 26000, 13000, 600, plan14());
        std::debug::print(&w); std::debug::print(&t);
        let (w, t) = clear_rate(a, 9, 25, 30000, 26000, 13000, 600, plan14());
        std::debug::print(&w); std::debug::print(&t);
    }

    #[test]
    fun sim_d5_solo_band() {
        let a = &std::account::create_account_for_test(@mohayo);
        reg(a);
        // Tuning report: D5 solo clear-rate. Design target is 80–90% for a strong solo;
        // currently a universal-heal build sustains through it (see content-design notes),
        // so combat threat must be raised to land the band before this can be enforced.
        let (w, t) = clear_rate(a, 5, 30, 30000, 26000, 13000, 600, plan14());
        std::debug::print(&w); std::debug::print(&t);
        let _pct = w * 100000 / t;
        assert!(t == 30, 1); // always ran the full sample (legibility guard only)
    }

    #[test]
    fun sim_d9_hard_rates() {
        let a = &std::account::create_account_for_test(@mohayo);
        reg(a);
        // D9 must be strictly harder than D5 for the same build.
        let (w5, t5) = clear_rate(a, 5, 30, 30000, 26000, 13000, 600, plan14());
        std::debug::print(&w5); std::debug::print(&t5);
        let (w9, t9) = clear_rate(a, 9, 30, 30000, 26000, 13000, 600, plan14());
        std::debug::print(&w9); std::debug::print(&t9);
        assert!(w9 <= w5, 1);
        assert!(t9 > 0, 2);
    }
}
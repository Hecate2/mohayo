/// Phase 5 — Monte-Carlo dungeon-clearance simulator.
///
/// Runs the FULL production combat engine (`mohayo::engine`) over many room seeds
/// (each distinct `room_id` = a distinct deterministic random sample) for a given
/// dungeon and a single-player build, then reports the clearance rate. This is the
/// tuning harness used to fine-tune dungeon/skill/enemy values (e.g. the D5 solo band
/// of 80–90%, the level-1 gate against D3/D4, and the resource-affix chaining check).
/// It is `#[test_only]`: it depends on test-only initializers and is never deployed.
module mohayo::sim {
    use mohayo::engine;
    use mohayo::character;
    use mohayo::skill_registry;
    use mohayo::content_registration;

    /// Play one full dungeon run for a single-member party with flat stats (no
    /// resource affixes). Returns 1 if cleared, 0 otherwise.
    public fun clear_once(
        a: &signer, difficulty: u64,
        hp: u64, atk: u64, mag: u64, spd: u64,
        plan: vector<u64>,
    ): u64 {
        run(a, difficulty, hp, atk, mag, spd, 0, 0, 0, 0, plan)
    }

    /// Same as clear_once but with explicit resource-affix fields
    /// (mana_discount, ap_discount, ap_bonus, mana_gain_bonus).
    public fun clear_once_affixed(
        a: &signer, difficulty: u64,
        hp: u64, atk: u64, mag: u64, spd: u64,
        md: u16, ad: u16, ab: u16, mg: i64,
        plan: vector<u64>,
    ): u64 {
        run(a, difficulty, hp, atk, mag, spd, md, ad, ab, mg, plan)
    }

    /// Run and return 1 iff the first `stop_nb` battles are ALL won before the
    /// party is defeated or evicted by the turn cap. Observes mid-dungeon gates:
    /// e.g. clear_nb(D1, 3) wins iff battles 1..3 cleared — a loss/eviction in any
    /// earlier battle (including a b3 timeout) reads as 0. `stop_nb > total`
    /// degenerates to full-dungeon clearance.
    public fun clear_nb(
        a: &signer, difficulty: u64,
        hp: u64, atk: u64, mag: u64, spd: u64,
        stop_nb: u64, plan: vector<u64>,
    ): u64 {
        run_n(a, difficulty, hp, atk, mag, spd, 0, 0, 0, 0, stop_nb, plan)
    }

    public fun clear_nb_affixed(
        a: &signer, difficulty: u64,
        hp: u64, atk: u64, mag: u64, spd: u64,
        md: u16, ad: u16, ab: u16, mg: i64,
        stop_nb: u64, plan: vector<u64>,
    ): u64 {
        run_n(a, difficulty, hp, atk, mag, spd, md, ad, ab, mg, stop_nb, plan)
    }

    public fun clear_nb_rate(
        a: &signer, difficulty: u64, samples: u64,
        hp: u64, atk: u64, mag: u64, spd: u64,
        stop_nb: u64, plan: vector<u64>,
    ): (u64, u64) {
        let wins = 0;
        let i = 0;
        while (i < samples) {
            wins = wins + clear_nb(a, difficulty, hp, atk, mag, spd, stop_nb, plan);
            i = i + 1;
        };
        (wins, samples)
    }

    public fun clear_nb_rate_affixed(
        a: &signer, difficulty: u64, samples: u64,
        hp: u64, atk: u64, mag: u64, spd: u64,
        md: u16, ad: u16, ab: u16, mg: i64,
        stop_nb: u64, plan: vector<u64>,
    ): (u64, u64) {
        let wins = 0;
        let i = 0;
        while (i < samples) {
            wins = wins + clear_nb_affixed(a, difficulty, hp, atk, mag, spd, md, ad, ab, mg, stop_nb, plan);
            i = i + 1;
        };
        (wins, samples)
    }

    fun run_n(
        a: &signer, difficulty: u64,
        hp: u64, atk: u64, mag: u64, spd: u64,
        md: u16, ad: u16, ab: u16, mg: i64,
        stop_nb: u64, plan: vector<u64>,
    ): u64 {
        engine::create_room(a, difficulty);
        let room_id = skill_registry::next_room_id() - 1;
        if (md == 0 && ad == 0 && ab == 0 && mg == 0) {
            engine::join_room(a, room_id, hp, atk, mag, spd);
        } else {
            engine::join_room_affixed(a, room_id, hp, atk, mag, spd, md, ad, ab, mg);
        };
        engine::start_combat(a, room_id);
        engine::set_plan(a, room_id, 0, plan);
        let guard = 0;
        while (guard < 600) {
            let ph = engine::room_phase(room_id);
            if (ph == 1) {
                engine::advance_turn(a, room_id);
            } else if (ph == 3) {
                let (bi, _total) = engine::room_battle(room_id);
                if (bi >= stop_nb) { return 1; };
                engine::advance_battle(a, room_id);
            } else {
                break;
            };
            guard = guard + 1;
        };
        if (engine::room_result(room_id) == 1) { 1 } else { 0 }
    }

    fun run(
        a: &signer, difficulty: u64,
        hp: u64, atk: u64, mag: u64, spd: u64,
        md: u16, ad: u16, ab: u16, mg: i64,
        plan: vector<u64>,
    ): u64 {
        engine::create_room(a, difficulty);
        let room_id = skill_registry::next_room_id() - 1;
        if (md == 0 && ad == 0 && ab == 0 && mg == 0) {
            engine::join_room(a, room_id, hp, atk, mag, spd);
        } else {
            engine::join_room_affixed(a, room_id, hp, atk, mag, spd, md, ad, ab, mg);
        };
        engine::start_combat(a, room_id);
        engine::set_plan(a, room_id, 0, plan);
        // Hard safety cap: a handful of turns per battle per dungeon is ample; a
        // battle that cannot be won still ends by the per-battle turn timeout.
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

    /// Aggregate clearance rate across `samples` room seeds. Returns (wins, total).
    public fun clear_rate(
        a: &signer, difficulty: u64, samples: u64,
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

    public fun clear_rate_affixed(
        a: &signer, difficulty: u64, samples: u64,
        hp: u64, atk: u64, mag: u64, spd: u64,
        md: u16, ad: u16, ab: u16, mg: i64,
        plan: vector<u64>,
    ): (u64, u64) {
        let wins = 0;
        let i = 0;
        while (i < samples) {
            wins = wins + clear_once_affixed(a, difficulty, hp, atk, mag, spd, md, ad, ab, mg, plan);
            i = i + 1;
        };
        (wins, samples)
    }

    // ===================== party (multi-member) helpers =====================
    // 组队仿真: 同一房间多名成员(各自面板+计划)打完整座地下城。成员经 #[test_only]
    // 面板 join(owner=同 signer, char_id=0 免检), 用于 D5-D9 组队胜率标定。

    fun run_duo(
        a: &signer, difficulty: u64,
        h1: u64, atk1: u64, m1: u64, s1: u64, p1: vector<u64>,
        h2: u64, atk2: u64, m2: u64, s2: u64, p2: vector<u64>,
    ): u64 {
        engine::create_room(a, difficulty);
        let room_id = skill_registry::next_room_id() - 1;
        engine::join_room(a, room_id, h1, atk1, m1, s1);
        engine::join_room(a, room_id, h2, atk2, m2, s2);
        engine::start_combat(a, room_id);
        engine::set_plan(a, room_id, 0, p1);
        engine::set_plan(a, room_id, 1, p2);
        let guard = 0;
        while (guard < 800) {
            let ph = engine::room_phase(room_id);
            if (ph == 1) { engine::advance_turn(a, room_id); }
            else if (ph == 3) { engine::advance_battle(a, room_id); }
            else { break; };
            guard = guard + 1;
        };
        if (engine::room_result(room_id) == 1) { 1 } else { 0 }
    }

    public fun clear_rate_duo(
        a: &signer, difficulty: u64, samples: u64,
        h1: u64, atk1: u64, m1: u64, s1: u64, p1: vector<u64>,
        h2: u64, atk2: u64, m2: u64, s2: u64, p2: vector<u64>,
    ): (u64, u64) {
        let wins = 0;
        let i = 0;
        while (i < samples) {
            wins = wins + run_duo(a, difficulty, h1, atk1, m1, s1, p1, h2, atk2, m2, s2, p2);
            i = i + 1;
        };
        (wins, samples)
    }

    fun run_trio(
        a: &signer, difficulty: u64,
        h1: u64, atk1: u64, m1: u64, s1: u64, p1: vector<u64>,
        h2: u64, atk2: u64, m2: u64, s2: u64, p2: vector<u64>,
        h3: u64, atk3: u64, m3: u64, s3: u64, p3: vector<u64>,
    ): u64 {
        engine::create_room(a, difficulty);
        let room_id = skill_registry::next_room_id() - 1;
        engine::join_room(a, room_id, h1, atk1, m1, s1);
        engine::join_room(a, room_id, h2, atk2, m2, s2);
        engine::join_room(a, room_id, h3, atk3, m3, s3);
        engine::start_combat(a, room_id);
        engine::set_plan(a, room_id, 0, p1);
        engine::set_plan(a, room_id, 1, p2);
        engine::set_plan(a, room_id, 2, p3);
        let guard = 0;
        while (guard < 800) {
            let ph = engine::room_phase(room_id);
            if (ph == 1) { engine::advance_turn(a, room_id); }
            else if (ph == 3) { engine::advance_battle(a, room_id); }
            else { break; };
            guard = guard + 1;
        };
        if (engine::room_result(room_id) == 1) { 1 } else { 0 }
    }

    public fun clear_rate_trio(
        a: &signer, difficulty: u64, samples: u64,
        h1: u64, atk1: u64, m1: u64, s1: u64, p1: vector<u64>,
        h2: u64, atk2: u64, m2: u64, s2: u64, p2: vector<u64>,
        h3: u64, atk3: u64, m3: u64, s3: u64, p3: vector<u64>,
    ): (u64, u64) {
        let wins = 0;
        let i = 0;
        while (i < samples) {
            wins = wins + run_trio(a, difficulty, h1, atk1, m1, s1, p1, h2, atk2, m2, s2, p2, h3, atk3, m3, s3, p3);
            i = i + 1;
        };
        (wins, samples)
    }

    fun run_four(
        a: &signer, difficulty: u64,
        h1: u64, atk1: u64, m1: u64, s1: u64, p1: vector<u64>,
        h2: u64, atk2: u64, m2: u64, s2: u64, p2: vector<u64>,
        h3: u64, atk3: u64, m3: u64, s3: u64, p3: vector<u64>,
        h4: u64, atk4: u64, m4: u64, s4: u64, p4: vector<u64>,
    ): u64 {
        engine::create_room(a, difficulty);
        let room_id = skill_registry::next_room_id() - 1;
        engine::join_room(a, room_id, h1, atk1, m1, s1);
        engine::join_room(a, room_id, h2, atk2, m2, s2);
        engine::join_room(a, room_id, h3, atk3, m3, s3);
        engine::join_room(a, room_id, h4, atk4, m4, s4);
        engine::start_combat(a, room_id);
        engine::set_plan(a, room_id, 0, p1);
        engine::set_plan(a, room_id, 1, p2);
        engine::set_plan(a, room_id, 2, p3);
        engine::set_plan(a, room_id, 3, p4);
        let guard = 0;
        while (guard < 800) {
            let ph = engine::room_phase(room_id);
            if (ph == 1) { engine::advance_turn(a, room_id); }
            else if (ph == 3) { engine::advance_battle(a, room_id); }
            else { break; };
            guard = guard + 1;
        };
        if (engine::room_result(room_id) == 1) { 1 } else { 0 }
    }

    public fun clear_rate_four(
        a: &signer, difficulty: u64, samples: u64,
        h1: u64, atk1: u64, m1: u64, s1: u64, p1: vector<u64>,
        h2: u64, atk2: u64, m2: u64, s2: u64, p2: vector<u64>,
        h3: u64, atk3: u64, m3: u64, s3: u64, p3: vector<u64>,
        h4: u64, atk4: u64, m4: u64, s4: u64, p4: vector<u64>,
    ): (u64, u64) {
        let wins = 0;
        let i = 0;
        while (i < samples) {
            wins = wins + run_four(a, difficulty, h1, atk1, m1, s1, p1, h2, atk2, m2, s2, p2, h3, atk3, m3, s3, p3, h4, atk4, m4, s4, p4);
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

    // ---- report as one [wins, total, pct-per-100k] triple per line (readable) ----
    fun report(w: u64, t: u64) {
        let pct = if (t == 0) { 0u64 } else { w * 100000 / t };
        std::debug::print(&vector[w, t, pct]);
    }

    // ===================== plan helpers =====================
    fun plan_attack(): vector<u64> { vector[1, 3] }              // 攻击 + 治疗(自循环)
    fun plan_burst(): vector<u64> { vector[24] }                 // 暴风剑(高AP消耗)自循环
    fun plan_burst_heal(): vector<u64> { vector[24, 3] }         // 暴风剑+治疗(爆发带续航)
    fun plan_swing(): vector<u64> { vector[1] }                  // 纯攻击(挖矿/低危图,无治疗空转)

    // ================================================================
    //  L1 gate check: even a maxed-out level-1 must NOT clear D3 / D4.
    //  Maxed L1 = best class/race (守卫×巨人) + tier-10 affix on every stat.
    //  守卫 hp_pct150 atk115 mag90 spd90; 巨人 hp+400 atk+300 mag-200 spd-300
    //  → hp=100×(1000+150+400+2000) /1000 = 355
    //    atk=10×(1000+115+300+2000)/1000 = 34, mag=28, spd=27
    // ================================================================
    #[test]
    fun sim_level1_gate_d34() {
        let a = &std::account::create_account_for_test(@mohayo);
        reg(a);
        // D3: 3 battles (兽人士兵×3 → 兽人战士×3 → 兽人酋长×1)
        let (w3, t3) = clear_rate_affixed(a, 3, 15, 355, 34, 28, 27, 0, 0, 0, 0, plan_attack());
        report(w3, t3);
        // D4: 3 battles (幽灵×3 → 石魔像 → 守卫石像)
        let (w4, t4) = clear_rate_affixed(a, 4, 15, 355, 34, 28, 27, 0, 0, 0, 0, plan_attack());
        report(w4, t4);
        // even with every resource affix maxed, DPS is far below the 120-turn budget
        let (w3r, t3r) = clear_rate_affixed(a, 3, 15, 355, 34, 28, 27, 2, 2, 2, 2, plan_attack());
        report(w3r, t3r);
        let (w4r, t4r) = clear_rate_affixed(a, 4, 15, 355, 34, 28, 27, 2, 2, 2, 2, plan_attack());
        report(w4r, t4r);
        assert!(w3 == 0 && w4 == 0 && w3r == 0 && w4r == 0, 1);
    }

    // ================================================================
    //  Growth ladder across the early dungeons so D3/D4 visibly sit above
    //  the level-1 reach but are clearable once the player has levelled.
    // ================================================================
    #[test]
    fun sim_early_ladder() {
        let a = &std::account::create_account_for_test(@mohayo);
        reg(a);
        // level-1 (maxed talent): D1 D2 D3 D4
        let (w1, t1) = clear_rate(a, 1, 15, 355, 34, 28, 27, plan_attack()); report(w1, t1);
        let (w2, t2) = clear_rate(a, 2, 15, 355, 34, 28, 27, plan_attack()); report(w2, t2);
        let (w3, t3) = clear_rate(a, 3, 15, 355, 34, 28, 27, plan_attack()); report(w3, t3);
        let (w4, t4) = clear_rate(a, 4, 15, 355, 34, 28, 27, plan_attack()); report(w4, t4);
        // level ~40 (hp 4000 atk 3200 mag 1600 spd 200): D1 D2 D3 D4
        let (w5, t5) = clear_rate(a, 1, 15, 4000, 3200, 1600, 200, plan_attack()); report(w5, t5);
        let (w6, t6) = clear_rate(a, 2, 15, 4000, 3200, 1600, 200, plan_attack()); report(w6, t6);
        let (w7, t7) = clear_rate(a, 3, 15, 4000, 3200, 1600, 200, plan_attack()); report(w7, t7);
        let (w8, t8) = clear_rate(a, 4, 15, 4000, 3200, 1600, 200, plan_attack()); report(w8, t8);
    }

    #[test]
    fun DBG_d9_single() {
        let a = &std::account::create_account_for_test(@mohayo);
        reg(a);
        engine::create_room(a, 9);
        let room_id = skill_registry::next_room_id() - 1;
        engine::join_room(a, room_id, 30000, 26000, 13000, 600);
        engine::start_combat(a, room_id);
        engine::set_plan(a, room_id, 0, plan_attack());
        let guard = 0;
        while (guard < 700) {
            let ph = engine::room_phase(room_id);
            let (mhp, _, _, _, _, _) = engine::member_state(room_id, 0);
            let ec = engine::enemy_count(room_id);
            std::debug::print(&vector[guard, (ph as u64), mhp, ec]);
            if (ph == 1) { engine::advance_turn(a, room_id); }
            else if (ph == 3) { engine::advance_battle(a, room_id); }
            else { break; };
            guard = guard + 1;
        };
        std::debug::print(&vector[999, (engine::room_result(room_id) as u64)]);
    }

    // ================================================================
    //  D5 solo band: a strong near-max solo should clear 80–90%.
    // ================================================================
    #[test]
    fun sim_d5_solo_band() {
        let a = &std::account::create_account_for_test(@mohayo);
        reg(a);
        let (w, t) = clear_rate(a, 5, 60, 30000, 26000, 13000, 600, plan_attack());
        // D5 strong solo band target 80–90% ⇒ 48..54 wins out of 60.
        report(w, t);
        assert!(w >= 44 && w <= 56, 1);
    }

    // ================================================================
    //  D9 must stay strictly harder than D5 for the same build.
    // ================================================================
    #[test]
    fun sim_d9_harder_than_d5() {
        let a = &std::account::create_account_for_test(@mohayo);
        reg(a);
        // 样本刻意取小(8): D9 solo 对 near-max 也近乎必败, 每场都拖到 120 回合清退,
        // 大样本会令测试超时(此前 40 样本即超时)。
        let (w5, t5) = clear_rate(a, 5, 8, 30000, 26000, 13000, 600, plan_attack());
        // D5
        report(w5, t5);
        let (w9, t9) = clear_rate(a, 9, 8, 30000, 26000, 13000, 600, plan_attack());
        // D9
        report(w9, t9);
        assert!(w9 <= w5, 1);
        assert!(t9 >= 5, 2); // legibility guard only
    }

    // ================================================================
    //  Resource-affix chaining: identical flat stats, only the resource-affix
    //  fields differ. A costly burst skill (暴风剑 id 24: ap 3 / mana 5) needs
    //  3 AP and 5 mana; on D1's 2-mana/turn mine the average build fires it
    //  ~every 3rd turn, so grinding 巨型魔素岩 drags to/past the 120-turn cap;
    //  a build with ap_discount 2 + ap_bonus 2 (+ mana -2/+2) fires it EVERY
    //  turn and clears comfortably. 舞台选 D1(无伤时间赛跑)而非 D5: D5 敌伤
    //  极高时玻璃炮无论有无词条都是 0 胜, 分层被淹没 —— 资源词条的本质是
    //  "连续施放大技的能力", 时间赛跑是最干净的观测场(挖矿=连续大招)。
    // ================================================================
    #[test]
    fun sim_resource_chain_power() {
        let a = &std::account::create_account_for_test(@mohayo);
        reg(a);
        let (wa, ta) = clear_rate(a, 1, 25, 4000, 95, 100, 80, plan_burst());
        // D1 average(no affix) burst-only
        report(wa, ta);
        let (wt, tt) = clear_rate_affixed(a, 1, 25, 4000, 95, 100, 80, 2, 2, 2, 2, plan_burst());
        // D1 talented(ap/md-2, ap/mg+2) burst-only
        report(wt, tt);
        // 天赋必须显著优于平民(连发大招的能力); 平民挖巨型魔素岩大概率超时清退
        assert!(wt > wa, 1);
        assert!(wa <= 8, 2);   // 平民至多 1/3 挖穿(其余被 120 回合清退阀清退)
        assert!(wt >= 22, 3);  // 天赋基本能连发挖穿
    }

    // ================================================================
    //  D1 mining gradient (灰烬矿坑, 免费挖矿, 敌人全部待机不还手):
    //  ① 平凡 1 级(人类守卫, 无词条: hp109/atk10) 极可能赢第 1 场 —— 保底体验;
    //  ② 但打不穿整座矿坑(后续大魔素岩血量按回合预算拉高 → 超时清退);
    //  ③ 满天赋 1 级(hp355/atk34) 能过 b2;
    //  ④ 中坚矿工(atk≈135, ~Lv12) 在 b3 大魔素岩处"并不轻松": 部分样本被 120
    //     回合清退阀清退 —— 挖矿有"见好就收"(打完前几场逃离)的策略空间;
    //  ⑤ Lv≈30(atk≈340) 能挖穿全部 4 场。
    // ================================================================
    #[test]
    fun sim_d1_gradient() {
        let a = &std::account::create_account_for_test(@mohayo);
        reg(a);
        let (w1, t1) = clear_nb_rate(a, 1, 20, 109, 10, 10, 10, 1, plan_swing());  // 平凡1级 b1
        report(w1, t1);
        let (wf, tf) = clear_nb_rate(a, 1, 20, 109, 10, 10, 10, 4, plan_swing());   // 平凡1级 全程
        report(wf, tf);
        let (w2, t2) = clear_nb_rate(a, 1, 20, 355, 34, 28, 27, 2, plan_swing());   // 满天赋1级 b2
        report(w2, t2);
        let (w3, t3) = clear_nb_rate(a, 1, 20, 1300, 135, 130, 100, 3, plan_swing()); // 中坚 b3
        report(w3, t3);
        let (wh, th) = clear_nb_rate(a, 1, 20, 3300, 340, 300, 200, 4, plan_swing()); // Lv30 全程
        report(wh, th);
        assert!(w1 >= 17, 1);   // 平凡1级 b1 ≥85%
        assert!(wf <= 2, 2);    // 平凡1级 全程 ≤10%
        assert!(w2 >= 18, 3);   // 满天赋1级 b2 ≥90%
        assert!(w3 >= 12 && w3 <= 17, 4); // 中坚 b3 60%~85% 通过 → 20%~40% 被超时清退(大魔素岩不轻松)
        assert!(wh >= 17, 5);   // Lv30 挖穿 ≥85%
    }

    // ================================================================
    //  D2 reachability: a maxed-out level-1 (能力词条全 t10 + 全资源词条
    //  ap折扣2/ap产量2/魔素折扣2/魔素产量2) driving 暴风剑+治疗 every turn is a
    //  "极强天赋" build. Design intent: D2 (机仆残骸+藤蔓) 对 1 级仅"说不定能赢"——
    //  顶级天赋也只有小概率(~10%)通过; 方差核心是唤魔藤蔓的缠绕眩晕(50%×2行动回合)
    //  与机仆随机宕机, 而非单纯面板碾压。普通/无天赋 1 级打不穿(门槛仍在)。
    // ================================================================
    #[test]
    fun sim_d2_l1_talented() {
        let a = &std::account::create_account_for_test(@mohayo);
        reg(a);
        // 对照组: 同面板无资源词条(普攻循环) — 不应能通 D2
        let (wp, tp) = clear_rate(a, 2, 20, 355, 34, 28, 27, plan_attack());
        report(wp, tp);
        // 观察: 无资源词条的爆发+治疗流(不做断言——资源天赋分层由 D5 资源链测试承担)
        let (wb, tb) = clear_rate(a, 2, 20, 355, 34, 28, 27, plan_burst_heal());
        report(wb, tb);
        // 极强天赋: 资源词条全拉满 + 爆发带续航循环
        let (wt, tt) = clear_rate_affixed(a, 2, 20, 355, 34, 28, 27, 2, 2, 2, 2, plan_burst_heal());
        report(wt, tt);
        assert!(wt >= 1 && wt <= 4, 1); // 极强天赋1级对D2: 小概率通过(约10%, "说不定能赢")
        assert!(wp == 0, 2);            // 无天赋普攻流1级打不穿D2(门槛仍存在)
    }

    // ================================================================
    //  技能归属红线(用户定案): 玩家的技能只来自 职业/种族/自选池 三来源。
    //  a) 创建端: 自选池逐 id 白名单(1..=44 玩家区), 敌技(45+)被拒;
    //  b) 执行端: 生产入口 join_room_as_char 绑定角色, set_plan 提交时校验
    //     计划技能 ∈ Character.skill_ids(权威源=角色自身存储), 敌技无法进计划;
    //  c) 只能给自己排(owner 校验), 他人不可代排。
    // ================================================================
    // b) 敌技进计划被拒: 生产 join 后 set_plan 排敌技(45) → E_SKILL_NOT_OWNED(20)
    #[test]
    #[expected_failure(abort_code = 20)]
    fun sim_skill_ownership_enemy_plan_rejected() {
        let a = &std::account::create_account_for_test(@mohayo);
        reg(a);
        let own = std::signer::address_of(a);
        character::gm_mint(a, own, 1, 2, vector[0, 0, 0, 0], vector[39, 43]);
        let char_id = character::owner_latest_char(own);
        engine::create_room(a, 1);
        let room_id = skill_registry::next_room_id() - 1;
        engine::join_room_as_char(a, room_id, char_id);
        engine::start_combat(a, room_id);
        engine::set_plan(a, room_id, 0, vector[45]); // 火花锯=敌技 → abort 20
    }

    // c) 他人不可代排: 非 owner 的地址 set_plan → E_NOT_PLAN_OWNER(19)
    #[test]
    #[expected_failure(abort_code = 19)]
    fun sim_skill_ownership_foreign_plan_rejected() {
        let a = &std::account::create_account_for_test(@mohayo);
        reg(a);
        let own = std::signer::address_of(a);
        character::gm_mint(a, own, 1, 2, vector[0, 0, 0, 0], vector[39, 43]);
        let char_id = character::owner_latest_char(own);
        engine::create_room(a, 1);
        let room_id = skill_registry::next_room_id() - 1;
        engine::join_room_as_char(a, room_id, char_id);
        engine::start_combat(a, room_id);
        let b = &std::account::create_account_for_test(@0xCAFE);
        engine::set_plan(b, room_id, 0, vector[1]); // b 不是成员 owner → abort 19
    }

    // d) 自选敌技在创建端被拒: gm_mint 自选列表含敌技(45) → E_SKILL_NOT_POOL(4)
    #[test]
    #[expected_failure(abort_code = 4)]
    fun sim_skill_ownership_enemy_self_select_rejected() {
        let a = &std::account::create_account_for_test(@mohayo);
        reg(a);
        character::gm_mint(a, std::signer::address_of(a), 1, 2, vector[0, 0, 0, 0], vector[45]);
    }

    // d2) 自选他人职业技被拒(31=守卫专属盾击) → E_SKILL_NOT_POOL(4)
    #[test]
    #[expected_failure(abort_code = 4)]
    fun sim_skill_ownership_class_skill_rejected() {
        let a = &std::account::create_account_for_test(@mohayo);
        reg(a);
        character::gm_mint(a, std::signer::address_of(a), 3, 2, vector[0, 0, 0, 0], vector[31]);
    }

    // d3) 自选种族技被拒(12=兽人专属狂暴) → E_SKILL_NOT_POOL(4)
    #[test]
    #[expected_failure(abort_code = 4)]
    fun sim_skill_ownership_race_skill_rejected() {
        let a = &std::account::create_account_for_test(@mohayo);
        reg(a);
        character::gm_mint(a, std::signer::address_of(a), 1, 2, vector[0, 0, 0, 0], vector[12]);
    }

    // e) 生产链路端到端: 合法计划可提交并推进战斗
    #[test]
    fun sim_skill_ownership_owned_plan_ok() {
        let a = &std::account::create_account_for_test(@mohayo);
        reg(a);
        let own = std::signer::address_of(a);
        character::gm_mint(a, own, 1, 2, vector[0, 0, 0, 0], vector[39]); // 守卫仅1自选槽(池技:急救包扎)
        let char_id = character::owner_latest_char(own);
        engine::create_room(a, 1);
        let room_id = skill_registry::next_room_id() - 1;
        engine::join_room_as_char(a, room_id, char_id);
        engine::start_combat(a, room_id);
        // 计划=自选急救(39)+守卫职业技盾击(31), 均在技能集内 → 应通过
        engine::set_plan(a, room_id, 0, vector[39, 31]);
        let guard = 0;
        while (guard < 40) {
            let ph = engine::room_phase(room_id);
            if (ph == 1) { engine::advance_turn(a, room_id); }
            else if (ph == 3) { engine::advance_battle(a, room_id); }
            else { break; };
            guard = guard + 1;
        };
        // 能跑到这里即说明归属校验不误伤合法计划(角色血薄, 被碎石磨死也属正常模拟)
        assert!(guard > 0, 1);
    }

    // ================================================================
    //  中后期梯度: D5(成长分水岭, ~85%) → D6 亡者回廊 → D7 熔渊龙巢 →
    //  D8 虚空裂隙(接近顶配) → D9 机神帝座(顶点)。near-max solo 通关率应随
    //  难度单调下降, 且 D8 以下不该把近满级队挡死(留出组队/词条提升空间)。
    // ================================================================
    #[test]
    fun sim_late_ladder() {
        let a = &std::account::create_account_for_test(@mohayo);
        reg(a);
        let (w5, t5) = clear_rate(a, 5, 15, 30000, 26000, 13000, 600, plan_attack());
        report(w5, t5);
        let (w6, t6) = clear_rate(a, 6, 15, 30000, 26000, 13000, 600, plan_attack());
        report(w6, t6);
        let (w7, t7) = clear_rate(a, 7, 15, 30000, 26000, 13000, 600, plan_attack());
        report(w7, t7);
        let (w8, t8) = clear_rate(a, 8, 15, 30000, 26000, 13000, 600, plan_attack());
        report(w8, t8);
        assert!(w5 >= 12, 1);   // D5 solo 高胜率(参考 80-90% 带)
        assert!(w6 >= w7 && w7 >= w8, 2); // 难度单调递进
        assert!(w8 >= 1, 3);    // near-max 打 D8 留有胜面(非全灭)
    }

    // ================================================================
    //  真实角色端到端: 守卫(31盾击, 挂 TAUNT) 在双人房间拉走全部单体火力 ——
    //  走生产链路 gm_mint_at_level → join_room_as_char → 双成员独立计划。
    //  覆写 D3 为单场 1 只祭司/怨灵(单体魔攻技 targeting1), mana 给足。
    //  判定: 守卫掉血 >> 脆皮(比值>3) —— taunt 未实现时两者掉血接近。
    // ================================================================
    #[test]
    fun sim_guard_taunt_e2e() {
        let a = &std::account::create_account_for_test(@mohayo);
        reg(a);
        let own = std::signer::address_of(a);
        character::gm_mint_at_level(a, own, 1, 2, vector[0, 0, 0, 0], vector[39], 40); // 守卫×巨人
        let guard = character::owner_latest_char(own);
        character::gm_mint_at_level(a, own, 3, 0, vector[0, 0, 0, 0], vector[43], 40); // 人类黑魔(脆皮)
        let squishy = character::owner_latest_char(own);
        // 覆写 D3: 单场 1 敌, 表10(祭司850/怨灵150), 两者技能均为 targeting1 单体
        skill_registry::set_dungeon(a, 3, mohayo::types::make_dungeon_config(10, 1, 15, 0, 0, 0, 120, 1));
        skill_registry::set_dungeon_battles(a, 3, vector[mohayo::types::make_battle_config(10, 1)]);
        engine::create_room(a, 3);
        let room_id = skill_registry::next_room_id() - 1;
        engine::join_room_as_char(a, room_id, guard);
        engine::join_room_as_char(a, room_id, squishy);
        engine::start_combat(a, room_id);
        engine::set_plan(a, room_id, 0, vector[31]); // 守卫: 每回盾击(眩晕40%+嘲讽2轮)
        engine::set_plan(a, room_id, 1, vector[]);   // 脆皮: 空过
        let guard_i = 0;
        while (guard_i < 8) { engine::advance_turn(a, room_id); guard_i = guard_i + 1; };
        let (gh, gmax, _, _, _, _) = engine::member_state(room_id, 0);
        let (sh, smax, _, _, _, _) = engine::member_state(room_id, 1);
        let guard_drop = gmax - gh;
        let squish_drop = smax - sh;
        std::debug::print(&vector[guard_drop, squish_drop]);
        assert!(guard_drop > 0, 1);     // 守卫确实吃到单体火力
        assert!(squish_drop == 0, 2);   // 嘲讽拉怪: 脆皮全程零受击(taunt 未实现时脆皮会吃 2~4 击)
    }

    // ================================================================
    //  多人魔素聚合(校验#4 多人面): 房间 mana 池每回合 = mana_per_turn +
    //  Σ(存活成员 mana_gain_bonus)。两名成员各带「魔素产量+1」词条 →
    //  D1(mana2) 每回合 +4。多人堆魔素词条 = 大魔法连续施放的基础(共享池曲线)。
    // ================================================================
    #[test]
    fun sim_multi_mana_regen() {
        let a = &std::account::create_account_for_test(@mohayo);
        reg(a);
        engine::create_room(a, 1);
        let room_id = skill_registry::next_room_id() - 1;
        engine::join_room_affixed(a, room_id, 4000, 300, 300, 100, 0, 0, 0, 1); // A: 魔素产量+1
        engine::join_room_affixed(a, room_id, 4000, 300, 300, 100, 0, 0, 0, 1); // B: 魔素产量+1
        engine::start_combat(a, room_id);
        // 两成员都空过(plan 空, 不消耗 mana): 池应每回合 + (2 + 1 + 1) = +4
        engine::set_plan(a, room_id, 0, vector[]);
        engine::set_plan(a, room_id, 1, vector[]);
        let gi = 0;
        while (gi < 5) { engine::advance_turn(a, room_id); gi = gi + 1; };
        let pool = engine::room_mana(room_id);
        std::debug::print(&vector[pool]);
        // 起点 mana2(mana_per_turn) + 5 回合 × 4 = 22; 若多人词条未被聚合则 2+5×2=12
        assert!(pool == 22, 1);
    }

    // ================================================================
    //  毒刃 DOT 数值护栏(DOT 20×3 + 同源刷新不累加): 平凡1级带毒刃不应磨穿 D1
    //  (b4 巨型 2600 → 120 回合超时), 但 b1 保底仍能挖; 满天赋1级(直伤加成)仍可穿——
    //  顶配特权, 与"很强天赋可越级"的叙事一致。防 DOT 数值回弹(150×3 曾 100% 挖穿)。
    // ================================================================
    #[test]
    fun sim_poison_d1_gate() {
        let a = &std::account::create_account_for_test(@mohayo);
        reg(a);
        let (p1, t1) = clear_nb_rate(a, 1, 10, 109, 10, 10, 10, 1, vector[10]); // 平凡1级毒刃 b1
        report(p1, t1);
        let (pf, tf) = clear_rate(a, 1, 10, 109, 10, 10, 10, vector[10]);      // 平凡1级毒刃 全程
        report(pf, tf);
        let (m1, m2) = clear_rate(a, 1, 10, 355, 34, 28, 27, vector[10]);      // 满天赋1级毒刃 全程(观察)
        report(m1, m2);
        assert!(p1 >= 8, 1);  // b1 保底可挖
        assert!(pf <= 2, 2);  // 平凡1级磨不穿 D1(b4 超时)
    }

    // ================================================================
    //  组队观察: near-max 面板 双人/三人 vs D5/D9。把 D9"满编组队也未必通关"
    //  从定性变成可测量曲线。计划: 成员0=输出带奶(攻击+治疗), 其余=暴风剑带奶。
    // ================================================================
    #[test]
    fun sim_party_observe() {
        let a = &std::account::create_account_for_test(@mohayo);
        reg(a);
        // near-max duo/trio vs D5/D9 (顶配面板对照)
        let (d5a, d5t) = clear_rate_duo(a, 5, 3,
            30000, 26000, 13000, 600, plan_attack(),
            26000, 22000, 15000, 550, plan_burst_heal());
        report(d5a, d5t);
        let (d9a, d9t) = clear_rate_duo(a, 9, 10,
            30000, 26000, 13000, 600, plan_attack(),
            26000, 22000, 15000, 550, plan_burst_heal());
        report(d9a, d9t);
        let (t9a, t9t) = clear_rate_trio(a, 9, 10,
            30000, 26000, 13000, 600, plan_attack(),
            26000, 22000, 15000, 550, plan_burst_heal(),
            24000, 18000, 18000, 600, plan_burst_heal());
        report(t9a, t9t);
        // 常规满级队(人类剑士无词条 Lv300 ≈ 33150/3390/3315/3360) duo/trio vs D9
        // 常规队无资源词条 → 用 攻击+治疗 基本循环(非暴风剑资源流)
        let (cd9a, cd9t) = clear_rate_duo(a, 9, 3,
            33150, 3390, 3315, 3360, plan_attack(),
            33150, 3390, 3315, 3360, plan_attack());
        report(cd9a, cd9t);
        let (ct9a, ct9t) = clear_rate_trio(a, 9, 3,
            33150, 3390, 3315, 3360, plan_attack(),
            33150, 3390, 3315, 3360, plan_attack(),
            33150, 3390, 3315, 3360, plan_attack());
        report(ct9a, ct9t);
        // 常规满级 4 人满编 vs D9(文档 §3.1 目标对象: 合理职业搭配满级队)
        let (f4a, f4t) = clear_rate_four(a, 9, 3,
            33150, 3390, 3315, 3360, plan_attack(),
            33150, 3390, 3315, 3360, plan_attack(),
            33150, 3390, 3315, 3360, plan_attack(),
            33150, 3390, 3315, 3360, plan_attack());
        report(f4a, f4t);
    }

    // ================================================================
    //  黑魔献祭(34): 烧血 4 段魔法攻击 + 每段命中为房间池产魔素 —— 验证输出与产魔同时成立。
    //  覆写 D1 为单只巨型魔素岩(2600hp 待机), 黑魔 Lv40 纯献祭循环 2 回合。
    // ================================================================
    #[test]
    fun sim_sacrifice_mana() {
        let a = &std::account::create_account_for_test(@mohayo);
        reg(a);
        let own = std::signer::address_of(a);
        character::gm_mint_at_level(a, own, 3, 0, vector[0, 0, 0, 0], vector[43], 40); // 人类黑魔 Lv40
        let cid = character::owner_latest_char(own);
        skill_registry::set_dungeon(a, 1, mohayo::types::make_dungeon_config(4, 1, 2, 0, 0, 0, 120, 1));
        skill_registry::set_dungeon_battles(a, 1, vector[mohayo::types::make_battle_config(4, 1)]);
        engine::create_room(a, 1);
        let room_id = skill_registry::next_room_id() - 1;
        engine::join_room_as_char(a, room_id, cid);
        engine::start_combat(a, room_id);
        engine::set_plan(a, room_id, 0, vector[34]);
        engine::advance_turn(a, room_id);
        engine::advance_turn(a, room_id);
        let pool = engine::room_mana(room_id);
        let (eh, _, _, _, _, _) = engine::enemy_state(room_id, 0);
        std::debug::print(&vector[pool, eh]);
        // 魔素池: 自然 2+2×2=6 之外, 命中产魔应显著推高; 巨岩应已受创
        assert!(pool > 30, 1);   // 献祭每段命中 +10 × ~4 段 × 2 施放 ≈ +70(命中率扣减)
        assert!(eh < 2600, 2);   // 多段攻击确实在输出
    }

    // ================================================================
    //  白魔替身人偶(38): FLAG_SUMMON_ALLY 召唤无行动己方假目标 → 成员数增长。
    // ================================================================
    #[test]
    fun sim_decoy_summon() {
        let a = &std::account::create_account_for_test(@mohayo);
        reg(a);
        let own = std::signer::address_of(a);
        character::gm_mint_at_level(a, own, 4, 0, vector[0, 0, 0, 0], vector[43], 40); // 人类白魔 Lv40
        let cid = character::owner_latest_char(own);
        skill_registry::set_dungeon(a, 1, mohayo::types::make_dungeon_config(1, 1, 8, 0, 0, 0, 120, 1));
        skill_registry::set_dungeon_battles(a, 1, vector[mohayo::types::make_battle_config(1, 2)]);
        engine::create_room(a, 1);
        let room_id = skill_registry::next_room_id() - 1;
        engine::join_room_as_char(a, room_id, cid);
        engine::start_combat(a, room_id);
        engine::set_plan(a, room_id, 0, vector[38]); // 每回召唤一人偶
        let gi = 0;
        while (gi < 5) { engine::advance_turn(a, room_id); gi = gi + 1; };
        let mc = engine::member_count(room_id);
        std::debug::print(&vector[mc]);
        assert!(mc >= 3, 1); // 白魔 + ≥2 只人偶(mana 8/回合 足够每回招)
    }
}
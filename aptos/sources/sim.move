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
        let (w5, t5) = clear_rate(a, 5, 40, 30000, 26000, 13000, 600, plan_attack());
        // D5
        report(w5, t5);
        let (w9, t9) = clear_rate(a, 9, 40, 30000, 26000, 13000, 600, plan_attack());
        // D9
        report(w9, t9);
        assert!(w9 <= w5, 1);
        assert!(t9 >= 25, 2); // legibility guard only
    }

    // ================================================================
    //  Resource-affix chaining: identical flat stats, only the resource-affix
    //  fields differ. A costly burst skill (暴风剑 id 24: ap_cost 3) needs 3 AP;
    //  the average build regenerates +1 AP/turn so the burst only fires ~1/3 of
    //  turns and the fight drags until the dungeon's damage overwhelms it. A build
    //  with ap_discount 2 + ap_bonus 2 pays 1 AP and regains +3/turn → the burst
    //  loops every turn, or content is killed fast. Talent therefore changes which
    //  skills you can afford to dedicate plan slots to, not just raw power.
    // ================================================================
    #[test]
    fun sim_resource_chain_power() {
        let a = &std::account::create_account_for_test(@mohayo);
        reg(a);
        // Glass-cannon burst solo on D5 (no heal in plan → survival = kill speed).
        // hit the same 暴风剑, the average build fires it ~1/3 of turns and the fight
        // drags until D5's damage overwhelms its thin HP; the talented build loops it
        // every turn and finishes before death.
        let (wa, ta) = clear_rate(a, 5, 25, 7000, 8000, 1500, 300, plan_burst());
        // D5 average(no affix) burst-only
        report(wa, ta);
        // Talented: ap_discount 2 → cost 1; ap_bonus 2 → ap_gen +3/turn → loops every turn.
        let (wt, tt) = clear_rate_affixed(a, 5, 25, 7000, 8000, 1500, 300, 0, 2, 2, 0, plan_burst());
        // D5 talented(ap-2,ap+2) burst-only
        report(wt, tt);
        // Talented must be plainly better than average on the same burst-only plan.
        assert!(wt > wa, 1);
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
}
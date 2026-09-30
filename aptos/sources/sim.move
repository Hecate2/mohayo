/// Phase 5 — Monte-Carlo dungeon-clearance simulator.
///
/// Runs the FULL production combat engine (`mohayo::engine`) over many room seeds
/// (each distinct `room_id` = a distinct deterministic random sample) for a given
/// dungeon and a single-player build, then reports the clearance rate. This is the
/// tuning harness used to fine-tune dungeon/skill/enemy values (e.g. the D5 solo band
/// of 80–90%, the level-1 gate against D3/D4, and the resource-affix chaining check).
/// It is `#[test_only]`: it depends on test-only initializers and is never deployed.
#[test_only]
module mohayo::sim {
    use std::vector;
    use mohayo::engine;
    use mohayo::item;
    use mohayo::character;
    use mohayo::skill_registry;
    use mohayo::content_registration;
    use mohayo::use_item;
    use mohayo::economy;

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

    // ===================== 统一执行器 =====================
    // 此前 run / run_n / run_duo / run_trio / run_four / run_pro4 是六份近乎克隆的实现,
    // 只有「建几个成员、谁来建」不同。循环体、结果判定与 guard 语义现在只在 drive 一处。

    /// 面板入房(测试通道)。四项资源词条全 0 时走普通 join, 否则走带词条的 join。
    fun join_panel(
        a: &signer, room_id: u64, hp: u64, atk: u64, mag: u64, spd: u64,
        md: u16, ad: u16, ab: u16, mg: i64,
    ) {
        if (md == 0 && ad == 0 && ab == 0 && mg == 0) {
            engine::join_room(a, room_id, hp, atk, mag, spd);
        } else {
            engine::join_room_affixed(a, room_id, hp, atk, mag, spd, md, ad, ab, mg);
        };
    }

    /// 把一战推到结算, 返回是否通关。
    /// `stop_nb > 0` 时「打到第 stop_nb 场」即算过(用于观察中途关卡的门槛);
    /// `stop_nb = 0` 表示打完整座地下城。`guard_cap` 是循环上限保护(不同规模队伍留的余量不同)。
    fun drive(a: &signer, room_id: u64, stop_nb: u64, guard_cap: u64): u64 {
        let guard = 0;
        while (guard < guard_cap) {
            let ph = engine::room_phase(room_id);
            if (ph == 1) {
                step(a, room_id);
            } else if (ph == 3) {
                let (bi, _total) = engine::room_battle(room_id);
                if (stop_nb > 0 && bi >= stop_nb) { return 1; };
                engine::advance_battle_test(a, room_id);
            } else {
                break;
            };
            guard = guard + 1;
        };
        if (engine::room_result(room_id) == 1) { 1 } else { 0 }
    }

    /// 单人（可选资源词条）。`stop_nb = 0` 等价于打到底。
    fun run_n(
        a: &signer, difficulty: u64,
        hp: u64, atk: u64, mag: u64, spd: u64,
        md: u16, ad: u16, ab: u16, mg: i64,
        stop_nb: u64, plan: vector<u64>,
    ): u64 {
        engine::create_room(a, difficulty);
        let room_id = skill_registry::next_room_id() - 1;
        join_panel(a, room_id, hp, atk, mag, spd, md, ad, ab, mg);
        engine::start_combat_test(a, room_id);
        engine::set_plan(a, room_id, 0, plan);
        drive(a, room_id, stop_nb, 600)
    }

    fun run(
        a: &signer, difficulty: u64,
        hp: u64, atk: u64, mag: u64, spd: u64,
        md: u16, ad: u16, ab: u16, mg: i64,
        plan: vector<u64>,
    ): u64 {
        run_n(a, difficulty, hp, atk, mag, spd, md, ad, ab, mg, 0, plan)
    }

    /// 单人通关率(样本数 → (胜, 总))。
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

    /// 单人通关率(带资源词条)。
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

    fun rate_of(a: &signer, difficulty: u64, samples: u64, stats: vector<u64>, plans: vector<vector<u64>>): (u64, u64) {
        let wins = 0;
        let i = 0;
        while (i < samples) {
            wins = wins + run_party(a, difficulty, stats, plans, 800);
            i = i + 1;
        };
        (wins, samples)
    }

    public fun clear_rate_duo(
        a: &signer, difficulty: u64, samples: u64,
        h1: u64, atk1: u64, m1: u64, s1: u64, p1: vector<u64>,
        h2: u64, atk2: u64, m2: u64, s2: u64, p2: vector<u64>,
    ): (u64, u64) {
        rate_of(a, difficulty, samples,
            vector[h1, atk1, m1, s1, h2, atk2, m2, s2], vector[p1, p2])
    }

    public fun clear_rate_trio(
        a: &signer, difficulty: u64, samples: u64,
        h1: u64, atk1: u64, m1: u64, s1: u64, p1: vector<u64>,
        h2: u64, atk2: u64, m2: u64, s2: u64, p2: vector<u64>,
        h3: u64, atk3: u64, m3: u64, s3: u64, p3: vector<u64>,
    ): (u64, u64) {
        rate_of(a, difficulty, samples,
            vector[h1, atk1, m1, s1, h2, atk2, m2, s2, h3, atk3, m3, s3], vector[p1, p2, p3])
    }

    public fun clear_rate_four(
        a: &signer, difficulty: u64, samples: u64,
        h1: u64, atk1: u64, m1: u64, s1: u64, p1: vector<u64>,
        h2: u64, atk2: u64, m2: u64, s2: u64, p2: vector<u64>,
        h3: u64, atk3: u64, m3: u64, s3: u64, p3: vector<u64>,
        h4: u64, atk4: u64, m4: u64, s4: u64, p4: vector<u64>,
    ): (u64, u64) {
        rate_of(a, difficulty, samples,
            vector[h1, atk1, m1, s1, h2, atk2, m2, s2, h3, atk3, m3, s3, h4, atk4, m4, s4],
            vector[p1, p2, p3, p4])
    }

    /// 组队执行器: 面板入房, `stats` 每 4 个一组(hp, atk, mag, spd), `plans` 与成员一一对应。
    fun run_party(
        a: &signer, difficulty: u64,
        stats: vector<u64>, plans: vector<vector<u64>>, guard_cap: u64,
    ): u64 {
        engine::create_room(a, difficulty);
        let room_id = skill_registry::next_room_id() - 1;
        let n = vector::length(&plans);
        let i = 0;
        while (i < n) {
            join_panel(
                a, room_id,
                *vector::borrow(&stats, i * 4), *vector::borrow(&stats, i * 4 + 1),
                *vector::borrow(&stats, i * 4 + 2), *vector::borrow(&stats, i * 4 + 3),
                0, 0, 0, 0,
            );
            i = i + 1;
        };
        engine::start_combat_test(a, room_id);
        let j = 0;
        while (j < n) {
            engine::set_plan(a, room_id, j, *vector::borrow(&plans, j));
            j = j + 1;
        };
        drive(a, room_id, 0, guard_cap)
    }

    // 真实角色 4 人队执行器: 4 个已 mint 的角色(生产链路 join_room_as_char) + 各自计划。
    // 用于"职业互补组队"观测(守卫坦克/白魔奶/黑魔献祭/剑士输出)。
    fun run_pro4(
        a: &signer, difficulty: u64,
        c1: u64, p1: vector<u64>, c2: u64, p2: vector<u64>,
        c3: u64, p3: vector<u64>, c4: u64, p4: vector<u64>,
    ): u64 {
        engine::create_room(a, difficulty);
        let room_id = skill_registry::next_room_id() - 1;
        engine::join_room_as_char(a, room_id, c1);
        engine::join_room_as_char(a, room_id, c2);
        engine::join_room_as_char(a, room_id, c3);
        engine::join_room_as_char(a, room_id, c4);
        engine::start_combat_test(a, room_id);
        engine::set_plan(a, room_id, 0, p1);
        engine::set_plan(a, room_id, 1, p2);
        engine::set_plan(a, room_id, 2, p3);
        engine::set_plan(a, room_id, 3, p4);
        drive(a, room_id, 0, 900)
    }

    fun reg(a: &signer) {
        character::init_for_test(a);
        skill_registry::init_for_test(a);
        engine::init_for_test(a);
        use_item::init_for_test(a);
        use_item::set_window_limit(a, 1000); // 仿真需成千上万次开房
        init_timestamp();                      // 入场次数门控读 timestamp::now_seconds

        economy::init_for_test(a);
        // 测试钱包：覆盖入场费/救援费/收益结算链路(生产走真实玩家余额)
        economy::gm_mint(a, @mohayo, 1000000000);
        content_registration::register_all_content(a);
    }

    /// 推进一步(测试/仿真用): 先过 ≥2 秒推进冷却, 再以**当前 turn_id** 作为期望值调用
    /// —— 同时覆盖 §4.1 的自动/手动同入口与 §3.1 的「turnId 单调 + 冷却」两道防重。
    fun step(who: &signer, room_id: u64) {
        let t = aptos_framework::timestamp::now_seconds();
        aptos_framework::timestamp::update_global_time_for_test_secs(t + 2);
        engine::advance_turn_test(who, room_id, engine::room_turn(room_id));
    }

    // ---- report as one [wins, total, pct-per-100k] triple per line (readable) ----
    fun report(w: u64, t: u64) {
        let pct = if (t == 0) { 0u64 } else { w * 100000 / t };
        std::debug::print(&vector[w, t, pct]);
    }

    // ===================== plan helpers =====================
    fun plan_attack(): vector<u64> { vector[820, 850, 820, 760] }    // 毒刃×2+急救+圣愈(奶量≈旧治疗; 玩家无基础技)
    fun plan_burst(): vector<u64> { vector[840] }                 // 暴风剑(高AP消耗)自循环
    fun plan_burst_heal(): vector<u64> { vector[840, 850] }         // 暴风剑+急救(爆发带续航)
    fun plan_swing(): vector<u64> { vector[820] }                  // 纯毒刃(挖矿/低危图,无治疗空转)

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
        engine::start_combat_test(a, room_id);
        engine::set_plan(a, room_id, 0, plan_attack());
        let guard = 0;
        while (guard < 700) {
            let ph = engine::room_phase(room_id);
            let (mhp, _, _, _, _, _) = engine::member_state(room_id, 0);
            let ec = engine::enemy_count(room_id);
            std::debug::print(&vector[guard, (ph as u64), mhp, ec]);
            if (ph == 1) { step(a, room_id); }
            else if (ph == 3) { engine::advance_battle_test(a, room_id); }
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
        assert!(w3 >= 12, 4); // 中坚 b3 可挖(毒刃 DPS 高于旧普攻, 超时卡点消失; 梯度锚=平凡1级全程=0)
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
        // 对照组: 同面板无资源词条(毒刃循环) — 只有小概率通 D2
        let (wp, tp) = clear_rate(a, 2, 20, 355, 34, 28, 27, plan_attack());
        report(wp, tp);
        // 满天赋(满能力 + 满资源词条) + 毒刃循环(1 AP 起手即可行动)
        // 2026-09-30 敏捷排序上线后重标: 极限面板 = 守卫×巨人(spd 27, 全游戏最慢),
        // 而 D2 敌人 spd 45~90 —— 慢速单位现在后手, 缠绕的眩晕先落地。
        let (wt, tt) = clear_rate_affixed(a, 2, 20, 355, 34, 28, 27, 2, 2, 2, 2, plan_attack());
        report(wt, tt);
        let (wb, tb) = clear_rate_affixed(a, 2, 20, 355, 34, 28, 27, 2, 2, 2, 2, plan_burst_heal());
        report(wb, tb);
        assert!(wt >= 1 && wt <= 12, 1); // 极强天赋1级对D2: 小概率通过(约10%, "说不定能赢")
        assert!(wb <= 4, 2);            // 慢速 + AP 门槛循环(暴风剑首回合 AP 不足空过): 基本翻不了 D2
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
    #[expected_failure(abort_code = 20, location = mohayo::engine)]
    fun sim_skill_ownership_enemy_plan_rejected() {
        let a = &std::account::create_account_for_test(@mohayo);
        reg(a);
        let own = std::signer::address_of(a);
        character::gm_mint(a, own, 1, 2, vector[0, 0, 0, 0], vector[850, 890]);
        let char_id = character::owner_latest_char(own);
        engine::create_room(a, 1);
        let room_id = skill_registry::next_room_id() - 1;
        engine::join_room_as_char(a, room_id, char_id);
        engine::start_combat_test(a, room_id);
        engine::set_plan(a, room_id, 0, vector[1015]); // 火花锯=敌技 → abort 20
    }

    // c) 他人不可代排: 非 owner 的地址 set_plan → E_NOT_PLAN_OWNER(19)
    #[test]
    #[expected_failure(abort_code = 19, location = mohayo::engine)]
    fun sim_skill_ownership_foreign_plan_rejected() {
        let a = &std::account::create_account_for_test(@mohayo);
        reg(a);
        let own = std::signer::address_of(a);
        character::gm_mint(a, own, 1, 2, vector[0, 0, 0, 0], vector[850, 890]);
        let char_id = character::owner_latest_char(own);
        engine::create_room(a, 1);
        let room_id = skill_registry::next_room_id() - 1;
        engine::join_room_as_char(a, room_id, char_id);
        engine::start_combat_test(a, room_id);
        let b = &std::account::create_account_for_test(@0xCAFE);
        engine::set_plan(b, room_id, 0, vector[820]); // b 不是成员 owner → abort 19
    }

    // d) 自选敌技在创建端被拒: gm_mint 自选列表含敌技(45) → E_SKILL_NOT_POOL(4)
    #[test]
    #[expected_failure(abort_code = 4, location = mohayo::character)]
    fun sim_skill_ownership_enemy_self_select_rejected() {
        let a = &std::account::create_account_for_test(@mohayo);
        reg(a);
        character::gm_mint(a, std::signer::address_of(a), 1, 2, vector[0, 0, 0, 0], vector[1015]);
    }

    // d2) 自选他人职业技被拒(31=守卫专属盾击) → E_SKILL_NOT_POOL(4)
    #[test]
    #[expected_failure(abort_code = 4, location = mohayo::character)]
    fun sim_skill_ownership_class_skill_rejected() {
        let a = &std::account::create_account_for_test(@mohayo);
        reg(a);
        character::gm_mint(a, std::signer::address_of(a), 3, 2, vector[0, 0, 0, 0], vector[210]);
    }

    // d3) 自选种族技被拒(12=兽人专属狂暴) → E_SKILL_NOT_POOL(4)
    #[test]
    #[expected_failure(abort_code = 4, location = mohayo::character)]
    fun sim_skill_ownership_race_skill_rejected() {
        let a = &std::account::create_account_for_test(@mohayo);
        reg(a);
        character::gm_mint(a, std::signer::address_of(a), 1, 2, vector[0, 0, 0, 0], vector[710]);
    }

    // e) 生产链路端到端: 合法计划可提交并推进战斗
    #[test]
    fun sim_skill_ownership_owned_plan_ok() {
        let a = &std::account::create_account_for_test(@mohayo);
        reg(a);
        let own = std::signer::address_of(a);
        character::gm_mint(a, own, 1, 2, vector[0, 0, 0, 0], vector[850]); // 守卫仅1自选槽(池技:急救包扎)
        let char_id = character::owner_latest_char(own);
        engine::create_room(a, 1);
        let room_id = skill_registry::next_room_id() - 1;
        engine::join_room_as_char(a, room_id, char_id);
        engine::start_combat_test(a, room_id);
        // 计划=自选急救(39)+守卫职业技盾击(31), 均在技能集内 → 应通过
        engine::set_plan(a, room_id, 0, vector[850, 210]);
        let guard = 0;
        while (guard < 40) {
            let ph = engine::room_phase(room_id);
            if (ph == 1) { step(a, room_id); }
            else if (ph == 3) { engine::advance_battle_test(a, room_id); }
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
        // D5 solo 实测 48/60 = 80%（含 20% 混沌变体的方差, §2.6.14）。
        // 15 样本下 80% 真值有约 1/3 概率低于 12/15, 所以阈值留 2 个房间余量:
        // 这里只用来抓「明显掉出带外」的回归, 不是把胜率钉死在 12。
        assert!(w5 >= 10, 1);
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
        character::gm_mint_at_level(a, own, 1, 2, vector[0, 0, 0, 0], vector[850], 40); // 守卫×巨人
        let guard = character::owner_latest_char(own);
        character::gm_mint_at_level(a, own, 3, 0, vector[0, 0, 0, 0], vector[890], 40); // 人类黑魔(脆皮)
        let squishy = character::owner_latest_char(own);
        // 覆写 D3: 单场 1 敌, 表10(祭司850/怨灵150), 两者技能均为 targeting1 单体
        skill_registry::set_dungeon(a, 3, mohayo::types::make_dungeon_config(10, 1, 15, 0, 0, 120, 1));
        skill_registry::set_dungeon_battles(a, 3, vector[mohayo::types::make_battle_config(10, 1)]);
        engine::create_room(a, 3);
        let room_id = skill_registry::next_room_id() - 1;
        engine::join_room_as_char(a, room_id, guard);
        engine::join_room_as_char(a, room_id, squishy);
        engine::start_combat_test(a, room_id);
        engine::set_plan(a, room_id, 0, vector[210]); // 守卫: 每回盾击(眩晕40%+嘲讽2轮)
        engine::set_plan(a, room_id, 1, vector[]);   // 脆皮: 空过
        let guard_i = 0;
        while (guard_i < 8) { step(a, room_id); guard_i = guard_i + 1; };
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
        engine::start_combat_test(a, room_id);
        // 两成员都空过(plan 空, 不消耗 mana): 池应每回合 + (2 + 1 + 1) = +4
        engine::set_plan(a, room_id, 0, vector[]);
        engine::set_plan(a, room_id, 1, vector[]);
        let gi = 0;
        while (gi < 5) { step(a, room_id); gi = gi + 1; };
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
        let (p1, t1) = clear_nb_rate(a, 1, 10, 109, 10, 10, 10, 1, vector[820]); // 平凡1级毒刃 b1
        report(p1, t1);
        let (pf, tf) = clear_rate(a, 1, 10, 109, 10, 10, 10, vector[820]);      // 平凡1级毒刃 全程
        report(pf, tf);
        let (m1, m2) = clear_rate(a, 1, 10, 355, 34, 28, 27, vector[820]);      // 满天赋1级毒刃 全程(观察)
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
        let (d9a, d9t) = clear_rate_duo(a, 9, 4,
            30000, 26000, 13000, 600, plan_attack(),
            26000, 22000, 15000, 550, plan_burst_heal());
        report(d9a, d9t);
        let (t9a, t9t) = clear_rate_trio(a, 9, 4,
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
        character::gm_mint_at_level(a, own, 3, 0, vector[0, 0, 0, 0], vector[890], 40); // 人类黑魔 Lv40
        let cid = character::owner_latest_char(own);
        skill_registry::set_dungeon(a, 1, mohayo::types::make_dungeon_config(4, 1, 2, 0, 0, 120, 1));
        skill_registry::set_dungeon_battles(a, 1, vector[mohayo::types::make_battle_config(4, 1)]);
        engine::create_room(a, 1);
        let room_id = skill_registry::next_room_id() - 1;
        engine::join_room_as_char(a, room_id, cid);
        engine::start_combat_test(a, room_id);
        engine::set_plan(a, room_id, 0, vector[410]);
        step(a, room_id);
        step(a, room_id);
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
        character::gm_mint_at_level(a, own, 4, 0, vector[0, 0, 0, 0], vector[890], 40); // 人类白魔 Lv40
        let cid = character::owner_latest_char(own);
        skill_registry::set_dungeon(a, 1, mohayo::types::make_dungeon_config(1, 1, 8, 0, 0, 120, 1));
        skill_registry::set_dungeon_battles(a, 1, vector[mohayo::types::make_battle_config(1, 2)]);
        engine::create_room(a, 1);
        let room_id = skill_registry::next_room_id() - 1;
        engine::join_room_as_char(a, room_id, cid);
        engine::start_combat_test(a, room_id);
        engine::set_plan(a, room_id, 0, vector[530]); // 每回召唤一人偶
        let gi = 0;
        while (gi < 5) { step(a, room_id); gi = gi + 1; };
        let mc = engine::member_count(room_id);
        std::debug::print(&vector[mc]);
        assert!(mc >= 3, 1); // 白魔 + ≥2 只人偶(mana 8/回合 足够每回招)
    }

    // ================================================================
    //  真实职业搭配队(职业互补) vs 同型队观测: Lv300 常规词条 守卫(盾击+盾墙)/
    //  白魔(圣泉+人偶)/黑魔(献祭产魔)/剑士(快剑+斩铁)。D9 与 D5 通关率。
    //  与同型面板队(~33% D9)对比, 看职业互补的贡献。
    // ================================================================
    #[test]
    fun sim_professional_d9() {
        let a = &std::account::create_account_for_test(@mohayo);
        reg(a);
        let own = std::signer::address_of(a);
        // 守卫(巨人, self 急救39)
        character::gm_mint_at_level(a, own, 1, 2, vector[0, 0, 0, 0], vector[850], 300);
        let c_g = character::owner_latest_char(own);
        // 白魔(人类, self 龙息43)
        character::gm_mint_at_level(a, own, 4, 0, vector[0, 0, 0, 0], vector[890], 300);
        let c_w = character::owner_latest_char(own);
        // 黑魔(人类, self 魔爆44)
        character::gm_mint_at_level(a, own, 3, 0, vector[0, 0, 0, 0], vector[900], 300);
        let c_b = character::owner_latest_char(own);
        // 剑士(人类, self 暴风剑24)
        character::gm_mint_at_level(a, own, 2, 0, vector[0, 0, 0, 0], vector[840], 300);
        let c_s = character::owner_latest_char(own);
        let w1 = 0;
        let i1 = 0;
        while (i1 < 3) {
            w1 = w1 + run_pro4(a, 9, c_g, vector[210, 220], c_w, vector[520, 530], c_b, vector[410], c_s, vector[310, 310, 320]);
            i1 = i1 + 1;
        };
        report(w1, 3); // 职业队 D9
        let w2 = 0;
        let i2 = 0;
        while (i2 < 2) {
            w2 = w2 + run_pro4(a, 5, c_g, vector[210, 220], c_w, vector[520, 530], c_b, vector[410], c_s, vector[310, 310, 320]);
            i2 = i2 + 1;
        };
        report(w2, 2); // 职业队 D5
    }
    // ================================================================
    //  mana 经济观测: 黑魔献祭(每命中+10×4) + 白魔圣泉(每治疗+6/人) 双产魔源下
    //  房间池随回合的增长曲线, 评估是否会失控抬高 28 爆裂的蓄池威力。
    //  黑魔 plan [34×3, 28](献祭产魔→周期性爆裂), 白魔 [37]。D7 实战。
    // ================================================================
    #[test]
    fun sim_mana_econ_observe() {
        let a = &std::account::create_account_for_test(@mohayo);
        reg(a);
        let own = std::signer::address_of(a);
        character::gm_mint_at_level(a, own, 3, 0, vector[0, 0, 0, 0], vector[900], 300);
        let c_b = character::owner_latest_char(own);
        character::gm_mint_at_level(a, own, 4, 0, vector[0, 0, 0, 0], vector[890], 300);
        let c_w = character::owner_latest_char(own);
        engine::create_room(a, 7);
        let room_id = skill_registry::next_room_id() - 1;
        engine::join_room_as_char(a, room_id, c_b);
        engine::join_room_as_char(a, room_id, c_w);
        engine::start_combat_test(a, room_id);
        engine::set_plan(a, room_id, 0, vector[410, 410, 410, 430]);
        engine::set_plan(a, room_id, 1, vector[520]);
        let gi = 0;
        while (gi < 120) {
            let ph2 = engine::room_phase(room_id);
            if (ph2 == 1) { step(a, room_id); }
            else if (ph2 == 3) { engine::advance_battle_test(a, room_id); }
            else { break; };
            if ((gi + 1) % 10 == 0) {
                let mp = engine::room_mana(room_id);
                let ph3 = engine::room_phase(room_id);
                std::debug::print(&vector[(gi + 1), mp, (ph3 as u64)]);
            };
            gi = gi + 1;
        };
        let r = engine::room_result(room_id);
        std::debug::print(&vector[999, (r as u64)]);
    }

    // ================================================================
    //  道具层验证(数据驱动): 火枪弹药自动消耗(弹尽空过) / 魔素礼花入队占回合加魔素 /
    //  非战斗道具不可进计划 / decimals=18 拆分交易。
    // ================================================================
    #[test]
    fun sim_ammo_consumption() {
        let a = &std::account::create_account_for_test(@mohayo);
        reg(a);
        let own = std::signer::address_of(a);
        character::gm_mint_at_level(a, own, 5, 0, vector[0, 0, 0, 0], vector[850], 40); // 火枪手
        let cid = character::owner_latest_char(own);
        item::gm_mint(a, item::ITEM_LEAD_BULLET, own, 5); // 5 发铅弹
        skill_registry::set_dungeon(a, 1, mohayo::types::make_dungeon_config(4, 1, 10, 0, 0, 120, 1));
        skill_registry::set_dungeon_battles(a, 1, vector[mohayo::types::make_battle_config(4, 1)]);
        engine::create_room(a, 1);
        let room_id = skill_registry::next_room_id() - 1;
        engine::join_room_as_char(a, room_id, cid);
        engine::start_combat_test(a, room_id);
        engine::set_plan(a, room_id, 0, vector[620]); // 左轮弹雨(每施放耗 3 发)
        step(a, room_id); // r1: 耗 3 发施放(段伤 150×452/1000×3≈202)
        step(a, room_id); // r2: 剩 2 发不足 → 空过
        let bal = item::balance_whole(item::ITEM_LEAD_BULLET, own);
        let (eh, _, _, _, _, _) = engine::enemy_state(room_id, 0);
        std::debug::print(&vector[bal, eh]);
        assert!(bal == 2, 1);    // 5 - 3 = 2 发
        assert!(eh < 2600, 2);   // 左轮确实输出了
    }

    #[test]
    fun sim_mana_firework() {
        let a = &std::account::create_account_for_test(@mohayo);
        reg(a);
        let own = std::signer::address_of(a);
        character::gm_mint_at_level(a, own, 2, 0, vector[0, 0, 0, 0], vector[850], 40); // 剑士
        let cid = character::owner_latest_char(own);
        item::gm_mint(a, item::ITEM_MANA_FIREWORK, own, 3); // 3 份魔素礼花
        engine::create_room(a, 1);
        let room_id = skill_registry::next_room_id() - 1;
        engine::join_room_as_char(a, room_id, cid);
        engine::start_combat_test(a, room_id);
        // 道具占计划队列: ITEM_SKILL_BASE(61440) + 魔素礼花(type 100) = 61540, 占 1 回合行动位
        engine::set_plan(a, room_id, 0, vector[61540]);
        step(a, room_id);
        step(a, room_id);
        let pool = engine::room_mana(room_id);
        let bal = item::balance_whole(item::ITEM_MANA_FIREWORK, own);
        std::debug::print(&vector[pool, bal]);
        assert!(pool >= 400, 1); // 池 ≈ 2 + 2×2 + 2×200 = 406
        assert!(bal == 1, 2);
    }

    #[test]
    #[expected_failure(abort_code = 20, location = mohayo::engine)]
    fun sim_item_noncombat_rejected() {
        let a = &std::account::create_account_for_test(@mohayo);
        reg(a);
        let own = std::signer::address_of(a);
        character::gm_mint_at_level(a, own, 5, 0, vector[0, 0, 0, 0], vector[850], 40);
        let cid = character::owner_latest_char(own);
        item::gm_mint(a, item::ITEM_LEAD_BULLET, own, 5);
        engine::create_room(a, 1);
        let room_id = skill_registry::next_room_id() - 1;
        engine::join_room_as_char(a, room_id, cid);
        engine::start_combat_test(a, room_id);
        // 铅弹标记战斗中不可使用 → 不可进计划队列
        engine::set_plan(a, room_id, 0, vector[61441]);
    }

    #[test]
    fun sim_item_split_transfer() {
        let a = &std::account::create_account_for_test(@mohayo);
        reg(a);
        let own = std::signer::address_of(a);
        let b = &std::account::create_account_for_test(@0xCAFE);
        let baddr = std::signer::address_of(b);
        item::gm_mint(a, item::ITEM_MANA_FIREWORK, own, 2);
        // 拆散交易: 转 1.5 份(1.5 × 10^18 raw)
        item::transfer(a, item::ITEM_MANA_FIREWORK, baddr, 1500000000000000000);
        let rb = item::balance_whole(item::ITEM_MANA_FIREWORK, baddr);
        let ra = item::balance_raw(item::ITEM_MANA_FIREWORK, own);
        std::debug::print(&vector[rb, (ra as u64)]);
        assert!(rb == 1, 1);             // 收款方 1 整份(1.5e18 → 整除 1)
        assert!(ra == 500000000000000000, 2); // 转出方剩 0.5 份 raw
    }
    // ================================================================
    //  火枪手弹药长线验证: 60 发铅弹打穿单只巨型魔素岩(2600hp)整场战斗。
    //  左轮 3 发/施放 × 段伤≈201 → 约 13 施放(39 发)击杀; 验证全程扣减与余量。
    // ================================================================
    #[test]
    fun sim_ammo_long_clear() {
        let a = &std::account::create_account_for_test(@mohayo);
        reg(a);
        let own = std::signer::address_of(a);
        character::gm_mint_at_level(a, own, 5, 0, vector[0, 0, 0, 0], vector[850], 300); // 火枪手 Lv300
        let cid = character::owner_latest_char(own);
        item::gm_mint(a, item::ITEM_LEAD_BULLET, own, 60);
        skill_registry::set_dungeon(a, 1, mohayo::types::make_dungeon_config(4, 1, 30, 0, 0, 120, 1));
        skill_registry::set_dungeon_battles(a, 1, vector[mohayo::types::make_battle_config(4, 1)]);
        engine::create_room(a, 1);
        let room_id = skill_registry::next_room_id() - 1;
        engine::join_room_as_char(a, room_id, cid);
        engine::start_combat_test(a, room_id);
        engine::set_plan(a, room_id, 0, vector[620]); // 左轮弹雨(3 发/施放)
        let guard = 0;
        while (guard < 200) {
            let ph = engine::room_phase(room_id);
            if (ph == 1) { step(a, room_id); }
            else { break; };
            guard = guard + 1;
        };
        let bal = item::balance_whole(item::ITEM_LEAD_BULLET, own);
        let res = engine::room_result(room_id);
        let (eh, _, _, _, _, _) = engine::enemy_state(room_id, 0);
        std::debug::print(&vector[bal, (res as u64), eh]);
        assert!(res == 1, 1);   // 打穿
        assert!(bal >= 0 && bal < 60, 2); // 弹药确实消耗
    }

    // ================================================================
    //  战斗消耗品基本效果验证(content-design §7 恢复/干扰/复活类)。
    //  本轮只做"效果确实发生 + 道具确实消耗"的宽松断言(数值策划未精调)。
    // ================================================================
    #[test]
    fun sim_item_heal_potion() {
        let a = &std::account::create_account_for_test(@mohayo);
        reg(a);
        let own = std::signer::address_of(a);
        // 火枪手: 无铅弹 → 左轮(620)每次空过不还手, 机仆单回合只磨少量血
        character::gm_mint_at_level(a, own, 5, 0, vector[0, 0, 0, 0], vector[], 40);
        let cid = character::owner_latest_char(own);
        item::gm_mint(a, item::ITEM_HEALING_POTION, own, 5);
        skill_registry::set_dungeon(a, 1, mohayo::types::make_dungeon_config(5, 1, 10, 0, 0, 120, 1)); // 机仆(会还手)
        skill_registry::set_dungeon_battles(a, 1, vector[mohayo::types::make_battle_config(5, 1)]);
        engine::create_room(a, 1);
        let room_id = skill_registry::next_room_id() - 1;
        engine::join_room_as_char(a, room_id, cid);
        engine::start_combat_test(a, room_id);
        engine::set_plan(a, room_id, 0, vector[620]); // 空过, 故意挨打
        let i = 0;
        while (i < 5) { step(a, room_id); i = i + 1; }; // 磨血 5 回合
        let (hp1, _, _, _, _, _) = engine::member_state(room_id, 0);
        engine::set_plan(a, room_id, 0, vector[61541]); // 疗伤药水(占 1 回合)
        step(a, room_id);
        let (hp2, mh, _, _, _, _) = engine::member_state(room_id, 0);
        let bal = item::balance_whole(item::ITEM_HEALING_POTION, own);
        let (eh, _, _, _, _, _) = engine::enemy_state(room_id, 0);
        std::debug::print(&vector[hp1, hp2, mh, eh, bal]);
        assert!(hp2 > hp1, 1); // 治疗生效(400 > 机仆单回合伤害)
        assert!(bal == 4, 2);  // 消耗 1 份
    }

    #[test]
    fun sim_item_smoke_bomb() {
        let a = &std::account::create_account_for_test(@mohayo);
        reg(a);
        let own = std::signer::address_of(a);
        character::gm_mint_at_level(a, own, 5, 0, vector[0, 0, 0, 0], vector[], 40);
        let cid = character::owner_latest_char(own);
        item::gm_mint(a, item::ITEM_SMOKE_BOMB, own, 2);
        skill_registry::set_dungeon(a, 1, mohayo::types::make_dungeon_config(4, 1, 10, 0, 0, 120, 1)); // 魔素岩(不还手, 安全)
        skill_registry::set_dungeon_battles(a, 1, vector[mohayo::types::make_battle_config(4, 1)]);
        engine::create_room(a, 1);
        let room_id = skill_registry::next_room_id() - 1;
        engine::join_room_as_char(a, room_id, cid);
        engine::start_combat_test(a, room_id);
        engine::set_plan(a, room_id, 0, vector[61543]); // 烟幕弹(103+61440)
        step(a, room_id);
        let mc = engine::member_effect_count(room_id, 0);
        let ec = engine::enemy_effect_count(room_id, 0);
        let (mop, _, mmag) = engine::member_effect(room_id, 0, 0);
        let bal = item::balance_whole(item::ITEM_SMOKE_BOMB, own);
        std::debug::print(&vector[bal, mc, ec, (mop as u64), (mmag as u64)]);
        assert!(mc >= 1 && ec >= 1, 1);      // 敌我双方都吃到 ACC_DOWN
        assert!(mop == 6 && mmag == 300, 2); // op=6(ACC_DOWN) 幅度 300‰
        assert!(bal == 1, 3);                // 消耗 1 份
    }

    #[test]
    fun sim_item_phoenix_revive() {
        let a = &std::account::create_account_for_test(@mohayo);
        reg(a);
        let aaddr = std::signer::address_of(a);
        let b = &std::account::create_account_for_test(@0xBEEF);
        let baddr = std::signer::address_of(b);
        // a: Lv300 守卫(耐打)持不死鸟之羽; b: Lv1 弱角色 → 被渊炎龙全体龙息每回合秒杀
        character::gm_mint_at_level(a, aaddr, 1, 0, vector[0, 0, 0, 0], vector[850], 300);
        character::gm_mint_at_level(a, baddr, 1, 0, vector[0, 0, 0, 0], vector[], 1);
        let ca = character::owner_latest_char(aaddr);
        let cb = character::owner_latest_char(baddr);
        item::gm_mint(a, item::ITEM_PHOENIX_FEATHER, aaddr, 5);
        skill_registry::set_dungeon(a, 1, mohayo::types::make_dungeon_config(22, 1, 10, 0, 0, 120, 1)); // 渊炎龙(全体龙息)
        skill_registry::set_dungeon_battles(a, 1, vector[mohayo::types::make_battle_config(22, 1)]);
        engine::create_room(a, 1);
        let room_id = skill_registry::next_room_id() - 1;
        engine::join_room_as_char(a, room_id, ca);
        engine::join_room_as_char(b, room_id, cb);
        engine::start_combat_test(a, room_id);
        engine::set_plan(a, room_id, 0, vector[61544]); // 不死鸟之羽
        let feathers_before = item::balance_whole(item::ITEM_PHOENIX_FEATHER, aaddr);
        let guard = 0;
        while (guard < 8 && engine::room_phase(room_id) == 1) {
            step(a, room_id);
            guard = guard + 1;
        };
        let feathers = item::balance_whole(item::ITEM_PHOENIX_FEATHER, aaddr);
        let (_, _, _, _, _, aalive) = engine::member_state(room_id, 0);
        let (bh, bm, _, _, _, balive) = engine::member_state(room_id, 1);
        let res = engine::room_result(room_id);
        std::debug::print(&vector[bh, bm, (balive as u64), aalive, feathers, guard, (res as u64)]);
        assert!(feathers < feathers_before, 1); // 羽毛在复活判定路径上被消耗(渊炎龙每回合秒 b)
        assert!(aalive == 1, 2);                // a 全程存活, 战斗未崩
    }

    // ================================================================
    //  角色类 / 入场类道具(content-design §7): 命运骰子 / 重生卷轴 / 挑战券。
    // ================================================================
    #[test]
    fun sim_item_dice_of_fate() {
        let a = &std::account::create_account_for_test(@mohayo);
        reg(a);
        let own = std::signer::address_of(a);
        character::gm_mint_at_level(a, own, 2, 0, vector[0, 0, 0, 0], vector[850], 40); // 剑士 Lv40
        let cid = character::owner_latest_char(own);
        item::gm_mint(a, item::ITEM_DICE_OF_FATE, own, 1);
        // §2.3 二选一: 首号自带 3 次免费重掷 → 前三次不核销骰子
        assert!(character::free_rerolls(own) == 3, 5);
        use_item::dice_of_fate_test(a, cid, 101);
        assert!(character::free_rerolls(own) == 2, 6);
        assert!(item::balance_whole(item::ITEM_DICE_OF_FATE, own) == 1, 7);
        // 用光免费次数后才核销骰子
        use_item::dice_of_fate_test(a, cid, 102);
        use_item::dice_of_fate_test(a, cid, 103);
        assert!(character::free_rerolls(own) == 0, 8);
        assert!(item::balance_whole(item::ITEM_DICE_OF_FATE, own) == 1, 9);
        use_item::dice_of_fate_test(a, cid, 104);
        let (cls, race, lvl, _, _, _, _, _, _, _) = character::get_character(cid);
        let ss = character::get_self_select(cid);
        let bal = item::balance_whole(item::ITEM_DICE_OF_FATE, own);
        std::debug::print(&vector[(cls as u64), (race as u64), (lvl as u64), bal, std::vector::length(&ss)]);
        assert!((cls as u64) == 2, 1);                 // 职业保留
        assert!((lvl as u64) == 40, 2);                // 等级保留
        assert!(std::vector::length(&ss) == 1, 3);     // 自选技保留
        assert!(bal == 0, 4);                          // 免费次数用尽 → 骰子消耗
    }

    #[test]
    fun sim_item_rebirth_scroll() {
        let a = &std::account::create_account_for_test(@mohayo);
        reg(a);
        let own = std::signer::address_of(a);
        character::gm_mint_at_level(a, own, 2, 0, vector[0, 0, 0, 0], vector[850], 40);
        let cid = character::owner_latest_char(own);
        item::gm_mint(a, item::ITEM_REBIRTH_SCROLL, own, 1);
        use_item::rebirth_scroll_test(a, cid, 777);
        let (cls, race, lvl, _, _, _, _, _, _, _) = character::get_character(cid);
        let ss = character::get_self_select(cid);
        let bal = item::balance_whole(item::ITEM_REBIRTH_SCROLL, own);
        std::debug::print(&vector[(cls as u64), (race as u64), (lvl as u64), std::vector::length(&ss), bal]);
        assert!(bal == 0, 1);                          // 卷轴消耗
        assert!((lvl as u64) == 1, 2);                 // 等级重置为 1
        assert!(std::vector::length(&ss) == 0, 3);     // 自选技清空
    }

    #[test]
    #[expected_failure(abort_code = 6, location = mohayo::item)]
    fun sim_item_bound_transfer_rejected() {
        let a = &std::account::create_account_for_test(@mohayo);
        reg(a);
        let own = std::signer::address_of(a);
        let b = &std::account::create_account_for_test(@0xCAFE);
        let baddr = std::signer::address_of(b);
        // 挑战券类道具已随「24 小时滑动窗口」取消(§2.6.14), 这里临时注册一件绑定道具,
        // 继续覆盖「绑定 = 不可转移」这条机制本身。
        item::register_item(a, 999, b"bound_probe", 9, false, item::EFFECT_NONE, 0, 18, true);
        assert!(item::is_bound(999), 1);
        item::gm_mint(a, 999, own, 1);
        item::transfer(a, 999, baddr, item::one()); // 绑定 → E_BOUND(6)
    }

    /// 初始化 aptos_framework 时间戳, 并把"今日"推进到非零日(便于每日领取判定)。
    fun init_timestamp() {
        let f = &std::account::create_account_for_test(@aptos_framework);
        aptos_framework::timestamp::set_time_has_started_for_testing(f);
        aptos_framework::timestamp::update_global_time_for_test_secs(1760000000);
    }
}
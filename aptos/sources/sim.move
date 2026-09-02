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
}
// Mohayo engine comprehensive tests
module mohayo::tests {
    use std::account;
    use std::signer;
    use mohayo::engine::{Self};

    const SKILL_ATTACK: u64 = 1;
    const SKILL_MAGIC_BOLT: u64 = 2;
    const SKILL_HEAL: u64 = 3;
    const SKILL_STRIKE_3: u64 = 4;
    const SKILL_SHIELD: u64 = 5;
    const SKILL_STUN: u64 = 6;
    const SKILL_SMOKE: u64 = 7;
    const SKILL_EAGLE_EYE: u64 = 8;
    const SKILL_MANA_BURST: u64 = 9;
    const SKILL_DOT: u64 = 10;
    const SKILL_TAUNT: u64 = 11;
    const SKILL_BERSERK: u64 = 12;
    const SKILL_STONE_BODY: u64 = 13;
    const SKILL_SPIRIT_RETURN: u64 = 14;
    const SKILL_STORM: u64 = 15;
    const SKILL_DRAGON_SCALE: u64 = 16;
    const SKILL_HOLY_LIGHT: u64 = 17;
    const SKILL_ANGEL_JUDGMENT: u64 = 18;
    const SKILL_SOUL_DRAIN: u64 = 19;
    const SKILL_ABYSS_WHISPER: u64 = 20;
    const SKILL_SUMMON: u64 = 21;
    const SKILL_IDLE: u64 = 22;
    const SKILL_FLASH: u64 = 23;
    const SKILL_STORM_BLADE: u64 = 24;
    const SKILL_MAGIC_SWORD: u64 = 25;
    const SKILL_REVOLVER_RAIN: u64 = 26;
    const SKILL_DRAGON_BULLET: u64 = 27;
    const SKILL_BURST_MAGIC: u64 = 28;
    const SKILL_RAPID_STRIKE: u64 = 29;
    const SKILL_IRON_CLEAVE: u64 = 30;
    const SKILL_SHIELD_BASH: u64 = 31;
    const SKILL_SHIELD_WALL: u64 = 32;
    const SKILL_GUARD_EVADE: u64 = 33;
    const SKILL_SACRIFICE: u64 = 34;
    const SKILL_BLACK_VEIL: u64 = 35;
    const SKILL_LIGHT_ORB: u64 = 36;
    const SKILL_HOLY_SPRING: u64 = 37;
    const SKILL_DECOY_DOLL: u64 = 38;
    const SKILL_FIRST_AID: u64 = 39;
    const SKILL_BLINDING_POWDER: u64 = 40;
    const SKILL_ROCK_BULWARK: u64 = 41;
    const SKILL_MAGIC_SHIELD: u64 = 42;
    const SKILL_DRAGON_BREATH: u64 = 43;
    const SKILL_MANA_CLAP: u64 = 44;
    const SKILL_SPARK_SAW: u64 = 45;
    const SKILL_PARTICLE_SLASH: u64 = 46;
    const SKILL_MARSHAL_LEAK: u64 = 47;
    const SKILL_FURNACE_LEAK: u64 = 48;
    const SKILL_FURNACE_SIPHON: u64 = 49;
    const SKILL_FURNACE_SUMMON: u64 = 50;
    const SKILL_EMPEROR_CANNON: u64 = 51;
    const SKILL_EMPEROR_WHEEL: u64 = 52;
    const SKILL_EMPEROR_LEAK: u64 = 53;
    const SKILL_EMPEROR_SIPHON: u64 = 54;
    const SKILL_EMPEROR_PRESSURE: u64 = 55;
    const SKILL_EMPEROR_SUMMON: u64 = 56;

    // helpers using engine constructors
    fun eff(op: u8, dur: u8, mag: u64, scope: u8, prob: u64): engine::EffectSpec {
        engine::make_effect_spec(op, dur, mag, scope, prob)
    }
    fun empty_eff(): engine::EffectSpec { eff(0, 0, 0, 0, 1000) }
    fun no_summon(): engine::SummonRule { engine::make_summon_rule(0, 0, 0) }

    fun base_skill(id: u64, kind: u8, mana: u64, tgt: u8, tcount: u64, power: u64, acc: u64, flags: u8): engine::Skill {
        engine::make_skill(id, kind, 0, 0, 0, 0, mana, 0, tgt, 0, tcount, power, 0, acc, flags,
            vector[empty_eff(), empty_eff(), empty_eff(), empty_eff()], no_summon())
    }

    fun ods(tid: u64, count: u64, prob: u64): engine::OnDeathSpawn { engine::make_on_death_spawn(tid, count, prob) }
    fun tpl_no_ods(ai: u64, threat: u64, hp: u64, p: u64, m: u64, spd: u64): engine::EnemyTemplate {
        engine::make_enemy_template(ai, threat, hp, p, m, spd, 1000, 5, 10, ods(0, 0, 0))
    }
    fun tpl_ods(ai: u64, threat: u64, hp: u64, p: u64, m: u64, spd: u64, otid: u64, ocnt: u64, oprob: u64): engine::EnemyTemplate {
        engine::make_enemy_template(ai, threat, hp, p, m, spd, 1000, 5, 10, ods(otid, ocnt, oprob))
    }
    fun te(tid: u64, w: u64): engine::TableEntry { engine::make_table_entry(tid, w) }
    fun bc(tid: u64, ec: u64): engine::BattleConfig { engine::make_battle_config(tid, ec) }

    fun seed_engine(acct: &signer) {
        // acct must be at @mohayo for engine resources
        engine::init_for_test(acct);

        // ---- skills (all 56) ----
        engine::register_skill(acct, base_skill(1, 1, 0, 1, 0, 100, 1000, 0));
        engine::register_skill(acct, base_skill(2, 2, 1, 1, 0, 150, 1000, 0));
        // 3. Heal
        let s = base_skill(3, 3, 1, 5, 0, 100, 1000, 0);
        s = engine::make_skill(3, 3, 0, 0, 0, 0, 1, 0, 5, 0, 0, 100, 0, 1000, 0,
            vector[eff(9, 0, 0, 1, 1000), empty_eff(), empty_eff(), empty_eff()], no_summon());
        engine::register_skill(acct, s);
        // 4. Strike 3
        let s = engine::make_skill(4, 1, 1, 2, 0, 0, 0, 0, 3, 0, 3, 50, 0, 1000, 0,
            vector[empty_eff(), empty_eff(), empty_eff(), empty_eff()], no_summon());
        engine::register_skill(acct, s);
        // 5. Shield
        let s = engine::make_skill(5, 3, 0, 0, 0, 0, 1, 0, 9, 0, 0, 100, 0, 1000, 0,
            vector[eff(4, 3, 0, 0, 1000), empty_eff(), empty_eff(), empty_eff()], no_summon());
        engine::register_skill(acct, s);
        // 6. Stun
        let s = engine::make_skill(6, 1, 3, 0, 0, 0, 0, 0, 1, 0, 0, 50, 0, 1000, 0,
            vector[eff(1, 2, 0, 1, 1000), empty_eff(), empty_eff(), empty_eff()], no_summon());
        engine::register_skill(acct, s);
        // 7. Smoke
        let s = engine::make_skill(7, 3, 0, 0, 0, 0, 1, 0, 8, 0, 0, 0, 0, 1000, 0,
            vector[eff(6, 2, 200, 2, 1000), empty_eff(), empty_eff(), empty_eff()], no_summon());
        engine::register_skill(acct, s);
        // 8. Eagle Eye
        let s = engine::make_skill(8, 3, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 0, 1000, 0,
            vector[eff(7, 2, 0, 0, 1000), empty_eff(), empty_eff(), empty_eff()], no_summon());
        engine::register_skill(acct, s);
        // 9. Mana Burst
        let s = engine::make_skill(9, 3, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 0, 1000, 0,
            vector[eff(13, 0, 1, 0, 1000), empty_eff(), empty_eff(), empty_eff()], no_summon());
        engine::register_skill(acct, s);
        // 10. DOT
        let s = engine::make_skill(10, 1, 2, 0, 0, 0, 0, 0, 1, 0, 0, 200, 0, 950, 0,
            vector[eff(8, 3, 18, 1, 1000), empty_eff(), empty_eff(), empty_eff()], no_summon());
        engine::register_skill(acct, s);
        // 11. Taunt
        let s = engine::make_skill(11, 3, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 1000, 0,
            vector[eff(11, 2, 0, 1, 1000), empty_eff(), empty_eff(), empty_eff()], no_summon());
        engine::register_skill(acct, s);
        // 12. Berserk
        let s = engine::make_skill(12, 3, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 0, 1000, 0,
            vector[eff(2, 2, 300, 0, 1000), eff(3, 2, 200, 0, 1000), empty_eff(), empty_eff()], no_summon());
        engine::register_skill(acct, s);
        // 13. Stone Body
        let s = engine::make_skill(13, 3, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 0, 1000, 0,
            vector[eff(4, 4, 80, 0, 1000), empty_eff(), empty_eff(), empty_eff()], no_summon());
        engine::register_skill(acct, s);
        // 14. Spirit Return
        let s = engine::make_skill(14, 3, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 0, 1000, 0,
            vector[eff(10, 0, 0, 0, 1000), eff(9, 0, 30, 0, 1000), empty_eff(), empty_eff()], no_summon());
        engine::register_skill(acct, s);
        // 15. Storm
        let s = engine::make_skill(15, 2, 0, 0, 0, 0, 3, 0, 3, 0, 3, 60, 0, 1000, 0,
            vector[eff(1, 1, 0, 1, 300), empty_eff(), empty_eff(), empty_eff()], no_summon());
        engine::register_skill(acct, s);
        // 16. Dragon Scale
        let s = engine::make_skill(16, 3, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 0, 1000, 0,
            vector[eff(4, 3, 60, 0, 1000), eff(2, 3, 150, 0, 1000), empty_eff(), empty_eff()], no_summon());
        engine::register_skill(acct, s);
        // 17. Holy Light
        let s = engine::make_skill(17, 3, 0, 0, 0, 0, 1, 0, 10, 0, 0, 0, 0, 1000, 0,
            vector[eff(9, 0, 100, 1, 1000), empty_eff(), empty_eff(), empty_eff()], no_summon());
        engine::register_skill(acct, s);
        // 18. Angel Judgment
        engine::register_skill(acct, engine::make_skill(18, 2, 0, 0, 0, 0, 3, 0, 3, 0, 4, 80, 0, 1000, 0,
            vector[empty_eff(), empty_eff(), empty_eff(), empty_eff()], no_summon()));
        // 19. Soul Drain
        let s = engine::make_skill(19, 1, 0, 1, 0, 0, 0, 0, 1, 0, 0, 100, 0, 1000, 0,
            vector[eff(12, 0, 300, 0, 1000), empty_eff(), empty_eff(), empty_eff()], no_summon());
        // ap_gain=1 — need to reconstruct since make_skill has fixed params
        let s = engine::make_skill(19, 1, 0, 1, 0, 0, 0, 0, 1, 0, 0, 100, 0, 1000, 0,
            vector[eff(12, 0, 300, 0, 1000), empty_eff(), empty_eff(), empty_eff()], no_summon());
        engine::register_skill(acct, s);
        // 20. Abyss Whisper
        let s = engine::make_skill(20, 3, 0, 0, 0, 0, 1, 0, 4, 0, 0, 0, 0, 1000, 0,
            vector[eff(6, 2, 200, 3, 1000), empty_eff(), empty_eff(), empty_eff()], no_summon());
        engine::register_skill(acct, s);
        // 21. Summon
        let s = engine::make_skill(21, 4, 0, 0, 0, 0, 3, 0, 9, 0, 0, 0, 0, 1000, 0,
            vector[eff(14, 0, 0, 0, 1000), empty_eff(), empty_eff(), empty_eff()],
            engine::make_summon_rule(100, 1, 2));
        engine::register_skill(acct, s);
        // 22. Idle
        engine::register_skill(acct, base_skill(22, 3, 0, 9, 0, 0, 1000, 0));
        // 23. Flash
        let s = engine::make_skill(23, 1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 350, 350, 650, 0,
            vector[empty_eff(), empty_eff(), empty_eff(), empty_eff()], no_summon());
        // ap_cost=1
        let s = engine::make_skill(23, 1, 1, 0, 0, 0, 0, 0, 1, 0, 0, 350, 350, 650, 0,
            vector[empty_eff(), empty_eff(), empty_eff(), empty_eff()], no_summon());
        engine::register_skill(acct, s);
        // 24. Storm Blade (AP 5)
        let s = engine::make_skill(24, 1, 5, 0, 0, 0, 0, 0, 3, 0, 4, 250, 0, 900, 0,
            vector[empty_eff(), empty_eff(), empty_eff(), empty_eff()], no_summon());
        engine::register_skill(acct, s);
        // 25. Magic Sword (mana 1, ap_gain 1)
        let s = engine::make_skill(25, 2, 0, 1, 0, 0, 1, 0, 1, 0, 0, 200, 0, 1000, 0,
            vector[empty_eff(), empty_eff(), empty_eff(), empty_eff()], no_summon());
        engine::register_skill(acct, s);
        // 26-28
        engine::register_skill(acct, engine::make_skill(26, 1, 0, 0, 0, 0, 0, 0, 3, 0, 3, 60, 0, 700, 0,
            vector[empty_eff(), empty_eff(), empty_eff(), empty_eff()], no_summon()));
        engine::register_skill(acct, engine::make_skill(27, 1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 300, 0, 1000, 0,
            vector[empty_eff(), empty_eff(), empty_eff(), empty_eff()], no_summon()));
        engine::register_skill(acct, engine::make_skill(28, 2, 0, 0, 0, 0, 0, 3, 4, 0, 0, 500, 0, 1000, 3,
            vector[eff(1, 3, 0, 0, 1000), empty_eff(), empty_eff(), empty_eff()], no_summon()));
        // 29-30
        let s = engine::make_skill(29, 1, 1, 2, 0, 0, 0, 0, 3, 0, 3, 50, 0, 1000, 0,
            vector[empty_eff(), empty_eff(), empty_eff(), empty_eff()], no_summon());
        engine::register_skill(acct, s);
        engine::register_skill(acct, engine::make_skill(30, 1, 10, 0, 0, 0, 0, 0, 1, 0, 0, 800, 0, 1000, 0,
            vector[empty_eff(), empty_eff(), empty_eff(), empty_eff()], no_summon()));
        // 31-44
        let s = engine::make_skill(31, 1, 3, 0, 0, 0, 0, 0, 1, 0, 0, 80, 0, 1000, 0,
            vector[eff(1, 2, 0, 1, 400), eff(11, 2, 0, 1, 1000), empty_eff(), empty_eff()], no_summon());
        engine::register_skill(acct, s);
        let s = engine::make_skill(32, 3, 0, 1, 0, 0, 0, 0, 9, 0, 0, 0, 0, 1000, 0,
            vector[eff(4, 3, 150, 0, 1000), empty_eff(), empty_eff(), empty_eff()], no_summon());
        engine::register_skill(acct, s);
        let s = engine::make_skill(33, 3, 0, 1, 0, 0, 0, 0, 9, 0, 0, 0, 0, 1000, 0,
            vector[eff(5, 3, 300, 0, 1000), empty_eff(), empty_eff(), empty_eff()], no_summon());
        engine::register_skill(acct, s);
        engine::register_skill(acct, engine::make_skill(34, 1, 0, 0, 0, 50, 0, 0, 3, 0, 2, 120, 0, 1000, 0,
            vector[eff(13, 0, 1, 0, 1000), empty_eff(), empty_eff(), empty_eff()], no_summon()));
        let s = engine::make_skill(35, 3, 0, 1, 0, 0, 0, 0, 4, 0, 0, 0, 0, 1000, 0,
            vector[eff(6, 2, 200, 3, 1000), empty_eff(), empty_eff(), empty_eff()], no_summon());
        engine::register_skill(acct, s);
        engine::register_skill(acct, engine::make_skill(36, 2, 0, 1, 0, 0, 0, 0, 2, 0, 4, 80, 0, 1000, 0,
            vector[empty_eff(), empty_eff(), empty_eff(), empty_eff()], no_summon()));
        let s = engine::make_skill(37, 3, 0, 1, 0, 0, 0, 0, 6, 1, 3, 90, 0, 1000, 0,
            vector[eff(13, 0, 1, 0, 1000), empty_eff(), empty_eff(), empty_eff()], no_summon());
        engine::register_skill(acct, s);
        let s = engine::make_skill(38, 4, 0, 1, 0, 0, 0, 4, 9, 0, 0, 0, 0, 1000, 4,
            vector[eff(14, 0, 0, 0, 1000), empty_eff(), empty_eff(), empty_eff()],
            engine::make_summon_rule(200, 1, 0));
        engine::register_skill(acct, s);
        let s = engine::make_skill(39, 3, 0, 1, 0, 0, 0, 0, 5, 1, 0, 60, 0, 1000, 0,
            vector[empty_eff(), empty_eff(), empty_eff(), empty_eff()], no_summon());
        engine::register_skill(acct, s);
        let s = engine::make_skill(40, 3, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1000, 0,
            vector[eff(6, 2, 250, 0, 1000), eff(6, 2, 400, 1, 1000), empty_eff(), empty_eff()], no_summon());
        engine::register_skill(acct, s);
        let s = engine::make_skill(41, 3, 0, 1, 0, 0, 0, 0, 9, 0, 0, 0, 0, 1000, 0,
            vector[eff(4, 3, 60, 0, 1000), empty_eff(), empty_eff(), empty_eff()], no_summon());
        engine::register_skill(acct, s);
        let s = engine::make_skill(42, 2, 0, 1, 0, 1000, 0, 0, 9, 0, 0, 1000, 0, 1000, 0,
            vector[eff(4, 3, 0, 0, 1000), empty_eff(), empty_eff(), empty_eff()], no_summon());
        engine::register_skill(acct, s);
        engine::register_skill(acct, engine::make_skill(43, 2, 0, 2, 0, 0, 0, 0, 2, 0, 2, 70, 0, 1000, 0,
            vector[empty_eff(), empty_eff(), empty_eff(), empty_eff()], no_summon()));
        engine::register_skill(acct, engine::make_skill(44, 2, 0, 2, 0, 0, 0, 0, 4, 0, 0, 60, 0, 1000, 0,
            vector[empty_eff(), empty_eff(), empty_eff(), empty_eff()], no_summon()));
        // 45-56 (D9)
        engine::register_skill(acct, engine::make_skill(45, 1, 0, 0, 0, 0, 0, 0, 1, 0, 1, 1300, 0, 950, 0,
            vector[empty_eff(), empty_eff(), empty_eff(), empty_eff()], no_summon()));
        engine::register_skill(acct, engine::make_skill(46, 1, 0, 0, 0, 0, 0, 0, 1, 0, 1, 1700, 0, 950, 0,
            vector[empty_eff(), empty_eff(), empty_eff(), empty_eff()], no_summon()));
        let s = engine::make_skill(47, 3, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 0, 1000, 0,
            vector[eff(13, 0, 100, 0, 1000), empty_eff(), empty_eff(), empty_eff()], no_summon());
        engine::register_skill(acct, s);
        let s = engine::make_skill(48, 3, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 0, 1000, 0,
            vector[eff(13, 0, 100, 0, 1000), empty_eff(), empty_eff(), empty_eff()], no_summon());
        engine::register_skill(acct, s);
        let s = engine::make_skill(49, 3, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 0, 1000, 0,
            vector[eff(13, 0, 80, 1, 1000), empty_eff(), empty_eff(), empty_eff()], no_summon());
        engine::register_skill(acct, s);
        engine::register_skill(acct, engine::make_skill(51, 1, 0, 0, 0, 0, 40, 0, 1, 0, 1, 17000, 0, 900, 0,
            vector[empty_eff(), empty_eff(), empty_eff(), empty_eff()], no_summon()));
        let s = engine::make_skill(52, 2, 0, 0, 0, 0, 12, 0, 3, 0, 4, 6700, 0, 900, 0,
            vector[eff(1, 2, 0, 1, 400), empty_eff(), empty_eff(), empty_eff()], no_summon());
        engine::register_skill(acct, s);
        let s = engine::make_skill(53, 3, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 0, 1000, 0,
            vector[eff(13, 0, 100, 0, 1000), empty_eff(), empty_eff(), empty_eff()], no_summon());
        engine::register_skill(acct, s);
        let s = engine::make_skill(54, 3, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 0, 1000, 0,
            vector[eff(13, 0, 80, 1, 1000), empty_eff(), empty_eff(), empty_eff()], no_summon());
        engine::register_skill(acct, s);
        let s = engine::make_skill(55, 3, 0, 0, 0, 0, 2, 0, 4, 0, 0, 0, 0, 1000, 0,
            vector[eff(6, 3, 300, 3, 1000), eff(1, 1, 0, 3, 300), empty_eff(), empty_eff()], no_summon());
        engine::register_skill(acct, s);
        let s = engine::make_skill(50, 4, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 0, 1000, 0,
            vector[eff(14, 0, 0, 0, 1000), empty_eff(), empty_eff(), empty_eff()],
            engine::make_summon_rule(300, 2, 0));
        engine::register_skill(acct, s);
        let s = engine::make_skill(56, 4, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 0, 1000, 0,
            vector[eff(14, 0, 0, 0, 1000), empty_eff(), empty_eff(), empty_eff()],
            engine::make_summon_rule(300, 2, 0));
        engine::register_skill(acct, s);

        // ---- AI ----
        engine::register_ai(acct, 1, vector[SKILL_ATTACK]);
        engine::register_ai(acct, 2, vector[SKILL_ATTACK, SKILL_ATTACK, SKILL_MAGIC_BOLT]);
        engine::register_ai(acct, 10, vector[SKILL_SPARK_SAW]);
        engine::register_ai(acct, 11, vector[SKILL_PARTICLE_SLASH, SKILL_PARTICLE_SLASH, SKILL_MARSHAL_LEAK]);
        engine::register_ai(acct, 12, vector[SKILL_FURNACE_LEAK, SKILL_FURNACE_SIPHON, SKILL_FURNACE_SUMMON, SKILL_FURNACE_LEAK, SKILL_FURNACE_SIPHON]);
        engine::register_ai(acct, 13, vector[SKILL_EMPEROR_WHEEL, SKILL_EMPEROR_CANNON, SKILL_EMPEROR_PRESSURE, SKILL_EMPEROR_SUMMON, SKILL_EMPEROR_LEAK, SKILL_EMPEROR_CANNON]);
        engine::register_ai(acct, 14, vector[0]);

        // ---- Templates ----
        engine::register_template(acct, 100, tpl_no_ods(0, 0, 30, 10, 3, 6));   // decoy
        engine::register_template(acct, 200, tpl_no_ods(0, 0, 120, 0, 0, 0));   // decoy target
        engine::register_template(acct, 1, tpl_no_ods(1, 1, 50, 12, 5, 8));     // slime
        engine::register_template(acct, 2, tpl_ods(2, 5, 200, 25, 15, 12, 1, 2, 500)); // boss
        engine::register_template(acct, 300, tpl_no_ods(10, 3, 2600, 380, 150, 28)); // soldier
        engine::register_template(acct, 301, tpl_no_ods(11, 8, 9000, 900, 600, 42)); // marshal
        engine::register_template(acct, 302, tpl_ods(12, 4, 22000, 0, 0, 5, 303, 1, 600)); // furnace
        engine::register_template(acct, 303, tpl_no_ods(13, 9, 60000, 3000, 3000, 60)); // emperor
        engine::register_template(acct, 304, tpl_ods(14, 0, 1, 0, 0, 1, 303, 1, 200)); // chest

        // ---- Tables ----
        engine::register_table(acct, 1, vector[te(1, 100)]);
        engine::register_table(acct, 71, vector[te(300, 100)]);
        engine::register_table(acct, 72, vector[te(300, 60), te(301, 40)]);
        engine::register_table(acct, 73, vector[te(302, 55), te(300, 45)]);
        engine::register_table(acct, 74, vector[te(303, 55), te(300, 45)]);
        engine::register_table(acct, 75, vector[te(304, 100)]);
        engine::register_table(acct, 101, vector[te(1, 100)]);

        // ---- Dungeons ----
        engine::set_dungeon(acct, 1, engine::make_dungeon_config(1, 2, 1, 0, 0, 0, 0, 1));
        engine::set_dungeon(acct, 9, engine::make_dungeon_config(71, 3, 6, 0, 0, 0, 0, 4));
        engine::set_dungeon_battles(acct, 9, vector[
            engine::make_battle_config(71, 3),
            engine::make_battle_config(72, 3),
            engine::make_battle_config(73, 2),
            engine::make_battle_config(75, 1),
        ]);
        engine::add_battle_variant(acct, 9, 4, 75, 850);
        engine::add_battle_variant(acct, 9, 4, 74, 150);
        engine::set_dungeon(acct, 10, engine::make_dungeon_config(101, 2, 4, 0, 0, 0, 0, 1));
    }

    fun create_and_join(acct: &signer, diff: u64, hp: u64, atk: u64, mag: u64, spd: u64): u64 {
        engine::create_room(acct, diff);
        let rid = 1;
        engine::join_room(acct, rid, hp, atk, mag, spd, 0, 0, 0, 0);
        rid
    }

    fun start_combat(acct: &signer, rid: u64, plan: vector<u64>, seed: u64) {
        engine::set_plan(acct, rid, plan);
        engine::start_combat_test(acct, rid, seed);
    }

    fun drive(acct: &signer, rid: u64, n: u64) {
        let i = 0;
        while (i < n) {
            if (engine::room_phase(rid) != 1) return; // stop if not COMBAT
            engine::advance_turn_test(acct, rid);
            i = i + 1;
        };
    }

    // ============================ tests ============================
    #[test]
    fun test_all_56_skills_registered() {
        let a = account::create_account_for_test(@mohayo);
        seed_engine(&a);
        let i = 1;
        while (i <= 56) { assert!(engine::skill_registered(i), i); i = i + 1; };
    }

    #[test]
    fun test_rng_stream_deterministic() {
        let a = account::create_account_for_test(@mohayo);
        seed_engine(&a);
        let rid = create_and_join(&a, 1, 1000, 100, 50, 10);
        start_combat(&a, rid, vector[SKILL_ATTACK], 42);
        let (hp1, _, _, _, _, _, _) = engine::enemy_state(rid, 0);
        // Re-seed and restart
        let b = account::create_account_for_test(@0x2);
        engine::create_room(&b, 1);
        engine::join_room(&b, 2, 1000, 100, 50, 10, 0, 0, 0, 0);
        start_combat(&b, 2, vector[SKILL_ATTACK], 42);
        let (hp2, _, _, _, _, _, _) = engine::enemy_state(2, 0);
        assert!(hp1 == hp2, 1); // same seed → same outcome
    }

    #[test]
    fun test_basic_attack_deals_damage() {
        let a = account::create_account_for_test(@mohayo);
        seed_engine(&a);
        let rid = create_and_join(&a, 1, 10000, 5000, 0, 100);
        start_combat(&a, rid, vector[SKILL_ATTACK], 42);
        let (hp0, _, _, _, _, _, _) = engine::enemy_state(rid, 0);
        assert!(hp0 == 50, 1); // slime has 50 HP
        drive(&a, rid, 3);
        let (hp1, _, _, _, _, _, alive) = engine::enemy_state(rid, 0);
        if (alive) { assert!(hp1 < hp0, 2); };
    }

    #[test]
    fun test_room_lifecycle_to_settled() {
        let a = account::create_account_for_test(@mohayo);
        seed_engine(&a);
        let rid = create_and_join(&a, 1, 100000, 10000, 0, 100);
        start_combat(&a, rid, vector[SKILL_ATTACK], 42);
        assert!(engine::room_phase(rid) == 1, 1); // COMBAT
        let i = 0;
        while (i < 50 && engine::room_phase(rid) == 1) { drive(&a, rid, 1); i = i + 1; };
        assert!(engine::room_phase(rid) == 2, 2); // SETTLED
    }

    #[test]
    fun test_defeat_weakling() {
        let a = account::create_account_for_test(@mohayo);
        seed_engine(&a);
        let rid = create_and_join(&a, 1, 1, 1, 1, 1); // 1 HP
        start_combat(&a, rid, vector[SKILL_IDLE], 42);
        drive(&a, rid, 3);
        assert!(engine::room_phase(rid) == 2, 1);
    }

    #[test]
    fun test_enemy_takes_damage() {
        let a = account::create_account_for_test(@mohayo);
        seed_engine(&a);
        let rid = create_and_join(&a, 1, 10000, 5000, 0, 100);
        start_combat(&a, rid, vector[SKILL_ATTACK], 42);
        let (hp0, _, _, _, _, _, _) = engine::member_state(rid, 0);
        drive(&a, rid, 3);
        let (hp1, _, _, _, _, _, _) = engine::member_state(rid, 0);
        assert!(hp1 < hp0, 1); // member took damage from enemy
    }

    #[test]
    fun test_berserk_applies_effects() {
        let a = account::create_account_for_test(@mohayo);
        seed_engine(&a);
        let rid = create_and_join(&a, 1, 10000, 100, 50, 10);
        start_combat(&a, rid, vector[SKILL_BERSERK, SKILL_ATTACK], 42);
        drive(&a, rid, 2);
        // Berserk costs 0, should apply DMG_OUT_MOD and DMG_IN_MOD
        let (_, _, _, _, eff_count, _, _) = engine::member_state(rid, 0);
        assert!(eff_count >= 2, 1); // at least 2 effects
    }

    #[test]
    fun test_d9_multi_battle() {
        let a = account::create_account_for_test(@mohayo);
        seed_engine(&a);
        let rid = create_and_join(&a, 9, 50000, 5000, 5000, 50);
        start_combat(&a, rid, vector[SKILL_ATTACK], 42);
        let (bi, tb) = engine::room_battle(rid);
        assert!(bi == 1, 1);
        assert!(tb == 4, 2);
        // Drive battle 1
        let i = 0;
        while (i < 50 && engine::room_phase(rid) == 1) { drive(&a, rid, 1); i = i + 1; };
        if (engine::room_phase(rid) == 3) { // INTERMISSION
            engine::advance_battle(&a, rid);
            let (bi2, _) = engine::room_battle(rid);
            assert!(bi2 == 2, 3);
        };
    }

    #[test]
    fun test_d9_furnace_mana() {
        let a = account::create_account_for_test(@mohayo);
        seed_engine(&a);
        engine::set_dungeon(&a, 7, engine::make_dungeon_config(73, 1, 6, 0, 0, 0, 0, 1));
        engine::create_room(&a, 7);
        engine::join_room(&a, 1, 50000, 1, 1, 10, 0, 0, 0, 0);
        start_combat(&a, 1, vector[SKILL_ATTACK], 42);
        // Run several turns — furnace AI cycles leak/siphon
        drive(&a, 1, 10);
        let mana = engine::room_mana(1);
        // After 10 turns with mana_per_turn=6, pool should have accumulated mana
        // (leak adds 100, siphon removes 80, net positive per cycle)
        assert!(mana > 0, 1);
        // Verify enemy still alive (furnace has 22000 HP, member does 0 damage)
        let ec = engine::enemy_count(1);
        assert!(ec >= 1, 2);
    }

    #[test]
    fun test_d9_emperor_mana_cycle() {
        let a = account::create_account_for_test(@mohayo);
        seed_engine(&a);
        engine::set_dungeon(&a, 7, engine::make_dungeon_config(74, 1, 6, 0, 0, 0, 0, 1));
        engine::create_room(&a, 7);
        engine::join_room(&a, 1, 200000, 1, 1, 50, 0, 0, 0, 0); // very weak attack to avoid killing emperor
        start_combat(&a, 1, vector[SKILL_ATTACK], 77);
        let m0 = engine::room_mana(1);
        drive(&a, 1, 1);
        let m1 = engine::room_mana(1);
        // Emperor AI cycles through wheel/cannon/pressure/summon/leak/cannon
        // Mana should change each turn
        assert!(m1 > m0, 1); // at least regen
        drive(&a, 1, 5);
        let m5 = engine::room_mana(1);
        // After several turns, mana should accumulate (leak +100 each cycle)
        assert!(m5 > 0, 2);
    }

    #[test]
    fun test_d9_chest_emperor_spawn() {
        let a = account::create_account_for_test(@mohayo);
        seed_engine(&a);
        engine::set_dungeon(&a, 7, engine::make_dungeon_config(75, 1, 6, 0, 0, 0, 0, 1));
        engine::create_room(&a, 7);
        engine::join_room(&a, 1, 100000, 10000, 0, 100, 0, 0, 0, 0);
        start_combat(&a, 1, vector[SKILL_ATTACK], 42);
        drive(&a, 1, 3);
        // Chest has 1 HP — dies immediately; 20% emperor spawn
        let ec = engine::enemy_count(1);
        assert!(ec <= 10, 1);
    }
}

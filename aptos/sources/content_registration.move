/// Mohayo full game-content registration.
///
/// Registers, in strict sequential order (so ids match the canonical constants
/// from `content.move`):
///   - player skills id 1..44
///   - enemy skills id 45..56
///   - monster AIs, enemy templates, per-battle tables
///   - classes, races, affix templates
///   - dungeons D1..D10
///
/// Base skills (Attack/MagicBolt/Heal/Strike3) are registered ONLY as selectable
/// pool entries — they are NOT auto-granted to any character.
module mohayo::content_registration {
    use std::vector;
    use mohayo::types;
    use mohayo::character;
    use mohayo::skill_registry;
    use mohayo::content;

    // Per-battle turn cap, uniform across all dungeons. Its purpose is NOT difficulty:
    // it is a chain-safety eviction bound so a party that can never win (or that stalls
    // the room on-chain) is eventually cleared. At a 10–30s turn rhythm this bounds each
    // battle to roughly a few minutes to under an hour of real time — casual players have
    // ample room to keep pushing. Difficulty comes solely from combat, never the cap.

    const BATTLE_TURN_CAP: u64 = 120;

    // ---------------- effect helpers ----------------
    fun eff(op: u8, mag: u16, dur: u8, sc: u8, prob: u16): types::EffectSpec {
        // make_effect_spec(op, duration, magnitude, scope, prob)
        types::make_effect_spec(op, dur, mag, sc, prob)
    }

    fun nosummon(): types::SummonRule { types::make_summon_rule(0, 0, 0) }

    /// Player skill builder (player-side). ammo fields fixed to 0.
    fun sk(
        kind: u8, ap_cost: u16, ap_gain: u16, mana_cost: u64, hp_cost: u16,
        targeting: u8, weight_mode: u8, target_count: u8,
        power: u64, damage_cap: u64, base_acc: u16, flags: u8,
        effects: vector<types::EffectSpec>,
    ): types::Skill {
        types::make_skill(0, kind, ap_cost, ap_gain, 0, 0, mana_cost, hp_cost,
            targeting, weight_mode, target_count, power, damage_cap, base_acc, flags,
            effects, nosummon())
    }

    public entry fun register_all_content(account: &signer) {
        // ===================== CLASSES =====================
        // make_class_def(base_hp_pct, base_attack_pct, base_magic_pct, base_speed_pct, skill_slots)
        character::register_class(account, 1, types::make_class_def(150, 115, 90, 90, 1));   // 守卫
        character::register_class(account, 2, types::make_class_def(105, 130, 105, 120, 1)); // 剑士
        character::register_class(account, 3, types::make_class_def(85, 90, 140, 105, 1));   // 黑魔法师
        character::register_class(account, 4, types::make_class_def(110, 90, 135, 100, 1));  // 白魔法师
        character::register_class(account, 5, types::make_class_def(85, 120, 110, 135, 1));  // 火枪手

        // ===================== RACES =====================
        // make_race_def(hp_mod, stat_mods[atk,mag,spd], skill1, skill2, self_select_bonus)
        character::register_race(account, 0, types::make_race_def(0, vector[0, 0, 0], 0, 0, 2));                          // 人类
        character::register_race(account, 1, types::make_race_def(150, vector[250, -200, -150], content::SKILL_BERSERK, 0, 0));      // 兽人
        character::register_race(account, 2, types::make_race_def(400, vector[300, -200, -300], content::SKILL_STONE_BODY, 0, 0));   // 巨人
        character::register_race(account, 3, types::make_race_def(250, vector[200, -250, -100], content::SKILL_SPIRIT_RETURN, 0, 0));// 矮人
        character::register_race(account, 4, types::make_race_def(-50, vector[-100, 300, 350], content::SKILL_STORM, 0, 0));          // 精灵
        character::register_race(account, 5, types::make_race_def(-50, vector[250, 250, -100], content::SKILL_DRAGON_SCALE, 0, 0));  // 龙人
        character::register_race(account, 6, types::make_race_def(200, vector[-150, 400, 50], content::SKILL_HOLY_LIGHT, content::SKILL_ANGEL_JUDGMENT, 0)); // 天使
        character::register_race(account, 7, types::make_race_def(-100, vector[400, 0, 250], content::SKILL_SOUL_DRAIN, content::SKILL_ABYSS_WHISPER, 0));  // 恶魔

        // ===================== AFFIX TEMPLATES =====================
        // make_affix_template(stat_type, tier_weights, tier_values) ; stat 0=hp 1=atk 2=mag 3=spd
        let weights = vector[450u16, 200, 140, 90, 55, 30, 18, 10, 5, 2];
        let vals = vector[0u16, 150, 250, 380, 520, 750, 950, 1200, 1500, 2000];
        character::register_affix_template(account, 0, types::make_affix_template(0, weights, vals));
        character::register_affix_template(account, 1, types::make_affix_template(1, weights, vals));
        character::register_affix_template(account, 2, types::make_affix_template(2, weights, vals));
        character::register_affix_template(account, 3, types::make_affix_template(3, weights, vals));

        // ===================== PLAYER SKILLS 1..44 (canonical order) =====================
        // --- 基础技 (仅作为可自选池，不自动授予) ---
        skill_registry::register_skill(account, sk(types::KIND_PHYSICAL(), 0, 1, 2, 0,
            types::TGT_RAND_SINGLE_ENEMY(), types::WT_THREAT_ENEMY(), 1, 100, 0, 950, 0,
            vector::empty()));                                                          // 1 攻击
        skill_registry::register_skill(account, sk(types::KIND_MAGIC(), 0, 1, 3, 0,
            types::TGT_RAND_SINGLE_ENEMY(), types::WT_THREAT_ENEMY(), 1, 120, 0, 950, 0,
            vector::empty()));                                                          // 2 魔法弹
        skill_registry::register_skill(account, sk(types::KIND_SUPPORT(), 0, 1, 4, 0,
            types::TGT_MOST_WOUNDED_ALLY(), types::WT_HP_DEFICIT_ALLY(), 1, 800, 0, 1000, 0,
            vector[eff(types::OP_HEAL(), 800, 1, 1, 1000)]));                          // 3 治疗
        skill_registry::register_skill(account, sk(types::KIND_PHYSICAL(), 0, 2, 5, 0,
            types::TGT_RAND_STRIKE_ENEMY(), types::WT_THREAT_ENEMY(), 3, 100, 0, 900, 0,
            vector::empty()));                                                          // 4 三段斩

        // --- 通用池 ---
        skill_registry::register_skill(account, sk(types::KIND_SUPPORT(), 1, 0, 2, 0,
            types::TGT_SELF(), types::WT_UNIFORM(), 1, 0, 0, 1000, 0,
            vector[eff(types::OP_SHIELD(), 400, 4, 0, 1000)]));                        // 5 盾(通用)
        skill_registry::register_skill(account, sk(types::KIND_PHYSICAL(), 1, 1, 3, 0,
            types::TGT_RAND_SINGLE_ENEMY(), types::WT_THREAT_ENEMY(), 1, 130, 0, 900, 0,
            vector[eff(types::OP_STUN(), 1, 2, 1, 350)]));                             // 6 眩晕打击
        skill_registry::register_skill(account, sk(types::KIND_SUPPORT(), 1, 0, 4, 0,
            types::TGT_ALL_ENEMY(), types::WT_UNIFORM(), 1, 0, 0, 1000, 0,
            vector[eff(types::OP_ACC_DOWN(), 150, 3, 3, 1000)]));                     // 7 烟雾(尘幕)
        // 8 鹰眼(火枪手 class) —— GUAR_NEXT
        skill_registry::register_class_skill(account, sk(types::KIND_SUPPORT(), 1, 0, 0, 0,
            types::TGT_SELF(), types::WT_UNIFORM(), 1, 0, 0, 1000, 0,
            vector[eff(types::OP_GUAR_NEXT(), 1, 2, 0, 1000)]), 5);
        skill_registry::register_skill(account, sk(types::KIND_MAGIC(), 2, 1, 8, 0,
            types::TGT_RAND_SINGLE_ENEMY(), types::WT_THREAT_ENEMY(), 1, 300, 0, 900, 0,
            vector::empty()));                                                          // 9 魔素爆发
        skill_registry::register_skill(account, sk(types::KIND_PHYSICAL(), 1, 1, 3, 0,
            types::TGT_RAND_SINGLE_ENEMY(), types::WT_THREAT_ENEMY(), 1, 140, 0, 950, 0,
            vector[eff(types::OP_DOT(), 150, 3, 1, 1000)]));                          // 10 毒刃
        skill_registry::register_skill(account, sk(types::KIND_SUPPORT(), 1, 0, 2, 0,
            types::TGT_SELF(), types::WT_UNIFORM(), 1, 0, 0, 1000, 0,
            vector[eff(types::OP_TAUNT(), 1, 3, 0, 1000), eff(types::OP_DMG_IN_MOD(), 150, 3, 0, 1000)])); // 11 挑衅

        // --- 种族技 ---
        skill_registry::register_skill(account, sk(types::KIND_SUPPORT(), 1, 0, 0, 0,
            types::TGT_SELF(), types::WT_UNIFORM(), 1, 0, 0, 1000, 0,
            vector[eff(types::OP_DMG_OUT_MOD(), 250, 4, 0, 1000), eff(types::OP_DMG_IN_MOD(), 250, 4, 0, 1000)])); // 12 狂暴(兽人)
        skill_registry::register_skill(account, sk(types::KIND_SUPPORT(), 1, 0, 0, 0,
            types::TGT_SELF(), types::WT_UNIFORM(), 1, 0, 0, 1000, 0,
            vector[eff(types::OP_SHIELD(), 1200, 5, 0, 1000)]));                       // 13 磐石之躯(巨人)
        skill_registry::register_skill(account, sk(types::KIND_SUPPORT(), 1, 0, 0, 0,
            types::TGT_SELF(), types::WT_UNIFORM(), 1, 0, 0, 1000, 0,
            vector[eff(types::OP_DISPEL(), 0, 1, 0, 1000), eff(types::OP_HEAL(), 900, 1, 0, 1000)])); // 14 烈酒回魂(矮人)
        skill_registry::register_skill(account, sk(types::KIND_MAGIC(), 2, 1, 8, 0,
            types::TGT_RAND_STRIKE_ENEMY(), types::WT_THREAT_ENEMY(), 4, 140, 0, 900, 0,
            vector[eff(types::OP_STUN(), 1, 2, 1, 250)]));                             // 15 暴风术(精灵)
        skill_registry::register_skill(account, sk(types::KIND_SUPPORT(), 1, 0, 4, 0,
            types::TGT_SELF(), types::WT_UNIFORM(), 1, 0, 0, 1000, 0,
            vector[eff(types::OP_SHIELD(), 1000, 4, 0, 1000), eff(types::OP_DMG_OUT_MOD(), 180, 3, 0, 1000)])); // 16 龙鳞(龙人)
        skill_registry::register_skill(account, sk(types::KIND_SUPPORT(), 0, 1, 3, 0,
            types::TGT_MOST_WOUNDED_ALLY(), types::WT_HP_DEFICIT_ALLY(), 1, 1200, 0, 950, 0,
            vector[eff(types::OP_HEAL(), 1200, 1, 1, 1000)]));                        // 17 圣愈之光(天使)
        skill_registry::register_skill(account, sk(types::KIND_MAGIC(), 2, 1, 6, 0,
            types::TGT_RAND_STRIKE_ENEMY(), types::WT_THREAT_ENEMY(), 3, 160, 0, 900, 0,
            vector[eff(types::OP_STUN(), 1, 2, 1, 300)]));                            // 18 天使雷击(天使)
        skill_registry::register_skill(account, sk(types::KIND_PHYSICAL(), 1, 1, 0, 0,
            types::TGT_RAND_SINGLE_ENEMY(), types::WT_THREAT_ENEMY(), 1, 260, 0, 950, 0,
            vector[eff(types::OP_LIFESTEAL(), 500, 1, 1, 1000)]));                    // 19 汲魂(恶魔)
        skill_registry::register_skill(account, sk(types::KIND_SUPPORT(), 1, 0, 4, 0,
            types::TGT_ALL_ENEMY(), types::WT_UNIFORM(), 1, 0, 0, 1000, 0,
            vector[eff(types::OP_ACC_DOWN(), 200, 3, 3, 1000)]));                     // 20 深渊低语(恶魔)

        // --- 占位/备用 (不授予) ---
        skill_registry::register_skill(account, sk(types::KIND_SUPPORT(), 1, 0, 0, 0,
            types::TGT_SELF(), types::WT_UNIFORM(), 1, 0, 0, 1000, 0,
            vector[eff(types::OP_SHIELD(), 200, 2, 0, 1000)]));                       // 21 召唤(占位)
        skill_registry::register_skill(account, sk(types::KIND_SUPPORT(), 0, 0, 0, 0,
            types::TGT_SELF(), types::WT_UNIFORM(), 1, 0, 0, 1000, 0,
            vector::empty()));                                                          // 22 待机

        // --- 自选池补强 ---
        skill_registry::register_skill(account, sk(types::KIND_PHYSICAL(), 1, 1, 4, 0,
            types::TGT_RAND_SINGLE_ENEMY(), types::WT_THREAT_ENEMY(), 1, 420, 0, 620, 0,
            vector::empty()));                                                          // 23 一闪(高暴击/难命中)
        skill_registry::register_skill(account, sk(types::KIND_PHYSICAL(), 3, 1, 5, 0,
            types::TGT_RAND_STRIKE_ENEMY(), types::WT_THREAT_ENEMY(), 4, 150, 0, 900, 0,
            vector::empty()));                                                          // 24 暴风剑

        // --- 剑士 ---
        skill_registry::register_class_skill(account, sk(types::KIND_MAGIC(), 1, 2, 5, 0,
            types::TGT_RAND_SINGLE_ENEMY(), types::WT_THREAT_ENEMY(), 1, 280, 0, 950, 0,
            vector::empty()), 2);                                                       // 25 魔法剑
        // --- 火枪手 ---
        skill_registry::register_class_skill(account, sk(types::KIND_PHYSICAL(), 1, 3, 4, 0,
            types::TGT_RAND_STRIKE_ENEMY(), types::WT_THREAT_ENEMY(), 3, 150, 0, 820, 0,
            vector::empty()), 5);                                                       // 26 左轮弹雨
        skill_registry::register_class_skill(account, sk(types::KIND_PHYSICAL(), 2, 1, 0, 0,
            types::TGT_RAND_SINGLE_ENEMY(), types::WT_THREAT_ENEMY(), 1, 420, 0, 950, 0,
            vector[eff(types::OP_MANA_DELTA(), 40, 1, 0, 1000)]), 5);                  // 27 龙击弹
        // --- 黑魔法师 ---
        skill_registry::register_class_skill(account, sk(types::KIND_MAGIC(), 0, 1, 0, 0,
            types::TGT_ALL_ENEMY(), types::WT_UNIFORM(), 1, 3000, 0, 1000, types::FLAG_MANA_ALL(),
            vector[eff(types::OP_STUN(), 1, 3, 0, 1000)]), 3);                         // 28 爆裂魔法(全魔素)
        skill_registry::register_class_skill(account, sk(types::KIND_PHYSICAL(), 0, 2, 3, 0,
            types::TGT_RAND_SINGLE_ENEMY(), types::WT_THREAT_ENEMY(), 1, 220, 0, 900, 0,
            vector::empty()), 2);                                                       // 29 快速剑
        skill_registry::register_class_skill(account, sk(types::KIND_PHYSICAL(), 3, 1, 5, 0,
            types::TGT_RAND_SINGLE_ENEMY(), types::WT_THREAT_ENEMY(), 1, 340, 0, 950, 0,
            vector::empty()), 2);                                                       // 30 斩铁剑
        // --- 守卫 ---
        skill_registry::register_class_skill(account, sk(types::KIND_PHYSICAL(), 1, 1, 4, 0,
            types::TGT_RAND_SINGLE_ENEMY(), types::WT_THREAT_ENEMY(), 1, 260, 0, 900, 0,
            vector[eff(types::OP_STUN(), 1, 2, 1, 400)]), 1);                          // 31 盾击
        skill_registry::register_class_skill(account, sk(types::KIND_SUPPORT(), 2, 0, 6, 0,
            types::TGT_SELF(), types::WT_UNIFORM(), 1, 0, 0, 1000, 0,
            vector[eff(types::OP_SHIELD(), 1400, 4, 0, 1000)]), 1);                    // 32 盾墙
        skill_registry::register_class_skill(account, sk(types::KIND_SUPPORT(), 1, 0, 0, 0,
            types::TGT_SELF(), types::WT_UNIFORM(), 1, 0, 0, 1000, 0,
            vector[eff(types::OP_EVADE_UP(), 350, 3, 0, 1000)]), 1);                   // 33 回避
        // --- 黑魔法师 ---
        skill_registry::register_class_skill(account, sk(types::KIND_SUPPORT(), 0, 2, 0, 30,
            types::TGT_SELF(), types::WT_UNIFORM(), 1, 0, 0, 1000, 0,
            vector[eff(types::OP_MANA_DELTA(), 60, 1, 0, 1000)]), 3);                  // 34 献祭(HP→魔素)
        skill_registry::register_class_skill(account, sk(types::KIND_SUPPORT(), 1, 0, 5, 0,
            types::TGT_ALL_ENEMY(), types::WT_UNIFORM(), 1, 0, 0, 1000, 0,
            vector[eff(types::OP_ACC_DOWN(), 250, 3, 3, 1000)]), 3);                   // 35 黑幕
        // --- 白魔法师 ---
        skill_registry::register_class_skill(account, sk(types::KIND_MAGIC(), 1, 2, 5, 0,
            types::TGT_RAND_STRIKE_ENEMY(), types::WT_THREAT_ENEMY(), 5, 160, 0, 950, 0,
            vector::empty()), 4);                                                       // 36 光弹(固定5弹着)
        skill_registry::register_class_skill(account, sk(types::KIND_SUPPORT(), 1, 1, 8, 0,
            types::TGT_ALL_ALLY(), types::WT_UNIFORM(), 1, 0, 0, 1000, 0,
            vector[eff(types::OP_HEAL(), 400, 1, 2, 1000)]), 4);                       // 37 圣泉(群回)
        skill_registry::register_class_skill(account, sk(types::KIND_SUPPORT(), 1, 0, 4, 0,
            types::TGT_SELF(), types::WT_UNIFORM(), 1, 0, 0, 1000, 0,
            vector[eff(types::OP_SHIELD(), 1600, 5, 0, 1000)]), 4);                    // 38 替身人偶
        // --- 自选池 ---
        skill_registry::register_skill(account, sk(types::KIND_SUPPORT(), 0, 1, 2, 0,
            types::TGT_MOST_WOUNDED_ALLY(), types::WT_HP_DEFICIT_ALLY(), 1, 500, 0, 1000, 0,
            vector[eff(types::OP_HEAL(), 500, 1, 1, 1000)]));                          // 39 急救包扎
        skill_registry::register_skill(account, sk(types::KIND_SUPPORT(), 1, 0, 3, 0,
            types::TGT_ALL_ENEMY(), types::WT_UNIFORM(), 1, 0, 0, 1000, 0,
            vector[eff(types::OP_ACC_DOWN(), 300, 2, 3, 1000)]));                      // 40 致盲粉
        skill_registry::register_skill(account, sk(types::KIND_SUPPORT(), 2, 0, 5, 0,
            types::TGT_ALL_ALLY(), types::WT_UNIFORM(), 1, 0, 0, 1000, 0,
            vector[eff(types::OP_SHIELD(), 500, 3, 2, 1000)]));                        // 41 岩石壁垒
        skill_registry::register_skill(account, sk(types::KIND_SUPPORT(), 2, 0, 5, 0,
            types::TGT_ALL_ALLY(), types::WT_UNIFORM(), 1, 0, 0, 1000, 0,
            vector[eff(types::OP_SHIELD(), 850, 4, 2, 1000)]));                        // 42 魔力护盾(吃魔攻)
        skill_registry::register_skill(account, sk(types::KIND_MAGIC(), 3, 1, 8, 0,
            types::TGT_ALL_ENEMY(), types::WT_UNIFORM(), 1, 220, 0, 900, 0,
            vector::empty()));                                                          // 43 龙息
        skill_registry::register_skill(account, sk(types::KIND_MAGIC(), 3, 1, 9, 0,
            types::TGT_ALL_ENEMY(), types::WT_UNIFORM(), 1, 260, 0, 900, 0,
            vector::empty()));                                                          // 44 魔爆术

        // ===================== ENEMY SKILLS 45..56 (canonical order) =====================
        skill_registry::register_skill(account, sk(types::KIND_PHYSICAL(), 0, 0, 0, 0,
            types::TGT_RAND_SINGLE_ENEMY(), types::WT_THREAT_ENEMY(), 1, 1400, 0, 900, 0,
            vector::empty()));                                                          // 45 火花锯
        skill_registry::register_skill(account, sk(types::KIND_PHYSICAL(), 0, 0, 0, 0,
            types::TGT_RAND_SINGLE_ENEMY(), types::WT_THREAT_ENEMY(), 1, 680, 0, 900, 0,
            vector::empty()));                                                          // 46 粒子斩
        skill_registry::register_skill(account, sk(types::KIND_SUPPORT(), 0, 0, 0, 0,
            types::TGT_ROOM_ALL(), types::WT_UNIFORM(), 1, 0, 0, 1000, 0,
            vector[eff(types::OP_MANA_DRAIN(), 160, 1, 0, 1000)]));                    // 47 督军泄漏(抽魔素)
        skill_registry::register_skill(account, sk(types::KIND_SUPPORT(), 0, 0, 0, 0,
            types::TGT_ROOM_ALL(), types::WT_UNIFORM(), 1, 0, 0, 1000, 0,
            vector[eff(types::OP_MANA_DRAIN(), 200, 1, 0, 1000)]));                    // 48 炉泄漏
        skill_registry::register_skill(account, sk(types::KIND_SUPPORT(), 0, 0, 0, 0,
            types::TGT_ROOM_ALL(), types::WT_UNIFORM(), 1, 0, 0, 1000, 0,
            vector[eff(types::OP_MANA_DRAIN(), 320, 1, 0, 1000)]));                    // 49 炉虹吸(强抽)
        // 50 炉召唤(机神卫兵) —— 敌方阵营召唤，flags=0
        skill_registry::register_skill(account, types::make_skill(0, types::KIND_SUPPORT(), 0, 0, 0, 0,
            0, 0, types::TGT_SELF(), types::WT_UNIFORM(), 1, 0, 0, 1000,
            0, vector::empty(), types::make_summon_rule(19, 2, 0)));
        skill_registry::register_skill(account, sk(types::KIND_MAGIC(), 0, 0, 0, 0,
            types::TGT_RAND_SINGLE_ENEMY(), types::WT_THREAT_ENEMY(), 1, 2800, 0, 880, 0,
            vector::empty()));                                                          // 51 皇帝火花炮
        skill_registry::register_skill(account, sk(types::KIND_PHYSICAL(), 0, 0, 0, 0,
            types::TGT_RAND_STRIKE_ENEMY(), types::WT_UNIFORM(), 4, 450, 0, 850, 0,
            vector[eff(types::OP_STUN(), 1, 2, 3, 300)]));                            // 52 皇帝幻光轮
        skill_registry::register_skill(account, sk(types::KIND_SUPPORT(), 0, 0, 0, 0,
            types::TGT_ROOM_ALL(), types::WT_UNIFORM(), 1, 0, 0, 1000, 0,
            vector[eff(types::OP_MANA_DRAIN(), 260, 1, 0, 1000)]));                    // 53 皇帝泄漏
        skill_registry::register_skill(account, sk(types::KIND_SUPPORT(), 0, 0, 0, 0,
            types::TGT_ROOM_ALL(), types::WT_UNIFORM(), 1, 0, 0, 1000, 0,
            vector[eff(types::OP_MANA_DRAIN(), 420, 1, 0, 1000)]));                    // 54 皇帝虹吸
        skill_registry::register_skill(account, sk(types::KIND_SUPPORT(), 0, 0, 0, 0,
            types::TGT_ALL_ENEMY(), types::WT_UNIFORM(), 1, 0, 0, 1000, 0,
            vector[eff(types::OP_ACC_DOWN(), 250, 4, 3, 1000), eff(types::OP_STUN(), 1, 2, 3, 300)])); // 55 帝王威压
        // 56 皇帝召唤(机神卫兵) —— 敌方阵营召唤，flags=0
        skill_registry::register_skill(account, types::make_skill(0, types::KIND_SUPPORT(), 0, 0, 0, 0,
            0, 0, types::TGT_SELF(), types::WT_UNIFORM(), 1, 0, 0, 1000,
            0, vector::empty(), types::make_summon_rule(19, 2, 0)));

        // ===================== ENEMY SKILLS 57..67 (D2-D8 世界观怪物) =====================
        // 注: 敌技 targeting 以"施放者视角"书写; 引擎按阵营自动镜像(打玩家侧用 1-4)。
        skill_registry::register_skill(account, sk(types::KIND_PHYSICAL(), 0, 0, 0, 0,
            types::TGT_RAND_SINGLE_ENEMY(), types::WT_THREAT_ENEMY(), 1, 700, 0, 920, 0,
            vector::empty()));                                                          // 57 锈爪
        skill_registry::register_skill(account, sk(types::KIND_PHYSICAL(), 0, 0, 0, 0,
            types::TGT_RAND_SINGLE_ENEMY(), types::WT_THREAT_ENEMY(), 1, 800, 0, 900, 0,
            vector[eff(types::OP_STUN(), 1, 3, 1, 500)]));                              // 58 缠绕(50%概率晕2回合行动——早期控制体验的方差核心)
        skill_registry::register_skill(account, sk(types::KIND_PHYSICAL(), 0, 0, 0, 0,
            types::TGT_RAND_MULTI_ENEMY(), types::WT_THREAT_ENEMY(), 2, 500, 0, 880, 0,
            vector::empty()));                                                          // 59 矿镐横扫
        skill_registry::register_skill(account, sk(types::KIND_MAGIC(), 0, 0, 0, 0,
            types::TGT_RAND_SINGLE_ENEMY(), types::WT_THREAT_ENEMY(), 1, 900, 0, 920, 0,
            vector::empty()));                                                          // 60 摄魂(走魔攻)
        skill_registry::register_skill(account, sk(types::KIND_SUPPORT(), 0, 0, 0, 0,
            types::TGT_RAND_SINGLE_ENEMY(), types::WT_THREAT_ENEMY(), 1, 0, 0, 900, 0,
            vector[eff(types::OP_ACC_DOWN(), 300, 3, 1, 1000)]));                       // 61 恐惧尖啸
        skill_registry::register_skill(account, sk(types::KIND_MAGIC(), 0, 0, 0, 0,
            types::TGT_RAND_SINGLE_ENEMY(), types::WT_THREAT_ENEMY(), 1, 1000, 0, 920, 0,
            vector::empty()));                                                          // 62 圣光鞭挞(走魔攻)
        // 63 召唤机仆 —— 敌方阵营召唤残破机仆(模板31)×2，flags=0
        skill_registry::register_skill(account, types::make_skill(0, types::KIND_SUPPORT(), 0, 0, 0, 0,
            0, 0, types::TGT_SELF(), types::WT_UNIFORM(), 1, 0, 0, 1000,
            0, vector::empty(), types::make_summon_rule(31, 2, 0)));
        skill_registry::register_skill(account, sk(types::KIND_PHYSICAL(), 0, 0, 0, 0,
            types::TGT_RAND_MULTI_ENEMY(), types::WT_THREAT_ENEMY(), 3, 520, 0, 880, 0,
            vector::empty()));                                                          // 64 熔岩溅射
        skill_registry::register_skill(account, sk(types::KIND_MAGIC(), 0, 0, 0, 0,
            types::TGT_ALL_ENEMY(), types::WT_UNIFORM(), 1, 600, 0, 900, 0,
            vector::empty()));                                                          // 65 龙息(敌,全体魔攻)
        skill_registry::register_skill(account, sk(types::KIND_PHYSICAL(), 0, 0, 0, 0,
            types::TGT_RAND_STRIKE_ENEMY(), types::WT_THREAT_ENEMY(), 2, 650, 0, 900, 0,
            vector::empty()));                                                          // 66 撕咬(双段)
        skill_registry::register_skill(account, sk(types::KIND_SUPPORT(), 0, 0, 0, 0,
            types::TGT_SELF(), types::WT_UNIFORM(), 1, 0, 0, 1000, 0,
            vector[eff(types::OP_MANA_DRAIN(), 160, 1, 0, 1000)]));                     // 67 魔素虹吸(自施,单次抽池)

        // ===================== ENEMY SKILLS 68..77 (D5-D8 世界观怪物) =====================
        skill_registry::register_skill(account, sk(types::KIND_PHYSICAL(), 0, 0, 0, 0,
            types::TGT_RAND_SINGLE_ENEMY(), types::WT_THREAT_ENEMY(), 1, 950, 0, 920, 0,
            vector::empty()));                                                          // 68 督军炮(机神督军收敛重炮)
        // 69 督军增援: 召唤机神哨兵(模板41)×1 —— 战斗雪球感: 拖越久敌人越多
        skill_registry::register_skill(account, types::make_skill(0, types::KIND_SUPPORT(), 0, 0, 0, 0,
            0, 0, types::TGT_SELF(), types::WT_UNIFORM(), 1, 0, 0, 1000,
            0, vector::empty(), types::make_summon_rule(41, 1, 0)));
        skill_registry::register_skill(account, sk(types::KIND_PHYSICAL(), 0, 0, 0, 0,
            types::TGT_RAND_SINGLE_ENEMY(), types::WT_THREAT_ENEMY(), 1, 900, 0, 920, 0,
            vector::empty()));                                                          // 70 骸王斩
        // 71 骸王号令: 召唤白骨卫士(模板44)×2
        skill_registry::register_skill(account, types::make_skill(0, types::KIND_SUPPORT(), 0, 0, 0, 0,
            0, 0, types::TGT_SELF(), types::WT_UNIFORM(), 1, 0, 0, 1000,
            0, vector::empty(), types::make_summon_rule(44, 2, 0)));
        skill_registry::register_skill(account, sk(types::KIND_PHYSICAL(), 0, 0, 0, 0,
            types::TGT_RAND_SINGLE_ENEMY(), types::WT_THREAT_ENEMY(), 1, 1000, 0, 920, 0,
            vector::empty()));                                                          // 72 龙爪(物理)
        // 73 龙裔号令: 召唤熔岩幼龙(模板47)×2
        skill_registry::register_skill(account, types::make_skill(0, types::KIND_SUPPORT(), 0, 0, 0, 0,
            0, 0, types::TGT_SELF(), types::WT_UNIFORM(), 1, 0, 0, 1000,
            0, vector::empty(), types::make_summon_rule(47, 2, 0)));
        skill_registry::register_skill(account, sk(types::KIND_PHYSICAL(), 0, 0, 0, 0,
            types::TGT_RAND_SINGLE_ENEMY(), types::WT_THREAT_ENEMY(), 1, 900, 0, 900, 0,
            vector::empty()));                                                          // 74 裂爪(物理)
        skill_registry::register_skill(account, sk(types::KIND_PHYSICAL(), 0, 0, 0, 0,
            types::TGT_RAND_SINGLE_ENEMY(), types::WT_THREAT_ENEMY(), 1, 700, 0, 920, 0,
            vector[eff(types::OP_LIFESTEAL(), 350, 1, 1, 1000)]));                      // 75 深渊撕咬(物理+35%吸血)
        skill_registry::register_skill(account, sk(types::KIND_SUPPORT(), 0, 0, 0, 0,
            types::TGT_ALL_ENEMY(), types::WT_UNIFORM(), 1, 0, 0, 1000, 0,
            vector[eff(types::OP_ACC_DOWN(), 250, 3, 3, 1000)]));                       // 76 裂隙威压(全体玩家降命中)
        // 77 裂隙召唤: 召唤裂痕魔(模板50)×2
        skill_registry::register_skill(account, types::make_skill(0, types::KIND_SUPPORT(), 0, 0, 0, 0,
            0, 0, types::TGT_SELF(), types::WT_UNIFORM(), 1, 0, 0, 1000,
            0, vector::empty(), types::make_summon_rule(50, 2, 0)));

        // ===================== MONSTER AIs =====================
        // make_monster_ai(skill_cycle, cycle_len) ; skill selection is RANDOMIZED
        // per turn (engine picks a uniform-random index into the cycle each action).
        // Repeating a skill id inside the cycle raises its pick weight.
        ai(account, vector[content::SKILL_IDLE]);                              // 1 石头:待机
        ai(account, vector[content::SKILL_PARTICLE_SLASH]);                    // 2 哥布林:粒子斩
        ai(account, vector[content::SKILL_PARTICLE_SLASH,                      // 3 督军:斩+泄漏
            content::SKILL_MARSHAL_LEAK]);
        ai(account, vector[content::SKILL_IDLE, content::SKILL_IDLE]);         // 4 大石头:罕见偶动
        ai(account, vector[content::SKILL_SPARK_SAW,                           // 5 机神卫兵:锯+斩
            content::SKILL_PARTICLE_SLASH]);
        ai(account, vector[content::SKILL_FURNACE_LEAK,                        // 6 机神魔素炉
            content::SKILL_FURNACE_LEAK,
            content::SKILL_FURNACE_SIPHON,
            content::SKILL_FURNACE_SUMMON]);
        ai(account, vector[content::SKILL_EMPEROR_CANNON,                     // 7 机神皇帝
            content::SKILL_EMPEROR_WHEEL,
            content::SKILL_EMPEROR_LEAK,
            content::SKILL_EMPEROR_SIPHON,
            content::SKILL_EMPEROR_PRESSURE,
            content::SKILL_EMPEROR_SUMMON]);
        // ---- 世界观重做: D2-D4 新怪 AI (8..17) ----
        ai(account, vector[content::SKILL_RUST_CLAW,                          // 8 残破机仆:锈爪/宕机待机(方差: 半残的机仆随时卡死)
            content::SKILL_IDLE]);
        ai(account, vector[content::SKILL_VINE_BIND,                          // 9 唤魔藤蔓:缠绕为主
            content::SKILL_VINE_BIND,
            content::SKILL_RUST_CLAW]);
        ai(account, vector[content::SKILL_VINE_BIND,                          // 10 唤魔藤王:缠绕连发
            content::SKILL_VINE_BIND,
            content::SKILL_VINE_BIND,
            content::SKILL_RUST_CLAW]);
        ai(account, vector[content::SKILL_PICK_SWEEP]);                       // 11 亡灵矿工:横扫
        ai(account, vector[content::SKILL_WRAITH_DRAIN,                       // 12 怨灵:摄魂+恐惧
            content::SKILL_WRAITH_FEAR,
            content::SKILL_WRAITH_DRAIN]);
        ai(account, vector[content::SKILL_PRIEST_LASH,                        // 13 机神祭司:鞭挞+召唤
            content::SKILL_PRIEST_SUMMON,
            content::SKILL_PRIEST_LASH]);
        ai(account, vector[content::SKILL_MAGMA_SPLASH]);                     // 14 熔火傀儡:溅射
        ai(account, vector[content::SKILL_DRAGON_SPIT]);                      // 15 熔铁幼龙:龙息
        ai(account, vector[content::SKILL_DIRE_BITE]);                        // 16 深渊魔犬:撕咬
        ai(account, vector[content::SKILL_SIPHON,                             // 17 魔素吞噬者:虹吸为主
            content::SKILL_SIPHON,
            content::SKILL_RUST_CLAW]);
        // ---- 世界观重做: D5-D8 新怪 AI (18..29) ----
        ai(account, vector[content::SKILL_PARTICLE_SLASH]);                   // 18 机神哨兵:粒子斩
        ai(account, vector[content::SKILL_PARTICLE_SLASH]);                   // 19 机神魔像:粒子斩(与旧火焰魔像同伤档)
        ai(account, vector[content::SKILL_MARSHAL_CANNON,                     // 20 机神督军:炮/斩/泄漏/低频增援(雪球罕见但致命)
            content::SKILL_MARSHAL_CANNON,
            content::SKILL_PARTICLE_SLASH,
            content::SKILL_PARTICLE_SLASH,
            content::SKILL_MARSHAL_LEAK,
            content::SKILL_MARSHAL_REIN]);
        ai(account, vector[content::SKILL_PICK_SWEEP]);                       // 21 白骨卫士:横扫
        ai(account, vector[content::SKILL_WRAITH_DRAIN,                       // 22 缚灵:摄魂+恐惧
            content::SKILL_WRAITH_FEAR,
            content::SKILL_WRAITH_DRAIN]);
        ai(account, vector[content::SKILL_WIGHT_CLEAVE,                       // 23 守墓骸王:斩/横扫/号令
            content::SKILL_PICK_SWEEP,
            content::SKILL_WIGHT_CALL]);
        ai(account, vector[content::SKILL_DRAGON_SPIT]);                      // 24 熔岩幼龙:龙息(全体)
        ai(account, vector[content::SKILL_DRAGON_SPIT,                        // 25 渊炎龙:龙息/龙爪
            content::SKILL_DRAGON_CLAW,
            content::SKILL_DRAGON_SPIT]);
        ai(account, vector[content::SKILL_DRAGON_CLAW,                        // 26 渊龙长老:爪/号令/龙息
            content::SKILL_DRAGON_CALL,
            content::SKILL_DRAGON_SPIT,
            content::SKILL_DRAGON_CLAW]);
        ai(account, vector[content::SKILL_RIFT_CLAW]);                        // 27 裂痕魔:裂爪
        ai(account, vector[content::SKILL_ABYSS_BITE]);                       // 28 深渊魔:深渊撕咬(吸血)
        ai(account, vector[content::SKILL_RIFT_PRESSURE,                      // 29 裂隙支配者:威压/召唤/裂爪
            content::SKILL_RIFT_CALL,
            content::SKILL_RIFT_CLAW,
            content::SKILL_RIFT_CLAW]);

        // ===================== ENEMY TEMPLATES (ids 1..30, in order) =====================
        // make_enemy_template(ai_id, threat, max_hp, power, magic, speed, base_acc, rew_min, rew_max, ods)
        // ---- 魔素岩系（AI1 待机，不攻击；D1 灰烬矿坑挖矿）----
        // 血量按 120 回合/场的清退阀倒推：碎晶岩≈平凡1级可挖穿的下限；
        // 大魔素岩让"中坚矿工"(atk≈135) 逼近回合预算(有时超时清退)；巨型魔素岩只有更高等级能啃。
        skill_registry::register_template(account, tmpl(1, 0, 35, 0, 0, 5, 0, 1, 2));        // 1 碎晶岩
        skill_registry::register_template(account, tmpl(1, 0, 90, 0, 0, 4, 0, 3, 5));        // 2 魔素岩
        skill_registry::register_template(account, tmpl(1, 0, 735, 0, 0, 3, 0, 8, 12));      // 3 大魔素岩
        skill_registry::register_template(account, tmpl(1, 0, 2600, 0, 0, 2, 0, 18, 30));    // 4 巨型魔素岩
        // ---- 哥布林系（AI2）----
        skill_registry::register_template(account, tmpl(2, 1, 160, 60, 0, 90, 920, 2, 3));   // 5 哥布林
        skill_registry::register_template(account, tmpl(2, 1, 280, 90, 0, 130, 920, 3, 4)); // 6 狼
        skill_registry::register_template(account, tmpl(2, 2, 900, 150, 0, 95, 900, 8, 12));// 7 哥布林王
        // ---- 兽人系（AI2/AI3，D3 关口）----
        skill_registry::register_template(account, tmpl(2, 1, 420, 190, 0, 80, 900, 4, 6));  // 8 兽人士兵
        skill_registry::register_template(account, tmpl(2, 2, 950, 320, 0, 85, 900, 7, 10)); // 9 兽人战士
        skill_registry::register_template(account, tmpl(3, 2, 2800, 460, 180, 90, 900, 15, 25)); // 10 兽人酋长
        // ---- 遗迹系（AI2/AI3，D4 关口，幽灵走魔攻）----
        skill_registry::register_template(account, tmpl(2, 1, 320, 120, 240, 160, 900, 5, 7));// 11 幽灵
        skill_registry::register_template(account, tmpl(2, 2, 1400, 280, 0, 40, 900, 10, 15)); // 12 石魔像
        skill_registry::register_template(account, tmpl(3, 2, 3600, 420, 0, 45, 900, 20, 30)); // 13 守卫石像
        // ---- 灼热系（D5 关口，高威胁）----
        skill_registry::register_template(account, tmpl(2, 1, 1100, 2600, 0, 150, 910, 6, 9)); // 14 地狱猎犬
        skill_registry::register_template(account, tmpl(2, 2, 8200, 3400, 0, 50, 900, 16, 24)); // 15 火焰魔像
        skill_registry::register_template(account, tmpl(3, 3, 29400, 4300, 2650, 120, 900, 40, 60)); // 16 督军
        skill_registry::register_template(account, tmpl(2, 1, 3400, 2300, 0, 30, 900, 18, 28)); // 17 焦岩
        skill_registry::register_template(account, tmpl(3, 3, 15000, 3600, 2150, 110, 900, 35, 55)); // 18 熔岩督军
        // ---- 机神系（D7-D9，最高威胁）----
        skill_registry::register_template(account, tmpl(5, 2, 9000, 720, 260, 100, 900, 45, 70)); // 19 机神卫兵
        skill_registry::register_template(account, tmpl(5, 1, 6000, 820, 0, 130, 900, 30, 50)); // 20 火花机
        skill_registry::register_template(account, tmpl(3, 3, 20000, 1050, 480, 120, 900, 80, 120)); // 21 机神队长
        skill_registry::register_template(account, tmpl(5, 2, 26000, 1150, 0, 70, 900, 70, 110)); // 22 装甲巨像
        skill_registry::register_template(account, tmpl(3, 2, 14000, 1000, 740, 40, 900, 55, 85)); // 23 炮台
        skill_registry::register_template(account, tmpl(3, 3, 42000, 1300, 700, 110, 900, 150, 220)); // 24 要塞统领
        skill_registry::register_template(account, tmpl(3, 2, 18000, 1120, 990, 50, 900, 90, 140)); // 25 火力瞭望塔
        // 26 机神魔素炉 —— 不攻击(魔法/物攻0)，抽魔+召唤；被摧毁时 60% 召唤 机神皇帝(30)同场再战
        skill_registry::register_template(account, types::make_enemy_template(6, 2, 60000, 0, 0, 20, 0, 0, 0,
            types::make_on_death_spawn(30, 1, 600)));
        skill_registry::register_template(account, tmpl(1, 0, 50, 0, 0, 10, 0, 200, 300));  // 27 王座宝箱(待机)
        skill_registry::register_template(account, tmpl(5, 1, 11000, 950, 0, 125, 900, 60, 95)); // 28 火花锯兵
        skill_registry::register_template(account, tmpl(7, 3, 220000, 620, 480, 140, 920, 400, 600)); // 29 机神皇帝(备用机体, 王座变体)
        skill_registry::register_template(account, tmpl(7, 3, 250000, 640, 500, 150, 930, 500, 800)); // 30 机神皇帝(炉召唤)
        // ---- 世界观重做: D2-D4 新怪 (31..40)。模板 5-18(旧哥布林/兽人/幽灵/灼热草稿)不再被
        //     任何 dungeon 表引用, 仅保留占位防止 id 漂移; 内容定稿后可整体清理重排。 ----
        skill_registry::register_template(account, tmpl(8, 1, 110, 10, 0, 90, 900, 2, 4));     // 31 残破机仆(D2)
        skill_registry::register_template(account, tmpl(9, 1, 180, 14, 0, 45, 900, 4, 7));     // 32 唤魔藤蔓(D2)
        skill_registry::register_template(account, tmpl(10, 2, 500, 12, 0, 50, 900, 9, 14));   // 33 唤魔藤王(D2b3)
        skill_registry::register_template(account, tmpl(11, 1, 420, 110, 0, 60, 900, 4, 6));    // 34 亡灵矿工(D3)
        skill_registry::register_template(account, tmpl(12, 1, 320, 0, 170, 150, 900, 5, 8));   // 35 怨灵(D3,走魔攻)
        skill_registry::register_template(account, tmpl(13, 3, 1600, 0, 200, 70, 920, 14, 22)); // 36 机神祭司(D3b3,召唤)
        skill_registry::register_template(account, tmpl(14, 2, 1400, 150, 0, 35, 900, 10, 16)); // 37 熔火傀儡(D4,AoE)
        skill_registry::register_template(account, tmpl(15, 2, 1900, 0, 210, 110, 920, 18, 28));// 38 熔铁幼龙(D4,全体龙息)
        skill_registry::register_template(account, tmpl(16, 1, 700, 160, 0, 170, 920, 8, 13));  // 39 深渊魔犬(D4,高速)
        skill_registry::register_template(account, tmpl(17, 3, 3000, 60, 0, 20, 900, 24, 38));  // 40 魔素吞噬者(D4,虹吸)
        // ---- 世界观重做: D5-D8 新怪 (41..52) ----
        skill_registry::register_template(account, tmpl(18, 1, 1100, 2600, 0, 150, 910, 6, 9));  // 41 机神哨兵(D5)
        skill_registry::register_template(account, tmpl(19, 2, 8200, 3400, 0, 50, 900, 16, 24)); // 42 机神魔像(D5)
        skill_registry::register_template(account, tmpl(20, 3, 29400, 3600, 0, 120, 920, 40, 60));// 43 机神督军(D5,弱化皇帝机体: 炮/泄漏/增援)
        skill_registry::register_template(account, tmpl(21, 1, 1300, 700, 0, 60, 900, 8, 12));   // 44 白骨卫士(D6)
        skill_registry::register_template(account, tmpl(22, 1, 1000, 0, 950, 160, 900, 9, 14));  // 45 缚灵(D6,走魔攻)
        skill_registry::register_template(account, tmpl(23, 3, 14000, 950, 0, 80, 920, 40, 60)); // 46 守墓骸王(D6,号令)
        skill_registry::register_template(account, tmpl(24, 2, 2600, 0, 1150, 130, 910, 15, 22));// 47 熔岩幼龙(D7,龙息)
        skill_registry::register_template(account, tmpl(25, 2, 6000, 900, 1400, 90, 910, 25, 38));// 48 渊炎龙(D7,龙息+爪)
        skill_registry::register_template(account, tmpl(26, 3, 22000, 1200, 1600, 110, 920, 80, 120)); // 49 渊龙长老(D7,龙裔号令)
        skill_registry::register_template(account, tmpl(27, 1, 1500, 1400, 0, 170, 910, 18, 26));// 50 裂痕魔(D8)
        skill_registry::register_template(account, tmpl(28, 2, 4200, 1700, 0, 140, 910, 30, 45));// 51 深渊魔(D8,吸血)
        skill_registry::register_template(account, tmpl(29, 3, 42000, 1650, 0, 100, 920, 150, 240)); // 52 裂隙支配者(D8,威压/召唤)

        // ===================== ENEMY TABLES (ids 1..32, in order) =====================
        // make_table_entry(template_id, weight)
        skill_registry::register_table(account, vector[te(1, 1000)]);                          // 1 D1b1 碎晶岩
        skill_registry::register_table(account, vector[te(2, 1000)]);                          // 2 D1b2 魔素岩
        skill_registry::register_table(account, vector[te(3, 1000)]);                          // 3 D1b3 大魔素岩
        skill_registry::register_table(account, vector[te(4, 1000)]);                          // 4 D1b4 巨型魔素岩
        skill_registry::register_table(account, vector[te(5, 800), te(6, 200)]);               // 5 D2b1
        skill_registry::register_table(account, vector[te(6, 1000)]);                          // 6 D2b2
        skill_registry::register_table(account, vector[te(7, 700), te(5, 300)]);               // 7 D2b3
        skill_registry::register_table(account, vector[te(8, 1000)]);                          // 8 D3b1
        skill_registry::register_table(account, vector[te(9, 1000)]);                          // 9 D3b2
        skill_registry::register_table(account, vector[te(10, 1000)]);                         // 10 D3b3
        skill_registry::register_table(account, vector[te(11, 1000)]);                         // 11 D4b1
        skill_registry::register_table(account, vector[te(12, 800), te(11, 200)]);            // 12 D4b2
        skill_registry::register_table(account, vector[te(13, 1000)]);                         // 13 D4b3
        skill_registry::register_table(account, vector[te(14, 1000)]);                         // 14 D5b1
        skill_registry::register_table(account, vector[te(15, 900), te(14, 100)]);            // 15 D5b2
        skill_registry::register_table(account, vector[te(16, 1000)]);                         // 16 D5b3 督军(基准)
        skill_registry::register_table(account, vector[te(16, 800), te(15, 120), te(14, 80)]); // 17 D5b3 混沌变体
        skill_registry::register_table(account, vector[te(17, 1000)]);                         // 18 D6b1
        skill_registry::register_table(account, vector[te(15, 600), te(14, 200), te(17, 200)]); // 19 D6b2
        skill_registry::register_table(account, vector[te(18, 1000)]);                         // 20 D6b3
        skill_registry::register_table(account, vector[te(19, 800), te(20, 200)]);            // 21 D7b1
        skill_registry::register_table(account, vector[te(28, 1000)]);                         // 22 D7b2
        skill_registry::register_table(account, vector[te(21, 1000)]);                         // 23 D7b3
        skill_registry::register_table(account, vector[te(19, 900), te(20, 100)]);            // 24 D8b1
        skill_registry::register_table(account, vector[te(22, 1000)]);                         // 25 D8b2
        skill_registry::register_table(account, vector[te(23, 1000)]);                         // 26 D8b3
        skill_registry::register_table(account, vector[te(24, 1000)]);                         // 27 D8b4
        skill_registry::register_table(account, vector[te(19, 700), te(20, 150), te(28, 150)]); // 28 D9b1 卫兵走廊
        skill_registry::register_table(account, vector[te(19, 700), te(25, 300)]);            // 29 D9b2 前厅
        skill_registry::register_table(account, vector[te(26, 600), te(19, 400)]);            // 30 D9b3 机神魔素炉(炉+卫兵)
        skill_registry::register_table(account, vector[te(27, 1000)]);                        // 31 D9b4 王座宝箱
        skill_registry::register_table(account, vector[te(29, 1000)]);                        // 32 D9b4 皇帝备用机体
        // ---- 世界观重做: D2-D4 新表 (33..41)。旧表 5..27 为草稿体系占位,不被 dungeon battles 引用。 ----
        skill_registry::register_table(account, vector[te(31, 1000)]);                        // 33 D2b1 机仆×2
        skill_registry::register_table(account, vector[te(32, 700), te(31, 300)]);           // 34 D2b2 藤蔓混编
        skill_registry::register_table(account, vector[te(33, 800), te(31, 200)]);           // 35 D2b3 藤王+机仆
        skill_registry::register_table(account, vector[te(34, 1000)]);                        // 36 D3b1 矿工群
        skill_registry::register_table(account, vector[te(34, 650), te(35, 350)]);           // 37 D3b2 矿工+怨灵
        skill_registry::register_table(account, vector[te(36, 850), te(35, 150)]);           // 38 D3b3 机神祭司
        skill_registry::register_table(account, vector[te(37, 600), te(39, 400)]);           // 39 D4b1 傀儡+魔犬
        skill_registry::register_table(account, vector[te(38, 700), te(37, 300)]);           // 40 D4b2 熔铁幼龙
        skill_registry::register_table(account, vector[te(40, 600), te(39, 400)]);           // 41 D4b3 吞噬者+魔犬护卫
        // ---- 世界观重做: D5-D8 新表 (42..54) ----
        skill_registry::register_table(account, vector[te(41, 1000)]);                        // 42 D5b1 机神哨兵×3
        skill_registry::register_table(account, vector[te(42, 700), te(41, 300)]);           // 43 D5b2 魔像+哨兵
        skill_registry::register_table(account, vector[te(43, 1000)]);                        // 44 D5b3 机神督军(基准)
        skill_registry::register_table(account, vector[te(43, 750), te(42, 180), te(41, 70)]); // 45 D5b3 混沌变体
        skill_registry::register_table(account, vector[te(44, 1000)]);                        // 46 D6b1 白骨卫士×3
        skill_registry::register_table(account, vector[te(44, 650), te(45, 350)]);           // 47 D6b2 卫士+缚灵
        skill_registry::register_table(account, vector[te(46, 1000)]);                        // 48 D6b3 守墓骸王
        skill_registry::register_table(account, vector[te(47, 800), te(48, 200)]);           // 49 D7b1 幼龙群
        skill_registry::register_table(account, vector[te(48, 800), te(47, 200)]);           // 50 D7b2 渊炎龙
        skill_registry::register_table(account, vector[te(49, 1000)]);                        // 51 D7b3 渊龙长老
        skill_registry::register_table(account, vector[te(50, 700), te(51, 300)]);           // 52 D8b1 裂痕魔群
        skill_registry::register_table(account, vector[te(51, 800), te(50, 200)]);           // 53 D8b2 深渊魔
        skill_registry::register_table(account, vector[te(52, 1000)]);                        // 54 D8b3 裂隙支配者

        // ===================== DUNGEONS D1..D10 =====================
        // make_dungeon_config(table, enemy_count, mana/turn, reward_base, entry_fee, rescue_fee, turn_interval, battles)
        skill_registry::set_dungeon(account, 1, dng(1, 2, 2, 0, 0, 10, BATTLE_TURN_CAP, 4)); // D1 灰烬矿坑(免费)；mana 2/回合保证"每回合挥一镐"节奏
        skill_registry::set_dungeon_battles(account, 1, vector[bt(1, 2), bt(2, 2), bt(3, 2), bt(4, 1)]);
        skill_registry::set_dungeon(account, 2, dng(33, 3, 3, 0, 5, 15, BATTLE_TURN_CAP, 3)); // D2 遗弃回廊
        skill_registry::set_dungeon_battles(account, 2, vector[bt(33, 2), bt(34, 2), bt(35, 1)]);
        skill_registry::set_dungeon(account, 3, dng(36, 3, 3, 0, 10, 25, BATTLE_TURN_CAP, 3));// D3 沉眠圣所
        skill_registry::set_dungeon_battles(account, 3, vector[bt(36, 3), bt(37, 3), bt(38, 1)]);
        skill_registry::set_dungeon(account, 4, dng(39, 3, 4, 0, 15, 30, BATTLE_TURN_CAP, 3));// D4 熔铁深渊
        skill_registry::set_dungeon_battles(account, 4, vector[bt(39, 3), bt(40, 2), bt(41, 2)]);
        // D5 机神前哨 —— 单人攻关门；b3 督军战加入混沌变体(20% 拖出魔像/哨兵，提升随机性)
        skill_registry::set_dungeon(account, 5, dng(42, 3, 4, 0, 20, 40, BATTLE_TURN_CAP, 3));
        skill_registry::set_dungeon_battles(account, 5, vector[bt(42, 3), bt(43, 3), bt(44, 1)]);
        skill_registry::add_battle_variant(account, 5, 3, 45, 200);
        skill_registry::set_dungeon(account, 6, dng(46, 3, 5, 0, 25, 50, BATTLE_TURN_CAP, 3)); // D6 亡者回廊深处
        skill_registry::set_dungeon_battles(account, 6, vector[bt(46, 3), bt(47, 3), bt(48, 1)]);
        skill_registry::set_dungeon(account, 7, dng(49, 3, 6, 0, 30, 60, BATTLE_TURN_CAP, 3)); // D7 熔渊龙巢
        skill_registry::set_dungeon_battles(account, 7, vector[bt(49, 3), bt(50, 2), bt(51, 1)]);
        skill_registry::set_dungeon(account, 8, dng(52, 3, 6, 0, 35, 70, BATTLE_TURN_CAP, 3)); // D8 虚空裂隙
        skill_registry::set_dungeon_battles(account, 8, vector[bt(52, 3), bt(53, 3), bt(54, 1)]);
        // D9 机神王座 —— 4 战；b3 炉毁 60% 召唤皇帝，b4 变体 85% 宝箱 / 15% 皇帝备用机体
        skill_registry::set_dungeon(account, 9, dng(28, 3, 7, 0, 40, 100, BATTLE_TURN_CAP, 4));
        skill_registry::set_dungeon_battles(account, 9, vector[bt(28, 4), bt(29, 4), bt(30, 3), bt(31, 1)]);
        skill_registry::add_battle_variant(account, 9, 4, 31, 850);   // 王座宝箱
        skill_registry::add_battle_variant(account, 9, 4, 32, 150);   // 皇帝备用机体
        // D10 超级难关 —— 暂不填充具体内容，保留占位单场待机怪，后续配置
        skill_registry::set_dungeon(account, 10, dng(31, 1, 5, 0, 50, 200, BATTLE_TURN_CAP, 1));
    }

    // ===================== private helpers =====================
    fun ai(account: &signer, cycle: vector<u64>) {
        skill_registry::register_ai(account, types::make_monster_ai(cycle, (vector::length(&cycle) as u8)));
    }

    fun tmpl(ai_id: u64, threat: u8, hp: u64, power: u64, magic: u64, speed: u64,
             acc: u16, rmin: u16, rmax: u16): types::EnemyTemplate {
        types::make_enemy_template(ai_id, threat, hp, power, magic, speed, acc, rmin, rmax,
            types::make_on_death_spawn(0, 0, 0))
    }

    fun te(id: u64, w: u16): types::TableEntry { types::make_table_entry(id, w) }
    fun bt(table_id: u64, count: u64): types::BattleConfig { types::make_battle_config(table_id, count) }
    fun dng(table: u64, ecount: u64, mana: u64, rb: u16, entry: u64, rescue: u64,
            turns: u64, battles: u8): types::DungeonConfig {
        types::make_dungeon_config(table, ecount, mana, rb, entry, rescue, turns, battles)
    }
}
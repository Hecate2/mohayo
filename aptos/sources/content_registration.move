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
    use mohayo::item;

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
        id: u64, kind: u8, ap_cost: u16, ap_gain: u16, mana_cost: u64, hp_cost: u16,
        targeting: u8, weight_mode: u8, target_count: u8,
        power: u64, damage_cap: u64, base_acc: u16, flags: u8,
        effects: vector<types::EffectSpec>,
    ): types::Skill {
        types::make_skill(id, kind, ap_cost, ap_gain, 0, 0, mana_cost, hp_cost,
            targeting, weight_mode, target_count, power, damage_cap, base_acc, flags,
            effects, nosummon())
    }

    /// 带弹药需求的技能构造(火枪系): 每次施放固定消耗 ammo_cost 份 ammo_id 道具。
    fun ska(
        id: u64, kind: u8, ap_cost: u16, ap_gain: u16, mana_cost: u64, hp_cost: u16,
        targeting: u8, weight_mode: u8, target_count: u8,
        power: u64, damage_cap: u64, base_acc: u16, flags: u8,
        effects: vector<types::EffectSpec>, ammo_id: u16, ammo_cost: u16,
    ): types::Skill {
        types::make_skill(id, kind, ap_cost, ap_gain, ammo_id, ammo_cost, mana_cost, hp_cost,
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
                                
        // --- 通用池 ---
                        skill_registry::register_skill(account, sk(810,types::KIND_SUPPORT(), 1, 0, 4, 0,
            types::TGT_ALL_ENEMY(), types::WT_UNIFORM(), 1, 0, 0, 1000, 0,
            vector[eff(types::OP_ACC_DOWN(), 150, 3, 3, 1000)]));                     // 810 烟雾(尘幕)
        // 610 鹰眼(火枪手 class) —— GUAR_NEXT
        skill_registry::register_class_skill(account, sk(610,types::KIND_SUPPORT(), 1, 0, 0, 0,
            types::TGT_SELF(), types::WT_UNIFORM(), 1, 0, 0, 1000, 0,
            vector[eff(types::OP_GUAR_NEXT(), 1, 2, 0, 1000)]), 5);
                skill_registry::register_skill(account, sk(820,types::KIND_PHYSICAL(), 1, 1, 3, 0,
            types::TGT_RAND_SINGLE_ENEMY(), types::WT_THREAT_ENEMY(), 1, 140, 0, 950, 0,
            vector[eff(types::OP_DOT(), 20, 3, 1, 1000)]));                          // 820 毒刃(流血20×3, 复审后值; 同源刷新不累加)
        
        // --- 种族技 ---
        skill_registry::register_skill(account, sk(710,types::KIND_SUPPORT(), 1, 0, 0, 0,
            types::TGT_SELF(), types::WT_UNIFORM(), 1, 0, 0, 1000, 0,
            vector[eff(types::OP_DMG_OUT_MOD(), 250, 4, 0, 1000), eff(types::OP_DMG_IN_MOD(), 250, 4, 0, 1000)])); // 710 狂暴(兽人)
        skill_registry::register_skill(account, sk(720,types::KIND_SUPPORT(), 1, 0, 0, 0,
            types::TGT_SELF(), types::WT_UNIFORM(), 1, 0, 0, 1000, 0,
            vector[eff(types::OP_SHIELD(), 1200, 5, 0, 1000)]));                       // 720 磐石之躯(巨人)
        skill_registry::register_skill(account, sk(730,types::KIND_SUPPORT(), 1, 0, 0, 0,
            types::TGT_SELF(), types::WT_UNIFORM(), 1, 0, 0, 1000, 0,
            vector[eff(types::OP_DISPEL(), 0, 1, 0, 1000), eff(types::OP_HEAL(), 900, 1, 0, 1000)])); // 730 烈酒回魂(矮人)
        skill_registry::register_skill(account, sk(740,types::KIND_MAGIC(), 2, 1, 8, 0,
            types::TGT_RAND_STRIKE_ENEMY(), types::WT_THREAT_ENEMY(), 4, 140, 0, 900, 0,
            vector[eff(types::OP_STUN(), 1, 2, 1, 250)]));                             // 740 暴风术(精灵)
        skill_registry::register_skill(account, sk(750,types::KIND_SUPPORT(), 1, 0, 4, 0,
            types::TGT_SELF(), types::WT_UNIFORM(), 1, 0, 0, 1000, 0,
            vector[eff(types::OP_SHIELD(), 1000, 4, 0, 1000), eff(types::OP_DMG_OUT_MOD(), 180, 3, 0, 1000)])); // 750 龙鳞(龙人)
        skill_registry::register_skill(account, sk(760,types::KIND_SUPPORT(), 0, 1, 3, 0,
            types::TGT_MOST_WOUNDED_ALLY(), types::WT_HP_DEFICIT_ALLY(), 1, 1200, 0, 950, 0,
            vector[eff(types::OP_HEAL(), 1200, 1, 1, 1000)]));                        // 760 圣愈之光(天使)
        skill_registry::register_skill(account, sk(770,types::KIND_MAGIC(), 2, 1, 6, 0,
            types::TGT_RAND_STRIKE_ENEMY(), types::WT_THREAT_ENEMY(), 3, 160, 0, 900, 0,
            vector[eff(types::OP_STUN(), 1, 2, 1, 300)]));                            // 770 天使雷击(天使)
        skill_registry::register_skill(account, sk(780,types::KIND_PHYSICAL(), 1, 1, 0, 0,
            types::TGT_RAND_SINGLE_ENEMY(), types::WT_THREAT_ENEMY(), 1, 260, 0, 950, 0,
            vector[eff(types::OP_LIFESTEAL(), 500, 1, 1, 1000)]));                    // 780 汲魂(恶魔)
        skill_registry::register_skill(account, sk(790,types::KIND_SUPPORT(), 1, 0, 4, 0,
            types::TGT_ALL_ENEMY(), types::WT_UNIFORM(), 1, 0, 0, 1000, 0,
            vector[eff(types::OP_ACC_DOWN(), 200, 3, 3, 1000)]));                     // 790 深渊低语(恶魔)

        // --- 占位/备用 (不授予) ---
        skill_registry::register_skill(account, sk(180,types::KIND_SUPPORT(), 1, 0, 0, 0,
            types::TGT_SELF(), types::WT_UNIFORM(), 1, 0, 0, 1000, 0,
            vector[eff(types::OP_SHIELD(), 200, 2, 0, 1000)]));                       // 180 召唤(占位)
        skill_registry::register_skill(account, sk(190,types::KIND_SUPPORT(), 0, 0, 0, 0,
            types::TGT_SELF(), types::WT_UNIFORM(), 1, 0, 0, 1000, 0,
            vector::empty()));                                                          // 190 待机

        // --- 自选池补强 ---
        skill_registry::register_skill(account, sk(830,types::KIND_PHYSICAL(), 1, 1, 4, 0,
            types::TGT_RAND_SINGLE_ENEMY(), types::WT_THREAT_ENEMY(), 1, 420, 0, 620, 0,
            vector::empty()));                                                          // 830 一闪(高暴击/难命中)
        skill_registry::register_skill(account, sk(840,types::KIND_PHYSICAL(), 3, 1, 5, 0,
            types::TGT_RAND_STRIKE_ENEMY(), types::WT_THREAT_ENEMY(), 4, 150, 0, 900, 0,
            vector::empty()));                                                          // 840 暴风剑

        // --- 剑士 ---
        skill_registry::register_class_skill(account, sk(330,types::KIND_MAGIC(), 1, 2, 5, 0,
            types::TGT_RAND_SINGLE_ENEMY(), types::WT_THREAT_ENEMY(), 1, 280, 0, 950, 0,
            vector::empty()), 2);                                                       // 330 魔法剑
        // --- 火枪手 ---
        // 620/630 火枪子弹走双修公式 power × (ATK + MAG)/1000 → power 取原物理值之半, 保持同量级
        skill_registry::register_class_skill(account, ska(620, types::KIND_HYBRID(), 1, 3, 4, 0,
            types::TGT_RAND_STRIKE_ENEMY(), types::WT_THREAT_ENEMY(), 3, 75, 0, 820, 0,
            vector::empty(), (item::ITEM_LEAD_BULLET as u16), 3), 5);                   // 620 左轮弹雨(耗铅弹×3)
        skill_registry::register_class_skill(account, ska(630, types::KIND_HYBRID(), 2, 1, 0, 0,
            types::TGT_RAND_SINGLE_ENEMY(), types::WT_THREAT_ENEMY(), 1, 210, 0, 950, 0,
            vector[eff(types::OP_MANA_DELTA(), 40, 1, 0, 1000)], (item::ITEM_DRAGON_BULLET as u16), 1), 5); // 630 龙击弹(耗龙击弹×1, 命中产魔)
        // --- 黑魔法师 ---
        // §4.9 固有绝对命中: flags = GUARANTEED_HIT(bit0) | FLAG_MANA_ALL(bit1)。
        // 此前只写了 FLAG_MANA_ALL, 靠 base_acc=1000 只是「基本必中」, 会被烟幕/致盲/回避削减(§2.6.11)。
        skill_registry::register_class_skill(account, sk(430,types::KIND_MAGIC(), 0, 1, 0, 0,
            types::TGT_ALL_ENEMY(), types::WT_UNIFORM(), 1, 3000, 0, 1000, types::FLAG_GUARANTEED_HIT() | types::FLAG_MANA_ALL(),
            vector[eff(types::OP_STUN(), 1, 3, 0, 1000)]), 3);                         // 430 爆裂魔法(全魔素+绝对命中+自晕)
        skill_registry::register_class_skill(account, sk(310,types::KIND_PHYSICAL(), 0, 2, 3, 0,
            types::TGT_RAND_SINGLE_ENEMY(), types::WT_THREAT_ENEMY(), 1, 220, 0, 900, 0,
            vector::empty()), 2);                                                       // 310 快速剑
        skill_registry::register_class_skill(account, sk(320,types::KIND_PHYSICAL(), 3, 1, 5, 0,
            types::TGT_RAND_SINGLE_ENEMY(), types::WT_THREAT_ENEMY(), 1, 340, 0, 950, 0,
            vector::empty()), 2);                                                       // 320 斩铁剑
        // --- 守卫 ---
        skill_registry::register_class_skill(account, sk(210,types::KIND_PHYSICAL(), 1, 1, 4, 0,
            types::TGT_RAND_SINGLE_ENEMY(), types::WT_THREAT_ENEMY(), 1, 260, 0, 900, 0,
            vector[eff(types::OP_STUN(), 1, 2, 1, 400), eff(types::OP_TAUNT(), 1, 2, 0, 1000)]), 1); // 210 盾击(眩晕40% + 必嘲讽2轮)
        skill_registry::register_class_skill(account, sk(220,types::KIND_SUPPORT(), 2, 0, 6, 0,
            types::TGT_SELF(), types::WT_UNIFORM(), 1, 0, 0, 1000, 0,
            vector[eff(types::OP_SHIELD(), 1400, 4, 0, 1000)]), 1);                    // 220 盾墙
        skill_registry::register_class_skill(account, sk(230,types::KIND_SUPPORT(), 1, 0, 0, 0,
            types::TGT_SELF(), types::WT_UNIFORM(), 1, 0, 0, 1000, 0,
            vector[eff(types::OP_EVADE_UP(), 350, 3, 0, 1000)]), 1);                   // 230 回避
        // --- 黑魔法师 ---
        // 28 爆裂魔法(全魔素) 见上; 34 献祭 = 烧血 4 段魔法攻击, 每段命中为房间池 +10 魔素
        // (战地血泵: 黑魔唯一常规输出 + 全队应急回蓝; 段数×产魔量初值, sim 可调)
        skill_registry::register_class_skill(account, sk(410,types::KIND_MAGIC(), 0, 0, 0, 30,
            types::TGT_RAND_STRIKE_ENEMY(), types::WT_THREAT_ENEMY(), 4, 110, 0, 900, 0,
            vector[eff(types::OP_MANA_DELTA(), 10, 1, 0, 1000)]), 3);                  // 410 献祭(HP→多段输出→每命中产魔素)
        skill_registry::register_class_skill(account, sk(420,types::KIND_SUPPORT(), 1, 0, 5, 0,
            types::TGT_ALL_ENEMY(), types::WT_UNIFORM(), 1, 0, 0, 1000, 0,
            vector[eff(types::OP_ACC_DOWN(), 250, 3, 3, 1000)]), 3);                   // 420 黑幕
        // --- 白魔法师 ---
        skill_registry::register_class_skill(account, sk(510,types::KIND_MAGIC(), 1, 2, 5, 0,
            types::TGT_RAND_STRIKE_ENEMY(), types::WT_THREAT_ENEMY(), 5, 160, 0, 950, 0,
            vector::empty()), 4);                                                       // 510 光弹(固定5弹着)
        skill_registry::register_class_skill(account, sk(520,types::KIND_SUPPORT(), 1, 1, 8, 0,
            types::TGT_ALL_ALLY(), types::WT_UNIFORM(), 1, 450, 0, 1000, 0,
            vector[eff(types::OP_HEAL(), 450, 1, 2, 1000), eff(types::OP_MANA_DELTA(), 6, 1, 0, 1000)]), 4); // 520 圣泉(群回 power×魔攻; 每治疗目标回池6魔素——奶人回蓝)
        // 38 替身人偶 —— 召唤无嘲讽、无行动的己方假目标(模板35)吸随机火力; FLAG_SUMMON_ALLY(bit2)
        skill_registry::register_class_skill(account, types::make_skill(530, types::KIND_SUPPORT(), 1, 0, 0, 0,
            4, 0, types::TGT_SELF(), types::WT_UNIFORM(), 1, 0, 0, 1000,
            types::FLAG_SUMMON_ALLY(), vector::empty(), types::make_summon_rule(35, 1, 0)), 4); // 530 替身人偶
        // --- 自选池 ---
        skill_registry::register_skill(account, sk(850,types::KIND_SUPPORT(), 0, 1, 2, 0,
            types::TGT_RAND_SINGLE_ALLY(), types::WT_HP_DEFICIT_ALLY(), 1, 500, 0, 1000, 0,
            vector[eff(types::OP_HEAL(), 500, 1, 1, 1000)]));                          // 850 急救包扎(随机我方, 按血量亏空加权; 确定性最重伤者留给天使圣愈之光)
        // 860 致盲粉(双刃): 命中单体随机敌人 + **同时自降命中**(SCOPE_SELF 条) —— 大幅(450)>黑幕(250)>尘幕(150)
        skill_registry::register_skill(account, sk(860,types::KIND_SUPPORT(), 1, 0, 3, 0,
            types::TGT_RAND_SINGLE_ENEMY(), types::WT_THREAT_ENEMY(), 1, 0, 0, 1000, 0,
            vector[eff(types::OP_ACC_DOWN(), 450, 2, 0, 1000),
                   eff(types::OP_ACC_DOWN(), 450, 2, 1, 1000)]));                      // 860 致盲粉
        skill_registry::register_skill(account, sk(870,types::KIND_SUPPORT(), 2, 0, 5, 0,
            types::TGT_SELF(), types::WT_UNIFORM(), 1, 0, 0, 1000, 0,
            vector[eff(types::OP_SHIELD(), 500, 3, 0, 1000)]));                        // 870 岩石壁垒(自施小额护盾)
        // 880 魔力护盾(自施): 护盾量 = power × 魔攻/1000 —— 法系越强盾越厚(与岩石壁垒的小额固定互补)
        skill_registry::register_skill(account, sk(880,types::KIND_MAGIC(), 2, 0, 5, 0,
            types::TGT_SELF(), types::WT_UNIFORM(), 1, 900, 0, 1000, 0,
            vector[eff(types::OP_SHIELD(), 0, 4, 0, 1000)]));                          // 880 魔力护盾(吃魔攻)
        skill_registry::register_skill(account, sk(890,types::KIND_MAGIC(), 3, 1, 8, 0,
            types::TGT_ALL_ENEMY(), types::WT_UNIFORM(), 1, 220, 0, 900, 0,
            vector::empty()));                                                          // 890 龙息
        skill_registry::register_skill(account, sk(900,types::KIND_MAGIC(), 3, 1, 9, 0,
            types::TGT_ALL_ENEMY(), types::WT_UNIFORM(), 1, 260, 0, 900, 0,
            vector::empty()));                                                          // 900 魔爆术

        // ===================== ENEMY SKILLS 45..56 (canonical order) =====================
        skill_registry::register_skill(account, sk(1015,types::KIND_PHYSICAL(), 0, 0, 0, 0,
            types::TGT_RAND_SINGLE_ENEMY(), types::WT_THREAT_ENEMY(), 1, 1400, 0, 900, 0,
            vector::empty()));                                                          // 1015 火花锯
        skill_registry::register_skill(account, sk(1010,types::KIND_PHYSICAL(), 0, 0, 0, 0,
            types::TGT_RAND_SINGLE_ENEMY(), types::WT_THREAT_ENEMY(), 1, 680, 0, 900, 0,
            vector::empty()));                                                          // 1010 粒子斩
        skill_registry::register_skill(account, sk(1020,types::KIND_SUPPORT(), 0, 0, 0, 0,
            types::TGT_ROOM_ALL(), types::WT_UNIFORM(), 1, 0, 0, 1000, 0,
            vector[eff(types::OP_MANA_DRAIN(), 160, 1, 0, 1000)]));                    // 1020 督军泄漏(抽魔素)
        skill_registry::register_skill(account, sk(1610,types::KIND_SUPPORT(), 0, 0, 0, 0,
            types::TGT_ROOM_ALL(), types::WT_UNIFORM(), 1, 0, 0, 1000, 0,
            vector[eff(types::OP_MANA_DRAIN(), 200, 1, 0, 1000)]));                    // 1610 炉泄漏
        skill_registry::register_skill(account, sk(1615,types::KIND_SUPPORT(), 0, 0, 0, 0,
            types::TGT_ROOM_ALL(), types::WT_UNIFORM(), 1, 0, 0, 1000, 0,
            vector[eff(types::OP_MANA_DRAIN(), 320, 1, 0, 1000)]));                    // 1615 炉虹吸(强抽)
        // 1620 炉召唤(机神卫兵) —— 敌方阵营召唤，flags=0
        skill_registry::register_skill(account, types::make_skill(1620, types::KIND_SUPPORT(), 0, 0, 0, 0,
            0, 0, types::TGT_SELF(), types::WT_UNIFORM(), 1, 0, 0, 1000,
            0, vector::empty(), types::make_summon_rule(27, 2, 0)));
        skill_registry::register_skill(account, sk(1630,types::KIND_MAGIC(), 0, 0, 0, 0,
            types::TGT_RAND_SINGLE_ENEMY(), types::WT_THREAT_ENEMY(), 1, 2800, 0, 880, 0,
            vector::empty()));                                                          // 1630 皇帝火花炮
        skill_registry::register_skill(account, sk(1635,types::KIND_PHYSICAL(), 0, 0, 0, 0,
            types::TGT_RAND_STRIKE_ENEMY(), types::WT_UNIFORM(), 4, 450, 0, 850, 0,
            vector[eff(types::OP_STUN(), 1, 2, 3, 300)]));                            // 1635 皇帝幻光轮
        skill_registry::register_skill(account, sk(1640,types::KIND_SUPPORT(), 0, 0, 0, 0,
            types::TGT_ROOM_ALL(), types::WT_UNIFORM(), 1, 0, 0, 1000, 0,
            vector[eff(types::OP_MANA_DRAIN(), 260, 1, 0, 1000)]));                    // 1640 皇帝泄漏
        skill_registry::register_skill(account, sk(1645,types::KIND_SUPPORT(), 0, 0, 0, 0,
            types::TGT_ROOM_ALL(), types::WT_UNIFORM(), 1, 0, 0, 1000, 0,
            vector[eff(types::OP_MANA_DRAIN(), 420, 1, 0, 1000)]));                    // 1645 皇帝虹吸
        skill_registry::register_skill(account, sk(1650,types::KIND_SUPPORT(), 0, 0, 0, 0,
            types::TGT_ALL_ENEMY(), types::WT_UNIFORM(), 1, 0, 0, 1000, 0,
            vector[eff(types::OP_ACC_DOWN(), 250, 4, 3, 1000), eff(types::OP_STUN(), 1, 2, 3, 300)])); // 1650 帝王威压
        // 1655 皇帝召唤(机神卫兵) —— 敌方阵营召唤，flags=0
        skill_registry::register_skill(account, types::make_skill(1655, types::KIND_SUPPORT(), 0, 0, 0, 0,
            0, 0, types::TGT_SELF(), types::WT_UNIFORM(), 1, 0, 0, 1000,
            0, vector::empty(), types::make_summon_rule(27, 2, 0)));

        // ===================== ENEMY SKILLS 57..67 (D2-D8 世界观怪物) =====================
        // 注: 敌技 targeting 以"施放者视角"书写; 引擎按阵营自动镜像(打玩家侧用 1-4)。
        skill_registry::register_skill(account, sk(1110,types::KIND_PHYSICAL(), 0, 0, 0, 0,
            types::TGT_RAND_SINGLE_ENEMY(), types::WT_THREAT_ENEMY(), 1, 700, 0, 920, 0,
            vector::empty()));                                                          // 1110 锈爪
        skill_registry::register_skill(account, sk(1115,types::KIND_PHYSICAL(), 0, 0, 0, 0,
            types::TGT_RAND_SINGLE_ENEMY(), types::WT_THREAT_ENEMY(), 1, 800, 0, 900, 0,
            vector[eff(types::OP_STUN(), 1, 3, 1, 500)]));                              // 1115 缠绕(50%概率晕2回合行动——早期控制体验的方差核心)
        skill_registry::register_skill(account, sk(1120,types::KIND_PHYSICAL(), 0, 0, 0, 0,
            types::TGT_RAND_MULTI_ENEMY(), types::WT_THREAT_ENEMY(), 2, 500, 0, 880, 0,
            vector::empty()));                                                          // 1120 矿镐横扫
        skill_registry::register_skill(account, sk(1125,types::KIND_MAGIC(), 0, 0, 0, 0,
            types::TGT_RAND_SINGLE_ENEMY(), types::WT_THREAT_ENEMY(), 1, 900, 0, 920, 0,
            vector::empty()));                                                          // 1125 摄魂(走魔攻)
        skill_registry::register_skill(account, sk(1130,types::KIND_SUPPORT(), 0, 0, 0, 0,
            types::TGT_RAND_SINGLE_ENEMY(), types::WT_THREAT_ENEMY(), 1, 0, 0, 900, 0,
            vector[eff(types::OP_ACC_DOWN(), 300, 3, 1, 1000)]));                       // 1130 恐惧尖啸
        skill_registry::register_skill(account, sk(1135,types::KIND_MAGIC(), 0, 0, 0, 0,
            types::TGT_RAND_SINGLE_ENEMY(), types::WT_THREAT_ENEMY(), 1, 1000, 0, 920, 0,
            vector::empty()));                                                          // 1135 圣光鞭挞(走魔攻)
        // 1140 召唤机仆 —— 敌方阵营召唤残破机仆(模板5)×2，flags=0
        skill_registry::register_skill(account, types::make_skill(1140, types::KIND_SUPPORT(), 0, 0, 0, 0,
            0, 0, types::TGT_SELF(), types::WT_UNIFORM(), 1, 0, 0, 1000,
            0, vector::empty(), types::make_summon_rule(5, 2, 0)));
        skill_registry::register_skill(account, sk(1145,types::KIND_PHYSICAL(), 0, 0, 0, 0,
            types::TGT_RAND_MULTI_ENEMY(), types::WT_THREAT_ENEMY(), 3, 520, 0, 880, 0,
            vector::empty()));                                                          // 1145 熔岩溅射
        skill_registry::register_skill(account, sk(1150,types::KIND_MAGIC(), 0, 0, 0, 0,
            types::TGT_ALL_ENEMY(), types::WT_UNIFORM(), 1, 600, 0, 900, 0,
            vector::empty()));                                                          // 1150 龙息(敌,全体魔攻)
        skill_registry::register_skill(account, sk(1155,types::KIND_PHYSICAL(), 0, 0, 0, 0,
            types::TGT_RAND_STRIKE_ENEMY(), types::WT_THREAT_ENEMY(), 2, 650, 0, 900, 0,
            vector::empty()));                                                          // 1155 撕咬(双段)
        skill_registry::register_skill(account, sk(1160,types::KIND_SUPPORT(), 0, 0, 0, 0,
            types::TGT_SELF(), types::WT_UNIFORM(), 1, 0, 0, 1000, 0,
            vector[eff(types::OP_MANA_DRAIN(), 160, 1, 0, 1000)]));                     // 1160 魔素虹吸(自施,单次抽池)

        // ===================== ENEMY SKILLS 68..77 (D5-D8 世界观怪物) =====================
        skill_registry::register_skill(account, sk(1210,types::KIND_PHYSICAL(), 0, 0, 0, 0,
            types::TGT_RAND_SINGLE_ENEMY(), types::WT_THREAT_ENEMY(), 1, 950, 0, 920, 0,
            vector::empty()));                                                          // 1210 督军炮(机神督军收敛重炮)
        // 1215 督军增援: 召唤机神哨兵(模板15)×1 —— 战斗雪球感: 拖越久敌人越多
        skill_registry::register_skill(account, types::make_skill(1215, types::KIND_SUPPORT(), 0, 0, 0, 0,
            0, 0, types::TGT_SELF(), types::WT_UNIFORM(), 1, 0, 0, 1000,
            0, vector::empty(), types::make_summon_rule(15, 1, 0)));
        skill_registry::register_skill(account, sk(1310,types::KIND_PHYSICAL(), 0, 0, 0, 0,
            types::TGT_RAND_SINGLE_ENEMY(), types::WT_THREAT_ENEMY(), 1, 900, 0, 920, 0,
            vector::empty()));                                                          // 1310 骸王斩
        // 1315 骸王号令: 召唤白骨卫士(模板18)×2
        skill_registry::register_skill(account, types::make_skill(1315, types::KIND_SUPPORT(), 0, 0, 0, 0,
            0, 0, types::TGT_SELF(), types::WT_UNIFORM(), 1, 0, 0, 1000,
            0, vector::empty(), types::make_summon_rule(18, 2, 0)));
        skill_registry::register_skill(account, sk(1410,types::KIND_PHYSICAL(), 0, 0, 0, 0,
            types::TGT_RAND_SINGLE_ENEMY(), types::WT_THREAT_ENEMY(), 1, 1000, 0, 920, 0,
            vector::empty()));                                                          // 1410 龙爪(物理)
        // 1415 龙裔号令: 召唤熔岩幼龙(模板21)×2
        skill_registry::register_skill(account, types::make_skill(1415, types::KIND_SUPPORT(), 0, 0, 0, 0,
            0, 0, types::TGT_SELF(), types::WT_UNIFORM(), 1, 0, 0, 1000,
            0, vector::empty(), types::make_summon_rule(21, 2, 0)));
        skill_registry::register_skill(account, sk(1510,types::KIND_PHYSICAL(), 0, 0, 0, 0,
            types::TGT_RAND_SINGLE_ENEMY(), types::WT_THREAT_ENEMY(), 1, 900, 0, 900, 0,
            vector::empty()));                                                          // 1510 裂爪(物理)
        skill_registry::register_skill(account, sk(1515,types::KIND_PHYSICAL(), 0, 0, 0, 0,
            types::TGT_RAND_SINGLE_ENEMY(), types::WT_THREAT_ENEMY(), 1, 700, 0, 920, 0,
            vector[eff(types::OP_LIFESTEAL(), 350, 1, 1, 1000)]));                      // 1515 深渊撕咬(物理+35%吸血)
        skill_registry::register_skill(account, sk(1520,types::KIND_SUPPORT(), 0, 0, 0, 0,
            types::TGT_ALL_ENEMY(), types::WT_UNIFORM(), 1, 0, 0, 1000, 0,
            vector[eff(types::OP_ACC_DOWN(), 250, 3, 3, 1000)]));                       // 1520 裂隙威压(全体玩家降命中)
        // 1525 裂隙召唤: 召唤裂痕魔(模板24)×2
        skill_registry::register_skill(account, types::make_skill(1525, types::KIND_SUPPORT(), 0, 0, 0, 0,
            0, 0, types::TGT_SELF(), types::WT_UNIFORM(), 1, 0, 0, 1000,
            0, vector::empty(), types::make_summon_rule(24, 2, 0)));

        // ===================== SELF-SELECT POOL (自选池白名单, content-design §5) =====================
        // 红线: 玩家创建时只能从以下技能中自选 —— 基础技/占位/职业技/种族技/敌技不在池内。
        let pool = vector[
            content::SKILL_SMOKE,              // 7 尘幕
            content::SKILL_DOT,                // 10 毒刃
            content::SKILL_FLASH,              // 23 一闪
            content::SKILL_STORM_BLADE,        // 24 暴风剑
            content::SKILL_FIRST_AID,          // 39 急救包扎
            content::SKILL_BLINDING_POWDER,    // 40 致盲粉
            content::SKILL_ROCK_BULWARK,       // 41 岩石壁垒
            content::SKILL_MAGIC_SHIELD,       // 42 魔力护盾
            content::SKILL_DRAGON_BREATH,      // 43 龙息
            content::SKILL_MANA_CLAP,          // 44 魔爆术
        ];
        let pi = 0;
        while (pi < vector::length(&pool)) {
            skill_registry::add_pool_skill(account, *vector::borrow(&pool, pi));
            pi = pi + 1;
        };

        // ===================== MONSTER AIs (1..23, 紧凑编号) =====================
        // make_monster_ai(skill_cycle, cycle_len); 每回合均匀随机抽一个技能; cycle 内重复=加权。
        ai(account, vector[content::SKILL_IDLE]);                              // 1 待机(D1 魔素岩 / D9 王座宝箱)
        ai(account, vector[content::SKILL_RUST_CLAW,                           // 2 残破机仆:锈爪/宕机(半残机仆随机卡死)
            content::SKILL_IDLE]);
        ai(account, vector[content::SKILL_VINE_BIND,                           // 3 唤魔藤蔓:缠绕为主
            content::SKILL_VINE_BIND,
            content::SKILL_RUST_CLAW]);
        ai(account, vector[content::SKILL_VINE_BIND,                           // 4 唤魔藤王:缠绕连发
            content::SKILL_VINE_BIND,
            content::SKILL_VINE_BIND,
            content::SKILL_RUST_CLAW]);
        ai(account, vector[content::SKILL_PICK_SWEEP]);                        // 5 横扫型(亡灵矿工/白骨卫士)
        ai(account, vector[content::SKILL_WRAITH_DRAIN,                        // 6 怨灵型:摄魂+恐惧(怨灵/缚灵)
            content::SKILL_WRAITH_FEAR,
            content::SKILL_WRAITH_DRAIN]);
        ai(account, vector[content::SKILL_PRIEST_LASH,                         // 7 机神祭司:鞭挞+召唤机仆
            content::SKILL_PRIEST_SUMMON,
            content::SKILL_PRIEST_LASH]);
        ai(account, vector[content::SKILL_MAGMA_SPLASH]);                      // 8 熔火傀儡:熔岩溅射
        ai(account, vector[content::SKILL_DRAGON_SPIT]);                       // 9 幼龙型:龙息(熔铁/熔岩幼龙)
        ai(account, vector[content::SKILL_DIRE_BITE]);                         // 10 深渊魔犬:撕咬
        ai(account, vector[content::SKILL_SIPHON,                              // 11 魔素吞噬者:虹吸为主
            content::SKILL_SIPHON,
            content::SKILL_RUST_CLAW]);
        ai(account, vector[content::SKILL_PARTICLE_SLASH]);                    // 12 机神哨兵/魔像:粒子斩
        ai(account, vector[content::SKILL_MARSHAL_CANNON,                      // 13 机神督军:炮/斩/泄漏/低频增援(雪球罕见但致命)
            content::SKILL_MARSHAL_CANNON,
            content::SKILL_PARTICLE_SLASH,
            content::SKILL_PARTICLE_SLASH,
            content::SKILL_MARSHAL_LEAK,
            content::SKILL_MARSHAL_REIN]);
        ai(account, vector[content::SKILL_WIGHT_CLEAVE,                        // 14 守墓骸王:斩/横扫/号令
            content::SKILL_PICK_SWEEP,
            content::SKILL_WIGHT_CALL]);
        ai(account, vector[content::SKILL_DRAGON_SPIT,                         // 15 渊炎龙:龙息/龙爪
            content::SKILL_DRAGON_CLAW,
            content::SKILL_DRAGON_SPIT]);
        ai(account, vector[content::SKILL_DRAGON_CLAW,                         // 16 渊龙长老:爪/龙裔号令/龙息
            content::SKILL_DRAGON_CALL,
            content::SKILL_DRAGON_SPIT,
            content::SKILL_DRAGON_CLAW]);
        ai(account, vector[content::SKILL_RIFT_CLAW]);                         // 17 裂痕魔:裂爪
        ai(account, vector[content::SKILL_ABYSS_BITE]);                        // 18 深渊魔:深渊撕咬(吸血)
        ai(account, vector[content::SKILL_RIFT_PRESSURE,                       // 19 裂隙支配者:威压/召唤/裂爪
            content::SKILL_RIFT_CALL,
            content::SKILL_RIFT_CLAW,
            content::SKILL_RIFT_CLAW]);
        ai(account, vector[content::SKILL_SPARK_SAW,                           // 20 机神卫兵系:锯+斩(卫兵/火花机/火花锯兵)
            content::SKILL_PARTICLE_SLASH]);
        ai(account, vector[content::SKILL_PARTICLE_SLASH,                      // 21 火力瞭望塔:斩+泄漏(抽魔压制)
            content::SKILL_MARSHAL_LEAK]);
        ai(account, vector[content::SKILL_FURNACE_LEAK,                        // 22 机神魔素炉:泄漏/虹吸/召唤卫兵
            content::SKILL_FURNACE_LEAK,
            content::SKILL_FURNACE_SIPHON,
            content::SKILL_FURNACE_SUMMON]);
        ai(account, vector[content::SKILL_EMPEROR_CANNON,                      // 23 机神皇帝:六技循环
            content::SKILL_EMPEROR_WHEEL,
            content::SKILL_EMPEROR_LEAK,
            content::SKILL_EMPEROR_SIPHON,
            content::SKILL_EMPEROR_PRESSURE,
            content::SKILL_EMPEROR_SUMMON]);

        // ===================== ENEMY TEMPLATES (1..34, 紧凑编号) =====================
        // make_enemy_template(ai_id, threat, max_hp, power, magic, speed, base_acc, rew_min, rew_max, ods)
        // ---- D1 灰烬矿坑(魔素岩系, 全待机)---- 血量按 120 回合/场清退阀倒推
        skill_registry::register_template(account, tmpl(1, 0, 35, 0, 0, 5, 0, 1, 2));        // 1 碎晶岩
        skill_registry::register_template(account, tmpl(1, 0, 90, 0, 0, 4, 0, 3, 5));        // 2 魔素岩
        skill_registry::register_template(account, tmpl(1, 0, 735, 0, 0, 3, 0, 8, 12));      // 3 大魔素岩
        skill_registry::register_template(account, tmpl(1, 0, 2600, 0, 0, 2, 0, 18, 30));    // 4 巨型魔素岩
        // ---- D2 遗弃回廊 ----
        skill_registry::register_template(account, tmpl(2, 1, 110, 10, 0, 90, 900, 2, 4));   // 5 残破机仆
        skill_registry::register_template(account, tmpl(3, 1, 180, 14, 0, 45, 900, 4, 7));   // 6 唤魔藤蔓
        skill_registry::register_template(account, tmpl(4, 2, 500, 12, 0, 50, 900, 9, 14));  // 7 唤魔藤王
        // ---- D3 沉眠圣所 ----
        skill_registry::register_template(account, tmpl(5, 1, 420, 110, 0, 60, 900, 4, 6));  // 8 亡灵矿工
        skill_registry::register_template(account, tmpl(6, 1, 320, 0, 170, 150, 900, 5, 8)); // 9 怨灵(魔攻)
        skill_registry::register_template(account, tmpl(7, 3, 1600, 0, 200, 70, 920, 14, 22));// 10 机神祭司(召唤)
        // ---- D4 熔铁深渊 ----
        skill_registry::register_template(account, tmpl(8, 2, 1400, 150, 0, 35, 900, 10, 16)); // 11 熔火傀儡(AoE)
        skill_registry::register_template(account, tmpl(9, 2, 1900, 0, 210, 110, 920, 18, 28));// 12 熔铁幼龙(全体龙息)
        skill_registry::register_template(account, tmpl(10, 1, 700, 160, 0, 170, 920, 8, 13));// 13 深渊魔犬(高速)
        skill_registry::register_template(account, tmpl(11, 3, 3000, 60, 0, 20, 900, 24, 38));// 14 魔素吞噬者(虹吸)
        // ---- D5 机神前哨(单人攻关门) ----
        skill_registry::register_template(account, tmpl(12, 1, 1100, 3400, 0, 150, 910, 6, 9)); // 15 机神哨兵
        skill_registry::register_template(account, tmpl(12, 2, 8200, 4200, 0, 50, 900, 16, 24));// 16 机神魔像
        skill_registry::register_template(account, tmpl(13, 3, 29400, 4600, 0, 120, 920, 40, 60));// 17 机神督军(弱化皇帝机体; 召唤缺口公式封顶兵源后回调攻击)
        // ---- D6 亡者回廊深处 ----
        skill_registry::register_template(account, tmpl(5, 1, 1300, 700, 0, 60, 900, 8, 12)); // 18 白骨卫士
        skill_registry::register_template(account, tmpl(6, 1, 1000, 0, 950, 160, 900, 9, 14));// 19 缚灵(魔攻)
        skill_registry::register_template(account, tmpl(14, 3, 14000, 950, 0, 80, 920, 40, 60));// 20 守墓骸王(号令)
        // ---- D7 熔渊龙巢 ----
        skill_registry::register_template(account, tmpl(9, 2, 2600, 0, 1150, 130, 910, 15, 22));// 21 熔岩幼龙
        skill_registry::register_template(account, tmpl(15, 2, 6000, 900, 1400, 90, 910, 25, 38));// 22 渊炎龙
        skill_registry::register_template(account, tmpl(16, 3, 22000, 1200, 1600, 110, 920, 80, 120));// 23 渊龙长老
        // ---- D8 虚空裂隙 ----
        skill_registry::register_template(account, tmpl(17, 1, 1500, 1400, 0, 170, 910, 18, 26));// 24 裂痕魔
        skill_registry::register_template(account, tmpl(18, 2, 4200, 1700, 0, 140, 910, 30, 45));// 25 深渊魔(吸血)
        skill_registry::register_template(account, tmpl(19, 3, 42000, 1650, 0, 100, 920, 150, 240));// 26 裂隙支配者
        // ---- D9 机神帝座(保持既有数值) ----
        skill_registry::register_template(account, tmpl(20, 2, 9000, 720, 260, 100, 900, 45, 70)); // 27 机神卫兵
        skill_registry::register_template(account, tmpl(20, 1, 6000, 820, 0, 130, 900, 30, 50)); // 28 火花机
        skill_registry::register_template(account, tmpl(21, 2, 18000, 1120, 990, 50, 900, 90, 140)); // 29 火力瞭望塔
        // 30 机神魔素炉 —— 不攻击, 抽魔+召唤; 被摧毁时 60% 召唤 机神皇帝(34)同场再战
        skill_registry::register_template(account, types::make_enemy_template(22, 2, 60000, 0, 0, 20, 0, 0, 0,
            types::make_on_death_spawn(34, 1, 600)));
        skill_registry::register_template(account, tmpl(1, 0, 50, 0, 0, 10, 0, 200, 300)); // 31 王座宝箱(待机)
        skill_registry::register_template(account, tmpl(20, 1, 11000, 950, 0, 125, 900, 60, 95)); // 32 火花锯兵
        skill_registry::register_template(account, tmpl(23, 3, 220000, 620, 480, 140, 920, 400, 600)); // 33 机神皇帝(备用机体, 王座变体)
        skill_registry::register_template(account, tmpl(23, 3, 250000, 640, 500, 150, 930, 500, 800)); // 34 机神皇帝(炉召唤)
        // 35 替身人偶(白魔法师 38 的己方假目标: 有血不行动, 吸随机火力; ai 字段仅占位)
        skill_registry::register_template(account, tmpl(1, 0, 3000, 0, 0, 30, 0, 0, 0));  // 35 替身人偶(decoy)

        // ===================== ENEMY TABLES (1..31, 紧凑编号) =====================
        // make_table_entry(template_id, weight)
        skill_registry::register_table(account, vector[te(1, 1000)]);                          // 1  D1b1 碎晶岩
        skill_registry::register_table(account, vector[te(2, 1000)]);                          // 2  D1b2 魔素岩
        skill_registry::register_table(account, vector[te(3, 1000)]);                          // 3  D1b3 大魔素岩
        skill_registry::register_table(account, vector[te(4, 1000)]);                          // 4  D1b4 巨型魔素岩
        skill_registry::register_table(account, vector[te(5, 1000)]);                          // 5  D2b1 机仆
        skill_registry::register_table(account, vector[te(6, 700), te(5, 300)]);              // 6  D2b2 藤蔓混编
        skill_registry::register_table(account, vector[te(7, 800), te(5, 200)]);              // 7  D2b3 藤王
        skill_registry::register_table(account, vector[te(8, 1000)]);                          // 8  D3b1 矿工群
        skill_registry::register_table(account, vector[te(8, 650), te(9, 350)]);              // 9  D3b2 矿工+怨灵
        skill_registry::register_table(account, vector[te(10, 850), te(9, 150)]);             // 10 D3b3 机神祭司
        skill_registry::register_table(account, vector[te(11, 600), te(13, 400)]);            // 11 D4b1 傀儡+魔犬
        skill_registry::register_table(account, vector[te(12, 700), te(11, 300)]);            // 12 D4b2 熔铁幼龙
        skill_registry::register_table(account, vector[te(14, 600), te(13, 400)]);            // 13 D4b3 吞噬者+魔犬
        skill_registry::register_table(account, vector[te(15, 1000)]);                        // 14 D5b1 机神哨兵
        skill_registry::register_table(account, vector[te(16, 700), te(15, 300)]);            // 15 D5b2 魔像+哨兵
        skill_registry::register_table(account, vector[te(17, 1000)]);                        // 16 D5b3 机神督军(基准)
        skill_registry::register_table(account, vector[te(17, 750), te(16, 180), te(15, 70)]); // 17 D5b3 混沌变体
        skill_registry::register_table(account, vector[te(18, 1000)]);                        // 18 D6b1 白骨卫士
        skill_registry::register_table(account, vector[te(18, 650), te(19, 350)]);            // 19 D6b2 卫士+缚灵
        skill_registry::register_table(account, vector[te(20, 1000)]);                        // 20 D6b3 守墓骸王
        skill_registry::register_table(account, vector[te(21, 800), te(22, 200)]);            // 21 D7b1 幼龙群
        skill_registry::register_table(account, vector[te(22, 800), te(21, 200)]);            // 22 D7b2 渊炎龙
        skill_registry::register_table(account, vector[te(23, 1000)]);                        // 23 D7b3 渊龙长老
        skill_registry::register_table(account, vector[te(24, 700), te(25, 300)]);            // 24 D8b1 裂痕魔群
        skill_registry::register_table(account, vector[te(25, 800), te(24, 200)]);            // 25 D8b2 深渊魔
        skill_registry::register_table(account, vector[te(26, 1000)]);                        // 26 D8b3 裂隙支配者
        skill_registry::register_table(account, vector[te(27, 700), te(28, 150), te(32, 150)]); // 27 D9b1 卫兵走廊
        skill_registry::register_table(account, vector[te(27, 700), te(29, 300)]);            // 28 D9b2 前厅
        skill_registry::register_table(account, vector[te(30, 600), te(27, 400)]);            // 29 D9b3 机神魔素炉
        skill_registry::register_table(account, vector[te(31, 1000)]);                        // 30 D9b4 王座宝箱
        skill_registry::register_table(account, vector[te(33, 1000)]);                        // 31 D9b4 皇帝备用机体

        // ===================== DUNGEONS D1..D10 =====================
        // make_dungeon_config(table, enemy_count, mana/turn, reward_base, entry_fee, rescue_fee, turn_interval, battles)
        skill_registry::set_dungeon(account, 1, dng(1, 2, 2, 0, 0, 10, BATTLE_TURN_CAP, 4));   // D1 灰烬矿坑(免费; mana 2 保证每回合挥镐)
        skill_registry::set_dungeon_battles(account, 1, vector[bt(1, 2), bt(2, 2), bt(3, 2), bt(4, 1)]);
        skill_registry::set_dungeon(account, 2, dng(5, 3, 3, 0, 5, 15, BATTLE_TURN_CAP, 3));   // D2 遗弃回廊
        skill_registry::set_dungeon_battles(account, 2, vector[bt(5, 2), bt(6, 2), bt(7, 1)]);
        skill_registry::set_dungeon(account, 3, dng(8, 3, 3, 0, 10, 25, BATTLE_TURN_CAP, 3));  // D3 沉眠圣所
        skill_registry::set_dungeon_battles(account, 3, vector[bt(8, 3), bt(9, 3), bt(10, 1)]);
        skill_registry::set_dungeon(account, 4, dng(11, 3, 4, 0, 15, 30, BATTLE_TURN_CAP, 3)); // D4 熔铁深渊
        skill_registry::set_dungeon_battles(account, 4, vector[bt(11, 3), bt(12, 2), bt(13, 2)]);
        skill_registry::set_dungeon(account, 5, dng(14, 3, 4, 0, 20, 40, BATTLE_TURN_CAP, 3)); // D5 机神前哨(单人攻关门)
        skill_registry::set_dungeon_battles(account, 5, vector[bt(14, 3), bt(15, 3), bt(16, 1)]);
        skill_registry::add_battle_variant(account, 5, 3, 17, 200);   // b3 混沌变体 20%
        skill_registry::set_dungeon(account, 6, dng(18, 3, 5, 0, 25, 50, BATTLE_TURN_CAP, 3)); // D6 亡者回廊深处
        skill_registry::set_dungeon_battles(account, 6, vector[bt(18, 3), bt(19, 3), bt(20, 1)]);
        skill_registry::set_dungeon(account, 7, dng(21, 3, 6, 0, 30, 60, BATTLE_TURN_CAP, 3)); // D7 熔渊龙巢
        skill_registry::set_dungeon_battles(account, 7, vector[bt(21, 3), bt(22, 2), bt(23, 1)]);
        skill_registry::set_dungeon(account, 8, dng(24, 3, 6, 0, 35, 70, BATTLE_TURN_CAP, 3)); // D8 虚空裂隙
        skill_registry::set_dungeon_battles(account, 8, vector[bt(24, 3), bt(25, 3), bt(26, 1)]);
        // D9 机神帝座 —— 4 战; b3 炉毁 60% 召皇帝, b4 变体 70% 宝箱 / 30% 皇帝备用机体
        // (组队标定 2026-09-02: 由 85/15 上调皇帝路, 防顶配 duo/trio 100% 稳过, 贴 §3.1 60~90% 上限)
        skill_registry::set_dungeon(account, 9, dng(27, 3, 7, 0, 40, 100, BATTLE_TURN_CAP, 4));
        skill_registry::set_dungeon_battles(account, 9, vector[bt(27, 4), bt(28, 4), bt(29, 3), bt(30, 1)]);
        skill_registry::add_battle_variant(account, 9, 4, 30, 700);   // 王座宝箱
        skill_registry::add_battle_variant(account, 9, 4, 31, 300);   // 皇帝备用机体
        // ===================== DROP TABLES (掉落表: difficulty → 条目, 千分比权重) =====================
        // 数值为初值(数值层可调): 权重是同一张表内的相对比例; item_type 0 = 「空手而归」。
        // 通关 / 队长全员逃离时, 每个存活者独立掷一次(item::pick_drop)。
        // 参数 = (item_types, weights, amounts) 三条等长向量。
        item::register_drop_table(account, 1,
            vector[item::ITEM_MANA_FIREWORK, 0], vector[300, 700], vector[1, 0]);  // D1 入门: 偶尔一份魔素礼花
        item::register_drop_table(account, 2,
            vector[item::ITEM_LEAD_BULLET, item::ITEM_HEALING_POTION, 0],
            vector[250, 120, 630], vector[5, 1, 0]);
        item::register_drop_table(account, 3,
            vector[item::ITEM_LEAD_BULLET, item::ITEM_HEALING_POTION, item::ITEM_SMOKE_BOMB, 0],
            vector[250, 180, 80, 490], vector[8, 1, 1, 0]);
        item::register_drop_table(account, 4,
            vector[item::ITEM_HEALING_POTION, item::ITEM_SMOKE_BOMB, item::ITEM_DRAGON_BULLET, 0],
            vector[200, 120, 60, 620], vector[1, 1, 1, 0]);
        item::register_drop_table(account, 5,
            vector[item::ITEM_DRAGON_BULLET, item::ITEM_SMOKE_BOMB, item::ITEM_SPRING_OF_LIFE, 0],
            vector[90, 120, 40, 750], vector[1, 1, 1, 0]);
        item::register_drop_table(account, 6,
            vector[item::ITEM_DRAGON_BULLET, item::ITEM_SPRING_OF_LIFE, item::ITEM_CHALLENGE_TICKET, 0],
            vector[100, 60, 40, 800], vector[1, 1, 1, 0]);
        item::register_drop_table(account, 7,
            vector[item::ITEM_SPRING_OF_LIFE, item::ITEM_CHALLENGE_TICKET, item::ITEM_PHOENIX_FEATHER, 0],
            vector[80, 60, 25, 835], vector[1, 1, 1, 0]);
        item::register_drop_table(account, 8,
            vector[item::ITEM_CHALLENGE_TICKET, item::ITEM_PHOENIX_FEATHER, item::ITEM_DICE_OF_FATE, 0],
            vector[80, 40, 15, 865], vector[1, 1, 1, 0]);
        item::register_drop_table(account, 9,
            vector[item::ITEM_PHOENIX_FEATHER, item::ITEM_DICE_OF_FATE, item::ITEM_REBIRTH_SCROLL, 0],
            vector[60, 30, 12, 898], vector[1, 1, 1, 0]);

        // D10 超级难关 —— 占位(单场宝箱怪=待机, 砍开即胜), 后续配置
        skill_registry::set_dungeon(account, 10, dng(30, 1, 5, 0, 50, 200, BATTLE_TURN_CAP, 1));

        // ===================== ITEMS (道具层: 数据驱动, decimals=18) =====================
        // 上线后新增道具: GM 调 item::register_item 一笔交易即可, 无需发布新代码。
        // register_item(account, item_type, name, group, combat_usable, effect_kind, effect_value, decimals, bound)
        item::register_item(account, item::ITEM_LEAD_BULLET, b"lead_bullet",
            item::GROUP_AMMO, false, item::EFFECT_NONE, 0, 18, false);      // 铅弹: 战斗不可用, 左轮技能自动消耗
        item::register_item(account, item::ITEM_DRAGON_BULLET, b"dragon_bullet",
            item::GROUP_AMMO, false, item::EFFECT_NONE, 0, 18, false);      // 龙击弹: 同上, 龙击弹技能自动消耗
        item::register_item(account, item::ITEM_MANA_FIREWORK, b"mana_firework",
            item::GROUP_COMBAT_CONSUMABLE, true, item::EFFECT_MANA_BOOST, 200, 18, false); // 魔素礼花: 房间魔素+200
        // ---- 战斗消耗品 (content-design §7) ----
        item::register_item(account, item::ITEM_HEALING_POTION, b"healing_potion",
            item::GROUP_COMBAT_CONSUMABLE, true, item::EFFECT_HEAL, 400, 18, false);  // 疗伤药水: 小额治疗(占行动位)
        item::register_item(account, item::ITEM_SPRING_OF_LIFE, b"spring_of_life",
            item::GROUP_COMBAT_CONSUMABLE, true, item::EFFECT_HEAL, 3000, 18, false); // 生命之泉: 大额治疗(仅掉落)
        item::register_item(account, item::ITEM_SMOKE_BOMB, b"smoke_bomb",
            item::GROUP_COMBAT_CONSUMABLE, true, item::EFFECT_SMOKE_ALL, 300, 18, false); // 烟幕弹: 全体降命中(双向大于尘幕150)
        item::register_item(account, item::ITEM_PHOENIX_FEATHER, b"phoenix_feather",
            item::GROUP_COMBAT_CONSUMABLE, true, item::EFFECT_REVIVE, 2000, 18, false); // 不死鸟之羽: 复活一名被击败的队友(仅掉落)
        // ---- 角色类(重生/重掷, 仅掉落, 关卡外) ----
        item::register_item(account, item::ITEM_REBIRTH_SCROLL, b"rebirth_scroll",
            item::GROUP_CHARACTER_META, false, item::EFFECT_NONE, 0, 18, false); // 重生卷轴: 整体重建角色
        item::register_item(account, item::ITEM_DICE_OF_FATE, b"dice_of_fate",
            item::GROUP_CHARACTER_META, false, item::EFFECT_NONE, 0, 18, false); // 命运骰子: 种族+词条全重掷(保留职业/等级/自选技)
        // ---- 入场类 ----
        item::register_item(account, item::ITEM_DAILY_TICKET, b"daily_challenge_ticket",
            item::GROUP_ENTRY, false, item::EFFECT_NONE, 0, 18, true);       // 每日挑战券: 每日免费领取, 绑定不可交易
        item::register_item(account, item::ITEM_CHALLENGE_TICKET, b"challenge_ticket",
            item::GROUP_ENTRY, false, item::EFFECT_NONE, 0, 18, false);      // 挑战券: 可交易, 无视当日入场次数限制
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
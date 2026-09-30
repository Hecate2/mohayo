/// Shared type definitions for the Mohayo game system.
module mohayo::types {
    use std::vector;

    // ---- skill kinds ----
    public fun KIND_PHYSICAL(): u8 { 1 }
    public fun KIND_MAGIC(): u8 { 2 }
    public fun KIND_SUPPORT(): u8 { 3 }
    public fun KIND_SUMMON(): u8 { 4 }
    /// 双修型伤害公式: 伤害按 (物攻 + 魔攻) 之和结算(火枪手子弹, content-design §4.5)
    public fun KIND_HYBRID(): u8 { 5 }

    // ---- targeting ----
    public fun TGT_RAND_SINGLE_ENEMY(): u8 { 1 }
    public fun TGT_RAND_MULTI_ENEMY(): u8 { 2 }
    public fun TGT_RAND_STRIKE_ENEMY(): u8 { 3 }
    public fun TGT_ALL_ENEMY(): u8 { 4 }
    public fun TGT_RAND_SINGLE_ALLY(): u8 { 5 }
    public fun TGT_RAND_MULTI_ALLY(): u8 { 6 }
    public fun TGT_ALL_ALLY(): u8 { 7 }
    public fun TGT_ROOM_ALL(): u8 { 8 }
    public fun TGT_SELF(): u8 { 9 }
    public fun TGT_MOST_WOUNDED_ALLY(): u8 { 10 }

    // ---- weight modes ----
    public fun WT_UNIFORM(): u8 { 0 }
    public fun WT_HP_DEFICIT_ALLY(): u8 { 1 }
    public fun WT_THREAT_ENEMY(): u8 { 2 }

    // ---- flags (bitmask) ----
    public fun FLAG_GUARANTEED_HIT(): u8 { 1 }
    public fun FLAG_MANA_ALL(): u8 { 2 }
    public fun FLAG_SUMMON_ALLY(): u8 { 4 }

    // ---- effect scope ----
    public fun SCOPE_SELF(): u8 { 0 }
    public fun SCOPE_TARGET(): u8 { 1 }
    public fun SCOPE_ALL_ALLY(): u8 { 2 }
    public fun SCOPE_ALL_ENEMY(): u8 { 3 }

    // ---- effect ops ----
    public fun OP_STUN(): u8 { 1 }
    public fun OP_DMG_OUT_MOD(): u8 { 2 }
    public fun OP_DMG_IN_MOD(): u8 { 3 }
    public fun OP_SHIELD(): u8 { 4 }
    public fun OP_EVADE_UP(): u8 { 5 }
    public fun OP_ACC_DOWN(): u8 { 6 }
    public fun OP_GUAR_NEXT(): u8 { 7 }
    public fun OP_DOT(): u8 { 8 }
    public fun OP_HEAL(): u8 { 9 }
    public fun OP_DISPEL(): u8 { 10 }
    public fun OP_TAUNT(): u8 { 11 }
    public fun OP_LIFESTEAL(): u8 { 12 }
    public fun OP_MANA_DELTA(): u8 { 13 }
    public fun OP_SUMMON(): u8 { 14 }
    public fun OP_MANA_DRAIN(): u8 { 15 }

    // ---- room phases ----
    public fun PHASE_LOBBY(): u8 { 0 }
    public fun PHASE_COMBAT(): u8 { 1 }
    public fun PHASE_SETTLED(): u8 { 2 }
    public fun PHASE_INTERMISSION(): u8 { 3 }

    // ---- capacities ----
    public fun MAX_MEMBERS(): u64 { 10 }
    public fun MAX_ENEMIES(): u64 { 10 }
    public fun MAX_EFFECTS(): u64 { 6 }
    public fun MAX_PLAN(): u64 { 16 }
    public fun MAX_SKILL_EFFECTS(): u64 { 4 }
    public fun MAX_STRIKES(): u64 { 8 }
    public fun MAX_DIFFICULTY(): u64 { 10 }
    public fun MAX_ROOMS(): u64 { 1000 }
    public fun MAX_PLAN_SKILLS(): u64 { 8 }
    public fun AP_CAP_BASE(): u64 { 22 }
    public fun MIN_HIT_RATE(): u64 { 50 }
    public fun TIMEOUT_HP_PCT(): u64 { 10 }

    // ---- character ----
    public fun MAX_LEVEL(): u64 { 300 }
    public fun BASE_HP(): u64 { 100 }
    public fun BASE_ATTACK(): u64 { 10 }
    public fun BASE_MAGIC(): u64 { 10 }
    public fun BASE_SPEED(): u64 { 10 }
    public fun MAX_AFFIX_MOD(): u64 { 2000 }
    public fun MAX_SKILL_PER_CHAR(): u64 { 8 }

    // ---- race IDs ----
    public fun RACE_HUMAN(): u8 { 0 }
    public fun RACE_ORC(): u8 { 1 }
    public fun RACE_GIANT(): u8 { 2 }
    public fun RACE_DWARF(): u8 { 3 }
    public fun RACE_ELF(): u8 { 4 }
    public fun RACE_DRAGONKIN(): u8 { 5 }
    public fun RACE_ANGEL(): u8 { 6 }
    public fun RACE_DEMON(): u8 { 7 }

    // ---- structs ----

    struct EffectSpec has copy, drop, store {
        op: u8,
        duration: u8,
        magnitude: u16,
        scope: u8,
        prob: u16,
    }

    struct SummonRule has copy, drop, store {
        template_id: u64,
        max_count: u8,
        enemy_headroom: u8,
    }

    struct Skill has copy, drop, store {
        id: u64,
        kind: u8,
        ap_cost: u16,
        ap_gain: u16,
        ammo_id: u16,
        ammo_cost: u16,
        mana_cost: u64,
        hp_cost: u16,
        targeting: u8,
        weight_mode: u8,
        target_count: u8,
        power: u64,
        damage_cap: u64,
        base_acc: u16,
        flags: u8,
        effects: vector<EffectSpec>,
        summon: SummonRule,
    }

    struct MonsterAI has copy, drop, store {
        skill_cycle: vector<u64>,
        cycle_len: u8,
    }

    struct OnDeathSpawn has copy, drop, store {
        template_id: u64,
        count: u8,
        prob: u16,
    }

    struct EnemyTemplate has copy, drop, store {
        ai_id: u64,
        threat: u8,
        max_hp: u64,
        power: u64,
        magic: u64,
        speed: u64,
        base_acc: u16,
        reward_min: u16,
        reward_max: u16,
        on_death_spawn: OnDeathSpawn,
    }

    struct TableEntry has copy, drop, store {
        template_id: u64,
        weight: u16,
    }

    struct VariantEntry has copy, drop, store {
        table_id: u64,
        weight: u16,
    }

    struct BattleConfig has copy, drop, store {
        table_id: u64,
        enemy_count: u64,
    }

    struct DungeonConfig has copy, drop, store {
        table_id: u64,
        enemy_count: u64,
        mana_per_turn: u64,
        reward_base: u16,
        entry_fee: u64,
        rescue_fee: u64,
        turn_interval: u64,
        battles: u8,
    }

    struct ActiveEffect has copy, drop, store {
        op: u8,
        duration: u8,
        magnitude: u16,
        source_id: u64,
    }

    struct Member has copy, drop, store {
        hp: u64,
        max_hp: u64,
        attack: u64,
        magic: u64,
        speed: u64,
        ap: u16,
        mana_discount: u16,
        ap_discount: u16,
        ap_bonus: u16,
        mana_gain_bonus: i64,
        class_id: u8,
        effects: vector<ActiveEffect>,
        plan: vector<u64>,
        plan_start: u64,
        alive: bool,
        is_summon: bool,
        /// 个人逃离(§6.2)：true = 已脱离关卡(无收益、不占活人名额、不吃救援费)
        escaped: bool,
        /// 战斗中发起逃离后的倒计时(回合)；0 = 无待处理逃离
        escape_delay: u8,
        owner: address,
        char_id: u64,
    }

    struct Enemy has copy, drop, store {
        template_id: u64,
        hp: u64,
        max_hp: u64,
        attack: u64,
        magic: u64,
        speed: u64,
        base_acc: u16,
        threat: u8,
        ai_id: u64,
        turn_counter: u8,
        effects: vector<ActiveEffect>,
        alive: bool,
    }

    struct Target has copy, drop, store {
        is_enemy: bool,
        index: u64,
    }

    // ---- character types ----

    struct ClassDef has copy, drop, store {
        base_hp_pct: i64,
        base_attack_pct: i64,
        base_magic_pct: i64,
        base_speed_pct: i64,
        skill_slots: u8,
    }

    struct RaceDef has copy, drop, store {
        hp_mod: i64,
        stat_mods: vector<i64>,
        race_skill_id: u64,
        race_skill_id2: u64,
        self_select_bonus: u8,
    }

    struct AffixTemplate has copy, drop, store {
        stat_type: u8,
        tier_weights: vector<u16>,
        tier_values: vector<u16>,
    }

    // ---- constructors ----

    public fun make_effect_spec(op: u8, duration: u8, magnitude: u16, scope: u8, prob: u16): EffectSpec {
        EffectSpec { op, duration, magnitude, scope, prob }
    }

    public fun make_summon_rule(template_id: u64, max_count: u8, enemy_headroom: u8): SummonRule {
        SummonRule { template_id, max_count, enemy_headroom }
    }

    public fun make_skill(
        id: u64, kind: u8, ap_cost: u16, ap_gain: u16,
        ammo_id: u16, ammo_cost: u16, mana_cost: u64, hp_cost: u16,
        targeting: u8, weight_mode: u8, target_count: u8,
        power: u64, damage_cap: u64, base_acc: u16, flags: u8,
        effects: vector<EffectSpec>, summon: SummonRule,
    ): Skill {
        Skill { id, kind, ap_cost, ap_gain, ammo_id, ammo_cost, mana_cost, hp_cost,
                targeting, weight_mode, target_count, power, damage_cap, base_acc, flags,
                effects, summon }
    }

    public fun make_on_death_spawn(template_id: u64, count: u8, prob: u16): OnDeathSpawn {
        OnDeathSpawn { template_id, count, prob }
    }

    public fun make_enemy_template(
        ai_id: u64, threat: u8, max_hp: u64, power: u64, magic: u64, speed: u64,
        base_acc: u16, reward_min: u16, reward_max: u16, on_death_spawn: OnDeathSpawn,
    ): EnemyTemplate {
        EnemyTemplate { ai_id, threat, max_hp, power, magic, speed, base_acc,
                        reward_min, reward_max, on_death_spawn }
    }

    public fun make_table_entry(template_id: u64, weight: u16): TableEntry {
        TableEntry { template_id, weight }
    }

    public fun make_variant_entry(table_id: u64, weight: u16): VariantEntry {
        VariantEntry { table_id, weight }
    }

    public fun make_battle_config(table_id: u64, enemy_count: u64): BattleConfig {
        BattleConfig { table_id, enemy_count }
    }

    public fun make_dungeon_config(
        table_id: u64, enemy_count: u64, mana_per_turn: u64, reward_base: u16,
        entry_fee: u64, rescue_fee: u64, turn_interval: u64, battles: u8,
    ): DungeonConfig {
        DungeonConfig { table_id, enemy_count, mana_per_turn, reward_base,
                        entry_fee, rescue_fee, turn_interval, battles }
    }

    public fun make_class_def(base_hp_pct: i64, base_attack_pct: i64, base_magic_pct: i64, base_speed_pct: i64, skill_slots: u8): ClassDef {
        ClassDef { base_hp_pct, base_attack_pct, base_magic_pct, base_speed_pct, skill_slots }
    }

    public fun make_race_def(hp_mod: i64, stat_mods: vector<i64>, race_skill_id: u64, race_skill_id2: u64, self_select_bonus: u8): RaceDef {
        RaceDef { hp_mod, stat_mods, race_skill_id, race_skill_id2, self_select_bonus }
    }

    public fun make_affix_template(stat_type: u8, tier_weights: vector<u16>, tier_values: vector<u16>): AffixTemplate {
        AffixTemplate { stat_type, tier_weights, tier_values }
    }

    public fun make_member(
        hp: u64, max_hp: u64, attack: u64, magic: u64, speed: u64,
        ap: u16, mana_discount: u16, ap_discount: u16, ap_bonus: u16,
        mana_gain_bonus: i64, class_id: u8,
        effects: vector<ActiveEffect>, plan: vector<u64>, plan_start: u64,
        alive: bool, is_summon: bool, owner: address, char_id: u64,
    ): Member {
        Member { hp, max_hp, attack, magic, speed, ap, mana_discount,
                 ap_discount, ap_bonus, mana_gain_bonus, class_id,
                 effects, plan, plan_start, alive, is_summon,
                 escaped: false, escape_delay: 0, owner, char_id }
    }

    public fun make_enemy(
        template_id: u64, hp: u64, max_hp: u64, attack: u64, magic: u64,
        speed: u64, base_acc: u16, threat: u8, ai_id: u64,
        turn_counter: u8, effects: vector<ActiveEffect>, alive: bool,
    ): Enemy {
        Enemy { template_id, hp, max_hp, attack, magic, speed, base_acc,
                threat, ai_id, turn_counter, effects, alive }
    }

    public fun make_monster_ai(skill_cycle: vector<u64>, cycle_len: u8): MonsterAI {
        MonsterAI { skill_cycle, cycle_len }
    }

    public fun make_active_effect(op: u8, duration: u8, magnitude: u16, source_id: u64): ActiveEffect {
        ActiveEffect { op, duration, magnitude, source_id }
    }

    public fun make_target(is_enemy: bool, index: u64): Target {
        Target { is_enemy, index }
    }

    // ---- DungeonConfig accessors ----
    public fun dungeon_table_id(d: &DungeonConfig): u64 { d.table_id }
    public fun dungeon_enemy_count(d: &DungeonConfig): u64 { d.enemy_count }
    public fun dungeon_mana_per_turn(d: &DungeonConfig): u64 { d.mana_per_turn }
    public fun dungeon_reward_base(d: &DungeonConfig): u16 { d.reward_base }
    public fun dungeon_entry_fee(d: &DungeonConfig): u64 { d.entry_fee }
    public fun dungeon_rescue_fee(d: &DungeonConfig): u64 { d.rescue_fee }
    public fun dungeon_turn_interval(d: &DungeonConfig): u64 { d.turn_interval }
    public fun dungeon_battles(d: &DungeonConfig): u8 { d.battles }

    // ---- BattleConfig accessors ----
    public fun battle_config_table_id(b: &BattleConfig): u64 { b.table_id }
    public fun battle_config_enemy_count(b: &BattleConfig): u64 { b.enemy_count }

    // ---- VariantEntry accessors ----
    public fun variant_table_id(v: &VariantEntry): u64 { v.table_id }
    public fun variant_weight(v: &VariantEntry): u16 { v.weight }

    // ---- TableEntry accessors ----
    public fun table_entry_template_id(e: &TableEntry): u64 { e.template_id }
    public fun table_entry_weight(e: &TableEntry): u16 { e.weight }

    // ---- accessors ----

    public fun skill_id(s: &Skill): u64 { s.id }
    public fun skill_kind(s: &Skill): u8 { s.kind }
    public fun skill_power(s: &Skill): u64 { s.power }
    public fun skill_damage_cap(s: &Skill): u64 { s.damage_cap }
    public fun skill_base_acc(s: &Skill): u16 { s.base_acc }
    public fun skill_targeting(s: &Skill): u8 { s.targeting }
    public fun skill_flags(s: &Skill): u8 { s.flags }

    public fun skill_ammo_id(s: &Skill): u16 { s.ammo_id }
    public fun skill_ammo_cost(s: &Skill): u16 { s.ammo_cost }    public fun skill_mana_cost(s: &Skill): u64 { s.mana_cost }
    public fun skill_ap_cost(s: &Skill): u16 { s.ap_cost }
    public fun skill_ap_gain(s: &Skill): u16 { s.ap_gain }
    public fun skill_hp_cost(s: &Skill): u16 { s.hp_cost }
    public fun skill_target_count(s: &Skill): u8 { s.target_count }
    public fun skill_weight_mode(s: &Skill): u8 { s.weight_mode }
    public fun skill_effects(s: &Skill): &vector<EffectSpec> { &s.effects }
    public fun skill_summon(s: &Skill): &SummonRule { &s.summon }

    public fun effect_op(e: &EffectSpec): u8 { e.op }
    public fun effect_duration(e: &EffectSpec): u8 { e.duration }
    public fun effect_magnitude(e: &EffectSpec): u16 { e.magnitude }
    public fun effect_scope(e: &EffectSpec): u8 { e.scope }
    public fun effect_prob(e: &EffectSpec): u16 { e.prob }

    public fun summon_rule_template_id(s: &SummonRule): u64 { s.template_id }
    public fun summon_rule_max_count(s: &SummonRule): u8 { s.max_count }
    public fun summon_rule_enemy_headroom(s: &SummonRule): u8 { s.enemy_headroom }

    public fun template_max_hp(t: &EnemyTemplate): u64 { t.max_hp }
    public fun template_power(t: &EnemyTemplate): u64 { t.power }
    public fun template_magic(t: &EnemyTemplate): u64 { t.magic }
    public fun template_speed(t: &EnemyTemplate): u64 { t.speed }
    public fun template_base_acc(t: &EnemyTemplate): u16 { t.base_acc }
    public fun template_threat(t: &EnemyTemplate): u8 { t.threat }
    public fun template_ai_id(t: &EnemyTemplate): u64 { t.ai_id }
    public fun template_reward_min(t: &EnemyTemplate): u16 { t.reward_min }
    public fun template_reward_max(t: &EnemyTemplate): u16 { t.reward_max }
    public fun template_on_death_spawn(t: &EnemyTemplate): &OnDeathSpawn { &t.on_death_spawn }

    public fun ai_skill_cycle(a: &MonsterAI): &vector<u64> { &a.skill_cycle }
    public fun ai_cycle_len(a: &MonsterAI): u8 { a.cycle_len }

    public fun on_death_spawn_template_id(o: &OnDeathSpawn): u64 { o.template_id }
    public fun on_death_spawn_count(o: &OnDeathSpawn): u8 { o.count }
    public fun on_death_spawn_prob(o: &OnDeathSpawn): u16 { o.prob }

    public fun active_effect_op(e: &ActiveEffect): u8 { e.op }
    public fun active_effect_duration(e: &ActiveEffect): u8 { e.duration }
    public fun active_effect_magnitude(e: &ActiveEffect): u16 { e.magnitude }

    public fun target_is_enemy(t: &Target): bool { t.is_enemy }
    public fun target_index(t: &Target): u64 { t.index }

    // ---- class/race/affix accessors ----

    public fun class_def_hp_pct(c: &ClassDef): i64 { c.base_hp_pct }
    public fun class_def_attack_pct(c: &ClassDef): i64 { c.base_attack_pct }
    public fun class_def_magic_pct(c: &ClassDef): i64 { c.base_magic_pct }
    public fun class_def_speed_pct(c: &ClassDef): i64 { c.base_speed_pct }
    public fun class_def_skill_slots(c: &ClassDef): u8 { c.skill_slots }

    public fun race_def_hp_mod(r: &RaceDef): i64 { r.hp_mod }
    public fun race_def_stat_mods(r: &RaceDef): &vector<i64> { &r.stat_mods }
    public fun race_def_skill_id(r: &RaceDef): u64 { r.race_skill_id }
    public fun race_def_skill_id2(r: &RaceDef): u64 { r.race_skill_id2 }
    public fun race_def_self_select_bonus(r: &RaceDef): u8 { r.self_select_bonus }

    public fun affix_stat_type(a: &AffixTemplate): u8 { a.stat_type }
    public fun affix_tier_weights(a: &AffixTemplate): &vector<u16> { &a.tier_weights }
    public fun affix_tier_values(a: &AffixTemplate): &vector<u16> { &a.tier_values }

    // ---- ActiveEffect mutators ----
    public fun ae_set_duration(e: &mut ActiveEffect, v: u8) { e.duration = v; }
    public fun ae_set_magnitude(e: &mut ActiveEffect, v: u16) { e.magnitude = v; }

    // ---- Member accessors ----
    public fun member_hp(m: &Member): u64 { m.hp }
    public fun member_max_hp(m: &Member): u64 { m.max_hp }
    public fun member_attack(m: &Member): u64 { m.attack }
    public fun member_magic(m: &Member): u64 { m.magic }
    public fun member_speed(m: &Member): u64 { m.speed }
    public fun member_ap(m: &Member): u16 { m.ap }
    public fun member_alive(m: &Member): bool { m.alive }
    public fun member_is_summon(m: &Member): bool { m.is_summon }
    public fun member_escaped(m: &Member): bool { m.escaped }
    public fun member_escape_delay(m: &Member): u8 { m.escape_delay }
    public fun member_owner(m: &Member): address { m.owner }
    public fun member_char_id(m: &Member): u64 { m.char_id }
    public fun member_effects(m: &Member): &vector<ActiveEffect> { &m.effects }
    public fun member_plan(m: &Member): &vector<u64> { &m.plan }
    public fun member_plan_start(m: &Member): u64 { m.plan_start }
    public fun member_mana_gain_bonus(m: &Member): i64 { m.mana_gain_bonus }
    public fun member_mana_discount(m: &Member): u16 { m.mana_discount }
    public fun member_ap_discount(m: &Member): u16 { m.ap_discount }
    public fun member_ap_bonus(m: &Member): u16 { m.ap_bonus }
    public fun member_class_id(m: &Member): u8 { m.class_id }

    // ---- Member mutators ----
    public fun member_set_hp(m: &mut Member, v: u64) { m.hp = v; }
    public fun member_set_alive(m: &mut Member, v: bool) { m.alive = v; }
    public fun member_set_ap(m: &mut Member, v: u16) { m.ap = v; }
    public fun member_set_plan(m: &mut Member, v: vector<u64>) { m.plan = v; }
    public fun member_set_plan_start(m: &mut Member, v: u64) { m.plan_start = v; }
    public fun member_set_escaped(m: &mut Member, v: bool) { m.escaped = v; }
    public fun member_set_escape_delay(m: &mut Member, v: u8) { m.escape_delay = v; }

    // ---- Member effect mutation (takes &mut Member) ----
    public fun member_tick_effects(m: &mut Member) { tick_effects(&mut m.effects); }
    public fun member_has_effect(m: &Member, op: u8): bool { has_effect(&m.effects, op) }
    public fun member_effect_count(m: &Member): u64 { vector::length(&m.effects) }
    public fun member_get_effect(m: &Member, i: u64): (u8, u8, u16) {
        let e = vector::borrow(&m.effects, i);
        (e.op, e.duration, e.magnitude)
    }
    public fun member_sum_effect_mag(m: &Member, op: u8): u16 { sum_effect_mag_with_op(&m.effects, op) }
    public fun member_add_effect(m: &mut Member, ae: ActiveEffect) {
        add_effect(&mut m.effects, ae);
    }
    public fun member_dispel(m: &mut Member) { dispel_effects(&mut m.effects); }
    public fun member_absorb_shield(m: &mut Member, dmg: u64): u64 { absorb_shield(&mut m.effects, dmg) }
    public fun member_clear_effects(m: &mut Member) { m.effects = vector::empty(); }

    // ---- Enemy accessors ----
    public fun enemy_template_id(e: &Enemy): u64 { e.template_id }
    public fun enemy_hp(e: &Enemy): u64 { e.hp }
    public fun enemy_max_hp(e: &Enemy): u64 { e.max_hp }
    public fun enemy_attack(e: &Enemy): u64 { e.attack }
    public fun enemy_magic(e: &Enemy): u64 { e.magic }
    public fun enemy_speed(e: &Enemy): u64 { e.speed }
    public fun enemy_base_acc(e: &Enemy): u16 { e.base_acc }
    public fun enemy_threat(e: &Enemy): u8 { e.threat }
    public fun enemy_ai_id(e: &Enemy): u64 { e.ai_id }
    public fun enemy_turn_counter(e: &Enemy): u8 { e.turn_counter }
    public fun enemy_alive(e: &Enemy): bool { e.alive }
    public fun enemy_effects(e: &Enemy): &vector<ActiveEffect> { &e.effects }

    // ---- Enemy mutators ----
    public fun enemy_set_hp(e: &mut Enemy, v: u64) { e.hp = v; }
    public fun enemy_set_alive(e: &mut Enemy, v: bool) { e.alive = v; }
    public fun enemy_set_turn_counter(e: &mut Enemy, v: u8) { e.turn_counter = v; }

    // ---- Enemy effect mutation ----
    public fun enemy_tick_effects(e: &mut Enemy) { tick_effects(&mut e.effects); }
    public fun enemy_has_effect(e: &Enemy, op: u8): bool { has_effect(&e.effects, op) }
    public fun enemy_effect_count(e: &Enemy): u64 { vector::length(&e.effects) }
    public fun enemy_get_effect(e: &Enemy, i: u64): (u8, u8, u16) {
        let eff = vector::borrow(&e.effects, i);
        (eff.op, eff.duration, eff.magnitude)
    }
    public fun enemy_sum_effect_mag(e: &Enemy, op: u8): u16 { sum_effect_mag_with_op(&e.effects, op) }
    public fun enemy_add_effect(e: &mut Enemy, ae: ActiveEffect) {
        add_effect(&mut e.effects, ae);
    }
    public fun enemy_dispel(e: &mut Enemy) { dispel_effects(&mut e.effects); }
    public fun enemy_absorb_shield(e: &mut Enemy, dmg: u64): u64 { absorb_shield(&mut e.effects, dmg) }
    public fun enemy_clear_effects(e: &mut Enemy) { e.effects = vector::empty(); }

    // ---- ActiveEffect direct accessors (short names) ----
    public fun ae_op(e: &ActiveEffect): u8 { e.op }
    public fun ae_duration(e: &ActiveEffect): u8 { e.duration }
    public fun ae_magnitude(e: &ActiveEffect): u16 { e.magnitude }
    public fun ae_source_id(e: &ActiveEffect): u64 { e.source_id }

    // ---- internal effect helpers ----

    fun tick_effects(effects: &mut vector<ActiveEffect>) {
        let i = vector::length(effects);
        while (i > 0) {
            let idx = i - 1;
            let e = vector::borrow_mut(effects, idx);
            if (e.duration > 0) {
                e.duration = e.duration - 1;
                if (e.duration == 0) {
                    vector::remove(effects, idx);
                };
            };
            i = i - 1;
        };
    }

    fun has_effect(effects: &vector<ActiveEffect>, op: u8): bool {
        let len = vector::length(effects);
        let i = 0;
        while (i < len) {
            let e = vector::borrow(effects, i);
            if (e.op == op) return true;
            i = i + 1;
        };
        false
    }

    fun sum_effect_mag_with_op(effects: &vector<ActiveEffect>, op: u8): u16 {
        let sum: u16 = 0;
        let len = vector::length(effects);
        let i = 0;
        while (i < len) {
            let e = vector::borrow(effects, i);
            if (e.op == op) { sum = sum + e.magnitude; };
            i = i + 1;
        };
        sum
    }

    fun add_effect(effects: &mut vector<ActiveEffect>, ae: ActiveEffect) {
        let len = vector::length(effects);
        let i = 0;
        while (i < len) {
            let e = vector::borrow_mut(effects, i);
            if (e.op == ae.op && ae.op != 4 && ae.op != 8) { // SHIELD stacks separately; DOT refreshes only
                e.duration = ae.duration;
                e.magnitude = e.magnitude + ae.magnitude;
                return;
            };
            if (e.op == ae.op && ae.op == 8) { // DOT: 同源反复施加只刷新 duration, 不累加(防跳伤线性堆叠)
                e.duration = ae.duration;
                return;
            };
            i = i + 1;
        };
        if (vector::length(effects) < 6) { // MAX_EFFECTS
            vector::push_back(effects, ae);
        };
    }

    fun dispel_effects(effects: &mut vector<ActiveEffect>) {
        let i = vector::length(effects);
        while (i > 0) {
            let idx = i - 1;
            let e = vector::borrow(effects, idx);
            let op = e.op;
            if (op == 1 || op == 2 || op == 3 || op == 5 || op == 6 || op == 8 || op == 11) {
                vector::remove(effects, idx);
            };
            i = i - 1;
        };
    }

    fun absorb_shield(effects: &mut vector<ActiveEffect>, mut_dmg: u64): u64 {
        let mut_remaining = mut_dmg;
        let len = vector::length(effects);
        let i = len;
        while (i > 0) {
            let idx = i - 1;
            let e = vector::borrow_mut(effects, idx);
            if (e.op == 4 && e.magnitude > 0) { // OP_SHIELD
                if ((e.magnitude as u64) <= mut_remaining) {
                    mut_remaining = mut_remaining - (e.magnitude as u64);
                    e.magnitude = 0;
                } else {
                    e.magnitude = e.magnitude - (mut_remaining as u16);
                    mut_remaining = 0;
                };
                if (mut_remaining == 0) break;
            };
            i = i - 1;
        };
        mut_remaining
    }
}

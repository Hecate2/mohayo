/// 技能与内容的 key 常量表。
/// ============================================================
/// 技能 KEY 分区表（2026-09-02 定案，组间大空隙、组内留位）：
///   100–199  基础/通用技(非池/非职业/非种族)
///   200–299  守卫职业技      300–399  剑士职业技
///   400–499  黑魔职业技      500–599  白魔职业技
///   600–699  火枪职业技
///   700–799  种族技          800–999  自选池技(白名单, content-design §5)
///  1000–1099 通用敌技(跨关复用)   1100–1199 D2-D4 敌技
///  1200–1299 D5 敌技  1300–1399 D6  1400–1499 D7  1500–1599 D8
///  1600–1699 D9 敌技  1700–1799 D10(预留)
/// 组内步长 5~10, 新技能在所属区间内取未用 key 注册(skill.id 显式)。
/// ============================================================
module mohayo::content {
    // ---- 100–199 基础/通用技 ----
    public const SKILL_ATTACK: u64 = 100;        // 攻击
    public const SKILL_MAGIC_BOLT: u64 = 110;    // 魔法弹
    public const SKILL_HEAL: u64 = 120;          // 治疗
    public const SKILL_STRIKE_3: u64 = 130;      // 三段斩
    public const SKILL_SHIELD: u64 = 140;        // 盾(通用)
    public const SKILL_STUN: u64 = 150;          // 眩晕打击
    public const SKILL_MANA_BURST: u64 = 160;    // 魔素爆发
    public const SKILL_TAUNT: u64 = 170;         // 挑衅
    public const SKILL_SUMMON: u64 = 180;        // 召唤占位
    public const SKILL_IDLE: u64 = 190;          // 待机
    // ---- 200–299 守卫 ----
    public const SKILL_SHIELD_BASH: u64 = 210;   // 盾击(晕+嘲讽)
    public const SKILL_SHIELD_WALL: u64 = 220;   // 盾墙
    public const SKILL_GUARD_EVADE: u64 = 230;   // 回避
    // ---- 300–399 剑士 ----
    public const SKILL_RAPID_STRIKE: u64 = 310;  // 快速剑(三连)
    public const SKILL_IRON_CLEAVE: u64 = 320;   // 斩铁剑
    public const SKILL_MAGIC_SWORD: u64 = 330;   // 魔法剑
    // ---- 400–499 黑魔法师 ----
    public const SKILL_SACRIFICE: u64 = 410;     // 献祭(烧血多段+每命中产魔)
    public const SKILL_BLACK_VEIL: u64 = 420;    // 黑幕
    public const SKILL_BURST_MAGIC: u64 = 430;   // 爆裂魔法(全魔素)
    // ---- 500–599 白魔法师 ----
    public const SKILL_LIGHT_ORB: u64 = 510;     // 光弹
    public const SKILL_HOLY_SPRING: u64 = 520;   // 圣泉(群回+回蓝)
    public const SKILL_DECOY_DOLL: u64 = 530;    // 替身人偶(ally decoy)
    // ---- 600–699 火枪手 ----
    public const SKILL_EAGLE_EYE: u64 = 610;     // 鹰眼(GUAR_NEXT)
    public const SKILL_REVOLVER_RAIN: u64 = 620; // 左轮弹雨
    public const SKILL_DRAGON_BULLET: u64 = 630; // 龙击弹
    // ---- 700–799 种族技 ----
    public const SKILL_BERSERK: u64 = 710;       // 狂暴(兽人)
    public const SKILL_STONE_BODY: u64 = 720;    // 磐石(哥布林/巨人)
    public const SKILL_SPIRIT_RETURN: u64 = 730; // 烈酒(哥布林)
    public const SKILL_STORM: u64 = 740;         // 暴风(史莱姆)
    public const SKILL_DRAGON_SCALE: u64 = 750;  // 龙鳞(龙人)
    public const SKILL_HOLY_LIGHT: u64 = 760;    // 圣愈之光(天使)
    public const SKILL_ANGEL_JUDGMENT: u64 = 770;// 雷击(天使)
    public const SKILL_SOUL_DRAIN: u64 = 780;    // 汲魂(恶魔)
    public const SKILL_ABYSS_WHISPER: u64 = 790; // 低语(恶魔)
    // ---- 800–999 自选池(白名单) ----
    public const SKILL_SMOKE: u64 = 810;         // 尘幕
    public const SKILL_DOT: u64 = 820;           // 毒刃
    public const SKILL_FLASH: u64 = 830;         // 一闪
    public const SKILL_STORM_BLADE: u64 = 840;   // 暴风剑
    public const SKILL_FIRST_AID: u64 = 850;     // 急救包扎
    public const SKILL_BLINDING_POWDER: u64 = 860; // 致盲粉
    public const SKILL_ROCK_BULWARK: u64 = 870;  // 岩石壁垒
    public const SKILL_MAGIC_SHIELD: u64 = 880;  // 魔力护盾
    public const SKILL_DRAGON_BREATH: u64 = 890; // 龙息
    public const SKILL_MANA_CLAP: u64 = 900;     // 魔爆术
    // ---- 1000–1099 通用敌技(跨关复用) ----
    public const SKILL_PARTICLE_SLASH: u64 = 1010; // 粒子斩
    public const SKILL_SPARK_SAW: u64 = 1015;      // 火花锯
    public const SKILL_MARSHAL_LEAK: u64 = 1020;   // 机神泄漏(抽魔, D5/D9)
    // ---- 1100–1199 D2-D4 敌技 ----
    public const SKILL_RUST_CLAW: u64 = 1110;      // 残破机仆·锈爪
    public const SKILL_VINE_BIND: u64 = 1115;      // 唤魔藤蔓·缠绕
    public const SKILL_PICK_SWEEP: u64 = 1120;     // 亡灵矿工·矿镐横扫
    public const SKILL_WRAITH_DRAIN: u64 = 1125;   // 怨灵·摄魂
    public const SKILL_WRAITH_FEAR: u64 = 1130;    // 怨灵·恐惧尖啸
    public const SKILL_PRIEST_LASH: u64 = 1135;    // 机神祭司·圣光鞭挞
    public const SKILL_PRIEST_SUMMON: u64 = 1140;  // 机神祭司·召唤机仆
    public const SKILL_MAGMA_SPLASH: u64 = 1145;   // 熔火傀儡·熔岩溅射
    public const SKILL_DRAGON_SPIT: u64 = 1150;    // 幼龙·龙息(全体)
    public const SKILL_DIRE_BITE: u64 = 1155;      // 深渊魔犬·撕咬
    public const SKILL_SIPHON: u64 = 1160;         // 魔素吞噬者·虹吸
    // ---- 1200–1299 D5 机神前哨 ----
    public const SKILL_MARSHAL_CANNON: u64 = 1210; // 机神督军·督军炮
    public const SKILL_MARSHAL_REIN: u64 = 1215;   // 机神督军·增援
    // ---- 1300–1399 D6 亡者回廊深处 ----
    public const SKILL_WIGHT_CLEAVE: u64 = 1310;   // 守墓骸王·骸王斩
    public const SKILL_WIGHT_CALL: u64 = 1315;     // 守墓骸王·号令
    // ---- 1400–1499 D7 熔渊龙巢 ----
    public const SKILL_DRAGON_CLAW: u64 = 1410;    // 渊龙·龙爪
    public const SKILL_DRAGON_CALL: u64 = 1415;    // 渊龙长老·龙裔号令
    // ---- 1500–1599 D8 虚空裂隙 ----
    public const SKILL_RIFT_CLAW: u64 = 1510;      // 裂痕魔·裂爪
    public const SKILL_ABYSS_BITE: u64 = 1515;     // 深渊魔·深渊撕咬
    public const SKILL_RIFT_PRESSURE: u64 = 1520;  // 裂隙支配者·威压
    public const SKILL_RIFT_CALL: u64 = 1525;      // 裂隙支配者·召唤
    // ---- 1600–1699 D9 机神帝座 ----
    public const SKILL_FURNACE_LEAK: u64 = 1610;   // 机神魔素炉·泄漏
    public const SKILL_FURNACE_SIPHON: u64 = 1615; // 机神魔素炉·虹吸
    public const SKILL_FURNACE_SUMMON: u64 = 1620; // 机神魔素炉·召唤卫兵
    public const SKILL_EMPEROR_CANNON: u64 = 1630; // 机神皇帝·火花炮
    public const SKILL_EMPEROR_WHEEL: u64 = 1635;  // 机神皇帝·幻光轮
    public const SKILL_EMPEROR_LEAK: u64 = 1640;   // 机神皇帝·泄漏
    public const SKILL_EMPEROR_SIPHON: u64 = 1645; // 机神皇帝·虹吸
    public const SKILL_EMPEROR_PRESSURE: u64 = 1650; // 机神皇帝·威压
    public const SKILL_EMPEROR_SUMMON: u64 = 1655; // 机神皇帝·召唤卫兵
}

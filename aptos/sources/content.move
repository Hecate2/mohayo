module mohayo::content {
    use aptos_std::table::{Self, Table};
    use std::signer;

    const E_ALREADY: u64 = 3;

    public const SKILL_ATTACK: u64 = 1;
    public const SKILL_MAGIC_BOLT: u64 = 2;
    public const SKILL_HEAL: u64 = 3;
    public const SKILL_STRIKE_3: u64 = 4;
    public const SKILL_SHIELD: u64 = 5;
    public const SKILL_STUN: u64 = 6;
    public const SKILL_SMOKE: u64 = 7;
    public const SKILL_EAGLE_EYE: u64 = 8;
    public const SKILL_MANA_BURST: u64 = 9;
    public const SKILL_DOT: u64 = 10;
    public const SKILL_TAUNT: u64 = 11;
    public const SKILL_BERSERK: u64 = 12;
    public const SKILL_STONE_BODY: u64 = 13;
    public const SKILL_SPIRIT_RETURN: u64 = 14;
    public const SKILL_STORM: u64 = 15;
    public const SKILL_DRAGON_SCALE: u64 = 16;
    public const SKILL_HOLY_LIGHT: u64 = 17;
    public const SKILL_ANGEL_JUDGMENT: u64 = 18;
    public const SKILL_SOUL_DRAIN: u64 = 19;
    public const SKILL_ABYSS_WHISPER: u64 = 20;
    public const SKILL_SUMMON: u64 = 21;
    public const SKILL_IDLE: u64 = 22;
    public const SKILL_FLASH: u64 = 23;
    public const SKILL_STORM_BLADE: u64 = 24;
    public const SKILL_MAGIC_SWORD: u64 = 25;
    public const SKILL_REVOLVER_RAIN: u64 = 26;
    public const SKILL_DRAGON_BULLET: u64 = 27;
    public const SKILL_BURST_MAGIC: u64 = 28;
    public const SKILL_RAPID_STRIKE: u64 = 29;
    public const SKILL_IRON_CLEAVE: u64 = 30;
    public const SKILL_SHIELD_BASH: u64 = 31;
    public const SKILL_SHIELD_WALL: u64 = 32;
    public const SKILL_GUARD_EVADE: u64 = 33;
    public const SKILL_SACRIFICE: u64 = 34;
    public const SKILL_BLACK_VEIL: u64 = 35;
    public const SKILL_LIGHT_ORB: u64 = 36;
    public const SKILL_HOLY_SPRING: u64 = 37;
    public const SKILL_DECOY_DOLL: u64 = 38;
    public const SKILL_FIRST_AID: u64 = 39;
    public const SKILL_BLINDING_POWDER: u64 = 40;
    public const SKILL_ROCK_BULWARK: u64 = 41;
    public const SKILL_MAGIC_SHIELD: u64 = 42;
    public const SKILL_DRAGON_BREATH: u64 = 43;
    public const SKILL_MANA_CLAP: u64 = 44;
    public const SKILL_SPARK_SAW: u64 = 45;
    public const SKILL_PARTICLE_SLASH: u64 = 46;
    public const SKILL_MARSHAL_LEAK: u64 = 47;
    public const SKILL_FURNACE_LEAK: u64 = 48;
    public const SKILL_FURNACE_SIPHON: u64 = 49;
    public const SKILL_FURNACE_SUMMON: u64 = 50;
    public const SKILL_EMPEROR_CANNON: u64 = 51;
    public const SKILL_EMPEROR_WHEEL: u64 = 52;
    public const SKILL_EMPEROR_LEAK: u64 = 53;
    public const SKILL_EMPEROR_SIPHON: u64 = 54;
    public const SKILL_EMPEROR_PRESSURE: u64 = 55;
    public const SKILL_EMPEROR_SUMMON: u64 = 56;
    // ---- enemy skills 57+ (D2-D8 世界观怪物) ----
    public const SKILL_RUST_CLAW: u64 = 57;     // 残破机仆·锈爪(单体物理)
    public const SKILL_VINE_BIND: u64 = 58;     // 唤魔藤蔓·缠绕(单体物理+概率眩晕)
    public const SKILL_PICK_SWEEP: u64 = 59;    // 亡灵矿工·矿镐横扫(2目标物理)
    public const SKILL_WRAITH_DRAIN: u64 = 60;  // 怨灵·摄魂(单体魔法)
    public const SKILL_WRAITH_FEAR: u64 = 61;   // 怨灵·恐惧尖啸(单体降命中)
    public const SKILL_PRIEST_LASH: u64 = 62;   // 机神祭司·圣光鞭挞(单体魔法)
    public const SKILL_PRIEST_SUMMON: u64 = 63; // 机神祭司·召唤机仆
    public const SKILL_MAGMA_SPLASH: u64 = 64;  // 熔火傀儡·熔岩溅射(3目标物理)
    public const SKILL_DRAGON_SPIT: u64 = 65;   // 熔铁幼龙·龙息(全体魔法)
    public const SKILL_DIRE_BITE: u64 = 66;     // 深渊魔犬·撕咬(双段单体)
    public const SKILL_SIPHON: u64 = 67;        // 魔素吞噬者·魔素虹吸(抽房间池)
    // ---- enemy skills 68..77 (D5-D8 世界观怪物) ----
    public const SKILL_MARSHAL_CANNON: u64 = 68; // 机神督军·督军炮(收敛重炮, 单体物理)
    public const SKILL_MARSHAL_REIN: u64 = 69;   // 机神督军·增援(召唤机神哨兵×1)
    public const SKILL_WIGHT_CLEAVE: u64 = 70;   // 守墓骸王·骸王斩(单体物理)
    public const SKILL_WIGHT_CALL: u64 = 71;     // 守墓骸王·号令(召唤白骨卫士×2)
    public const SKILL_DRAGON_CLAW: u64 = 72;    // 渊龙·龙爪(单体物理)
    public const SKILL_DRAGON_CALL: u64 = 73;    // 渊龙长老·龙裔号令(召唤熔岩幼龙×2)
    public const SKILL_RIFT_CLAW: u64 = 74;      // 裂痕魔·裂爪(单体物理)
    public const SKILL_ABYSS_BITE: u64 = 75;     // 深渊魔·深渊撕咬(单体物理+吸血)
    public const SKILL_RIFT_PRESSURE: u64 = 76;  // 裂隙支配者·裂隙威压(全体玩家降命中)
    public const SKILL_RIFT_CALL: u64 = 77;      // 裂隙支配者·召唤裂痕魔×2

    public const DUNGEON_D9: u64 = 9;
    public const D9_BATTLE_1: u64 = 71;
    public const D9_BATTLE_2: u64 = 72;
    public const D9_BATTLE_3: u64 = 73;
    public const D9_CHEST_TABLE: u64 = 75;
    public const D9_EMPEROR_TABLE: u64 = 74;

    struct ContentState has key {
        installed: bool,
        skills: Table<u64, bool>,
        dungeons: Table<u64, Dungeon>,
    }

    struct Dungeon has copy, drop, store {
        difficulty: u8,
        battles: u8,
        mana_per_turn: u64,
        entry_fee: u64,
        rescue_fee: u64,
        turn_interval: u64,
        first_table: u64,
        final_variant_chest_weight: u64,
        final_variant_emperor_weight: u64,
    }

    fun init_module(account: &signer) {
        move_to(account, ContentState { installed: false, skills: table::new(), dungeons: table::new() });
    }

    public entry fun install_all(account: &signer) acquires ContentState {
        let state = borrow_global_mut<ContentState>(signer::address_of(account));
        assert!(!state.installed, E_ALREADY);
        let skill_id = 1;
        while (skill_id <= SKILL_EMPEROR_SUMMON) {
            table::add(&mut state.skills, skill_id, true);
            skill_id = skill_id + 1;
        };
        let difficulty = 1;
        while (difficulty <= 8) {
            table::add(&mut state.dungeons, difficulty, Dungeon {
                difficulty: difficulty as u8,
                battles: 1,
                mana_per_turn: difficulty,
                entry_fee: if (difficulty == 1) { 0 } else { difficulty * 5 },
                rescue_fee: difficulty * 10,
                turn_interval: 5,
                first_table: difficulty,
                final_variant_chest_weight: 0,
                final_variant_emperor_weight: 0,
            });
            difficulty = difficulty + 1;
        };
        table::add(&mut state.dungeons, 9, Dungeon {
            difficulty: 9, battles: 4, mana_per_turn: 6, entry_fee: 40, rescue_fee: 80,
            turn_interval: 5, first_table: D9_BATTLE_1,
            final_variant_chest_weight: 850, final_variant_emperor_weight: 150,
        });
        table::add(&mut state.dungeons, 10, Dungeon {
            difficulty: 10, battles: 1, mana_per_turn: 4, entry_fee: 10, rescue_fee: 20,
            turn_interval: 5, first_table: 101,
            final_variant_chest_weight: 0, final_variant_emperor_weight: 0,
        });
        state.installed = true;
    }

    #[view]
    public fun installed(address: address): bool acquires ContentState {
        borrow_global<ContentState>(address).installed
    }

    #[view]
    public fun skill_exists(address: address, skill_id: u64): bool acquires ContentState {
        table::contains(&borrow_global<ContentState>(address).skills, skill_id)
    }

    #[view]
    public fun dungeon(address: address, difficulty: u64): (u8, u8, u64, u64, u64, u64, u64, u64) acquires ContentState {
        let d = table::borrow(&borrow_global<ContentState>(address).dungeons, difficulty);
        (d.difficulty, d.battles, d.mana_per_turn, d.entry_fee, d.rescue_fee, d.turn_interval, d.final_variant_chest_weight, d.final_variant_emperor_weight)
    }
}

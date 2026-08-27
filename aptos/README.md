# Mohayo — Aptos Move Implementation

## Architecture

### Module Layout
- **`rng.move`** — Deterministic PRNG stream (xorshift64). Seeded once from Aptos protocol randomness API; all in-game rolls derive from this stream for reproducibility.
- **`engine.move`** — Complete combat engine: room lifecycle, skill resolution, ActiveEffect system, enemy AI, multi-battle dungeons, victory/defeat, reward distribution.
- **`content.move`** — Skill ID constants, dungeon configs, content registry.
- **`tests.move`** — Comprehensive test suite (13 tests).

### Key Design Decisions

1. **Two-resource pattern**: `Registry` (static data: skills, AIs, templates, tables) and `RoomStore` (mutable rooms) are separate resources at `@mohayo`. This allows borrowing both simultaneously without Move borrow checker conflicts.

2. **RNG threading**: The protocol-level `randomness::u64_range` is called once in `start_combat` to seed the room's RNG. All subsequent randomness (hit rolls, target selection, damage variance, spawns) flows through `rng::Rng` stored in each `Room`.

3. **`#[randomness]` entry functions**: `start_combat` and `advance_turn` are annotated with `#[randomness]` per Aptos AIP-41/AIP-79 requirements.

4. **Test-friendly**: `start_combat_test` and `advance_turn_test` allow injecting fixed seeds for deterministic testing.

### Skills
All 56 EVM skills ported:
- 4 base skills (Attack, Magic Bolt, Heal, Strike 3)
- 5 class skills per class (Sword, Guard, Gunner, Black Mage, White Mage)
- 8 race skills (Orc, Giant, Dwarf, Elf, Dragonborn, Angel, Demon, Human)
- 14 pool/selection skills
- 12 D9 boss/elite skills

### ActiveEffect System
Full port of CombatLib.sol:
- 14 effect operations (STUN, SHIELD, DOT, TAUNT, DISPEL, LIFESTEAL, etc.)
- Stacking rules (ACC_DOWN/EVADE_UP/DMG_OUT_MOD/DMG_IN_MOD merge)
- FIFO shield absorption
- Effect duration decay per turn

### Dungeon System
- Multi-battle dungeons (D9: 4 battles)
- Battle variants (D9 battle 4: 85% chest / 15% emperor)
- On-death spawn (furnace → emperor 60%, chest → emperor 20%)
- Speed-ordered turn resolution

## Tests (13 passing)

| Test | What it verifies |
|------|-----------------|
| `test_all_56_skills_registered` | All 56 skill IDs are in the registry |
| `test_rng_stream_deterministic` | Same seed → same outcome |
| `test_basic_attack_deals_damage` | Physical attack reduces enemy HP |
| `test_enemy_takes_damage` | Enemy AI attacks reduce player HP |
| `test_berserk_applies_effects` | Berserk grants DMG_OUT_MOD + DMG_IN_MOD |
| `test_defeat_weakling` | 1 HP player dies immediately |
| `test_room_lifecycle_to_settled` | Lobby → Combat → Settled flow |
| `test_d9_multi_battle` | D9 4-battle progression to intermission |
| `test_d9_furnace_mana` | Furnace leak/siphon mana manipulation |
| `test_d9_emperor_mana_cycle` | Emperor skill cycle mana costs |
| `test_d9_chest_emperor_spawn` | Chest death can spawn emperor |

## Build & Test
```bash
aptos move compile --package-dir aptos
aptos move test --package-dir aptos
```

## Remaining Work
- Character registry (classes, races, affixes, level scaling)
- Economy system (TurnipMarket, token rewards)
- Item/vault system with ammo
- Deployment scripts and client SDK integration

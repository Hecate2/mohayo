# Mohayo — Aptos Move 实现

本目录是「摸哈游」链上部分的 Move 实现。设计权威在 `../docs/`：
`content-design.md` / `gameplay-design.md` 为活设计文档，
`technical-design.md` §2.5–§2.6.11 记录 Move 实现的语义与每一轮修正。

## 模块布局

| 模块 | 职责 |
|---|---|
| `types.move` | 全部共享数据结构、枚举式常量、Member/Enemy 访问器、效果合并与护盾吸收 |
| `skill_registry.move` | 技能 / AI / 敌人模板 / 敌人构成表 / 变体表 / 副本配置的注册与读取 |
| `content.move` | 技能 key 常量表（分区制，见下） |
| `content_registration.move` | 一次性注册全部内容：职业、种族、词条模板、技能、AI、模板、表、副本、掉落表、道具 |
| `character.move` | 角色创建 / 属性公式 / 词条 / 技能合并 / 升级 / 转移 / 履历 / 房间锁 |
| `engine.move` | 战斗引擎：房间生命周期、行动计划、技能结算、效果、目标选择、AI、多场副本、胜负与结算 |
| `economy.move` | 游戏币账本（i128 有符号，允许负余额） |
| `item.move` | 道具层：数据驱动 ItemDef + 每类型一张 address→u128 账本 + 掉落表 |
| `use_item.move` | 关卡外道具编排（命运骰子 / 重生卷轴 / 挑战券）与每日入场次数门控 |
| `rng.move` | 确定性随机流（xorshift64，种子由房间与回合派生） |
| `sim.move` | 蒙特卡洛通关率仿真（`#[test_only]`，标定护栏） |
| `tests.move` | 单元 / 集成测试（`#[test_only]`） |

## 关键设计

1. **两份全局资源**。`Registry`（静态内容）与 `RoomStore`（可变房间）都在 `@mohayo`，
   分开存放是为了同时借用二者而不触发 Move 借用冲突。
2. **随机数**。房间创建时由 `room_id` 派生的种子写入 `Room.rng_seed`，
   之后命中、目标抽取、掉落、召唤都从这条流里取数。同一 `room_id` 与同一操作序列必得同一结果，
   因此仿真可以在本地复现链上战斗。正式随机方案见 `../docs/randomness-design.md`。
3. **回合驱动**。`advance_turn(account, room_id, expected_turn_id)` 是自动与手动共用的唯一入口，
   靠 `turnId` 互斥加 2 秒冷却防重复推进，`emergency_advance` 在停摆 30 秒后允许任何人解卡。
4. **技能 key 分区**。`content.move` 按 100–199 基础 / 200–600 五职业 / 700 种族 / 800 自选池 /
   1000+ 敌技分区，组内步长 5–10，同组追加时取区间内未用的 key。注册层支持显式 id 并查重。
5. **技能来源红线**。玩家技能只能来自职业、种族、自选池三处。自选池是显式白名单，
   职业技、种族技、敌技、占位技一律不在池内。

## 内容规模

技能 60 余个（五职业各 3、种族 9、自选池 10、敌技 30 余），怪物 AI 23 套，敌人模板 35 个，
敌人构成表 31 张，副本 D1–D10，道具 11 种，掉落表 D1–D9。

## 构建与测试

```bash
aptos move compile   # 发布路径
aptos move test      # 测试路径
```

两条路径都要过。测试模式会编译 `#[test_only]` 模块，因此只跑 `move test` 会掩盖发布路径的编译错误
（2026-09-30 就发生过：`sim.move` 漏写 `#[test_only]`，`move compile` 直接失败）。

当前 154 个用例全绿。仿真的标定锚（各难度通关率、资源链、职业搭配）见
`technical-design.md` §2.6.8 与 `gameplay-design.md` §11。

## 尚未落地

- **房间无回收**。房间关闭只置 `closed` 标志，`RoomStore.rooms` 只增不减。
- 菜市与角色交易依赖链上 DEX，不在本仓库范围。
- Keeper 链下服务与客户端 SDK 不在本仓库范围。
- 履历只记参与次数、通关次数、最高通关难度，逐项统计需要引擎按伤害归属回写。

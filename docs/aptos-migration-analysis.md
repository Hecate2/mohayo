# Aptos 迁移可行性分析：聚焦链上可靠随机数

> 基于代码仓库与设计文档的完整调研；日期：2026-08-27
> 触发原因：EVM 链上（Conflux eSpace）难以实现单区块可靠随机数，严重影响游戏体验
>
> **⚠️ 历史文档（2026-10-09 标注）**：本文是迁移决策前的调研存档，**迁移已执行完成**——当前实现为 Aptos Move
> （仓库根目录 `sources/`，随机数走 `aptos_framework::randomness` / AIP-41），Solidity 版本已弃用并收拢于 `solidity/`。
> 文中「倾向迁移 / 留链」的决策因素、PoC 步骤与迁移成本估算仅作历史参考；实现现状见 `README.md` 与
> `technical-design.md` §2.6.14。

---

## 1. 当前架构回顾：两层随机数的困境

### 1.1 现有设计

本项目采用两层随机架构（`randomness-design.md` §1）：

| 层级 | 场景 | 现有方案 | 核心缺陷 |
|------|------|----------|----------|
| **第一层（高频低价值）** | 战斗内：命中掷骰、随机目标、多段连击、奖励浮动、死亡召唤、效果概率 | `CombatTypes.nextRandom`：`keccak256(room.seed, roomId, turnId, block.prevrandao)` 链式 PRNG | `prevrandao` 在 Conflux eSpace 上的语义**需要测试网实测验证**，且验证人有偏置能力 |
| **第二层（低频高价值）** | 角色创建：种族抽取（三层加权）、词条方向/词条/档位三次掷骰；预留关卡掉落 | `BlockEntropyRNG`（`keccak256(blockhash(n-1), PREVRANDAO, block.number, block.timestamp, category, context)`），走 `RNGRouter` 路由 | 与第一层相同的信任假设；文档明确「未来切 VRF」的升级路径，但**目前无可用 VRF** |

### 1.2 四大痛点

**痛点一：`PREVRANDAO` 语义不确定性**。`technical-design.md` §2.3.4 明确指出：「上线前需在测试网实测 eSpace 上 `prevrandao` 的具体回填值，若语义存疑可退化为 `blockhash(block.number - 1)` 混合熵」。Conflux eSpace 通过 CIP-645 对齐以太坊，但 `PREVRANDAO` 的实际值取决于 Conflux 树图共识的具体实现，**尚无公开实证确认其不可预测性**。

**痛点二：验证人偏置能力**。`randomness-design.md` §3 对三类操纵者的分析中，对验证人的论证是「成本远高于收益」——但这个结论依赖 Conflux 树图 PoS 的具体质押与分叉选择机制，且**无法用数学证明偏置上限**。对于一个正式运营的 MMO，「概率上够用」不等于「可审计地安全」。

**痛点三：VRF 升级路径悬空**。`RNGRouter` 的设计（§2.3.2）预留了 VRF Provider 切换能力，但 EVM 生态中成熟的游戏级 VRF（如 Chainlink VRF v2.5）存在两个根本限制：（a）异步回调模型把回合结算拆成「请求 → 回调 → 结算」三步，**破坏原子性**（§2.3.3 专门论证了这是「默认不用 VRF」的核心理由）；（b）每帧约 0.25-0.5 LINK + gas 的成本，在高频调用下不可接受。

**痛点四：社区信任博弈**。设计文档对「验证人偏置」的论证逻辑是「概率上不划算」，但这依赖玩家理解博弈论。 MMO 玩家社区中，「随机数被操纵」是**最常见的信任危机触发器**——即便技术上不可操纵，只要玩家「感觉」可以被操纵，就会引发流失。这是社区运营层面的非技术风险。

---

## 2. Aptos Randomness API：从设计层解决信任问题

### 2.1 AIP-41 / AIP-79 的核心创新

Aptos 的 Randomness API 不是一个「可选的 VRF 插件」，而是**协议层原生集成的安全随机数基础设施**（AIP-41 定义 Move API 接口，AIP-79 描述底层密码学实现）。

**核心特性：**

| 特性 | 说明 | 对比 EVM 现状 |
|------|------|--------------|
| **协议层保证** | 由共识协议（Jolteon/Shoal）在 VM 层面注入，不是合约层混合 `blockhash` | EVM 的 `PREVRANDAO` 是提议值，**没有共识协议级别的不可偏置证明** |
| **即时可得** | 在交易执行期间直接调用，同步返回结果 | Chainlink VRF 是异步回调（请求 → 等待 → 回调），破坏原子性 |
| **不可预测性** | 基于分布式随机数协议，验证人无法在交易提交时预测结果 | `prevrandao` 在某些链上可在出块前被验证人推断 |
| **零额外 gas** | 随机数是 VM 内置原语，调用成本极低 | VRF 的外部合约调用 + 链下计算成本显著 |
| **编译器强制安全** | 只能在 `#[randomness]` 标注的私有 entry 函数中调用，编译器在编译期阻断不安全用法 | Solidity 无编译器层面的随机数使用约束 |

### 2.2 API 接口

```move
module aptos_framework::randomness {
    // 生成 [min_incl, max_excl) 范围内的均匀随机 u64
    fun u64_range(min_incl: u64, max_excl: u64): u64;

    // 生成随机字节序列
    fun bytes(n: u64): vector<u8>;

    // 生成 [0, ..., n-1] 的随机排列（完美洗牌）
    fun permutation(n: u64): vector<u64>;

    // 更多类型：u8_range, u16_range, u32_range, u128_range, u256_range
}
```

**对本游戏的直接适用性：**

| 游戏随机场景 | Aptos API 映射 | 说明 |
|-------------|---------------|------|
| 命中掷骰（`baseAcc` vs `1000` 比较） | `randomness::u64_range(0, 1000) < hitRate` | 直接替代 `nextRandom(r) % 1000` |
| 随机目标抽取（N 个目标中选 1 个） | `randomness::u64_range(0, n)` | 直接替代 `nextRandom(r) % total` |
| 多段连击每段独立目标 | 在循环中多次调用 `u64_range` | 每次调用独立随机，**天然消除链式 PRNG 的序列依赖** |
| 加权目标抽取 | `permutation(n)` + 权重前缀和二分 | `permutation` 天然支持，无需手动实现 |
| 种族抽取（三层加权 85/12/3） | `u64_range(0, 1000)` + 阈值比较 | 比 `keccak256` 混合方案更简洁 |
| 词条档位抽取（10 档加权） | `u64_range(0, totalWeight)` + 累积权重扫描 | 同上 |
| 死亡召唤概率（千分比掷骰） | `u64_range(0, 1000) < onDeathSpawn.prob` | 直接替代 |
| 变体敌人表权重选择 | `permutation(len)` 或 `u64_range` | 视表大小选择 |
| 收益随机分配（权重分配） | `permutation(n)` 或逐个 `u64_range` | 完美匹配 |

### 2.3 安全模型对比

| 维度 | EVM (Conflux eSpace) | Aptos Randomness API |
|------|---------------------|---------------------|
| **密码学基础** | `keccak256` 混合区块变量；无密码学承诺方案 | AIP-79：基于分布式协议的 VRF 级保证，共识层面注入 |
| **验证人偏置** | 理论上可偏置（取决于共识细节） | **协议层偏置不可能**——随机数在共识协议内产生，验证人无法单独偏置 |
| **用户操纵** | 玩家可选择交易提交时机（理论偏置） | 交易提交时结果**完全不可预测**——VM 层保证 |
| **可审计性** | 需要验证 `prevrandao` 历史值才能审计 | 随机数在 VM 层面有公开可验证的密码学证明 |
| **编译器保障** | 无——`keccak256` 混合可出现在任何函数中 | **强制**：只在 `#[randomness]` 私有 entry 函数中可用，编译器阻断 |
| **Undergasing 攻击** | 不适用（固定 gas 模型） | ⚠️ **需要开发者注意**：Randomness API 目前不防 undergasing，需设计时规避 |

---

## 3. 迁移架构映射

### 3.1 合约层级映射

| 现有 Solidity 合约 | Move 模块映射 | 复杂度评估 |
|-------------------|--------------|-----------|
| `CombatEngine.sol`（291 行，入口层） | `mohayo::combat_engine` entry 函数集 | 中——逻辑直接，但存储模型完全不同 |
| `CombatLib.sol`（结算库） | `mohayo::combat_lib` 内部函数 | 高——核心结算逻辑最复杂，含多段连击、命中管线、召唤逻辑 |
| `CombatEndLib.sol`（回合结束/胜利判定） | `mohayo::combat_end_lib` | 中——含死亡召唤结算 |
| `CombatTargetLib.sol`（目标选择） | `mohayo::combat_target_lib` | 中——加权抽取逻辑 |
| `CombatTypes.sol`（共享类型） | `mohayo::types` | 低——纯数据结构定义 |
| `SkillRegistry.sol`（技能注册） | `mohayo::skill_registry` | 中——结构体存储 + 查询 |
| `CharacterRegistry.sol`（角色 CRUD + ERC-721） | `mohayo::character_registry` | **高**——涉及 Move 的 Object 模型（Digital Asset 标准替代 ERC-721） |
| `Economy.sol`（游戏币账本） | `mohayo::economy` | 低——内部 mapping，Move 中更自然 |
| `RNGRouter.sol`（随机数路由） | **可删除或大幅简化** | ✅ 低——Randomness API 消除了路由需求 |
| `BlockEntropyRNG.sol`（同步随机源） | **直接删除** | ✅ 无——VM 内置替代 |
| `IRNG.sol`（随机数接口） | **直接删除** | ✅ 无——不再需要抽象层 |
| `ItemFactory.sol`（道具 ERC-20） | `mohayo::item_factory` | 中——Fungible Asset 标准替代 ERC-20，单模块复用 |
| `TurnipMarket.sol`（菜市） | `mohayo::turnip_market` | 高——合约复杂度不变，但 Move 资产模型需要适配 |
| `DexMedianPriceSource.sol`（菜价源） | `mohayo::price_source` | 中——需要 Aptos DEX（如 Liquidswap）的储备读取接口 |
| `GasTreasury.sol`（动作费） | `mohayo::gas_treasury` | 低——简单账本 |
| `Limits.sol`（限额库） | `mohayo::limits` | 低——时间窗口计数器 |

### 3.2 随机数架构简化

这是迁移的**核心收益**：

```
EVM 当前架构（12 行随机相关代码路径）：
┌─────────────────────────────────────────────────┐
│ CombatEngine.createRoom()                        │
│   → r.seed = keccak256(prevrandao, ts, sender, id)│
│                                                   │
│ CombatTypes.nextRandom(r)                         │
│   → r.seed = keccak256(seed, id, turnId, prevr)  │
│   → 被 CombatLib（6处）、CombatTargetLib（1处）、  │
│     CombatEndLib（1处）调用                       │
│                                                   │
│ RNGRouter → BlockEntropyRNG                      │
│   → 被 CharacterRegistry（种族/词条创建）调用      │
│   → 未来 VRF 升级路径                             │
└─────────────────────────────────────────────────┘

Aptos 迁移后（零随机数相关状态）：
┌─────────────────────────────────────────────────┐
│ 所有随机场景统一调用：                              │
│   randomness::u64_range(min, max)                │
│                                                   │
│ Room 结构体删除 seed 字段                         │
│ RNGRouter / BlockEntropyRNG / IRNG 全部删除       │
│ createRoom 中删除 seed 初始化                     │
│ nextRandom 函数删除                               │
│                                                   │
│ 随机数从「有状态的链式 PRNG + 区块变量混合」        │
│ 简化为「无状态的 VM 原语调用」                      │
└─────────────────────────────────────────────────┘
```

**代码量减少估算**：随机数相关状态与路由逻辑约消除 ~200 行 Solidity 代码（`Room.seed` 字段、`RNGRouter` 72 行、`BlockEntropyRNG` 32 行、`IRNG` 16 行、`CombatTypes.nextRandom` 函数、`createRoom` 中 seed 初始化、`nextRandom` 调用点 8 处的编码模式）。

### 3.3 存储模型差异（最大的迁移摩擦）

| 维度 | EVM (Solidity) | Move (Aptos) |
|------|---------------|--------------|
| **数据归属** | 所有数据存储在合约的 storage 中；合约是「上帝视角」 | **账户中心**：每个用户存储自己的 Resource；模块（合约）发布在地址上 |
| **映射模式** | `mapping(uint32 => Room) public rooms` | 两种选择：(a) 将 Room 存为 Object Resource；(b) 使用 Table（全局可寻址的 KV 存储） |
| **引用模型** | `storage` 引用，可在函数内自由读写 | `&T` / `&mut T` 引用，需 `acquires` 声明，编译器保证生命周期安全 |
| **继承/代理** | `DELEGATECALL`（CombatLib 代理调用共享 CombatEngine 存储） | **不存在**——所有函数在同一个模块内直接访问存储，或通过 `friend` 关键字暴露 |
| **升级** | Proxy 模式（EIP-1967）| 原生模块升级（`--upgrade-policy compatible`），无需 Proxy |

**关键影响：Room/成员状态的存储位置**

在 Solidity 中，`Room` 是 `CombatEngine` 合约的一个 mapping value。在 Move 中，需要决定：

- **方案 A（Table/Object）**：将 Room 存为一个 Object Resource，CombatEngine 模块持有全局 Table `table::Table<u64, Room>`。每次访问 Room 需要 `borrow_global_mut<Room>(room_addr)`。这**最接近现有 Solidity 的 `rooms[roomId]` 语义**，迁移摩擦最低。
- **方案 B（账户中心）**：每个玩家地址存储自己的 `RoomMember` Resource，Room 本身存为队长地址的 Resource。这更符合 Move 的哲学，但需要重新设计「加入/离开房间」的状态同步机制。

**推荐方案 A**：用 Table 模拟 Solidity 的 mapping，最小化状态模型变更。

### 3.4 `#[randomness]` 约束的影响

Aptos Randomness API **只能在标注了 `#[randomness]` 的私有 entry 函数中调用**。这对回合结算架构有直接影响：

**问题**：当前 EVM 架构中，`advanceTurn` 是一个 public entry 函数，它调用 `CombatLib.advanceTurn`（library 函数），后者调用 `nextRandom`。在 Move 中，`advanceTurn` 必须标注 `#[randomness]` 且必须是 `entry fun`（私有，即不加 `public`）。

**解决方案**：
```move
module mohayo::combat_engine {
    #[randomness]
    entry fun advance_turn(aptos_framework: &signer, room_id: u64) acquires RoomState {
        // 整个回合结算逻辑在这个 entry 函数内执行
        // 内部调用的辅助函数（private fun）可以自由使用 randomness API
        let state = borrow_global_mut<RoomState>(@mohayo);
        let room = table::borrow_mut(&mut state.rooms, room_id);
        combat_lib::resolve_turn(room);  // private fun，可以调用 randomness
    }
}
```

**这完全可行**：`resolve_turn` 是模块内的 private function，不需要标注 `#[randomness]`，只要整个调用链的最外层是 `#[randomness]` entry 函数即可。编译器在编译期验证这一点。

**⚠️ Undergasing 攻击防护**：这是迁移中需要特别关注的安全点。在当前 EVM 架构中，gas 消耗是确定的（每个操作有固定 gas 成本）。但在 Move + Randomness API 场景下，如果回合结算中存在 **gas 消耗依赖随机数结果的分支**，攻击者可以通过控制 `max_gas` 参数，让不利分支因 gas 不足而 abort，从而「选择性地」只执行有利分支。

**防护策略**（对本游戏适用）：
1. **原子性结算**：整个回合在一笔交易内结算完毕，所有玩家的技能、所有敌人的行动都在同一笔 `advance_turn` 中完成——不存在「先看结果再决定是否执行」的中间状态。
2. **gas 恒定路径**：确保无论随机数结果如何，执行路径的 gas 消耗相同或极为接近（本游戏的结算逻辑天然满足——命中/未命中只是数值差异，不改变控制流）。
3. **管理员门槛**（可选）：对高价值随机场景（种族抽取），可要求 `signer` 是系统合约或 Trusted Relayer，而非玩家直接调用。

---

## 4. 迁移工作量评估

### 4.1 代码迁移

| 模块 | 代码规模 | 迁移难度 | 说明 |
|------|---------|---------|------|
| 类型定义 (`CombatTypes`) | ~179 行 | ⭐ 低 | 纯结构体，语法几乎直接对应 |
| 技能注册 (`SkillRegistry`) | 中 | ⭐⭐ 中 | 结构体存储 + 查询函数，Move 的 Table 模型需要适配 |
| 角色注册 (`CharacterRegistry`) | 大 | ⭐⭐⭐ 高 | 涉及 NFT（ERC-721 → Digital Asset），属性计算，转移逻辑，种族/词条生成 |
| 战斗引擎 (`CombatEngine` + 库) | 大 | ⭐⭐⭐ 高 | 核心逻辑，含回合结算、技能结算、伤害管线、召唤系统、死亡召唤、变体表 |
| 道具系统 (`ItemFactory` + `Economy`) | 中 | ⭐⭐ 中 | ERC-20 → Fungible Asset，内部账本直接对应 Move Table |
| 菜市 (`TurnipMarket`) | 大 | ⭐⭐⭐ 高 | 杠杆合约逻辑复杂度不变，需要适配 Aptos DEX 价格源 |
| 随机数路由 (`RNGRouter` + `BlockEntropyRNG`) | ~120 行 | ✅ 删除 | **核心收益：消除随机数基础设施** |
| 测试套件 | ~10 个测试文件 | ⭐⭐⭐ 高 | Foundry → `aptos move test`，VM cheat code 不同（`vm.warp` → `timestamp::update_global_time_for_test`） |

**总估算**：全量迁移约 **3000-5000 行 Move 代码**（原 Solidity 代码量的 1.2-1.5 倍，Move 的样板代码略多但表达力更高）。团队全职投入约 **4-8 周**（含测试）。

### 4.2 工具链迁移

| 现有工具 | Aptos 替代 | 差异 |
|---------|-----------|------|
| Foundry (`forge test`) | `aptos move test` | 测试框架不同；Foundry 的 fuzz/invariant testing 在 Move 中需要手动实现或等待 Move 团队支持 |
| Hardhat（部署脚本） | `aptos move publish` + Aptos CLI | CLI 驱动，更简单 |
| OpenZeppelin Contracts | Aptos Framework 内置模块 | 无需外部库依赖 |
| Remappings + .gitmodules | `Move.toml` 依赖管理 | 更简洁的包管理 |

### 4.3 前端/基础设施迁移

| 组件 | 迁移影响 |
|------|---------|
| Bot 中继器（Discord/Telegram） | 需要改用 Aptos TypeScript SDK（`@aptos-labs/ts-sdk`）发送交易 |
| CLI 客户端 | 同上，改用 Aptos SDK |
| Keeper 服务 | 改用 Aptos RPC 节点，`advanceTurn` 调用方式变更 |
| 事件索引器 | 需要重新配置——Aptos 事件模型与 EVM 的 `emit` 语义不同（需要索引不同的字段） |
| `block.timestamp` / `block.number` 等时间相关逻辑 | Aptos 使用 `aptos_framework::timestamp` 模块，`block.number` 概念不存在（用 `epoch` 和 `round`） |
| 钱包交互（如有） | EVM 钱包（MetaMask）→ Aptos 钱包（Petra、Pontem 等） |
| DEX 价格源（`DexMedianPriceSource`） | 需要适配 Aptos 上的 DEX（如 Liquidswap、Thala）的流动性池读取接口 |

---

## 5. 迁移收益总结

### 5.1 随机数问题的根本性解决

| 问题 | EVM 现状 | Aptos 迁移后 |
|------|---------|-------------|
| `prevrandao` 语义不确定性 | ❌ 需要测试网实测验证 | ✅ Randomness API 是协议层保证，无需验证 |
| 验证人偏置 | ⚠️ 博弈论论证（「成本不划算」） | ✅ 密码学保证（AIP-79 底层协议） |
| VRF 升级路径悬空 | ⚠️ 异步回调破坏原子性 | ✅ **不需要 VRF**——Randomness API 已达到 VRF 级安全且同步可用 |
| 「随机数被操纵」社区信任危机 | ❌ 依赖玩家理解博弈论 | ✅ 可向社区声明「协议层密码学保证，非合约层混合」 |
| 两层随机架构复杂度 | ⚠️ 需要维护 PRNG 状态 + Router 路由 | ✅ 单一 API，零状态，代码更简洁 |

### 5.2 迁移的附带收益

1. **Gas 成本下降**：Aptos 的 gas 模型比 Conflux eSpace 更可预测，且没有 `SSTORE` 的阶梯定价（2100 gas cold write）——回合结算中频繁的 `room.seed` 读写在 Move 中几乎零成本（Randomness API 是 VM 原语）。
2. **并行执行**：Aptos 的 Block-STM 并行执行引擎让不同房间的 `advanceTurn` 可以并行处理（只要不操作同一个 Room Resource），**理论上提高吞吐量**。
3. **编译器安全**：Move 的类型系统在编译期消除整类漏洞（重入、整数溢出、类型混淆）——不需要 OpenZeppelin 的 SafeMath 或 ReentrancyGuard。
4. **模块升级**：原生 `compatible` 升级策略，无需 Proxy 模式，部署与维护更简单。

### 5.3 迁移的成本与风险

| 风险 | 级别 | 缓解措施 |
|------|------|---------|
| **全量重写** | ⚠️ 高 | 无法渐进式迁移——Solidity 和 Move 是完全不同的语言与 VM |
| **团队学习曲线** | ⚠️ 中-高 | Move 的所有权模型、Resource 系统、`acquires` 约束需要学习周期 |
| **Undergasing 攻击** | ⚠️ 中 | 设计时注意 gas 恒定路径；回合结算的原子性天然提供保护 |
| **生态系统成熟度** | ⚠️ 中 | Aptos 生态比 EVM 小；第三方工具、审计公司支持度低于 EVM |
| **EVM 已有资产** | ⚠️ 低-中 | 角色 NFT、道具 ERC-20 无法跨链迁移——需要社区迁移窗口 |
| **Foundry fuzz/invariant testing 缺失** | ⚠️ 中 | 当前有 256 次 fuzz + 64 次 invariant 测试，Move 生态中同等覆盖需要额外工作 |

---

## 6. 推荐路径

### 6.1 短期：EVM 上的缓解方案（不迁移）

如果团队暂时不考虑迁链，可采取以下缓解措施：

1. **Commit-Reveal 方案**：将 `CombatTypes.nextRandom` 改为两步——本回合提交哈希，下回合揭示种子。代价是每回合多一次存储写，但消除玩家对 `prevrandao` 的操纵可能。
2. **KeeperPushRNG**：让可信 Keeper 每回合推送随机种子。完全依赖 Keeper 信任，但代码改动最小。
3. **`blockhash(block.number - 1)` 增强**：在 `nextRandom` 中额外混合 `blockhash(block.number - 1)`（Conflux eSpace 支持查询近 256 块的 blockhash，成本仅 100-2100 gas），增加熵源。

### 6.2 中期：Aptos PoC（2 周概念验证）

如果团队对迁移感兴趣，建议先做一个 **核心战斗结算的 Move PoC**：

1. 实现 `CombatTypes` 结构体（Move 版）
2. 实现 `next_random` 函数（直接调用 `randomness::u64_range`）
3. 实现一个简化版的 `advance_turn`（包含随机目标抽取 + 命中判定 + 伤害计算）
4. 用 `aptos move test` 验证随机数的不可预测性与均匀分布

**这个 PoC 的核心价值**：让团队亲身感受 Move 的编码体验、Randomness API 的调用方式、以及与 Foundry 的开发体验差异。

### 6.3 长期：全量迁移决策（基于 PoC 结果）

决策因素：

| 因素 | 倾向迁链 | 倾向留链 |
|------|---------|---------|
| 随机数信任问题是否成为社区运营痛点 | ✅ 是 | 留在 EVM |
| 团队是否有 Move/Rust 语言经验或学习意愿 | ✅ 有 | 留在 EVM |
| Aptos 游戏生态是否有成功先例 | ✅ 有 | 留在 EVM |
| 是否有外部投资者/合作伙伴要求 Aptos 部署 | ✅ 有 | 留在 EVM |
| 已有 EVM 用户资产规模是否足够大（迁移成本） | 小规模可接受 | 规模大则留 |

---

## 7. 结论

**Aptos Randomness API 从协议层解决了本项目在 EVM 上面临的随机数信任问题**，且同步调用的特性完美匹配回合结算的原子性要求——这是 Chainlink VRF 等 EVM 方案无法提供的。

迁移的核心收益不是「换一条更快的链」，而是**从根本上消除随机数这一贯穿全系统的核心机制的信任假设**。对于一个以「命运的抽签」为核心叙事的 MMO，随机数的可信度就是产品的可信度。

迁移成本是全量重写（~3000-5000 行 Move，4-8 周全职），不可渐进式进行。建议先做 2 周 PoC 验证 Move 开发体验，再基于团队实际情况做出最终决策。

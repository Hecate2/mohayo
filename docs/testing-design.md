# 摸哈游（Mohayo）：测试机制设计
> **⚠️ 文档状态声明（2026-09-02）**：本文描述的是 **EVM 时代的 Foundry/Hardhat 测试体系**（`forge`/`out/`/Hardhat 部署），
> 已被废弃。当前实现为 **Aptos Move**，测试入口 = `aptos move test`（`aptos/sources/tests.move` 模块级单元测试 +
> `sim.move` 蒙特卡洛通关率仿真/平衡标定）。本文仅作历史参考。


> 配套文档：`technical-design.md`（技术实现）、`gameplay-design.md`（玩法）、`content-design.md`（内容）
> 本文档定义整套测试机制：**Foundry 合约测试（单元/模糊/不变式）→ Anvil 私链集成测试 → Hardhat 部署与运维 → CLI/Bot 客户端集成测试（预留）**。
> 核心立场：**Foundry 是唯一编译源与合约级测试源；Hardhat 不参与编译，直接消费 Foundry 的 `out/` 产物，专职生产部署与链下运维。**

---

## 1. 总体架构：双工具链分工

| 工具 | 职责 | 不做什么 |
|------|------|----------|
| **Foundry（forge/cast/anvil）** | 合约编译、Solidity 单元/模糊/不变式测试、forge script 部署、Anvil 本地私链、cast 命令行交互 | 不做链下业务逻辑、不做 TS 运维脚本 |
| **Hardhat（ethers.js）** | 生产部署编排（SkillRegistry 批量数据灌入、代理部署）、链下运维（Bot 充值、暂停、多签）、对 Anvil/测试网的 TS 集成测试 | 不编译合约（直接读 `out/`） |

**为什么这样分工**：战斗逻辑、伤害计算、经济模型是纯 Solidity 领域，用 Solidity 写测试可以直接实例化结构体、直接断言内部状态，比在 TS 里拼 ABI 传参高效得多，且模糊测试（fuzz）与不变式测试（invariant）是 Foundry 的原生能力。而部署编排、批量数据灌入、运维操作天然是脚本语言的工作，Hardhat/ethers.js 生态成熟。二者通过**统一的 `out/` 产物目录**衔接，不维护两套编译结果。

### 1.1 目录结构

```
mohayo/
├── foundry.toml              # Foundry 配置（编译/测试/脚本）
├── src/                      # 合约源码（Foundry 唯一编译源）
│   ├── core/                 # 核心合约
│   ├── interfaces/           # 接口（IRNG 等）
│   └── libs/                 # 纯函数库（伤害公式、加权随机等）
├── test/                     # Foundry 测试
│   ├── unit/                 # 单元测试（每合约一个文件）
│   ├── fuzz/                 # 模糊测试（属性/边界）
│   ├── invariant/            # 不变式测试（经济守恒等）
│   └── integration/          # 多合约端到端（对 Anvil 或 fork）
├── script/                   # forge script（部署/播种/压测）
│   ├── Deploy.s.sol
│   ├── Seed.s.sol
│   └── ...
├── hardhat/                  # Hardhat 项目（不编译，读 ../out）
│   ├── hardhat.config.ts
│   ├── scripts/              # deploy.ts / seed.ts / verify.ts
│   ├── tasks/                # 运维 tasks（bot-fund、pause、multisig…）
│   └── test/                 # TS 集成测试（对 Anvil 实例）
└── .gitignore
```

---

## 2. 私链测试工具（Anvil 为主）

### 2.1 Anvil 本地私链

Anvil 是 Foundry 自带的本地节点，作为私链测试的默认底座，具备以下关键能力：

- **确定性账户**：默认派生 10 个测试账户（私钥公开、余额充足），测试脚本无需管理密钥。
- **可配置链 ID**：`--chain-id` 固定链 ID（如 `1337`），避免与主网/测试网混淆。
- **自动挖矿与固定时间**：默认即时出块；`--block-time <N>` 可模拟固定出块间隔（用于测试回合推进的"5 区块"节奏）；`--timestamp` 可设定起始时间（用于测试自然日熔断、打工每日一次等时间边界）。
- **状态可回溯**：`anvil --state <path>` 持久化状态，`anvil --load-state` 恢复——用于"预置数据 → 重启节点 → 客户端联调"的场景。
- **无 gas 门槛**：默认 `--gas-limit` 宽松，便于压测最坏回合结算。

**私链测试的标准流程**：

```
启动 Anvil（固定链 ID + 状态文件）
   → forge script 部署全部合约（Deploy.s.sol）
   → forge script 播种数据（Seed.s.sol：技能/词条/敌人模板/测试角色）
   → 集成测试（Foundry 对 Anvil 的 RPC 交互，或 Hardhat TS 脚本）
   → 断言事件与状态
   → 清理/重置（重启 Anvil 或 --load-state 恢复基线）
```

### 2.2 测试网（公共测试网）

私链验证通过后，同一套 `Deploy.s.sol` 可指向公共测试网（Conflux eSpace 测试网，链 ID 71）。差异点：

- 需要真实私钥（环境变量注入，禁止硬编码）；
- 需要测试网 CFX（水龙头）；
- 部署脚本通过 `--rpc-url` 与 `--private-key` 参数切换目标；
- 测试网上的集成测试用 Hardhat TS 脚本（更贴近生产运维路径），Foundry 测试保持对 Anvil/fork 执行。

### 2.3 主网 fork 测试

`forge test --fork-url <RPC>` 可对 eSpace 主网状态做分叉测试，用于验证：已部署合约与既有状态的兼容性、升级脚本对存量数据的迁移、以及真实链上 gas 成本（fork 模式下 gas 计量与主网一致）。这是"上线前最后一道合约级验证"。

---

## 3. Foundry 合约测试分层

### 3.0 构建提速：debug/release 双 profile 与定向测试

**硬约束**：本代码库的合约依赖 `via_ir`（IR 中间表示编译管线）的无限栈槽——legacy 代码生成器与精简 Yul 优化步骤都会在**大结构体 getter 的 ABI 编码器**上触发 stack-too-deep（`getRoom`/`getSkill`/`getRaceDef` 等返回完整结构体的函数，字段过多）。因此 `via_ir + 完整 Yul 优化器` 不可关闭，冷构建（`forge clean` 后）全量约 2 分钟，这是编译管线的固有成本，不是配置问题。

**提速手段一：debug/release 双 profile**（`foundry.toml`）。默认 profile（debug）用 `optimizer_runs=1` 产出最小体积字节码，保证全部合约低于 EIP-170 24KB 上限（当前 CombatLib 19.5KB、CharacterRegistry 17.6KB，余量充足）；`[profile.release]` 用 `optimizer_runs=200` 换运行时 gas 效率，产物输出到 `out-release/`，供生产部署使用（`FOUNDRY_PROFILE=release forge build && FOUNDRY_OUT=out-release npx hardhat run scripts/deploy.ts`）。注意 `optimizer_runs` 只影响体积/gas 权衡，**不影响编译时间**（实测 runs=1 与 runs=200 冷构建均为约 2 分钟）。

**提速手段二：定向测试（真正的开发循环加速器）**。`forge test --match-path <文件>` 只编译匹配的测试文件及其依赖，冷构建约 44 秒（全量约 2 分钟）；`--match-contract`/`--match-test` 同理。日常迭代用定向测试，全量测试只在提交前跑一次。增量编译本身已很快（只重编改动文件及其依赖），因此**不要在改动后频繁 `forge clean`**。

**提速手段三：src 单独构建**。`forge build --skip 'test/*' --skip 'script/*'` 只编译 src（约 13 秒），用于快速验证合约可编译或生成部署产物。注意 `forge test` 不编译 `script/` 下的部署脚本，`forge build` 才编译——部署脚本只影响全量 `forge build` 的时间。

**已排除的方案**：拆分更多 lib 只影响体积余量、不影响编译速度（实测去掉 CombatLib 后 src 构建时间不变，13 秒被共享依赖主导）；`optimizerSteps` 精简优化步骤会触发 ABI 编码器 stack-too-deep，不可行。

### 3.1 单元测试（test/unit/）

每个合约一个测试文件，覆盖每个外部函数的正常路径、边界路径、revert 路径。重点：

- **CombatEngine**：行动顺序、随机目标、命中判定管线（豁免/掷骰/未命中）、护盾 FIFO、同 op 合并规则、两阶段资源门槛（AP/魔素/弹药）、死亡结算顺序红线、召唤上限、收益随机分配。
- **CharacterRegistry**：创建流程（职业→种族三层加权→词条方向×档位→属性计算）、转移钩子（等级重置、战斗锁）、重掷计数器。
- **Economy**：负余额、负债行为限制、救援费、打工每日一次、娱乐模块总线权限。
- **RNGRouter**：按用途路由、Provider 切换、事件播报。

### 3.2 模糊测试（test/fuzz/）

用 Foundry 原生 fuzz 对纯函数与状态机做属性测试：

- **伤害公式**：任意属性/技能参数组合下，伤害不溢出、不为负、受 damageCap 钳制。
- **加权随机**：任意权重数组下，抽取结果落在合法目标集内、权重全 1 退化为均匀。
- **命中公式**：任意 ACC_DOWN/EVADE_UP 组合下，命中率被钳制在全局下限之上。
- **存储打包**：任意 uint 组合下，打包/解包往返一致。

### 3.3 不变式测试（test/invariant/）

对经济与状态不变量做长期随机序列验证（`invariant` 目标函数 + `handler` 随机调用）：

- **Char总量守恒**：mint/burn/销毁路径下，`总铸造 − 总销毁` 恒等于账本余额之和。
- **房间状态有界**：任意随机操作序列下，房间数、单位数、事件数不超硬上限。
- **角色属性不溢出**：任意升级/词条组合下，三维属性在 uint 范围内且受种族上限约束。

### 3.4 集成测试（test/integration/）

多合约端到端场景，覆盖完整玩家旅程：

```
创建角色（含重掷） → 开房（选难度） → 加入 → 排技能计划
→ 推进回合（手动/自动） → 战斗结算 → 胜利/失败 → 收益发放 → 逃离/通关
```

集成测试既可在 Foundry 内以 `setUp` 直接部署全部合约跑（快、无网络），也可对 Anvil 实例通过 RPC 跑（验证真实节点行为）。

---

## 4. 部署与播种脚本（forge script）

### 4.1 Deploy.s.sol

按依赖顺序部署全部合约，并把地址写入**部署清单文件**（`deployments/<chainId>.json`），供 Hardhat 脚本与 CLI/Bot 读取：

```
RNGRouter + BlockEntropyRNG → Economy → SkillRegistry → CharacterRegistry
→ CombatEngine → RoomManager（若独立） → ItemFactory → TurnipMarket → PriceFeed
→ 权限授予（RBAC 角色） → 配置初始化（难度参数、限额、RNG 路由）
```

### 4.2 Seed.s.sol

播种测试数据，与部署分离（生产环境不跑 Seed）：

- 注册首版技能（职业技/种族技/自选池，见 `content-design.md` §4/§5）；
- 注册词条模板（方向×档位分布）；
- 注册敌人模板与地下城配置（D1~D5）；
- 创建若干测试角色（固定种子 RNG，保证可复现）。

### 4.3 数据灌入的两种方式

- **Foundry 方式**：`Seed.s.sol` 用 Solidity 直接构造 `Skill`/`Effect`/`EnemyTemplate` 结构体数组批量注册——类型安全、可复现，是首选。
- **Hardhat 方式**：`hardhat/scripts/seed.ts` 从 JSON/CSV 读取技能表批量灌入——适合内容策划用表格维护数据、或从旧系统迁移。

---

## 5. Hardhat 部署与运维（生产路径）

### 5.1 与 Foundry 的衔接

Hardhat 配置 `paths.sources` 指向 `../src`、`paths.artifacts` 指向 `../out`，并**禁用 Hardhat 自身编译**（override compile 任务为 `forge build`）。TS 侧通过一个 `loadArtifact(name)` 辅助函数读取 `out/<Contract>.sol/<Contract>.json`，把 `abi` 与 `bytecode` 交给 ethers.js 的 `ContractFactory`——不依赖 Hardhat 的 artifact 格式，避免两套编译结果漂移。

### 5.2 deploy.ts（生产部署编排）

- 读取部署清单，支持增量部署（已部署的跳过）；
- 处理代理合约部署（CombatEngine/SkillRegistry/TurnipMarket/PriceFeed 走可升级代理）；
- 批量灌入 SkillRegistry 数据（大数组拆分多笔交易，避免单笔超 gas）；
- 输出部署报告（地址、交易哈希、gas 消耗）。

### 5.3 运维 tasks

用 Hardhat tasks 封装运维操作，供运营在命令行执行：

| task | 用途 |
|------|------|
| `bot-fund` | 给 L1 中继 Bot 钱包充值 CFX |
| `pause` / `unpause` | 紧急暂停/恢复（Pausable） |
| `set-config` | 修改难度参数/限额/RNG 路由（走时间锁） |
| `register-module` | Char娱乐模块总线注册 |
| `post-price` | （若采用推送模型）价格上链 |
| `advance-turn` | 手动推进指定房间回合（Keeper 兜底） |

---

## 6. CLI 与 Bot 的测试预留（客户端集成测试）

CLI（L2 自托管）与 Discord/Telegram Bot（L1 代发）都是**链下软件**，它们的测试分两层：

### 6.1 单元/逻辑测试（不依赖链）

- 命令解析器：`/排技能 鹰眼 弹雨 接下来2回合` → 结构化的 `setPlan` 参数；
- 战报渲染器：事件流 → 群内可读文本（模板 + 数据填充）；
- 计费账本：L1a 配额扣减、L1b 余额扣减、价目表计算；
- 身份映射：chatUserId → playerId 的绑定与校验。

这些逻辑与链无关，用各语言的标准测试框架（如 Node 的 vitest/jest）直接测。

### 6.2 端到端集成测试（依赖私链）

CLI/Bot 通过 RPC 与事件与链交互，因此端到端测试直接复用 **Anvil 私链 + Seed 数据**：

```
启动 Anvil（--state 预置数据）
   → 启动 CLI 测试实例（或 Bot 测试实例，指向 Anvil RPC）
   → 注入聊天指令（模拟 Discord/TG 消息）
   → 断言链上状态变化 + 事件 + 战报输出
```

**关键设计**：私链测试的部署清单（`deployments/1337.json`）与 Seed 数据是 CLI/Bot 集成测试的**共享夹具**——同一份夹具同时服务合约测试与客户端测试，保证"合约层通过"与"客户端通过"验证的是同一套链上状态。Anvil 的 `--state`/`--load-state` 让客户端测试可以反复从同一基线启动，无需每次重新部署。

### 6.3 Bot 的模拟聊天测试

Bot 依赖 Discord/TG 的网关，测试时用**模拟网关适配器**注入消息（不连真实 Discord/TG），把"消息 → 命令解析 → 代发交易 → 事件 → 战报"整条链路在本地跑通；真实网关的接入只做冒烟测试（连一次真实环境验证鉴权与消息收发）。CLI 的 `--announce` 回写频道同样走模拟适配器。

---

## 7. 测试数据与可复现性

- **两层确定性随机**：创建层随机（角色创建掷骰）经 `RNGRouter` 路由到固定种子的 MockRNG，保证创建结果可复现；战斗内随机走**房间级链式 PRNG**（`CombatTypes.nextRandom`，`randomness-design.md` §2）——Foundry 测试中 `block.prevrandao` 单次测试内稳定，给定相同操作序列战斗结果精确可复现，无需注入确定性随机源模拟战斗随机。`vm.warp`/`vm.roll` 用于控制区块时间与超时判定。
- **部署清单**：每次部署写入 `deployments/<chainId>.json`，是合约测试、Hardhat 脚本、CLI/Bot 测试共用的地址源。
- **快照/恢复**：Anvil `--state` 与 Foundry `vm.createSelectFork` 提供两级状态恢复，测试之间互不污染。
- **CI 集成**：`forge test` 与 `forge script` 全部无网络依赖（除 fork 测试），可在 CI 中一键执行；Hardhat 测试对 Anvil 实例执行。

---

## 8. 测试矩阵（验收口径）

| 层级 | 工具 | 覆盖内容 | 执行环境 |
|------|------|----------|----------|
| 合约单元 | Foundry | 每函数正常/边界/revert | 本地（无网络） |
| 合约模糊 | Foundry | 纯函数属性、gas 有界 | 本地 |
| 合约不变式 | Foundry | 经济守恒、状态有界 | 本地 |
| 合约集成 | Foundry | 多合约端到端玩家旅程 | 本地 / fork |
| 部署验证 | forge script | 部署顺序、权限、配置 | Anvil / 测试网 |
| 部署编排 | Hardhat | 代理部署、批量灌入、增量部署 | 测试网 / 主网 |
| 运维 | Hardhat tasks | 充值/暂停/配置/模块注册 | 测试网 / 主网 |
| 客户端逻辑 | vitest/jest | 命令解析、战报渲染、计费 | 本地 |
| 客户端端到端 | vitest/jest + Anvil | CLI/Bot 全链路 | Anvil 私链 |

---

## 9. 当前落地范围（本仓库已实现）

本仓库当前实现的是**私链测试工具链的第一阶段**：Foundry 项目骨架 + 核心合约垂直切片（RNGRouter/BlockEntropyRNG、Economy、SkillRegistry、CharacterRegistry、CombatEngine 核心战斗循环）+ 单元/模糊/集成测试 + forge 部署脚本 + Anvil 私链跑通 + Hardhat 部署/运维骨架。CLI/Bot 的端到端测试框架已按 §6 预留接口，待客户端代码落地后接入。

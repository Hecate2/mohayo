// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title Economy - 游戏币（烬晶）内部账本 + 烬晶娱乐模块总线
/// @notice 游戏币只存在于合约内部 mapping，无 transfer 接口、禁止 P2P 转账、支持无上限负数
///         （技术设计 §2.1 / 玩法设计 §7.1）。烬晶娱乐模块总线（技术设计 §5.5）：
///         托管级（tier 1）零铸造、结算分配强制抽水销毁；铸销级（tier 2）可 mint/burn，
///         每次 mint 走「逐模块日预算 + 全局合计预算」双闸门。
contract Economy is Ownable {
    /// @notice 玩家游戏币余额（int256，允许负数）
    mapping(address => int256) public balances;

    /// @notice 有铸造权限的调用方（如 CombatEngine 发放通关奖励）
    mapping(address => bool) public minters;
    /// @notice 有扣费权限的调用方（如 CombatEngine 救援费、Shop、GasTreasury）
    mapping(address => bool) public spenders;

    // ---- 打工（每日零花钱水龙头）----
    uint256 public workReward = 5;
    mapping(address => uint256) public lastWorkDay;

    // ---- 美元购币限购（自然日）----
    uint256 public usdDailyCap = 100 ether; // 示例：每账号每日 100 美元
    mapping(address => uint256) public dailyUsdMinted;
    mapping(address => uint256) public lastUsdDay;

    // ---- 烬晶娱乐模块总线 ----
    struct ModuleGrant {
        uint8 tier; // 0=禁用 1=托管级 2=铸销级
        uint32 minRakeBps; // 托管级强制最低抽水（基点，结算时扣除销毁）
        uint96 dailyBudget; // 铸销级：自然日净铸造预算
        int256 dailyNetMint; // 当日已用（跨日清零）
        uint96 totalMinted; // 累计铸造（审计）
        uint96 totalBurned; // 累计销毁（审计）
    }
    mapping(address => ModuleGrant) public modules;
    uint96 public globalDailyBudget = 500_000 ether; // 全局合计净铸造预算（示例）
    int256 public globalDailyNetMint; // 当日全局合计
    uint256 public lastGlobalResetDay;

    event Minted(address indexed player, uint256 amount);
    event Spent(address indexed player, uint256 amount);
    event RescueFeeCharged(address indexed player, uint256 amount);
    event Worked(address indexed player, uint256 amount);
    event UsdMinted(address indexed player, uint256 amount);
    event ModuleRegistered(address indexed module, uint8 tier, uint32 minRakeBps, uint96 dailyBudget);
    event ModuleEscrowed(address indexed module, address indexed player, uint256 amount);
    event ModuleSettled(address indexed module, address[] players, uint256[] amounts);
    event ModuleMint(address indexed module, address indexed player, uint256 amount);
    event ModuleBurn(address indexed module, address indexed player, uint256 amount);
    event ModuleBudgetTripped(address indexed module, uint256 day);

    constructor() Ownable(msg.sender) {}

    // ---- 权限 ----
    function setMinter(address who, bool ok) external onlyOwner {
        minters[who] = ok;
    }

    function setSpender(address who, bool ok) external onlyOwner {
        spenders[who] = ok;
    }

    function setWorkReward(uint256 amount) external onlyOwner {
        workReward = amount;
    }

    function setUsdDailyCap(uint256 cap) external onlyOwner {
        usdDailyCap = cap;
    }

    function setGlobalDailyBudget(uint96 cap) external onlyOwner {
        globalDailyBudget = cap;
    }

    // ---- 余额查询 ----
    function balanceOf(address player) external view returns (int256) {
        return balances[player];
    }

    /// @notice 负债行为限制：负余额玩家不得创建角色/升级/购买/开房/付费入场（玩法设计 §6.3）
    function isRestricted(address player) public view returns (bool) {
        return balances[player] < 0;
    }

    // ---- 铸造与扣费（授权调用方）----
    function mint(address player, uint256 amount) external {
        require(minters[msg.sender], "Economy: not minter");
        balances[player] += int256(amount);
        emit Minted(player, amount);
    }

    /// @notice 扣费（允许余额变负，用于救援费/入场费/升级/商店）
    function spend(address player, uint256 amount) external {
        require(spenders[msg.sender], "Economy: not spender");
        balances[player] -= int256(amount);
        emit Spent(player, amount);
    }

    /// @notice 救援费：全队失败时倒扣，允许负余额（难度挂钩的固定费）
    function chargeRescueFee(address player, uint256 amount) external {
        require(spenders[msg.sender], "Economy: not spender");
        balances[player] -= int256(amount);
        emit RescueFeeCharged(player, amount);
    }

    // ---- 打工（每日一次）----
    function work() external {
        uint256 day = block.timestamp / 86400;
        require(lastWorkDay[msg.sender] != day, "Economy: already worked today");
        lastWorkDay[msg.sender] = day;
        balances[msg.sender] += int256(workReward);
        emit Worked(msg.sender, workReward);
    }

    // ---- 美元购币（官方商城单向入金，自然日限购）----
    function mintUsd(address player, uint256 usdAmount, uint256 coinAmount) external onlyOwner {
        uint256 day = block.timestamp / 86400;
        if (lastUsdDay[player] != day) {
            lastUsdDay[player] = day;
            dailyUsdMinted[player] = 0;
        }
        require(dailyUsdMinted[player] + usdAmount <= usdDailyCap, "Economy: usd daily cap exceeded");
        dailyUsdMinted[player] += usdAmount;
        balances[player] += int256(coinAmount);
        emit UsdMinted(player, coinAmount);
    }

    // ---- 烬晶娱乐模块总线 ----
    function registerModule(address module, uint8 tier, uint32 minRakeBps, uint96 dailyBudget) external onlyOwner {
        require(tier <= 2, "Economy: bad tier");
        if (tier == 1) {
            require(minRakeBps > 0, "Economy: escrow tier needs rake");
        }
        modules[module] = ModuleGrant({tier: tier, minRakeBps: minRakeBps, dailyBudget: dailyBudget, dailyNetMint: 0, totalMinted: 0, totalBurned: 0});
        emit ModuleRegistered(module, tier, minRakeBps, dailyBudget);
    }

    function revokeModule(address module) external onlyOwner {
        modules[module].tier = 0;
    }

    /// @notice 托管级：玩家烬晶划入模块托管（零铸造）
    function moduleEscrow(address module, address player, uint256 amount) external {
        require(msg.sender == module, "Economy: not module");
        require(modules[module].tier >= 1, "Economy: module disabled");
        balances[player] -= int256(amount);
        emit ModuleEscrowed(module, player, amount);
    }

    /// @notice 托管级：结算分配，强制扣除 minRakeBps 抽水销毁（反转账红线）
    function moduleSettle(address module, address[] calldata players, uint256[] calldata amounts) external {
        require(msg.sender == module, "Economy: not module");
        ModuleGrant storage g = modules[module];
        require(g.tier >= 1, "Economy: module disabled");
        uint32 rake = g.minRakeBps;
        uint256 n = players.length;
        require(n == amounts.length, "Economy: len mismatch");
        uint256 total;
        for (uint256 i; i < n; ++i) {
            uint256 pay = amounts[i];
            uint256 rakeAmt = (pay * rake) / 10000;
            uint256 net = pay - rakeAmt;
            balances[players[i]] += int256(net);
            total += rakeAmt;
        }
        // 抽水销毁：从模块托管池扣除（此处简化为从调用模块的余额扣，实际由模块托管账本承载）
        balances[module] -= int256(total);
        emit ModuleSettled(module, players, amounts);
    }

    /// @notice 铸销级：mint（走双预算闸门）
    function moduleMint(address module, address player, uint256 amount) external {
        require(msg.sender == module, "Economy: not module");
        ModuleGrant storage g = modules[module];
        require(g.tier == 2, "Economy: not mint tier");
        _resetDaily();
        g.dailyNetMint += int256(amount);
        globalDailyNetMint += int256(amount);
        if (g.dailyNetMint > int256(uint256(g.dailyBudget))) {
            emit ModuleBudgetTripped(module, block.timestamp / 86400);
            revert("Economy: module daily budget");
        }
        if (globalDailyNetMint > int256(uint256(globalDailyBudget))) {
            emit ModuleBudgetTripped(address(0), block.timestamp / 86400);
            revert("Economy: global daily budget");
        }
        g.totalMinted += uint96(amount);
        balances[player] += int256(amount);
        emit ModuleMint(module, player, amount);
    }

    /// @notice 铸销级：burn（亏损/费用销毁）
    function moduleBurn(address module, address player, uint256 amount) external {
        require(msg.sender == module, "Economy: not module");
        ModuleGrant storage g = modules[module];
        require(g.tier == 2, "Economy: not mint tier");
        _resetDaily();
        g.dailyNetMint -= int256(amount);
        globalDailyNetMint -= int256(amount);
        g.totalBurned += uint96(amount);
        balances[player] -= int256(amount);
        emit ModuleBurn(module, player, amount);
    }

    function _resetDaily() private {
        uint256 day = block.timestamp / 86400;
        if (lastGlobalResetDay != day) {
            lastGlobalResetDay = day;
            globalDailyNetMint = 0;
        }
    }
}

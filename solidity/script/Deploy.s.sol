// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {RNGRouter} from "../src/core/RNGRouter.sol";
import {BlockEntropyRNG} from "../src/core/BlockEntropyRNG.sol";
import {Economy} from "../src/core/Economy.sol";
import {SkillRegistry} from "../src/core/SkillRegistry.sol";
import {CharacterRegistry} from "../src/core/CharacterRegistry.sol";
import {CombatEngine} from "../src/core/CombatEngine.sol";

/// @title Deploy - 按依赖顺序部署全部核心合约并写入部署清单
/// @notice 用法：
///   forge script script/Deploy.s.sol --rpc-url <RPC> --broadcast
///   - 本地 Anvil：--rpc-url http://127.0.0.1:8545
///   - 测试网：--rpc-url <testnet> --private-key <KEY>
///   部署清单写入 deployments/<chainId>.json，供 Hardhat/CLI/Bot 共享。
contract Deploy is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        vm.startBroadcast(deployerKey);

        // ---- 1. 随机数路由 + 默认 Provider（角色创建/词条用；战斗走房间级链式 PRNG）----
        RNGRouter rng = new RNGRouter();
        BlockEntropyRNG blockRng = new BlockEntropyRNG();
        rng.setGlobalProvider(address(blockRng));
        rng.setCategoryProvider(keccak256("AFFIX"), address(blockRng));

        // ---- 2. 经济 + 技能注册表（gmEnabled 由环境变量控制，主网传 false 使全部 GM 入口物理移除）----
        bool gmEnabled = vm.envOr("GM_ENABLED", true);
        Economy economy = new Economy(gmEnabled);
        SkillRegistry sr = new SkillRegistry();

        // ---- 3. 角色注册表 ----
        CharacterRegistry cr = new CharacterRegistry(rng, sr, gmEnabled);

        // ---- 4. 战斗结算器 ----
        CombatEngine ce = new CombatEngine(sr, cr, economy);

        // ---- 5. 权限授予 ----
        economy.setMinter(address(ce), true);
        economy.setSpender(address(ce), true);
        cr.setCombatEngine(address(ce));

        vm.stopBroadcast();

        // ---- 6. 写入部署清单 ----
        string memory manifest = string.concat(
            '{"chainId":', vm.toString(block.chainid),
            ',"deployer":"', vm.toString(deployer),
            '","gmEnabled":', gmEnabled ? "true" : "false",
            ',"contracts":{',
            '"RNGRouter":"', vm.toString(address(rng)), '",',
            '"BlockEntropyRNG":"', vm.toString(address(blockRng)), '",',
            '"Economy":"', vm.toString(address(economy)), '",',
            '"SkillRegistry":"', vm.toString(address(sr)), '",',
            '"CharacterRegistry":"', vm.toString(address(cr)), '",',
            '"CombatEngine":"', vm.toString(address(ce)), '"',
            "}}"
        );
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(manifest, path);
        console2.log("Deployed to chain", block.chainid, "manifest:", path);
        console2.log("  RNGRouter:", address(rng));
        console2.log("  Economy:", address(economy));
        console2.log("  SkillRegistry:", address(sr));
        console2.log("  CharacterRegistry:", address(cr));
        console2.log("  CombatEngine:", address(ce));
    }
}

import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-ethers";
import "./tasks/ops";

// 私链/测试网 RPC 由环境变量注入；Anvil 默认本地 8545。
const ANVIL_RPC = process.env.ANVIL_RPC || "http://127.0.0.1:8545";
const TESTNET_RPC = process.env.TESTNET_RPC || "";
const PRIVATE_KEY = process.env.PRIVATE_KEY || "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.24",
    settings: {
      optimizer: { enabled: true, runs: 200 },
      viaIR: false,
    },
  },
  // 本层不编译合约（ABI/字节码全部来自 Foundry out/），sources 指向空目录跳过编译。
  paths: {
    sources: "./sources",
    artifacts: "./artifacts",
    cache: "./cache",
  },
  networks: {
    anvil: {
      url: ANVIL_RPC,
      chainId: 1337,
      accounts: [PRIVATE_KEY],
    },
    testnet: {
      url: TESTNET_RPC,
      chainId: Number(process.env.TESTNET_CHAIN_ID || 0),
      accounts: TESTNET_RPC ? [PRIVATE_KEY] : [],
    },
  },
};

export default config;

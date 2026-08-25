// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IRNG} from "../interfaces/IRNG.sol";

/// @title RNGRouter - 可插拔随机数路由器
/// @notice 维护「用途 → Provider」映射，由管理员配置（未来可移交治理）。核心合约只依赖此路由，
///         任何场景都能在不改动核心逻辑的前提下切换随机源（技术设计 §2.3.2）。
contract RNGRouter is Ownable {
    /// @notice 用途分类常量（与玩法/技术设计对齐）
    bytes32 public constant CATEGORY_COMBAT = keccak256("COMBAT");
    bytes32 public constant CATEGORY_AFFIX = keccak256("AFFIX");
    bytes32 public constant CATEGORY_DROP = keccak256("DROP");

    /// @notice 用途 → Provider 地址（未配置则回落全局 Provider）
    mapping(bytes32 => address) public categoryProvider;
    /// @notice 全局默认 Provider
    address public globalProvider;

    event CategoryProviderSet(bytes32 indexed category, address indexed provider);
    event GlobalProviderSet(address indexed provider);

    constructor() Ownable(msg.sender) {}

    function setCategoryProvider(bytes32 category, address provider) external onlyOwner {
        require(provider != address(0), "RNGRouter: zero provider");
        categoryProvider[category] = provider;
        emit CategoryProviderSet(category, provider);
    }

    function setGlobalProvider(address provider) external onlyOwner {
        require(provider != address(0), "RNGRouter: zero provider");
        globalProvider = provider;
        emit GlobalProviderSet(provider);
    }

    /// @notice 按用途取随机数；未配置的用途回落全局 Provider
    function next(bytes32 category, bytes32 context) external returns (uint256) {
        address provider = categoryProvider[category];
        if (provider == address(0)) provider = globalProvider;
        require(provider != address(0), "RNGRouter: no provider");
        return IRNG(provider).next(category, context);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IRNG - 可插拔随机数接口
/// @notice 核心合约不直接触碰任何链上熵源，统一经此接口向 RNGRouter 要随机数。
///         同步取数（next）立即返回；异步取数（request）仅 VRF 类 Provider 需要。
interface IRNG {
    /// @param category 用途分类（COMBAT/AFFIX/DROP/MARKET），由 RNGRouter 路由
    /// @param context  调用方提供的上下文（房间号/回合号/角色等），参与熵混合
    function next(bytes32 category, bytes32 context) external returns (uint256);

    /// @dev 异步取数（仅 VRF 类 Provider 实现；同步 Provider 直接 revert）
    function request(bytes32 category, bytes32 context) external returns (uint256 requestId);
}

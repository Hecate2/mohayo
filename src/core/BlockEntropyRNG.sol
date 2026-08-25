// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IRNG} from "../interfaces/IRNG.sol";

/// @title BlockEntropyRNG - 默认同步随机源（游戏级随机数）
/// @notice 熵源 = keccak256(blockhash(n-1), PREVRANDAO, block.number, block.timestamp, category, context)。
///         纯视图逻辑、零 SSTORE，单次约 30 gas。信任假设：验证人仅有轻微偏置能力，对本游戏够用
///         （技术设计 §2.3.3）。eSpace 上 PREVRANDAO 语义需测试网实测，若存疑可退化。
contract BlockEntropyRNG is IRNG {
    function next(bytes32 category, bytes32 context) external view returns (uint256) {
        return uint256(
            keccak256(
                abi.encodePacked(
                    blockhash(block.number - 1),
                    block.prevrandao,
                    block.number,
                    block.timestamp,
                    category,
                    context
                )
            )
        );
    }

    function request(bytes32 category, bytes32 context) external pure returns (uint256) {
        category;
        context;
        revert("BlockEntropyRNG: sync only");
    }
}

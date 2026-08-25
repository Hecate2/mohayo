// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IRNG} from "../../src/interfaces/IRNG.sol";

/// @title MockRNG - 测试用确定性随机源
/// @notice 可播种（确定性序列）或固定值（强制特定结果，如必中/指定目标）。
///         测试通过 RNGRouter 把 COMBAT/AFFIX/DROP 全部路由到此源，保证可复现。
contract MockRNG is IRNG {
    uint256 public seed;
    uint256 public counter;
    uint256 public fixedValue;
    bool public useFixed;

    function setSeed(uint256 s) external {
        seed = s;
        counter = 0;
        useFixed = false;
    }

    function setFixed(uint256 v) external {
        fixedValue = v;
        useFixed = true;
    }

    function clearFixed() external {
        useFixed = false;
    }

    function next(bytes32, bytes32) external returns (uint256) {
        if (useFixed) return fixedValue;
        counter++;
        return uint256(keccak256(abi.encodePacked(seed, counter)));
    }

    function request(bytes32, bytes32) external pure returns (uint256) {
        revert("MockRNG: sync only");
    }
}

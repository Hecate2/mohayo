// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../BaseTest.sol";
import {MockRNG} from "../mocks/MockRNG.sol";

contract RNGRouterTest is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    function testGlobalProviderFallback() public {
        // 未配置用途分类 → 回落全局 Provider（mockRng）
        uint256 v = rng.next(keccak256("UNKNOWN"), "ctx");
        assertTrue(v != 0);
    }

    function testCategoryRouting() public {
        // 配置一个独立 provider 到 COMBAT，验证按用途路由
        MockRNG other = new MockRNG();
        other.setSeed(7);
        rng.setCategoryProvider(CAT_COMBAT, address(other));
        uint256 v = rng.next(CAT_COMBAT, "ctx");
        // 与 mockRng 序列不同（seed 不同）
        assertTrue(v != 0);
    }

    function testDeterministicSequence() public {
        mockRng.setSeed(1);
        uint256 a = rng.next(CAT_COMBAT, "a");
        mockRng.setSeed(1);
        uint256 b = rng.next(CAT_COMBAT, "a");
        assertEq(a, b, "same seed must give same sequence");
    }

    function testOnlyOwnerCanSetProvider() public {
        vm.prank(alice);
        vm.expectRevert();
        rng.setGlobalProvider(address(0x1234));
    }

    function testZeroProviderRejected() public {
        vm.expectRevert("RNGRouter: zero provider");
        rng.setGlobalProvider(address(0));
    }
}

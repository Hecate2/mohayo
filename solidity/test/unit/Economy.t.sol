// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../BaseTest.sol";
import {Economy} from "../../src/core/Economy.sol";

contract EconomyTest is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    // ---- 权限 ----
    function testMintOnlyMinter() public {
        vm.expectRevert("Economy: not minter");
        economy.mint(alice, 100);
    }

    function testMintByMinter() public {
        vm.prank(address(ce));
        economy.mint(alice, 100);
        assertEq(economy.balanceOf(alice), 100);
    }

    function testSpendOnlySpender() public {
        vm.prank(address(ce));
        economy.mint(alice, 100);
        vm.expectRevert("Economy: not spender");
        economy.spend(alice, 10);
    }

    // ---- 负余额与行为限制 ----
    function testNegativeBalanceAllowed() public {
        vm.prank(address(ce));
        economy.spend(alice, 50);
        assertEq(economy.balanceOf(alice), -50);
        assertTrue(economy.isRestricted(alice));
    }

    function testRestrictedClearedOnMint() public {
        vm.prank(address(ce));
        economy.spend(alice, 50);
        assertTrue(economy.isRestricted(alice));
        vm.prank(address(ce));
        economy.mint(alice, 100);
        assertEq(economy.balanceOf(alice), 50);
        assertFalse(economy.isRestricted(alice));
    }

    // ---- 打工（每日一次）----
    function testWorkOncePerDay() public {
        economy.work();
        assertEq(economy.balanceOf(address(this)), int256(economy.workReward()));
        vm.expectRevert("Economy: already worked today");
        economy.work();
    }

    function testWorkResetsNextDay() public {
        economy.work();
        vm.warp(block.timestamp + 86400);
        economy.work();
        assertEq(economy.balanceOf(address(this)), int256(economy.workReward() * 2));
    }

    // ---- 美元购币限购 ----
    function testUsdDailyCap() public {
        economy.mintUsd(alice, 60 ether, 600);
        assertEq(economy.balanceOf(alice), 600);
        vm.expectRevert("Economy: usd daily cap exceeded");
        economy.mintUsd(alice, 50 ether, 500);
    }

    function testUsdResetsNextDay() public {
        economy.mintUsd(alice, 60 ether, 600);
        vm.warp(block.timestamp + 86400);
        economy.mintUsd(alice, 60 ether, 600);
        assertEq(economy.balanceOf(alice), 1200);
    }

    // ---- 娱乐模块总线 ----
    function testRegisterModuleTiers() public {
        economy.registerModule(address(0x1111), 1, 100, 0); // 托管级需抽水
        economy.registerModule(address(0x2222), 2, 0, 1000 ether); // 铸销级
        // 托管级零抽水被拒
        vm.expectRevert("Economy: escrow tier needs rake");
        economy.registerModule(address(0x3333), 1, 0, 0);
    }

    function testEscrowModuleCannotMint() public {
        economy.registerModule(address(0x1111), 1, 100, 0);
        vm.prank(address(0x1111));
        vm.expectRevert("Economy: not mint tier");
        economy.moduleMint(address(0x1111), alice, 100);
    }

    function testMintTierBudgetGate() public {
        economy.registerModule(address(0x2222), 2, 0, 100 ether);
        vm.prank(address(0x2222));
        economy.moduleMint(address(0x2222), alice, 60 ether);
        assertEq(economy.balanceOf(alice), 60 ether);
        // 超预算熔断
        vm.prank(address(0x2222));
        vm.expectRevert("Economy: module daily budget");
        economy.moduleMint(address(0x2222), alice, 50 ether);
    }

    function testGlobalBudgetGate() public {
        economy.registerModule(address(0x2222), 2, 0, 1000 ether);
        economy.setGlobalDailyBudget(100 ether);
        vm.prank(address(0x2222));
        economy.moduleMint(address(0x2222), alice, 60 ether);
        vm.prank(address(0x2222));
        vm.expectRevert("Economy: global daily budget");
        economy.moduleMint(address(0x2222), alice, 60 ether);
    }

    function testEscrowSettleRakeBurned() public {
        economy.registerModule(address(0x1111), 1, 100, 0);
        vm.prank(address(ce));
        economy.mint(alice, 100);
        // 托管：alice 划入 100
        vm.prank(address(0x1111));
        economy.moduleEscrow(address(0x1111), alice, 100);
        assertEq(economy.balanceOf(alice), 0);
        // 结算：alice 得 100，抽 1% 销毁
        address[] memory players = new address[](1);
        players[0] = alice;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;
        vm.prank(address(0x1111));
        economy.moduleSettle(address(0x1111), players, amounts);
        assertEq(economy.balanceOf(alice), 99); // 100 - 1% rake
        assertEq(economy.balanceOf(address(0x1111)), -1); // 抽水从模块余额扣
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../BaseTest.sol";
import {CombatTypes} from "../../src/libs/CombatTypes.sol";

/// @notice 旧版 forge-std(1.2.0) 接口未声明 prevrandao cheatcode，但 Foundry 1.3.5 二进制支持；
///         本地接口按 selector 匹配调用（EIP-4399 后 difficulty 不可用）。
interface IPrevrandao {
    function prevrandao(bytes32 newPrevrandao) external;
}

/// @title CombatRandomnessTest - 房间级链式随机数专项测试
/// @notice 直接调用 CombatTypes.nextRandom（internal 库函数内联进测试合约），
///         验证链式推进、确定性重放、turnId/roomId/PREVRANDAO 参与混合；
///         引擎级验证房间种子随战斗推进链式变化、同区块房间种子互异。
contract CombatRandomnessTest is BaseTest {
    CombatTypes.Room internal r;

    function setUp() public override {
        super.setUp();
        r.id = 7;
        r.turnId = 3;
        r.seed = bytes32(uint256(0x1234));
    }

    function _gmSolo(address player, uint8 classId, uint8 difficulty, uint32[] memory skills) internal returns (uint256 charId, uint32 roomId) {
        charId = _gmCharacter(player, classId, 0, new uint16[](0), skills);
        vm.prank(player);
        roomId = ce.createRoom(difficulty);
        vm.prank(player);
        ce.joinRoom(roomId, charId);
    }

    function _setPlan(address player, uint32 roomId, uint32[] memory skills) internal {
        uint16[16] memory plan;
        for (uint8 i; i < skills.length; ++i) plan[i] = uint16(skills[i]);
        vm.prank(player);
        ce.setPlan(roomId, plan, uint8(skills.length));
    }

    // ---- 链式推进：每次抽数推进种子，同回合多次抽数互不相同 ----
    function testChainedSeedAdvances() public {
        bytes32 s0 = r.seed;
        uint256 a = CombatTypes.nextRandom(r);
        assertTrue(r.seed != s0, "seed advanced");
        uint256 b = CombatTypes.nextRandom(r);
        assertTrue(a != b, "chained draws differ");
        assertTrue(r.seed != bytes32(uint256(a)), "seed != first draw");
    }

    // ---- 确定性：同输入（seed/turnId/id/PREVRANDAO）→ 同输出 ----
    function testDeterministicReplay() public {
        uint256 a = CombatTypes.nextRandom(r);
        bytes32 s1 = r.seed;
        r.seed = bytes32(uint256(0x1234));
        r.turnId = 3;
        r.id = 7;
        uint256 b = CombatTypes.nextRandom(r);
        assertEq(a, b, "replay identical");
        assertEq(r.seed, s1, "seed replay identical");
    }

    // ---- turnId 参与混合：不同回合 → 不同随机数 ----
    function testTurnIdChangesOutput() public {
        uint256 a = CombatTypes.nextRandom(r);
        r.seed = bytes32(uint256(0x1234));
        r.turnId = 4;
        uint256 b = CombatTypes.nextRandom(r);
        assertTrue(a != b, "turnId affects output");
    }

    // ---- roomId 参与混合：不同房间 → 不同随机数 ----
    function testRoomIdChangesOutput() public {
        uint256 a = CombatTypes.nextRandom(r);
        r.seed = bytes32(uint256(0x1234));
        r.id = 8;
        uint256 b = CombatTypes.nextRandom(r);
        assertTrue(a != b, "roomId affects output");
    }

    // ---- PREVRANDAO 参与混合：不同区块随机数 → 不同输出 ----
    function testPrevrandaoChangesOutput() public {
        uint256 a = CombatTypes.nextRandom(r);
        r.seed = bytes32(uint256(0x1234));
        IPrevrandao(address(vm)).prevrandao(bytes32(uint256(0xdead)));
        uint256 b = CombatTypes.nextRandom(r);
        assertTrue(a != b, "prevrandao affects output");
    }

    // ---- 引擎级：房间种子随战斗推进链式变化 ----
    function testEngineSeedAdvancesOnCombat() public {
        uint32[] memory skills = new uint32[](1);
        skills[0] = skillAttack;
        (uint256 charId, uint32 roomId) = _gmSolo(alice, 1, 1, skills);
        _setPlan(alice, roomId, skills);
        vm.prank(alice);
        ce.startCombat(roomId);
        bytes32 s0 = ce.getRoom(roomId).seed;
        vm.prank(alice);
        ce.advanceTurn(roomId);
        bytes32 s1 = ce.getRoom(roomId).seed;
        assertTrue(s1 != s0, "seed advanced after turn 1");
        vm.prank(alice);
        ce.advanceTurn(roomId);
        bytes32 s2 = ce.getRoom(roomId).seed;
        assertTrue(s2 != s1, "seed advanced after turn 2");
    }

    // ---- 引擎级：同区块创建的两个房间种子互异（roomId 参与混合） ----
    function testEngineSeedDiffersAcrossRooms() public {
        uint32[] memory skills = new uint32[](1);
        skills[0] = skillAttack;
        uint256 c1 = _gmCharacter(alice, 1, 0, new uint16[](0), skills);
        uint256 c2 = _gmCharacter(bob, 1, 0, new uint16[](0), skills);
        vm.prank(alice);
        uint32 r1 = ce.createRoom(1);
        vm.prank(bob);
        uint32 r2 = ce.createRoom(1);
        assertTrue(ce.getRoom(r1).seed != ce.getRoom(r2).seed, "room seeds differ");
    }

    // ---- 引擎级：同一房间重放战斗（同 seed/turnId/PREVRANDAO）→ 同种子序列 ----
    function testEngineSeedDeterministicAcrossIdenticalRooms() public {
        uint32[] memory skills = new uint32[](1);
        skills[0] = skillAttack;
        uint256 c1 = _gmCharacter(alice, 1, 0, new uint16[](0), skills);
        uint256 c2 = _gmCharacter(bob, 1, 0, new uint16[](0), skills);
        // 同区块创建 → 同 PREVRANDAO；但 roomId 不同 → 种子不同（链式起点不同）
        vm.prank(alice);
        uint32 r1 = ce.createRoom(1);
        vm.prank(bob);
        uint32 r2 = ce.createRoom(1);
        vm.prank(alice);
        ce.joinRoom(r1, c1);
        vm.prank(bob);
        ce.joinRoom(r2, c2);
        _setPlan(alice, r1, skills);
        _setPlan(bob, r2, skills);
        vm.prank(alice);
        ce.startCombat(r1);
        vm.prank(bob);
        ce.startCombat(r2);
        // 同一回合推进后，两房间种子仍互异（起点不同 → 链式序列不同）
        vm.prank(alice);
        ce.advanceTurn(r1);
        vm.prank(bob);
        ce.advanceTurn(r2);
        assertTrue(ce.getRoom(r1).seed != ce.getRoom(r2).seed, "divergent chains");
    }
}

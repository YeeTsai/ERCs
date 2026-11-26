// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SerialConsolidations} from "../../contracts/utils/SerialConsolidations.sol";
import {SerialConsolidationsOracle} from "./SerialConsolidationsOracle.sol";

/// @dev Writes the same records into both SerialConsolidations and the version before the change
///      (SerialConsolidationsOracle), and compares the query results one by one.
contract ConsolidationsHarness {
    using SerialConsolidations for SerialConsolidations.Records;
    using SerialConsolidationsOracle for SerialConsolidationsOracle.Records;

    SerialConsolidations.Records internal _a;
    SerialConsolidationsOracle.Records internal _o;

    function add(uint256 oldStart, uint256 successor, uint256 len) external {
        _a.add(oldStart, successor, len);
        _o.add(oldStart, successor, len);
    }

    /// @dev Adds with prev (prev is the old start of another record added just before).
    function addAfter(uint256 oldStart, uint256 successor, uint256 len, uint256 prev) external {
        _a.add(oldStart, successor, len, prev);
        _o.add(oldStart, successor, len);
    }

    function floorKey(uint256 x) external view returns (bool f1, uint256 k1, bool f2, uint256 k2) {
        (f1, k1) = _a.floorKey(x);
        (f2, k2) = _o.floorKey(x);
    }

    function ceilKey(uint256 x, uint256 limit) external view returns (uint256, uint256) {
        return (_a.ceilKey(x, limit), _o.ceilKey(x, limit));
    }

    function runOf(uint256 k) external view returns (uint256 s, uint256 len) {
        return _a.runOf(k);
    }

    function runAtNew(uint256 serial, uint256 issued) external view returns (bool, uint256, uint256) {
        return _a.runAt(serial, issued);
    }

    function runAtOld(uint256 serial, uint256 issued) external view returns (bool, uint256, uint256) {
        return _o.runAt(serial, issued);
    }

    function successorsNew(uint256 start, uint256 end) external view returns (uint256[] memory, uint256[] memory) {
        return _a.successorsOf(start, end);
    }

    function successorsOld(uint256 start, uint256 end) external view returns (uint256[] memory, uint256[] memory) {
        return _o.successorsOf(start, end);
    }
}

/// @dev Differential test: random sets of keys mixing several magnitudes (dense, every 2^32 after 2^56, random gaps
///      of 2^8 to 2^48, random 127-bit values, near 2^127) are added one by one; then floor and ceiling lookups,
///      consolidatedRunAt and the successor query are compared near each key and at random positions.
contract SerialConsolidationsDiffTest is Test {
    ConsolidationsHarness internal h;
    uint256[] internal keys;
    uint256[] internal lens;
    uint256[] internal succs;
    uint256 internal issued;
    uint256 internal constant SUCC_BASE = 1 << 127;

    function setUp() public {
        h = new ConsolidationsHarness();
        issued = SUCC_BASE;
    }

    function _rand(uint256 seed, uint256 i) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, i)));
    }

    /// @dev The i-th candidate old start.
    function _candidate(uint256 seed, uint256 i, uint256 mode) internal view returns (uint256) {
        uint256 r = _rand(seed, i);
        uint256 r2 = _rand(seed, i + 1_000_000);
        if (mode == 0) return r % 4096;
        if (mode == 1) return (1 << 56) + (r % 512) * (1 << 32) + (r2 % 3);
        if (mode == 2) {
            uint256 last = keys.length == 0 ? (1 << 40) : keys[keys.length - 1];
            uint256 gap = (uint256(1) << (8 + r % 41)) + (r2 % 4096);
            uint256 v = last + gap;
            return v < SUCC_BASE ? v : r % SUCC_BASE;
        }
        if (mode == 3) return r % SUCC_BASE;
        if (mode == 4) return SUCC_BASE - 1 - (r % 100_000);
        // An existing successor (two generations)
        if (succs.length == 0) return r % 4096;
        return succs[r % succs.length] + (r2 % 2);
    }

    function _overlaps(uint256 a, uint256 len) internal view returns (bool) {
        for (uint256 i; i < keys.length; ++i) {
            if (a < keys[i] + lens[i] && keys[i] < a + len) return true;
        }
        return false;
    }

    function _build(uint256 seed, uint256 n, uint256 modeMask) internal {
        for (uint256 i; i < n; ++i) {
            uint256 mode = _rand(seed, i + 2_000_000) % 6;
            if ((modeMask >> mode) & 1 == 0) mode = 0;
            uint256 a = _candidate(seed, i, mode);
            uint256 len = 1 + (_rand(seed, i + 3_000_000) % 4 == 0 ? _rand(seed, i + 4_000_000) % 300 : 0);
            if (a >= SUCC_BASE && mode != 5) continue;
            if (a + len > issued || _overlaps(a, len)) continue;
            uint256 s = issued;
            issued += len;
            // Half with prev (the record added last, not necessarily smaller than a), half without
            if (keys.length != 0 && _rand(seed, i + 8_000_000) % 2 == 0) h.addAfter(a, s, len, keys[keys.length - 1]);
            else h.add(a, s, len);
            keys.push(a);
            lens.push(len);
            succs.push(s);
        }
    }

    function _checkPoint(uint256 x, uint256 limit) internal view {
        _checkFloor(x);
        (uint256 c1, uint256 c2) = h.ceilKey(x, limit);
        assertEq(c1, c2, "ceil key");
        (c1, c2) = h.ceilKey(x, type(uint256).max);
        assertEq(c1, c2, "ceil key, no limit");
        if (x < issued) _checkRunAt(x);
    }

    function _checkFloor(uint256 x) internal view {
        (bool f1, uint256 k1, bool f2, uint256 k2) = h.floorKey(x);
        assertEq(f1, f2, "floor found");
        if (f1) assertEq(k1, k2, "floor key");
    }

    function _checkRunAt(uint256 x) internal view {
        (bool a1, uint256 a2, uint256 a3) = h.runAtNew(x, issued);
        (bool b1, uint256 b2, uint256 b3) = h.runAtOld(x, issued);
        assertEq(a1, b1, "runAt consolidated");
        assertEq(a2, b2, "runAt successor");
        assertEq(a3, b3, "runAt length");
    }

    function _checkSuccessors(uint256 a, uint256 b) internal view {
        (uint256[] memory s1, uint256[] memory e1) = h.successorsNew(a, b);
        (uint256[] memory s2, uint256[] memory e2) = h.successorsOld(a, b);
        assertEq(s1, s2, "successor starts");
        assertEq(e1, e2, "successor ends");
    }

    function _checkAll(uint256 seed) internal view {
        uint256 n = keys.length;
        for (uint256 i; i < n; ++i) {
            uint256 k = keys[i];
            uint256 lim = k + 1 + (_rand(seed, i + 5_000_000) % (1 << 40));
            if (k != 0) _checkPoint(k - 1, lim);
            _checkPoint(k, lim);
            _checkPoint(k + 1, lim);
            _checkPoint(k + lens[i], lim);
            _checkPoint(k + lens[i] - 1, k + lens[i]);
            uint256 r = _rand(seed, i + 6_000_000);
            _checkPoint(r % issued, (r % issued) + (r >> 200));
            // Serials do not exceed 2^128 - 1, so queries also stay within this bound
            _checkPoint(uint128(r), type(uint256).max);
        }
        _checkPoint(0, 1);
        _checkPoint(type(uint128).max, type(uint256).max);
        // Successor queries: slices of random length starting near some key, and the whole span
        for (uint256 i; i < n && i < 24; ++i) {
            uint256 r = _rand(seed, i + 7_000_000);
            uint256 a = keys[r % n];
            if (r % 3 == 0 && a != 0) a -= 1;
            uint256 span = (r >> 128) % 4 == 0 ? (r >> 8) % (1 << 60) : 1 + (r >> 16) % 600;
            uint256 b = a + span;
            if (b > issued) b = issued;
            if (a < b) _checkSuccessors(a, b);
        }
        if (n != 0) _checkSuccessors(0, issued);
    }

    function testFuzz_matchesOracle(uint256 seed, uint8 n, uint8 modeMask) public {
        _build(seed, uint256(n) % 80, uint256(modeMask) | 1);
        _checkAll(seed);
    }

    function test_mixedLarge() public {
        _build(1, 250, 0x3f);
        _checkAll(1);
    }

    function test_denseLarge() public {
        _build(2, 600, 0x01);
        _checkAll(2);
    }

    function test_sparseLarge() public {
        _build(3, 400, 0x02);
        _checkAll(3);
    }

    function test_irregularGapsLarge() public {
        _build(4, 300, 0x04);
        _checkAll(4);
    }

    function test_generations() public {
        _build(5, 300, 0x21);
        _checkAll(5);
    }
}

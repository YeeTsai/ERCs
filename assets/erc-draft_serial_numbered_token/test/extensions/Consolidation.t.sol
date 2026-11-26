// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {IERCXXXX} from "../../contracts/spec/IERCXXXX.sol";
import {ERCXXXX} from "../../contracts/ERCXXXX.sol";
import {ERCXXXXConsolidation} from "../../contracts/extensions/ERCXXXXConsolidation.sol";
import {
    Rule,
    PresetBothConsolTuned,
    PresetBothConsolTunedStack,
    PresetBothStack,
    PresetCoreSorted
} from "../presets/Presets.sol";
import "../presets/Targets.sol";

/// @dev The consolidation module ERCXXXXConsolidation, checked clause by clause against "Consolidation" in the draft:
///      every revert of the argument checks, the assignment of new serials and the return value, the events,
///      consolidatedSpanAt, enumeration, and that balances, total supply and allowances do not change; the refusals
///      and the propagation in combination with the freezing extension ("Freezing and consolidation"); the refusals
///      and the classes in combination with the classification extension ("Classes and consolidation"). There is
///      one concrete contract for each combination that opens consolidation (at the end of the file); tests that use
///      freezing or classification are skipped on combinations that do not support them.
abstract contract ConsolidationBase is Test, TokenTarget {
    event SliceConsolidated(address indexed account, uint256 start, uint256 newStart, uint256 amount);
    event SliceFrozen(bytes32 indexed reason, uint256 start, uint256 amount);
    event SliceUnfrozen(bytes32 indexed reason, uint256 start, uint256 amount);
    event SliceClassified(uint256 start, uint256 amount, bytes32 classId);

    bytes32 internal constant TRANSFER_SIG = keccak256("Transfer(address,address,uint256)");
    bytes32 internal constant SERIAL_SIG = keccak256("SliceTransferred(address,address,uint256,uint256)");
    bytes32 internal constant CONSOL_SIG = keccak256("SliceConsolidated(address,uint256,uint256,uint256)");
    bytes32 internal constant FROZEN_SIG = keccak256("SliceFrozen(bytes32,uint256,uint256)");
    bytes32 internal constant UNFROZEN_SIG = keccak256("SliceUnfrozen(bytes32,uint256,uint256)");
    bytes32 internal constant CLASS_SIG = keccak256("SliceClassified(uint256,uint256,bytes32)");

    ITestToken internal t;
    bool internal hasFreeze;
    bool internal hasClass;
    address internal admin = makeAddr("admin");
    address internal A = makeAddr("A");
    address internal B = makeAddr("B");
    address internal X = makeAddr("X");
    bytes32 internal constant R1 = "r1";
    bytes32 internal constant R2 = "r2";
    bytes32 internal constant R3 = "r3";
    bytes32 internal constant W = "w";
    bytes32 internal constant N = "n";

    function setUp() public {
        bool consol;
        (t, hasFreeze, hasClass, consol) = _deployToken(admin);
        assertTrue(consol, "these tests need a token that opens consolidation");
        vm.startPrank(admin);
        if (hasFreeze) {
            t.setReasonInfo(R1, "Reason one", "");
            t.setReasonInfo(R2, "Reason two", "");
            t.setReasonInfo(R3, "Reason three", "");
        }
        if (hasClass) {
            t.defineClass(W, Rule.Allowlist, 0, "Designated recipients only", "");
            t.defineClass(N, Rule.None, 0, "Label", "");
        }
        vm.stopPrank();
    }

    // ───────────────────────── Helpers ─────────────────────────

    function _mint(address to, uint256 v) internal {
        vm.prank(admin);
        t.mint(to, v);
    }

    function _mintClass(address to, uint256 v, bytes32 c) internal {
        vm.prank(admin);
        t.mintWithClass(to, v, c);
    }

    function _freeze(uint256 s, uint256 a, bytes32 r) internal {
        vm.prank(admin);
        t.freezeSlice(s, a, r);
    }

    function _unfreeze(uint256 s, uint256 a, bytes32 r) internal {
        vm.prank(admin);
        t.unfreezeSlice(s, a, r);
    }

    /// @dev `who` receives k units that are not adjacent to one another: the serials base, base + 2, ... (the serials
    ///      in between go to X).
    function _scatter(address who, uint256 k) internal {
        for (uint256 i; i < k; ++i) {
            _mint(who, 1);
            _mint(X, 1);
        }
    }

    function _consolidate(address who, uint256[] memory s, uint256[] memory a) internal returns (uint256) {
        vm.prank(who);
        return t.consolidateSlices(s, a);
    }

    function _arr(uint256 x) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = x;
    }

    function _arr(uint256 x, uint256 y) internal pure returns (uint256[] memory r) {
        r = new uint256[](2);
        (r[0], r[1]) = (x, y);
    }

    function _arr(uint256 x, uint256 y, uint256 z) internal pure returns (uint256[] memory r) {
        r = new uint256[](3);
        (r[0], r[1], r[2]) = (x, y, z);
    }

    function _arr(uint256 x, uint256 y, uint256 z, uint256 w) internal pure returns (uint256[] memory r) {
        r = new uint256[](4);
        (r[0], r[1], r[2], r[3]) = (x, y, z, w);
    }

    /// @dev The serials held by `account`, expanded slice by slice through sliceAt into a mask over [0, size); also
    ///      checks that the enumerated slices are disjoint and not empty.
    function _held(address account, uint256 size) internal view returns (bool[] memory mask) {
        mask = new bool[](size);
        uint256 n = t.sliceCount(account);
        for (uint256 i; i < n; ++i) {
            (uint256 s, uint256 a) = t.sliceAt(account, i);
            assertGt(a, 0, "empty slice");
            for (uint256 x = s; x < s + a; ++x) {
                assertLt(x, size, "slice beyond expected space");
                assertFalse(mask[x], "overlapping slices");
                mask[x] = true;
            }
        }
    }

    function _assertHeldExactly(address account, uint256 size, uint256[] memory los, uint256[] memory his)
        internal
        view
    {
        bool[] memory m = _held(account, size);
        for (uint256 x; x < size; ++x) {
            bool want;
            for (uint256 k; k < los.length; ++k) {
                if (x >= los[k] && x < his[k]) want = true;
            }
            assertEq(m[x], want, string.concat("holding of serial ", vm.toString(x)));
        }
    }

    function _assertSpan(uint256 serial, bool c, uint256 succ, uint256 len) internal view {
        (bool c2, uint256 s2, uint256 l2) = t.consolidatedSpanAt(serial);
        string memory w = string.concat("consolidatedSpanAt(", vm.toString(serial), ")");
        assertEq(c2, c, string.concat(w, ".consolidated"));
        assertEq(s2, succ, string.concat(w, ".successor"));
        assertEq(l2, len, string.concat(w, ".length"));
    }

    /// @dev The data of the events with signature `sig` in the logs of this call (only those the token emitted).
    function _datas(Vm.Log[] memory logs, bytes32 sig) internal view returns (bytes[] memory out) {
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(t) && logs[i].topics[0] == sig) ++n;
        }
        out = new bytes[](n);
        n = 0;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(t) && logs[i].topics[0] == sig) out[n++] = logs[i].data;
        }
    }

    function _assertNoTransferEvents(Vm.Log[] memory logs) internal view {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(t)) continue;
            assertTrue(logs[i].topics[0] != TRANSFER_SIG, "consolidation emitted Transfer");
            assertTrue(logs[i].topics[0] != SERIAL_SIG, "consolidation emitted SliceTransferred");
        }
    }

    /// @dev The set of serials covered by the freeze or unfreeze events (selected by `sig`); checks that the reason of
    ///      every event is `reason`.
    function _freezeMask(Vm.Log[] memory logs, bytes32 sig, bytes32 reason, uint256 size)
        internal
        view
        returns (bool[] memory mask, uint256 events)
    {
        mask = new bool[](size);
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(t) || logs[i].topics[0] != sig) continue;
            assertEq(logs[i].topics[1], reason, "event reason");
            (uint256 s, uint256 a) = abi.decode(logs[i].data, (uint256, uint256));
            assertGt(a, 0, "event amount");
            for (uint256 x = s; x < s + a; ++x) {
                mask[x] = true;
            }
            ++events;
        }
    }

    function _assertMask(bool[] memory mask, uint256[] memory serials, string memory what) internal pure {
        for (uint256 x; x < mask.length; ++x) {
            bool want;
            for (uint256 k; k < serials.length; ++k) {
                if (serials[k] == x) want = true;
            }
            assertEq(mask[x], want, string.concat(what, " at serial ", vm.toString(x)));
        }
    }

    function _reasonAmount(address account, bytes32 reason) internal view returns (uint256 amount, uint256 entries) {
        (bytes32[] memory rs, uint256[] memory am) = t.freezeReasonsOf(account);
        entries = rs.length;
        for (uint256 i; i < rs.length; ++i) {
            if (rs[i] == reason) amount = am[i];
        }
    }

    // ───────────────────────── ERC-165 ─────────────────────────

    /// @dev Consolidation belongs to the core interface: a token that opens consolidation still declares the id of the
    ///      core, and there is no separate id for consolidation.
    function test_supportsInterface() public view {
        assertTrue(t.supportsInterface(type(IERCXXXX).interfaceId));
        assertEq(type(IERCXXXX).interfaceId, bytes4(0x668ccf00));
    }

    // ───────────────────────── Consolidation: argument checks (clause 4 of "Consolidation") ─────────────────────────

    function test_parameterReverts() public {
        _scatter(A, 3); // A: 0, 2, 4; X: 1, 3, 5
        _mint(A, 4); // A: 6..9
        vm.startPrank(A);
        vm.expectRevert(ERCXXXX.ERCXXXXInvalidRanges.selector);
        t.consolidateSlices(new uint256[](0), new uint256[](0));
        vm.expectRevert(ERCXXXX.ERCXXXXInvalidRanges.selector);
        t.consolidateSlices(_arr(0, 2), _arr(1));
        vm.expectRevert(ERCXXXX.ERCXXXXInvalidRanges.selector);
        t.consolidateSlices(_arr(0), _arr(1, 1));
        vm.expectRevert(ERCXXXX.ERCXXXXInvalidRanges.selector);
        t.consolidateSlices(_arr(0, 2), _arr(1, 0));
        // overlapping
        vm.expectRevert(ERCXXXX.ERCXXXXInvalidRanges.selector);
        t.consolidateSlices(_arr(6, 7), _arr(2, 2));
        // not in ascending order of start
        vm.expectRevert(ERCXXXX.ERCXXXXInvalidRanges.selector);
        t.consolidateSlices(_arr(2, 0), _arr(1, 1));
        // not held by the caller: another account's, partly another account's, not yet issued, partly not yet
        // issued; the error names the first slice that contains such a serial
        vm.expectRevert(abi.encodeWithSelector(IERCXXXX.ERCXXXXNotHeld.selector, A, 1, 1));
        t.consolidateSlices(_arr(0, 1), _arr(1, 1));
        vm.expectRevert(abi.encodeWithSelector(IERCXXXX.ERCXXXXNotHeld.selector, A, 4, 3));
        t.consolidateSlices(_arr(0, 4), _arr(1, 3));
        vm.expectRevert(abi.encodeWithSelector(IERCXXXX.ERCXXXXNotHeld.selector, A, 10, 1));
        t.consolidateSlices(_arr(0, 10), _arr(1, 1));
        vm.expectRevert(abi.encodeWithSelector(IERCXXXX.ERCXXXXNotHeld.selector, A, 8, 5));
        t.consolidateSlices(_arr(8), _arr(5));
        // the error in the earlier slice is found before the form error in the arrays
        vm.expectRevert(abi.encodeWithSelector(IERCXXXX.ERCXXXXNotHeld.selector, A, 20, 1));
        t.consolidateSlices(_arr(20, 30), _arr(1, 0));
        vm.stopPrank();
        // destroyed serials
        vm.prank(A);
        t.burnSlices(_arr(4), _arr(1));
        vm.prank(A);
        vm.expectRevert(abi.encodeWithSelector(IERCXXXX.ERCXXXXNotHeld.selector, A, 4, 1));
        t.consolidateSlices(_arr(0, 4), _arr(1, 1));
        // consolidated serials
        _consolidate(A, _arr(0), _arr(1));
        vm.prank(A);
        vm.expectRevert(abi.encodeWithSelector(IERCXXXX.ERCXXXXNotHeld.selector, A, 0, 1));
        t.consolidateSlices(_arr(0), _arr(1));
        // an account with no holdings at all
        vm.prank(B);
        vm.expectRevert(abi.encodeWithSelector(IERCXXXX.ERCXXXXNotHeld.selector, B, 6, 1));
        t.consolidateSlices(_arr(6), _arr(1));
        // none of the failed calls above changed anything
        assertEq(t.balanceOf(A), 6);
        assertEq(t.serialsIssued(), 11);
    }

    // ───────────────────────── Assignment, return value, events, state (clauses 1 to 6) ─────────────────────────

    function test_allocationEventsAndState() public {
        _scatter(A, 3); // A: 0, 2, 4; X: 1, 3, 5
        _mint(A, 4); // A: 6..9
        _mint(B, 2); // B: 10, 11
        vm.prank(A);
        t.approve(B, 7);
        uint256 supply = t.totalSupply();
        vm.recordLogs();
        uint256 n = _consolidate(A, _arr(2, 6), _arr(1, 3));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        // clause 1: returns serialsIssued() from before the call, assigns in ascending order of the old serials
        assertEq(n, 12, "newStart");
        assertEq(t.serialsIssued(), 16, "serialsIssued grows by v");
        // clause 5: exactly one SliceConsolidated for each i, in the order of i
        bytes[] memory ev = _datas(logs, CONSOL_SIG);
        assertEq(ev.length, 2, "one SliceConsolidated per slice");
        uint256 seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(t) || logs[i].topics[0] != CONSOL_SIG) continue;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), A, "SliceConsolidated.account");
            (uint256 s, uint256 ns, uint256 a) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            if (seen == 0) assertEq(abi.encode(s, ns, a), abi.encode(uint256(2), uint256(12), uint256(1)));
            else assertEq(abi.encode(s, ns, a), abi.encode(uint256(6), uint256(13), uint256(3)));
            ++seen;
        }
        // clause 6: no Transfer and no SliceTransferred
        _assertNoTransferEvents(logs);
        // clauses 2 and 3
        assertEq(t.balanceOf(A), 7, "balance unchanged");
        assertEq(t.balanceOf(B), 2);
        assertEq(t.balanceOf(X), 3);
        assertEq(t.totalSupply(), supply, "totalSupply unchanged");
        assertEq(t.allowance(A, B), 7, "allowance unchanged");
        _assertHeldExactly(A, 16, _arr(0, 4, 9, 12), _arr(1, 5, 10, 16));
        _assertHeldExactly(B, 16, _arr(10), _arr(12));
        _assertHeldExactly(X, 16, _arr(1, 3, 5), _arr(2, 4, 6));
        // the new serials can be transferred by serial, the old ones cannot (a consolidated serial is held by no one)
        vm.prank(A);
        vm.expectRevert(abi.encodeWithSelector(IERCXXXX.ERCXXXXNotHeld.selector, A, 6, 1));
        t.transferSlices(B, _arr(6), _arr(1));
        vm.prank(A);
        t.transferSlices(B, _arr(13), _arr(2));
        assertEq(t.balanceOf(B), 4);
        // after the consolidation, transfers by amount work as usual
        vm.prank(A);
        t.transfer(B, 5);
        assertEq(t.balanceOf(A), 0);
        assertEq(t.totalSupply(), supply);
    }

    /// @dev Adjacent slices, given separately: each i still has its own event; they become one record, and the query
    ///      returns the whole span.
    function test_adjacentSlicesGivenSeparately() public {
        _mint(A, 10); // 0..9
        _mint(X, 1);
        vm.recordLogs();
        uint256 n = _consolidate(A, _arr(0, 3, 4), _arr(3, 1, 2));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(n, 11);
        assertEq(_datas(logs, CONSOL_SIG).length, 3);
        _assertSpan(0, true, 11, 6);
        _assertSpan(3, true, 14, 3);
        _assertSpan(5, true, 16, 1);
        _assertSpan(6, false, 0, 11); // none of 6..16 is consolidated
        _assertHeldExactly(A, 17, _arr(6, 11), _arr(10, 17));
    }

    // ───────────────────────── Queries on consolidation records (clauses 9 to 11) ─────────────────────────

    function test_consolidatedSpanAt() public {
        _scatter(A, 3); // A: 0, 2, 4; X: 1, 3, 5
        _mint(A, 4); // A: 6..9
        // when nothing is consolidated
        _assertSpan(0, false, 0, 10);
        _assertSpan(9, false, 0, 1);
        _assertSpan(10, false, 0, 0);
        _consolidate(A, _arr(2, 6), _arr(1, 3)); // 2 -> 10, 6..8 -> 11..13
        _assertSpan(0, false, 0, 2);
        _assertSpan(1, false, 0, 1);
        _assertSpan(2, true, 10, 1);
        _assertSpan(3, false, 0, 3);
        _assertSpan(6, true, 11, 3);
        _assertSpan(7, true, 12, 2);
        _assertSpan(8, true, 13, 1);
        _assertSpan(9, false, 0, 5); // 9..13; nothing after 13 is issued yet
        _assertSpan(13, false, 0, 1);
        _assertSpan(14, false, 0, 0); // not issued yet
        _assertSpan(type(uint256).max, false, 0, 0);
        // a destroyed serial is not consolidated
        vm.prank(A);
        t.burnSlices(_arr(4), _arr(1));
        _assertSpan(4, false, 0, 2);
        // records of different consolidations: when they follow immediately in both the old serials and the
        // successors, the query returns them joined into one span
        _mint(A, 10); // 14..23
        uint256 n1 = _consolidate(A, _arr(14), _arr(5)); // 14..18 -> 24..28
        uint256 n2 = _consolidate(A, _arr(19), _arr(5)); // 19..23 -> 29..33
        assertEq(n1, 24);
        assertEq(n2, 29);
        _assertSpan(14, true, 24, 10);
        _assertSpan(17, true, 27, 7);
        _assertSpan(19, true, 29, 5);
        // a successor is consolidated again: follow the queries to the end
        uint256 n3 = _consolidate(A, _arr(24), _arr(3)); // 24..26 -> 34..36
        // 14..23 -> 24..33 and 24..26 -> 34..36 follow immediately (the successor of serial 24 is 34 = 24 + 10),
        // so they form one span
        _assertSpan(14, true, 24, 13);
        _assertSpan(19, true, 29, 8);
        _assertSpan(24, true, 34, 3);
        _assertSpan(27, false, 0, 10); // none of 27..36 is consolidated (34..36 were just issued); from 37 on not issued
        assertEq(n3, 34);
        // records whose old serials are adjacent but whose successors are not are not joined
        _mint(A, 4); // 37..40
        _consolidate(A, _arr(37), _arr(2)); // 37,38 -> 41,42
        _mint(X, 1); // 43
        _consolidate(A, _arr(39), _arr(2)); // 39,40 -> 44,45
        _assertSpan(37, true, 41, 2);
        _assertSpan(39, true, 44, 2);
    }

    /// @dev Many records that follow immediately (the old serials are adjacent and so are the successors; they come
    ///      from different consolidations): one query joins at most 32 more records after the record that
    ///      contains the serial, and the span returned is shorter than the longest one but still satisfies clause 9; a
    ///      caller that continues querying from the end of the returned span reaches the end of the whole span.
    function test_consolidatedSpanAtCapsTheRecordsRead() public {
        uint256 k = 40;
        _mint(A, k); // 0..39
        for (uint256 i; i < k; ++i) {
            _consolidate(A, _arr(i), _arr(1)); // i -> 40 + i, one record each
        }
        // 40 adjacent records of 1 serial each: starting from 0, at most 1 + 32 records are joined
        _assertSpan(0, true, 40, 33);
        _assertSpan(6, true, 46, 33);
        _assertSpan(7, true, 47, 33);
        _assertSpan(8, true, 48, 32); // 8..39 are only 32 records
        _assertSpan(39, true, 79, 1);
        _assertSpan(40, false, 0, 40); // none of 40..79 is consolidated
        // continuing the queries from any serial, every result satisfies clause 9 and the end of the whole span is
        // reached
        for (uint256 start; start < k; start += 5) {
            uint256 x = start;
            uint256 calls;
            while (x < k) {
                (bool c, uint256 succ, uint256 len) = t.consolidatedSpanAt(x);
                assertTrue(c);
                assertEq(succ, 40 + x);
                assertGe(len, 1);
                assertLe(x + len, k, "the span stays inside the consolidated serials");
                x += len;
                ++calls;
            }
            assertEq(x, k);
            assertLe(calls, 2);
        }
        // when every record is longer, the truncated span is longer too: it is truncated by number of records, not
        // by number of serials
        _mint(A, 3 * k); // 80..199
        for (uint256 i; i < k; ++i) {
            _consolidate(A, _arr(80 + 3 * i), _arr(3)); // 3 serials each, one record
        }
        _assertSpan(80, true, 200, 99); // 33 records x 3
        _assertSpan(81, true, 201, 98);
    }

    // ───────────────────────── Units stored in different piles ─────────────────────────

    /// @dev The named serials can be spread over several piles (a class pile; the default pile, for units whose class
    ///      was set after receipt; the frozen pile, for units moved there after a freeze and unfrozen afterwards);
    ///      the consolidation takes them all out and puts the new serials in the piles where they belong.
    function test_slicesInSeveralPiles() public {
        vm.skip(!hasFreeze);
        _scatter(A, 6); // A: 0, 2, 4, 6, 8, 10
        _mint(A, 5); // A: 12..16
        // freeze 0 and 2, a transfer moves them into the frozen pile, then unfreeze
        _freeze(0, 3, R1);
        vm.prank(A);
        t.transfer(B, 1);
        vm.prank(admin);
        t.tidySlices(A, bytes32(0), 100);
        _unfreeze(0, 3, R1);
        uint256 bal = t.balanceOf(A);
        uint256 n = t.serialsIssued();
        _consolidate(A, _arr(0, 2, 4, 6), _arr(1, 1, 1, 1));
        assertEq(t.balanceOf(A), bal);
        bool[] memory m = _held(A, n + 4);
        for (uint256 x = n; x < n + 4; ++x) {
            assertTrue(m[x], "new serial held");
        }
        assertFalse(m[0] || m[2] || m[4] || m[6], "old serials not held");
        assertEq(t.transferableBalanceOf(A, B), bal, "all transferable");
        vm.prank(A);
        t.transfer(B, bal);
        assertEq(t.sliceCount(A), 0, "no empty slices left behind");
    }

    // ───────────────────────── Serial space ─────────────────────────

    function test_issuanceOverflow() public {
        _mint(X, type(uint128).max - 15);
        _mint(A, 10); // serials 2^128 - 15 .. 2^128 - 6; only 5 serials are left after them
        uint256 s = type(uint128).max - 15;
        vm.prank(A);
        vm.expectRevert(
            abi.encodeWithSelector(ERCXXXX.ERCXXXXIssuanceOverflow.selector, type(uint128).max - 5, 10)
        );
        t.consolidateSlices(_arr(s), _arr(10));
        // a consolidation that fits still succeeds
        uint256 n = _consolidate(A, _arr(s, s + 5), _arr(2, 3));
        assertEq(n, type(uint128).max - 5);
        assertEq(t.serialsIssued(), type(uint128).max);
        _assertSpan(s, true, n, 2);
        _assertSpan(s + 5, true, n + 2, 3);
        _assertSpan(s + 2, false, 0, 3);
        _assertSpan(n, false, 0, 5);
    }

    // ───────────────────────── Freezing and consolidation ─────────────────────────

    /// @dev Clause 1: frozen serials cannot be consolidated; the error names the slice that contains a frozen serial.
    function test_frozenCannotBeConsolidated() public {
        vm.skip(!hasFreeze);
        _scatter(A, 4); // A: 0, 2, 4, 6
        _freeze(4, 1, R1);
        vm.startPrank(A);
        vm.expectRevert(abi.encodeWithSelector(IERCXXXX.ERCXXXXNotConsolidatable.selector, A, 4, 1));
        t.consolidateSlices(_arr(0, 2, 4, 6), _arr(1, 1, 1, 1));
        vm.expectRevert(abi.encodeWithSelector(IERCXXXX.ERCXXXXNotConsolidatable.selector, A, 4, 1));
        t.consolidateSlices(_arr(4, 6), _arr(1, 1));
        // a frozen serial not held by the caller: not held is reported first
        vm.expectRevert(abi.encodeWithSelector(IERCXXXX.ERCXXXXNotHeld.selector, A, 5, 1));
        t.consolidateSlices(_arr(0, 5), _arr(1, 1));
        vm.stopPrank();
        _freeze(5, 1, R1); // X's serial 5
        vm.prank(A);
        vm.expectRevert(abi.encodeWithSelector(IERCXXXX.ERCXXXXNotHeld.selector, A, 5, 1));
        t.consolidateSlices(_arr(0, 5), _arr(1, 1));
        // the rest can be consolidated
        _consolidate(A, _arr(0, 2, 6), _arr(1, 1, 1));
        // after the unfreeze, so can this one
        _unfreeze(4, 1, R1);
        _consolidate(A, _arr(4), _arr(1));
        assertEq(t.balanceOf(A), 4);
    }

    /// @dev Clauses 2 and 4: freezing all of an old slice, part of one, and a slice that spans several records; the
    ///      successors are frozen, and SliceFrozen is emitted for them.
    function test_freezePropagates() public {
        vm.skip(!hasFreeze);
        _scatter(A, 4); // A: 0, 2, 4, 6; X: 1, 3, 5, 7
        _consolidate(A, _arr(0, 2, 4, 6), _arr(1, 1, 1, 1)); // -> 8, 9, 10, 11 (four records)
        _mint(A, 3); // 12..14

        // a slice that spans four records
        vm.recordLogs();
        _freeze(0, 7, R1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (bool[] memory fm, uint256 events) = _freezeMask(logs, FROZEN_SIG, R1, 15);
        uint256[] memory expect = new uint256[](11);
        for (uint256 i; i < 7; ++i) {
            expect[i] = i;
        }
        (expect[7], expect[8], expect[9], expect[10]) = (8, 9, 10, 11);
        _assertMask(fm, expect, "SliceFrozen coverage");
        assertEq(events, 2, "the call's slice, then the successors merged into one event");
        (uint256 firstStart, uint256 firstAmount) = abi.decode(_datas(logs, FROZEN_SIG)[0], (uint256, uint256));
        assertEq(firstStart, 0, "first event is the call's own slice");
        assertEq(firstAmount, 7);
        assertEq(t.frozenBalanceOf(A), 4);
        assertEq(t.frozenBalanceOf(X), 3);
        (uint256 amt, uint256 entries) = _reasonAmount(A, R1);
        assertEq(amt, 4);
        assertEq(entries, 1);
        (bool f, uint256 len) = t.frozenSpanAt(8);
        assertTrue(f);
        assertEq(len, 4);
        (f, len) = t.frozenSpanAt(12);
        assertFalse(f);
        // the successors reached by propagation cannot be transferred out
        assertEq(t.transferableBalanceOf(A, B), 3);
        vm.prank(A);
        vm.expectRevert(abi.encodeWithSelector(IERCXXXX.ERCXXXXNotTransferable.selector, A, B, 9, 1));
        t.transferSlices(B, _arr(9), _arr(1));
        vm.prank(A);
        vm.expectRevert();
        t.transfer(B, 4);

        // part: serials 2..4 -> successors 9, 10
        vm.recordLogs();
        _freeze(2, 3, R2);
        logs = vm.getRecordedLogs();
        (fm, events) = _freezeMask(logs, FROZEN_SIG, R2, 15);
        uint256[] memory part = new uint256[](5);
        (part[0], part[1], part[2], part[3], part[4]) = (2, 3, 4, 9, 10);
        _assertMask(fm, part, "partial freeze coverage");
        assertEq(events, 2);
        (amt,) = _reasonAmount(A, R2);
        assertEq(amt, 2);
        (amt, entries) = _reasonAmount(A, R1);
        assertEq(amt, 4);
        assertEq(entries, 2, "two reasons on A");

        // clause 3: an unfreeze propagates in the same way
        vm.recordLogs();
        _unfreeze(0, 7, R1);
        logs = vm.getRecordedLogs();
        (fm, events) = _freezeMask(logs, UNFROZEN_SIG, R1, 15);
        _assertMask(fm, expect, "SliceUnfrozen coverage");
        assertEq(events, 2);
        assertEq(t.frozenBalanceOf(A), 2, "9 and 10 still frozen for r2");
        (amt, entries) = _reasonAmount(A, R1);
        assertEq(amt, 0);
        assertEq(entries, 1);
        assertEq(t.transferableBalanceOf(A, B), 5);
        // freezing a successor itself does not propagate back
        _freeze(11, 1, R3);
        (f,) = t.frozenSpanAt(6);
        assertFalse(f, "freezing a successor does not freeze the old serial");
    }

    /// @dev Two and three generations: 0 -> 4 -> 6 -> 8, 2 -> 5 -> 7. A freeze from any generation propagates toward
    ///      the successors to the end, not back.
    function test_freezeAcrossGenerations() public {
        vm.skip(!hasFreeze);
        _scatter(A, 2); // A: 0, 2; X: 1, 3
        _consolidate(A, _arr(0, 2), _arr(1, 1)); // 0 -> 4, 2 -> 5
        _consolidate(A, _arr(4), _arr(1)); // 4 -> 6
        _consolidate(A, _arr(5), _arr(1)); // 5 -> 7
        _consolidate(A, _arr(6), _arr(1)); // 6 -> 8
        _assertHeldExactly(A, 9, _arr(7), _arr(9));
        _assertSpan(0, true, 4, 1);
        _assertSpan(2, true, 5, 1);
        // 4 -> 6, 5 -> 7 and 6 -> 8 come from three consolidations; the old serials are adjacent and so are the
        // successors, so they form one span
        _assertSpan(4, true, 6, 3);
        _assertSpan(5, true, 7, 2);
        _assertSpan(6, true, 8, 1);
        _assertSpan(7, false, 0, 2);

        // three generations
        vm.recordLogs();
        _freeze(0, 1, R1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (bool[] memory fm, uint256 events) = _freezeMask(logs, FROZEN_SIG, R1, 9);
        _assertMask(fm, _arr(0, 4, 6, 8), "three generations");
        assertEq(events, 4);
        assertEq(t.frozenBalanceOf(A), 1);
        (bool f,) = t.frozenSpanAt(2);
        assertFalse(f);

        // freezing from the middle generation: only toward the successors
        vm.recordLogs();
        _freeze(5, 1, R2);
        logs = vm.getRecordedLogs();
        (fm, events) = _freezeMask(logs, FROZEN_SIG, R2, 9);
        _assertMask(fm, _arr(5, 7), "from the middle generation");
        (f,) = t.frozenSpanAt(2);
        assertFalse(f, "not backwards");
        assertEq(t.frozenBalanceOf(A), 2);
        assertEq(t.transferableBalanceOf(A, B), 0);

        // the frozen slice contains both old serials and their successors: successors inside the slice get no
        // extra event
        vm.recordLogs();
        _freeze(0, 9, R3);
        logs = vm.getRecordedLogs();
        (fm, events) = _freezeMask(logs, FROZEN_SIG, R3, 9);
        assertEq(events, 1, "successors inside the frozen slice need no extra event");
        // the successors of part of the slice lie outside the slice
        vm.recordLogs();
        _unfreeze(0, 5, R3);
        logs = vm.getRecordedLogs();
        (fm, events) = _freezeMask(logs, UNFROZEN_SIG, R3, 9);
        for (uint256 x; x < 9; ++x) {
            assertTrue(fm[x], "unfreeze covers 0..4 and reaches 6, 7 and 8");
        }

        // unfreezing the middle generation: the earlier generation is not affected
        _unfreeze(4, 1, R1);
        (f,) = t.frozenSpanAt(0);
        assertTrue(f, "0 stays frozen for r1");
        (f,) = t.frozenSpanAt(8);
        assertFalse(f, "8 unfrozen through 4 -> 6 -> 8");
        (uint256 amt, uint256 entries) = _reasonAmount(A, R2);
        assertEq(amt, 1);
        assertEq(entries, 1);
        assertEq(t.frozenBalanceOf(A), 1, "7 frozen for r2");
    }

    /// @dev When the successors of one freeze are not adjacent to one another (they come from different
    ///      consolidations), each gets its own event; the events are in ascending order of serial.
    function test_freezeSuccessorsFromSeparateConsolidations() public {
        vm.skip(!hasFreeze);
        _scatter(A, 3); // A: 0, 2, 4
        _consolidate(A, _arr(4), _arr(1)); // 4 -> 6
        _mint(X, 1); // 7
        _consolidate(A, _arr(0), _arr(1)); // 0 -> 8
        _mint(X, 1); // 9
        _consolidate(A, _arr(2), _arr(1)); // 2 -> 10
        vm.recordLogs();
        _freeze(0, 5, R1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes[] memory ev = _datas(logs, FROZEN_SIG);
        assertEq(ev.length, 4);
        uint256[4] memory starts = [uint256(0), 6, 8, 10];
        uint256[4] memory amounts = [uint256(5), 1, 1, 1];
        for (uint256 i; i < 4; ++i) {
            (uint256 s, uint256 a) = abi.decode(ev[i], (uint256, uint256));
            assertEq(s, starts[i]);
            assertEq(a, amounts[i]);
        }
        assertEq(t.frozenBalanceOf(A), 3);
        assertEq(t.frozenBalanceOf(X), 2);
    }

    /// @dev Two generations 0 -> 4 -> 6, and 2 -> 5; A holds 5, 6 and 7.
    function _twoGenerations() internal {
        _scatter(A, 2); // A: 0, 2; X: 1, 3
        _consolidate(A, _arr(0, 2), _arr(1, 1)); // 0 -> 4, 2 -> 5
        _consolidate(A, _arr(4), _arr(1)); // 4 -> 6
        _mint(A, 1); // 7
        _assertHeldExactly(A, 8, _arr(5), _arr(8));
    }

    function _assertFrozen(uint256 serial, bool want, string memory what) internal view {
        (bool f,) = t.frozenSpanAt(serial);
        assertEq(f, want, what);
    }

    /// @dev Freezing for one reason along two paths: first the old serial is frozen (which propagates to the
    ///      successors of every generation), then the successors are frozen directly; then only the old serial is
    ///      unfrozen. Clause 1 of "Freezing and unfreezing": what is recorded per reason is whether each serial is
    ///      frozen, not how many times it was frozen, so the two direct freezes of the successors leave nothing
    ///      behind. Clause 3 of "Freezing and consolidation": after the old serial is unfrozen, the successors of
    ///      every generation are no longer frozen for this reason.
    function test_freezeTwoPathsThenUnfreezeOld() public {
        vm.skip(!hasFreeze);
        _twoGenerations();
        _freeze(0, 1, R1);
        _assertFrozen(4, true, "4 frozen through 0");
        _assertFrozen(6, true, "6 frozen through 0 -> 4");
        assertEq(t.frozenBalanceOf(A), 1);
        (uint256 amt, uint256 entries) = _reasonAmount(A, R1);
        assertEq(amt, 1);
        assertEq(entries, 1);

        // freezing the successors directly: the state does not change, and nothing is counted twice
        vm.recordLogs();
        _freeze(6, 1, R1);
        (bool[] memory fm, uint256 events) = _freezeMask(vm.getRecordedLogs(), FROZEN_SIG, R1, 8);
        _assertMask(fm, _arr(6), "freezing the successor directly");
        assertEq(events, 1, "6 has no successor");
        _freeze(4, 1, R1);
        assertEq(t.frozenBalanceOf(A), 1, "no double counting");
        (amt, entries) = _reasonAmount(A, R1);
        assertEq(amt, 1, "no double counting per reason");
        assertEq(entries, 1);
        assertEq(t.transferableBalanceOf(A, B), 2);

        // unfreezing only the old serial: propagates to 4 and 6, and neither is frozen for r1 any longer
        vm.recordLogs();
        _unfreeze(0, 1, R1);
        (fm, events) = _freezeMask(vm.getRecordedLogs(), UNFROZEN_SIG, R1, 8);
        _assertMask(fm, _arr(0, 4, 6), "SliceUnfrozen covers every generation");
        _assertFrozen(0, false, "0 unfrozen");
        _assertFrozen(4, false, "4 unfrozen although it was also frozen directly");
        _assertFrozen(6, false, "6 unfrozen although it was also frozen directly");
        assertEq(t.frozenBalanceOf(A), 0);
        (amt, entries) = _reasonAmount(A, R1);
        assertEq(amt, 0);
        assertEq(entries, 0, "no reason left on A");
        assertEq(t.transferableBalanceOf(A, B), 3);
    }

    /// @dev The other way round: after freezing along two paths, only the successor is unfrozen. An unfreeze
    ///      propagates only toward the successors, so the old serial (and the middle generation) stay frozen for this
    ///      reason, while the unfrozen successor is no longer frozen, although its old serials still are. A later
    ///      freeze of the old serial propagates to this successor again.
    function test_freezeTwoPathsThenUnfreezeSuccessor() public {
        vm.skip(!hasFreeze);
        _twoGenerations();
        _freeze(0, 1, R1);
        _freeze(6, 1, R1);
        vm.recordLogs();
        _unfreeze(6, 1, R1);
        (bool[] memory fm, uint256 events) = _freezeMask(vm.getRecordedLogs(), UNFROZEN_SIG, R1, 8);
        _assertMask(fm, _arr(6), "unfreezing the successor does not reach back");
        assertEq(events, 1);
        _assertFrozen(0, true, "0 stays frozen for r1");
        _assertFrozen(4, true, "4 stays frozen for r1");
        _assertFrozen(6, false, "6 unfrozen while its old serials stay frozen");
        assertEq(t.frozenBalanceOf(A), 0);
        (uint256 amt, uint256 entries) = _reasonAmount(A, R1);
        assertEq(amt, 0);
        assertEq(entries, 0);
        assertEq(t.transferableBalanceOf(A, B), 3);
        vm.prank(A);
        t.transferSlices(B, _arr(6), _arr(1));
        vm.prank(B);
        t.transferSlices(A, _arr(6), _arr(1));

        // freezing the old serial again: propagates to 6 again
        vm.recordLogs();
        _freeze(0, 1, R1);
        (fm,) = _freezeMask(vm.getRecordedLogs(), FROZEN_SIG, R1, 8);
        _assertMask(fm, _arr(0, 4, 6), "freezing the old serial again reaches 6");
        _assertFrozen(6, true, "6 frozen again");
        assertEq(t.frozenBalanceOf(A), 1);

        // unfreezing the middle generation: propagates to 6, does not affect 0
        _unfreeze(4, 1, R1);
        _assertFrozen(0, true, "0 stays frozen");
        _assertFrozen(4, false, "4 unfrozen");
        _assertFrozen(6, false, "6 unfrozen through 4");
        assertEq(t.frozenBalanceOf(A), 0);
    }

    // ───────────────────────── Classes and consolidation ─────────────────────────

    function test_classes() public {
        vm.skip(!hasClass);
        _mintClass(A, 2, W); // 0, 1
        _mint(X, 1); // 2
        _mintClass(A, 2, W); // 3, 4
        _mint(A, 2); // 5, 6 (default class)
        _mint(X, 1); // 7
        _mintClass(A, 1, N); // 8

        // clause 1: reverts when the classes are not all the same; the error names the slice that contains a serial
        // whose class differs from that of starts[0]
        vm.startPrank(A);
        vm.expectRevert(abi.encodeWithSelector(IERCXXXX.ERCXXXXNotConsolidatable.selector, A, 5, 2));
        t.consolidateSlices(_arr(0, 5), _arr(2, 2));
        vm.expectRevert(abi.encodeWithSelector(IERCXXXX.ERCXXXXNotConsolidatable.selector, A, 5, 2));
        t.consolidateSlices(_arr(3, 5), _arr(2, 2));
        vm.expectRevert(abi.encodeWithSelector(IERCXXXX.ERCXXXXNotConsolidatable.selector, A, 8, 1));
        t.consolidateSlices(_arr(0, 3, 8), _arr(2, 2, 1));
        // the classes already differ within one slice
        vm.expectRevert(abi.encodeWithSelector(IERCXXXX.ERCXXXXNotConsolidatable.selector, A, 3, 3));
        t.consolidateSlices(_arr(3), _arr(3));
        vm.stopPrank();

        // clause 2: the new serials keep a non-zero class, and SliceClassified comes after all the
        // SliceConsolidated events
        (bytes32[] memory cs0, uint256[] memory am0) = t.classesOf(A);
        vm.recordLogs();
        uint256 n = _consolidate(A, _arr(0, 3), _arr(2, 2));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(n, 9);
        uint256 lastConsol;
        uint256 classAt = type(uint256).max;
        uint256 classEvents;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(t)) continue;
            if (logs[i].topics[0] == CONSOL_SIG) lastConsol = i;
            if (logs[i].topics[0] == CLASS_SIG) {
                classAt = i;
                ++classEvents;
                (uint256 s, uint256 a, bytes32 c) = abi.decode(logs[i].data, (uint256, uint256, bytes32));
                assertEq(s, 9);
                assertEq(a, 4);
                assertEq(c, W);
            }
        }
        assertEq(classEvents, 1);
        assertGt(classAt, lastConsol, "SliceClassified after the SliceConsolidated events");
        _assertNoTransferEvents(logs);
        (bytes32 cid, uint256 len) = t.classSpanAt(9);
        assertEq(cid, W);
        assertEq(len, 4);
        // the class of the old serials does not change
        (cid,) = t.classSpanAt(0);
        assertEq(cid, W);
        // the amounts reported by classesOf do not change
        (bytes32[] memory cs1, uint256[] memory am1) = t.classesOf(A);
        assertEq(cs1.length, cs0.length);
        for (uint256 i; i < cs0.length; ++i) {
            for (uint256 j; j < cs1.length; ++j) {
                if (cs0[i] == cs1[j]) assertEq(am0[i], am1[j], "classesOf amount");
            }
        }
        // the new serials are still subject to the flow rule of their class: the 4 of W cannot go to B, the 2 of
        // the default class and the 1 of N can
        assertEq(t.transferableBalanceOf(A, B), 3);

        // a consolidation of the default class emits no SliceClassified
        vm.recordLogs();
        n = _consolidate(A, _arr(5), _arr(2));
        logs = vm.getRecordedLogs();
        assertEq(_datas(logs, CLASS_SIG).length, 0, "no SliceClassified for the default class");
        (cid, len) = t.classSpanAt(n);
        assertEq(cid, bytes32(0));
        assertEq(len, 2);
        // a third class
        n = _consolidate(A, _arr(8), _arr(1));
        (cid,) = t.classSpanAt(n);
        assertEq(cid, N);
    }

    /// @dev A class set after receipt (the units are still in the default pile): the consolidation checks and keeps
    ///      the current class of the serials.
    function test_classSetAfterReceipt() public {
        vm.skip(!hasClass);
        _scatter(A, 3); // A: 0, 2, 4
        vm.prank(admin);
        t.setClass(0, 3, W); // 0 and 2 become W
        vm.prank(A);
        vm.expectRevert(abi.encodeWithSelector(IERCXXXX.ERCXXXXNotConsolidatable.selector, A, 4, 1));
        t.consolidateSlices(_arr(0, 2, 4), _arr(1, 1, 1));
        uint256 n = _consolidate(A, _arr(0, 2), _arr(1, 1));
        (bytes32 cid, uint256 len) = t.classSpanAt(n);
        assertEq(cid, W);
        assertEq(len, 2);
        assertEq(t.transferableBalanceOf(A, B), 1);
    }

    /// @dev Serials that are frozen and have a class: the freeze is reported first; after the unfreeze they are
    ///      consolidated by class.
    function test_frozenAndClassed() public {
        vm.skip(!hasClass || !hasFreeze);
        _mintClass(A, 3, W); // 0..2
        _mint(X, 1);
        _mintClass(A, 3, W); // 4..6
        _freeze(5, 1, R1);
        vm.prank(A);
        vm.expectRevert(abi.encodeWithSelector(IERCXXXX.ERCXXXXNotConsolidatable.selector, A, 4, 3));
        t.consolidateSlices(_arr(0, 4), _arr(3, 3));
        _unfreeze(5, 1, R1);
        uint256 n = _consolidate(A, _arr(0, 4), _arr(3, 3));
        (bytes32 cid, uint256 len) = t.classSpanAt(n);
        assertEq(cid, W);
        assertEq(len, 6);
        // freezing the old serials propagates to the new serials; the class does not change
        _freeze(0, 7, R1);
        (bool f, uint256 fl) = t.frozenSpanAt(n);
        assertTrue(f);
        assertEq(fl, 6);
        (cid,) = t.classSpanAt(n);
        assertEq(cid, W);
    }
}

// ───────────────────────── Deployment parameters (the three hooks of this implementation) ─────────────────────────

contract ConsolidationParams is Test {
    address internal admin = makeAddr("admin");
    address internal A = makeAddr("A");
    address internal X = makeAddr("X");

    function _deploy(uint256 minSlices, uint256 threshold, bool gated)
        internal
        returns (PresetBothConsolTunedStack t)
    {
        t = new PresetBothConsolTunedStack("Serial", "SRL", 6, admin, minSlices, threshold, gated);
        vm.startPrank(admin);
        for (uint256 i; i < 5; ++i) {
            t.mint(A, 1);
            t.mint(X, 1);
        }
        t.mint(A, 10); // A: 0, 2, 4, 6, 8, 10..19
        vm.stopPrank();
    }

    function _arr(uint256 x, uint256 y, uint256 z) internal pure returns (uint256[] memory r) {
        r = new uint256[](3);
        (r[0], r[1], r[2]) = (x, y, z);
    }

    function _arr(uint256 x, uint256 y) internal pure returns (uint256[] memory r) {
        r = new uint256[](2);
        (r[0], r[1]) = (x, y);
    }

    function test_defaultsAllowAnyHolderAndOneSlice() public {
        PresetBothConsolTunedStack t = _deploy(1, 0, false);
        vm.prank(A);
        t.consolidateSlices(_arr(10, 11), _arr(1, 1)); // one group
        assertEq(t.serialsIssued(), 22);
    }

    function test_gatedCaller() public {
        PresetBothConsolTunedStack t = _deploy(1, 0, true);
        vm.prank(A);
        vm.expectRevert(abi.encodeWithSelector(PresetBothConsolTuned.ConsolidationNotAllowed.selector, A));
        t.consolidateSlices(_arr(0, 2), _arr(1, 1));
        vm.prank(admin);
        t.setConsolidator(A, true);
        vm.prank(A);
        t.consolidateSlices(_arr(0, 2), _arr(1, 1));
    }

    /// @dev The minimum number of groups is counted as slices that are not adjacent to one another: a slice split into
    ///      several adjacent slices and given separately is still one group.
    function test_minSlicesCountsGroups() public {
        PresetBothConsolTunedStack t = _deploy(3, 0, false);
        vm.startPrank(A);
        vm.expectRevert(
            abi.encodeWithSelector(ERCXXXXConsolidation.ERCXXXXConsolidationTooFewSlices.selector, 2, 3)
        );
        t.consolidateSlices(_arr(0, 2), _arr(1, 1));
        vm.expectRevert(
            abi.encodeWithSelector(ERCXXXXConsolidation.ERCXXXXConsolidationTooFewSlices.selector, 1, 3)
        );
        t.consolidateSlices(_arr(10, 11, 12), _arr(1, 1, 1));
        vm.expectRevert(
            abi.encodeWithSelector(ERCXXXXConsolidation.ERCXXXXConsolidationTooFewSlices.selector, 2, 3)
        );
        t.consolidateSlices(_arr(0, 10, 11), _arr(1, 1, 1));
        // several pieces of one slice that are not adjacent to one another are several groups
        t.consolidateSlices(_arr(10, 12, 14), _arr(1, 1, 1));
        t.consolidateSlices(_arr(0, 2, 4), _arr(1, 1, 1));
        vm.stopPrank();
    }

    function test_threshold() public {
        PresetBothConsolTunedStack t = _deploy(1, 6, false);
        uint256 c = t.sliceCount(A);
        assertEq(c, 6);
        vm.prank(A);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERCXXXXConsolidation.ERCXXXXConsolidationNotFragmented.selector, A, uint256(6), uint256(6)
            )
        );
        t.consolidateSlices(_arr(0, 2), _arr(1, 1));
        vm.prank(admin);
        t.mint(A, 1); // 20 is adjacent to 10..19, so the number of slices does not change
        vm.prank(admin);
        t.mint(X, 1);
        vm.prank(admin);
        t.mint(A, 1); // 22: the 7th slice
        assertEq(t.sliceCount(A), 7);
        vm.prank(A);
        t.consolidateSlices(_arr(0, 2), _arr(1, 1));
    }
}

// ───────────────────────── Consolidation closed (the default implementation of the core) ─────────────────────────

/// @dev A token that does not inherit the consolidation module (clause 7 of "Consolidation" in the draft):
///      consolidateSlices reverts with the implementation's own error for every caller and every argument, without
///      checking the arguments first; for an issued serial, consolidatedSpanAt returns the whole span from it to the
///      last issued serial, and for a serial not issued it returns (false, 0, 0); there are no consolidation
///      records, and freezes and unfreezes do not propagate. For each target that keeps consolidation closed, the
///      closed behavior is also asserted in the conformance tests.
contract ConsolidationClosed is Test {
    event SliceFrozen(bytes32 indexed reason, uint256 start, uint256 amount);

    address internal A = makeAddr("A");
    address internal X = makeAddr("X");
    bytes32 internal constant FROZEN_SIG = keccak256("SliceFrozen(bytes32,uint256,uint256)");

    function _arr(uint256 x, uint256 y) internal pure returns (uint256[] memory r) {
        r = new uint256[](2);
        (r[0], r[1]) = (x, y);
    }

    function _arr(uint256 x) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = x;
    }

    /// @dev A holds 0..2 and 4..5, X holds 3.
    function _holdings(ITestToken t) internal {
        t.mint(A, 3);
        t.mint(X, 1);
        t.mint(A, 2);
    }

    function _assertSpans(ITestToken t) internal view {
        uint256[4] memory serials = [uint256(0), 3, 5, 6];
        uint256[4] memory lens = [uint256(6), 3, 1, 0];
        for (uint256 i; i < 4; ++i) {
            (bool c, uint256 succ, uint256 len) = t.consolidatedSpanAt(serials[i]);
            assertFalse(c);
            assertEq(succ, 0);
            assertEq(len, lens[i], "the span reaches the last issued serial");
        }
        (bool c2, uint256 s2, uint256 l2) = t.consolidatedSpanAt(type(uint256).max);
        assertFalse(c2);
        assertEq(s2, 0);
        assertEq(l2, 0);
    }

    /// @dev Every kind of call reverts with `err`: valid and held, not held, invalid arguments, not issued.
    function _assertAlwaysReverts(ITestToken t, bytes4 err) internal {
        vm.prank(A);
        vm.expectRevert(err);
        t.consolidateSlices(_arr(0, 4), _arr(3, 2));
        vm.prank(A);
        vm.expectRevert(err);
        t.consolidateSlices(_arr(5), _arr(1));
        vm.prank(X);
        vm.expectRevert(err);
        t.consolidateSlices(_arr(0), _arr(1));
        vm.prank(A);
        vm.expectRevert(err);
        t.consolidateSlices(new uint256[](0), new uint256[](0));
        vm.prank(A);
        vm.expectRevert(err);
        t.consolidateSlices(_arr(0), _arr(0));
        vm.prank(A);
        vm.expectRevert(err);
        t.consolidateSlices(_arr(6), _arr(1));
        assertEq(t.serialsIssued(), 6);
    }

    /// @dev A freeze emits only the event for the slice named in the call, and does not propagate.
    function _assertFreezeDoesNotPropagate(ITestToken t) internal {
        t.setReasonInfo("r", "a reason", "");
        vm.recordLogs();
        t.freezeSlice(0, 6, "r");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == FROZEN_SIG) ++n;
        }
        assertEq(n, 1, "freezing on a closed token emits only the call's own event");
    }

    function test_coreStack() public {
        ITestToken t = ITestToken(address(new PresetBothStack("Serial", "SRL", 6, address(this))));
        _holdings(t);
        _assertAlwaysReverts(t, ERCXXXX.ERCXXXXConsolidationClosed.selector);
        _assertSpans(t);
        _assertFreezeDoesNotPropagate(t);
        _assertAlwaysReverts(t, ERCXXXX.ERCXXXXConsolidationClosed.selector);
    }

    function test_coreSorted() public {
        ITestToken t = ITestToken(address(new PresetCoreSorted("Serial", "SRL", 6, address(this))));
        (bool c, uint256 succ, uint256 len) = t.consolidatedSpanAt(0);
        assertFalse(c);
        assertEq(succ, 0);
        assertEq(len, 0, "nothing issued yet");
        _holdings(t);
        _assertAlwaysReverts(t, ERCXXXX.ERCXXXXConsolidationClosed.selector);
        _assertSpans(t);
    }
}

// ───────────────────────── Tokens under test ─────────────────────────

contract Consolidation_CoreStack is ConsolidationBase, TargetCoreConsolStack {}

contract Consolidation_CoreSorted is ConsolidationBase, TargetCoreConsolSorted {}

contract Consolidation_FreezeStack is ConsolidationBase, TargetFreezeConsolStack {}

contract Consolidation_FreezeSorted is ConsolidationBase, TargetFreezeConsolSorted {}

contract Consolidation_ClassStack is ConsolidationBase, TargetClassConsolStack {}

contract Consolidation_ClassSorted is ConsolidationBase, TargetClassConsolSorted {}

contract Consolidation_BothStack is ConsolidationBase, TargetBothConsolStack {}

contract Consolidation_BothSorted is ConsolidationBase, TargetBothConsolSorted {}

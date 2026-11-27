// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {IERCXXXX} from "../../contracts/spec/IERCXXXX.sol";
import {IERCXXXXFreezable} from "../../contracts/spec/IERCXXXXFreezable.sol";
import {IERCXXXXClassified} from "../../contracts/spec/IERCXXXXClassified.sol";
import {IERCXXXXAcceptance} from "../../contracts/spec/IERCXXXXAcceptance.sol";
import {IERC20} from "../../contracts/utils/IERC20.sol";
import {
    ACCEPT,
    ERC165_ID,
    NoInterfaceContract,
    RangeLimitReceiver,
    PullingReceiver
} from "../mocks/AcceptanceCheckers.sol";
import {Rule} from "../presets/Presets.sol";
import "../presets/Targets.sol";

/// @dev The test sequences of the draft, written as tests step by step following the text. The sequences are in
///      assets/erc-draft_serial_numbered_token/test-cases.md, the file linked from the section "Test Cases" of the
///      draft.
///      The acceptance check sequence has one more test, which checks what the last paragraph of the sequence states
///      about contracts that do not support the acceptance check.
///      The assertions use only what the file states and do not depend on the implementation's selection rule.
///      One concrete contract for each token under test (at the end of the file); steps that use an extension are
///      skipped on tokens that do not support it.
///      Consolidation is part of the core interface: tokens that open consolidation run the consolidation sequence;
///      tokens that do not (clause 7 of "Consolidation" of the draft) assert the closed behavior at the same places
///      instead of skipping. Whether a token opens consolidation is marked explicitly by its target in Targets.sol.
abstract contract DraftSequencesBase is Test, TokenTarget {
    bytes32 internal constant TRANSFER_SIG = keccak256("Transfer(address,address,uint256)");
    bytes32 internal constant SERIAL_SIG = keccak256("SliceTransferred(address,address,uint256,uint256)");
    bytes32 internal constant FORCED_SIG = keccak256("SliceForciblyTransferred(address,address,uint256,uint256)");
    bytes32 internal constant FROZEN_SIG = keccak256("SliceFrozen(bytes32,uint256,uint256)");
    bytes32 internal constant CLASS_SET_SIG = keccak256("SliceClassified(uint256,uint256,bytes32)");
    bytes32 internal constant UNFROZEN_SIG = keccak256("SliceUnfrozen(bytes32,uint256,uint256)");
    bytes32 internal constant CONSOL_SIG = keccak256("SliceConsolidated(address,uint256,uint256,uint256)");
    /// @dev ERC-165 identifier of the acceptance check ("Acceptance check" of the draft), which is also the selector
    ///      of the error ERCXXXXTransferRefused.
    bytes4 internal constant ACCEPTANCE_CHECK_ID = 0x29543499;

    ITestToken internal t;
    bool internal hasFreeze;
    bool internal hasClass;
    bool internal hasAccept;
    bool internal hasConsol;
    address internal admin = makeAddr("admin");
    address internal A = makeAddr("A");
    address internal B = makeAddr("B");
    address internal C = makeAddr("C");
    address internal D = makeAddr("D");
    address internal M = makeAddr("M");
    address internal T = makeAddr("T");
    address internal Z = makeAddr("someone else");

    bytes32 internal r1 = "r1";
    bytes32 internal r2 = "r2";
    bytes32 internal r = "r";
    bytes32 internal w = "w";

    function setUp() public {
        (t, hasFreeze, hasClass, hasConsol) = _deployToken(admin);
        hasAccept = t.supportsInterface(ACCEPTANCE_CHECK_ID);
        assertEq(hasAccept, _mustAccept(), "acceptance check support");
        vm.startPrank(admin);
        if (hasFreeze) {
            t.setReasonInfo(r1, "Reason one", "");
            t.setReasonInfo(r2, "Reason two", "");
            t.setReasonInfo(r, "Reason", "");
        }
        if (hasClass) {
            t.defineClass(w, Rule.Allowlist, 0, "Designated recipients only", "");
            t.setAllowed(w, M, true);
        }
        vm.stopPrank();
        vm.recordLogs();
    }

    /// @dev Whether the token under test should support the acceptance check. The targets with the extension
    ///      ERCXXXXAcceptance override it at the end of the file.
    function _mustAccept() internal pure virtual returns (bool) {
        return false;
    }

    // ───────────────────────── Helpers ─────────────────────────

    function _dests() internal view returns (address[] memory d) {
        d = new address[](8);
        (d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7]) = (A, B, C, D, M, T, Z, address(0));
    }

    function _mint(address to, uint256 v) internal {
        vm.prank(admin);
        t.mint(to, v);
    }

    function _send(address from, address to, uint256 v) internal {
        vm.prank(from);
        assertTrue(t.transfer(to, v), "transfer must return true");
    }

    function _one(uint256 x) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = x;
    }

    function _two(uint256 x, uint256 y) internal pure returns (uint256[] memory a) {
        a = new uint256[](2);
        (a[0], a[1]) = (x, y);
    }

    /// @dev The set of serials covered by the SliceTransferred events of this call.
    ///      Also checks that each event has the expected from and to and amount > 0, that the slices are pairwise
    ///      disjoint, and that they all come before the Transfer event, followed by exactly one
    ///      Transfer(from, to, sum of the amounts).
    function _serialMask(Vm.Log[] memory logs, address from, address to, uint256 size)
        internal
        view
        returns (bool[] memory mask, uint256 sum)
    {
        mask = new bool[](size);
        uint256 transfers;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory lg = logs[i];
            if (lg.emitter != address(t)) continue;
            if (lg.topics[0] == SERIAL_SIG) {
                assertEq(transfers, 0, "SliceTransferred after Transfer");
                assertEq(address(uint160(uint256(lg.topics[1]))), from, "SliceTransferred.from");
                assertEq(address(uint160(uint256(lg.topics[2]))), to, "SliceTransferred.to");
                (uint256 start, uint256 amount) = abi.decode(lg.data, (uint256, uint256));
                assertGt(amount, 0, "SliceTransferred.amount");
                for (uint256 s = start; s < start + amount; ++s) {
                    assertLt(s, size, "serial out of expected space");
                    assertFalse(mask[s], "overlapping SliceTransferred ranges");
                    mask[s] = true;
                }
                sum += amount;
            } else if (lg.topics[0] == TRANSFER_SIG) {
                ++transfers;
                assertEq(address(uint160(uint256(lg.topics[1]))), from, "Transfer.from");
                assertEq(address(uint160(uint256(lg.topics[2]))), to, "Transfer.to");
                assertEq(abi.decode(lg.data, (uint256)), sum, "Transfer.value != sum of SliceTransferred");
            }
        }
        assertEq(transfers, 1, "exactly one Transfer");
    }

    function _assertExactly(bool[] memory mask, uint256[] memory los, uint256[] memory his, string memory what)
        internal
        pure
    {
        for (uint256 s; s < mask.length; ++s) {
            bool want;
            for (uint256 k; k < los.length; ++k) {
                if (s >= los[k] && s < his[k]) want = true;
            }
            assertEq(mask[s], want, what);
        }
    }

    function _assertWithin(bool[] memory mask, uint256 lo, uint256 hi, string memory what) internal pure {
        for (uint256 s; s < mask.length; ++s) {
            if (mask[s]) assertTrue(s >= lo && s < hi, what);
        }
    }

    function _holdMask(address account, uint256 size) internal view returns (bool[] memory mask) {
        mask = new bool[](size);
        uint256 n = t.sliceCount(account);
        for (uint256 i; i < n; ++i) {
            (uint256 start, uint256 amount) = t.sliceAt(account, i);
            assertGt(amount, 0, "empty range");
            for (uint256 s = start; s < start + amount; ++s) {
                assertFalse(mask[s], "overlapping ranges");
                mask[s] = true;
            }
        }
    }

    function _assertTransferableForAnyTo(address from, uint256 want) internal view {
        address[] memory d = _dests();
        for (uint256 i; i < d.length; ++i) {
            assertEq(t.transferableBalanceOf(from, d[i]), want, "transferableBalanceOf for some to");
        }
    }

    function _reasonAmount(address account, bytes32 reason) internal view returns (uint256 amount, uint256 entries) {
        (bytes32[] memory rs, uint256[] memory am) = t.freezeReasonsOf(account);
        assertEq(rs.length, am.length, "freezeReasonsOf lengths");
        entries = rs.length;
        for (uint256 i; i < rs.length; ++i) {
            assertGt(am[i], 0, "freezeReasonsOf zero amount");
            for (uint256 j; j < i; ++j) {
                assertTrue(rs[j] != rs[i], "duplicate reason");
            }
            if (rs[i] == reason) amount = am[i];
        }
    }

    function _classAmount(address account, bytes32 classId) internal view returns (uint256 amount, uint256 entries) {
        (bytes32[] memory cs, uint256[] memory am) = t.classesOf(account);
        assertEq(cs.length, am.length, "classesOf lengths");
        entries = cs.length;
        for (uint256 i; i < cs.length; ++i) {
            assertGt(am[i], 0, "classesOf zero amount");
            for (uint256 j; j < i; ++j) {
                assertTrue(cs[j] != cs[i], "duplicate class");
            }
            if (cs[i] == classId) amount = am[i];
        }
    }

    // ───────────────────────── ERC-165 ─────────────────────────

    function test_supportsInterface() public view {
        assertTrue(t.supportsInterface(0x01ffc9a7));
        assertTrue(t.supportsInterface(type(IERCXXXX).interfaceId));
        assertEq(t.supportsInterface(type(IERCXXXXFreezable).interfaceId), hasFreeze);
        assertEq(t.supportsInterface(type(IERCXXXXClassified).interfaceId), hasClass);
        assertEq(t.supportsInterface(ACCEPTANCE_CHECK_ID), _mustAccept());
        // 0x4689efd4 is the interface of recipients; supporting the acceptance check does not make the token
        // declare it.
        assertFalse(t.supportsInterface(type(IERCXXXXAcceptance).interfaceId));
        assertFalse(t.supportsInterface(0xffffffff));
        assertEq(t.decimals(), 6);
        // The two consolidation functions are in the core interface: the same id is declared whether or not
        // consolidation is open.
        assertEq(type(IERCXXXX).interfaceId, bytes4(0x668ccf00));
        assertEq(type(IERCXXXXFreezable).interfaceId, bytes4(0x6eb84bb0));
        assertEq(type(IERCXXXXClassified).interfaceId, bytes4(0xb62c1e43));
        assertEq(type(IERCXXXXAcceptance).interfaceId, bytes4(0x4689efd4));
        assertEq(IERCXXXX.ERCXXXXTransferRefused.selector, ACCEPTANCE_CHECK_ID);
    }

    // ───────────────────────── First sequence and freezing steps ─────────────────────────

    function _firstSequence() internal {
        // 1
        _mint(A, 100);
        (bool[] memory m1, uint256 s1) = _serialMask(vm.getRecordedLogs(), address(0), A, 100);
        assertEq(s1, 100);
        _assertExactly(m1, _one(0), _one(100), "step 1 coverage");
        assertEq(t.serialsIssued(), 100);

        // 2
        _send(A, B, 30);
        (bool[] memory m2, uint256 s2) = _serialMask(vm.getRecordedLogs(), A, B, 100);
        assertEq(s2, 30);
        vm.prank(A);
        vm.expectRevert();
        t.transfer(address(0), 1);

        // 3
        _send(B, C, 10);
        (bool[] memory m3, uint256 s3) = _serialMask(vm.getRecordedLogs(), B, C, 100);
        assertEq(s3, 10);
        for (uint256 s; s < 100; ++s) {
            if (m3[s]) assertTrue(m2[s], "step 3 ranges must lie in what B received in step 2");
        }

        // 4
        _mint(C, 50);
        (bool[] memory m4,) = _serialMask(vm.getRecordedLogs(), address(0), C, 150);
        _assertExactly(m4, _one(100), _one(150), "step 4 coverage");
        assertEq(t.serialsIssued(), 150);
        assertEq(t.balanceOf(A), 70);
        assertEq(t.balanceOf(B), 20);
        assertEq(t.balanceOf(C), 60);
    }

    function test_sequence1() public {
        _firstSequence();
    }

    function test_sequence1_freezeSteps() public {
        vm.skip(!hasFreeze);
        _firstSequence();

        // 5
        vm.prank(admin);
        t.freezeSlice(0, 100, r1);
        {
            Vm.Log[] memory logs = vm.getRecordedLogs();
            bool[] memory fm = new bool[](150);
            for (uint256 i; i < logs.length; ++i) {
                if (logs[i].topics[0] != FROZEN_SIG) continue;
                assertEq(logs[i].topics[1], r1, "SliceFrozen reason");
                (uint256 start, uint256 amount) = abi.decode(logs[i].data, (uint256, uint256));
                for (uint256 s = start; s < start + amount; ++s) {
                    fm[s] = true;
                }
            }
            _assertExactly(fm, _one(0), _one(100), "step 5 SliceFrozen coverage");
        }
        assertEq(t.balanceOf(A), 70);
        assertEq(t.balanceOf(B), 20);
        assertEq(t.balanceOf(C), 60);
        _assertTransferableForAnyTo(A, 0);
        _assertTransferableForAnyTo(B, 0);
        _assertTransferableForAnyTo(C, 50);
        assertEq(t.frozenBalanceOf(A), 70);
        assertEq(t.frozenBalanceOf(B), 20);
        assertEq(t.frozenBalanceOf(C), 10);
        (bool f, uint256 len) = t.frozenSpanAt(0);
        assertTrue(f);
        assertTrue(len >= 1 && len <= 100);
        (f, len) = t.frozenSpanAt(100);
        assertFalse(f);
        assertTrue(len >= 1 && len <= 50);
        (f, len) = t.frozenSpanAt(150);
        assertFalse(f);
        assertEq(len, 0);
        (uint256 amt, uint256 entries) = _reasonAmount(C, r1);
        assertEq(entries, 1);
        assertEq(amt, 10);
        vm.prank(A);
        assertTrue(t.approve(D, 5));
        assertEq(t.allowance(A, D), 5);
        vm.prank(D);
        vm.expectRevert();
        t.transferFrom(A, D, 5);

        // 6
        vm.prank(B);
        vm.expectRevert();
        t.transfer(A, 1);
        vm.prank(C);
        vm.expectRevert(
            abi.encodeWithSelector(IERCXXXX.ERCXXXXInsufficientTransferableBalance.selector, C, D, 51, 50)
        );
        t.transfer(D, 51);
        vm.getRecordedLogs();
        _send(C, D, 50);
        (bool[] memory m6,) = _serialMask(vm.getRecordedLogs(), C, D, 150);
        _assertWithin(m6, 100, 150, "step 6 ranges");

        // 7
        vm.prank(admin);
        t.freezeSlice(0, 150, r2);
        assertEq(t.frozenBalanceOf(A), 70);
        (amt, entries) = _reasonAmount(A, r1);
        assertEq(entries, 2);
        assertEq(amt, 70);
        (amt,) = _reasonAmount(A, r2);
        assertEq(amt, 70);
        assertEq(t.frozenBalanceOf(D), 50);
        (amt, entries) = _reasonAmount(D, r2);
        assertEq(entries, 1);
        assertEq(amt, 50);

        // 8
        vm.prank(admin);
        t.unfreezeSlice(0, 100, r1);
        (f,) = t.frozenSpanAt(0);
        assertTrue(f);
        _assertTransferableForAnyTo(A, 0);
        _assertTransferableForAnyTo(B, 0);
        _assertTransferableForAnyTo(C, 0);
        _assertTransferableForAnyTo(D, 0);
        vm.prank(B);
        vm.expectRevert();
        t.transfer(A, 1);
        (amt, entries) = _reasonAmount(A, r2);
        assertEq(entries, 1);
        assertEq(amt, 70);

        // 9
        vm.prank(admin);
        t.unfreezeSlice(0, 100, r2);
        (f, len) = t.frozenSpanAt(0);
        assertFalse(f);
        assertTrue(len >= 1 && len <= 100);
        (f, len) = t.frozenSpanAt(100);
        assertTrue(f);
        assertTrue(len >= 1 && len <= 50);
        assertEq(t.frozenBalanceOf(A), 0);
        _assertTransferableForAnyTo(A, 70);
        _assertTransferableForAnyTo(B, 20);
        _assertTransferableForAnyTo(C, 10);
        _assertTransferableForAnyTo(D, 0);
        _send(B, D, 1);
        vm.prank(D);
        vm.expectRevert(abi.encodeWithSelector(IERCXXXX.ERCXXXXNotTransferable.selector, D, A, 100, 1));
        t.transferSlices(A, _one(100), _one(1));
        vm.prank(D);
        vm.expectRevert(abi.encodeWithSelector(IERCXXXX.ERCXXXXNotTransferable.selector, D, address(0), 100, 1));
        t.burnSlices(_one(100), _one(1));

        // 10
        vm.prank(admin);
        t.unfreezeSlice(100, 50, r2);
        assertEq(t.frozenBalanceOf(A), 0);
        assertEq(t.frozenBalanceOf(B), 0);
        assertEq(t.frozenBalanceOf(C), 0);
        assertEq(t.frozenBalanceOf(D), 0);
        (bytes32[] memory rs, uint256[] memory am) = t.freezeReasonsOf(D);
        assertEq(rs.length, 0);
        assertEq(am.length, 0);
        assertEq(t.balanceOf(A), 70);
        assertEq(t.balanceOf(B), 19);
        assertEq(t.balanceOf(C), 10);
        assertEq(t.balanceOf(D), 51);
        assertEq(t.totalSupply(), 150);
        assertEq(t.serialsIssued(), 150);
        assertEq(t.allowance(A, D), 5);
    }

    // ───────────────────────── transferSlices sequence ─────────────────────────

    function test_sequenceTransferSlices() public {
        // 1
        _mint(A, 100);
        vm.getRecordedLogs();

        // 2
        vm.prank(A);
        assertTrue(t.transferSlices(B, _one(40), _one(20)));
        (bool[] memory m2,) = _serialMask(vm.getRecordedLogs(), A, B, 100);
        _assertExactly(m2, _one(40), _one(60), "step 2 coverage");
        assertEq(t.balanceOf(A), 80);
        assertEq(t.balanceOf(B), 20);
        _assertExactly(_holdMask(B, 100), _one(40), _one(60), "step 2 B ranges");
        _assertExactly(_holdMask(A, 100), _two(0, 60), _two(40, 100), "step 2 A ranges");

        // 3
        vm.prank(A);
        assertTrue(t.transferSlices(B, _two(0, 70), _two(10, 5)));
        (bool[] memory m3,) = _serialMask(vm.getRecordedLogs(), A, B, 100);
        _assertExactly(m3, _two(0, 70), _two(10, 75), "step 3 coverage");
        assertEq(t.balanceOf(A), 65);
        assertEq(t.balanceOf(B), 35);

        // 4
        vm.startPrank(A);
        vm.expectRevert(abi.encodeWithSelector(IERCXXXX.ERCXXXXNotHeld.selector, A, 30, 20));
        t.transferSlices(B, _one(30), _one(20));
        vm.expectRevert(abi.encodeWithSelector(IERCXXXX.ERCXXXXNotHeld.selector, A, 90, 20));
        t.transferSlices(B, _one(90), _one(20));
        vm.expectRevert();
        t.transferSlices(B, _one(10), _one(0));
        vm.expectRevert();
        t.transferSlices(B, new uint256[](0), new uint256[](0));
        vm.expectRevert();
        t.transferSlices(B, _two(10, 20), _one(5));
        vm.expectRevert();
        t.transferSlices(B, _two(10, 12), _two(5, 5));
        vm.expectRevert();
        t.transferSlices(B, _two(20, 10), _two(5, 5));
        vm.expectRevert();
        t.transferSlices(address(0), _one(10), _one(5));
        vm.stopPrank();
        vm.getRecordedLogs();

        // 5
        bool[] memory before = _holdMask(B, 100);
        vm.prank(B);
        assertTrue(t.transferSlices(B, _one(40), _one(20)));
        {
            Vm.Log[] memory logs = vm.getRecordedLogs();
            uint256 transfers;
            for (uint256 i; i < logs.length; ++i) {
                assertTrue(logs[i].topics[0] != SERIAL_SIG, "no SliceTransferred for a transfer to self");
                if (logs[i].topics[0] == TRANSFER_SIG) {
                    ++transfers;
                    assertEq(address(uint160(uint256(logs[i].topics[1]))), B);
                    assertEq(address(uint160(uint256(logs[i].topics[2]))), B);
                    assertEq(abi.decode(logs[i].data, (uint256)), 20);
                }
            }
            assertEq(transfers, 1);
        }
        bool[] memory afterMask = _holdMask(B, 100);
        for (uint256 s; s < 100; ++s) {
            assertEq(afterMask[s], before[s], "step 5 holders changed");
        }
        vm.prank(B);
        vm.expectRevert();
        t.transferSlices(B, _two(40, 45), _two(10, 5));

        // 6
        vm.prank(B);
        assertTrue(t.transferSlices(A, _one(45), _one(5)));
        uint256[] memory losA = new uint256[](4);
        uint256[] memory hisA = new uint256[](4);
        (losA[0], losA[1], losA[2], losA[3]) = (10, 45, 60, 75);
        (hisA[0], hisA[1], hisA[2], hisA[3]) = (40, 50, 70, 100);
        _assertExactly(_holdMask(A, 100), losA, hisA, "step 6 A ranges");
        uint256[] memory losB = new uint256[](4);
        uint256[] memory hisB = new uint256[](4);
        (losB[0], losB[1], losB[2], losB[3]) = (0, 40, 50, 70);
        (hisB[0], hisB[1], hisB[2], hisB[3]) = (10, 45, 60, 75);
        _assertExactly(_holdMask(B, 100), losB, hisB, "step 6 B ranges");
        assertEq(t.balanceOf(A), 70);
        assertEq(t.balanceOf(B), 30);
        vm.getRecordedLogs();

        // 7
        vm.prank(A);
        vm.expectRevert(abi.encodeWithSelector(IERCXXXX.ERCXXXXNotHeld.selector, A, 0, 5));
        t.burnSlices(_one(0), _one(5));
        vm.prank(A);
        t.burnSlices(_two(10, 60), _two(5, 10));
        (bool[] memory m7,) = _serialMask(vm.getRecordedLogs(), A, address(0), 100);
        _assertExactly(m7, _two(10, 60), _two(15, 70), "step 7 coverage");
        assertEq(t.balanceOf(A), 55);
        assertEq(t.totalSupply(), 85);
        assertEq(t.serialsIssued(), 100);
    }

    // ───────────────────────── Classification sequence ─────────────────────────

    function test_sequenceClassification() public {
        vm.skip(!hasClass);
        // Preconditions: classInfo(w) returns a non-empty name; when from is any one of A, B and M,
        // classAllows(w, from, to) returns true when to is M and returns false when to is A or B.
        (string memory nm,) = t.classInfo(w);
        assertGt(bytes(nm).length, 0);
        {
            address[3] memory parties = [A, B, M];
            for (uint256 i; i < 3; ++i) {
                assertTrue(t.classAllows(w, parties[i], M), "classAllows(w, from, M)");
                assertFalse(t.classAllows(w, parties[i], A), "classAllows(w, from, A)");
                assertFalse(t.classAllows(w, parties[i], B), "classAllows(w, from, B)");
            }
        }
        vm.getRecordedLogs();

        // 1
        vm.prank(admin);
        t.mintWithClass(A, 100, w);
        {
            Vm.Log[] memory logs = vm.getRecordedLogs();
            bool[] memory cm = new bool[](100);
            // The SliceClassified events must be emitted after the Transfer(0x0, A, 100) that issues these serials.
            uint256 issuedAt = type(uint256).max;
            for (uint256 i; i < logs.length; ++i) {
                if (
                    logs[i].topics[0] == keccak256("Transfer(address,address,uint256)")
                        && logs[i].topics[1] == bytes32(0) && logs[i].topics[2] == bytes32(uint256(uint160(A)))
                ) {
                    assertEq(abi.decode(logs[i].data, (uint256)), 100);
                    issuedAt = i;
                }
                if (logs[i].topics[0] != CLASS_SET_SIG) continue;
                assertTrue(issuedAt != type(uint256).max, "step 1 SliceClassified before the issuing Transfer");
                (uint256 start, uint256 amount, bytes32 cid) = abi.decode(logs[i].data, (uint256, uint256, bytes32));
                assertEq(cid, w);
                for (uint256 s = start; s < start + amount; ++s) {
                    cm[s] = true;
                }
            }
            _assertExactly(cm, _one(0), _one(100), "step 1 SliceClassified coverage");
        }

        // 2
        _mint(A, 50);
        assertEq(t.balanceOf(A), 150);
        assertEq(t.transferableBalanceOf(A, B), 50);
        assertEq(t.transferableBalanceOf(A, M), 150);
        (uint256 amt, uint256 entries) = _classAmount(A, w);
        assertEq(entries, 2);
        assertEq(amt, 100);
        (amt,) = _classAmount(A, bytes32(0));
        assertEq(amt, 50);
        (bytes32 cid, uint256 len) = t.classSpanAt(0);
        assertEq(cid, w);
        assertTrue(len >= 1 && len <= 100);
        (cid, len) = t.classSpanAt(100);
        assertEq(cid, bytes32(0));
        assertTrue(len >= 1 && len <= 50);
        (cid, len) = t.classSpanAt(150);
        assertEq(cid, bytes32(0));
        assertEq(len, 0);
        vm.getRecordedLogs();

        // 3
        vm.prank(A);
        vm.expectRevert(
            abi.encodeWithSelector(IERCXXXX.ERCXXXXInsufficientTransferableBalance.selector, A, B, 51, 50)
        );
        t.transfer(B, 51);
        vm.getRecordedLogs(); // vm.recordLogs also records the events emitted by the reverted call
        _send(A, B, 50);
        (bool[] memory m3,) = _serialMask(vm.getRecordedLogs(), A, B, 150);
        _assertWithin(m3, 100, 150, "step 3 ranges");

        // 4
        _send(A, M, 30);
        (bool[] memory m4,) = _serialMask(vm.getRecordedLogs(), A, M, 150);
        _assertWithin(m4, 0, 100, "step 4 ranges");
        for (uint256 s; s < 150; ++s) {
            if (!m4[s]) continue;
            (cid,) = t.classSpanAt(s);
            assertEq(cid, w, "step 4 class kept");
        }

        // 5
        assertEq(t.transferableBalanceOf(M, B), 0);
        assertEq(t.transferableBalanceOf(M, A), 0);
        vm.prank(M);
        vm.expectRevert();
        t.transfer(B, 1);
        assertEq(t.balanceOf(A), 70);
        assertEq(t.balanceOf(B), 50);
        assertEq(t.balanceOf(M), 30);

        // 6 (requires the freezing extension)
        if (!hasFreeze) return;
        vm.prank(admin);
        t.freezeSlice(0, 100, r);
        assertEq(t.transferableBalanceOf(A, M), 0);
        (amt, entries) = _classAmount(A, w);
        assertEq(entries, 1);
        assertEq(amt, 70);
    }

    // ───────────────────────── Forced transfer and destruction sequence ─────────────────────────

    function test_sequenceForced() public {
        vm.skip(!hasFreeze);
        // 1
        _mint(A, 100);
        vm.prank(A);
        t.transferSlices(B, _one(20), _one(30));
        _assertExactly(_holdMask(B, 100), _one(20), _one(50), "step 1 B ranges");

        // 2 (this implementation requires freezing first)
        vm.prank(admin);
        vm.expectRevert();
        t.forcedTransferSlice(B, T, 20, 10);

        // 3
        vm.prank(admin);
        t.freezeSlice(20, 30, r);
        vm.getRecordedLogs();

        // 4
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IERCXXXX.ERCXXXXNotHeld.selector, A, 20, 10));
        t.forcedTransferSlice(A, T, 20, 10);
        vm.prank(admin);
        t.forcedTransferSlice(B, T, 20, 10);
        {
            Vm.Log[] memory logs = vm.getRecordedLogs();
            _checkForcedLogs(logs, B, T, 20, 10);
            (bool[] memory m4,) = _serialMask(logs, B, T, 100);
            _assertExactly(m4, _one(20), _one(30), "step 4 coverage");
        }
        assertEq(t.balanceOf(T), 10);
        assertEq(t.frozenBalanceOf(T), 10);
        _assertTransferableForAnyTo(T, 0);
        (bool f, uint256 len) = t.frozenSpanAt(20);
        assertTrue(f);
        assertTrue(len >= 1 && len <= 30);

        // 5
        vm.prank(admin);
        t.destroySlice(B, 30, 20);
        {
            Vm.Log[] memory logs = vm.getRecordedLogs();
            _checkForcedLogs(logs, B, address(0), 30, 20);
            (bool[] memory m5,) = _serialMask(logs, B, address(0), 100);
            _assertExactly(m5, _one(30), _one(50), "step 5 coverage");
        }
        assertEq(t.balanceOf(B), 0);
        assertEq(t.totalSupply(), 80);
        assertEq(t.serialsIssued(), 100);

        // 6
        vm.prank(admin);
        t.unfreezeSlice(20, 10, r);
        _assertTransferableForAnyTo(T, 10);
        (f, len) = t.frozenSpanAt(20);
        assertFalse(f);
        assertTrue(len >= 1 && len <= 10);
        // the destroyed serials 30 through 49 are still frozen for r
        (f, len) = t.frozenSpanAt(30);
        assertTrue(f);
        assertTrue(len >= 1 && len <= 20);
    }

    /// @dev Exactly one SliceForciblyTransferred, with the same arguments as the call, and after the Transfer.
    function _checkForcedLogs(Vm.Log[] memory logs, address from, address to, uint256 start, uint256 amount)
        internal
        view
    {
        uint256 transferAt = type(uint256).max;
        uint256 forced;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(t)) continue;
            if (logs[i].topics[0] == TRANSFER_SIG) transferAt = i;
            if (logs[i].topics[0] == FORCED_SIG) {
                ++forced;
                assertTrue(transferAt != type(uint256).max && i > transferAt, "SliceForciblyTransferred before Transfer");
                assertEq(address(uint160(uint256(logs[i].topics[1]))), from);
                assertEq(address(uint160(uint256(logs[i].topics[2]))), to);
                (uint256 s, uint256 a) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(s, start);
                assertEq(a, amount);
            }
        }
        assertEq(forced, 1, "exactly one SliceForciblyTransferred");
    }

    // ───────────────────────── Consolidation sequence ─────────────────────────

    /// @dev The SliceConsolidated events of this call equal (account, starts[i], newStarts[i], amounts[i]) in order,
    ///      and there is no Transfer or SliceTransferred.
    function _checkConsolidated(
        Vm.Log[] memory logs,
        address account,
        uint256[] memory starts,
        uint256[] memory newStarts,
        uint256[] memory amounts
    ) internal view {
        uint256 k;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(t)) continue;
            bytes32 sig = logs[i].topics[0];
            assertTrue(sig != TRANSFER_SIG && sig != SERIAL_SIG, "consolidation emitted Transfer or SliceTransferred");
            if (sig != CONSOL_SIG) continue;
            assertLt(k, starts.length, "too many SliceConsolidated");
            assertEq(address(uint160(uint256(logs[i].topics[1]))), account, "SliceConsolidated.account");
            (uint256 s, uint256 ns, uint256 a) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            assertEq(s, starts[k], "SliceConsolidated.start");
            assertEq(ns, newStarts[k], "SliceConsolidated.newStart");
            assertEq(a, amounts[k], "SliceConsolidated.amount");
            ++k;
        }
        assertEq(k, starts.length, "one SliceConsolidated per slice");
    }

    /// @dev The set of serials covered by the SliceFrozen or SliceUnfrozen events (chosen by sig) of this call whose
    ///      reason is `reason`.
    function _freezeEventMask(Vm.Log[] memory logs, bytes32 sig, bytes32 reason, uint256 size)
        internal
        view
        returns (bool[] memory mask)
    {
        mask = new bool[](size);
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(t) || logs[i].topics[0] != sig) continue;
            assertEq(logs[i].topics[1], reason, "event reason");
            (uint256 start, uint256 amount) = abi.decode(logs[i].data, (uint256, uint256));
            assertGt(amount, 0, "event amount");
            for (uint256 s = start; s < start + amount; ++s) {
                mask[s] = true;
            }
        }
    }

    function _three(uint256 x, uint256 y, uint256 z) internal pure returns (uint256[] memory a) {
        a = new uint256[](3);
        (a[0], a[1], a[2]) = (x, y, z);
    }

    function _assertConsolidatedSpan(uint256 serial, bool c, uint256 succ, uint256 maxLen) internal view {
        (bool c2, uint256 s2, uint256 l2) = t.consolidatedSpanAt(serial);
        assertEq(c2, c, "consolidatedSpanAt.consolidated");
        assertEq(s2, succ, "consolidatedSpanAt.successor");
        if (maxLen == 0) assertEq(l2, 0, "consolidatedSpanAt.length of an unissued serial");
        else assertTrue(l2 >= 1 && l2 <= maxLen, "consolidatedSpanAt.length");
    }

    function _consolidationSequence() internal {
        // 1
        _mint(A, 100);
        vm.prank(A);
        t.transferSlices(B, _three(10, 30, 50), _three(10, 10, 10));
        _assertExactly(_holdMask(B, 100), _three(10, 30, 50), _three(20, 40, 60), "step 1 B ranges");
        vm.getRecordedLogs();

        // 2
        vm.prank(B);
        assertEq(t.consolidateSlices(_three(10, 30, 50), _three(10, 10, 5)), 100, "step 2 newStart");
        _checkConsolidated(vm.getRecordedLogs(), B, _three(10, 30, 50), _three(100, 110, 120), _three(10, 10, 5));
        assertEq(t.serialsIssued(), 125);
        assertEq(t.balanceOf(A), 70);
        assertEq(t.balanceOf(B), 30);
        assertEq(t.totalSupply(), 100);
        _assertExactly(_holdMask(B, 125), _two(55, 100), _two(60, 125), "step 2 B ranges");
        {
            uint256[] memory los = new uint256[](4);
            uint256[] memory his = new uint256[](4);
            (los[0], los[1], los[2], los[3]) = (0, 20, 40, 60);
            (his[0], his[1], his[2], his[3]) = (10, 30, 50, 100);
            _assertExactly(_holdMask(A, 125), los, his, "step 2 A ranges");
        }
        _assertConsolidatedSpan(10, true, 100, 10);
        _assertConsolidatedSpan(15, true, 105, 5);
        _assertConsolidatedSpan(20, false, 0, 10);
        _assertConsolidatedSpan(55, false, 0, 70);
        _assertConsolidatedSpan(125, false, 0, 0);

        // 3
        vm.startPrank(B);
        vm.expectRevert(abi.encodeWithSelector(IERCXXXX.ERCXXXXNotHeld.selector, B, 10, 1));
        t.transferSlices(A, _one(10), _one(1));
        vm.expectRevert(abi.encodeWithSelector(IERCXXXX.ERCXXXXNotHeld.selector, B, 10, 1));
        t.consolidateSlices(_one(10), _one(1));
        vm.expectRevert(abi.encodeWithSelector(IERCXXXX.ERCXXXXNotHeld.selector, B, 120, 10));
        t.consolidateSlices(_one(120), _one(10));
        vm.expectRevert();
        t.consolidateSlices(_one(55), _one(0));
        vm.expectRevert();
        t.consolidateSlices(new uint256[](0), new uint256[](0));
        vm.expectRevert();
        t.consolidateSlices(_two(55, 100), _one(1));
        vm.expectRevert();
        t.consolidateSlices(_two(100, 55), _two(1, 1));
        vm.expectRevert();
        t.consolidateSlices(_two(100, 105), _two(10, 1));
        vm.stopPrank();
        vm.prank(A);
        vm.expectRevert();
        t.consolidateSlices(_one(55), _one(1));

        // 4
        vm.getRecordedLogs();
        vm.prank(B);
        assertEq(t.consolidateSlices(_two(55, 100), _two(5, 10)), 125, "step 4 newStart");
        _checkConsolidated(vm.getRecordedLogs(), B, _two(55, 100), _two(125, 130), _two(5, 10));
        assertEq(t.serialsIssued(), 140);
        assertEq(t.balanceOf(B), 30);
        _assertExactly(_holdMask(B, 140), _one(110), _one(140), "step 4 B ranges");
        _assertConsolidatedSpan(10, true, 100, 10);
        _assertConsolidatedSpan(100, true, 130, 10);
        _assertConsolidatedSpan(130, false, 0, 10);
    }

    // ───────────────────────── Tokens that keep consolidation closed ─────────────────────────
    // Clause 7 of "Consolidation" of the draft: a contract that does not open consolidation MAY make
    // consolidateSlices revert for every caller; such a contract has no consolidated serials.
    // The tests below consolidate slices with valid arguments, all held by the caller, not frozen and of the same
    // class, and require the call to revert with an error that is not about the arguments, holding, transferability
    // or consolidatability (otherwise the revert might have another cause); the state does not change, and
    // consolidatedSpanAt reports no consolidated serials.

    /// @dev account consolidating (starts, amounts) must revert because consolidation is closed, and the state does
    ///      not change.
    function _assertConsolidationClosed(address account, uint256[] memory starts, uint256[] memory amounts) internal {
        uint256 issued = t.serialsIssued();
        uint256 bal = t.balanceOf(account);
        uint256 supply = t.totalSupply();
        uint256 slices = t.sliceCount(account);
        vm.prank(account);
        try t.consolidateSlices(starts, amounts) returns (uint256) {
            fail("consolidateSlices succeeded on a token that keeps consolidation closed");
        } catch (bytes memory err) {
            assertEq(closedConsolidationErrorProblem(err), "", "closed consolidation reverted for another reason");
        }
        assertEq(t.serialsIssued(), issued, "closed consolidation changed serialsIssued");
        assertEq(t.balanceOf(account), bal, "closed consolidation changed balanceOf");
        assertEq(t.totalSupply(), supply, "closed consolidation changed totalSupply");
        assertEq(t.sliceCount(account), slices, "closed consolidation changed sliceCount");
        _assertNothingConsolidated();
    }

    /// @dev No serial is consolidated: for every issued serial, consolidatedSpanAt returns
    ///      (false, 0, 1..issued - serial), and for one not issued it returns (false, 0, 0) (clause 9 of
    ///      "Consolidation" of the draft).
    function _assertNothingConsolidated() internal view {
        uint256 n = t.serialsIssued();
        for (uint256 s; s < n; ++s) {
            (bool c, uint256 succ, uint256 len) = t.consolidatedSpanAt(s);
            assertFalse(c, "consolidatedSpanAt.consolidated on a closed token");
            assertEq(succ, 0, "consolidatedSpanAt.successor on a closed token");
            assertTrue(len >= 1 && len <= n - s, "consolidatedSpanAt.length on a closed token");
        }
        _assertConsolidatedSpan(n, false, 0, 0);
        _assertConsolidatedSpan(n + 1000, false, 0, 0);
        _assertConsolidatedSpan(type(uint256).max, false, 0, 0);
    }

    /// @dev The holdings of step 1 of the consolidation sequence; then the consolidations of steps 2 and 4 both
    ///      revert because consolidation is closed.
    function _closedSequence() internal {
        _mint(A, 100);
        vm.prank(A);
        t.transferSlices(B, _three(10, 30, 50), _three(10, 10, 10));
        _assertNothingConsolidated();
        vm.getRecordedLogs();
        _assertConsolidationClosed(B, _three(10, 30, 50), _three(10, 10, 5));
        _assertConsolidationClosed(B, _one(10), _one(10));
        _assertConsolidationClosed(A, _two(0, 60), _two(10, 40));
        assertEq(vm.getRecordedLogs().length, 0, "a closed consolidation emitted events");
        _assertExactly(_holdMask(B, 100), _three(10, 30, 50), _three(20, 40, 60), "closed: B ranges");
        // calls with invalid arguments of course revert as well
        vm.startPrank(B);
        vm.expectRevert();
        t.consolidateSlices(new uint256[](0), new uint256[](0));
        vm.expectRevert();
        t.consolidateSlices(_one(55), _one(0));
        vm.stopPrank();
    }

    function test_sequenceConsolidation() public {
        if (!hasConsol) return _closedSequence();
        _consolidationSequence();
    }

    function test_sequenceConsolidation_freezeSteps() public {
        vm.skip(!hasFreeze);
        if (!hasConsol) return _closedFreezeSteps();
        _consolidationSequence();
        vm.getRecordedLogs();

        // 5
        vm.prank(admin);
        t.freezeSlice(100, 5, r1);
        _assertExactly(
            _freezeEventMask(vm.getRecordedLogs(), FROZEN_SIG, r1, 140), _two(100, 130), _two(105, 135), "step 5"
        );
        (bool f, uint256 len) = t.frozenSpanAt(10);
        assertFalse(f, "step 5: not propagated to the old serial");
        assertEq(t.frozenBalanceOf(B), 5);

        // 6
        vm.prank(admin);
        t.freezeSlice(10, 10, r2);
        _assertExactly(
            _freezeEventMask(vm.getRecordedLogs(), FROZEN_SIG, r2, 140),
            _three(10, 100, 130),
            _three(20, 110, 140),
            "step 6"
        );
        assertEq(t.frozenBalanceOf(B), 10);
        (uint256 amt, uint256 entries) = _reasonAmount(B, r1);
        assertEq(entries, 2);
        assertEq(amt, 5);
        (amt,) = _reasonAmount(B, r2);
        assertEq(amt, 10);
        _assertTransferableForAnyTo(B, 20);
        vm.prank(B);
        vm.expectRevert(abi.encodeWithSelector(IERCXXXX.ERCXXXXNotTransferable.selector, B, A, 135, 1));
        t.transferSlices(A, _one(135), _one(1));
        vm.prank(B);
        vm.expectRevert(abi.encodeWithSelector(IERCXXXX.ERCXXXXNotConsolidatable.selector, B, 130, 10));
        t.consolidateSlices(_one(130), _one(10));

        // 7
        vm.prank(admin);
        t.unfreezeSlice(10, 10, r2);
        _assertExactly(
            _freezeEventMask(vm.getRecordedLogs(), UNFROZEN_SIG, r2, 140),
            _three(10, 100, 130),
            _three(20, 110, 140),
            "step 7"
        );
        assertEq(t.frozenBalanceOf(B), 5);
        (amt, entries) = _reasonAmount(B, r1);
        assertEq(entries, 1);
        assertEq(amt, 5);
        (f, len) = t.frozenSpanAt(130);
        assertTrue(f);
        assertTrue(len >= 1 && len <= 5);
        (f, len) = t.frozenSpanAt(135);
        assertFalse(f);
        assertTrue(len >= 1 && len <= 5);

        // 8
        vm.prank(admin);
        t.unfreezeSlice(100, 5, r1);
        assertEq(t.frozenBalanceOf(B), 0);
        vm.prank(B);
        assertEq(t.consolidateSlices(_one(130), _one(10)), 140);
        assertEq(t.balanceOf(A), 70);
        assertEq(t.balanceOf(B), 30);
        assertEq(t.totalSupply(), 100);
        assertEq(t.serialsIssued(), 150);
    }

    /// @dev When consolidation is closed, freezes do not propagate: the freeze events cover only the slice named in
    ///      the call; slices cannot be consolidated whether frozen or not.
    function _closedFreezeSteps() internal {
        _closedSequence();
        vm.getRecordedLogs();
        vm.prank(admin);
        t.freezeSlice(10, 10, r2);
        _assertExactly(_freezeEventMask(vm.getRecordedLogs(), FROZEN_SIG, r2, 100), _one(10), _one(20), "closed freeze");
        assertEq(t.frozenBalanceOf(B), 10);
        _assertConsolidationClosed(B, _one(10), _one(10));
        _assertConsolidationClosed(B, _one(30), _one(10));
        vm.prank(admin);
        t.unfreezeSlice(10, 10, r2);
        _assertExactly(
            _freezeEventMask(vm.getRecordedLogs(), UNFROZEN_SIG, r2, 100), _one(10), _one(20), "closed unfreeze"
        );
        assertEq(t.frozenBalanceOf(B), 0);
        _assertConsolidationClosed(B, _three(10, 30, 50), _three(10, 10, 10));
    }

    /// @dev When consolidation is closed, slices of the same class cannot be consolidated either, and the classes do
    ///      not change.
    function _closedClassSteps() internal {
        vm.startPrank(admin);
        t.mintWithClass(A, 10, w);
        t.mint(B, 1);
        t.mint(A, 10);
        t.mintWithClass(A, 10, w);
        vm.stopPrank();
        vm.getRecordedLogs();
        _assertConsolidationClosed(A, _two(0, 21), _two(10, 10));
        _assertConsolidationClosed(A, _one(11), _one(10));
        _assertConsolidationClosed(A, _two(0, 11), _two(10, 5));
        assertEq(vm.getRecordedLogs().length, 0, "a closed consolidation emitted events");
        (uint256 amt, uint256 entries) = _classAmount(A, w);
        assertEq(entries, 2);
        assertEq(amt, 20);
        (bytes32 cid, uint256 len) = t.classSpanAt(31);
        assertEq(cid, bytes32(0));
        assertEq(len, 0, "serial 31 was never issued");
    }

    function test_sequenceConsolidation_classes() public {
        vm.skip(!hasClass);
        if (!hasConsol) return _closedClassSteps();
        // 1
        vm.startPrank(admin);
        t.mintWithClass(A, 10, w);
        t.mint(B, 1);
        t.mint(A, 10);
        t.mintWithClass(A, 10, w);
        vm.stopPrank();
        vm.getRecordedLogs();

        // 2
        vm.startPrank(A);
        vm.expectRevert(abi.encodeWithSelector(IERCXXXX.ERCXXXXNotConsolidatable.selector, A, 11, 5));
        t.consolidateSlices(_two(0, 11), _two(10, 5));
        vm.expectRevert(abi.encodeWithSelector(IERCXXXX.ERCXXXXNotConsolidatable.selector, A, 21, 5));
        t.consolidateSlices(_two(11, 21), _two(5, 5));
        vm.expectRevert(abi.encodeWithSelector(IERCXXXX.ERCXXXXNotConsolidatable.selector, A, 20, 2));
        t.consolidateSlices(_one(20), _one(2));

        // 3
        assertEq(t.consolidateSlices(_two(0, 21), _two(10, 10)), 31);
        vm.stopPrank();
        {
            Vm.Log[] memory logs = vm.getRecordedLogs();
            _checkConsolidated(logs, A, _two(0, 21), _two(31, 41), _two(10, 10));
            bool[] memory cm = new bool[](51);
            uint256 lastConsol;
            for (uint256 i; i < logs.length; ++i) {
                if (logs[i].emitter != address(t)) continue;
                if (logs[i].topics[0] == CONSOL_SIG) lastConsol = i;
                if (logs[i].topics[0] != CLASS_SET_SIG) continue;
                assertGt(i, lastConsol, "SliceClassified before a SliceConsolidated");
                (uint256 start, uint256 amount, bytes32 c) = abi.decode(logs[i].data, (uint256, uint256, bytes32));
                assertEq(c, w);
                for (uint256 s = start; s < start + amount; ++s) {
                    cm[s] = true;
                }
            }
            _assertExactly(cm, _one(31), _one(51), "step 3 SliceClassified coverage");
        }
        (bytes32 cid, uint256 len) = t.classSpanAt(31);
        assertEq(cid, w);
        assertTrue(len >= 1 && len <= 20);
        (uint256 amt, uint256 entries) = _classAmount(A, w);
        assertEq(entries, 2);
        assertEq(amt, 20);
        (amt,) = _classAmount(A, bytes32(0));
        assertEq(amt, 10);
        assertEq(t.balanceOf(A), 30);

        // 4
        vm.prank(A);
        assertEq(t.consolidateSlices(_one(11), _one(10)), 51);
        {
            Vm.Log[] memory logs = vm.getRecordedLogs();
            for (uint256 i; i < logs.length; ++i) {
                assertTrue(logs[i].topics[0] != CLASS_SET_SIG, "step 4 SliceClassified for the default class");
            }
        }
        (cid, len) = t.classSpanAt(51);
        assertEq(cid, bytes32(0));
        assertTrue(len >= 1 && len <= 10);
    }

    // ───────────────────────── Acceptance check sequence ─────────────────────────

    /// @dev The number of SliceTransferred events from `from` to `to` emitted by this call.
    function _serialTransferCount(Vm.Log[] memory logs, address from, address to) internal view returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory lg = logs[i];
            if (lg.emitter != address(t) || lg.topics[0] != SERIAL_SIG) continue;
            if (address(uint160(uint256(lg.topics[1]))) == from && address(uint160(uint256(lg.topics[2]))) == to) ++n;
        }
    }

    /// @dev The three contracts of the sequence. P does not implement ERC-165; R accepts when slices is not greater
    ///      than 1; S always reverts and has in addition the function pull.
    function _acceptanceParties() internal returns (address P, address R, PullingReceiver S) {
        P = address(new NoInterfaceContract());
        R = address(new RangeLimitReceiver(1));
        S = new PullingReceiver(address(t));
        // Preconditions: A and C have no code; P, R and S have code.
        assertEq(A.code.length, 0);
        assertEq(C.code.length, 0);
        assertGt(P.code.length, 0);
    }

    function test_sequenceAcceptance() public {
        vm.skip(!hasAccept);
        assertTrue(t.supportsInterface(ACCEPTANCE_CHECK_ID));
        (address P, address R, PullingReceiver S) = _acceptanceParties();

        // 1 (issuance is performed by a restricted caller and does not query receiving contracts)
        _mint(A, 100);
        _assertExactly(_holdMask(A, 100), _one(0), _one(100), "step 1 A ranges");
        vm.prank(A);
        assertTrue(t.transferSlices(P, _one(0), _one(1)));
        vm.prank(A);
        assertTrue(t.transferSlices(C, _one(1), _one(1)));

        // 2
        vm.getRecordedLogs();
        vm.prank(A);
        assertTrue(t.transferSlices(R, _one(10), _one(1)));
        assertEq(_serialTransferCount(vm.getRecordedLogs(), A, R), 1, "step 2 ranges");
        vm.prank(A);
        vm.expectRevert(abi.encodeWithSelector(IERCXXXX.ERCXXXXTransferRefused.selector, A, R, 2));
        t.transferSlices(R, _two(20, 22), _two(1, 1));
        vm.getRecordedLogs(); // vm.recordLogs also records the events emitted by the reverted call
        vm.expectEmit(address(t));
        emit IERC20.Transfer(A, R, 0);
        _send(A, R, 0);
        assertEq(t.transferableBalanceOf(A, R), 97);
        assertEq(t.balanceOf(A), 97);

        // 3
        vm.prank(A);
        vm.expectRevert();
        t.transferSlices(address(S), _one(30), _one(1));
        vm.startPrank(A);
        assertTrue(t.approve(address(S), 5));
        assertTrue(t.approve(C, 5));
        vm.stopPrank();
        vm.prank(C);
        vm.expectRevert();
        t.transferFrom(A, address(S), 5);
        vm.prank(Z);
        S.pull(A, 5);
        assertEq(t.balanceOf(A), 92);
        assertEq(t.balanceOf(P), 1);
        assertEq(t.balanceOf(C), 1);
        assertEq(t.balanceOf(R), 1);
        assertEq(t.balanceOf(address(S)), 5);
        assertEq(t.totalSupply(), 100);
        assertEq(t.allowance(A, C), 5);
    }

    /// @dev The last paragraph of the sequence: a contract that does not support the acceptance check returns false
    ///      for 0x29543499, and none of the calls above that transfer units to R or S is refused.
    ///      Also checks that such a contract does not query recipients at all.
    function test_sequenceAcceptance_unsupported() public {
        vm.skip(hasAccept);
        assertFalse(t.supportsInterface(ACCEPTANCE_CHECK_ID));
        (address P, address R, PullingReceiver S) = _acceptanceParties();
        address[3] memory contracts = [P, R, address(S)];
        for (uint256 i; i < 3; ++i) {
            vm.expectCall(contracts[i], abi.encodeWithSelector(ERC165_ID), 0);
            vm.expectCall(contracts[i], abi.encodeWithSelector(ACCEPT), 0);
        }

        // 1
        _mint(A, 100);
        vm.startPrank(A);
        assertTrue(t.transferSlices(P, _one(0), _one(1)));
        assertTrue(t.transferSlices(C, _one(1), _one(1)));
        // 2
        assertTrue(t.transferSlices(R, _one(10), _one(1)));
        assertTrue(t.transferSlices(R, _two(20, 22), _two(1, 1)));
        assertTrue(t.transfer(R, 0));
        // 3
        assertTrue(t.transferSlices(address(S), _one(30), _one(1)));
        assertTrue(t.approve(address(S), 5));
        assertTrue(t.approve(C, 5));
        vm.stopPrank();
        vm.prank(C);
        assertTrue(t.transferFrom(A, address(S), 5));
        vm.prank(Z);
        S.pull(A, 5);
        assertEq(t.balanceOf(A), 84);
        assertEq(t.balanceOf(P), 1);
        assertEq(t.balanceOf(C), 1);
        assertEq(t.balanceOf(R), 3);
        assertEq(t.balanceOf(address(S)), 11);
        assertEq(t.totalSupply(), 100);
        assertEq(t.allowance(A, C), 0);
    }
}

// ───────────────────────── Tokens under test ─────────────────────────

contract DraftSequences_CoreStack is DraftSequencesBase, TargetCoreStack {}

contract DraftSequences_CoreSorted is DraftSequencesBase, TargetCoreSorted {}

contract DraftSequences_FreezeStack is DraftSequencesBase, TargetFreezeStack {}

contract DraftSequences_FreezeSorted is DraftSequencesBase, TargetFreezeSorted {}

contract DraftSequences_ClassStack is DraftSequencesBase, TargetClassStack {}

contract DraftSequences_ClassSorted is DraftSequencesBase, TargetClassSorted {}

contract DraftSequences_BothStack is DraftSequencesBase, TargetBothStack {}

contract DraftSequences_BothSorted is DraftSequencesBase, TargetBothSorted {}

contract DraftSequences_BothStackTight is DraftSequencesBase, TargetBothStackTight {}

contract DraftSequences_BothSortedTight is DraftSequencesBase, TargetBothSortedTight {}

contract DraftSequences_AcceptStack is DraftSequencesBase, TargetAcceptStack {
    function _mustAccept() internal pure override returns (bool) {
        return true;
    }
}

contract DraftSequences_AcceptSorted is DraftSequencesBase, TargetAcceptSorted {
    function _mustAccept() internal pure override returns (bool) {
        return true;
    }
}

contract DraftSequences_AllStack is DraftSequencesBase, TargetAllStack {
    function _mustAccept() internal pure override returns (bool) {
        return true;
    }
}

contract DraftSequences_AllSorted is DraftSequencesBase, TargetAllSorted {
    function _mustAccept() internal pure override returns (bool) {
        return true;
    }
}

contract DraftSequences_CoreConsolStack is DraftSequencesBase, TargetCoreConsolStack {}

contract DraftSequences_CoreConsolSorted is DraftSequencesBase, TargetCoreConsolSorted {}

contract DraftSequences_FreezeConsolStack is DraftSequencesBase, TargetFreezeConsolStack {}

contract DraftSequences_FreezeConsolSorted is DraftSequencesBase, TargetFreezeConsolSorted {}

contract DraftSequences_ClassConsolStack is DraftSequencesBase, TargetClassConsolStack {}

contract DraftSequences_ClassConsolSorted is DraftSequencesBase, TargetClassConsolSorted {}

contract DraftSequences_BothConsolStack is DraftSequencesBase, TargetBothConsolStack {}

contract DraftSequences_BothConsolSorted is DraftSequencesBase, TargetBothConsolSorted {}

// The second rule ("best fit in a bounded window"). The assertions of the draft do not depend on the selection
// rule, so these run the same sequences as under the default rule.

contract DraftSequences_CoreStackWindow is DraftSequencesBase, TargetCoreStackWindow {}

contract DraftSequences_BothStackWindow is DraftSequencesBase, TargetBothStackWindow {}

contract DraftSequences_BothStackWindowTight is DraftSequencesBase, TargetBothStackWindowTight {}

contract DraftSequences_BothConsolStackWindow is DraftSequencesBase, TargetBothConsolStackWindow {}

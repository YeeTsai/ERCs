// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20Errors} from "../../contracts/utils/IERC20.sol";
import {IERCXXXX} from "../../contracts/spec/IERCXXXX.sol";
import {ERCXXXX} from "../../contracts/ERCXXXX.sol";
import {ERCXXXXFreezable} from "../../contracts/extensions/ERCXXXXFreezable.sol";
import {Rule, TestAdmin} from "../presets/Presets.sol";
import "../presets/Targets.sol";

/// @dev The two groups of functions that are this implementation's own: the forced operations that take a position
///      hint (forcedTransferSliceAt / destroySliceAt / serialPositionOf) and the tidying function (tidySlices). Each
///      of the four requirements that clause 9 of "Forced transfer and destruction" in the draft places on other
///      forced operation functions has its assertions: the events and their order (clauses 5 and 7), the
///      restriction of callers (clause 8), and that the serials are frozen first (clause 1); the tests also assert
///      that a wrong hint reverts and changes nothing, and that the checks are made in the same order as in the
///      functions without a hint.
///      A token without these functions is skipped.
abstract contract ForcedAtAndTidyBase is Test, TokenTarget {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event SliceTransferred(address indexed from, address indexed to, uint256 start, uint256 amount);
    event SliceForciblyTransferred(address indexed from, address indexed to, uint256 start, uint256 amount);

    bytes32 internal constant DEFAULT = bytes32(0);
    bytes32 internal constant FROZEN = keccak256("ERCXXXX.pile.frozen");
    bytes32 internal constant R = "r";
    bytes32 internal constant W = "w";

    ITestToken internal t;
    bool internal hasFreeze;
    bool internal hasClass;
    bool internal hasHints;
    bool internal hasTidy;
    address internal admin = makeAddr("admin");
    address internal A = makeAddr("A");
    address internal B = makeAddr("B");
    address internal C = makeAddr("C");
    address internal D = makeAddr("D");
    address internal Z = makeAddr("anyone");

    /// @dev The backend is the slice stack (otherwise it is the sorted array).
    function _stack() internal pure virtual returns (bool);

    function setUp() public {
        (t, hasFreeze, hasClass,) = _deployToken(admin);
        (bool ok,) = address(t).staticcall(abi.encodeCall(ITestToken.serialPositionOf, (A, 0)));
        hasHints = ok;
        (ok,) = address(t).call(abi.encodeCall(ITestToken.tidySlices, (A, DEFAULT, 0)));
        hasTidy = ok;
        vm.startPrank(admin);
        if (hasFreeze) t.setReasonInfo(R, "Reason", "");
        if (hasClass) t.defineClass(W, Rule.Allowlist, 0, "Designated recipients only", "");
        vm.stopPrank();
    }

    // ───────────────────────── Helpers ─────────────────────────

    function _mint(address to, uint256 v) internal {
        vm.prank(admin);
        t.mint(to, v);
    }

    function _send(address from, address to, uint256 v) internal {
        vm.prank(from);
        t.transfer(to, v);
    }

    function _freeze(uint256 start, uint256 amount) internal {
        vm.prank(admin);
        t.freezeSlice(start, amount, R);
    }

    function _unfreeze(uint256 start, uint256 amount) internal {
        vm.prank(admin);
        t.unfreezeSlice(start, amount, R);
    }

    function _tidy(address account, bytes32 pile, uint256 maxMoves) internal returns (uint256) {
        vm.prank(Z); // anyone can call it
        return t.tidySlices(account, pile, maxMoves);
    }

    function _pos(address account, uint256 serial) internal view returns (bytes32 pile, uint256 index) {
        bool held;
        (held, pile, index,,) = t.serialPositionOf(account, serial);
        assertTrue(held, "serial not held");
    }

    function _assertPos(address account, uint256 serial, bytes32 pile, uint256 index, uint256 rs, uint256 ra)
        internal
        view
    {
        (bool held, bytes32 p, uint256 i, uint256 s, uint256 a) = t.serialPositionOf(account, serial);
        assertTrue(held, "held");
        assertEq(p, pile, "pile");
        assertEq(i, index, "index");
        assertEq(s, rs, "rangeStart");
        assertEq(a, ra, "rangeAmount");
    }

    function _stale(address account, bytes32 pile, uint256 index) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(ERCXXXX.ERCXXXXStaleHint.selector, account, pile, index);
    }

    function _destroyAt(address from, uint256 start, uint256 amount, bytes32 pile, uint256 index) internal {
        vm.prank(admin);
        t.destroySliceAt(from, start, amount, pile, index);
    }

    /// @dev The admin calls `data`, which is expected to revert with `err`.
    function _expectRevertAs(bytes memory data, bytes memory err) internal {
        vm.prank(admin);
        (bool ok, bytes memory ret) = address(t).call(data);
        assertFalse(ok, "call was expected to revert");
        assertEq(ret, err, "revert data");
    }

    /// @dev The set of serials held by `account` (among the first `size` serials).
    function _holdMask(address account, uint256 size) internal view returns (bool[] memory mask) {
        mask = new bool[](size);
        uint256 n = t.sliceCount(account);
        for (uint256 i; i < n; ++i) {
            (uint256 start, uint256 amount) = t.sliceAt(account, i);
            for (uint256 s = start; s < start + amount; ++s) {
                mask[s] = true;
            }
        }
    }

    function _skipUnless(bool supported) internal returns (bool skip) {
        if (!supported) {
            vm.skip(true);
            return true;
        }
    }

    function _skipUnlessHints() internal returns (bool skip) {
        return _skipUnless(hasFreeze && hasHints);
    }

    // ───────────────────────── Forced operations that take a position hint ─────────────────────────

    function test_destroyAt_eventsAndState() public {
        if (_skipUnlessHints()) return;
        _mint(A, 100);
        _freeze(20, 30); // [20,50)
        _assertPos(A, 25, DEFAULT, 0, 0, 100);

        vm.expectEmit(address(t));
        emit SliceTransferred(A, address(0), 25, 10);
        vm.expectEmit(address(t));
        emit Transfer(A, address(0), 10);
        vm.expectEmit(address(t));
        emit SliceForciblyTransferred(A, address(0), 25, 10);
        vm.recordLogs();
        _destroyAt(A, 25, 10, DEFAULT, 0);
        assertEq(vm.getRecordedLogs().length, 3, "exactly three events");

        assertEq(t.balanceOf(A), 90);
        assertEq(t.totalSupply(), 90);
        assertEq(t.frozenBalanceOf(A), 20);
        (bool held,,,,) = t.serialPositionOf(A, 30);
        assertFalse(held, "destroyed serial still held");
        _send(A, B, 70); // the part that is not frozen is transferable as usual
        assertEq(t.balanceOf(A), 20);
    }

    function test_forcedTransferAt_eventsAndState() public {
        if (_skipUnlessHints()) return;
        _mint(A, 100);
        _freeze(60, 40);
        _send(A, B, 10); // selection moves [60,100) into the frozen pile
        _assertPos(A, 70, FROZEN, 0, 60, 40);

        vm.expectEmit(address(t));
        emit SliceTransferred(A, C, 60, 40);
        vm.expectEmit(address(t));
        emit Transfer(A, C, 40);
        vm.expectEmit(address(t));
        emit SliceForciblyTransferred(A, C, 60, 40);
        vm.prank(admin);
        t.forcedTransferSliceAt(A, C, 60, 40, FROZEN, 0);

        assertEq(t.balanceOf(A), 50);
        assertEq(t.balanceOf(C), 40);
        assertEq(t.frozenBalanceOf(C), 40);
        assertEq(t.totalSupply(), 100);
        _assertPos(C, 60, FROZEN, 0, 60, 40); // the payee puts them in the pile where they belong by their state
    }

    /// @dev A hint that points to the wrong place only reverts; it does not touch other serials.
    function test_wrongHintRevertsAndChangesNothing() public {
        if (_skipUnlessHints()) return;
        _mint(A, 100); // [0,100)
        _mint(B, 1); //   [100,101)
        _mint(A, 100); // [101,201)
        _freeze(0, 201);
        _assertPos(A, 0, DEFAULT, 0, 0, 100);
        _assertPos(A, 150, DEFAULT, 1, 101, 100);

        bytes4 sel = ITestToken.destroySliceAt.selector;
        // the target is in slice 1, the hint points to slice 0
        _expectRevertAs(abi.encodeWithSelector(sel, A, 101, 100, DEFAULT, 0), _stale(A, DEFAULT, 0));
        // extends beyond slice 0 ([100,101) is B's)
        _expectRevertAs(abi.encodeWithSelector(sel, A, 50, 60, DEFAULT, 0), _stale(A, DEFAULT, 0));
        // wrong account
        _expectRevertAs(abi.encodeWithSelector(sel, B, 0, 100, DEFAULT, 0), _stale(B, DEFAULT, 0));
        // the frozen pile is empty
        _expectRevertAs(abi.encodeWithSelector(sel, A, 0, 100, FROZEN, 0), _stale(A, FROZEN, 0));
        // index out of bounds
        _expectRevertAs(abi.encodeWithSelector(sel, A, 0, 100, DEFAULT, 2), _stale(A, DEFAULT, 2));
        // a pile that does not exist
        _expectRevertAs(abi.encodeWithSelector(sel, A, 0, 100, bytes32("nope"), 0), _stale(A, bytes32("nope"), 0));
        _expectRevertAs(
            abi.encodeCall(ITestToken.forcedTransferSliceAt, (A, C, 101, 100, DEFAULT, 0)), _stale(A, DEFAULT, 0)
        );

        assertEq(t.balanceOf(A), 200);
        assertEq(t.balanceOf(B), 1);
        assertEq(t.totalSupply(), 201);
        assertEq(t.sliceCount(A), 2);
        _assertPos(A, 0, DEFAULT, 0, 0, 100);
        _assertPos(A, 150, DEFAULT, 1, 101, 100);
    }

    /// @dev The checks other than locating are the same as in the function without a hint, and in the same order:
    ///      even when the hint is wrong as well, the same error is reported first.
    function test_checksMatchSearchVariant() public {
        if (_skipUnlessHints()) return;
        _mint(A, 100);
        _freeze(0, 50);
        uint256 bad = 7; // a wrong index
        // the second half is not frozen
        _sameError(
            abi.encodeCall(ITestToken.destroySlice, (A, 40, 20)),
            abi.encodeCall(ITestToken.destroySliceAt, (A, 40, 20, DEFAULT, bad)),
            abi.encodeWithSelector(ERCXXXXFreezable.ERCXXXXNotFrozen.selector, 40, 20)
        );
        // zero amount
        _sameError(
            abi.encodeCall(ITestToken.destroySlice, (A, 0, 0)),
            abi.encodeCall(ITestToken.destroySliceAt, (A, 0, 0, DEFAULT, bad)),
            abi.encodeWithSelector(ERCXXXX.ERCXXXXInvalidRange.selector, 0, 0)
        );
        // not issued
        _sameError(
            abi.encodeCall(ITestToken.destroySlice, (A, 1000, 1)),
            abi.encodeCall(ITestToken.destroySliceAt, (A, 1000, 1, DEFAULT, bad)),
            abi.encodeWithSelector(IERCXXXX.ERCXXXXNotHeld.selector, A, 1000, 1)
        );
        // the payee is the zero address or from itself
        _sameError(
            abi.encodeCall(ITestToken.forcedTransferSlice, (A, A, 0, 10)),
            abi.encodeCall(ITestToken.forcedTransferSliceAt, (A, A, 0, 10, DEFAULT, bad)),
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, A)
        );
        _sameError(
            abi.encodeCall(ITestToken.forcedTransferSlice, (A, address(0), 0, 10)),
            abi.encodeCall(ITestToken.forcedTransferSliceAt, (A, address(0), 0, 10, DEFAULT, bad)),
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0))
        );
        assertEq(t.balanceOf(A), 100);
    }

    function _sameError(bytes memory search, bytes memory hinted, bytes memory err) internal {
        _expectRevertAs(search, err);
        _expectRevertAs(hinted, err);
    }

    function test_hintedOpsAreRestricted() public {
        if (_skipUnlessHints()) return;
        _mint(A, 100);
        _freeze(0, 100);
        vm.prank(A);
        vm.expectRevert(TestAdmin.NotAdmin.selector);
        t.destroySliceAt(A, 0, 100, DEFAULT, 0);
        vm.prank(Z);
        vm.expectRevert(TestAdmin.NotAdmin.selector);
        t.forcedTransferSliceAt(A, Z, 0, 100, DEFAULT, 0);
        assertEq(t.balanceOf(A), 100);
    }

    /// @dev A position in the frozen pile: incoming transfers from third parties, the holder's own outgoing transfers
    ///      and receipts do not change it (only a forced transfer can put something into another account's frozen
    ///      pile). The indexes of sliceAt do drift, so a hint cannot use them.
    function test_frozenPilePositionSurvivesOrdinaryActivity() public {
        if (_skipUnlessHints()) return;
        _mint(A, 100);
        _freeze(60, 40);
        _send(A, B, 10); // A: default pile [0,50), frozen pile [60,100)
        _assertPos(A, 60, FROZEN, 0, 60, 40);
        uint256 countBefore = t.sliceCount(A);

        _mint(C, 50);
        for (uint256 i; i < 5; ++i) {
            _send(C, A, 1);
        }
        _send(A, D, 20);
        _mint(A, 7);
        assertTrue(t.sliceCount(A) != countBefore, "enumeration was expected to change");

        _assertPos(A, 60, FROZEN, 0, 60, 40);
        _destroyAt(A, 60, 40, FROZEN, 0);
        assertEq(t.frozenBalanceOf(A), 0);
    }

    /// @dev A position in the default pile: on the slice stack an incoming transfer from a third party touches only
    ///      the top of the stack, and the position does not change; when the sorted array receives a slice with
    ///      smaller serials, the indexes after it move up.
    function test_defaultPileReceiptKeepsStackPositionShiftsSorted() public {
        if (_skipUnlessHints()) return;
        _mint(A, 50); // [0,50)
        _mint(B, 50); // [50,100)
        _mint(C, 1); //  [100,101)
        _mint(A, 50); // [101,151)
        _freeze(101, 10);
        _assertPos(A, 101, DEFAULT, 1, 101, 50);

        _send(B, A, 10); // A receives [90,100), adjacent to none of the slices it already holds
        if (_stack()) {
            _assertPos(A, 101, DEFAULT, 1, 101, 50);
        } else {
            _assertPos(A, 101, DEFAULT, 2, 101, 50);
            _expectRevertAs(
                abi.encodeCall(ITestToken.destroySliceAt, (A, 101, 10, DEFAULT, 1)), _stale(A, DEFAULT, 1)
            );
        }
        (bytes32 p, uint256 i) = _pos(A, 101);
        _destroyAt(A, 101, 10, p, i);
        assertEq(t.frozenBalanceOf(A), 0);
        assertEq(t.balanceOf(A), 100);
    }

    /// @dev Anyone who calls the tidying function can move frozen slices into the frozen pile, which invalidates the
    ///      old position.
    function test_tidyByAnyoneInvalidatesHint() public {
        if (_skipUnless(hasTidy && hasFreeze && hasHints)) return;
        _mint(A, 100);
        _freeze(60, 40);
        _assertPos(A, 60, DEFAULT, 0, 0, 100);
        assertEq(_tidy(A, DEFAULT, 10), 1);
        _expectRevertAs(abi.encodeCall(ITestToken.destroySliceAt, (A, 60, 40, DEFAULT, 0)), _stale(A, DEFAULT, 0));
        _assertPos(A, 60, FROZEN, 0, 60, 40);
        _destroyAt(A, 60, 40, FROZEN, 0);
        assertEq(t.balanceOf(A), 60);
    }

    /// @dev After a whole slice is taken from a pile, the positions of other slices in that pile can change: the
    ///      slice stack moves the last slice into the vacated position, and the sorted array moves the later slices
    ///      forward.
    function test_fullRemovalMovesOtherPositions() public {
        if (_skipUnless(hasTidy && hasFreeze && hasHints)) return;
        _mint(A, 10); // [0,10)
        _mint(B, 1);
        _mint(A, 10); // [11,21)
        _mint(B, 1);
        _mint(A, 10); // [22,32)
        _freeze(0, 32);
        assertEq(_tidy(A, DEFAULT, 10), 3); // all three slices go into the frozen pile
        (bytes32 p0, uint256 i0) = _pos(A, 0);
        (bytes32 p2, uint256 i2) = _pos(A, 22);
        assertEq(p0, FROZEN);
        assertEq(p2, FROZEN);
        // slice stack: tidying moves slices starting from the top of the stack, so [22,32) is slice 0 and [0,10)
        // slice 2; on the sorted array it is the other way round.
        assertEq(i0, _stack() ? 2 : 0);
        assertEq(i2, _stack() ? 0 : 2);

        (bytes32 pf, uint256 first) = _stack() ? (p2, i2) : (p0, i0);
        (uint256 fs, uint256 ls) = _stack() ? (uint256(22), uint256(0)) : (uint256(0), uint256(22));
        _destroyAt(A, fs, 10, pf, first); // take slice 0
        (bytes32 pl, uint256 il) = _stack() ? (p0, i0) : (p2, i2);
        _expectRevertAs(abi.encodeCall(ITestToken.destroySliceAt, (A, ls, 10, pl, il)), _stale(A, pl, il));
        (bytes32 pn, uint256 inew) = _pos(A, ls);
        assertEq(inew, _stack() ? 0 : 1);
        _destroyAt(A, ls, 10, pn, inew);
        assertEq(t.balanceOf(A), 10);
    }

    /// @dev After an unfreeze, a transfer by the holder that checks the frozen pile in place and takes the unfrozen
    ///      slice can also change the positions of other slices in that pile.
    function test_unfreezeThenTransferMayMovePositions() public {
        if (_skipUnless(hasTidy && hasFreeze && hasHints)) return;
        _mint(A, 100);
        _freeze(90, 10); // X
        _freeze(70, 10); // Y
        assertEq(_tidy(A, DEFAULT, 10), 2);
        (bytes32 py, uint256 iy) = _pos(A, 70);
        assertEq(py, FROZEN);

        _unfreeze(90, 10);
        _send(A, B, 90); // transfer everything not frozen, including the unfrozen X in the frozen pile
        assertEq(t.balanceOf(A), 10);
        (bytes32 py2, uint256 iy2) = _pos(A, 70);
        assertEq(py2, FROZEN);
        if (iy2 != iy) {
            _expectRevertAs(abi.encodeCall(ITestToken.destroySliceAt, (A, 70, 10, py, iy)), _stale(A, py, iy));
        }
        if (_stack()) assertTrue(iy2 != iy, "stack: the last range is swapped into the removed slot");
        _destroyAt(A, 70, 10, py2, iy2);
        assertEq(t.balanceOf(A), 0);
    }

    function test_positionOfUnheldSerial() public {
        if (_skipUnlessHints()) return;
        _mint(A, 10);
        (bool held, bytes32 p, uint256 i, uint256 s, uint256 a) = t.serialPositionOf(B, 5);
        assertFalse(held);
        assertEq(p, DEFAULT);
        assertEq(i + s + a, 0);
        (held,,,,) = t.serialPositionOf(A, 10); // not issued
        assertFalse(held);
    }

    // ───────────────────────── The tidying function ─────────────────────────

    function _skipUnlessTidy() internal returns (bool skip) {
        return _skipUnless(hasTidy);
    }

    /// @dev Builds an account with misplaced slices: five frozen slices stay in the default pile; with
    ///      classification, two slices of class W are added.
    function _messyAccount() internal returns (uint256 misplaced) {
        for (uint256 i; i < 6; ++i) {
            _mint(A, 10);
            _mint(B, 1);
        }
        if (hasFreeze) {
            for (uint256 i; i < 5; ++i) {
                _freeze(i * 11 + 2, 5);
            }
            misplaced += 5;
        }
        if (hasClass) {
            vm.startPrank(admin);
            t.setClass(55, 3, W); // part of slice 5, [55,65)
            t.setClass(62, 2, W);
            vm.stopPrank();
            misplaced += 2;
        }
    }

    function test_tidy_noEventsAndNoObservableChange() public {
        if (_skipUnlessTidy()) return;
        uint256 misplaced = _messyAccount();
        uint256 size = t.serialsIssued();
        address[4] memory dests = [B, C, address(0), A];
        uint256[4] memory tr;
        for (uint256 i; i < 4; ++i) {
            tr[i] = t.transferableBalanceOf(A, dests[i]);
        }
        bool[] memory held = _holdMask(A, size);
        uint256 frozen = hasFreeze ? t.frozenBalanceOf(A) : 0;

        vm.recordLogs();
        assertEq(_tidy(A, DEFAULT, 1000), misplaced);
        assertEq(vm.getRecordedLogs().length, 0, "tidy must not emit events");

        assertEq(t.balanceOf(A), 60);
        for (uint256 i; i < 4; ++i) {
            assertEq(t.transferableBalanceOf(A, dests[i]), tr[i], "transferableBalanceOf changed");
        }
        bool[] memory after_ = _holdMask(A, size);
        for (uint256 s; s < size; ++s) {
            assertEq(after_[s], held[s], "held serials changed");
        }
        if (hasFreeze) assertEq(t.frozenBalanceOf(A), frozen);
        assertEq(_tidy(A, DEFAULT, 1000), 0, "nothing left to tidy");
        assertEq(_tidy(A, FROZEN, 1000), 0, "the frozen pile holds only frozen ranges");
        assertEq(_tidy(A, W, 1000), 0, "the class pile holds only its class");
        assertEq(_tidy(A, bytes32("no such pile"), 1000), 0);
    }

    function test_tidy_respectsMaxMoves() public {
        if (_skipUnlessTidy()) return;
        uint256 misplaced = _messyAccount();
        if (misplaced == 0) return;
        assertEq(_tidy(A, DEFAULT, 0), 0);
        uint256 total;
        uint256 calls;
        while (true) {
            uint256 m = _tidy(A, DEFAULT, 2);
            assertLe(m, 2);
            total += m;
            ++calls;
            if (m < 2) break; // fewer than the limit means that tidying is complete
        }
        assertEq(total, misplaced);
        assertEq(calls, misplaced / 2 + 1);
        assertEq(_tidy(A, DEFAULT, 2), 0);
    }

    /// @dev The tidying function moves a slice that stays in the frozen pile after an unfreeze back to the default
    ///      pile.
    function test_tidy_movesUnfrozenBack() public {
        if (_skipUnless(hasTidy && hasFreeze && hasHints)) return;
        _mint(A, 100);
        _freeze(40, 20);
        assertEq(_tidy(A, DEFAULT, 10), 1);
        _assertPos(A, 40, FROZEN, 0, 40, 20);
        _unfreeze(40, 20);
        assertEq(_tidy(A, DEFAULT, 10), 0, "the default pile has nothing misplaced");
        assertEq(_tidy(A, FROZEN, 10), 1);
        (bytes32 p,) = _pos(A, 40);
        assertEq(p, DEFAULT);
        assertEq(_tidy(A, FROZEN, 10), 0);
    }

    /// @dev After tidying, a transfer by amount no longer needs to move slices between piles or skip them in place.
    function test_tidy_thenTransferTouchesOnlyUsableRanges() public {
        if (_skipUnless(hasTidy && hasFreeze)) return;
        for (uint256 i; i < 40; ++i) {
            _mint(A, 2);
            _mint(B, 1);
        }
        for (uint256 i; i < 40; ++i) {
            _freeze(i * 3 + 1, 1); // the higher serial of each slice
        }
        uint256 total;
        while (true) {
            uint256 m = _tidy(A, DEFAULT, 16);
            total += m;
            if (m < 16) break;
        }
        assertEq(total, 40);
        assertEq(t.transferableBalanceOf(A, B), 40);
        _send(A, B, 40);
        assertEq(t.balanceOf(A), 40);
        assertEq(t.frozenBalanceOf(A), 40);
        assertEq(_tidy(A, DEFAULT, 100), 0);
    }
}

// ───────────────────────── Tokens under test ─────────────────────────

contract ForcedAtAndTidy_FreezeStack is ForcedAtAndTidyBase, TargetFreezeStack {
    function _stack() internal pure override returns (bool) {
        return true;
    }
}

contract ForcedAtAndTidy_FreezeSorted is ForcedAtAndTidyBase, TargetFreezeSorted {
    function _stack() internal pure override returns (bool) {
        return false;
    }
}

contract ForcedAtAndTidy_ClassStack is ForcedAtAndTidyBase, TargetClassStack {
    function _stack() internal pure override returns (bool) {
        return true;
    }
}

contract ForcedAtAndTidy_ClassSorted is ForcedAtAndTidyBase, TargetClassSorted {
    function _stack() internal pure override returns (bool) {
        return false;
    }
}

contract ForcedAtAndTidy_BothStack is ForcedAtAndTidyBase, TargetBothStack {
    function _stack() internal pure override returns (bool) {
        return true;
    }
}

contract ForcedAtAndTidy_BothSorted is ForcedAtAndTidyBase, TargetBothSorted {
    function _stack() internal pure override returns (bool) {
        return false;
    }
}

contract ForcedAtAndTidy_BothStackTight is ForcedAtAndTidyBase, TargetBothStackTight {
    function _stack() internal pure override returns (bool) {
        return true;
    }
}

contract ForcedAtAndTidy_BothSortedTight is ForcedAtAndTidyBase, TargetBothSortedTight {
    function _stack() internal pure override returns (bool) {
        return false;
    }
}

contract ForcedAtAndTidy_BothConsolStack is ForcedAtAndTidyBase, TargetBothConsolStack {
    function _stack() internal pure override returns (bool) {
        return true;
    }
}

contract ForcedAtAndTidy_BothConsolSorted is ForcedAtAndTidyBase, TargetBothConsolSorted {
    function _stack() internal pure override returns (bool) {
        return false;
    }
}

// The second rule, "best fit in a bounded window".

contract ForcedAtAndTidy_BothStackWindow is ForcedAtAndTidyBase, TargetBothStackWindow {
    function _stack() internal pure override returns (bool) {
        return true;
    }
}

contract ForcedAtAndTidy_BothStackWindowTight is ForcedAtAndTidyBase, TargetBothStackWindowTight {
    function _stack() internal pure override returns (bool) {
        return true;
    }
}

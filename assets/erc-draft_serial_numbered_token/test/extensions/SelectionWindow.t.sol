// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {
    Rule,
    PresetBothStack,
    PresetCoreStackWindow,
    PresetBothStackWindow,
    PresetBothStackWindowTight
} from "../presets/Presets.sol";
import {ITestToken} from "../presets/Targets.sol";

/// @dev The second rule of selection by amount, "best fit in a bounded window" (deployment parameter
///      selectionWindow = W >= 1 of the slice stack).
///      Each test uses _build to mint a series of non-adjacent slices to the holder H, with the arrays listed from
///      the bottom of the stack to the top; _pay makes H transfer by amount to R and returns the SliceTransferred
///      events in the order emitted; _assertStack compares H's holdings in sliceAt order (the index order of the
///      default pile, then the other piles).
contract SelectionWindowTest is Test {
    bytes32 internal constant SERIAL_SIG = keccak256("SliceTransferred(address,address,uint256,uint256)");
    bytes32 internal constant REASON = "r";
    /// @dev A class without transfer restrictions, usable for any payee.
    bytes32 internal constant FREE = "free";
    /// @dev A class locked until a time; not transferable during the test.
    bytes32 internal constant LOCKED = "locked";

    address internal H = makeAddr("holder");
    address internal R = makeAddr("recipient");
    address internal F = makeAddr("filler");

    // ───────────────────────── Helpers ─────────────────────────

    function _core(uint256 w) internal returns (ITestToken) {
        return ITestToken(address(new PresetCoreStackWindow("Serial", "SRL", 6, address(this), w)));
    }

    function _both(uint256 w) internal returns (ITestToken t) {
        t = ITestToken(address(new PresetBothStackWindow("Serial", "SRL", 6, address(this), w)));
        _setup(t);
    }

    function _setup(ITestToken t) internal {
        t.setReasonInfo(REASON, "a reason", "");
        t.defineClass(FREE, Rule.None, 0, "label", "");
        t.defineClass(LOCKED, Rule.LockUntil, uint64(block.timestamp + 1000), "locked", "");
    }

    /// @dev Mints to H, in turn, slices of these lengths (bottom of the stack to top), and 1 unit to F after each
    ///      slice, so the slices are not adjacent to one another. Returns the starts of the slices.
    function _build(ITestToken t, uint256[] memory sizes, bytes32 classId) internal returns (uint256[] memory st) {
        st = new uint256[](sizes.length);
        for (uint256 i; i < sizes.length; ++i) {
            st[i] = t.serialsIssued();
            if (classId == bytes32(0)) t.mint(H, sizes[i]);
            else t.mintWithClass(H, sizes[i], classId);
            t.mint(F, 1);
        }
    }

    /// @dev H transfers by amount to R; returns the starts and amounts of the SliceTransferred events in the order
    ///      emitted.
    function _pay(ITestToken t, uint256 v) internal returns (uint256[] memory s, uint256[] memory a) {
        vm.recordLogs();
        vm.prank(H);
        t.transfer(R, v);
        return _pieces(t, vm.getRecordedLogs());
    }

    function _pieces(ITestToken t, Vm.Log[] memory logs)
        internal
        pure
        returns (uint256[] memory s, uint256[] memory a)
    {
        uint256 m;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(t) && logs[i].topics[0] == SERIAL_SIG) ++m;
        }
        s = new uint256[](m);
        a = new uint256[](m);
        m = 0;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(t) && logs[i].topics[0] == SERIAL_SIG) {
                (s[m], a[m]) = abi.decode(logs[i].data, (uint256, uint256));
                ++m;
            }
        }
    }

    function _assertPieces(uint256[] memory s, uint256[] memory a, uint256[] memory es, uint256[] memory ea)
        internal
        pure
    {
        assertEq(s.length, es.length, "number of SliceTransferred");
        for (uint256 i; i < s.length; ++i) {
            assertEq(s[i], es[i], "SliceTransferred.start");
            assertEq(a[i], ea[i], "SliceTransferred.amount");
        }
    }

    function _assertStack(ITestToken t, uint256[] memory es, uint256[] memory ea) internal view {
        assertEq(t.sliceCount(H), es.length, "sliceCount");
        for (uint256 i; i < es.length; ++i) {
            (uint256 s, uint256 a) = t.sliceAt(H, i);
            assertEq(s, es[i], "sliceAt.start");
            assertEq(a, ea[i], "sliceAt.amount");
        }
    }

    function _u(uint256 a) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = a;
    }

    function _u(uint256 a, uint256 b) internal pure returns (uint256[] memory r) {
        r = new uint256[](2);
        (r[0], r[1]) = (a, b);
    }

    function _u(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory r) {
        r = new uint256[](3);
        (r[0], r[1], r[2]) = (a, b, c);
    }

    function _u(uint256 a, uint256 b, uint256 c, uint256 d) internal pure returns (uint256[] memory r) {
        r = new uint256[](4);
        (r[0], r[1], r[2], r[3]) = (a, b, c, d);
    }

    function _u(uint256 a, uint256 b, uint256 c, uint256 d, uint256 e) internal pure returns (uint256[] memory r) {
        r = new uint256[](5);
        (r[0], r[1], r[2], r[3], r[4]) = (a, b, c, d, e);
    }

    // ───────────────────────── The default rule, for comparison ─────────────────────────

    /// @dev selectionWindow = 0 is the default rule: take from the top of the stack, and from the next slice when one
    ///      slice is not enough.
    function test_ruleZeroTakesFromTop() public {
        ITestToken t = _core(0);
        uint256[] memory st = _build(t, _u(50, 12, 20, 7), 0);
        (uint256[] memory s, uint256[] memory a) = _pay(t, 10);
        _assertPieces(s, a, _u(st[3], st[2] + 17), _u(7, 3));
        _assertStack(t, _u(st[0], st[1], st[2]), _u(50, 12, 17));
    }

    // ───────────────────────── The second rule ─────────────────────────

    /// @dev When the window has slices that are long enough, the shortest of them is picked and taken from its high
    ///      end; when only part of it is taken, the remaining low part stays in place and takes part in later picks
    ///      as usual. When a slice in the middle of the window is taken whole, the slice at the top of the stack
    ///      moves into its position.
    function test_smallestSufficientRange() public {
        ITestToken t = _core(4);
        uint256[] memory st = _build(t, _u(50, 12, 20, 7), 0);
        // 50, 12 and 20 are long enough for 10; pick 12
        (uint256[] memory s, uint256[] memory a) = _pay(t, 10);
        _assertPieces(s, a, _u(st[1] + 2), _u(10));
        _assertStack(t, _u(st[0], st[1], st[2], st[3]), _u(50, 2, 20, 7));
        // the 7, exactly long enough, is at the top of the stack
        (s, a) = _pay(t, 7);
        _assertPieces(s, a, _u(st[3]), _u(7));
        _assertStack(t, _u(st[0], st[1], st[2]), _u(50, 2, 20));
        // the slice exactly long enough is the 2 left over last time; it is taken whole, and the 20 at the top of
        // the stack moves into its position
        (s, a) = _pay(t, 2);
        _assertPieces(s, a, _u(st[1]), _u(2));
        _assertStack(t, _u(st[0], st[2]), _u(50, 20));
        // 50 and 20 are long enough for 15; pick 20
        (s, a) = _pay(t, 15);
        _assertPieces(s, a, _u(st[2] + 5), _u(15));
        _assertStack(t, _u(st[0], st[2]), _u(50, 5));
    }

    /// @dev When no slice in the window is long enough, the longest slice is paid out whole first, and the pick is
    ///      repeated with the remaining amount.
    function test_largestFirstWhenNoneSuffices() public {
        ITestToken t = _core(4);
        uint256[] memory st = _build(t, _u(5, 9, 3, 4), 0);
        // 15: none is long enough, pay 9 (the 4 at the top of the stack moves into its position); 6: pay 5 (the 3 at
        // the top moves in); 1: both 3 and 4 are long enough, pick 3
        (uint256[] memory s, uint256[] memory a) = _pay(t, 15);
        _assertPieces(s, a, _u(st[1], st[0], st[2] + 2), _u(9, 5, 1));
        _assertStack(t, _u(st[2], st[3]), _u(2, 4));
    }

    /// @dev Only the top W slices are considered: a slice below the window that is exactly long enough is not seen.
    ///      When W is not less than the number of slices, this is the best fit in the whole pile.
    function test_windowHidesBetterFitBelow() public {
        uint256[] memory sizes = _u(3, 50, 40, 60, 70);
        ITestToken t = _core(4);
        uint256[] memory st = _build(t, sizes, 0);
        (uint256[] memory s, uint256[] memory a) = _pay(t, 3);
        _assertPieces(s, a, _u(st[2] + 37), _u(3));

        t = _core(5);
        st = _build(t, sizes, 0);
        (s, a) = _pay(t, 3);
        _assertPieces(s, a, _u(st[0]), _u(3));
        // the slice at the bottom of the stack is taken whole, and the 70 at the top moves to index 0
        _assertStack(t, _u(st[4], st[1], st[2], st[3]), _u(70, 50, 40, 60));

        t = _core(type(uint256).max);
        st = _build(t, sizes, 0);
        (s, a) = _pay(t, 3);
        _assertPieces(s, a, _u(st[0]), _u(3));
    }

    /// @dev After the longest slice in the window is paid out, the slice below the window enters the window, and the
    ///      next pick is made in the new window.
    function test_newRangeEntersWindow() public {
        ITestToken t = _core(4);
        uint256[] memory st = _build(t, _u(100, 1, 9, 3, 4), 0);
        // no slice of the window [1, 9, 3, 4] is long enough for 60: pay 9, and the 4 at the top moves into its
        // position; 100 enters the window and is long enough for 51
        (uint256[] memory s, uint256[] memory a) = _pay(t, 60);
        _assertPieces(s, a, _u(st[2], st[0] + 49), _u(9, 51));
        _assertStack(t, _u(st[0], st[1], st[4], st[3]), _u(49, 1, 4, 3));
    }

    /// @dev Among slices of equal length, the one nearer the top of the stack is picked.
    function test_tiesPreferNearerTop() public {
        ITestToken t = _core(4);
        uint256[] memory st = _build(t, _u(8, 8, 2, 8), 0);
        (uint256[] memory s, uint256[] memory a) = _pay(t, 5);
        _assertPieces(s, a, _u(st[3] + 3), _u(5));
        // 20: none is long enough, and there are two longest slices of 8: first pay index 1, nearer the top (the 3
        // at the top moves in), then index 0 (the 2 moves in); 4: pay 3; 1: take 1 from the 2
        (s, a) = _pay(t, 20);
        _assertPieces(s, a, _u(st[1], st[0], st[3], st[2] + 1), _u(8, 8, 3, 1));
        _assertStack(t, _u(st[2]), _u(1));
    }

    /// @dev Burning by amount also selects by the second rule.
    function test_burnFollowsRule() public {
        ITestToken t = _core(4);
        uint256[] memory st = _build(t, _u(50, 12, 20, 7), 0);
        vm.recordLogs();
        vm.prank(H);
        t.burn(10);
        (uint256[] memory s, uint256[] memory a) = _pieces(t, vm.getRecordedLogs());
        _assertPieces(s, a, _u(st[1] + 2), _u(10));
    }

    /// @dev Transfers by serial are not affected by the selection rule.
    function test_transferSlicesUnaffected() public {
        ITestToken t = _core(4);
        uint256[] memory st = _build(t, _u(50, 12, 20, 7), 0);
        vm.recordLogs();
        vm.prank(H);
        t.transferSlices(R, _u(st[0]), _u(10));
        (uint256[] memory s, uint256[] memory a) = _pieces(t, vm.getRecordedLogs());
        _assertPieces(s, a, _u(st[0]), _u(10));
    }

    // ───────────────────────── Combined with freezing and classification ─────────────────────────

    /// @dev The high end of the picked slice is frozen: the frozen part is moved into the frozen pile, and the pick is
    ///      repeated with the same amount.
    ///      The rule compares the recorded length: 6 fits better than 10, but only 3 of its units are transferable.
    function test_frozenHighEndMovedThenRepick() public {
        ITestToken t = _both(4);
        uint256[] memory st = _build(t, _u(10, 6), 0);
        t.freezeSlice(st[1] + 3, 3, REASON);
        (uint256[] memory s, uint256[] memory a) = _pay(t, 5);
        _assertPieces(s, a, _u(st[0] + 5), _u(5));
        // default pile [5, 3], frozen pile [3]
        _assertStack(t, _u(st[0], st[1], st[1] + 3), _u(5, 3, 3));
        assertEq(t.balanceOf(R), 5);
    }

    /// @dev Once the budget for moving between piles is used up, the rest of this pile is checked in place from the
    ///      highest index down (as under the default rule).
    function test_budgetExhaustedFallsBackInPlace() public {
        ITestToken t = ITestToken(address(new PresetBothStackWindowTight("Serial", "SRL", 6, address(this), 4)));
        _setup(t);
        uint256[] memory st = _build(t, _u(10, 6, 7), 0);
        t.freezeSlice(st[1] + 3, 3, REASON);
        t.freezeSlice(st[2] + 4, 3, REASON);
        // Pick 6: high end frozen, moved away (budget used up); then pick 7: high end frozen, budget already used
        // up, so in place from index 2 down: the 4 transferable units of the 7, then 1 of the 3 left at index 1
        (uint256[] memory s, uint256[] memory a) = _pay(t, 5);
        _assertPieces(s, a, _u(st[2], st[1] + 2), _u(4, 1));
        _assertStack(t, _u(st[0], st[1], st[2] + 4, st[1] + 3), _u(10, 2, 3, 3));
    }

    /// @dev Every usable pile applies the second rule on its own, and the order of the piles is unchanged: the
    ///      non-default piles first, then the default pile. Piles that are not usable do not take part.
    function test_eachUsablePileAppliesRule() public {
        ITestToken t = _both(4);
        uint256[] memory fs = _build(t, _u(4, 9, 6), FREE);
        uint256[] memory ls = _build(t, _u(10), LOCKED);
        uint256[] memory ds = _build(t, _u(20, 3), 0);
        // in the class pile only 9 and 6 are long enough for 5; pick 6
        (uint256[] memory s, uint256[] memory a) = _pay(t, 5);
        _assertPieces(s, a, _u(fs[2] + 1), _u(5));
        // 30: no slice of the class pile [4, 9, 1] is long enough, so pay 9, 4 and 1 in turn; in the default pile
        // [20, 3], 20 is long enough for 16
        (s, a) = _pay(t, 30);
        _assertPieces(s, a, _u(fs[1], fs[0], fs[2], ds[0] + 4), _u(9, 4, 1, 16));
        assertEq(t.balanceOf(R), 35);
        // the 10 locked units stay as they are
        assertEq(t.transferableBalanceOf(H, R), 7);
        (uint256 ls0, uint256 la0) = t.sliceAt(H, 2);
        assertEq(ls0, ls[0]);
        assertEq(la0, 10);
    }

    // ───────────────────────── Cross-checks ─────────────────────────

    /// @dev Generates one step from a seed: mint, mint with a class, freeze, burn by amount, transfer by amount.
    ///      When skip is true the step is not performed.
    function _randomOp(uint256 seed, uint256 issued)
        internal
        view
        returns (address caller, bytes memory data, bool skip)
    {
        address[3] memory who = [H, R, F];
        caller = who[seed % 3];
        address to = who[(seed >> 8) % 3];
        uint256 v = (seed >> 16) % 25 + 1;
        uint256 op = (seed >> 32) % 6;
        if (op == 0) {
            return (address(this), abi.encodeCall(ITestToken.mint, (to, v)), false);
        }
        if (op == 1) {
            bytes32 c = (seed >> 40) % 2 == 0 ? FREE : LOCKED;
            return (address(this), abi.encodeCall(ITestToken.mintWithClass, (to, v, c)), false);
        }
        if (op == 2) {
            if (issued == 0) return (caller, data, true);
            uint256 start = (seed >> 48) % issued;
            uint256 n = (seed >> 64) % 8 + 1;
            if (n > issued - start) n = issued - start;
            return (address(this), abi.encodeCall(ITestToken.freezeSlice, (start, n, REASON)), false);
        }
        if (op == 3) return (caller, abi.encodeCall(ITestToken.burn, (v)), false);
        return (caller, abi.encodeCall(ITestToken.transfer, (to, v)), false);
    }

    /// @dev Makes the same call on two tokens and compares success, return data and the events emitted.
    function _sameCall(ITestToken t0, ITestToken t1, address caller, bytes memory data) internal {
        vm.recordLogs();
        vm.prank(caller);
        (bool ok0, bytes memory r0) = address(t0).call(data);
        Vm.Log[] memory l0 = vm.getRecordedLogs();
        vm.recordLogs();
        vm.prank(caller);
        (bool ok1, bytes memory r1) = address(t1).call(data);
        Vm.Log[] memory l1 = vm.getRecordedLogs();
        assertEq(ok0, ok1, "success differs");
        assertEq(r0, r1, "return data differs");
        assertEq(l0.length, l1.length, "number of events differs");
        for (uint256 k; k < l0.length; ++k) {
            assertEq(l0[k].topics, l1[k].topics, "event topics differ");
            assertEq(l0[k].data, l1[k].data, "event data differs");
        }
    }

    function _sameHoldings(ITestToken t0, ITestToken t1, address a) internal view {
        uint256 n = t0.sliceCount(a);
        assertEq(t1.sliceCount(a), n, "sliceCount differs");
        for (uint256 i; i < n; ++i) {
            (uint256 s0, uint256 a0) = t0.sliceAt(a, i);
            (uint256 s1, uint256 a1) = t1.sliceAt(a, i);
            assertEq(s0, s1, "sliceAt.start differs");
            assertEq(a0, a1, "sliceAt.amount differs");
        }
    }

    /// @dev With W = 1 the window is only the top of the stack, and the result is the same as under the default rule:
    ///      for the same sequence of operations, both tokens emit exactly the same events and end with exactly the
    ///      same holdings.
    function testFuzz_windowOneMatchesRuleZero(uint256 seed) public {
        ITestToken t0 = ITestToken(address(new PresetBothStack("Serial", "SRL", 6, address(this))));
        _setup(t0);
        ITestToken t1 = _both(1);
        for (uint256 i; i < 60; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            (address caller, bytes memory data, bool skip) = _randomOp(seed, t0.serialsIssued());
            if (!skip) _sameCall(t0, t1, caller, data);
        }
        _sameHoldings(t0, t1, H);
        _sameHoldings(t0, t1, R);
        _sameHoldings(t0, t1, F);
    }

    /// @dev Model of H's slice stack: the starts and lengths at the indexes [0, n).
    struct Model {
        uint256[] s;
        uint256[] l;
        uint256 n;
    }

    /// @dev Picks a slice by the definition: the window is the indexes [n - w, n); the shortest of the slices that are
    ///      long enough, otherwise the longest; among slices of equal length, the one with the larger index.
    function _modelPick(Model memory md, uint256 w, uint256 r) internal pure returns (uint256) {
        uint256 end = md.n > w ? md.n - w : 0;
        uint256 fit = type(uint256).max;
        uint256 big = type(uint256).max;
        for (uint256 k = md.n; k > end; --k) {
            uint256 len = md.l[k - 1];
            if (len >= r) {
                if (fit == type(uint256).max || len < md.l[fit]) fit = k - 1;
            } else if (big == type(uint256).max || len > md.l[big]) {
                big = k - 1;
            }
        }
        return fit != type(uint256).max ? fit : big;
    }

    /// @dev Pays r units by the model, compares them with the slices actually emitted, and updates the model: when
    ///      only part of a slice is taken, the remaining low part stays in place; when a slice is taken whole, the
    ///      slice at the top of the stack moves into its position.
    function _modelPay(Model memory md, uint256 w, uint256 r, uint256[] memory s, uint256[] memory a) internal pure {
        uint256 m;
        while (r != 0) {
            uint256 j = _modelPick(md, w, r);
            uint256 take = md.l[j] < r ? md.l[j] : r;
            assertLt(m, s.length, "fewer pieces than the model");
            assertEq(s[m], md.s[j] + md.l[j] - take, "piece start differs from the model");
            assertEq(a[m], take, "piece amount differs from the model");
            ++m;
            r -= take;
            md.l[j] -= take;
            if (md.l[j] == 0) {
                (md.s[j], md.l[j]) = (md.s[md.n - 1], md.l[md.n - 1]);
                --md.n;
            }
        }
        assertEq(s.length, m, "more pieces than the model");
    }

    /// @dev Compares with a reference model written from the definition (a token without restrictions, where H's
    ///      slice stack changes only by minting and by H's outgoing transfers): the slices of every outgoing transfer,
    ///      and the slice stack after it, are the same as in the model.
    function testFuzz_matchesReferenceModel(uint256 seed, uint8 wSeed) public {
        uint256 w = uint256(wSeed) % 6 + 1;
        ITestToken t = _core(w);
        Model memory md = Model(new uint256[](64), new uint256[](64), 0);
        uint256 bal;
        for (uint256 i; i < 80; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            if (md.n < 40 && (md.n == 0 || seed % 3 == 0)) {
                uint256 v = (seed >> 8) % 30 + 1;
                (md.s[md.n], md.l[md.n]) = (t.serialsIssued(), v);
                ++md.n;
                bal += v;
                t.mint(H, v);
                t.mint(F, 1);
                continue;
            }
            uint256 r = (seed >> 16) % (bal < 60 ? bal : 60) + 1;
            (uint256[] memory s, uint256[] memory a) = _pay(t, r);
            bal -= r;
            _modelPay(md, w, r, s, a);
            assertEq(t.sliceCount(H), md.n, "sliceCount differs from the model");
            for (uint256 k; k < md.n; ++k) {
                (uint256 ss, uint256 aa) = t.sliceAt(H, k);
                assertEq(ss, md.s[k], "sliceAt.start differs from the model");
                assertEq(aa, md.l[k], "sliceAt.amount differs from the model");
            }
        }
    }
}

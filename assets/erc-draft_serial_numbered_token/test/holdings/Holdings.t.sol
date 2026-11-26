// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SerialHoldings} from "../../contracts/holdings/SerialHoldings.sol";
import {SerialHoldingsStack} from "../../contracts/holdings/SerialHoldingsStack.sol";
import {SerialHoldingsSorted} from "../../contracts/holdings/SerialHoldingsSorted.sol";

/// @dev Wraps the internal functions of a backend as external functions. Uses only one pile of one account; the
///      number of slices is stored here (in the core, the account record keeps it).
abstract contract HoldingsHarness is SerialHoldings {
    bytes32 internal constant PILE = bytes32(0);
    uint256 public n;

    function rangeAt(uint256 i) external view returns (uint256, uint256) {
        return _rangeAt(address(this), PILE, i);
    }

    function addRange(uint256 start, uint256 len) external {
        n = _addRange(address(this), PILE, n, start, len);
    }

    function addRanges(uint256[] memory starts, uint256[] memory lens) external {
        n = _addRanges(address(this), PILE, n, starts, lens, starts.length);
    }

    function setTopLen(uint256 newLen) external {
        n = _setTopLen(address(this), PILE, n, newLen);
    }

    function removeAt(uint256 i, uint256 lo, uint256 hi) external {
        n = _removeAt(address(this), PILE, n, i, lo, hi);
    }

    function removeSerials(uint256 lo, uint256 hi) external returns (uint256 removed) {
        (n, removed) = _removeSerials(address(this), PILE, n, lo, hi);
    }

    function removeSerialsBatch(uint256[] memory los, uint256[] memory his, uint256 want)
        external
        returns (uint256 total, uint256[] memory got)
    {
        got = new uint256[](los.length);
        (n, total) = _removeSerialsBatch(address(this), PILE, n, los, his, got, want);
    }
}

contract StackHarness is HoldingsHarness, SerialHoldingsStack {
    constructor() SerialHoldingsStack(0) {}
}

contract SortedHarness is HoldingsHarness, SerialHoldingsSorted {}

/// @notice Fuzz test of a backend against a model: random adds, batch adds, removals by index, removals by serial,
///         batch removals by serial (used by consolidation) and shortening of the last slice; after each step it
///         checks that the set of slices matches the model, that the slices are pairwise disjoint, and that the
///         slots beyond the number of slices are cleared; for the sorted array it also requires starts in ascending
///         order and adjacent slices merged.
/// @dev Serials are limited to [0, 256), so the model is a 256-bit bitmap.
abstract contract HoldingsFuzzBase is Test {
    uint256 internal constant SPACE = 256;

    HoldingsHarness internal h;
    uint256 internal model;
    uint256 internal maxN;

    function _deploy() internal virtual returns (HoldingsHarness);

    function _sorted() internal pure virtual returns (bool);

    function testFuzz_matchesModel(uint256 seed) public {
        h = _deploy();
        for (uint256 step; step < 80; ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            uint256 op = seed % 9;
            uint256 r = seed >> 8;
            if (op <= 1) _opAdd(r);
            else if (op <= 3) _opAddBatch(r);
            else if (op == 4) _opRemoveAt(r);
            else if (op <= 6) _opRemoveSerials(r);
            else if (op == 7) _opSetTopLen(r);
            else _opRemoveSerialsBatch(r);
            _check();
        }
    }

    function test_emptyBatchIsNoop() public {
        h = _deploy();
        h.addRange(10, 5);
        h.addRanges(new uint256[](0), new uint256[](0));
        assertEq(h.n(), 1);
    }

    // ───────────────────────── Operations ─────────────────────────

    function _opAdd(uint256 r) private {
        (uint256 s, uint256 l) = _freeRun(model, r, 1 + (r >> 16) % 12);
        if (l == 0) return;
        h.addRange(s, l);
        model |= _mask(s, s + l);
    }

    /// @dev A batch of 1 to 5 slices, pairwise disjoint (they may be adjacent) and disjoint from the existing ones;
    ///      in ascending or descending order at random.
    function _opAddBatch(uint256 r) private {
        uint256 k = 1 + r % 5;
        uint256[] memory starts = new uint256[](k);
        uint256[] memory lens = new uint256[](k);
        uint256 taken = model;
        uint256 m;
        for (uint256 i; i < k; ++i) {
            r = uint256(keccak256(abi.encode(r, i)));
            (uint256 s, uint256 l) = _freeRun(taken, r, 1 + (r >> 16) % 8);
            if (l == 0) continue;
            taken |= _mask(s, s + l);
            (starts[m], lens[m]) = (s, l);
            ++m;
        }
        if (m == 0) return;
        assembly ("memory-safe") {
            mstore(starts, m)
            mstore(lens, m)
        }
        _sortAsc(starts, lens);
        if (r & (1 << 200) != 0) _reverse(starts, lens);
        h.addRanges(starts, lens);
        model = taken;
    }

    /// @dev Removes a random part of a random slice, and checks that the slices with an index less than i are
    ///      unchanged.
    function _opRemoveAt(uint256 r) private {
        uint256 n = h.n();
        if (n == 0) return;
        uint256 i = r % n;
        (uint256 s, uint256 l) = h.rangeAt(i);
        uint256 lo = s + (r >> 16) % l;
        uint256 hi = lo + 1 + (r >> 32) % (s + l - lo);
        uint256[] memory before = new uint256[](i);
        for (uint256 j; j < i; ++j) {
            (uint256 bs, uint256 bl) = h.rangeAt(j);
            before[j] = (bs << 128) | bl;
        }
        h.removeAt(i, lo, hi);
        for (uint256 j; j < i; ++j) {
            (uint256 bs, uint256 bl) = h.rangeAt(j);
            assertEq((bs << 128) | bl, before[j], "removeAt moved an index below i");
        }
        model &= ~_mask(lo, hi);
    }

    function _opRemoveSerials(uint256 r) private {
        uint256 lo = r % SPACE;
        uint256 hi = lo + 1 + (r >> 16) % (r & (1 << 100) != 0 ? 24 : SPACE - lo);
        if (hi > SPACE) hi = SPACE;
        uint256 expected = _popcount(model & _mask(lo, hi));
        uint256 removed = h.removeSerials(lo, hi);
        assertEq(removed, expected, "removeSerials count");
        model &= ~_mask(lo, hi);
    }

    /// @dev 1 to 6 slices in ascending order, pairwise disjoint (they may be adjacent); want is their total length
    ///      (as the core uses it), so what has to be removed is every serial of the model that lies in these slices,
    ///      counted per slice.
    function _opRemoveSerialsBatch(uint256 r) private {
        uint256 k = 1 + r % 6;
        uint256[] memory los = new uint256[](k);
        uint256[] memory his = new uint256[](k);
        uint256 at = (r >> 8) % 64;
        uint256 want;
        uint256 m;
        for (uint256 i; i < k && at < SPACE; ++i) {
            r = uint256(keccak256(abi.encode(r, i)));
            uint256 len = 1 + r % (r & (1 << 100) != 0 ? 6 : 40);
            if (at + len > SPACE) len = SPACE - at;
            (los[m], his[m]) = (at, at + len);
            want += len;
            ++m;
            at += len + ((r >> 16) % 3 == 0 ? 0 : 1 + (r >> 24) % 30);
        }
        assembly ("memory-safe") {
            mstore(los, m)
            mstore(his, m)
        }
        uint256 expected;
        for (uint256 i; i < m; ++i) {
            expected += _popcount(model & _mask(los[i], his[i]));
        }
        (uint256 total, uint256[] memory got) = h.removeSerialsBatch(los, his, want);
        assertEq(total, expected, "removeSerialsBatch total");
        for (uint256 i; i < m; ++i) {
            assertEq(got[i], _popcount(model & _mask(los[i], his[i])), "removeSerialsBatch per range");
            model &= ~_mask(los[i], his[i]);
        }
    }

    function _opSetTopLen(uint256 r) private {
        uint256 n = h.n();
        if (n == 0) return;
        (uint256 s, uint256 l) = h.rangeAt(n - 1);
        uint256 newLen = r % l;
        h.setTopLen(newLen);
        model &= ~_mask(s + newLen, s + l);
    }

    // ───────────────────────── Checks ─────────────────────────

    function _check() private {
        uint256 n = h.n();
        if (n > maxN) maxN = n;
        uint256 acc;
        uint256 prevEnd;
        for (uint256 i; i < n; ++i) {
            (uint256 s, uint256 l) = h.rangeAt(i);
            assertGt(l, 0, "empty range");
            assertLe(s + l, SPACE, "range out of space");
            uint256 m = _mask(s, s + l);
            assertEq(acc & m, 0, "ranges overlap");
            acc |= m;
            if (_sorted() && i != 0) assertLt(prevEnd, s, "sorted: not ascending or adjacent not merged");
            prevEnd = s + l;
        }
        assertEq(acc, model, "holdings differ from model");
        for (uint256 i = n; i < maxN + 2; ++i) {
            (uint256 s, uint256 l) = h.rangeAt(i);
            assertEq(s | l, 0, "slot beyond n not cleared");
        }
    }

    // ───────────────────────── Helpers ─────────────────────────

    /// @dev A slice of free serials starting at a random position (of length at most maxLen); the length is 0 when
    ///      the random position is already taken.
    function _freeRun(uint256 taken, uint256 r, uint256 maxLen) private pure returns (uint256 s, uint256 l) {
        s = r % SPACE;
        while (s + l < SPACE && l < maxLen && taken & (1 << (s + l)) == 0) ++l;
    }

    function _mask(uint256 lo, uint256 hi) private pure returns (uint256) {
        unchecked {
            return ((uint256(1) << (hi - lo)) - 1) << lo;
        }
    }

    function _popcount(uint256 x) private pure returns (uint256 c) {
        while (x != 0) {
            x &= x - 1;
            ++c;
        }
    }

    function _sortAsc(uint256[] memory s, uint256[] memory l) private pure {
        for (uint256 i = 1; i < s.length; ++i) {
            for (uint256 j = i; j != 0 && s[j - 1] > s[j]; --j) {
                (s[j - 1], s[j]) = (s[j], s[j - 1]);
                (l[j - 1], l[j]) = (l[j], l[j - 1]);
            }
        }
    }

    function _reverse(uint256[] memory s, uint256[] memory l) private pure {
        for (uint256 i; i < s.length / 2; ++i) {
            uint256 j = s.length - 1 - i;
            (s[i], s[j]) = (s[j], s[i]);
            (l[i], l[j]) = (l[j], l[i]);
        }
    }
}

contract HoldingsFuzz_Stack is HoldingsFuzzBase {
    function _deploy() internal override returns (HoldingsHarness) {
        return new StackHarness();
    }

    function _sorted() internal pure override returns (bool) {
        return false;
    }
}

contract HoldingsFuzz_Sorted is HoldingsFuzzBase {
    function _deploy() internal override returns (HoldingsHarness) {
        return new SortedHarness();
    }

    function _sorted() internal pure override returns (bool) {
        return true;
    }

    function test_rejectsUnorderedBatch() public {
        h = _deploy();
        uint256[] memory s = new uint256[](3);
        uint256[] memory l = new uint256[](3);
        (s[0], s[1], s[2]) = (5, 3, 9);
        (l[0], l[1], l[2]) = (1, 1, 1);
        vm.expectRevert(SerialHoldingsSorted.SerialHoldingsUnorderedBatch.selector);
        h.addRanges(s, l);
    }
}

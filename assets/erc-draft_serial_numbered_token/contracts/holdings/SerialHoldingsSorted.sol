// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SerialHoldingsArray} from "./SerialHoldingsArray.sol";

/// @title SerialHoldingsSorted
/// @notice Sorted array: the slices of each pile are kept in ascending order of start; a transfer by amount takes
///         from the slice with the largest serials.
/// @dev Cost profile:
///      - Locating by serial uses binary search; the number of reads grows logarithmically with the number of
///        slices.
///      - A slice received is merged with its neighbors on both sides when it is adjacent to them, so the number of
///        slices never exceeds the number of slices that are truly not adjacent.
///      - Inserting in the middle, or deleting a slice in the middle, shifts all the slices after it; the number of
///        writes grows linearly with the number of slices.
///        So transferring out an older slice by serial is often more expensive than on the stack: the stack has to
///        read the whole pile, while this backend has to rewrite all the slices after it, and writes cost more than
///        reads.
///      - The slices that one transfer delivers to the same pile are merged and written in one pass (_addRanges);
///        the cost grows with "the number of these slices + the number of existing slices after the insertion
///        point", not with their product.
///      - Newly issued serials are always larger than existing ones, so minting and receiving newly minted units
///        both append at the end, at constant cost.
///      - Selection by amount supports only the default rule (take from the slice with the largest serials); there
///        is no deployment parameter selectionWindow as on the slice stack.
abstract contract SerialHoldingsSorted is SerialHoldingsArray {
    /// @notice A batch of slices added at once is not strictly monotonic (the core ensures that this does not happen).
    error SerialHoldingsUnorderedBatch();

    /// @dev Supports only the default rule.
    function _selectionWindow() internal view virtual override returns (uint256) {
        return 0;
    }

    /// @dev Finds the insertion position by binary search and merges with the adjacent slices on the left and right;
    ///      when inserting in the middle, shifts the following slices up by one position.
    function _addRange(address account, bytes32 pile, uint256 n, uint256 start, uint256 len)
        internal
        virtual
        override
        returns (uint256)
    {
        uint256 j = _firstStartAbove(account, pile, n, start);
        uint256 ls;
        uint256 ll;
        bool left;
        if (j != 0) {
            (ls, ll) = _rangeAt(account, pile, j - 1);
            left = ls + ll == start;
        }
        uint256 rl;
        bool right;
        if (j < n) {
            uint256 rs;
            (rs, rl) = _rangeAt(account, pile, j);
            right = rs == start + len;
        }
        if (left && right) {
            _writeRange(account, pile, j - 1, ls, ll + len + rl);
            _shiftLeft(account, pile, n, j);
            return n - 1;
        }
        if (left) {
            _writeRange(account, pile, j - 1, ls, ll + len);
            return n;
        }
        if (right) {
            _writeRange(account, pile, j, start, len + rl);
            return n;
        }
        _shiftRight(account, pile, n, j);
        _writeRange(account, pile, j, start, len);
        return n + 1;
    }

    /// @dev A list in memory of slices in ascending order; only the first n entries are used.
    struct Run {
        uint256[] s;
        uint256[] l;
        uint256 n;
    }

    /// @dev Reads into memory the slices of the pile starting from "the left neighbor of the lowest start in the
    ///      batch", merges them with the batch (joining adjacent slices) and writes them back. The slices before the
    ///      left neighbor all lie to the left of the batch and are not adjacent to it, so they stay untouched.
    function _addRanges(
        address account,
        bytes32 pile,
        uint256 n,
        uint256[] memory starts,
        uint256[] memory lens,
        uint256 m
    ) internal virtual override returns (uint256) {
        if (m == 0) return n;
        if (m == 1) return _addRange(account, pile, n, starts[0], lens[0]);
        bool desc = starts[0] > starts[1];
        for (uint256 i = 1; i < m; ++i) {
            if (desc ? starts[i] >= starts[i - 1] : starts[i] <= starts[i - 1]) revert SerialHoldingsUnorderedBatch();
        }
        uint256 base = _firstStartAbove(account, pile, n, desc ? starts[m - 1] : starts[0]);
        if (base != 0) --base;
        Run memory old = _load(account, pile, base, n);
        Run memory merged = _merge(old, starts, lens, m, desc);
        for (uint256 t; t < merged.n; ++t) {
            if (t < old.n && old.s[t] == merged.s[t] && old.l[t] == merged.l[t]) continue;
            _writeRange(account, pile, base + t, merged.s[t], merged.l[t]);
        }
        for (uint256 idx = base + merged.n; idx < n; ++idx) {
            _clearRange(account, pile, idx);
        }
        return base + merged.n;
    }

    function _load(address account, bytes32 pile, uint256 base, uint256 n) private view returns (Run memory r) {
        r.n = n - base;
        r.s = new uint256[](r.n);
        r.l = new uint256[](r.n);
        for (uint256 t; t < r.n; ++t) {
            (r.s[t], r.l[t]) = _rangeAt(account, pile, base + t);
        }
    }

    /// @dev Merges two lists of slices in ascending order (reading the batch backward when it is in descending
    ///      order); slices that are adjacent are joined into one.
    function _merge(Run memory e, uint256[] memory starts, uint256[] memory lens, uint256 m, bool desc)
        private
        pure
        returns (Run memory o)
    {
        o.s = new uint256[](e.n + m);
        o.l = new uint256[](e.n + m);
        uint256 a;
        uint256 b;
        while (a < e.n || b < m) {
            uint256 s;
            uint256 l;
            if (b < m) (s, l) = desc ? (starts[m - 1 - b], lens[m - 1 - b]) : (starts[b], lens[b]);
            if (b == m || (a < e.n && e.s[a] < s)) {
                (s, l) = (e.s[a], e.l[a]);
                ++a;
            } else {
                ++b;
            }
            if (o.n != 0 && o.s[o.n - 1] + o.l[o.n - 1] == s) {
                o.l[o.n - 1] += l;
            } else {
                (o.s[o.n], o.l[o.n]) = (s, l);
                ++o.n;
            }
        }
    }

    function _removeAt(address account, bytes32 pile, uint256 n, uint256 i, uint256 lo, uint256 hi)
        internal
        virtual
        override
        returns (uint256)
    {
        (uint256 s, uint256 len) = _rangeAt(account, pile, i);
        uint256 e = s + len;
        if (s < lo) {
            _writeRange(account, pile, i, s, lo - s);
            if (hi < e) {
                _shiftRight(account, pile, n, i + 1);
                _writeRange(account, pile, i + 1, hi, e - hi);
                return n + 1;
            }
            return n;
        }
        if (hi < e) {
            _writeRange(account, pile, i, hi, e - hi);
            return n;
        }
        _shiftLeft(account, pile, n, i);
        return n - 1;
    }

    /// @dev Finds by binary search the first slice that intersects [lo, hi), then works forward from it.
    function _removeSerials(address account, bytes32 pile, uint256 n, uint256 lo, uint256 hi)
        internal
        virtual
        override
        returns (uint256 newN, uint256 removed)
    {
        newN = n;
        uint256 j = _firstEndAbove(account, pile, n, lo);
        while (j < newN) {
            (uint256 s, uint256 len) = _rangeAt(account, pile, j);
            if (s >= hi) break;
            uint256 e = s + len;
            uint256 ps = s > lo ? s : lo;
            uint256 pe = e < hi ? e : hi;
            uint256 before = newN;
            newN = _removeAt(account, pile, newN, j, ps, pe);
            removed += pe - ps;
            // When the whole slice is deleted, the following slices shift down and the index stays the same;
            // otherwise, further intersecting slices can only come after this one.
            if (newN >= before) ++j;
        }
    }

    /// @dev Finds by binary search the first slice whose end is greater than los[0], reads the slices from it onward
    ///      into memory, subtracts each of the given slices, and writes the result back (only the slots that
    ///      changed).
    ///      The cost grows with "the number of slices after this one" and does not depend on the number of slices
    ///      removed; when the slices removed are those with the largest serials, only those are read.
    function _removeSerialsBatch(
        address account,
        bytes32 pile,
        uint256 n,
        uint256[] memory los,
        uint256[] memory his,
        uint256[] memory got,
        uint256 want
    ) internal virtual override returns (uint256 newN, uint256 total) {
        if (los.length == 0 || n == 0 || want == 0) return (n, 0);
        uint256 base = _firstEndAbove(account, pile, n, los[0]);
        Run memory old = _load(account, pile, base, n);
        Run memory out;
        (out, total) = _subtract(old, los, his, got);
        for (uint256 t; t < out.n; ++t) {
            if (t < old.n && old.s[t] == out.s[t] && old.l[t] == out.l[t]) continue;
            _writeRange(account, pile, base + t, out.s[t], out.l[t]);
        }
        for (uint256 idx = base + out.n; idx < n; ++idx) {
            _clearRange(account, pile, idx);
        }
        newN = base + out.n;
    }

    /// @dev Subtracts each slice [los[p], his[p]) from a list of slices in ascending order, and returns the
    ///      remaining slices and the number of serials subtracted.
    ///      Each slice is cut in two by at most one of the subtracted slices, so the result has at most
    ///      old.n + los.length slices.
    function _subtract(Run memory old, uint256[] memory los, uint256[] memory his, uint256[] memory got)
        private
        pure
        returns (Run memory out, uint256 total)
    {
        uint256 m = los.length;
        out.s = new uint256[](old.n + m);
        out.l = new uint256[](old.n + m);
        uint256 p;
        for (uint256 t; t < old.n; ++t) {
            uint256 x = old.s[t];
            uint256 e = x + old.l[t];
            while (p < m && his[p] <= x) ++p;
            while (p < m && los[p] < e) {
                uint256 lo = los[p] > x ? los[p] : x;
                uint256 hi = his[p] < e ? his[p] : e;
                if (lo > x) {
                    (out.s[out.n], out.l[out.n]) = (x, lo - x);
                    ++out.n;
                }
                got[p] += hi - lo;
                total += hi - lo;
                x = hi;
                // When the subtracted slice extends past the end of this one, the next slice continues with it.
                if (his[p] > e) break;
                ++p;
            }
            if (x < e) {
                (out.s[out.n], out.l[out.n]) = (x, e - x);
                ++out.n;
            }
        }
    }

    /// @dev The first index whose start is greater than x (n if there is none). A new slice usually has larger
    ///      serials than all existing ones, so the last slice is checked first.
    function _firstStartAbove(address account, bytes32 pile, uint256 n, uint256 x) private view returns (uint256) {
        if (n == 0) return 0;
        (uint256 ts,) = _rangeAt(account, pile, n - 1);
        if (ts <= x) return n;
        uint256 lo;
        uint256 hi = n - 1;
        while (lo < hi) {
            uint256 mid = (lo + hi) >> 1;
            (uint256 s,) = _rangeAt(account, pile, mid);
            if (s <= x) lo = mid + 1;
            else hi = mid;
        }
        return lo;
    }

    /// @dev The first index whose end is greater than x (n if there is none). The slices are pairwise disjoint and
    ///      sorted, so their ends are also in ascending order.
    function _firstEndAbove(address account, bytes32 pile, uint256 n, uint256 x) private view returns (uint256) {
        uint256 lo;
        uint256 hi = n;
        while (lo < hi) {
            uint256 mid = (lo + hi) >> 1;
            (uint256 s, uint256 len) = _rangeAt(account, pile, mid);
            if (s + len <= x) lo = mid + 1;
            else hi = mid;
        }
        return lo;
    }

    /// @dev Shifts the slices at indexes [j, n) up by one position, freeing index j.
    function _shiftRight(address account, bytes32 pile, uint256 n, uint256 j) private {
        for (uint256 k = n; k > j; --k) {
            _copyRange(account, pile, k - 1, k);
        }
    }

    /// @dev Deletes index j and shifts the slices at indexes (j, n) down by one position.
    function _shiftLeft(address account, bytes32 pile, uint256 n, uint256 j) private {
        for (uint256 k = j; k + 1 < n; ++k) {
            _copyRange(account, pile, k + 1, k);
        }
        _clearRange(account, pile, n - 1);
    }
}

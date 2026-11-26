// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

/// @title SerialConsolidations
/// @notice Storage of consolidation records: each record states that the units of a slice of old serials
///         [oldStart, oldStart + length) received the new serials starting at successor. The old serials of the
///         records are pairwise disjoint (a serial is consolidated at most once). Used by the consolidation module
///         ERCXXXXConsolidation.
/// @dev Storage (implementation detail):
///      - runs: old start -> (successor start << 128) | length, one slot per record. Serials do not exceed
///        2^128 - 1 (the same width as in the core).
///      - The set of old starts is stored as a 256-ary bitmap tree in which only the parts with branches are
///        expanded. A subtree at level L (2^(8(L+1)) serials) is one word when expanded (a bitmap: at level 0 a bit
///        is one old start; at level L a bit means that the corresponding subtree at level L - 1 is not empty). The
///        key of a word is (level << 128) | word index, and the word index at level L is key >> (8 * (L + 1)).
///        Children whose bit is set in an expanded word: the children of a word at level 1 (words at level 0) are
///        always expanded; at higher levels, a child is expanded when it holds two or more old starts, and when it
///        holds only one it is not expanded but recorded as a "lone key" (one slot that stores this old start,
///        keyed by the child's key with bit 255 set), and none of the levels below it is written. No word inside a
///        subtree that is not expanded is written.
///      - height is the number of levels in use; it grows with the largest old start seen so far, up to 16 levels
///        (2^128). The root is word 0 at level height - 1 and is always expanded when the tree is not empty. When
///        a non-empty tree grows taller, word 0 of each new level is written once (bit 0 means that the old root
///        below it is not empty), and these words and the old root stay expanded from then on, even with only one
///        child.
///      Complexity (h = height, independent of the number of records):
///      - Adding a record: writes one record slot; goes up from level 0 (or from the level at which the previous
///        record of the same consolidation separates from it) to the first expanded word, then goes down to the
///        child where it belongs: if the child is empty, it sets one bit and records the new child as a lone key;
///        if the child was a lone key, it expands down to the level at which the two old starts separate. When
///        sparse, each record mostly creates only the record slot and one lone key. At most h words on the path
///        and one lone key are read, and h + 2 slots are written (plus word 0 of each new level when the tree
///        grows taller).
///      - Floor and ceiling lookups: go up from level 0 to the first word with a candidate, then go down taking the
///        highest (lowest) bit, checking for a lone key first on each level and stopping at one; at most about 3h
///        slots are read.
///      - Finding all records that intersect a slice of serials [a, b): one floor lookup and one ceiling lookup;
///        after that, the search for each record continues from the bit of the previous record in its expanded
///        word (the records are pairwise disjoint), without reading upward from level 0 again; no record unrelated
///        to [a, b) is read.
library SerialConsolidations {
    struct Records {
        uint256 height;
        mapping(uint256 oldStart => uint256 packed) runs;
        mapping(uint256 key => uint256 bitmap) words;
    }

    /// @dev A growable list of slices [s[i], e[i]) in memory; only the first m entries are used.
    struct Pieces {
        uint256[] s;
        uint256[] e;
        uint256 m;
    }

    uint256 private constant MAX_HEIGHT = 16;
    /// @dev The key of a lone key is the key of the word with this bit set; its value is _ONE | old start (never
    ///      zero).
    uint256 private constant _LONE = 1 << 255;
    uint256 private constant _ONE = 1 << 128;
    /// @dev The value of prev in add that means "no previous record".
    uint256 internal constant NONE = type(uint256).max;

    /// @dev When runAt extends a consolidated run along adjacent records, the maximum number of further records it
    ///      reads after the record that contains serial. The bound keeps many small records that follow one another
    ///      from driving up the gas of on-chain callers: one query reads at most 1 + 32 records.
    uint256 internal constant MAX_RUN_EXTENSION = 32;

    // ───────────────────────── Records ─────────────────────────

    /// @dev Adds a record. The caller ensures that [oldStart, oldStart + len) does not intersect the old serials of
    ///      existing records, and that len > 0.
    ///      prev is the old start of another record added just before (one consolidation adds its records in
    ///      ascending order), or NONE if there is none: the search for an expanded word then goes up from the level
    ///      at which the two separate, instead of reading from level 0. prev affects only the cost, not the result.
    function add(Records storage r, uint256 oldStart, uint256 successor, uint256 len, uint256 prev) internal {
        r.runs[oldStart] = (successor << 128) | len;
        uint256 h = r.height;
        uint256 nh = h == 0 ? 1 : h;
        while (nh < MAX_HEIGHT && (oldStart >> (8 * nh)) != 0) {
            // Bit 0 of the new root (word 0 at level nh) means that the old root is not empty. It is not set when an
            // empty tree grows taller.
            if (h != 0) r.words[nh << 128] |= 1;
            ++nh;
        }
        if (nh != h) r.height = nh;
        // Go up to the first expanded word (the root is always expanded; in an empty tree the root is zero and the
        // record is added at the root). prev and oldStart lie in the same word at level `level`, and on the path of
        // prev this word is already expanded.
        uint256 level = prev == NONE || (prev >> 8) == (oldStart >> 8) ? 0 : _msb(prev ^ oldStart) >> 3;
        if (level >= nh) level = 0;
        uint256 w = r.words[_key(level, oldStart)];
        while (w == 0 && level + 1 < nh) {
            ++level;
            w = r.words[_key(level, oldStart)];
        }
        // Go down: enter the child if it is expanded; set a bit if there is no such child; expand the child if it
        // is a lone key.
        for (;; --level) {
            uint256 bit = uint256(1) << ((oldStart >> (8 * level)) & 255);
            if (w & bit == 0) {
                r.words[_key(level, oldStart)] = w | bit;
                _newChild(r, level, oldStart);
                return;
            }
            uint256 child = _key(level - 1, oldStart);
            w = r.words[child];
            if (w == 0) {
                uint256 other = uint128(r.words[_LONE | child]);
                r.words[_LONE | child] = 0;
                _split(r, level - 1, other, oldStart);
                return;
            }
        }
    }

    /// @dev add without prev.
    function add(Records storage r, uint256 oldStart, uint256 successor, uint256 len) internal {
        add(r, oldStart, successor, len, NONE);
    }

    /// @dev The bit for k has just been set in the word at level `level`, and k is the only old start in this child:
    ///      at level 0 the bit is k itself; at level 1 the child is a word at level 0 and is expanded; at higher
    ///      levels the child is recorded as a lone key.
    function _newChild(Records storage r, uint256 level, uint256 k) private {
        if (level == 1) r.words[_key(0, k)] = uint256(1) << (k & 255);
        else if (level > 1) r.words[_LONE | _key(level - 1, k)] = _ONE | k;
    }

    /// @dev The subtree at level `level` held only the old start a (its lone key has been deleted), and b is now
    ///      added: expands from level `level` down to the level d at which a and b separate, with only one bit on
    ///      each level in between; level d has two bits, and the two children hold one old start each.
    function _split(Records storage r, uint256 level, uint256 a, uint256 b) private {
        uint256 d = _msb(a ^ b) >> 3;
        for (uint256 l = level; l > d; --l) {
            r.words[_key(l, b)] = uint256(1) << ((b >> (8 * l)) & 255);
        }
        r.words[_key(d, b)] = (uint256(1) << ((a >> (8 * d)) & 255)) | (uint256(1) << ((b >> (8 * d)) & 255));
        _newChild(r, d, a);
        _newChild(r, d, b);
    }

    /// @dev The record whose old start is oldStart; len is 0 if there is none.
    function runOf(Records storage r, uint256 oldStart) internal view returns (uint256 successor, uint256 len) {
        uint256 v = r.runs[oldStart];
        return (v >> 128, uint128(v));
    }

    /// @dev The largest old start not greater than x.
    function floorKey(Records storage r, uint256 x) internal view returns (bool found, uint256 key) {
        uint256 h = r.height;
        if (h == 0) return (false, 0);
        if (h < MAX_HEIGHT && (x >> (8 * h)) != 0) x = (uint256(1) << (8 * h)) - 1;
        bool below = true;
        for (uint256 level; level < h; ++level) {
            uint256 idx = x >> (8 * (level + 1));
            uint256 pos = (x >> (8 * level)) & 255;
            uint256 w = r.words[(level << 128) | idx];
            if (w == 0) continue;
            if (below) {
                // The first expanded word: the child that contains x is not expanded and is a lone key (at level 0
                // it is x itself).
                below = false;
                if ((w >> pos) & 1 != 0) {
                    if (level == 0) return (true, x);
                    uint256 k = uint128(r.words[_LONE | ((level - 1) << 128) | (x >> (8 * level))]);
                    if (k <= x) return (true, k);
                }
            }
            uint256 m = w & ((uint256(1) << pos) - 1);
            if (m != 0) return (true, _last(r, level, (idx << 8) | _msb(m)));
        }
        return (false, 0);
    }

    /// @dev The smallest old start that is not less than x and is less than limit; returns limit if there is none.
    ///      Stops going up as soon as the answer is known to be not less than limit.
    function ceilKey(Records storage r, uint256 x, uint256 limit) internal view returns (uint256 key) {
        (key,) = _ceil(r, x, limit, 0, true);
    }

    /// @dev Implementation of ceilKey that also returns lv, the level of the expanded word in which the old start
    ///      found has a bit (at level 0 that bit is the old start itself; otherwise the subtree of that bit holds
    ///      only it). Searches upward from level `level`: when below, x is any serial and `level` is 0; otherwise x is
    ///      an old start that has a bit in the expanded word at level `level` (the lv returned by the previous
    ///      call), and the search is for the old starts after this bit of this word.
    function _ceil(Records storage r, uint256 x, uint256 limit, uint256 level, bool below)
        private
        view
        returns (uint256, uint256)
    {
        uint256 h = r.height;
        if (h == 0 || x >= limit) return (limit, 0);
        if (h < MAX_HEIGHT && (x >> (8 * h)) != 0) return (limit, 0);
        for (; level < h; ++level) {
            uint256 idx = x >> (8 * (level + 1));
            uint256 pos = (x >> (8 * level)) & 255;
            uint256 w = r.words[(level << 128) | idx];
            // Not expanded: this subtree of x holds at most one old start, recorded in a lone key on some level
            // above; the search cannot stop yet.
            if (w == 0) continue;
            if (below) {
                below = false;
                if ((w >> pos) & 1 != 0) {
                    if (level == 0) return (x, 0);
                    uint256 k = uint128(r.words[_LONE | ((level - 1) << 128) | (x >> (8 * level))]);
                    if (k >= x) return (k < limit ? k : limit, level);
                }
            }
            uint256 m = pos == 255 ? 0 : w & ~((uint256(1) << (pos + 1)) - 1);
            if (m != 0) {
                uint256 node = (idx << 8) | _lsb(m);
                // node is a word index at level `level - 1` (at level 0 it is the old start), and the smallest old
                // start in its subtree is node << (8 * level).
                if ((node << (8 * level)) >= limit) return (limit, 0);
                (node, level) = _first(r, level, node);
                return (node < limit ? node : limit, level);
            }
            // The old starts in the next word of this level are all not less than (idx + 1) << (8 * (level + 1)).
            if (((idx + 1) << (8 * (level + 1))) >= limit) return (limit, 0);
        }
        return (limit, 0);
    }

    /// @dev The largest old start below the bit node of a word at level `level` (at level 0 node is the old start;
    ///      otherwise it is a word index at level `level - 1`). For children at level 1 and above, the lone key is
    ///      checked first: when sparse, a child is usually a lone key, and one read is enough.
    function _last(Records storage r, uint256 level, uint256 node) private view returns (uint256) {
        for (uint256 l = level; l != 0; --l) {
            uint256 key = ((l - 1) << 128) | node;
            if (l > 1) {
                uint256 k = r.words[_LONE | key];
                if (k != 0) return uint128(k);
            }
            node = (node << 8) | _msb(r.words[key]);
        }
        return node;
    }

    /// @dev Like _last, but takes the smallest old start; also returns the level of the expanded word in which it
    ///      has a bit (see _ceil).
    function _first(Records storage r, uint256 level, uint256 node) private view returns (uint256, uint256) {
        for (uint256 l = level; l != 0; --l) {
            uint256 key = ((l - 1) << 128) | node;
            if (l > 1) {
                uint256 k = r.words[_LONE | key];
                if (k != 0) return (uint128(k), l);
            }
            node = (node << 8) | _lsb(r.words[key]);
        }
        return (node, 0);
    }

    /// @dev The key of the word at level `level` that contains x.
    function _key(uint256 level, uint256 x) private pure returns (uint256) {
        return (level << 128) | (x >> (8 * (level + 1)));
    }

    // ───────────────────────── Queries ─────────────────────────

    /// @dev The result of consolidatedRunAt (clauses 9 and 10 of "Consolidation" in the draft); issued is
    ///      serialsIssued().
    ///      When consolidated, the run goes from serial to the end of the record that contains it, and extends into
    ///      the next record whose old serials follow immediately and whose successors also follow immediately, by at
    ///      most MAX_RUN_EXTENSION more records; when more records follow one another, the run returned is shorter
    ///      than the longest one (clause 10 is only a SHOULD), and the caller can continue querying from the end of
    ///      the run returned. A truncated run has at least MAX_RUN_EXTENSION + 1 serials (each record has at least 1).
    ///      When not consolidated, the run ends at the old start of the next record (not beyond issued), and is the
    ///      longest run.
    ///      Cost: when consolidated, at most 1 + MAX_RUN_EXTENSION records are read, plus one floor lookup; when not
    ///      consolidated, one floor lookup and one ceiling lookup.
    function runAt(Records storage r, uint256 serial, uint256 issued)
        internal
        view
        returns (bool consolidated, uint256 successor, uint256 length)
    {
        if (serial >= issued) return (false, 0, 0);
        (bool found, uint256 k) = floorKey(r, serial);
        if (found) {
            (uint256 s, uint256 len) = runOf(r, k);
            if (serial - k < len) {
                uint256 e = k + len;
                uint256 ns = s + len;
                for (uint256 j; j < MAX_RUN_EXTENSION; ++j) {
                    (uint256 s2, uint256 l2) = runOf(r, e);
                    if (l2 == 0 || s2 != ns) break;
                    e += l2;
                    ns += l2;
                }
                return (true, s + (serial - k), e - serial);
            }
        }
        return (false, 0, ceilKey(r, serial + 1, issued) - serial);
    }

    /// @dev The successors of all generations of the consolidated serials in [start, end), excluding the parts that
    ///      fall inside [start, end); in ascending order of start, pairwise disjoint, with adjacent ones merged.
    ///      Processes a queue slice by slice: first [start, end), then each slice of successors found. For each
    ///      slice in the queue, it finds the records that intersect it and adds the successors of the intersecting
    ///      parts to the queue. A successor is always greater than its old serial, so only the successors found from
    ///      [start, end) can fall back inside [start, end); once those parts are removed, the slices in the queue are
    ///      pairwise disjoint, and each serial of each record is processed at most once.
    ///      Cost: one ceiling lookup and one record read for each record passed through, plus sorting the result,
    ///      O(r log r). Successors that follow one another are merged when queued, so the successors of the records
    ///      of one consolidation are queried again only as one slice.
    function successorsOf(Records storage r, uint256 start, uint256 end)
        internal
        view
        returns (uint256[] memory starts, uint256[] memory ends)
    {
        if (r.height == 0) return (starts, ends);
        Pieces memory q;
        _push(q, start, end);
        for (uint256 head; head < q.m; ++head) {
            _scan(r, q, head, end);
        }
        // Entry 0 is [start, end) itself.
        return _sortedTail(q);
    }

    // ───────────────────────── Private ─────────────────────────

    /// @dev Finds all records that intersect entry head [a, b) of the queue, and adds the successors of the
    ///      intersecting parts to the queue q (without the part below end).
    function _scan(Records storage r, Pieces memory q, uint256 head, uint256 end) private view {
        (uint256 a, uint256 b) = (q.s[head], q.e[head]);
        uint256 x = a;
        (bool found, uint256 k) = floorKey(r, a);
        if (found) {
            (uint256 s, uint256 len) = runOf(r, k);
            if (k + len > a) {
                _pushSuccessor(q, head, a, k + len < b ? k + len : b, k, s, end);
                x = k + len;
            }
        }
        // Then look up the following records one by one with ceiling lookups. The records are pairwise disjoint, so
        // the next old start after the old start k just found is not less than k + len: it is enough to continue
        // from the bit of k in its expanded word (at level lv), without reading upward from level 0 again.
        uint256 lv = NONE;
        while (x < b) {
            (k, lv) = lv == NONE ? _ceil(r, x, b, 0, true) : _ceil(r, k, b, lv, false);
            if (k == b) break;
            (uint256 s, uint256 len) = runOf(r, k);
            _pushSuccessor(q, head, k, k + len < b ? k + len : b, k, s, end);
            x = k + len;
        }
    }

    /// @dev The slices of the queue q except entry 0, sorted in ascending order of start, with adjacent ones merged.
    function _sortedTail(Pieces memory q) private pure returns (uint256[] memory starts, uint256[] memory ends) {
        uint256 n = q.m - 1;
        if (n == 0) return (starts, ends);
        starts = new uint256[](n);
        ends = new uint256[](n);
        bool sorted = true;
        for (uint256 i; i < n; ++i) {
            (starts[i], ends[i]) = (q.s[i + 1], q.e[i + 1]);
            if (i != 0 && starts[i] < starts[i - 1]) sorted = false;
        }
        if (!sorted) (starts, ends) = _sort(starts, ends);
        uint256 k;
        for (uint256 i = 1; i < n; ++i) {
            if (starts[i] == ends[k]) {
                ends[k] = ends[i];
            } else {
                ++k;
                (starts[k], ends[k]) = (starts[i], ends[i]);
            }
        }
        assembly ("memory-safe") {
            mstore(starts, add(k, 1))
            mstore(ends, add(k, 1))
        }
    }


    /// @dev The old serials [x, y) lie in the record with old start k and successor start s; adds their successors
    ///      to the queue, except the part that falls in [.., end).
    ///      When they directly follow the last entry of the queue and that entry has not been processed yet (its
    ///      index is greater than head, the entry being processed), they are merged into that entry: the successors
    ///      of the records of one consolidation are contiguous, and once merged they are queried once instead of once
    ///      per record. The two merged slices were disjoint to begin with, so the records found are the same as with
    ///      separate queries.
    function _pushSuccessor(Pieces memory q, uint256 head, uint256 x, uint256 y, uint256 k, uint256 s, uint256 end)
        private
        pure
    {
        uint256 ns = s + (x - k);
        uint256 ne = s + (y - k);
        if (ne <= end) return;
        if (ns < end) ns = end;
        uint256 last = q.m - 1;
        if (last > head && q.e[last] == ns) {
            q.e[last] = ne;
            return;
        }
        _push(q, ns, ne);
    }

    function _push(Pieces memory q, uint256 s, uint256 e) private pure {
        uint256 m = q.m;
        if (m == q.s.length) {
            uint256 cap = m == 0 ? 8 : 2 * m;
            uint256[] memory ns = new uint256[](cap);
            uint256[] memory ne = new uint256[](cap);
            for (uint256 i; i < m; ++i) {
                (ns[i], ne[i]) = (q.s[i], q.e[i]);
            }
            (q.s, q.e) = (ns, ne);
        }
        (q.s[m], q.e[m]) = (s, e);
        q.m = m + 1;
    }

    /// @dev Sorts in ascending order of start (bottom-up merge sort) and returns the sorted arrays.
    function _sort(uint256[] memory s, uint256[] memory e)
        private
        pure
        returns (uint256[] memory, uint256[] memory)
    {
        uint256 n = s.length;
        uint256[] memory ts = new uint256[](n);
        uint256[] memory te = new uint256[](n);
        for (uint256 width = 1; width < n; width *= 2) {
            for (uint256 lo; lo < n; lo += 2 * width) {
                uint256 mid = lo + width < n ? lo + width : n;
                uint256 hi = lo + 2 * width < n ? lo + 2 * width : n;
                (uint256 i, uint256 j) = (lo, mid);
                for (uint256 k = lo; k < hi; ++k) {
                    if (i < mid && (j >= hi || s[i] <= s[j])) {
                        (ts[k], te[k]) = (s[i], e[i]);
                        ++i;
                    } else {
                        (ts[k], te[k]) = (s[j], e[j]);
                        ++j;
                    }
                }
            }
            (s, ts) = (ts, s);
            (e, te) = (te, e);
        }
        return (s, e);
    }

    /// @dev The position of the highest set bit (x is not zero). Binary search without jumps.
    function _msb(uint256 x) private pure returns (uint256 n) {
        assembly ("memory-safe") {
            n := shl(7, lt(0xffffffffffffffffffffffffffffffff, x))
            n := or(n, shl(6, lt(0xffffffffffffffff, shr(n, x))))
            n := or(n, shl(5, lt(0xffffffff, shr(n, x))))
            n := or(n, shl(4, lt(0xffff, shr(n, x))))
            n := or(n, shl(3, lt(0xff, shr(n, x))))
            n := or(n, shl(2, lt(0xf, shr(n, x))))
            n := or(n, shl(1, lt(0x3, shr(n, x))))
            n := or(n, lt(0x1, shr(n, x)))
        }
    }

    /// @dev The position of the lowest set bit (x is not zero).
    function _lsb(uint256 x) private pure returns (uint256) {
        unchecked {
            return _msb(x & (~x + 1));
        }
    }
}

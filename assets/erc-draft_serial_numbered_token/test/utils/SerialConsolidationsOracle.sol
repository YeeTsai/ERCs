// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title SerialConsolidationsOracle
/// @notice For testing: the version of the consolidation record storage (a 256-ary bitmap tree) from before it was
///         changed to a different index structure, kept verbatim as the oracle that the library is compared
///         against.
///         Storage of consolidation records: each record states that the units of a slice of old serials
///         [oldStart, oldStart + length) received the new serials starting at successor. The old serials of the
///         records are pairwise disjoint (a serial is consolidated at most once).
/// @dev Storage (implementation detail):
///      - runs: old start -> (successor start << 128) | length, one slot per record. Serials do not exceed
///        2^128 - 1 (the same width as in the core).
///      - The set of old starts is stored as a 256-ary bitmap tree: each word at level 0 is a bitmap of 256
///        serials, and a bit at level L means that the corresponding word at level L - 1 is not zero. The key of a
///        word is (level << 128) | word index, and the word index at level L is key >> (8 * (L + 1)).
///      - height is the number of levels in use; it grows with the largest old start seen so far, up to 16 levels
///        (2^128). The root is word 0 at level height - 1.
///      Complexity (h = height, independent of the number of records):
///      - Adding a record: writes one record slot and sets bits upward from level 0 until it meets a word that was
///        already non-zero, at most h words. The cost depends on whether the words on the path are already
///        non-zero: when the old start is close to existing records, only one existing word is changed; when
///        sparse, a new word is created on every level.
///      - Floor lookup (the largest old start not greater than x) and ceiling lookup (the smallest old start not
///        less than x): go up from level 0 to the first word with a candidate bit, then go down taking the highest
///        (lowest) bit, at most 2h reads; only one read when the candidate is in the same word.
///      - Finding all records that intersect a slice of serials [a, b): one floor lookup, then ceiling lookups
///        record by record; no record unrelated to [a, b) is read.
library SerialConsolidationsOracle {
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

    /// @dev When spanAt extends a consolidated span along adjacent records, the maximum number of further records it
    ///      reads after the record that contains serial. The bound keeps many small records that follow one another
    ///      from driving up the gas of on-chain callers: one query reads at most 1 + 32 records.
    uint256 internal constant MAX_SPAN_EXTENSION = 32;

    // ───────────────────────── Records ─────────────────────────

    /// @dev Adds a record. The caller ensures that [oldStart, oldStart + len) does not intersect the old serials of
    ///      existing records, and that len > 0.
    function add(Records storage r, uint256 oldStart, uint256 successor, uint256 len) internal {
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
        for (uint256 level; level < nh; ++level) {
            uint256 key = (level << 128) | (oldStart >> (8 * (level + 1)));
            uint256 bit = uint256(1) << ((oldStart >> (8 * level)) & 255);
            uint256 w = r.words[key];
            if (w & bit != 0) break;
            r.words[key] = w | bit;
            // This word was already non-zero: the levels above already record it.
            if (w != 0) break;
        }
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
        for (uint256 level; level < h; ++level) {
            uint256 idx = x >> (8 * (level + 1));
            uint256 pos = (x >> (8 * level)) & 255;
            uint256 w = r.words[(level << 128) | idx];
            // At level 0 pos itself is included; on higher levels the subtree of pos has already been searched, so
            // only lower bits are considered.
            uint256 m;
            if (level == 0) m = pos == 255 ? w : w & ((uint256(1) << (pos + 1)) - 1);
            else m = w & ((uint256(1) << pos) - 1);
            if (m != 0) {
                uint256 node = (idx << 8) | _msb(m);
                for (uint256 l = level; l != 0; --l) {
                    node = (node << 8) | _msb(r.words[((l - 1) << 128) | node]);
                }
                return (true, node);
            }
        }
        return (false, 0);
    }

    /// @dev The smallest old start that is not less than x and is less than limit; returns limit if there is none.
    ///      Stops going up as soon as the answer is known to be not less than limit.
    function ceilKey(Records storage r, uint256 x, uint256 limit) internal view returns (uint256) {
        uint256 h = r.height;
        if (h == 0 || x >= limit) return limit;
        if (h < MAX_HEIGHT && (x >> (8 * h)) != 0) return limit;
        for (uint256 level; level < h; ++level) {
            uint256 idx = x >> (8 * (level + 1));
            uint256 pos = (x >> (8 * level)) & 255;
            uint256 w = r.words[(level << 128) | idx];
            uint256 m;
            if (level == 0) m = w & ~((uint256(1) << pos) - 1);
            else m = pos == 255 ? 0 : w & ~((uint256(1) << (pos + 1)) - 1);
            if (m != 0) {
                uint256 node = (idx << 8) | _lsb(m);
                // node is a word index at level `level - 1` (at level 0 it is the old start), and the smallest old
                // start in its subtree is node << (8 * level).
                if ((node << (8 * level)) >= limit) return limit;
                for (uint256 l = level; l != 0; --l) {
                    node = (node << 8) | _lsb(r.words[((l - 1) << 128) | node]);
                }
                return node < limit ? node : limit;
            }
            // The old starts in the next word of this level are all not less than (idx + 1) << (8 * (level + 1)).
            if (((idx + 1) << (8 * (level + 1))) >= limit) return limit;
        }
        return limit;
    }

    // ───────────────────────── Queries ─────────────────────────

    /// @dev The result of consolidatedSpanAt (clauses 9 and 10 of "Consolidation" in the draft); issued is
    ///      serialsIssued().
    ///      When consolidated, the span goes from serial to the end of the record that contains it, and extends into
    ///      the next record whose old serials follow immediately and whose successors also follow immediately, by at
    ///      most MAX_SPAN_EXTENSION more records; when more records follow one another, the span returned is shorter
    ///      than the longest one (clause 10 is only a SHOULD), and the caller can continue querying from the end of
    ///      the span returned. A truncated span has at least MAX_SPAN_EXTENSION + 1 serials (each record has at least 1).
    ///      When not consolidated, the span ends at the old start of the next record (not beyond issued), and is the
    ///      longest span.
    ///      Cost: when consolidated, at most 1 + MAX_SPAN_EXTENSION records are read, plus one floor lookup; when not
    ///      consolidated, one floor lookup and one ceiling lookup.
    function spanAt(Records storage r, uint256 serial, uint256 issued)
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
                for (uint256 j; j < MAX_SPAN_EXTENSION; ++j) {
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
        while (x < b) {
            k = ceilKey(r, x, b);
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
        uint256[] memory tmpStarts = new uint256[](n);
        uint256[] memory tmpEnds = new uint256[](n);
        for (uint256 width = 1; width < n; width *= 2) {
            for (uint256 lo; lo < n; lo += 2 * width) {
                uint256 mid = lo + width < n ? lo + width : n;
                uint256 hi = lo + 2 * width < n ? lo + 2 * width : n;
                (uint256 i, uint256 j) = (lo, mid);
                for (uint256 k = lo; k < hi; ++k) {
                    if (i < mid && (j >= hi || s[i] <= s[j])) {
                        (tmpStarts[k], tmpEnds[k]) = (s[i], e[i]);
                        ++i;
                    } else {
                        (tmpStarts[k], tmpEnds[k]) = (s[j], e[j]);
                        ++j;
                    }
                }
            }
            (s, tmpStarts) = (tmpStarts, s);
            (e, tmpEnds) = (tmpEnds, e);
        }
        return (s, e);
    }

    /// @dev The position of the highest set bit (x is not zero).
    function _msb(uint256 x) private pure returns (uint256 n) {
        if (x >= 1 << 128) {
            x >>= 128;
            n += 128;
        }
        if (x >= 1 << 64) {
            x >>= 64;
            n += 64;
        }
        if (x >= 1 << 32) {
            x >>= 32;
            n += 32;
        }
        if (x >= 1 << 16) {
            x >>= 16;
            n += 16;
        }
        if (x >= 1 << 8) {
            x >>= 8;
            n += 8;
        }
        if (x >= 1 << 4) {
            x >>= 4;
            n += 4;
        }
        if (x >= 1 << 2) {
            x >>= 2;
            n += 2;
        }
        if (x >= 1 << 1) n += 1;
    }

    /// @dev The position of the lowest set bit (x is not zero).
    function _lsb(uint256 x) private pure returns (uint256) {
        unchecked {
            return _msb(x & (~x + 1));
        }
    }
}

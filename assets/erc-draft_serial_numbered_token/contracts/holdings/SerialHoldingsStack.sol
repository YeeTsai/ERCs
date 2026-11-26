// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SerialHoldingsArray} from "./SerialHoldingsArray.sol";

/// @title SerialHoldingsStack
/// @notice Slice stack: a newly received slice is pushed on top of the stack, and is merged with the top slice when
///         adjacent to it; a transfer by amount takes from the top of the stack, that is, last-in-first-out.
/// @dev Cost profile:
///      - Receiving a slice and transferring out a slice both have constant cost.
///      - Locating by serial (transferSlices, forced operations) scans the whole pile, at a cost that grows linearly
///        with the number of slices of the account.
///      - Slices are merged only with the top of the stack, so receiving units adjacent to an older slice still
///        increases the number of slices.
///
///      The selection rule for selection by amount is set by the deployment parameter selectionWindow, stored as an
///      immutable: it cannot be changed after deployment, and transfers read no extra storage for it:
///      - 0: the default rule, take from the top of the stack, that is, last-in-first-out.
///      - W >= 1: the second rule, "best fit in a bounded window", which looks only at the at most W slices on top
///        of the stack (defined in the notes at the top of ERCXXXX).
///        With W = 1 the result is the same as under the default rule, but the code of the second rule runs, which
///        costs slightly more; when W is not less than the number of slices in the pile, it is a best fit over the
///        whole pile, and each pick reads the whole pile.
///      When a slice in the middle of the window is taken whole, _removeAt moves the top slice into its position and
///      then pops the top of the stack; when only part of it is taken, the lower remainder stays in place.
///      So taking units shuffles the order only inside the window, and the slices below the window stay in the
///      order in which they were received.
abstract contract SerialHoldingsStack is SerialHoldingsArray {
    /// @dev The window size W of the second rule; 0 means the default rule.
    uint256 private immutable _window;

    constructor(uint256 selectionWindow) {
        _window = selectionWindow;
    }

    function _selectionWindow() internal view virtual override returns (uint256) {
        return _window;
    }

    function _addRange(address account, bytes32 pile, uint256 n, uint256 start, uint256 len)
        internal
        virtual
        override
        returns (uint256)
    {
        if (n != 0) {
            (uint256 ts, uint256 tl) = _rangeAt(account, pile, n - 1);
            if (ts + tl == start) {
                _writeRange(account, pile, n - 1, ts, tl + len);
                return n;
            }
            if (start + len == ts) {
                _writeRange(account, pile, n - 1, start, tl + len);
                return n;
            }
        }
        _writeRange(account, pile, n, start, len);
        return n + 1;
    }

    /// @dev Pushes the slices onto the stack one by one in the given order.
    function _addRanges(
        address account,
        bytes32 pile,
        uint256 n,
        uint256[] memory starts,
        uint256[] memory lens,
        uint256 m
    ) internal virtual override returns (uint256) {
        for (uint256 i; i < m; ++i) {
            n = _addRange(account, pile, n, starts[i], lens[i]);
        }
        return n;
    }

    /// @dev The lower remainder stays in place and the upper remainder is appended at the end; when nothing remains
    ///      on either side, the last slice is moved into this position.
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
                _writeRange(account, pile, n, hi, e - hi);
                return n + 1;
            }
            return n;
        }
        if (hi < e) {
            _writeRange(account, pile, i, hi, e - hi);
            return n;
        }
        if (i != n - 1) _copyRange(account, pile, n - 1, i);
        _clearRange(account, pile, n - 1);
        return n - 1;
    }

    /// @dev Scans the whole pile from the top of the stack downward.
    function _removeSerials(address account, bytes32 pile, uint256 n, uint256 lo, uint256 hi)
        internal
        virtual
        override
        returns (uint256 newN, uint256 removed)
    {
        uint256 want = hi - lo;
        newN = n;
        for (uint256 idx = n; idx != 0 && removed < want; --idx) {
            uint256 i = idx - 1;
            (uint256 s, uint256 len) = _rangeAt(account, pile, i);
            uint256 e = s + len;
            if (s >= hi || e <= lo) continue;
            uint256 ps = s > lo ? s : lo;
            uint256 pe = e < hi ? e : hi;
            newN = _removeAt(account, pile, newN, i, ps, pe);
            removed += pe - ps;
        }
    }

    /// @dev Scans once from the top of the stack downward; for each slice, finds by binary search the given slices
    ///      that intersect it; stops once want serials have been removed.
    function _removeSerialsBatch(
        address account,
        bytes32 pile,
        uint256 n,
        uint256[] memory los,
        uint256[] memory his,
        uint256[] memory got,
        uint256 want
    ) internal virtual override returns (uint256 newN, uint256 total) {
        newN = n;
        for (uint256 idx = n; idx != 0 && total < want; --idx) {
            uint256 removed;
            (newN, removed) = _cutRange(account, pile, newN, idx - 1, los, his, got);
            total += removed;
        }
    }

    /// @dev Removes from the slice at index i the parts that intersect the given slices. Takes from high to low:
    ///      _removeAt leaves the lower remainder at index i and appends the upper remainder at the end (a position
    ///      already visited).
    function _cutRange(
        address account,
        bytes32 pile,
        uint256 n,
        uint256 i,
        uint256[] memory los,
        uint256[] memory his,
        uint256[] memory got
    ) private returns (uint256 newN, uint256 removed) {
        newN = n;
        (uint256 s, uint256 len) = _rangeAt(account, pile, i);
        uint256 e = s + len;
        for (uint256 j = _countStartsBelow(los, e); j != 0; --j) {
            if (his[j - 1] <= s) break;
            uint256 ps = los[j - 1] > s ? los[j - 1] : s;
            uint256 pe = his[j - 1] < e ? his[j - 1] : e;
            newN = _removeAt(account, pile, newN, i, ps, pe);
            got[j - 1] += pe - ps;
            removed += pe - ps;
            // The start of this slice has been reached: lower given slices cannot intersect it (when the whole
            // slice was taken, index i now holds a different slice).
            if (ps == s) break;
        }
    }

    /// @dev The number of given slices whose start is less than x (los is in ascending order).
    function _countStartsBelow(uint256[] memory los, uint256 x) private pure returns (uint256 lo) {
        uint256 hi = los.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) >> 1;
            if (los[mid] < x) lo = mid + 1;
            else hi = mid;
        }
    }
}

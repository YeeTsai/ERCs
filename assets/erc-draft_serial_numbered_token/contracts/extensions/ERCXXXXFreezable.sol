// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERCXXXX} from "../ERCXXXX.sol";
import {IERCXXXXFreezable} from "../spec/IERCXXXXFreezable.sol";
import {SerialSteps} from "../utils/SerialSteps.sol";
import {SerialBounds} from "../utils/SerialBounds.sol";

/// @title ERCXXXXFreezable: reference implementation of the freezing extension
/// @notice Freezes serials by reason, and provides forced transfer and destruction.
///         Who can freeze, unfreeze and perform forced operations is decided by the token, which implements
///         _authorizeFreeze and _authorizeForced (clause 10 of "Freezing and unfreezing" and clause 8 of
///         "Forced transfer and destruction" in the draft require an implementation to restrict the caller).
///
/// @dev Storage (implementation details):
///      - For each reason, a sorted set of slices records the serials frozen for that reason.
///      - A global step function, the cover count, records the number of freezes covering each serial, that is,
///        for how many reasons it is frozen. Transfers read only this function, so their cost does not depend on
///        the number of reasons.
///      - The bounding slice shared with the classification extension (SerialBounds, at a fixed storage slot):
///        all frozen serials lie within it, and it also records whether there is any freeze and whether the cover
///        count consists of a single slice. A transfer reads it first; when there is no freeze, or the serial lies
///        outside the bounding slice, the cover count is not read; when only freezes exist and there is a single
///        slice, it need not be read inside the bounding slice either. After a freeze or an unfreeze it is updated
///        from the first breakpoint, the last breakpoint and the number of breakpoints of the cover count (2 more
///        slots read and written, plus 1 more slot read when the classification extension also has
///        restrictions).
///      - Freezes are recorded on serials, independently of holders, so destroyed serials keep their original
///        frozen state.
///
///      Choices of this implementation:
///      - A reason has to be registered with a name through _setReasonInfo before it can be used for freezing, so
///        a reason in use always has a name (clause 6 of "Freeze queries" in the draft).
///      - Forced operations by default require all the named serials to be frozen (the SHOULD of the draft);
///        overriding _requireFrozenForForced can remove this requirement.
///
///      When used together with the consolidation module ERCXXXXConsolidation ("Freezing and consolidation" in
///      the draft): a freeze or an unfreeze obtains the successors of every generation through the core hook
///      _successorPieces and merges them, together with the slice named in the call, into the set of slices (or
///      removes them from it); the set of slices and the cover count are still each rebuilt only once. One
///      additional event is emitted for each slice of successors. The rule that frozen serials cannot be
///      consolidated is checked by the consolidation module (by the frozen pile that _segmentAt reports). A token
///      that does not open consolidation has no consolidation records; _successorPieces returns empty arrays, and
///      freezes and unfreezes do not propagate.
///
///      Known limitation: every freeze or unfreeze rewrites the set of slices of that reason and the whole cover
///      count step function, at a cost that grows linearly with their number of points.
abstract contract ERCXXXXFreezable is ERCXXXX, IERCXXXXFreezable {
    /// @dev The slice [start, end); it takes one storage slot.
    struct Range {
        uint128 start;
        uint128 end;
    }

    /// @dev A breakpoint of the cover count step function.
    struct CoverPoint {
        uint128 pos;
        uint128 count;
    }

    struct ReasonInfo {
        string name;
        string uri;
    }

    /// @notice The reason has no registered name, or the registered name is empty.
    error ERCXXXXInvalidReason(bytes32 reason);
    /// @notice Some of the serials named by a forced operation are not frozen.
    error ERCXXXXNotFrozen(uint256 start, uint256 amount);

    /// @dev The serials frozen for each reason: in ascending order of start, pairwise disjoint and not adjacent.
    mapping(bytes32 reason => Range[]) private _reasonRanges;
    /// @dev The reasons whose set of frozen slices is not empty. freezeReasonsOf iterates over it.
    bytes32[] private _activeReasons;
    mapping(bytes32 reason => uint256) private _activeSlot; // index + 1
    mapping(bytes32 reason => ReasonInfo) private _reasonInfo;
    /// @dev The number of reasons for which each serial is frozen.
    CoverPoint[] private _cover;

    // ───────────────────────── ERC-165 ─────────────────────────

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IERCXXXXFreezable).interfaceId || super.supportsInterface(interfaceId);
    }

    // ───────────────────────── IERCXXXXFreezable ─────────────────────────

    function freezeSlice(uint256 start, uint256 amount, bytes32 reason) public virtual {
        _authorizeFreeze(msg.sender, reason, true);
        _freeze(start, amount, reason);
    }

    function unfreezeSlice(uint256 start, uint256 amount, bytes32 reason) public virtual {
        _authorizeFreeze(msg.sender, reason, false);
        _unfreeze(start, amount, reason);
    }

    function forcedTransferSlice(address from, address to, uint256 start, uint256 amount) public virtual {
        _authorizeForced(msg.sender, from, to);
        _forcedTransfer(from, to, start, amount);
    }

    function destroySlice(address from, uint256 start, uint256 amount) public virtual {
        _authorizeForced(msg.sender, from, address(0));
        _destroy(from, start, amount);
    }

    // ───────────────────────── Hinted forced operations (functions of this implementation) ─────────────────────────
    // Clause 9 of "Forced transfer and destruction" in the draft allows an implementation to provide other functions
    // that perform forced operations, as long as they follow the event rules of clauses 5 and 7 and restrict the
    // caller.
    // These two functions are the same as the two above, except that the caller gives the position of these serials
    // in the holding of from (read with serialPositionOf), so the whole holding need not be searched:
    // [start, start + amount) has to lie entirely within the slice with the index given by index in the pile with
    // the key pile; otherwise the call reverts with ERCXXXXStaleHint and changes nothing, and the caller can read
    // the position again and call again.
    //
    // On the slice stack the cost is constant and does not depend on the number of slices of the account; on the
    // sorted array, taking a slice out of the middle still shifts the slices after it.
    // The position changes in these cases: anyone calls the tidying function; a transfer by the holder moves a
    // misplaced slice between piles; when a whole slice is taken from the same pile, the last slice moves into its
    // index (slice stack); a slice with smaller serials is received (sorted array). So the position has to be read
    // shortly before the call.

    function forcedTransferSliceAt(
        address from,
        address to,
        uint256 start,
        uint256 amount,
        bytes32 pile,
        uint256 index
    ) public virtual {
        _authorizeForced(msg.sender, from, to);
        _forcedTransferAt(from, to, start, amount, pile, index);
    }

    function destroySliceAt(address from, uint256 start, uint256 amount, bytes32 pile, uint256 index)
        public
        virtual
    {
        _authorizeForced(msg.sender, from, address(0));
        _destroyAt(from, start, amount, pile, index);
    }

    /// @notice The position of serial in the holding of account, as the hint for the two functions above: the pile
    ///         that holds it, the index in that pile, and the whole slice at this position (the named slice has to
    ///         lie entirely within it). held is false when the serial is not held. Scans slice by slice; meant for
    ///         off-chain calls.
    function serialPositionOf(address account, uint256 serial)
        public
        view
        virtual
        returns (bool held, bytes32 pile, uint256 index, uint256 rangeStart, uint256 rangeAmount)
    {
        return _positionOf(account, serial);
    }

    /// @dev Destroyed serials also have a frozen state (destruction does not change it), so when destroyed serials
    ///      lie between two frozen slices, the run returned is a slice of the cover count step function and is not
    ///      broken by the destroyed serials in between.
    function frozenRunAt(uint256 serial) public view virtual returns (bool frozen, uint256 length) {
        uint256 issued = serialsIssued();
        if (serial >= issued) return (false, 0);
        uint256 n = _cover.length;
        (bool found, uint256 i) = _coverFind(serial);
        frozen = found && _cover[i].count != 0;
        uint256 j = found ? i + 1 : 0;
        while (j < n && (_cover[j].count != 0) == frozen) {
            ++j;
        }
        uint256 end = j < n ? _cover[j].pos : type(uint256).max;
        if (end > issued) end = issued;
        length = end - serial;
    }

    function frozenBalanceOf(address account) public view virtual returns (uint256 total) {
        if (_cover.length == 0) return 0;
        (uint256[] memory starts, uint256[] memory lens) = _heldRanges(account);
        for (uint256 i; i < starts.length; ++i) {
            total += _frozenAmountIn(starts[i], starts[i] + lens[i]);
        }
    }

    /// @dev Cost = number of reasons whose set of frozen slices is not empty x number of slices of the account
    ///      x log(number of slices of that reason).
    function freezeReasonsOf(address account)
        public
        view
        virtual
        returns (bytes32[] memory reasons, uint256[] memory amounts)
    {
        uint256 rn = _activeReasons.length;
        reasons = new bytes32[](rn);
        amounts = new uint256[](rn);
        if (rn == 0) return (reasons, amounts);
        (uint256[] memory starts, uint256[] memory lens) = _heldRanges(account);
        uint256 k;
        for (uint256 r; r < rn; ++r) {
            bytes32 reason = _activeReasons[r];
            Range[] storage rs = _reasonRanges[reason];
            uint256 total;
            for (uint256 i; i < starts.length; ++i) {
                total += _rangesLen(rs, starts[i], starts[i] + lens[i]);
            }
            if (total != 0) {
                reasons[k] = reason;
                amounts[k] = total;
                ++k;
            }
        }
        // Shrinks the array lengths in place (k is not greater than the original length); this writes only memory
        // that the arrays have already allocated, so it is marked memory-safe.
        // via-IR can move variables that do not fit on the stack into memory only if all inline assembly in the
        // contract is memory-safe; otherwise _reasonUnion fails to compile.
        assembly ("memory-safe") {
            mstore(reasons, k)
            mstore(amounts, k)
        }
    }

    function freezeReasonInfo(bytes32 reason) public view virtual returns (string memory name_, string memory uri) {
        ReasonInfo storage d = _reasonInfo[reason];
        return (d.name, d.uri);
    }

    // ───────────────────────── Authorization hooks ─────────────────────────

    /// @dev Whether caller can freeze (freeze is true) or unfreeze for reason. Reverts if not.
    function _authorizeFreeze(address caller, bytes32 reason, bool freeze) internal virtual;

    /// @dev Whether caller can force a transfer of serials of from to the address to (to being the zero address
    ///      denotes destruction). Reverts if not.
    function _authorizeForced(address caller, address from, address to) internal virtual;

    /// @dev Whether forced operations require all the named serials to be frozen.
    function _requireFrozenForForced() internal view virtual returns (bool) {
        return true;
    }

    // ───────────────────────── Internal operations ─────────────────────────

    /// @dev Registers or modifies the name and the description document of a reason. The name must not be empty.
    function _setReasonInfo(bytes32 reason, string memory name_, string memory uri) internal virtual {
        if (bytes(name_).length == 0) revert ERCXXXXInvalidReason(reason);
        _reasonInfo[reason] = ReasonInfo(name_, uri);
    }

    /// @dev Freezes [start, start + amount) and propagates the freeze to the successors of every generation of these
    ///      serials (clauses 2 and 4 of "Freezing and consolidation" in the draft). The successors are given by the
    ///      core hook _successorPieces and are empty when consolidation is closed. The reason's set of slices and
    ///      the cover count are each rebuilt once, however many slices the freeze propagates to. Emits SliceFrozen
    ///      for the slice named in the call first, then one SliceFrozen for each slice of successors, in ascending
    ///      order of serial.
    function _freeze(uint256 start, uint256 amount, bytes32 reason) internal virtual {
        uint256 end = _checkedRange(start, amount);
        if (bytes(_reasonInfo[reason].name).length == 0) revert ERCXXXXInvalidReason(reason);
        (uint256[] memory ss, uint256[] memory se) = _successorPieces(start, end);
        SerialSteps.Pieces memory gaps = ss.length == 0
            ? _reasonUnion(reason, start, end)
            : _reasonUnionPieces(reason, _withSuccessors(start, end, ss, se));
        if (gaps.m != 0) _coverApply(gaps, SerialSteps.ADD);
        emit SliceFrozen(reason, start, amount);
        for (uint256 i; i < ss.length; ++i) {
            emit SliceFrozen(reason, ss[i], se[i] - ss[i]);
        }
    }

    /// @dev Propagates the unfreeze in the same way as _freeze (clause 3 of "Freezing and consolidation" in the
    ///      draft).
    function _unfreeze(uint256 start, uint256 amount, bytes32 reason) internal virtual {
        uint256 end = _checkedRange(start, amount);
        (uint256[] memory ss, uint256[] memory se) = _successorPieces(start, end);
        SerialSteps.Pieces memory cut = ss.length == 0
            ? _reasonDiff(reason, start, end)
            : _reasonDiffPieces(reason, _withSuccessors(start, end, ss, se));
        if (cut.m != 0) _coverApply(cut, SerialSteps.SUB);
        emit SliceUnfrozen(reason, start, amount);
        for (uint256 i; i < ss.length; ++i) {
            emit SliceUnfrozen(reason, ss[i], se[i] - ss[i]);
        }
    }

    function _forcedTransfer(address from, address to, uint256 start, uint256 amount) internal virtual {
        if (to == address(0) || to == from) revert ERC20InvalidReceiver(to);
        _requireFrozen(start, amount);
        _moveRange(from, to, start, amount);
        emit SliceForciblyTransferred(from, to, start, amount);
    }

    function _destroy(address from, uint256 start, uint256 amount) internal virtual {
        _requireFrozen(start, amount);
        _moveRange(from, address(0), start, amount);
        emit SliceForciblyTransferred(from, address(0), start, amount);
    }

    /// @dev The checks and events are the same as for _forcedTransfer; locating uses the position hint instead.
    function _forcedTransferAt(address from, address to, uint256 start, uint256 amount, bytes32 pile, uint256 index)
        internal
        virtual
    {
        if (to == address(0) || to == from) revert ERC20InvalidReceiver(to);
        _requireFrozen(start, amount);
        _moveRangeAt(from, to, start, amount, pile, index);
        emit SliceForciblyTransferred(from, to, start, amount);
    }

    function _destroyAt(address from, uint256 start, uint256 amount, bytes32 pile, uint256 index) internal virtual {
        _requireFrozen(start, amount);
        _moveRangeAt(from, address(0), start, amount, pile, index);
        emit SliceForciblyTransferred(from, address(0), start, amount);
    }

    /// @dev The number of frozen serials in [s, e).
    function _frozenAmountIn(uint256 s, uint256 e) internal view returns (uint256 total) {
        uint256 n = _cover.length;
        if (n == 0) return 0;
        (bool found, uint256 i) = _coverFind(s);
        uint256 cnt = found ? _cover[i].count : 0;
        uint256 next = found ? i + 1 : 0;
        uint256 x = s;
        while (x < e) {
            uint256 nb = next < n ? _cover[next].pos : type(uint256).max;
            uint256 segEnd = nb < e ? nb : e;
            if (cnt != 0) total += segEnd - x;
            x = segEnd;
            if (x < e) {
                cnt = _cover[next].count;
                ++next;
            }
        }
    }

    // ───────────────────────── Hooks of the core ─────────────────────────

    /// @dev Reads only the one slot of the bounding slice, the same slot that the classification extension reads.
    function _hasRestrictions() internal view virtual override returns (bool) {
        return SerialBounds.any() || super._hasRestrictions();
    }

    /// @dev Frozen serials belong to the frozen pile, which is not usable for any (from, to). It first reads the
    ///      slot of the bounding slice (SerialBounds), so in most cases the cover count need not be read:
    ///      - No freeze: no narrowing.
    ///      - The serial lies outside the bounding slice [bl, bh): not frozen; the slice is narrowed to this side of
    ///        the bounding slice. The combined bounding slice is the union of the bounding slices of freezes and of
    ///        classes, so the narrowing by the two extensions gives the same result as each of them reading its own
    ///        step function.
    ///      - Only freezes exist, and the cover count has exactly one slice (two breakpoints): the bounding slice is
    ///        that slice, and all serials in it are frozen.
    ///      In the other cases, the function does a binary search on the cover count.
    function _segmentAt(uint256 serial) internal view virtual override returns (uint256 lo, uint256 hi, bytes32 pile) {
        (lo, hi, pile) = super._segmentAt(serial);
        (uint256 cs, uint256 ce, uint256 kind) = SerialBounds.probe(serial, SerialBounds.FREEZE);
        if (kind == SerialBounds.NONE) return (lo, hi, pile);
        uint256 cnt = kind == SerialBounds.SINGLE ? 1 : 0;
        if (kind == SerialBounds.LOOKUP) (cs, ce, cnt) = _coverSeg(serial);
        if (cs > lo) lo = cs;
        if (ce < hi) hi = ce;
        if (cnt != 0) pile = _FROZEN_PILE;
    }

    // ───────────────────────── Private: frozen slices ─────────────────────────

    /// @dev Serials that are not yet issued also count as "not held by from", for which the draft recommends
    ///      ERCXXXXNotHeld, so whether the serials are issued is checked first.
    function _requireFrozen(uint256 start, uint256 amount) private view {
        if (!_requireFrozenForForced() || amount == 0 || start >= serialsIssued()) return;
        if (amount > serialsIssued() - start) return;
        if (_frozenAmountIn(start, start + amount) != amount) revert ERCXXXXNotFrozen(start, amount);
    }

    /// @dev Adds [a, b) to the frozen slices of reason and returns the part of it that was not frozen for reason
    ///      before.
    function _reasonUnion(bytes32 reason, uint256 a, uint256 b) private returns (SerialSteps.Pieces memory gaps) {
        Range[] storage rs = _reasonRanges[reason];
        uint256 n = rs.length;
        Range[] memory out = new Range[](n + 1);
        gaps = SerialSteps.newPieces(n + 1);
        uint256 k;
        uint256 s = a;
        uint256 e = b;
        uint256 cursor = a;
        bool placed;
        for (uint256 i; i < n; ++i) {
            Range memory r = rs[i];
            if (r.start < b && r.end > a) {
                if (r.start > cursor) SerialSteps.addPiece(gaps, cursor, r.start);
                if (r.end > cursor) cursor = r.end;
            }
            if (r.end < s) {
                out[k++] = r;
            } else if (r.start > e) {
                if (!placed) {
                    out[k++] = Range(uint128(s), uint128(e));
                    placed = true;
                }
                out[k++] = r;
            } else {
                if (r.start < s) s = r.start;
                if (r.end > e) e = r.end;
            }
        }
        if (cursor < b) SerialSteps.addPiece(gaps, cursor, b);
        if (!placed) out[k++] = Range(uint128(s), uint128(e));
        _writeRanges(rs, out, k);
        _syncReason(reason, k);
    }

    /// @dev Removes [a, b) from the frozen slices of reason and returns the part actually removed.
    function _reasonDiff(bytes32 reason, uint256 a, uint256 b) private returns (SerialSteps.Pieces memory cut) {
        Range[] storage rs = _reasonRanges[reason];
        uint256 n = rs.length;
        Range[] memory out = new Range[](n + 1);
        cut = SerialSteps.newPieces(n);
        uint256 k;
        for (uint256 i; i < n; ++i) {
            Range memory r = rs[i];
            if (r.end <= a || r.start >= b) {
                out[k++] = r;
                continue;
            }
            SerialSteps.addPiece(cut, r.start > a ? r.start : a, r.end < b ? r.end : b);
            if (r.start < a) out[k++] = Range(r.start, uint128(a));
            if (r.end > b) out[k++] = Range(uint128(b), r.end);
        }
        _writeRanges(rs, out, k);
        _syncReason(reason, k);
    }

    /// @dev Combines [start, end) and its successors [ss[i], se[i]) into one ascending list of pairwise disjoint
    ///      slices. The successors are all not less than end and are already sorted.
    function _withSuccessors(uint256 start, uint256 end, uint256[] memory ss, uint256[] memory se)
        private
        pure
        returns (SerialSteps.Pieces memory pc)
    {
        pc = SerialSteps.newPieces(ss.length + 1);
        SerialSteps.addPiece(pc, start, end);
        for (uint256 i; i < ss.length; ++i) {
            SerialSteps.addPiece(pc, ss[i], se[i]);
        }
    }

    /// @dev The same as _reasonUnion, but adds several slices at once: the slices of pc are in ascending order and
    ///      pairwise disjoint, and may be adjacent.
    ///      Used only when propagating to successors; without successors the single-slice version above is used, at
    ///      the same cost as when consolidation is closed.
    function _reasonUnionPieces(bytes32 reason, SerialSteps.Pieces memory pc)
        private
        returns (SerialSteps.Pieces memory gaps)
    {
        Range[] storage rs = _reasonRanges[reason];
        Range[] memory cur = _loadRanges(rs);
        uint256 n = cur.length;
        gaps = SerialSteps.newPieces(n + pc.m);
        uint256 i;
        for (uint256 j; j < pc.m; ++j) {
            uint256 a = pc.s[j];
            uint256 b = pc.e[j];
            while (i < n && cur[i].end <= a) ++i;
            uint256 cursor = a;
            for (uint256 t = i; t < n && cur[t].start < b; ++t) {
                if (cur[t].start > cursor) SerialSteps.addPiece(gaps, cursor, cur[t].start);
                if (cur[t].end > cursor) cursor = cur[t].end;
            }
            if (cursor < b) SerialSteps.addPiece(gaps, cursor, b);
        }
        // Merges two ascending lists of slices; overlapping or adjacent slices are combined into one.
        Range[] memory out = new Range[](n + pc.m);
        uint256 k;
        uint256 j2;
        i = 0;
        while (i < n || j2 < pc.m) {
            uint256 s;
            uint256 e;
            if (j2 == pc.m || (i < n && cur[i].start <= pc.s[j2])) {
                (s, e) = (cur[i].start, cur[i].end);
                ++i;
            } else {
                (s, e) = (pc.s[j2], pc.e[j2]);
                ++j2;
            }
            if (k != 0 && s <= out[k - 1].end) {
                if (e > out[k - 1].end) out[k - 1].end = uint128(e);
            } else {
                out[k++] = Range(uint128(s), uint128(e));
            }
        }
        _writeRanges(rs, out, k);
        _syncReason(reason, k);
    }

    /// @dev The same as _reasonDiff, but removes several slices at once (with the same requirements as above).
    function _reasonDiffPieces(bytes32 reason, SerialSteps.Pieces memory pc)
        private
        returns (SerialSteps.Pieces memory cut)
    {
        Range[] storage rs = _reasonRanges[reason];
        Range[] memory cur = _loadRanges(rs);
        uint256 n = cur.length;
        Range[] memory out = new Range[](n + pc.m);
        cut = SerialSteps.newPieces(n + pc.m);
        uint256 k;
        uint256 j;
        for (uint256 i; i < n; ++i) {
            Range memory r = cur[i];
            uint256 x = r.start;
            while (j < pc.m && pc.e[j] <= r.start) ++j;
            for (uint256 t = j; t < pc.m && pc.s[t] < r.end; ++t) {
                uint256 cs = pc.s[t] > r.start ? pc.s[t] : r.start;
                uint256 ce = pc.e[t] < r.end ? pc.e[t] : r.end;
                SerialSteps.addPiece(cut, cs, ce);
                if (cs > x) out[k++] = Range(uint128(x), uint128(cs));
                x = ce;
            }
            if (x < r.end) out[k++] = Range(uint128(x), r.end);
        }
        _writeRanges(rs, out, k);
        _syncReason(reason, k);
    }

    function _loadRanges(Range[] storage rs) private view returns (Range[] memory cur) {
        uint256 n = rs.length;
        cur = new Range[](n);
        for (uint256 i; i < n; ++i) {
            cur[i] = rs[i];
        }
    }

    function _writeRanges(Range[] storage rs, Range[] memory out, uint256 k) private {
        uint256 n = rs.length;
        for (uint256 i; i < k; ++i) {
            if (i < n) {
                Range memory cur = rs[i];
                if (cur.start != out[i].start || cur.end != out[i].end) rs[i] = out[i];
            } else {
                rs.push(out[i]);
            }
        }
        for (; n > k; --n) {
            rs.pop();
        }
    }

    /// @dev Maintains the register of "reasons whose set of frozen slices is not empty".
    function _syncReason(bytes32 reason, uint256 rangeCount) private {
        uint256 slot = _activeSlot[reason];
        if (rangeCount != 0 && slot == 0) {
            _activeReasons.push(reason);
            _activeSlot[reason] = _activeReasons.length;
        } else if (rangeCount == 0 && slot != 0) {
            uint256 last = _activeReasons.length;
            if (slot != last) {
                bytes32 moved = _activeReasons[last - 1];
                _activeReasons[slot - 1] = moved;
                _activeSlot[moved] = slot;
            }
            _activeReasons.pop();
            delete _activeSlot[reason];
        }
    }

    /// @dev The number of serials in the sorted set of slices rs that lie in [s, e).
    function _rangesLen(Range[] storage rs, uint256 s, uint256 e) private view returns (uint256 total) {
        uint256 lo;
        uint256 hi = rs.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) >> 1;
            if (rs[mid].end <= s) lo = mid + 1;
            else hi = mid;
        }
        for (uint256 i = lo; i < rs.length; ++i) {
            Range memory r = rs[i];
            if (r.start >= e) break;
            uint256 a = r.start > s ? r.start : s;
            uint256 b = r.end < e ? r.end : e;
            total += b - a;
        }
    }

    // ───────────────────────── Private: cover count ─────────────────────────

    function _coverApply(SerialSteps.Pieces memory pc, uint8 mode) private {
        uint256 n = _cover.length;
        SerialSteps.Steps memory old = SerialSteps.newSteps(n);
        for (uint256 i; i < n; ++i) {
            CoverPoint memory p = _cover[i];
            SerialSteps.push(old, p.pos, p.count);
        }
        SerialSteps.Steps memory st = SerialSteps.rebuild(old, pc, mode, 0);
        for (uint256 i; i < st.n; ++i) {
            CoverPoint memory p = CoverPoint(uint128(st.pos[i]), uint128(st.val[i]));
            if (i < n) {
                CoverPoint memory cur = _cover[i];
                if (cur.pos != p.pos || cur.count != p.count) _cover[i] = p;
            } else {
                _cover.push(p);
            }
        }
        for (; n > st.n; --n) {
            _cover.pop();
        }
        // Canonical form: the count of the first breakpoint is not 0 and the count of the last breakpoint is 0,
        // so the frozen serials lie exactly between these two breakpoints.
        if (st.n == 0) SerialBounds.setPart(SerialBounds.FREEZE, 0, 0, 0);
        else SerialBounds.setPart(SerialBounds.FREEZE, st.pos[0], st.pos[st.n - 1], st.n);
    }

    /// @dev The last breakpoint with pos <= x.
    function _coverFind(uint256 x) private view returns (bool found, uint256 index) {
        uint256 lo;
        uint256 hi = _cover.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) >> 1;
            if (_cover[mid].pos <= x) lo = mid + 1;
            else hi = mid;
        }
        if (lo == 0) return (false, 0);
        return (true, lo - 1);
    }

    /// @dev The slice that contains x: [segStart, segEnd) and its cover count.
    function _coverSeg(uint256 x) private view returns (uint256 segStart, uint256 segEnd, uint256 count) {
        uint256 n = _cover.length;
        (bool found, uint256 i) = _coverFind(x);
        if (!found) return (0, n == 0 ? type(uint256).max : _cover[0].pos, 0);
        CoverPoint memory p = _cover[i];
        return (p.pos, i + 1 < n ? _cover[i + 1].pos : type(uint256).max, p.count);
    }
}

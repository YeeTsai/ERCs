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
///
///      The rebuilding, the events and the heavy queries are in the library SerialFreezeOps at the end of this
///      file, which is deployed separately and linked by the token, so its code does not count toward the token's
///      size; freezing, unfreezing, registering a reason, the forced operations and these queries each cost one
///      more DELEGATECALL. The code that reads the cover count during transfers stays in this contract and does
///      not call the library.
///      freezeReasonsOf, freezeReasonInfo and frozenSpanAt only call the library functions whose names end in
///      Raw: the library ABI-encodes the result according to the return types these functions declare and
///      returns it itself with RETURN; the token then uses inline assembly to return this return data unchanged
///      as its own (RETURNDATACOPY, RETURN), without decoding and re-encoding it, so the encoding code does not
///      count toward the token's size either. This is written as inline assembly rather than as a shared internal
///      function because the compiler cannot tell that the internal function does not return, and would keep
///      return-value encoding that is never used. RETURN ends the whole call, so these three functions are
///      external (they cannot be called from inside the contract), and a child contract that overrides them
///      cannot call super either.
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
    ///      lie between two frozen slices, the span returned is a slice of the cover count step function and is not
    ///      broken by the destroyed serials in between.
    ///      The query and the encoding of the return value are in the linked library SerialFreezeOps
    ///      (frozenSpanAtRaw); the token returns the library's return data unchanged (see the notes at the top of this
    ///      contract).
    function frozenSpanAt(uint256 serial) external view virtual returns (bool, uint256) {
        SerialFreezeOps.frozenSpanAtRaw(_cover, serial, serialsIssued());
        assembly ("memory-safe") {
            let p := mload(0x40)
            returndatacopy(p, 0, returndatasize())
            return(p, returndatasize())
        }
    }

    /// @dev The counting is in the linked library SerialFreezeOps; when no serial is frozen, the holding is not read
    ///      and the library is not called.
    function frozenBalanceOf(address account) public view virtual returns (uint256) {
        if (_cover.length == 0) return 0;
        (uint256[] memory starts, uint256[] memory lens) = _heldRanges(account);
        return SerialFreezeOps.frozenIn(_cover, starts, lens);
    }

    /// @dev Cost = number of reasons whose set of frozen slices is not empty x number of slices of the account
    ///      x log(number of slices of that reason).
    ///      The counting and the encoding of the return value are in the linked library SerialFreezeOps
    ///      (reasonsInRaw); the token returns the library's return data unchanged (see the notes at the top of this
    ///      contract). When no reason has a non-empty set of frozen slices, the holding is not read and the library
    ///      is not called; the encoding of two empty arrays is returned directly.
    function freezeReasonsOf(address account) external view virtual returns (bytes32[] memory, uint256[] memory) {
        if (_activeReasons.length == 0) {
            // ABI encoding of two empty arrays (bytes32[], uint256[]): the offsets 0x40 and 0x60 and two lengths of 0.
            assembly ("memory-safe") {
                let p := mload(0x40)
                mstore(p, 0x40)
                mstore(add(p, 0x20), 0x60)
                mstore(add(p, 0x40), 0)
                mstore(add(p, 0x60), 0)
                return(p, 0x80)
            }
        }
        (uint256[] memory starts, uint256[] memory lens) = _heldRanges(account);
        SerialFreezeOps.reasonsInRaw(_activeReasons, _reasonRanges, starts, lens);
        assembly ("memory-safe") {
            let p := mload(0x40)
            returndatacopy(p, 0, returndatasize())
            return(p, returndatasize())
        }
    }

    /// @dev The reading and the encoding are in the linked library SerialFreezeOps (reasonInfoRaw); the token returns
    ///      the library's return data unchanged (see the notes at the top of this contract).
    function freezeReasonInfo(bytes32 reason) external view virtual returns (string memory, string memory) {
        SerialFreezeOps.reasonInfoRaw(_reasonInfo, reason);
        assembly ("memory-safe") {
            let p := mload(0x40)
            returndatacopy(p, 0, returndatasize())
            return(p, returndatasize())
        }
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
        SerialFreezeOps.setReasonInfo(_reasonInfo, reason, name_, uri);
    }

    /// @dev Freezes [start, start + amount) and propagates the freeze to the successors of every generation of these
    ///      serials (clauses 2 and 4 of "Freezing and consolidation" in the draft). The successors are given by the
    ///      core hook _successorPieces and are empty when consolidation is closed. The reason's set of slices and
    ///      the cover count are each rebuilt once, however many slices the freeze propagates to. Emits SliceFrozen
    ///      for the slice named in the call first, then one SliceFrozen for each slice of successors, in ascending
    ///      order of serial.
    ///      The checks stay here; the rebuild and the events are in the linked library SerialFreezeOps (see the end of
    ///      this file).
    function _freeze(uint256 start, uint256 amount, bytes32 reason) internal virtual {
        _setFrozen(start, amount, reason, true);
    }

    /// @dev Propagates the unfreeze in the same way as _freeze (clause 3 of "Freezing and consolidation" in the
    ///      draft); the event is SliceUnfrozen.
    function _unfreeze(uint256 start, uint256 amount, bytes32 reason) internal virtual {
        _setFrozen(start, amount, reason, false);
    }

    /// @dev The common path of _freeze (add true) and _unfreeze: checks the range, and for a freeze also requires the
    ///      reason to have a registered name; obtains the successors, then lets the library rebuild and emit the
    ///      events. The two share one library call so that it takes less of the token's size.
    function _setFrozen(uint256 start, uint256 amount, bytes32 reason, bool add) private {
        uint256 end = _checkedRange(start, amount);
        if (add && bytes(_reasonInfo[reason].name).length == 0) revert ERCXXXXInvalidReason(reason);
        (uint256[] memory ss, uint256[] memory se) = _successorPieces(start, end);
        SerialFreezeOps.setFrozen(
            _reasonRanges[reason], _activeReasons, _activeSlot, _cover, reason, start, end, ss, se, add
        );
    }

    function _forcedTransfer(address from, address to, uint256 start, uint256 amount) internal virtual {
        if (to == address(0) || to == from) revert ERC20InvalidReceiver(to);
        _forcedMove(from, to, start, amount, false, 0, 0);
    }

    function _destroy(address from, uint256 start, uint256 amount) internal virtual {
        _forcedMove(from, address(0), start, amount, false, 0, 0);
    }

    /// @dev The checks and events are the same as for _forcedTransfer; locating uses the position hint instead.
    function _forcedTransferAt(address from, address to, uint256 start, uint256 amount, bytes32 pile, uint256 index)
        internal
        virtual
    {
        if (to == address(0) || to == from) revert ERC20InvalidReceiver(to);
        _forcedMove(from, to, start, amount, true, pile, index);
    }

    function _destroyAt(address from, uint256 start, uint256 amount, bytes32 pile, uint256 index) internal virtual {
        _forcedMove(from, address(0), start, amount, true, pile, index);
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
        SerialFreezeOps.requireFrozen(_cover, start, amount);
    }

    /// @dev The second half shared by the four forced operations: checks the freeze, moves the serials, and emits
    ///      SliceForciblyTransferred. With hinted true it locates by the position hint (pile, index) (_moveRangeAt);
    ///      otherwise it searches the holding (_moveRange).
    function _forcedMove(
        address from,
        address to,
        uint256 start,
        uint256 amount,
        bool hinted,
        bytes32 pile,
        uint256 index
    ) private {
        _requireFrozen(start, amount);
        if (hinted) _moveRangeAt(from, to, start, amount, pile, index);
        else _moveRange(from, to, start, amount);
        emit SliceForciblyTransferred(from, to, start, amount);
    }

    // ───────────────────────── Private: cover count ─────────────────────────

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

/// @title SerialFreezeOps: storage rebuilds and heavy queries of the freezing extension (a library deployed
///        separately and linked by the token)
/// @notice On a freeze or an unfreeze, rebuilds the set of slices of one reason, the register of "reasons whose set
///         of frozen slices is not empty" and the cover count step function, and emits SliceFrozen /
///         SliceUnfrozen; writes reason descriptions; and does the work behind freezeReasonsOf, freezeReasonInfo,
///         frozenSpanAt and frozenBalanceOf and the "all frozen" check of the forced operations (which reverts in
///         the library when it fails).
///         Callers: setFrozen <- ERCXXXXFreezable._setFrozen (_freeze, _unfreeze); setReasonInfo <- _setReasonInfo;
///         reasonsInRaw <- freezeReasonsOf; reasonInfoRaw <- freezeReasonInfo; frozenSpanAtRaw <- frozenSpanAt;
///         frozenIn <- frozenBalanceOf; requireFrozen <- _requireFrozen (the four forced operations).
///         The functions are external: the token calls them with DELEGATECALL, so they read and write the token's
///         own storage (the storage references among the parameters), and the events are emitted from the token's
///         address too. The library has no state and does not call the token's functions, so one deployment can be
///         shared by all tokens.
///         The transfer path does not call it: transfers read the cover count only through _segmentAt, and that
///         part stays in the token.
/// @dev The code is moved out of the token so that a token with the freezing extension stays below the runtime
///      code limit of EIP-170 (24,576 bytes). The price is one more DELEGATECALL for each of the operations above
///      (to a cold address) and the encoding of the arguments and storage references. The checks of authorization,
///      range and reason name stay in ERCXXXXFreezable; the "all frozen" comparison of the forced operations and
///      ERCXXXXNotFrozen are in requireFrozen.
///      Freezing and unfreezing share one entry point, setFrozen (told apart by add), so the token has only one
///      call site; the other functions take the token's state variables as storage reference parameters. The
///      register is updated from the length of the set of slices after the set is rewritten.
///      The bounding slice shared with the classification extension (SerialBounds) is updated after the cover
///      count is rebuilt: it is at a fixed storage slot, and the library writes it directly, in the token's
///      storage.
library SerialFreezeOps {
    /// @dev Freeze (add true): merges [start, end) and its successors [ss[i], se[i]) into the frozen slices rs of
    ///      the reason, updates the register, adds one to the cover count cover on the parts that were not yet frozen
    ///      for the reason, and updates the bounding slice. Without successors the single-slice version is used.
    ///      Then emits SliceFrozen for [start, end), followed by one for each slice of successors in ascending order
    ///      of serial (the events are emitted from the token's address).
    ///      Unfreeze (add false): removes these slices from rs in the same way and subtracts one from cover on the
    ///      parts actually removed; the event is SliceUnfrozen.
    function setFrozen(
        ERCXXXXFreezable.Range[] storage rs,
        bytes32[] storage activeReasons,
        mapping(bytes32 => uint256) storage activeSlot,
        ERCXXXXFreezable.CoverPoint[] storage cover,
        bytes32 reason,
        uint256 start,
        uint256 end,
        uint256[] memory ss,
        uint256[] memory se,
        bool add
    ) external {
        SerialSteps.Pieces memory p;
        if (ss.length == 0) p = add ? _union(rs, start, end) : _diff(rs, start, end);
        else if (add) p = _unionPieces(rs, _withSuccessors(start, end, ss, se));
        else p = _diffPieces(rs, _withSuccessors(start, end, ss, se));
        _syncReason(activeReasons, activeSlot, reason, rs.length);
        if (p.m != 0) _coverApply(cover, p, add ? SerialSteps.ADD : SerialSteps.SUB);
        if (add) {
            emit IERCXXXXFreezable.SliceFrozen(reason, start, end - start);
            for (uint256 i; i < ss.length; ++i) {
                emit IERCXXXXFreezable.SliceFrozen(reason, ss[i], se[i] - ss[i]);
            }
        } else {
            emit IERCXXXXFreezable.SliceUnfrozen(reason, start, end - start);
            for (uint256 i; i < ss.length; ++i) {
                emit IERCXXXXFreezable.SliceUnfrozen(reason, ss[i], se[i] - ss[i]);
            }
        }
    }

    /// @dev Writes the name and the description document of reason (the name has already been checked to be
    ///      non-empty).
    function setReasonInfo(
        mapping(bytes32 => ERCXXXXFreezable.ReasonInfo) storage infos,
        bytes32 reason,
        string memory name_,
        string memory uri
    ) external {
        infos[reason] = ERCXXXXFreezable.ReasonInfo(name_, uri);
    }

    // ───────────────────────── Queries (freezeReasonsOf, freezeReasonInfo, frozenSpanAt) ─────────────────────────
    // The functions whose names end in Raw declare no return values: they encode the result according to the return
    // types of the token's query function and return it directly with RETURN, and the token passes it on unchanged
    // (see the notes at the top of ERCXXXXFreezable), without decoding and re-encoding it.

    /// @dev The return data of freezeReasonsOf(account), (bytes32[] reasons, uint256[] amounts); see reasonsIn.
    function reasonsInRaw(
        bytes32[] storage activeReasons,
        mapping(bytes32 => ERCXXXXFreezable.Range[]) storage reasonRanges,
        uint256[] memory starts,
        uint256[] memory lens
    ) external view {
        (bytes32[] memory reasons, uint256[] memory amounts) = reasonsIn(activeReasons, reasonRanges, starts, lens);
        _rawReturn(abi.encode(reasons, amounts));
    }

    /// @dev The return data of freezeReasonInfo(reason), (string name, string uri).
    function reasonInfoRaw(mapping(bytes32 => ERCXXXXFreezable.ReasonInfo) storage infos, bytes32 reason)
        external
        view
    {
        ERCXXXXFreezable.ReasonInfo storage d = infos[reason];
        _rawReturn(abi.encode(d.name, d.uri));
    }

    /// @dev Ends execution with data as the return data.
    function _rawReturn(bytes memory data) private pure {
        assembly ("memory-safe") {
            return(add(data, 0x20), mload(data))
        }
    }

    /// @dev The counting for freezeReasonsOf: the number of serials in the holding (starts[i], lens[i]) frozen for
    ///      each reason, listing only the reasons with a non-zero number.
    function reasonsIn(
        bytes32[] storage activeReasons,
        mapping(bytes32 => ERCXXXXFreezable.Range[]) storage reasonRanges,
        uint256[] memory starts,
        uint256[] memory lens
    ) private view returns (bytes32[] memory reasons, uint256[] memory amounts) {
        uint256 rn = activeReasons.length;
        reasons = new bytes32[](rn);
        amounts = new uint256[](rn);
        uint256 k;
        for (uint256 r; r < rn; ++r) {
            bytes32 reason = activeReasons[r];
            ERCXXXXFreezable.Range[] storage rs = reasonRanges[reason];
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
        // contract is memory-safe.
        assembly ("memory-safe") {
            mstore(reasons, k)
            mstore(amounts, k)
        }
    }

    /// @dev The return data of frozenSpanAt(serial), (bool frozen, uint256 length); see _frozenSpanAt.
    function frozenSpanAtRaw(ERCXXXXFreezable.CoverPoint[] storage cover, uint256 serial, uint256 issued)
        external
        view
    {
        (bool frozen, uint256 length) = _frozenSpanAt(cover, serial, issued);
        _rawReturn(abi.encode(frozen, length));
    }

    /// @dev The result of frozenSpanAt; issued is serialsIssued(). Reads the same step function as the cover count
    ///      lookup that the token uses for transfers.
    function _frozenSpanAt(ERCXXXXFreezable.CoverPoint[] storage cover, uint256 serial, uint256 issued)
        private
        view
        returns (bool frozen, uint256 length)
    {
        if (serial >= issued) return (false, 0);
        uint256 n = cover.length;
        (bool found, uint256 i) = _coverFind(cover, serial);
        frozen = found && cover[i].count != 0;
        uint256 j = found ? i + 1 : 0;
        while (j < n && (cover[j].count != 0) == frozen) {
            ++j;
        }
        uint256 end = j < n ? cover[j].pos : type(uint256).max;
        if (end > issued) end = issued;
        length = end - serial;
    }

    /// @dev The counting for frozenBalanceOf: the number of frozen serials in the holding (starts[i], lens[i]).
    function frozenIn(ERCXXXXFreezable.CoverPoint[] storage cover, uint256[] memory starts, uint256[] memory lens)
        external
        view
        returns (uint256 total)
    {
        for (uint256 i; i < starts.length; ++i) {
            total += _frozenAmountIn(cover, starts[i], starts[i] + lens[i]);
        }
    }

    /// @dev The check of the forced operations: reverts with ERCXXXXNotFrozen(start, amount) when
    ///      [start, start + amount) is not entirely frozen. The token checks the issued range first.
    function requireFrozen(ERCXXXXFreezable.CoverPoint[] storage cover, uint256 start, uint256 amount)
        external
        view
    {
        if (_frozenAmountIn(cover, start, start + amount) != amount) {
            revert ERCXXXXFreezable.ERCXXXXNotFrozen(start, amount);
        }
    }

    function _frozenAmountIn(ERCXXXXFreezable.CoverPoint[] storage cover, uint256 s, uint256 e)
        private
        view
        returns (uint256 total)
    {
        uint256 n = cover.length;
        if (n == 0) return 0;
        (bool found, uint256 i) = _coverFind(cover, s);
        uint256 cnt = found ? cover[i].count : 0;
        uint256 next = found ? i + 1 : 0;
        uint256 x = s;
        while (x < e) {
            uint256 nb = next < n ? cover[next].pos : type(uint256).max;
            uint256 segEnd = nb < e ? nb : e;
            if (cnt != 0) total += segEnd - x;
            x = segEnd;
            if (x < e) {
                cnt = cover[next].count;
                ++next;
            }
        }
    }

    /// @dev The number of serials in the sorted set of slices rs that lie in [s, e).
    function _rangesLen(ERCXXXXFreezable.Range[] storage rs, uint256 s, uint256 e)
        private
        view
        returns (uint256 total)
    {
        uint256 lo;
        uint256 hi = rs.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) >> 1;
            if (rs[mid].end <= s) lo = mid + 1;
            else hi = mid;
        }
        for (uint256 i = lo; i < rs.length; ++i) {
            ERCXXXXFreezable.Range memory r = rs[i];
            if (r.start >= e) break;
            uint256 a = r.start > s ? r.start : s;
            uint256 b = r.end < e ? r.end : e;
            total += b - a;
        }
    }

    /// @dev The last breakpoint with pos <= x; the same as ERCXXXXFreezable._coverFind (that copy is on the transfer
    ///      path and stays in the token).
    function _coverFind(ERCXXXXFreezable.CoverPoint[] storage cover, uint256 x)
        private
        view
        returns (bool found, uint256 index)
    {
        uint256 lo;
        uint256 hi = cover.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) >> 1;
            if (cover[mid].pos <= x) lo = mid + 1;
            else hi = mid;
        }
        if (lo == 0) return (false, 0);
        return (true, lo - 1);
    }

    // ───────────────────────── Sets of slices ─────────────────────────

    /// @dev Adds [a, b) to rs and returns the part of it that was not in rs before.
    function _union(ERCXXXXFreezable.Range[] storage rs, uint256 a, uint256 b)
        private
        returns (SerialSteps.Pieces memory gaps)
    {
        uint256 n = rs.length;
        ERCXXXXFreezable.Range[] memory out = new ERCXXXXFreezable.Range[](n + 1);
        gaps = SerialSteps.newPieces(n + 1);
        uint256 k;
        uint256 s = a;
        uint256 e = b;
        uint256 cursor = a;
        bool placed;
        for (uint256 i; i < n; ++i) {
            ERCXXXXFreezable.Range memory r = rs[i];
            if (r.start < b && r.end > a) {
                if (r.start > cursor) SerialSteps.addPiece(gaps, cursor, r.start);
                if (r.end > cursor) cursor = r.end;
            }
            if (r.end < s) {
                out[k++] = r;
            } else if (r.start > e) {
                if (!placed) {
                    out[k++] = ERCXXXXFreezable.Range(uint128(s), uint128(e));
                    placed = true;
                }
                out[k++] = r;
            } else {
                if (r.start < s) s = r.start;
                if (r.end > e) e = r.end;
            }
        }
        if (cursor < b) SerialSteps.addPiece(gaps, cursor, b);
        if (!placed) out[k++] = ERCXXXXFreezable.Range(uint128(s), uint128(e));
        _writeRanges(rs, out, k);
    }

    /// @dev Removes [a, b) from rs and returns the part actually removed.
    function _diff(ERCXXXXFreezable.Range[] storage rs, uint256 a, uint256 b)
        private
        returns (SerialSteps.Pieces memory cut)
    {
        uint256 n = rs.length;
        ERCXXXXFreezable.Range[] memory out = new ERCXXXXFreezable.Range[](n + 1);
        cut = SerialSteps.newPieces(n);
        uint256 k;
        for (uint256 i; i < n; ++i) {
            ERCXXXXFreezable.Range memory r = rs[i];
            if (r.end <= a || r.start >= b) {
                out[k++] = r;
                continue;
            }
            SerialSteps.addPiece(cut, r.start > a ? r.start : a, r.end < b ? r.end : b);
            if (r.start < a) out[k++] = ERCXXXXFreezable.Range(r.start, uint128(a));
            if (r.end > b) out[k++] = ERCXXXXFreezable.Range(uint128(b), r.end);
        }
        _writeRanges(rs, out, k);
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

    /// @dev The same as _union, but adds several slices at once: the slices of pc are in ascending order and
    ///      pairwise disjoint, and may be adjacent.
    ///      Used only when propagating to successors; without successors the single-slice version above is used, at
    ///      the same cost as when consolidation is closed.
    function _unionPieces(ERCXXXXFreezable.Range[] storage rs, SerialSteps.Pieces memory pc)
        private
        returns (SerialSteps.Pieces memory gaps)
    {
        ERCXXXXFreezable.Range[] memory cur = _loadRanges(rs);
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
        ERCXXXXFreezable.Range[] memory out = new ERCXXXXFreezable.Range[](n + pc.m);
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
                out[k++] = ERCXXXXFreezable.Range(uint128(s), uint128(e));
            }
        }
        _writeRanges(rs, out, k);
    }

    /// @dev The same as _diff, but removes several slices at once (with the same requirements as above).
    function _diffPieces(ERCXXXXFreezable.Range[] storage rs, SerialSteps.Pieces memory pc)
        private
        returns (SerialSteps.Pieces memory cut)
    {
        ERCXXXXFreezable.Range[] memory cur = _loadRanges(rs);
        uint256 n = cur.length;
        ERCXXXXFreezable.Range[] memory out = new ERCXXXXFreezable.Range[](n + pc.m);
        cut = SerialSteps.newPieces(n + pc.m);
        uint256 k;
        uint256 j;
        for (uint256 i; i < n; ++i) {
            ERCXXXXFreezable.Range memory r = cur[i];
            uint256 x = r.start;
            while (j < pc.m && pc.e[j] <= r.start) ++j;
            for (uint256 t = j; t < pc.m && pc.s[t] < r.end; ++t) {
                uint256 cs = pc.s[t] > r.start ? pc.s[t] : r.start;
                uint256 ce = pc.e[t] < r.end ? pc.e[t] : r.end;
                SerialSteps.addPiece(cut, cs, ce);
                if (cs > x) out[k++] = ERCXXXXFreezable.Range(uint128(x), uint128(cs));
                x = ce;
            }
            if (x < r.end) out[k++] = ERCXXXXFreezable.Range(uint128(x), r.end);
        }
        _writeRanges(rs, out, k);
    }

    function _loadRanges(ERCXXXXFreezable.Range[] storage rs)
        private
        view
        returns (ERCXXXXFreezable.Range[] memory cur)
    {
        uint256 n = rs.length;
        cur = new ERCXXXXFreezable.Range[](n);
        for (uint256 i; i < n; ++i) {
            cur[i] = rs[i];
        }
    }

    function _writeRanges(ERCXXXXFreezable.Range[] storage rs, ERCXXXXFreezable.Range[] memory out, uint256 k)
        private
    {
        uint256 n = rs.length;
        for (uint256 i; i < k; ++i) {
            if (i < n) {
                ERCXXXXFreezable.Range memory cur = rs[i];
                if (cur.start != out[i].start || cur.end != out[i].end) rs[i] = out[i];
            } else {
                rs.push(out[i]);
            }
        }
        for (; n > k; --n) {
            rs.pop();
        }
    }

    /// @dev Maintains the register of "reasons whose set of frozen slices is not empty" (activeSlot stores the
    ///      index + 1).
    function _syncReason(
        bytes32[] storage activeReasons,
        mapping(bytes32 => uint256) storage activeSlot,
        bytes32 reason,
        uint256 rangeCount
    ) private {
        uint256 slot = activeSlot[reason];
        if (rangeCount != 0 && slot == 0) {
            activeReasons.push(reason);
            activeSlot[reason] = activeReasons.length;
        } else if (rangeCount == 0 && slot != 0) {
            uint256 last = activeReasons.length;
            if (slot != last) {
                bytes32 moved = activeReasons[last - 1];
                activeReasons[slot - 1] = moved;
                activeSlot[moved] = slot;
            }
            activeReasons.pop();
            delete activeSlot[reason];
        }
    }

    // ───────────────────────── Cover count ─────────────────────────

    function _coverApply(ERCXXXXFreezable.CoverPoint[] storage cover, SerialSteps.Pieces memory pc, uint8 mode)
        private
    {
        uint256 n = cover.length;
        SerialSteps.Steps memory old = SerialSteps.newSteps(n);
        for (uint256 i; i < n; ++i) {
            ERCXXXXFreezable.CoverPoint memory p = cover[i];
            SerialSteps.push(old, p.pos, p.count);
        }
        SerialSteps.Steps memory st = SerialSteps.rebuild(old, pc, mode, 0);
        for (uint256 i; i < st.n; ++i) {
            ERCXXXXFreezable.CoverPoint memory p =
                ERCXXXXFreezable.CoverPoint(uint128(st.pos[i]), uint128(st.val[i]));
            if (i < n) {
                ERCXXXXFreezable.CoverPoint memory cur = cover[i];
                if (cur.pos != p.pos || cur.count != p.count) cover[i] = p;
            } else {
                cover.push(p);
            }
        }
        for (; n > st.n; --n) {
            cover.pop();
        }
        // Canonical form: the count of the first breakpoint is not 0 and the count of the last breakpoint is 0,
        // so the frozen serials lie exactly between these two breakpoints.
        // The slot of SerialBounds is fixed, so through DELEGATECALL the write goes to the token's own storage.
        if (st.n == 0) SerialBounds.setPart(SerialBounds.FREEZE, 0, 0, 0);
        else SerialBounds.setPart(SerialBounds.FREEZE, st.pos[0], st.pos[st.n - 1], st.n);
    }
}

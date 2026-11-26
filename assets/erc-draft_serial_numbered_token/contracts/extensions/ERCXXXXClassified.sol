// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {ERCXXXX} from "../ERCXXXX.sol";
import {IERCXXXXClassified} from "../spec/IERCXXXXClassified.sol";
import {SerialSteps} from "../utils/SerialSteps.sol";
import {SerialBounds} from "../utils/SerialBounds.sol";

/// @title ERCXXXXClassified: reference implementation of the classification extension
/// @notice Sets classes on serials, and makes transfers obey the flow rules of the classes.
///         This contract only records and describes classes and carries no flow rule: unless a child contract
///         overrides _classAllows, every class allows every destination.
///         Which classes exist and who can set classes is decided by the token (clause 2 of "Classes" in the
///         draft).
///
/// @dev Storage (implementation details):
///      - A global step function records the class of each slice of serials; serials before the first breakpoint
///        have the default class.
///      - Classes are recorded on serials, independently of holders, so destroyed serials keep their original
///        class.
///      - Issuance with a non-zero class changes only the end of the step function, at a constant cost.
///      - The bounding slice shared with the freezing extension (SerialBounds, at a fixed storage slot): all
///        serials of non-default classes lie within it, and it also records whether there is any non-default
///        class and whether the step function consists of a single slice. A transfer reads it first; when there
///        is no non-default class, or the serial lies outside the bounding slice, the step function is not read;
///        when only classes exist and there is a single slice, only the class of that slice is read inside the
///        bounding slice. It is updated after a class is set and after an issuance with a class (2 more slots read
///        and written, plus 1 more slot read when the freezing extension also has restrictions).
///
///      A choice of this implementation: a class has to be defined with _defineClass (with a non-empty name)
///      before it can be used, so a class in use always has a name (clause 3 of "Description" in the draft).
///
///      Known limitation: every _setClass rewrites the whole step function, at a cost that grows linearly with its
///      number of breakpoints.
abstract contract ERCXXXXClassified is ERCXXXX, IERCXXXXClassified {
    /// @dev A breakpoint of the class step function; it takes two storage slots.
    struct ClassPoint {
        uint128 pos;
        bytes32 classId;
    }

    struct ClassInfo {
        bool defined;
        string name;
        string uri;
    }

    /// @notice The class is not defined, or its definition is invalid: the class is zero or equals an internally
    ///         reserved key, or the name is empty.
    error ERCXXXXInvalidClass(bytes32 classId);

    ClassPoint[] private _classPoints;
    mapping(bytes32 classId => ClassInfo) private _classInfo;

    // ───────────────────────── ERC-165 ─────────────────────────

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IERCXXXXClassified).interfaceId || super.supportsInterface(interfaceId);
    }

    // ───────────────────────── IERCXXXXClassified ─────────────────────────

    function classRunAt(uint256 serial) public view virtual returns (bytes32 classId, uint256 length) {
        uint256 issued = serialsIssued();
        if (serial >= issued) return (bytes32(0), 0);
        (, uint256 segEnd, bytes32 c) = _classSeg(serial);
        return (c, (segEnd < issued ? segEnd : issued) - serial);
    }

    function classAllows(bytes32 classId, address from, address to) public view virtual returns (bool) {
        return _classAllows(classId, from, to);
    }

    function classesOf(address account)
        public
        view
        virtual
        returns (bytes32[] memory classIds, uint256[] memory amounts)
    {
        // There are at most as many distinct classes as breakpoints of the step function, plus 1 (the default
        // class).
        uint256 cap = _classPoints.length + 1;
        classIds = new bytes32[](cap);
        amounts = new uint256[](cap);
        uint256 k;
        (uint256[] memory starts, uint256[] memory lens) = _heldRanges(account);
        for (uint256 i; i < starts.length; ++i) {
            uint256 x = starts[i];
            uint256 e = x + lens[i];
            while (x < e) {
                (, uint256 segEnd, bytes32 c) = _classSeg(x);
                uint256 hi = segEnd < e ? segEnd : e;
                uint256 j;
                while (j < k && classIds[j] != c) {
                    ++j;
                }
                if (j == k) {
                    classIds[k] = c;
                    ++k;
                }
                amounts[j] += hi - x;
                x = hi;
            }
        }
        // Shrinks the array lengths in place (k is not greater than the original length); this writes only memory
        // that the arrays have already allocated, so it is marked memory-safe.
        // via-IR can move variables that do not fit on the stack into memory only if all inline assembly in the
        // contract is memory-safe; otherwise a contract that also has the freezing extension fails to compile.
        assembly ("memory-safe") {
            mstore(classIds, k)
            mstore(amounts, k)
        }
    }

    function classInfo(bytes32 classId) public view virtual returns (string memory name_, string memory uri) {
        ClassInfo storage d = _classInfo[classId];
        return (d.name, d.uri);
    }

    // ───────────────────────── Hook for flow rules ─────────────────────────

    /// @dev Whether the class classId allows a serial held by from to be transferred to the address to (to being
    ///      the zero address denotes a burn).
    ///      Class zero always allows (clause 2 of "Flow rules" in the draft). A child contract overrides it to add
    ///      flow rules, and an override still has to return true for class zero.
    ///      Must not revert (clause 3 of "Flow rules" in the draft).
    function _classAllows(bytes32 classId, address from, address to) internal view virtual returns (bool) {
        classId;
        from;
        to;
        return true;
    }

    // ───────────────────────── Internal operations ─────────────────────────

    /// @dev Defines or modifies the description of a non-zero class.
    function _defineClass(bytes32 classId, string memory name_, string memory uri) internal virtual {
        if (classId == bytes32(0) || classId == _FROZEN_PILE || bytes(name_).length == 0) {
            revert ERCXXXXInvalidClass(classId);
        }
        _classInfo[classId] = ClassInfo(true, name_, uri);
    }

    function _isClassDefined(bytes32 classId) internal view returns (bool) {
        return _classInfo[classId].defined;
    }

    /// @dev Sets the class of [start, start + amount) to classId (zero means the default class). Rebuilds the whole
    ///      step function.
    function _setClass(uint256 start, uint256 amount, bytes32 classId) internal virtual {
        uint256 end = _checkedRange(start, amount);
        if (classId != bytes32(0) && !_classInfo[classId].defined) revert ERCXXXXInvalidClass(classId);
        uint256 n = _classPoints.length;
        SerialSteps.Steps memory old = SerialSteps.newSteps(n);
        for (uint256 i; i < n; ++i) {
            ClassPoint memory p = _classPoints[i];
            SerialSteps.push(old, p.pos, uint256(p.classId));
        }
        SerialSteps.Steps memory st =
            SerialSteps.rebuild(old, SerialSteps.onePiece(start, end), SerialSteps.SET, uint256(classId));
        for (uint256 i; i < st.n; ++i) {
            ClassPoint memory p = ClassPoint(uint128(st.pos[i]), bytes32(st.val[i]));
            if (i < n) {
                ClassPoint memory cur = _classPoints[i];
                if (cur.pos != p.pos || cur.classId != p.classId) _classPoints[i] = p;
            } else {
                _classPoints.push(p);
            }
        }
        for (; n > st.n; --n) {
            _classPoints.pop();
        }
        // Canonical form: the class of the first breakpoint is not 0 and the class of the last breakpoint is 0,
        // so the serials of non-default classes lie exactly between these two breakpoints.
        if (st.n == 0) SerialBounds.setPart(SerialBounds.CLASS, 0, 0, 0);
        else SerialBounds.setPart(SerialBounds.CLASS, st.pos[0], st.pos[st.n - 1], st.n);
        emit SliceClassified(start, amount, classId);
    }

    /// @dev Issues value units of the class classId to the address to and returns the first serial. The cost is
    ///      constant and does not grow with the number of existing class slices.
    function _mintWithClass(address to, uint256 value, bytes32 classId) internal virtual returns (uint256 start) {
        if (classId != bytes32(0) && !_classInfo[classId].defined) revert ERCXXXXInvalidClass(classId);
        // Put the units directly into the pile of this class (the pile of class 0 is the default pile).
        start = _issue(to, value, classId);
        if (value != 0 && classId != bytes32(0)) {
            _appendClass(start, start + value, classId);
            // The draft requires this event to come after the Transfer of the issuance.
            emit SliceClassified(start, value, classId);
        }
    }

    // ───────────────────────── Hooks of the core ─────────────────────────

    /// @dev Reads only the one slot of the bounding slice, the same slot that the freezing extension reads.
    function _hasRestrictions() internal view virtual override returns (bool) {
        return SerialBounds.any() || super._hasRestrictions();
    }

    /// @dev A serial of a non-zero class belongs to the pile keyed by its class. A serial that another extension has
    ///      already assigned to another pile (for example the frozen pile) stays there.
    ///      It first reads the slot of the bounding slice (SerialBounds), so in most cases the step function need
    ///      not be read:
    ///      - No non-default class: no narrowing.
    ///      - The serial lies outside the bounding slice [bl, bh): default class; the slice is narrowed to this side
    ///        of the bounding slice (as described for the freezing extension).
    ///      - Only classes exist, and the step function has exactly one slice (two breakpoints): the bounding slice
    ///        is that slice, and only its class is read.
    ///      In the other cases, the function does a binary search on the step function.
    function _segmentAt(uint256 serial) internal view virtual override returns (uint256 lo, uint256 hi, bytes32 pile) {
        (lo, hi, pile) = super._segmentAt(serial);
        (uint256 ks, uint256 ke, uint256 kind) = SerialBounds.probe(serial, SerialBounds.CLASS);
        if (kind == SerialBounds.NONE) return (lo, hi, pile);
        bytes32 c;
        if (kind == SerialBounds.SINGLE) c = _firstClass();
        else if (kind == SerialBounds.LOOKUP) (ks, ke, c) = _classSeg(serial);
        if (ks > lo) lo = ks;
        if (ke < hi) hi = ke;
        if (pile == _DEFAULT_PILE) pile = c;
    }

    function _pileUsable(bytes32 pile, address from, address to) internal view virtual override returns (bool) {
        return super._pileUsable(pile, from, to) || (pile != _FROZEN_PILE && _classAllows(pile, from, to));
    }

    /// @dev After a consolidation, the new serials keep the class of the old serials
    ///      (clause 2 of "Classes and consolidation" in the draft). Consolidation does not accept frozen serials, so
    ///      pile is the class of the old serials (the pile of the default class is 0). The new serials are at the
    ///      end of the issued serials, so only the end of the step function changes, at a constant cost.
    ///      SliceClassified is emitted after all the SliceConsolidated events.
    function _afterConsolidation(uint256 newStart, uint256 amount, bytes32 pile) internal virtual override {
        super._afterConsolidation(newStart, amount, pile);
        if (pile != _DEFAULT_PILE && pile != _FROZEN_PILE) {
            _appendClass(newStart, newStart + amount, pile);
            emit SliceClassified(newStart, amount, pile);
        }
    }

    // ───────────────────────── Private ─────────────────────────

    /// @dev Newly issued serials always come after the existing serials, so only the end needs to change; the
    ///      bounding slice becomes [first breakpoint, end).
    function _appendClass(uint256 start, uint256 end, bytes32 classId) private {
        uint256 n = _classPoints.length;
        uint256 first = n == 0 ? start : _classPoints[0].pos;
        if (n != 0 && _classPoints[n - 1].pos == start) {
            // The last breakpoint is (start, 0).
            if (n >= 2 && _classPoints[n - 2].classId == classId) {
                _classPoints[n - 1].pos = uint128(end);
            } else {
                _classPoints[n - 1].classId = classId;
                _classPoints.push(ClassPoint(uint128(end), bytes32(0)));
                ++n;
            }
        } else {
            _classPoints.push(ClassPoint(uint128(start), classId));
            _classPoints.push(ClassPoint(uint128(end), bytes32(0)));
            n += 2;
        }
        SerialBounds.setPart(SerialBounds.CLASS, first, end, n);
    }

    /// @dev The class of the first breakpoint. The caller guarantees that the step function is not empty; the slot
    ///      is computed directly, without reading the array length.
    function _firstClass() private view returns (bytes32 classId) {
        ClassPoint[] storage pts = _classPoints;
        assembly ("memory-safe") {
            mstore(0, pts.slot)
            // Breakpoint 0 takes the two slots starting at keccak256(pts.slot); the class is in the second slot.
            classId := sload(add(keccak256(0, 0x20), 1))
        }
    }

    function _classSeg(uint256 x) private view returns (uint256 segStart, uint256 segEnd, bytes32 classId) {
        uint256 n = _classPoints.length;
        uint256 lo;
        uint256 hi = n;
        while (lo < hi) {
            uint256 mid = (lo + hi) >> 1;
            if (_classPoints[mid].pos <= x) lo = mid + 1;
            else hi = mid;
        }
        if (lo == 0) return (0, n == 0 ? type(uint256).max : _classPoints[0].pos, bytes32(0));
        ClassPoint memory p = _classPoints[lo - 1];
        return (p.pos, lo < n ? _classPoints[lo].pos : type(uint256).max, p.classId);
    }
}

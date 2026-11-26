// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title SerialBounds
/// @notice The "bounding slice" shared by the freezing extension and the classification extension: the smallest
///         slice [lo, hi) that covers all frozen serials and all serials of non-default classes, and, for each of
///         the two extensions, whether it has any restriction and whether it has only one slice. A serial outside
///         this slice is neither frozen nor of a non-default class; a transfer establishes this by reading one
///         storage slot, without a binary search on a step function.
/// @dev Storage (implementation detail): kept in fixed slots (outside the contract's sequential storage layout).
///      Each of the two extensions uses this library on its own, so they need no common base contract, and the
///      token need not override any function for it.
///      - Slot _SLOT (the only one a transfer reads): the low 4 bits are the states of the two extensions (bits 0-1
///        freezing, bits 2-3 classes; 0 none, 1 exactly one slice, that is, the step function has only two points,
///        2 more than one slice), the next 126 bits are lo, and the top 126 bits are hi. All zero means that there
///        is no restriction at all. When lo or hi does not fit in 126 bits (serials of the order of 2^126), they are
///        no longer exact: lo is recorded as 0, and hi as all ones, meaning no upper bound. The slice only gets
///        wider, which is still correct, except that every serial inside it has to be looked up in the step
///        functions; when hi is all ones, the inference drawn from "only one slice" is not used either.
///      - Slot _SLOT + 1 + part: the exact bounding slice of each extension, (hi << 128) | lo, 0 when empty
///        (part 0 freezing, 1 classes). Serials are all less than the number issued (uint128, see _checkedRange in
///        the core and the checks at issuance), so lo and hi fit in 128 bits each. When the slice of one extension
///        shrinks (unfreezing, return to the default class), the combined slice has to be recomputed with the slice
///        of the other extension, so each extension keeps its own copy.
///      When only one extension has restrictions, the combined slice runs from the first point to the last point of
///      its step function; when that extension also has only one slice, every serial inside the combined slice lies
///      in that slice, and no lookup in the step function is needed.
///      Updated (setPart) on freezing, unfreezing, setting a class and issuance with a class: reads and writes its
///      own slot, reads and writes the combined slot, and also reads the other extension's slot when that
///      extension has restrictions; a value that does not change is not written.
library SerialBounds {
    uint256 internal constant FREEZE = 0;
    uint256 internal constant CLASS = 1;

    /// @dev Results of probe.
    // This extension has no restriction; nothing to narrow.
    uint256 internal constant NONE = 0;
    // The serial is outside the bounding slice; [lo, hi) is the part on this side of the bounding slice, and the
    // state is the default.
    uint256 internal constant OUTSIDE = 1;
    // Only this extension has restrictions, and they form only one slice; [lo, hi) is that slice.
    uint256 internal constant SINGLE = 2;
    // The step function has to be looked up.
    uint256 internal constant LOOKUP = 3;

    uint256 private constant _MASK = (1 << 126) - 1;

    bytes32 private constant _SLOT = keccak256("ERCXXXX.restriction.bounds");

    /// @dev Whether any freeze or any non-default class exists.
    function any() internal view returns (bool) {
        return _read(_SLOT) != 0;
    }

    /// @dev Whether extension part has to look up its step function at serial; see the four results above.
    function probe(uint256 serial, uint256 part) internal view returns (uint256 lo, uint256 hi, uint256 kind) {
        uint256 v = _read(_SLOT);
        unchecked {
            uint256 shift = 2 * part;
            if ((v >> shift) & 3 == 0) return (0, type(uint256).max, NONE);
            lo = (v >> 4) & _MASK;
            if (serial < lo) return (0, lo, OUTSIDE);
            hi = v >> 130;
            if (hi == _MASK) return (lo, type(uint256).max, LOOKUP);
            if (serial >= hi) return (hi, type(uint256).max, OUTSIDE);
            // The low 4 bits say exactly "this extension has only one slice, the other has none".
            return (lo, hi, v & 15 == 1 << shift ? SINGLE : LOOKUP);
        }
    }

    /// @dev Sets the bounding slice of extension part to [lo, hi) (lo == hi means none), where points is the
    ///      number of points of its step function, and recomputes the combined slice.
    function setPart(uint256 part, uint256 lo, uint256 hi, uint256 points) internal {
        uint256 v = lo < hi ? (hi << 128) | lo : 0;
        bytes32 ps = bytes32(uint256(_SLOT) + 1 + part);
        if (_read(ps) != v) _write(ps, v);
        uint256 old = _read(_SLOT);
        uint256 shift = 2 * part;
        // When the state of the other extension is 0, its slot is 0 as well and need not be read.
        uint256 other = (old >> (2 - shift)) & 3 == 0 ? 0 : _read(bytes32(uint256(_SLOT) + 2 - part));
        uint256 st = v == 0 ? 0 : points == 2 ? 1 : 2;
        uint256 states = (old & 15 & ~(3 << shift)) | (st << shift);
        // The smallest slice that bounds both slices, encoded as a 126-bit lo and a 126-bit hi.
        uint256 u;
        if (v != 0 || other != 0) {
            if (v == 0) v = other;
            if (other == 0) other = v;
            uint256 a = uint128(v) < uint128(other) ? uint128(v) : uint128(other);
            uint256 b = v >> 128 > other >> 128 ? v >> 128 : other >> 128;
            if (a > _MASK) a = 0;
            if (b > _MASK) b = _MASK;
            u = (b << 130) | (a << 4) | states;
        }
        if (old != u) _write(_SLOT, u);
    }

    function _read(bytes32 slot) private view returns (uint256 v) {
        assembly ("memory-safe") {
            v := sload(slot)
        }
    }

    function _write(bytes32 slot, uint256 v) private {
        assembly ("memory-safe") {
            sstore(slot, v)
        }
    }
}

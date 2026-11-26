// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title SerialSteps
/// @notice Rebuilds a step function "serial -> value" in memory. The freezing extension uses it to keep, for each
///         serial, the number of reasons for which it is frozen, and the classification extension uses it to keep
///         the class of each slice of serials.
/// @dev A step function is represented by a list of points: from pos[i] up to the next point it takes the value
///      val[i]; before the first point it takes 0.
///      Canonical form: two adjacent points have different values, the value of the first point is not 0, and the
///      value of the last point is 0.
///      The cost of a rebuild is linear in the number of points. This is a known limitation of the two extensions:
///      every freeze, unfreeze or setting of a class rewrites the whole list of points.
library SerialSteps {
    uint8 internal constant ADD = 0;
    uint8 internal constant SUB = 1;
    uint8 internal constant SET = 2;

    /// @dev A step function in memory; only the first n entries are used.
    struct Steps {
        uint256[] pos;
        uint256[] val;
        uint256 n;
    }

    /// @dev A set of slices [s[i], e[i]) in memory, in ascending order and pairwise disjoint; only the first m
    ///      entries are used.
    struct Pieces {
        uint256[] s;
        uint256[] e;
        uint256 m;
    }

    function newSteps(uint256 cap) internal pure returns (Steps memory st) {
        st.pos = new uint256[](cap);
        st.val = new uint256[](cap);
    }

    function push(Steps memory st, uint256 pos, uint256 val) internal pure {
        st.pos[st.n] = pos;
        st.val[st.n] = val;
        ++st.n;
    }

    function newPieces(uint256 cap) internal pure returns (Pieces memory pc) {
        pc.s = new uint256[](cap);
        pc.e = new uint256[](cap);
    }

    function onePiece(uint256 s, uint256 e) internal pure returns (Pieces memory pc) {
        pc = newPieces(1);
        addPiece(pc, s, e);
    }

    function addPiece(Pieces memory pc, uint256 s, uint256 e) internal pure {
        pc.s[pc.m] = s;
        pc.e[pc.m] = e;
        ++pc.m;
    }

    /// @dev Inside each slice of pc, new value = ADD ? old value + 1 : SUB ? old value - 1 : arg; outside the
    ///      slices the value is unchanged. The output stays in canonical form.
    function rebuild(Steps memory old, Pieces memory pc, uint8 mode, uint256 arg)
        internal
        pure
        returns (Steps memory out)
    {
        out = newSteps(old.n + 2 * pc.m);
        uint256 i;
        uint256 j;
        bool inside;
        uint256 ov; // value of the old function at the current position
        uint256 last; // last value output
        while (i < old.n || j < pc.m) {
            uint256 x = type(uint256).max;
            if (i < old.n) x = old.pos[i];
            if (j < pc.m) {
                uint256 pb = inside ? pc.e[j] : pc.s[j];
                if (pb < x) x = pb;
            }
            if (i < old.n && old.pos[i] == x) {
                ov = old.val[i];
                ++i;
            }
            while (j < pc.m) {
                if (inside) {
                    if (pc.e[j] != x) break;
                    inside = false;
                    ++j;
                } else {
                    if (pc.s[j] != x) break;
                    inside = true;
                }
            }
            uint256 nv = ov;
            if (inside) nv = mode == ADD ? ov + 1 : mode == SUB ? ov - 1 : arg;
            if (nv != last) {
                push(out, x, nv);
                last = nv;
            }
        }
    }
}

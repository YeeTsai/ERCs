// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {ERCXXXX} from "../ERCXXXX.sol";
import {SerialConsolidations} from "../utils/SerialConsolidations.sol";

/// @title ERCXXXXConsolidation: the module that opens consolidation
/// @notice Consolidation belongs to the core interface ("Consolidation" in the draft), and the core contract ERCXXXX
///         keeps it closed by default: consolidateSlices always reverts.
///         A token that inherits this module opens consolidation: a holder moves its scattered units onto one slice
///         of newly issued consecutive serials, and the correspondence between old and new serials is recorded in
///         the contract and queried with consolidatedRunAt. This module overrides these two functions of the core
///         and does not correspond to a separate interface, so it does not change supportsInterface.
///         When the freezing extension is inherited as well, freezes and unfreezes propagate along these records to
///         successors ("Freezing and consolidation" in the draft; the propagation is done in the freezing
///         extension, which reads the records through the core hook _successorPieces); when the classification
///         extension is inherited as well, the new serials keep the class of the old serials
///         ("Classes and consolidation" in the draft).
///
/// @dev Who can consolidate, and which consolidations are refused, is decided by the three virtual functions below
///      (clause 7 of "Consolidation" in the draft); a token overrides them to set its deployment parameters:
///      - _authorizeConsolidation(caller): by default any holder can consolidate its own units.
///      - _minConsolidationSlices(): how many groups a consolidation has to include at least, 1 by default. The
///        number of groups is the number of slices that are not adjacent to one another: a slice that starts
///        where the previous one ends belongs to the previous group. Groups are counted because adjacent slices
///        leave only one consolidation record, so splitting one slice into several adjacent slices and naming
///        them separately does not make up the number of groups.
///      - _consolidationThreshold(): only accounts whose number of slices (sliceCount) exceeds it can consolidate;
///        0 by default, that is, no limit.
///      This contract has no function for consolidating on behalf of another account.
///
///      The checks are made in this order: permission to call, the account's slice threshold, the form of the
///      arguments and whether the serials are issued (the same as transferSlices), whether the serials are held
///      by the caller, the number of groups, freezes and classes. So when the serials named include some that are
///      not held by the caller and some that are frozen, the call reverts with ERCXXXXNotHeld.
///
///      Storage (see SerialConsolidations): one storage slot per record, plus a 256-ary bitmap tree keyed by old
///      start; the tree is expanded only where it branches, so when old starts are sparse each record mostly
///      creates only one new slot in the tree. Slices of one consolidation that are adjacent to one another
///      become one record; records of different consolidations are not merged. consolidatedRunAt joins, at query
///      time, the records that follow immediately in both the old serials and the successors, but at most 32
///      more records after the record that contains the serial (SerialConsolidations.MAX_RUN_EXTENSION), so the
///      cost of one query is bounded; when more records follow one another, the run returned is shorter than the
///      longest one, which clause 10 of "Consolidation" in the draft allows.
///      Transfers by amount, transferSlices and forced operations do not read the consolidation records, and their
///      cost is not affected by this module.
abstract contract ERCXXXXConsolidation is ERCXXXX {
    using SerialConsolidations for SerialConsolidations.Records;

    /// @notice The number of groups of a consolidation (the number of slices not adjacent to one another) is less
    ///         than the minimum number of groups that the implementation requires.
    error ERCXXXXConsolidationTooFewSlices(uint256 slices, uint256 minSlices);
    /// @notice The account's number of slices does not exceed the threshold set by the implementation, so it cannot
    ///         consolidate.
    error ERCXXXXConsolidationNotFragmented(address account, uint256 sliceCount, uint256 threshold);

    SerialConsolidations.Records private _consolidations;

    // ───────────────────────── The two consolidation functions of IERCXXXX ─────────────────────────

    function consolidateSlices(uint256[] calldata starts, uint256[] calldata amounts)
        public
        virtual
        override
        returns (uint256 newStart)
    {
        _authorizeConsolidation(msg.sender);
        return _consolidate(msg.sender, starts, amounts);
    }

    function consolidatedRunAt(uint256 serial)
        public
        view
        virtual
        override
        returns (bool consolidated, uint256 successor, uint256 length)
    {
        return _consolidations.runAt(serial, serialsIssued());
    }

    // ───────────────────────── Hooks for deployment parameters ─────────────────────────

    /// @dev Whether caller can consolidate its own units. Reverts if not. By default any holder can.
    function _authorizeConsolidation(address caller) internal view virtual {
        caller;
    }

    /// @dev How many groups (slices not adjacent to one another) a consolidation has to include at least.
    function _minConsolidationSlices() internal view virtual returns (uint256) {
        return 1;
    }

    /// @dev Only accounts whose sliceCount exceeds it can consolidate; 0 means no limit.
    function _consolidationThreshold() internal view virtual returns (uint256) {
        return 0;
    }

    // ───────────────────────── Internal operations ─────────────────────────

    /// @dev Consolidates the slices (starts[i], amounts[i]) held by account and returns the first new serial. Does
    ///      not check permission to call.
    function _consolidate(address account, uint256[] calldata starts, uint256[] calldata amounts)
        internal
        virtual
        returns (uint256 newStart)
    {
        uint256 threshold = _consolidationThreshold();
        if (threshold != 0) {
            uint256 c = sliceCount(account);
            if (c <= threshold) revert ERCXXXXConsolidationNotFragmented(account, c, threshold);
        }
        (uint256 value, uint256 groups) = _detachSlices(account, starts, amounts);
        uint256 minSlices = _minConsolidationSlices();
        if (groups < minSlices) revert ERCXXXXConsolidationTooFewSlices(groups, minSlices);
        bytes32 pile = _consolidationPile(account, starts, amounts);
        newStart = _issueConsolidated(account, value, pile);
        _record(account, starts, amounts, newStart);
        _afterConsolidation(newStart, value, pile);
    }

    /// @dev The pile where the named serials belong; it has to be the same for all of them and must not be the
    ///      frozen pile (clause 1 of "Freezing and consolidation" and clause 1 of "Classes and consolidation" in the
    ///      draft). In this implementation the pile where a serial that is not frozen belongs is its class, so
    ///      "the same pile" means "the same class".
    ///      Otherwise reverts with ERCXXXXNotConsolidatable(account, starts[i], amounts[i]), where slice i is the
    ///      first slice that contains a frozen serial or a serial whose class differs from that of the serial
    ///      starts[0]. When there are no restrictions attached to serials, no check is needed.
    function _consolidationPile(address account, uint256[] calldata starts, uint256[] calldata amounts)
        private
        view
        returns (bytes32 pile)
    {
        if (!_hasRestrictions()) return _DEFAULT_PILE;
        (,, pile) = _segmentAt(starts[0]);
        for (uint256 k; k < starts.length; ++k) {
            uint256 x = starts[k];
            uint256 b = x + amounts[k];
            while (x < b) {
                (, uint256 hi, bytes32 q) = _segmentAt(x);
                if (q != pile || q == _FROZEN_PILE) revert ERCXXXXNotConsolidatable(account, starts[k], amounts[k]);
                x = hi;
            }
        }
    }

    /// @dev Emits SliceConsolidated (one for each i, in the order of i) and writes the consolidation records
    ///      (adjacent slices become one record).
    function _record(address account, uint256[] calldata starts, uint256[] calldata amounts, uint256 newStart)
        private
    {
        uint256 p = newStart;
        uint256 gOld;
        uint256 gNew;
        uint256 gLen;
        // Old start of the record added last: the groups are added in ascending order, and the search for the
        // next one starts at the level where the two diverge.
        uint256 prev = SerialConsolidations.NONE;
        for (uint256 k; k < starts.length; ++k) {
            uint256 a = starts[k];
            uint256 len = amounts[k];
            emit SliceConsolidated(account, a, p, len);
            if (gLen != 0 && a == gOld + gLen) {
                gLen += len;
            } else {
                if (gLen != 0) {
                    _consolidations.add(gOld, gNew, gLen, prev);
                    prev = gOld;
                }
                (gOld, gNew, gLen) = (a, p, len);
            }
            p += len;
        }
        _consolidations.add(gOld, gNew, gLen, prev);
    }

    // ───────────────────────── Hooks of the core ─────────────────────────

    function _successorPieces(uint256 start, uint256 end)
        internal
        view
        virtual
        override
        returns (uint256[] memory, uint256[] memory)
    {
        return _consolidations.successorsOf(start, end);
    }
}

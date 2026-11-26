// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

/// @title SerialHoldings
/// @notice Abstract interface of the storage backend for holdings. The core contract ERCXXXX reads and writes slices
///         only through these functions, so the same core and extensions can switch to a different data structure,
///         which serves to compare gas.
/// @dev Each account's holding is divided into several piles; each pile is a set of pairwise disjoint slices, with
///      indexes from 0 to n - 1. The number of slices n is kept by the core and passed in as an argument; the backend
///      handles only the slices themselves.
///      Convention: in selection by amount, the core takes from the end of a slice with the largest serials. The
///      default rule (_selectionWindow() is 0) always takes the slice at index n - 1, so index n - 1 is the first
///      slice in the backend's "selection order"; the second rule picks one slice by length among the W slices at
///      indexes [n - W, n) (see ERCXXXX).
abstract contract SerialHoldings {
    /// @dev The selection rule for selection by amount (fixed at deployment, unchanged afterward): 0 means the
    ///      default rule; W >= 1 means the second rule, whose window is the first W slices in selection order.
    ///      A backend that supports only the default rule returns the constant 0; a backend that supports the second
    ///      rule returns the immutable stored at deployment. Neither reads storage.
    function _selectionWindow() internal view virtual returns (uint256);

    /// @dev The slice at index i in pile (the caller ensures i < n).
    function _rangeAt(address account, bytes32 pile, uint256 i) internal view virtual returns (uint256 start, uint256 len);

    /// @dev Adds [start, start + len) to pile (the caller ensures that it is disjoint from the slices already in the
    ///      pile) and returns the new number of slices. The backend may merge it with adjacent slices.
    function _addRange(address account, bytes32 pile, uint256 n, uint256 start, uint256 len)
        internal
        virtual
        returns (uint256);

    /// @dev Adds the m slices starts[0..m) / lens[0..m) to pile at once and returns the new number of slices. They
    ///      are pairwise disjoint and also disjoint from the slices already in the pile. A batch taken by amount comes
    ///      from a single source pile and is in that pile's selection order; a batch moved out by serial is in
    ///      ascending order of start (the draft requires the caller to give the slices in ascending order of start).
    ///      So a batch taken by amount is strictly monotonic only on a backend whose selection order follows the
    ///      order of the serials (for example the sorted array, which takes from the slice with the largest
    ///      serials); on a backend whose selection order is the order of receipt (for example the stack), a batch is
    ///      not guaranteed to be monotonic, and its _addRanges cannot rely on monotonicity.
    ///      The simplest implementation calls _addRange for each slice; a backend whose insertion cost depends on
    ///      the position (for example the sorted array) should merge the batch and write it in one pass.
    function _addRanges(
        address account,
        bytes32 pile,
        uint256 n,
        uint256[] memory starts,
        uint256[] memory lens,
        uint256 m
    ) internal virtual returns (uint256);

    /// @dev Sets the length of the slice at index n - 1 to newLen (less than its current length, with the same
    ///      start); when newLen is 0, deletes the slice. Returns the new number of slices.
    function _setTopLen(address account, bytes32 pile, uint256 n, uint256 newLen) internal virtual returns (uint256);

    /// @dev Removes [lo, hi) from the slice at index i (the caller ensures that it lies within that slice). Returns
    ///      the new number of slices.
    ///      It may change the positions only of slices at indexes not less than i, so that the caller can walk the
    ///      indexes from high to low and take as it goes.
    function _removeAt(address account, bytes32 pile, uint256 n, uint256 i, uint256 lo, uint256 hi)
        internal
        virtual
        returns (uint256);

    /// @dev Removes from pile all serials that fall within [lo, hi), and returns the new number of slices and the
    ///      number of serials removed.
    ///      This is where operations by serial (transferSlices, forced operations and so on) locate serials; its cost
    ///      depends on the data structure.
    function _removeSerials(address account, bytes32 pile, uint256 n, uint256 lo, uint256 hi)
        internal
        virtual
        returns (uint256 newN, uint256 removed);

    /// @dev Removes from pile all serials that fall within the m slices [los[j], his[j]). These slices are in
    ///      ascending order of start and pairwise disjoint (they may be adjacent). The number removed for slice j is
    ///      added to got[j], and total is the number removed by this call; the backend may stop once want serials
    ///      have been removed.
    ///      Returns the new number of slices. Consolidation uses it to remove many slices at once: the backend should
    ///      do this in a single scan rather than search the holding once for each slice.
    function _removeSerialsBatch(
        address account,
        bytes32 pile,
        uint256 n,
        uint256[] memory los,
        uint256[] memory his,
        uint256[] memory got,
        uint256 want
    ) internal virtual returns (uint256 newN, uint256 total);
}

// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {ERCXXXX} from "../ERCXXXX.sol";

/// @title ERCXXXXTidy: a function that tidies without transferring
///        (a function of this implementation, not part of any interface of the draft)
/// @notice Freezing, unfreezing and setting a class change only the state recorded on serials and do not touch
///         holdings, so an account can have slices that are not in the pile where they belong.
///         Transfers by amount move them along the way, but each transfer moves at most a few dozen slices; when
///         many slices are frozen at once, the cost of the first few transfers can exceed the gas limit of a
///         single transaction. This function lets anyone move them into place over several calls, after which
///         transfers no longer have to skip them.
/// @dev Pile keys (a detail of this implementation, also returned by serialPositionOf): the default pile is 0, the
///      frozen pile is keccak256("ERCXXXX.pile.frozen"), and a class pile is keyed by its class ID. A slice that
///      was frozen or had its class set after it was received is in the default pile (or in its original class
///      pile); a slice that was moved into the frozen pile and unfrozen afterwards is in the frozen pile.
///
///      Anyone can call it. It does not change holders, balances, transferable balances or the results of the
///      freeze and class queries, and emits no events; but it does change the order and the number of slices
///      that sliceAt reports, and also which serials the next transfer by amount selects
///      (the draft states that the selection order can be influenced; see "Security Considerations").
///
///      It looks at one pile per call. Cost: maxMoves limits the number of slices moved; the slices that come
///      before a misplaced slice and are already in place also have to be read, and maxMoves does not limit
///      these reads; when the sorted array inserts a slice near the front of the destination pile, it also has
///      to rewrite all the slices that come after it in the destination pile.
abstract contract ERCXXXXTidy is ERCXXXX {
    /// @notice In the holding of account, moves the slices of the pile with the key pile that do not belong to this
    ///         pile to the piles where they belong, at most maxMoves slices, and returns how many slices it moved.
    ///         A return value smaller than maxMoves means that this pile is fully tidied.
    function tidySlices(address account, bytes32 pile, uint256 maxMoves) public virtual returns (uint256 moved) {
        return _tidy(account, pile, maxMoves);
    }
}

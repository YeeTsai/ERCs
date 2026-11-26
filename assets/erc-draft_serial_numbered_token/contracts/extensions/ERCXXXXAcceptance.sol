// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERCXXXX} from "../ERCXXXX.sol";
import {IERCXXXXAcceptance} from "../spec/IERCXXXXAcceptance.sol";

/// @title ERCXXXXAcceptance: reference implementation of the acceptance check
/// @notice A token that inherits this contract supports the acceptance check (clauses 1 to 10 of "Acceptance check"
///         in the draft): when units are transferred to an address that has code, the contract first determines
///         by ERC-165 whether that address is a receiving contract; if it is, the contract calls its
///         acceptsERCXXXXTransfer with STATICCALL, and if it does not accept, the operation reverts with
///         ERCXXXXTransferRefused(from, to, value).
///         The acceptance interface IERCXXXXAcceptance is implemented by the recipient; this contract does not
///         implement it.
///
/// @dev Choices of this implementation (the places that the draft asks to be documented):
///      - Declaration: supportsInterface returns true for 0x29543499, the identifier of the acceptance check (the
///        selector of the error ERCXXXXTransferRefused); it does not return true for 0x4689efd4, the interface of
///        the recipient. A token that does not inherit this contract returns false for 0x29543499.
///      - Operations covered: the core functions _transfer and _transferSlices call the hook _checkAcceptance, so
///        transfer, transferFrom and transferSlices are covered, and so is any transfer that the token provides
///        on its own and that goes through these two functions (clause 1). operator is msg.sender.
///        slices is the number of SliceTransferred events emitted for this incoming transfer: in a transfer by
///        amount it depends on the selection rule; transferSlices emits one for each named slice, so it equals the
///        number of slices.
///      - An exempt incoming transfer (value is zero, from equals to, or operator equals to) and an address to
///        without code make no external call.
///      - Determining a receiving contract (clauses 2 and 4), following the section
///        "How to Detect if a Contract Implements ERC-165" of ERC-165:
///        1. to has no code: not a receiving contract.
///        2. STATICCALL supportsInterface(0x01ffc9a7), forwarding 30,000 gas. If it fails or returns false: not a
///           receiving contract.
///        3. STATICCALL supportsInterface(0xffffffff), forwarding 30,000 gas. If it fails or does not return
///           false: not a receiving contract.
///        4. STATICCALL supportsInterface(0x4689efd4), forwarding 30,000 gas. to is a receiving contract only if
///           it returns true.
///        The return value is the first word of the return data; a call that returns fewer than 32 bytes of data
///        is treated as failed. "false" in step 2 means that this word is 0, step 3 requires it to be 0, and
///        step 4 requires it to be exactly 1. The three return values are thus evaluated in the same way as in the
///        ERC165Query contract in the test cases of ERC-165 (the first not 0, the second 0, the third 1);
///        ERC165Query does not look at the length of the return data, and this implementation adds that check.
///        ERC-165 states 30,000 gas only for the first call; the other two use 30,000 as well, on the basis of
///        clause 5 of "Acceptance check" in the draft.
///      - Clause 5 (gas): before each supportsInterface query the contract reads gasleft(); when it is below
///        _QUERY_GAS_FLOOR, the query is not made and the operation reverts with
///        ERCXXXXAcceptanceQueryOutOfGas(to), whether or not the query would have returned successfully. A query
///        that cannot get 30,000 gas might fail only because the gas is insufficient; a false that it returns
///        successfully might also be only the answer given when the gas is insufficient (for example, the callee
///        skips a subcall when gas is short, or catches the failure of a subcall). Neither case can be used to
///        conclude that to is not a receiving contract (the first sentence of clause 5), so in neither case does
///        the determination go on. So when the gas is below the floor, the operation reverts for an address to
///        that has code even if it turns out not to be a receiving contract; this is a revert caused by
///        insufficient gas, not a rejection because to is not a receiving contract in the sense of clause 4.
///        When the reading reaches the floor, every query forwards 30,000 gas and is judged by the result of the
///        call. The derivation of the floor is given at _QUERY_GAS_FLOOR.
///      - Clause 6: the queries and the call take place after all the changes that this operation makes to the
///        holders of serials are complete: the serials and the balance are already recorded under to,
///        SliceTransferred has been emitted, and Transfer has not yet been emitted (for issuance that any caller
///        can execute, they take place after the Transfer of the issuance). A payer who is refused therefore pays
///        the gas of the whole movement; during the call the receiving contract reads the token state as it is
///        after the incoming transfer.
///      - Clause 7: the gas forwarded to acceptsERCXXXXTransfer is not limited; the call forwards all the gas
///        available at that point (less the 1/64 retained under EIP-150). A failure of this call, including for
///        lack of gas, counts as a refusal. Only the first 32 bytes of the return data are copied into memory.
///        "Accept" means that the call succeeds, returns at least 32 bytes of data, and the first word is exactly
///        0x4689efd4 followed by 28 zero bytes.
///      - Clause 8: selection by amount does not look at the recipient and does not look for a selection that
///        would be accepted.
///      - Clause 9: restricted issuance (_mint and _issue of the core, _mintWithClass of the classification
///        extension) and forced operations (_moveRange and _moveRangeAt, that is, forcedTransferSlice,
///        destroySlice and their hinted versions) do not query receiving contracts.
///        For issuance that any caller can execute and that names the receiving address, the token has to call
///        _requireIssuanceAccepted after the issuance, or use _mintAccepted directly; then from is the zero
///        address, operator is msg.sender and slices is 1.
///        Burning has no recipient and makes no query.
///      - Clause 10: approve makes no query to any recipient; a refused transfer reverts as a whole, so the
///        allowance does not change.
///      - The receive limit for accounts that "The acceptance check and failed payments" in the draft recommends
///        is not provided, and the notification of ERC-1363 is not implemented.
abstract contract ERCXXXXAcceptance is ERCXXXX {
    /// @notice While determining whether to is a receiving contract, the remaining gas was not enough to guarantee
    ///         that 30,000 gas is forwarded to the next supportsInterface query (clause 5 of "Acceptance check" in
    ///         the draft), and that query was not made. Resending the transaction with more gas is enough.
    error ERCXXXXAcceptanceQueryOutOfGas(address to);

    /// @dev The ERC-165 identifier of the acceptance check, 0x29543499, that is, the selector of the error
    ///      ERCXXXXTransferRefused.
    bytes4 internal constant _ACCEPTANCE_CHECK_ID = ERCXXXXTransferRefused.selector;

    /// @dev The value a recipient returns to accept, which is also the ERC-165 identifier of IERCXXXXAcceptance,
    ///      0x4689efd4.
    bytes4 private constant _ACCEPTED = IERCXXXXAcceptance.acceptsERCXXXXTransfer.selector;

    /// @dev The gas that the detection procedure of ERC-165 forwards to each supportsInterface query.
    uint256 private constant _QUERY_GAS = 30_000;

    /// @dev gasleft() has to be at least this value before a query to guarantee that the callee receives _QUERY_GAS:
    ///      - EIP-150: STATICCALL first deducts its own cost, then forwards at most G - floor(G / 64) of the
    ///        remaining G. To forward 30,000, G >= 30,476 is needed (30,476 - 476 = 30,000).
    ///      - The cost of STATICCALL itself: accessing the account of to, counted as a cold access at 2,600 (in
    ///        fact the code length of to has already been read, so it is a warm access at 100); the arguments and
    ///        the return value are both in the scratch space from 0x00 to 0x3f, so there is no memory expansion.
    ///      - The few instructions between reading gasleft() and executing STATICCALL cost less than 100 gas; a
    ///        margin of 500 is left.
    ///      30,476 + 2,600 + 500 = 33,576, rounded up to 34,000. When the reading is below it, the callee is not
    ///      guaranteed 30,000 gas, and the query is not made.
    uint256 private constant _QUERY_GAS_FLOOR = 34_000;

    // ───────────────────────── ERC-165 ─────────────────────────

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == _ACCEPTANCE_CHECK_ID || super.supportsInterface(interfaceId);
    }

    // ───────────────────────── Internal functions for the token ─────────────────────────

    /// @dev Issues value units in the default state to the address to, and asks to under the acceptance check. For
    ///      issuance that any caller can execute (clause 9 of "Acceptance check" in the draft): from is the zero
    ///      address, operator is msg.sender.
    function _mintAccepted(address to, uint256 value) internal virtual returns (uint256 start) {
        start = _mint(to, value);
        _requireIssuanceAccepted(to, value);
    }

    /// @dev Called after an operation that issues value units to the address to; reverts when to refuses. For
    ///      issuance that any caller can execute and that does not go through _mintAccepted, for example issuance
    ///      with a non-zero class. Every issuance of the core (_issue) emits at most one SliceTransferred, so
    ///      slices is 1; the incoming transfer is exempt when value is zero or msg.sender equals to.
    function _requireIssuanceAccepted(address to, uint256 value) internal view virtual {
        _checkAcceptance(address(0), to, value, 1);
    }

    /// @dev Whether to is a receiving contract (as defined in "Acceptance check" in the draft); the steps are
    ///      described at the top of the contract. Reverts with ERCXXXXAcceptanceQueryOutOfGas when the remaining gas
    ///      before any supportsInterface query is below _QUERY_GAS_FLOOR.
    function _isReceivingContract(address to) internal view returns (bool) {
        if (to.code.length == 0) return false;
        (bool ok, uint256 word) = _query(to, 0x01ffc9a7);
        if (!ok || word == 0) return false;
        (ok, word) = _query(to, 0xffffffff);
        if (!ok || word != 0) return false;
        (ok, word) = _query(to, _ACCEPTED);
        return ok && word == 1;
    }

    // ───────────────────────── Acceptance check ─────────────────────────

    /// @dev The core calls it in _transfer and _transferSlices, and _requireIssuanceAccepted calls it as well.
    ///      operator is msg.sender.
    function _checkAcceptance(address from, address to, uint256 value, uint256 ranges) internal view virtual override {
        address operator = msg.sender;
        // Exempt incoming transfer: no determination and no call (clause 4 of "Acceptance check" in the draft).
        if (value == 0 || from == to || operator == to) return;
        if (!_isReceivingContract(to)) return;
        if (!_accepts(to, operator, from, value, ranges)) revert ERCXXXXTransferRefused(from, to, value);
    }

    /// @dev Calls supportsInterface(interfaceId) on to with STATICCALL, forwarding _QUERY_GAS.
    ///      ok means that the call succeeded and returned at least 32 bytes; word is the first word of the return
    ///      data. When gasleft() is below _QUERY_GAS_FLOOR before the call, the call is not made and the function
    ///      reverts right away, whether or not the call would have succeeded.
    function _query(address to, bytes4 interfaceId) private view returns (bool ok, uint256 word) {
        if (gasleft() < _QUERY_GAS_FLOOR) revert ERCXXXXAcceptanceQueryOutOfGas(to);
        bytes4 selector = 0x01ffc9a7; // supportsInterface(bytes4)
        uint256 size;
        assembly ("memory-safe") {
            // 36 bytes of call data: the selector at 0x00 and the argument at 0x04, both within the scratch space.
            mstore(0x00, selector)
            mstore(0x04, interfaceId)
            ok := staticcall(_QUERY_GAS, to, 0x00, 0x24, 0x00, 0x20)
            size := returndatasize()
            word := mload(0x00)
        }
        ok = ok && size >= 32;
    }

    /// @dev Calls acceptsERCXXXXTransfer on the receiving contract to with STATICCALL, without limiting the gas.
    ///      The receiving contract accepts when the call succeeds, returns at least 32 bytes of data, and the first
    ///      word is 0x4689efd4 padded with zeros; every other case is a refusal.
    function _accepts(address to, address operator, address from, uint256 value, uint256 ranges)
        private
        view
        returns (bool)
    {
        bytes memory data =
            abi.encodeCall(IERCXXXXAcceptance.acceptsERCXXXXTransfer, (operator, from, value, ranges));
        bool ok;
        uint256 size;
        bytes32 word;
        assembly ("memory-safe") {
            ok := staticcall(gas(), to, add(data, 0x20), mload(data), 0x00, 0x20)
            size := returndatasize()
            word := mload(0x00)
        }
        return ok && size >= 32 && word == bytes32(_ACCEPTED);
    }
}

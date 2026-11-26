// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

/// @title Serial-Numbered Fungible Tokens, acceptance interface
/// @dev Implemented by a receiving contract, not by the token. A contract implementing it MUST also
///      implement ERC-165. A token that supports the acceptance check calls it with `STATICCALL`.
interface IERCXXXXAcceptance /* is IERC165 */ {
    /// @notice Whether this contract accepts a transfer of `value` units from `from` that is
    ///         initiated by `operator` and delivered in `slices` slices. The caller is the token
    ///         contract.
    /// @dev Returns `IERCXXXXAcceptance.acceptsERCXXXXTransfer.selector` to accept.
    function acceptsERCXXXXTransfer(address operator, address from, uint256 value, uint256 slices)
        external
        view
        returns (bytes4);
}

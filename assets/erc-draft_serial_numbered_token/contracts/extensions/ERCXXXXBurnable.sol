// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERCXXXX} from "../ERCXXXX.sol";

/// @title ERCXXXXBurnable
/// @notice Lets holders burn their own units, with the signatures that clauses 5 and 6 of
///         "Requirements on ERC-20 behavior" in the draft recommend.
///         These three functions are not part of IERCXXXX and do not count toward its ERC-165 identifier.
abstract contract ERCXXXXBurnable is ERCXXXX {
    /// @notice Burns value units of the caller; the selection rule decides which serials are burned.
    function burn(uint256 value) public virtual {
        _burn(msg.sender, value);
    }

    /// @notice Burns value units of account and consumes the allowance that the caller has from account.
    function burnFrom(address account, uint256 value) public virtual {
        _spendAllowance(account, msg.sender, value);
        _burn(account, value);
    }

    /// @notice Burns the serials held by the caller that are named by the slices (starts[i], amounts[i]).
    function burnSlices(uint256[] calldata starts, uint256[] calldata amounts) public virtual {
        _burnSlices(msg.sender, starts, amounts);
    }
}

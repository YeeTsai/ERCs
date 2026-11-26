// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERCXXXX} from "../contracts/spec/IERCXXXX.sol";
import {IERCXXXXFreezable} from "../contracts/spec/IERCXXXXFreezable.sol";
import {IERCXXXXClassified} from "../contracts/spec/IERCXXXXClassified.sol";
import {IERCXXXXAcceptance} from "../contracts/spec/IERCXXXXAcceptance.sol";

/// @dev The interface ids written in the draft must equal the ones the compiler computes. contracts/spec/ follows
///      the draft, and the reference implementation declares these same ids.
contract InterfaceIdsTest is Test {
    function test_specInterfaceIds() public pure {
        // The two consolidation functions belong to the core interface; there is no separate interface id for
        // consolidation.
        assertEq(type(IERCXXXX).interfaceId, bytes4(0x668ccf00));
        assertEq(type(IERCXXXXFreezable).interfaceId, bytes4(0x6eb84bb0));
        assertEq(type(IERCXXXXClassified).interfaceId, bytes4(0xb62c1e43));
        assertEq(type(IERCXXXXAcceptance).interfaceId, bytes4(0x4689efd4));
        // The value a recipient returns to accept is the selector of this function (clause 2 of "Acceptance
        // check" in the draft), which is also the interface id above.
        assertEq(IERCXXXXAcceptance.acceptsERCXXXXTransfer.selector, bytes4(0x4689efd4));
    }

    /// @dev The ERC-165 identifier of the acceptance check is an agreed value that corresponds to no interface block:
    ///      it is the selector of the error ERCXXXXTransferRefused(address,address,uint256) ("Acceptance check" in
    ///      the draft).
    function test_declaredInterfaceIds() public pure {
        assertEq(IERCXXXX.ERCXXXXTransferRefused.selector, bytes4(0x29543499));
        assertEq(
            IERCXXXX.ERCXXXXTransferRefused.selector,
            bytes4(keccak256("ERCXXXXTransferRefused(address,address,uint256)"))
        );
        // The two identifiers differ: a token that supports the acceptance check does not thereby declare the
        // recipient's interface.
        assertTrue(bytes4(0x29543499) != type(IERCXXXXAcceptance).interfaceId);
    }
}

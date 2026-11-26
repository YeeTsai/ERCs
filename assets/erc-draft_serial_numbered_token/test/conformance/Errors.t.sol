// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20Errors} from "../../contracts/utils/IERC20.sol";
import {IERCXXXX} from "../../contracts/spec/IERCXXXX.sol";
import {ERCXXXX} from "../../contracts/ERCXXXX.sol";
import {ERCXXXXFreezable} from "../../contracts/extensions/ERCXXXXFreezable.sol";
import {ERCXXXXClassified} from "../../contracts/extensions/ERCXXXXClassified.sol";
import {ERCXXXXAllowlist} from "../../contracts/extensions/ERCXXXXAllowlist.sol";
import {Rule, TestAdmin} from "../presets/Presets.sol";
import "../presets/Targets.sol";

/// @dev The reference implementation's own errors and description queries. The draft only requires these cases to
///      revert; the specific errors are this implementation's choice.
///      Runs only on tokens that support both extensions (the core part is the same code as in core-only tokens).
abstract contract ErrorsBase is Test, TokenTarget {
    ITestToken internal t;
    address internal admin = makeAddr("admin");
    address internal A = makeAddr("A");
    address internal B = makeAddr("B");
    bytes32 internal constant W = "w";
    bytes32 internal constant R = "r";

    function setUp() public {
        (t,,,) = _deployToken(admin);
        vm.startPrank(admin);
        t.setReasonInfo(R, "Reason", "ipfs://reason");
        t.defineClass(W, Rule.Allowlist, 0, "Designated recipients only", "ipfs://w");
        t.mint(A, 100);
        vm.stopPrank();
    }

    function _one(uint256 x) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = x;
    }

    function test_metadata() public view {
        assertEq(t.name(), "Serial");
        assertEq(t.symbol(), "SRL");
        assertEq(t.decimals(), 6);
    }

    function test_erc20Errors() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        t.mint(address(0), 1);

        vm.prank(A);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        t.approve(address(0), 1);

        vm.prank(A);
        t.approve(B, 5);
        vm.prank(B);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, B, 5, 6));
        t.transferFrom(A, B, 6);

        vm.prank(A);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, A, 100, 101));
        t.transfer(B, 101);
    }

    /// @dev transferFrom and burnFrom reduce the allowance by the amount and emit no Approval; an unlimited allowance
    ///      (type(uint256).max) is not reduced.
    function test_allowanceAccounting() public {
        vm.prank(A);
        t.approve(B, 30);
        vm.recordLogs();
        vm.prank(B);
        t.transferFrom(A, B, 10);
        assertEq(t.allowance(A, B), 20);
        vm.prank(B);
        t.burnFrom(A, 5);
        assertEq(t.allowance(A, B), 15);

        vm.prank(A);
        t.approve(B, type(uint256).max);
        vm.prank(B);
        t.transferFrom(A, B, 10);
        vm.prank(B);
        t.burnFrom(A, 5);
        assertEq(t.allowance(A, B), type(uint256).max);
        assertEq(t.balanceOf(A), 70);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 approvalSig = keccak256("Approval(address,address,uint256)");
        uint256 approvals;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == approvalSig) ++approvals;
        }
        assertEq(approvals, 1, "only the explicit approve emits Approval");
    }

    /// @dev Zero-value transfers and transfers to oneself both emit Transfer and emit no SliceTransferred.
    function test_zeroAndSelfTransferEvents() public {
        vm.prank(A);
        t.approve(B, 5);
        bytes32 transferSig = keccak256("Transfer(address,address,uint256)");
        bytes32 serialSig = keccak256("SliceTransferred(address,address,uint256,uint256)");
        address[4] memory from = [A, A, A, A];
        address[4] memory to = [B, A, B, A];
        uint256[4] memory value = [uint256(0), 7, 0, 3];
        for (uint256 i; i < 4; ++i) {
            vm.recordLogs();
            if (i < 2) {
                vm.prank(A);
                assertTrue(t.transfer(to[i], value[i]));
            } else {
                vm.prank(B);
                assertTrue(t.transferFrom(from[i], to[i], value[i]));
            }
            Vm.Log[] memory logs = vm.getRecordedLogs();
            uint256 transfers;
            for (uint256 j; j < logs.length; ++j) {
                assertTrue(logs[j].topics[0] != serialSig, "SliceTransferred for a zero or self transfer");
                if (logs[j].topics[0] == transferSig) {
                    ++transfers;
                    assertEq(address(uint160(uint256(logs[j].topics[1]))), from[i]);
                    assertEq(address(uint160(uint256(logs[j].topics[2]))), to[i]);
                    assertEq(abi.decode(logs[j].data, (uint256)), value[i]);
                }
            }
            assertEq(transfers, 1, "exactly one Transfer");
        }
        assertEq(t.balanceOf(A), 100);
        assertEq(t.allowance(A, B), 2);
    }

    function test_rangeIndexOutOfBounds() public {
        // Spread A's holdings over the default pile and the frozen pile, then read out of bounds.
        vm.prank(admin);
        t.freezeSlice(40, 10, R);
        vm.prank(A);
        t.transfer(B, 70);
        assertEq(t.sliceCount(A), 2);
        t.sliceAt(A, 1);
        vm.expectRevert(abi.encodeWithSelector(ERCXXXX.ERCXXXXRangeIndexOutOfBounds.selector, A, 2));
        t.sliceAt(A, 2);
        vm.expectRevert(abi.encodeWithSelector(ERCXXXX.ERCXXXXRangeIndexOutOfBounds.selector, B, 5));
        t.sliceAt(B, 5);
    }

    function test_issuanceOverflow() public {
        uint256 room = type(uint128).max - 100;
        vm.prank(admin);
        t.mint(B, room);
        assertEq(t.serialsIssued(), type(uint128).max);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(ERCXXXX.ERCXXXXIssuanceOverflow.selector, uint256(type(uint128).max), 1)
        );
        t.mint(A, 1);
        // The largest serial can still be transferred out
        vm.prank(B);
        t.transfer(A, 1);
        assertEq(t.balanceOf(A), 101);
    }

    function test_invalidRanges() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(ERCXXXX.ERCXXXXInvalidRange.selector, 0, 0));
        t.freezeSlice(0, 0, R);
        vm.expectRevert(abi.encodeWithSelector(ERCXXXX.ERCXXXXInvalidRange.selector, 90, 11));
        t.unfreezeSlice(90, 11, R);
        vm.expectRevert(abi.encodeWithSelector(ERCXXXX.ERCXXXXInvalidRange.selector, 100, 1));
        t.setClass(100, 1, W);
        vm.stopPrank();
        vm.prank(A);
        vm.expectRevert(ERCXXXX.ERCXXXXInvalidRanges.selector);
        t.transferSlices(B, _one(0), new uint256[](0));
    }

    function test_reasons() public {
        (string memory nm, string memory uri) = t.freezeReasonInfo(R);
        assertEq(nm, "Reason");
        assertEq(uri, "ipfs://reason");
        (nm, uri) = t.freezeReasonInfo("unknown");
        assertEq(bytes(nm).length, 0);
        assertEq(bytes(uri).length, 0);

        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(ERCXXXXFreezable.ERCXXXXInvalidReason.selector, bytes32("x")));
        t.setReasonInfo("x", "", "");
        vm.expectRevert(abi.encodeWithSelector(ERCXXXXFreezable.ERCXXXXInvalidReason.selector, bytes32("x")));
        t.freezeSlice(0, 1, "x");
        vm.stopPrank();
    }

    function test_forcedErrors() public {
        vm.startPrank(admin);
        t.freezeSlice(0, 10, R);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        t.forcedTransferSlice(A, address(0), 0, 5);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, A));
        t.forcedTransferSlice(A, A, 0, 5);
        vm.expectRevert(abi.encodeWithSelector(ERCXXXX.ERCXXXXInvalidRange.selector, 0, 0));
        t.forcedTransferSlice(A, B, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(IERCXXXX.ERCXXXXNotHeld.selector, A, 95, 10));
        t.destroySlice(A, 95, 10);
        vm.expectRevert(abi.encodeWithSelector(ERCXXXXFreezable.ERCXXXXNotFrozen.selector, 5, 10));
        t.forcedTransferSlice(A, B, 5, 10);
        vm.stopPrank();
        vm.prank(A);
        vm.expectRevert(TestAdmin.NotAdmin.selector);
        t.destroySlice(A, 0, 1);
    }

    function test_classDefinitions() public {
        (string memory nm, string memory uri) = t.classInfo(W);
        assertEq(nm, "Designated recipients only");
        assertEq(uri, "ipfs://w");
        (nm, uri) = t.classInfo(bytes32(0));
        assertEq(bytes(nm).length + bytes(uri).length, 0);
        assertTrue(t.classAllows(bytes32(0), A, address(0)));

        bytes32 frozenPile = keccak256("ERCXXXX.pile.frozen");
        bytes4 bad = ERCXXXXClassified.ERCXXXXInvalidClass.selector;
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(bad, bytes32(0)));
        t.defineClass(bytes32(0), Rule.None, 0, "zero", "");
        vm.expectRevert(abi.encodeWithSelector(bad, frozenPile));
        t.defineClass(frozenPile, Rule.None, 0, "reserved key", "");
        vm.expectRevert(abi.encodeWithSelector(bad, bytes32("c")));
        t.defineClass("c", Rule.None, 0, "", "");
        t.defineClass("c", Rule.None, 0, "Batch", "");
        t.defineClass("d", Rule.None, 0, "Label", "");

        vm.expectRevert(abi.encodeWithSelector(bad, bytes32("u")));
        t.setClass(0, 1, "u");
        vm.expectRevert(abi.encodeWithSelector(bad, bytes32("u")));
        t.mintWithClass(A, 1, "u");
        // Lists of permitted recipients belong only to allowlist classes
        vm.expectRevert(abi.encodeWithSelector(bad, bytes32("c")));
        t.setAllowed("c", B, true);
        vm.expectEmit(address(t));
        emit ERCXXXXAllowlist.DesignatedRecipientSet(W, B, true);
        t.setAllowed(W, B, true);
        vm.stopPrank();
        assertTrue(t.classAllows(W, A, B));
        assertTrue(t.classAllows(W, address(0x1234), B));
        assertFalse(t.classAllows(W, A, A));
        assertTrue(t.classAllows("c", A, A));
    }
}

contract Errors_BothStack is ErrorsBase, TargetBothStack {}

contract Errors_BothSorted is ErrorsBase, TargetBothSorted {}

contract Errors_BothStackTight is ErrorsBase, TargetBothStackTight {}

contract Errors_BothSortedTight is ErrorsBase, TargetBothSortedTight {}

contract Errors_BothConsolStack is ErrorsBase, TargetBothConsolStack {}

contract Errors_BothConsolSorted is ErrorsBase, TargetBothConsolSorted {}

// The second rule ("best fit in a bounded window").

contract Errors_BothStackWindow is ErrorsBase, TargetBothStackWindow {}

contract Errors_BothStackWindowTight is ErrorsBase, TargetBothStackWindowTight {}

contract Errors_BothConsolStackWindow is ErrorsBase, TargetBothConsolStackWindow {}

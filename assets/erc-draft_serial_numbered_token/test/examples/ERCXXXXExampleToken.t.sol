// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERCXXXXExampleToken} from "../../contracts/examples/ERCXXXXExampleToken.sol";
import {IERCXXXX} from "../../contracts/spec/IERCXXXX.sol";
import {IERCXXXXFreezable} from "../../contracts/spec/IERCXXXXFreezable.sol";
import {IERCXXXXClassified} from "../../contracts/spec/IERCXXXXClassified.sol";
import {IERCXXXXAcceptance} from "../../contracts/spec/IERCXXXXAcceptance.sol";
import {AcceptAllReceiver, ZeroReturnReceiver} from "../mocks/AcceptanceCheckers.sol";

/// @dev Touches each feature of the example token once. Nothing is minted in setUp, so the serials of
///      every test start at 0.
contract ERCXXXXExampleTokenTest is Test {
    ERCXXXXExampleToken internal t;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal merchant = makeAddr("merchant"); // the permitted recipient of VOUCHER

    bytes32 internal constant COURT = "court-order";
    bytes32 internal constant VOUCHER = "voucher";
    /// @dev The key of the frozen pile in the reference implementation (an implementation detail).
    bytes32 internal constant FROZEN_PILE = keccak256("ERCXXXX.pile.frozen");

    function setUp() public {
        t = new ERCXXXXExampleToken("Example Serial Token", "EST", admin);
        vm.startPrank(admin);
        t.setReasonInfo(COURT, "Court order", "ipfs://court-order");
        t.defineAllowlistClass(VOUCHER, "Voucher", "");
        t.setPermittedRecipient(VOUCHER, merchant, true);
        vm.stopPrank();
    }

    function test_MetadataAndInterfaces() public view {
        assertEq(t.name(), "Example Serial Token");
        assertEq(t.symbol(), "EST");
        assertEq(t.decimals(), 18);
        assertEq(t.admin(), admin);
        assertEq(t.serialsIssued(), 0);

        assertTrue(t.supportsInterface(0x01ffc9a7)); // ERC-165
        assertTrue(t.supportsInterface(type(IERCXXXX).interfaceId));
        assertTrue(t.supportsInterface(type(IERCXXXXFreezable).interfaceId));
        assertTrue(t.supportsInterface(type(IERCXXXXClassified).interfaceId));
        // The acceptance check identifier is the selector of ERCXXXXTransferRefused.
        assertEq(IERCXXXX.ERCXXXXTransferRefused.selector, bytes4(0x29543499));
        assertTrue(t.supportsInterface(0x29543499));
        // The acceptance interface is implemented by receiving contracts, not by the token.
        assertEq(type(IERCXXXXAcceptance).interfaceId, bytes4(0x4689efd4));
        assertFalse(t.supportsInterface(0x4689efd4));
        assertFalse(t.supportsInterface(0xffffffff));
    }

    function test_MintAndTransferByAmount() public {
        vm.startPrank(admin);
        assertEq(t.mint(alice, 100), 0); // [0, 100)
        assertEq(t.mint(bob, 50), 100); // [100, 150)
        assertEq(t.mint(alice, 30), 150); // [150, 180)
        vm.stopPrank();
        assertEq(t.sliceCount(alice), 2);
        _assertSlice(alice, 0, 0, 100);
        _assertSlice(alice, 1, 150, 30);

        // The default selection rule takes from the slice received last, from its high end.
        vm.prank(alice);
        assertTrue(t.transfer(carol, 40));
        assertEq(t.balanceOf(alice), 90);
        assertEq(t.balanceOf(carol), 40);
        assertEq(t.sliceCount(alice), 1);
        _assertSlice(alice, 0, 0, 90);
        assertEq(t.sliceCount(carol), 2);
        _assertSlice(carol, 0, 150, 30);
        _assertSlice(carol, 1, 90, 10);
    }

    function test_TransferSlices() public {
        vm.prank(admin);
        t.mint(alice, 100);

        vm.prank(alice);
        assertTrue(t.transferSlices(bob, _pair(10, 50), _pair(5, 10)));
        assertEq(t.balanceOf(alice), 85);
        assertEq(t.balanceOf(bob), 15);
        assertEq(t.sliceCount(alice), 3);
        _assertSlice(alice, 0, 0, 10);
        _assertSlice(alice, 1, 15, 35);
        _assertSlice(alice, 2, 60, 40);
        assertEq(t.sliceCount(bob), 2);
        _assertSlice(bob, 0, 10, 5);
        _assertSlice(bob, 1, 50, 10);

        vm.expectRevert(abi.encodeWithSelector(IERCXXXX.ERCXXXXNotHeld.selector, alice, 10, 5));
        vm.prank(alice);
        t.transferSlices(bob, _one(10), _one(5));
    }

    function test_FreezeAndUnfreeze() public {
        vm.prank(admin);
        t.mint(alice, 100);

        vm.expectRevert(abi.encodeWithSelector(ERCXXXXExampleToken.NotAdmin.selector, bob));
        vm.prank(bob);
        t.freezeSlice(20, 10, COURT);

        vm.expectEmit(address(t));
        emit IERCXXXXFreezable.SliceFrozen(COURT, 20, 10);
        vm.prank(admin);
        t.freezeSlice(20, 10, COURT);

        _assertFrozenRun(20, true, 10);
        _assertFrozenRun(0, false, 20);
        assertEq(t.frozenBalanceOf(alice), 10);
        assertEq(t.transferableBalanceOf(alice, bob), 90);
        (bytes32[] memory reasons, uint256[] memory amounts) = t.freezeReasonsOf(alice);
        assertEq(reasons.length, 1);
        assertEq(reasons[0], COURT);
        assertEq(amounts[0], 10);
        (string memory name_, string memory uri) = t.freezeReasonInfo(COURT);
        assertEq(name_, "Court order");
        assertEq(uri, "ipfs://court-order");

        vm.expectRevert(
            abi.encodeWithSelector(IERCXXXX.ERCXXXXInsufficientTransferableBalance.selector, alice, bob, 91, 90)
        );
        vm.prank(alice);
        t.transfer(bob, 91);

        vm.prank(admin);
        t.unfreezeSlice(20, 10, COURT);
        assertEq(t.frozenBalanceOf(alice), 0);
        assertEq(t.transferableBalanceOf(alice, bob), 100);
        vm.prank(alice);
        t.transfer(bob, 100);
        assertEq(t.balanceOf(bob), 100);
    }

    function test_ForcedTransferOnlyByAdmin() public {
        vm.startPrank(admin);
        t.mint(alice, 100);
        t.freezeSlice(0, 10, COURT);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(ERCXXXXExampleToken.NotAdmin.selector, bob));
        vm.prank(bob);
        t.forcedTransferSlice(alice, bob, 0, 10);

        vm.expectEmit(address(t));
        emit IERCXXXXFreezable.SliceForciblyTransferred(alice, bob, 0, 10);
        vm.prank(admin);
        t.forcedTransferSlice(alice, bob, 0, 10);
        assertEq(t.balanceOf(alice), 90);
        assertEq(t.balanceOf(bob), 10);
        // The freeze stays with the serials.
        assertEq(t.frozenBalanceOf(alice), 0);
        assertEq(t.frozenBalanceOf(bob), 10);
    }

    function test_AllowlistClass() public {
        vm.startPrank(admin);
        assertEq(t.mintWithClass(alice, 40, VOUCHER), 0); // [0, 40) voucher
        t.mint(alice, 60); // [40, 100) default class
        vm.stopPrank();

        (bytes32 classId, uint256 len) = t.classRunAt(0);
        assertEq(classId, VOUCHER);
        assertEq(len, 40);
        assertTrue(t.classAllows(VOUCHER, alice, merchant));
        assertFalse(t.classAllows(VOUCHER, alice, bob));
        assertEq(t.transferableBalanceOf(alice, bob), 60);
        assertEq(t.transferableBalanceOf(alice, merchant), 100);

        vm.expectRevert(abi.encodeWithSelector(IERCXXXX.ERCXXXXNotTransferable.selector, alice, bob, 0, 10));
        vm.prank(alice);
        t.transferSlices(bob, _one(0), _one(10));

        // A payment by amount to a permitted recipient takes from the class pile first.
        vm.prank(alice);
        t.transfer(merchant, 40);
        (bytes32[] memory ids, uint256[] memory amounts) = t.classesOf(merchant);
        assertEq(ids.length, 1);
        assertEq(ids[0], VOUCHER);
        assertEq(amounts[0], 40);

        // Setting the class of held serials: [90, 100) becomes voucher.
        vm.prank(admin);
        t.setClass(90, 10, VOUCHER);
        assertEq(t.transferableBalanceOf(alice, bob), 50);
        vm.expectRevert(
            abi.encodeWithSelector(IERCXXXX.ERCXXXXInsufficientTransferableBalance.selector, alice, bob, 51, 50)
        );
        vm.prank(alice);
        t.transfer(bob, 51);
    }

    function test_AcceptanceCheck() public {
        ZeroReturnReceiver refusing = new ZeroReturnReceiver();
        AcceptAllReceiver accepting = new AcceptAllReceiver();
        vm.prank(admin);
        t.mint(alice, 100);

        vm.expectRevert(
            abi.encodeWithSelector(IERCXXXX.ERCXXXXTransferRefused.selector, alice, address(refusing), 10)
        );
        vm.prank(alice);
        t.transfer(address(refusing), 10);

        vm.prank(alice);
        assertTrue(t.transfer(address(accepting), 10));
        assertEq(t.balanceOf(address(accepting)), 10);

        // Restricted issuance does not query the recipient.
        vm.prank(admin);
        t.mint(address(refusing), 5);
        assertEq(t.balanceOf(address(refusing)), 5);
    }

    function test_ConsolidationAndFreezePropagation() public {
        vm.startPrank(admin);
        t.mint(alice, 10); // [0, 10)
        t.mint(bob, 10); // [10, 20)
        t.mint(alice, 10); // [20, 30)
        vm.stopPrank();
        assertEq(t.sliceCount(alice), 2);

        vm.prank(alice);
        assertEq(t.consolidateSlices(_pair(0, 20), _pair(10, 10)), 30);
        assertEq(t.serialsIssued(), 50);
        assertEq(t.totalSupply(), 30);
        assertEq(t.balanceOf(alice), 20);
        assertEq(t.sliceCount(alice), 1);
        _assertSlice(alice, 0, 30, 20);
        _assertConsolidatedRun(0, true, 30, 10);
        _assertConsolidatedRun(20, true, 40, 10);
        _assertConsolidatedRun(10, false, 0, 10);

        // Freezing old serials also freezes their successors.
        vm.expectEmit(address(t));
        emit IERCXXXXFreezable.SliceFrozen(COURT, 0, 10);
        vm.expectEmit(address(t));
        emit IERCXXXXFreezable.SliceFrozen(COURT, 30, 10);
        vm.prank(admin);
        t.freezeSlice(0, 10, COURT);
        _assertFrozenRun(30, true, 10);
        _assertFrozenRun(40, false, 10);
        assertEq(t.frozenBalanceOf(alice), 10);
        assertEq(t.transferableBalanceOf(alice, bob), 10);
    }

    function test_TidyByAnyone() public {
        vm.startPrank(admin);
        t.mint(alice, 100);
        t.freezeSlice(0, 50, COURT);
        vm.stopPrank();
        // Freezing does not move holdings: the frozen serials are still in the default pile.
        assertEq(t.sliceCount(alice), 1);
        (, bytes32 pile,,,) = t.serialPositionOf(alice, 0);
        assertEq(pile, bytes32(0));

        vm.prank(bob);
        assertEq(t.tidySlices(alice, bytes32(0), 10), 1);
        assertEq(t.sliceCount(alice), 2);
        _assertSlice(alice, 0, 50, 50);
        _assertSlice(alice, 1, 0, 50);
        (, pile,,,) = t.serialPositionOf(alice, 0);
        assertEq(pile, FROZEN_PILE);
        assertEq(t.balanceOf(alice), 100);
        assertEq(t.frozenBalanceOf(alice), 50);
        assertEq(t.transferableBalanceOf(alice, bob), 50);
    }

    function test_TransferAdmin() public {
        vm.expectRevert(abi.encodeWithSelector(ERCXXXXExampleToken.NotAdmin.selector, bob));
        vm.prank(bob);
        t.transferAdmin(bob);

        vm.prank(admin);
        t.transferAdmin(bob);
        assertEq(t.admin(), bob);

        vm.expectRevert(abi.encodeWithSelector(ERCXXXXExampleToken.NotAdmin.selector, admin));
        vm.prank(admin);
        t.mint(alice, 1);
    }

    // Helpers.

    function _assertSlice(address account, uint256 index, uint256 start, uint256 amount) internal view {
        (uint256 s, uint256 a) = t.sliceAt(account, index);
        assertEq(s, start, "slice start");
        assertEq(a, amount, "slice amount");
    }

    function _assertFrozenRun(uint256 serial, bool frozen, uint256 length) internal view {
        (bool f, uint256 len) = t.frozenRunAt(serial);
        assertEq(f, frozen, "frozen");
        assertEq(len, length, "frozen run length");
    }

    function _assertConsolidatedRun(uint256 serial, bool consolidated, uint256 successor, uint256 length)
        internal
        view
    {
        (bool c, uint256 s, uint256 len) = t.consolidatedRunAt(serial);
        assertEq(c, consolidated, "consolidated");
        assertEq(s, successor, "successor");
        assertEq(len, length, "consolidated run length");
    }

    function _one(uint256 x) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = x;
    }

    function _pair(uint256 x, uint256 y) internal pure returns (uint256[] memory r) {
        r = new uint256[](2);
        (r[0], r[1]) = (x, y);
    }
}

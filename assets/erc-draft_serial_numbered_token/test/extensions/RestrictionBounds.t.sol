// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {Rule} from "../presets/Presets.sol";
import "../presets/Targets.sol";

/// @dev The bounding slice shared by freezing and classification (contracts/utils/SerialBounds.sol) is only a
///      shortcut for transfers and must not change any observable result.
///      The bounding slice records serials exactly only below 2^126: for larger serials the slice gets wider, every
///      serial inside it is looked up in the step function, and the inferences "outside the slice" and "only one
///      slice" are not used. So the same sequence of operations is run starting at serial 0, near 2^126 (the upper
///      bound beyond it, the lower bound not) and at 2^127, and apart from the shift of all serials, the events,
///      holdings, balances and query results must be the same.
///      The operations cover the states of the bounding slice: classes only, both, only one slice, more than one
///      slice, the slice shrinking after unfreezing and after a return to the default class, and everything cleared.
abstract contract RestrictionBoundsBase is Test, TokenTarget {
    bytes32 internal constant SERIAL_SIG = keccak256("SliceTransferred(address,address,uint256,uint256)");
    bytes32 internal constant REASON = "reason";
    bytes32 internal constant CA = "allowlist class";
    bytes32 internal constant CB = "free class";

    address internal S = makeAddr("sender");
    address internal R = makeAddr("recipient");
    address internal M = makeAddr("allowed recipient");
    address internal X = makeAddr("other");

    ITestToken internal t;
    uint256 internal base;
    bytes internal trail;

    function _start(uint256 b) internal {
        bool hasFreeze;
        bool hasClass;
        (t, hasFreeze, hasClass,) = _deployToken(address(this));
        require(hasFreeze && hasClass, "target needs both extensions");
        t.setReasonInfo(REASON, "a reason", "");
        t.defineClass(CA, Rule.Allowlist, 0, "allowlist", "");
        t.defineClass(CB, Rule.None, 0, "free", "");
        t.setAllowed(CA, M, true);
        base = b;
        delete trail;
        if (b != 0) t.mint(X, b);
    }

    /// @dev Records the SliceTransferred events of one transfer (serials minus base).
    function _pay(address from, address to, uint256 value) internal {
        vm.recordLogs();
        vm.prank(from);
        t.transfer(to, value);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != SERIAL_SIG) continue;
            (uint256 s, uint256 a) = abi.decode(logs[i].data, (uint256, uint256));
            trail = abi.encodePacked(trail, logs[i].topics[1], logs[i].topics[2], s - base, a);
        }
    }

    /// @dev Records the holdings of the accounts (in sliceAt order) and the queries.
    function _observe() internal {
        address[3] memory who = [S, R, M];
        for (uint256 k; k < 3; ++k) {
            uint256 n = t.sliceCount(who[k]);
            trail = abi.encodePacked(trail, who[k], n, t.balanceOf(who[k]));
            for (uint256 i; i < n; ++i) {
                (uint256 s, uint256 a) = t.sliceAt(who[k], i);
                trail = abi.encodePacked(trail, s - base, a);
            }
            trail = abi.encodePacked(
                trail,
                t.transferableBalanceOf(who[k], R),
                t.transferableBalanceOf(who[k], M),
                t.frozenBalanceOf(who[k])
            );
            (bytes32[] memory ids, uint256[] memory amts) = t.classesOf(who[k]);
            trail = abi.encodePacked(trail, ids, amts);
        }
    }

    function _scenario(uint256 b) internal returns (bytes memory) {
        _start(b);
        t.mint(S, 100); // [b, b + 100)
        t.mint(X, 1);
        t.mintWithClass(S, 20, CA); // [b + 101, b + 121): classes only, one slice
        t.mint(X, 1);
        t.mint(S, 30); // [b + 122, b + 152)
        _observe();
        t.freezeSlice(b + 50, 10, REASON); // both
        _observe();
        _pay(S, R, 45);
        _pay(S, M, 5);
        _observe();
        t.unfreezeSlice(b + 50, 10, REASON); // classes only again, one slice
        _pay(S, M, 10);
        _pay(S, R, 10);
        _observe();
        t.setClass(b + 101, 20, bytes32(0)); // everything cleared
        _observe();
        t.freezeSlice(b + 10, 5, REASON); // freezes only, one slice
        _pay(S, R, 2);
        _observe();
        t.freezeSlice(b + 30, 5, REASON); // freezes only, more than one slice
        _pay(S, R, 60);
        _observe();
        t.setClass(b + 5, 3, CB); // both, more than one slice
        t.mintWithClass(S, 7, CB);
        _pay(S, R, 8);
        _observe();
        t.unfreezeSlice(b + 10, 5, REASON); // freezes down to one slice, classes more than one slice
        _pay(S, R, 6);
        _observe();
        t.unfreezeSlice(b + 30, 5, REASON);
        t.setClass(b + 5, 3, bytes32(0)); // only the slice issued with a class is left
        _pay(S, M, 3);
        _observe();
        return trail;
    }

    function test_largeSerialsBehaveTheSame() public {
        bytes memory small = _scenario(0);
        assertEq(keccak256(_scenario(1 << 127)), keccak256(small), "serials from 2^127");
        assertEq(keccak256(_scenario((1 << 126) - 60)), keccak256(small), "serials straddling 2^126");
    }
}

contract RestrictionBoundsTest_BothStack is RestrictionBoundsBase, TargetBothStack {}

contract RestrictionBoundsTest_BothSorted is RestrictionBoundsBase, TargetBothSorted {}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm, console} from "forge-std/Test.sol";
import {IERCXXXX} from "../../contracts/spec/IERCXXXX.sol";
import {Rule} from "../presets/Presets.sol";
import "../presets/Targets.sol";

/// @dev Performs at random all the operations the draft covers. The shadow model rebuilds "serial -> holder,
///      class, freezes per reason" from events alone, as an off-chain indexer would; during replay it checks the
///      event rules of the draft, and checks that operations other than forced ones move only transferable serials.
///      Before each operation the model predicts success or failure; after it, the model is compared with all the
///      views of the contract.
///      For an extension the token does not support, the corresponding operations do nothing and the corresponding
///      views are not checked.
///      Consolidation: the model records the successor of each old serial from SliceConsolidated; consolidated
///      serials are held by no one. A separate reference model (rBits) ignores freeze events: on every freeze or
///      unfreeze it takes the closure along the consolidation records from the call's arguments and rewrites the
///      bits directly; it is compared serial by serial with mBits, which is derived from events, to check that the
///      propagation, and the state it changes, are all reported by events.
///      Tokens that keep consolidation closed (clause 7 of "Consolidation" of the draft): consolidation is tried with
///      arguments that would succeed, and must revert, and not for another reason; consolidatedSpanAt is still
///      compared serial by serial, and the model has no consolidated serials.
contract ConformanceHandler is Test {
    bytes32 internal constant TRANSFER_SIG = keccak256("Transfer(address,address,uint256)");
    bytes32 internal constant SERIAL_SIG = keccak256("SliceTransferred(address,address,uint256,uint256)");
    bytes32 internal constant FORCED_SIG = keccak256("SliceForciblyTransferred(address,address,uint256,uint256)");
    bytes32 internal constant FROZEN_SIG = keccak256("SliceFrozen(bytes32,uint256,uint256)");
    bytes32 internal constant UNFROZEN_SIG = keccak256("SliceUnfrozen(bytes32,uint256,uint256)");
    bytes32 internal constant CLASS_SET_SIG = keccak256("SliceClassified(uint256,uint256,bytes32)");
    bytes32 internal constant CONSOL_SIG = keccak256("SliceConsolidated(address,uint256,uint256,uint256)");

    /// @dev Upper limit on the total number of units minted; consolidation takes up further serials, and all serials
    ///      together do not exceed MAX_SPACE.
    uint256 internal constant MAX_ISSUED = 200;
    uint256 internal constant MAX_SPACE = 400;
    bytes32 internal constant CA = "allowlist class";
    bytes32 internal constant CL = "lock class";
    bytes32 internal constant CN = "label class";

    ITestToken public token;
    bool public hasFreeze;
    bool public hasClass;
    /// @dev This implementation's own hinted forced operations and tidying function; a token under test need not have
    ///      them.
    bool public hasHints;
    bool public hasTidy;
    bool public hasConsol;
    bool internal initialized;
    address[] internal actors;
    address internal spender = address(0xBEEF);
    address internal outsider = address(0xCAFE);
    bytes32[3] internal reasons = [bytes32("r1"), bytes32("r2"), bytes32("r3")];
    uint64 internal unlockTime;
    mapping(address => bool) internal allowedMirror;

    // Shadow model, updated only from events.
    uint256 public mIssued;
    mapping(uint256 => address) internal mHolder;
    mapping(uint256 => bool) internal mDestroyed;
    mapping(uint256 => bytes32) internal mClass;
    mapping(uint256 => uint8) internal mBits; // bit i: frozen for reasons[i]
    uint256 public mMinted;
    mapping(uint256 => bool) internal mConsolidated;
    mapping(uint256 => uint256) internal mSucc;
    mapping(uint256 => uint8) internal rBits; // reference model: call arguments along the records, not freeze events
    bool internal inForced;
    bool internal inConsol;

    // Coverage statistics
    uint256 public okMoves;
    uint256 public failedMoves;
    uint256 public okSerialMoves;
    uint256 public okForced;
    uint256 public okHinted;
    uint256 public tidyMoves;
    uint256 public okConsol;
    uint256 public failedConsol;
    uint256 public consolFrozenRefused;
    uint256 public consolClassRefused;
    uint256 public closedConsolRefused;
    uint256 public maxGeneration;

    constructor(ITestToken token_, bool freeze_, bool class_, bool consol_) {
        token = token_;
        hasFreeze = freeze_;
        hasClass = class_;
        for (uint256 i; i < 4; ++i) {
            actors.push(address(uint160(0xA000 + i)));
        }
        unlockTime = uint64(block.timestamp + 1000);
        (bool ok,) = address(token_).staticcall(abi.encodeCall(ITestToken.serialPositionOf, (outsider, 0)));
        hasHints = ok;
        (ok,) = address(token_).call(abi.encodeCall(ITestToken.tidySlices, (outsider, bytes32(0), 0)));
        hasTidy = ok;
        hasConsol = consol_;
    }

    /// @dev Called after this contract has become the token's admin.
    function init() external {
        if (initialized) return; // the invariant test also calls it at random
        initialized = true;
        if (hasFreeze) {
            for (uint256 i; i < 3; ++i) {
                token.setReasonInfo(reasons[i], "a reason", "");
            }
        }
        if (hasClass) {
            token.defineClass(CA, Rule.Allowlist, 0, "allowlist", "");
            token.defineClass(CL, Rule.LockUntil, unlockTime, "locked", "");
            token.defineClass(CN, Rule.None, 0, "label", "");
        }
        vm.prank(actors[0]);
        token.approve(actors[3], 12345);
        vm.recordLogs();
    }

    // ───────────────────────── Model ─────────────────────────

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _classOf(uint256 seed) internal view returns (bytes32) {
        if (!hasClass) return bytes32(0);
        uint256 k = seed % 4;
        return k == 0 ? bytes32(0) : k == 1 ? CA : k == 2 ? CL : CN;
    }

    function _allows(bytes32 c, address to) internal view returns (bool) {
        if (c == bytes32(0) || c == CN) return true;
        if (c == CA) return to == address(0) || allowedMirror[to];
        return block.timestamp >= unlockTime;
    }

    function _ok(uint256 s, address from, address to) internal view returns (bool) {
        return mHolder[s] == from && !mDestroyed[s] && mBits[s] == 0 && _allows(mClass[s], to);
    }

    function _modelTransferable(address from, address to) internal view returns (uint256 n) {
        for (uint256 s; s < mIssued; ++s) {
            if (_ok(s, from, to)) ++n;
        }
    }

    function _modelBalance(address a) internal view returns (uint256 n) {
        for (uint256 s; s < mIssued; ++s) {
            if (mHolder[s] == a && !mDestroyed[s]) ++n;
        }
    }

    /// @dev [a, b) is entirely held by from and satisfies mode: 0 transferable to to; 1 frozen.
    function _modelAll(uint256 a, uint256 b, address from, address to, uint8 mode) internal view returns (bool) {
        if (b > mIssued || a >= b) return false;
        for (uint256 s = a; s < b; ++s) {
            if (mHolder[s] != from || mDestroyed[s]) return false;
            if (mode == 0 && !_ok(s, from, to)) return false;
            if (mode == 1 && mBits[s] == 0) return false;
        }
        return true;
    }

    /// @dev The number of consecutive serials held by from starting at s; when mode is 1 they must also be frozen.
    function _heldRun(address from, uint256 s, uint8 mode) internal view returns (uint256 n) {
        while (s + n < mIssued && mHolder[s + n] == from && !mDestroyed[s + n] && (mode == 0 || mBits[s + n] != 0)) {
            ++n;
        }
    }

    /// @dev The k-th (modulo) serial that is held by from and (when mode is 1) frozen; mIssued if there is none.
    function _heldSerialWhere(address from, uint256 k, uint8 mode) internal view returns (uint256) {
        uint256 n;
        for (uint256 s; s < mIssued; ++s) {
            if (mHolder[s] == from && !mDestroyed[s] && (mode == 0 || mBits[s] != 0)) ++n;
        }
        if (n == 0) return mIssued;
        k %= n;
        for (uint256 s; s < mIssued; ++s) {
            if (mHolder[s] == from && !mDestroyed[s] && (mode == 0 || mBits[s] != 0)) {
                if (k == 0) return s;
                --k;
            }
        }
        return mIssued;
    }

    /// @dev The k-th (modulo) serial held by from; mIssued if there is none.
    function _heldSerial(address from, uint256 k) internal view returns (uint256) {
        uint256 n = _modelBalance(from);
        if (n == 0) return mIssued;
        k %= n;
        for (uint256 s; s < mIssued; ++s) {
            if (mHolder[s] == from && !mDestroyed[s]) {
                if (k == 0) return s;
                --k;
            }
        }
        return mIssued;
    }

    // ───────────────────────── Event replay ─────────────────────────

    /// @dev State during replay.
    struct Replay {
        uint256 pending;
        address pFrom;
        address pTo;
        bool has;
        address tFrom;
        address tTo;
        uint256 tValue;
        bool seenTransfer;
        uint256 forcedSum;
        bool forcedOpen;
    }

    function _sync() internal {
        _replay(vm.getRecordedLogs());
    }

    function _replay(Vm.Log[] memory logs) internal {
        Replay memory st;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory lg = logs[i];
            if (lg.emitter != address(token)) continue;
            bytes32 sig = lg.topics[0];
            if (inConsol) {
                assertTrue(sig != SERIAL_SIG && sig != TRANSFER_SIG, "consolidation emitted Transfer or SliceTransferred");
                assertTrue(sig != FROZEN_SIG && sig != UNFROZEN_SIG, "consolidation changed a freeze");
            } else {
                assertTrue(sig != CONSOL_SIG, "SliceConsolidated outside a consolidation");
            }
            if (sig == CONSOL_SIG) {
                _onConsolidated(lg);
            } else if (sig == SERIAL_SIG) {
                _onSerial(st, lg);
            } else if (sig == TRANSFER_SIG) {
                _onTransfer(st, lg);
            } else if (sig == FORCED_SIG) {
                _onForced(st, lg);
            } else if (sig == FROZEN_SIG || sig == UNFROZEN_SIG) {
                (uint256 start, uint256 amount) = abi.decode(lg.data, (uint256, uint256));
                _applyFreeze(lg.topics[1], start, amount, sig == FROZEN_SIG);
            } else if (sig == CLASS_SET_SIG) {
                (uint256 start, uint256 amount, bytes32 c) = abi.decode(lg.data, (uint256, uint256, bytes32));
                assertGt(amount, 0, "SliceClassified amount");
                assertLe(start + amount, mIssued, "SliceClassified beyond issued serials");
                for (uint256 s = start; s < start + amount; ++s) {
                    mClass[s] = c;
                }
            }
        }
        if (st.forcedOpen) assertEq(st.forcedSum, st.tValue, "SliceForciblyTransferred sum != Transfer value");
        assertFalse(st.has, "SliceTransferred not followed by Transfer");
    }

    function _onSerial(Replay memory st, Vm.Log memory lg) internal {
        address from = address(uint160(uint256(lg.topics[1])));
        address to = address(uint160(uint256(lg.topics[2])));
        (uint256 start, uint256 amount) = abi.decode(lg.data, (uint256, uint256));
        assertGt(amount, 0, "SliceTransferred amount");
        assertTrue(from != to, "SliceTransferred from == to");
        if (st.has) {
            assertEq(from, st.pFrom, "mixed from");
            assertEq(to, st.pTo, "mixed to");
        } else {
            (st.pFrom, st.pTo, st.has) = (from, to, true);
        }
        st.pending += amount;
        _applySerialTransfer(from, to, start, amount);
    }

    function _onTransfer(Replay memory st, Vm.Log memory lg) internal pure {
        if (st.forcedOpen) assertEq(st.forcedSum, st.tValue, "SliceForciblyTransferred sum != Transfer value");
        (st.forcedSum, st.forcedOpen) = (0, false);
        st.tFrom = address(uint160(uint256(lg.topics[1])));
        st.tTo = address(uint160(uint256(lg.topics[2])));
        st.tValue = abi.decode(lg.data, (uint256));
        st.seenTransfer = true;
        if (st.tFrom != st.tTo && st.tValue != 0) {
            assertTrue(st.has, "Transfer without SliceTransferred");
            assertEq(st.pFrom, st.tFrom, "SliceTransferred.from != Transfer.from");
            assertEq(st.pTo, st.tTo, "SliceTransferred.to != Transfer.to");
            assertEq(st.pending, st.tValue, "SliceTransferred sum != Transfer value");
        } else {
            assertFalse(st.has, "SliceTransferred for a self or zero transfer");
        }
        (st.pending, st.has) = (0, false);
    }

    function _onForced(Replay memory st, Vm.Log memory lg) internal view {
        assertTrue(inForced, "SliceForciblyTransferred outside a forced operation");
        assertTrue(st.seenTransfer, "SliceForciblyTransferred before any Transfer");
        assertEq(address(uint160(uint256(lg.topics[1]))), st.tFrom, "Forced.from");
        assertEq(address(uint160(uint256(lg.topics[2]))), st.tTo, "Forced.to");
        (, uint256 amount) = abi.decode(lg.data, (uint256, uint256));
        st.forcedSum += amount;
        st.forcedOpen = true;
    }

    /// @dev The old serials are all held by account and not frozen; the new serials immediately follow the issued
    ///      ones and are held by account; their class is first recorded as the default class and changed by the
    ///      SliceClassified events that follow.
    function _onConsolidated(Vm.Log memory lg) internal {
        address account = address(uint160(uint256(lg.topics[1])));
        (uint256 start, uint256 newStart, uint256 amount) = abi.decode(lg.data, (uint256, uint256, uint256));
        assertGt(amount, 0, "SliceConsolidated amount");
        assertEq(newStart, mIssued, "new serials must follow the issued ones");
        for (uint256 k; k < amount; ++k) {
            uint256 o = start + k;
            assertLt(o, newStart, "consolidated an unissued serial");
            assertEq(mHolder[o], account, "consolidated a serial the account does not hold");
            assertFalse(mDestroyed[o], "consolidated a destroyed serial");
            assertFalse(mConsolidated[o], "consolidated a serial twice");
            assertEq(mBits[o], 0, "consolidated a frozen serial");
            uint256 n = newStart + k;
            mConsolidated[o] = true;
            mSucc[o] = n;
            mHolder[o] = address(0);
            mHolder[n] = account;
            mClass[n] = bytes32(0);
        }
        mIssued = newStart + amount;
    }

    function _applySerialTransfer(address from, address to, uint256 start, uint256 amount) internal {
        for (uint256 s = start; s < start + amount; ++s) {
            if (from == address(0)) {
                assertEq(s, mIssued, "serials must be issued consecutively");
                ++mIssued;
                ++mMinted;
            } else {
                assertEq(mHolder[s], from, "serial moved by a non-holder");
                assertFalse(mDestroyed[s], "destroyed serial moved");
                if (inForced) {
                    assertTrue(mBits[s] != 0, "forced operation on an unfrozen serial");
                } else {
                    assertEq(mBits[s], 0, "frozen serial moved by a non-forced operation");
                    assertTrue(_allows(mClass[s], to), "class rule broken by a non-forced operation");
                }
            }
            mHolder[s] = to;
            if (to == address(0)) mDestroyed[s] = true;
        }
    }

    function _applyFreeze(bytes32 reason, uint256 start, uint256 amount, bool frozen) internal {
        assertGt(amount, 0, "freeze event amount");
        assertLe(start + amount, mIssued, "freeze event beyond issued serials");
        uint8 bit;
        for (uint256 i; i < 3; ++i) {
            if (reasons[i] == reason) bit = uint8(1 << i);
        }
        assertTrue(bit != 0, "unknown reason");
        for (uint256 s = start; s < start + amount; ++s) {
            mBits[s] = frozen ? mBits[s] | bit : mBits[s] & ~bit;
        }
    }

    function _discard() internal {
        vm.getRecordedLogs();
    }

    // ───────────────────────── Operations ─────────────────────────

    function mint(uint256 toSeed, uint256 amount, uint256 classSeed) external {
        if (mMinted >= MAX_ISSUED || mIssued >= MAX_SPACE) return;
        uint256 room = MAX_ISSUED - mMinted;
        if (MAX_SPACE - mIssued < room) room = MAX_SPACE - mIssued;
        amount = bound(amount, 1, room < 20 ? room : 20);
        bytes32 c = _classOf(classSeed);
        if (c == bytes32(0)) token.mint(_actor(toSeed), amount);
        else token.mintWithClass(_actor(toSeed), amount, c);
        _sync();
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 bal = token.balanceOf(from);
        amount = bound(amount, 0, bal + 2);
        uint256 tr = _modelTransferable(from, to);
        vm.prank(from);
        try token.transfer(to, amount) {
            assertTrue(amount <= tr, "transfer beyond transferable succeeded");
            ++okMoves;
            _sync();
        } catch (bytes memory err) {
            assertTrue(amount > tr, "transfer within transferable reverted");
            if (amount <= bal) _expectInsufficient(err, from, to, amount, tr);
            ++failedMoves;
            _discard();
        }
    }

    function transferFrom(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 bal = token.balanceOf(from);
        amount = bound(amount, 0, bal + 2);
        uint256 tr = _modelTransferable(from, to);
        vm.prank(from);
        token.approve(spender, amount);
        vm.prank(spender);
        try token.transferFrom(from, to, amount) {
            assertTrue(amount <= tr, "transferFrom beyond transferable succeeded");
            ++okMoves;
            _sync();
        } catch (bytes memory err) {
            assertTrue(amount > tr, "transferFrom within transferable reverted");
            if (amount <= bal) _expectInsufficient(err, from, to, amount, tr);
            ++failedMoves;
            _discard();
        }
    }

    function burn(uint256 fromSeed, uint256 amount, bool viaAllowance) external {
        address from = _actor(fromSeed);
        uint256 bal = token.balanceOf(from);
        amount = bound(amount, 0, bal + 2);
        uint256 tr = _modelTransferable(from, address(0));
        bool ok;
        bytes memory err;
        if (viaAllowance) {
            vm.prank(from);
            token.approve(spender, amount);
            vm.prank(spender);
            try token.burnFrom(from, amount) {
                ok = true;
            } catch (bytes memory e) {
                err = e;
            }
        } else {
            vm.prank(from);
            try token.burn(amount) {
                ok = true;
            } catch (bytes memory e) {
                err = e;
            }
        }
        assertEq(ok, amount <= tr, "burn outcome");
        if (ok) {
            ++okMoves;
            _sync();
        } else {
            if (amount <= bal) _expectInsufficient(err, from, address(0), amount, tr);
            _discard();
        }
    }

    function _expectInsufficient(bytes memory err, address from, address to, uint256 amount, uint256 tr)
        internal
        pure
    {
        assertEq(
            keccak256(err),
            keccak256(
                abi.encodeWithSelector(
                    IERCXXXX.ERCXXXXInsufficientTransferableBalance.selector, from, to, amount, tr
                )
            ),
            "wrong error for insufficient transferable balance"
        );
    }

    /// @dev Generates one or two slices. Half the time it starts at a serial that from actually holds, the other half
    ///      at random; the second slice sometimes overlaps.
    function _ranges(address from, uint256 seed)
        internal
        view
        returns (uint256[] memory starts, uint256[] memory amounts, bool ordered)
    {
        uint256 a;
        uint256 len;
        if (seed % 4 != 0) {
            // Most of the time: take from a run of held serials, no longer than that run.
            a = _heldSerial(from, seed >> 8);
            uint256 run = a < mIssued ? _heldRun(from, a, 0) : 0;
            len = 1 + (seed >> 40) % (run == 0 ? 6 : (run < 6 ? run : 6));
        } else {
            a = (seed >> 8) % (mIssued + 5);
            len = 1 + (seed >> 40) % 6;
        }
        if ((seed >> 60) % 3 == 0) {
            starts = new uint256[](2);
            amounts = new uint256[](2);
            uint256 a2 = a + len + (seed >> 70) % 4;
            if ((seed >> 110) % 2 == 0) {
                // the second slice is also taken from held serials, and placed after the first
                uint256 h = _heldSerial(from, seed >> 120);
                if (h >= a + len) a2 = h;
            }
            if ((seed >> 80) % 5 == 0) a2 = a + (seed >> 90) % (len + 1); // may overlap or be out of order
            (starts[0], starts[1]) = (a, a2);
            (amounts[0], amounts[1]) = (len, 1 + (seed >> 100) % 4);
            ordered = a2 >= a + len;
        } else {
            starts = new uint256[](1);
            amounts = new uint256[](1);
            (starts[0], amounts[0]) = (a, len);
            ordered = true;
        }
    }

    function _predictSpecified(address from, address to, uint256[] memory starts, uint256[] memory amounts, bool ordered)
        internal
        view
        returns (bool)
    {
        if (!ordered) return false;
        for (uint256 k; k < starts.length; ++k) {
            if (!_modelAll(starts[k], starts[k] + amounts[k], from, to, 0)) return false;
        }
        return true;
    }

    function transferSlices(uint256 fromSeed, uint256 toSeed, uint256 seed) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        (uint256[] memory starts, uint256[] memory amounts, bool ordered) = _ranges(from, seed);
        bool want = _predictSpecified(from, to, starts, amounts, ordered);
        vm.prank(from);
        try token.transferSlices(to, starts, amounts) {
            assertTrue(want, "transferSlices succeeded unexpectedly");
            ++okSerialMoves;
            _sync();
        } catch {
            assertFalse(want, "transferSlices reverted unexpectedly");
            _discard();
        }
    }

    function burnSlices(uint256 fromSeed, uint256 seed) external {
        address from = _actor(fromSeed);
        (uint256[] memory starts, uint256[] memory amounts, bool ordered) = _ranges(from, seed);
        bool want = _predictSpecified(from, address(0), starts, amounts, ordered);
        vm.prank(from);
        try token.burnSlices(starts, amounts) {
            assertTrue(want, "burnSlices succeeded unexpectedly");
            ++okSerialMoves;
            _sync();
        } catch {
            assertFalse(want, "burnSlices reverted unexpectedly");
            _discard();
        }
    }

    function _span(uint256 start, uint256 amount, uint256 maxLen) internal view returns (uint256, uint256) {
        start = bound(start, 0, mIssued - 1);
        uint256 room = mIssued - start;
        amount = bound(amount, 1, room < maxLen ? room : maxLen);
        return (start, amount);
    }

    function freeze(uint256 reasonSeed, uint256 start, uint256 amount, bool unfreeze_) external {
        if (mIssued == 0 || !hasFreeze) return;
        (start, amount) = _span(start, amount, 40);
        bytes32 reason = reasons[reasonSeed % 3];
        if (unfreeze_) token.unfreezeSlice(start, amount, reason);
        else token.freezeSlice(start, amount, reason);
        _sync();
        _referenceFreeze(uint8(1 << (reasonSeed % 3)), start, amount, !unfreeze_);
    }

    /// @dev Reference model: rewrites bit on [start, start + amount) and on every successor reachable along the
    ///      consolidation records. A successor is always larger than its old serial, so one pass in ascending order
    ///      of serial finds the closure.
    function _referenceFreeze(uint8 bit, uint256 start, uint256 amount, bool frozen) internal {
        bool[] memory hit = new bool[](mIssued);
        for (uint256 s = start; s < start + amount; ++s) {
            hit[s] = true;
        }
        uint256 gen;
        for (uint256 s = start; s < mIssued; ++s) {
            if (!hit[s]) continue;
            rBits[s] = frozen ? rBits[s] | bit : rBits[s] & ~bit;
            if (mConsolidated[s]) hit[mSucc[s]] = true;
        }
        // Record the number of generations passed through (coverage statistics)
        for (uint256 s = start; s < start + amount; ++s) {
            uint256 g;
            for (uint256 x = s; mConsolidated[x]; x = mSucc[x]) {
                ++g;
            }
            if (g > gen) gen = g;
        }
        if (gen > maxGeneration) maxGeneration = gen;
    }

    /// @dev Slices to consolidate: most of the time 1 to 4 slices picked from the runs held by from (sometimes only
    ///      part of a run), given in ascending order; otherwise _ranges (random, possibly not held, overlapping or
    ///      out of order).
    function _consolRanges(address from, uint256 seed)
        internal
        view
        returns (uint256[] memory starts, uint256[] memory amounts, bool ordered)
    {
        if (seed % 5 == 0) return _ranges(from, seed >> 3);
        uint256 want = 1 + (seed >> 3) % 4;
        starts = new uint256[](want);
        amounts = new uint256[](want);
        uint256 m;
        uint256 r = seed;
        for (uint256 s; s < mIssued && m < want;) {
            if (mHolder[s] != from || mDestroyed[s]) {
                ++s;
                continue;
            }
            uint256 run = _heldRun(from, s, 0);
            r = uint256(keccak256(abi.encode(r)));
            if (r % 3 != 0) {
                uint256 off = (r >> 8) % 4 == 0 ? (r >> 16) % run : 0;
                uint256 len = (r >> 24) % 3 == 0 ? 1 + (r >> 32) % (run - off) : run - off;
                (starts[m], amounts[m]) = (s + off, len);
                ++m;
            }
            s += run;
        }
        // When no slice was picked, take the first run of held serials
        if (m == 0) {
            uint256 h = _heldSerial(from, 0);
            if (h < mIssued) {
                (starts[0], amounts[0]) = (h, _heldRun(from, h, 0));
                m = 1;
            }
        }
        assembly ("memory-safe") {
            mstore(starts, m)
            mstore(amounts, m)
        }
        ordered = m != 0;
    }

    function consolidate(uint256 fromSeed, uint256 seed) external {
        address from = _actor(fromSeed);
        // Most of the time switch to an account that has holdings (the call sequences of the invariant test are
        // short, and most accounts do not hold anything yet)
        for (uint256 i; i < actors.length && seed % 5 != 0 && _modelBalance(from) == 0; ++i) {
            from = _actor(fromSeed % actors.length + i + 1);
        }
        (uint256[] memory starts, uint256[] memory amounts, bool ordered) = _consolRanges(from, seed);
        uint256 v;
        for (uint256 k; k < amounts.length; ++k) {
            v += amounts[k];
        }
        if (mIssued + v > MAX_SPACE) return;
        // Prediction: valid arguments, all held by from; then no serial may be frozen, and every class must equal
        // that of starts[0].
        bool held = ordered && _predictHeld(from, starts, amounts);
        (bool frozenHit, bool classHit) = held ? _consolBlockers(starts, amounts) : (false, false);
        bool want = held && !frozenHit && !classHit;
        uint256 n = mIssued;
        bytes32 c0 = held ? mClass[starts[0]] : bytes32(0);
        _discard();
        if (!hasConsol) return _consolidateClosed(from, starts, amounts, want);
        vm.prank(from);
        try token.consolidateSlices(starts, amounts) returns (uint256 newStart) {
            assertTrue(want, "consolidateSlices succeeded unexpectedly");
            assertEq(newStart, n, "consolidateSlices return value");
            Vm.Log[] memory logs = vm.getRecordedLogs();
            _checkConsolEvents(logs, from, starts, amounts, n);
            inConsol = true;
            _replay(logs);
            inConsol = false;
            for (uint256 s = n; s < n + v; ++s) {
                assertEq(mClass[s], c0, "new serials must keep the class");
            }
            assertEq(mIssued, n + v, "serialsIssued grows by v");
            ++okConsol;
        } catch (bytes memory err) {
            assertFalse(want, "consolidateSlices reverted unexpectedly");
            if (held) _expectNotConsolidatable(err, from, starts, amounts);
            if (frozenHit) ++consolFrozenRefused;
            else if (classHit) ++consolClassRefused;
            ++failedConsol;
            _discard();
        }
    }

    /// @dev Consolidation closed: every call reverts and emits no events; when the arguments would otherwise succeed,
    ///      the revert must not have another cause.
    function _consolidateClosed(address from, uint256[] memory starts, uint256[] memory amounts, bool want) internal {
        vm.prank(from);
        try token.consolidateSlices(starts, amounts) returns (uint256) {
            fail("consolidateSlices succeeded on a token that keeps consolidation closed");
        } catch (bytes memory err) {
            if (want) {
                assertEq(closedConsolidationErrorProblem(err), "", "closed consolidation reverted for another reason");
                ++closedConsolRefused;
            }
        }
        assertEq(vm.getRecordedLogs().length, 0, "a closed consolidation emitted events");
    }

    function _predictHeld(address from, uint256[] memory starts, uint256[] memory amounts)
        internal
        view
        returns (bool)
    {
        for (uint256 k; k < starts.length; ++k) {
            uint256 e = starts[k] + amounts[k];
            if (e > mIssued || amounts[k] == 0) return false;
            for (uint256 s = starts[k]; s < e; ++s) {
                if (mHolder[s] != from || mDestroyed[s]) return false;
            }
        }
        return true;
    }

    function _consolBlockers(uint256[] memory starts, uint256[] memory amounts)
        internal
        view
        returns (bool frozenHit, bool classHit)
    {
        bytes32 c0 = mClass[starts[0]];
        for (uint256 k; k < starts.length; ++k) {
            for (uint256 s = starts[k]; s < starts[k] + amounts[k]; ++s) {
                if (mBits[s] != 0) frozenHit = true;
                if (mClass[s] != c0) classHit = true;
            }
        }
    }

    /// @dev The recommended error: ERCXXXXNotConsolidatable(from, starts[i], amounts[i]), where slice i contains a
    ///      serial that is frozen or whose class differs from that of starts[0].
    function _expectNotConsolidatable(
        bytes memory err,
        address from,
        uint256[] memory starts,
        uint256[] memory amounts
    ) internal view {
        assertEq(bytes4(err), IERCXXXX.ERCXXXXNotConsolidatable.selector, "wrong error");
        bytes memory args = new bytes(err.length - 4);
        for (uint256 i; i < args.length; ++i) {
            args[i] = err[i + 4];
        }
        (address a, uint256 s0, uint256 len) = abi.decode(args, (address, uint256, uint256));
        assertEq(a, from, "NotConsolidatable.account");
        bool found;
        bytes32 c0 = mClass[starts[0]];
        for (uint256 k; k < starts.length; ++k) {
            if (starts[k] != s0 || amounts[k] != len) continue;
            for (uint256 s = s0; s < s0 + len; ++s) {
                if (mBits[s] != 0 || mClass[s] != c0) found = true;
            }
        }
        assertTrue(found, "NotConsolidatable does not name a blocking slice");
    }

    /// @dev Exactly one SliceConsolidated(from, starts[i], n + p_i, amounts[i]) for each i, in the order of i;
    ///      all SliceClassified events come after them.
    function _checkConsolEvents(
        Vm.Log[] memory logs,
        address from,
        uint256[] memory starts,
        uint256[] memory amounts,
        uint256 n
    ) internal view {
        uint256 k;
        uint256 p;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(token)) continue;
            if (logs[i].topics[0] == CLASS_SET_SIG) {
                assertEq(k, starts.length, "SliceClassified before the last SliceConsolidated");
            }
            if (logs[i].topics[0] != CONSOL_SIG) continue;
            assertLt(k, starts.length, "too many SliceConsolidated");
            assertEq(address(uint160(uint256(logs[i].topics[1]))), from, "SliceConsolidated.account");
            (uint256 s, uint256 ns, uint256 a) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            assertEq(s, starts[k], "SliceConsolidated.start");
            assertEq(ns, n + p, "SliceConsolidated.newStart");
            assertEq(a, amounts[k], "SliceConsolidated.amount");
            p += a;
            ++k;
        }
        assertEq(k, starts.length, "one SliceConsolidated per slice");
    }

    function setClass(uint256 start, uint256 amount, uint256 classSeed) external {
        if (mIssued == 0 || !hasClass) return;
        (start, amount) = _span(start, amount, 30);
        token.setClass(start, amount, _classOf(classSeed));
        _sync();
    }

    function setAllowed(uint256 actorSeed, bool allowed) external {
        if (!hasClass) return;
        address a = _actor(actorSeed);
        token.setAllowed(CA, a, allowed);
        allowedMirror[a] = allowed;
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 600));
    }

    /// @dev Half the time it starts at a serial that from actually holds.
    function _forcedSpan(address from, uint256 start, uint256 amount) internal view returns (uint256, uint256) {
        if (start % 4 != 0) {
            // Most of the time: take from a run that is held and frozen
            start = _heldSerialWhere(from, start >> 2, 1);
            if (start < mIssued) {
                uint256 run = _heldRun(from, start, 1);
                amount = bound(amount, 1, run < 8 ? run : 8);
                return (start, amount);
            }
        }
        start = (start >> 2) % mIssued;
        uint256 room = mIssued - start;
        amount = bound(amount, 1, room < 8 ? room : 8);
        return (start, amount);
    }

    function forcedTransfer(uint256 fromSeed, uint256 toSeed, uint256 start, uint256 amount) external {
        if (mIssued == 0 || !hasFreeze) return;
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        if (from == to) to = _actor(toSeed % actors.length + 1);
        (start, amount) = _forcedSpan(from, start, amount);
        bool want = _modelAll(start, start + amount, from, to, 1);
        inForced = true;
        try token.forcedTransferSlice(from, to, start, amount) {
            assertTrue(want, "forcedTransferSlice succeeded unexpectedly");
            ++okForced;
            _sync();
        } catch {
            assertFalse(want, "forcedTransferSlice reverted unexpectedly");
            _discard();
        }
        inForced = false;
    }

    function destroy(uint256 fromSeed, uint256 start, uint256 amount) external {
        if (mIssued == 0 || !hasFreeze) return;
        address from = _actor(fromSeed);
        (start, amount) = _forcedSpan(from, start, amount);
        bool want = _modelAll(start, start + amount, from, address(0), 1);
        inForced = true;
        try token.destroySlice(from, start, amount) {
            assertTrue(want, "destroySlice succeeded unexpectedly");
            ++okForced;
            _sync();
        } catch {
            assertFalse(want, "destroySlice reverted unexpectedly");
            _discard();
        }
        inForced = false;
    }

    /// @dev The hint for the hinted forced operations. Most of the time it is the position read with
    ///      serialPositionOf, and the expected outcome also requires the named slice to lie entirely within the slice
    ///      read; a quarter of the time it gives a pile that does not exist, and a quarter of the time the index read
    ///      plus 1; both of these always revert (slices are pairwise disjoint, so the next slice cannot contain
    ///      start). Also compares serialPositionOf with the model.
    function _hint(address from, uint256 start, uint256 amount, uint256 hintSeed)
        internal
        view
        returns (bool fits, bytes32 pile, uint256 index)
    {
        (bool held, bytes32 p, uint256 i, uint256 rs, uint256 ra) = token.serialPositionOf(from, start);
        assertEq(held, mHolder[start] == from && !mDestroyed[start], "serialPositionOf.held");
        if (held) assertTrue(rs <= start && start - rs < ra, "serialPositionOf range does not contain the serial");
        uint256 mode = hintSeed % 4;
        if (mode == 0) return (false, bytes32("no such pile"), i);
        if (mode == 1) return (false, p, i + 1);
        return (held && start + amount <= rs + ra, p, i);
    }

    function forcedTransferAt(uint256 fromSeed, uint256 toSeed, uint256 start, uint256 amount, uint256 hintSeed)
        external
    {
        if (mIssued == 0 || !hasFreeze || !hasHints) return;
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        if (from == to) to = _actor(toSeed % actors.length + 1);
        (start, amount) = _forcedSpan(from, start, amount);
        (bool fits, bytes32 pile, uint256 index) = _hint(from, start, amount, hintSeed);
        bool want = fits && _modelAll(start, start + amount, from, to, 1);
        inForced = true;
        try token.forcedTransferSliceAt(from, to, start, amount, pile, index) {
            assertTrue(want, "forcedTransferSliceAt succeeded unexpectedly");
            ++okForced;
            ++okHinted;
            _sync();
        } catch {
            assertFalse(want, "forcedTransferSliceAt reverted unexpectedly");
            _discard();
        }
        inForced = false;
    }

    function destroyAt(uint256 fromSeed, uint256 start, uint256 amount, uint256 hintSeed) external {
        if (mIssued == 0 || !hasFreeze || !hasHints) return;
        address from = _actor(fromSeed);
        (start, amount) = _forcedSpan(from, start, amount);
        (bool fits, bytes32 pile, uint256 index) = _hint(from, start, amount, hintSeed);
        bool want = fits && _modelAll(start, start + amount, from, address(0), 1);
        inForced = true;
        try token.destroySliceAt(from, start, amount, pile, index) {
            assertTrue(want, "destroySliceAt succeeded unexpectedly");
            ++okForced;
            ++okHinted;
            _sync();
        } catch {
            assertFalse(want, "destroySliceAt reverted unexpectedly");
            _discard();
        }
        inForced = false;
    }

    /// @dev Anyone tidies any pile of any account (the default pile, the frozen pile, the three class piles, or a
    ///      pile that does not exist), with maxMoves 0, 1 or very large. It must emit no events and move no more
    ///      slices than the limit; after it moves slices, all views are compared (the serials held, the balances, the
    ///      transferable balances, and the freeze and class queries must not change).
    function tidy(uint256 accountSeed, uint256 maxSeed) external {
        if (!hasTidy) return;
        address a = _actor(accountSeed);
        uint256 k = maxSeed % 3;
        uint256 maxMoves = k == 0 ? 0 : k == 1 ? 1 : 1000;
        // Misplaced slices are mostly in the default pile (frozen or given a class after they were received), so
        // half the time pick the default pile.
        bytes32[8] memory piles =
            [bytes32(0), bytes32(0), bytes32(0), keccak256("ERCXXXX.pile.frozen"), CA, CL, CN, bytes32("nope")];
        bytes32 pile = piles[(maxSeed >> 8) % 8];
        _discard();
        vm.prank(outsider);
        uint256 moved = token.tidySlices(a, pile, maxMoves);
        assertLe(moved, maxMoves, "tidySlices moved more than maxMoves");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].emitter != address(token), "tidySlices emitted an event");
        }
        if (moved != 0) {
            tidyMoves += moved;
            // Tidying only moves slices between a's own piles, changes no state of any serial and touches no other
            // account, so only a's views are compared.
            // All views are compared every 60 steps; comparing all of them after every tidying would bring the
            // combinations with consolidation close to the gas limit of a single test in the random walk.
            this.checkAccountViews(a);
        }
    }

    // ───────────────────────── View comparison ─────────────────────────

    function checkViews() external view {
        assertEq(token.serialsIssued(), mIssued, "serialsIssued");
        uint256 live;
        uint256 held;
        for (uint256 s; s < mIssued; ++s) {
            // Each issued serial is exactly one of three: held by some account, destroyed, or consolidated.
            bool h = mHolder[s] != address(0) && !mDestroyed[s];
            uint256 kinds = (h ? 1 : 0) + (mDestroyed[s] ? 1 : 0) + (mConsolidated[s] ? 1 : 0);
            assertEq(kinds, 1, "held, destroyed and consolidated serials must tile the issued ones");
            if (!mDestroyed[s] && !mConsolidated[s]) ++live;
            if (h) ++held;
        }
        assertEq(live, held, "live serials must all be held");
        assertEq(token.totalSupply(), live, "totalSupply");
        assertEq(token.allowance(actors[0], actors[3]), 12345, "unrelated allowance changed");
        for (uint256 i; i < actors.length; ++i) {
            _checkAccount(actors[i]);
        }
        _checkSpans();
        _checkConsolidated();
        if (hasFreeze) {
            for (uint256 s; s < mIssued; ++s) {
                assertEq(mBits[s], rBits[s], "freeze events differ from propagation along the records");
            }
        }
    }

    /// @dev Compares the views of one account only (used after tidying, see tidy).
    function checkAccountViews(address a) external view {
        _checkAccount(a);
    }

    /// @dev Compares consolidatedSpanAt with the model serial by serial (this implementation returns the longest span,
    ///      shortened only when it spans more than 33 adjoining records); on a token that keeps consolidation closed
    ///      the model has no consolidated serials, and every serial should get the whole span up to the last issued
    ///      serial.
    ///      That the balances of the accounts sum to totalSupply is checked above; that no consolidated serial
    ///      appears in the enumeration of any account is checked by _checkAccount, which compares serial by serial
    ///      with mHolder.
    function _checkConsolidated() internal view {
        uint256 n = mIssued;
        uint256[] memory end = new uint256[](n);
        for (uint256 i = n; i != 0; --i) {
            uint256 s = i - 1;
            bool same = s + 1 < n && mConsolidated[s + 1] == mConsolidated[s]
                && (!mConsolidated[s] || mSucc[s + 1] == mSucc[s] + 1);
            end[s] = same ? end[s + 1] : s + 1;
        }
        for (uint256 s; s < n; ++s) {
            (bool c, uint256 succ, uint256 len) = token.consolidatedSpanAt(s);
            assertEq(c, mConsolidated[s], "consolidatedSpanAt.consolidated");
            assertEq(succ, mConsolidated[s] ? mSucc[s] : 0, "consolidatedSpanAt.successor");
            if (len != end[s] - s && mConsolidated[s]) {
                // When extending along adjoining records, this implementation reads at most 32 more records, each
                // of at least 1 serial, so a shortened span has at least 33 serials.
                assertTrue(len >= 33 && len < end[s] - s, "consolidatedSpanAt.length (capped)");
            } else {
                assertEq(len, end[s] - s, "consolidatedSpanAt.length");
            }
        }
        (bool c2, uint256 s2, uint256 l2) = token.consolidatedSpanAt(n);
        assertFalse(c2);
        assertEq(s2, 0);
        assertEq(l2, 0, "consolidatedSpanAt beyond issued");
    }

    function _checkAccount(address a) internal view {
        // Enumeration
        uint256 n = token.sliceCount(a);
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            (uint256 start, uint256 amount) = token.sliceAt(a, i);
            assertGt(amount, 0, "empty range");
            assertLe(start + amount, mIssued, "range beyond issued");
            for (uint256 s = start; s < start + amount; ++s) {
                assertEq(mHolder[s], a, "enumerated holder != model");
                assertFalse(mDestroyed[s], "enumerated a destroyed serial");
            }
            sum += amount;
        }
        uint256 bal = _modelBalance(a);
        assertEq(sum, bal, "ranges != model balance");
        assertEq(token.balanceOf(a), bal, "balanceOf");

        if (hasFreeze) _checkFreezes(a);
        if (hasClass) _checkClasses(a);

        // Transferable balance: every destination, including burning and the account itself
        address[] memory dests = new address[](actors.length + 2);
        for (uint256 i; i < actors.length; ++i) {
            dests[i] = actors[i];
        }
        dests[actors.length] = outsider;
        dests[actors.length + 1] = address(0);
        for (uint256 i; i < dests.length; ++i) {
            assertEq(token.transferableBalanceOf(a, dests[i]), _modelTransferable(a, dests[i]), "transferableBalanceOf");
        }
    }

    function _checkFreezes(address a) internal view {
        uint256 frozen;
        uint256[3] memory perReason;
        for (uint256 s; s < mIssued; ++s) {
            if (mHolder[s] != a || mDestroyed[s]) continue;
            if (mBits[s] != 0) ++frozen;
            for (uint256 k; k < 3; ++k) {
                if (mBits[s] & (1 << k) != 0) ++perReason[k];
            }
        }
        assertEq(token.frozenBalanceOf(a), frozen, "frozenBalanceOf");
        (bytes32[] memory rs, uint256[] memory am) = token.freezeReasonsOf(a);
        assertEq(rs.length, am.length, "freezeReasonsOf lengths");
        uint256 expectEntries;
        for (uint256 k; k < 3; ++k) {
            if (perReason[k] != 0) ++expectEntries;
        }
        assertEq(rs.length, expectEntries, "freezeReasonsOf entries");
        for (uint256 i; i < rs.length; ++i) {
            uint256 k = rs[i] == reasons[0] ? 0 : rs[i] == reasons[1] ? 1 : 2;
            assertEq(rs[i], reasons[k], "unknown reason listed");
            assertEq(am[i], perReason[k], "freezeReasonsOf amount");
        }
    }

    function _checkClasses(address a) internal view {
        bytes32[4] memory cs = [bytes32(0), CA, CL, CN];
        uint256[4] memory cnt;
        for (uint256 s; s < mIssued; ++s) {
            if (mHolder[s] != a || mDestroyed[s]) continue;
            for (uint256 k; k < 4; ++k) {
                if (mClass[s] == cs[k]) ++cnt[k];
            }
        }
        (bytes32[] memory ids, uint256[] memory am) = token.classesOf(a);
        assertEq(ids.length, am.length, "classesOf lengths");
        uint256 expectEntries;
        for (uint256 k; k < 4; ++k) {
            if (cnt[k] != 0) ++expectEntries;
        }
        assertEq(ids.length, expectEntries, "classesOf entries");
        for (uint256 i; i < ids.length; ++i) {
            bool found;
            for (uint256 k; k < 4; ++k) {
                if (ids[i] == cs[k]) {
                    assertEq(am[i], cnt[k], "classesOf amount");
                    found = true;
                }
            }
            assertTrue(found, "unknown class listed");
        }
    }

    /// @dev Compares the spans with the model serial by serial. The model's spans are computed over all issued serials,
    ///      destroyed ones included.
    function _checkSpans() internal view {
        uint256 n = mIssued;
        uint256[] memory fEnd = new uint256[](n);
        uint256[] memory cEnd = new uint256[](n);
        for (uint256 i = n; i != 0; --i) {
            uint256 s = i - 1;
            bool sameF = s + 1 < n && (mBits[s + 1] != 0) == (mBits[s] != 0);
            fEnd[s] = sameF ? fEnd[s + 1] : s + 1;
            bool sameC = s + 1 < n && mClass[s + 1] == mClass[s];
            cEnd[s] = sameC ? cEnd[s + 1] : s + 1;
        }
        for (uint256 s; s < n; ++s) {
            if (hasFreeze) {
                (bool f, uint256 fl) = token.frozenSpanAt(s);
                assertEq(f, mBits[s] != 0, "frozenSpanAt.frozen");
                assertEq(fl, fEnd[s] - s, "frozenSpanAt.length");
            }
            if (hasClass) {
                (bytes32 c, uint256 cl) = token.classSpanAt(s);
                assertEq(c, mClass[s], "classSpanAt.classId");
                assertEq(cl, cEnd[s] - s, "classSpanAt.length");
            }
        }
        if (hasFreeze) {
            (bool f2, uint256 l2) = token.frozenSpanAt(n);
            assertFalse(f2);
            assertEq(l2, 0, "frozenSpanAt beyond issued");
        }
        if (hasClass) {
            (bytes32 c2, uint256 l3) = token.classSpanAt(n);
            assertEq(c2, bytes32(0));
            assertEq(l3, 0, "classSpanAt beyond issued");
        }
    }
}

/// @dev One concrete contract for each token under test (at the end of the file).
abstract contract InvariantBase is Test, TokenTarget {
    ConformanceHandler internal h;

    function setUp() public {
        (ITestToken token, bool freeze_, bool class_, bool consol_) = _deployToken(address(this));
        h = new ConformanceHandler(token, freeze_, class_, consol_);
        token.transferAdmin(address(h));
        h.init();
        targetContract(address(h));
    }

    function invariant_viewsMatchModel() public view {
        h.checkViews();
    }

    /// @dev Random walks with fixed seeds: the same operations and checks as the invariant test, but they assert that
    ///      every kind of operation has succeeded.
    ///      Each step performs one of the 13 operations the draft covers; this implementation's own functions (the
    ///      hinted forced operations and the tidying function) are drawn separately, and about half the steps
    ///      perform one of them in addition, so that the frequency of the first 13 operations is the same as before
    ///      these were added.
    function _walk(uint256 rnd, uint256 steps) internal {
        for (uint256 i; i < steps; ++i) {
            rnd = uint256(keccak256(abi.encode(rnd, i)));
            uint256 op = rnd % 13;
            uint256 a = uint256(keccak256(abi.encode(rnd, 1)));
            uint256 b = uint256(keccak256(abi.encode(rnd, 2)));
            uint256 c = uint256(keccak256(abi.encode(rnd, 3)));
            if (op == 0 || op == 1) h.mint(a, b, c);
            else if (op == 2) h.transfer(a, b, c % 40);
            else if (op == 3) h.transferFrom(a, b, c % 40);
            else if (op == 4) h.burn(a, c % 10, b % 2 == 0);
            else if (op == 5 || op == 6) h.transferSlices(a, b, c);
            else if (op == 7) h.burnSlices(a, c);
            else if (op == 8) h.freeze(a, b, c, rnd % 3 == 0);
            else if (op == 9) h.setClass(a, b, c);
            else if (op == 10) h.setAllowed(a, b % 2 == 0);
            else if (op == 11) h.forcedTransfer(a, b, c, rnd >> 128);
            else if (op == 12) h.destroy(a, c, rnd >> 128);
            uint256 extra = (rnd >> 160) % 8;
            uint256 d = uint256(keccak256(abi.encode(rnd, 4)));
            if (extra == 1) h.forcedTransferAt(d, a, b, c, rnd >> 64);
            else if (extra == 2) h.destroyAt(d, b, c, rnd >> 64);
            else if (extra == 3 || extra == 4) h.tidy(d, c);
            else if (extra == 5 || extra == 6) h.consolidate(d, c);
            if (i % 60 == 59) h.checkViews();
            if (i % 150 == 149) h.warp(400);
        }
        h.checkViews();
        console.log("ok amount moves", h.okMoves(), "failed amount moves", h.failedMoves());
        console.log("ok moves by serial", h.okSerialMoves(), "ok forced ops", h.okForced());
        console.log("ok hinted forced ops", h.okHinted(), "ranges moved by tidy", h.tidyMoves());
        console.log("ok consolidations", h.okConsol(), "failed consolidations", h.failedConsol());
        console.log("refused for freeze", h.consolFrozenRefused(), "refused for class", h.consolClassRefused());
        console.log("deepest freeze propagation (generations)", h.maxGeneration());
        assertGt(h.okMoves(), 10, "too few successful amount-based moves");
        assertGt(h.failedMoves(), 2, "too few failed amount-based moves");
        assertGt(h.okSerialMoves(), 5, "too few successful moves by serial");
        if (h.hasFreeze()) assertGt(h.okForced(), 2, "too few successful forced operations");
        if (h.hasFreeze() && h.hasHints()) assertGt(h.okHinted(), 0, "no successful hinted forced operation");
        if (h.hasTidy() && h.hasFreeze()) assertGt(h.tidyMoves(), 0, "tidy never moved a range");
        if (h.hasConsol()) {
            assertGt(h.okConsol(), 5, "too few successful consolidations");
            assertGt(h.failedConsol(), 2, "too few refused consolidations");
            if (h.hasFreeze()) assertGt(h.consolFrozenRefused(), 0, "no consolidation refused for a freeze");
            if (h.hasFreeze()) assertGt(h.maxGeneration(), 0, "no freeze propagated along a record");
        } else {
            assertGt(h.closedConsolRefused(), 5, "too few consolidations tried on a closed token");
            assertEq(h.okConsol(), 0, "a closed token consolidated");
        }
    }

    function test_randomWalk1() public {
        _walk(1, 360);
    }

    function test_randomWalk2() public {
        _walk(2, 360);
    }

    function test_randomWalk3() public {
        _walk(3, 360);
    }

    function test_randomWalk4() public {
        _walk(4, 360);
    }

    /// @dev Prints the coverage at the end of each run (visible with -vv), to confirm that every kind of operation
    ///      has actually succeeded.
    function afterInvariant() public view {
        console.log("ok amount moves", h.okMoves(), "failed amount moves", h.failedMoves());
        console.log("ok moves by serial", h.okSerialMoves(), "ok forced ops", h.okForced());
        console.log("ok hinted forced ops", h.okHinted(), "ranges moved by tidy", h.tidyMoves());
        console.log("ok consolidations", h.okConsol(), "failed consolidations", h.failedConsol());
    }
}

// ───────────────────────── Tokens under test ─────────────────────────

contract Invariant_CoreStack is InvariantBase, TargetCoreStack {}

contract Invariant_CoreSorted is InvariantBase, TargetCoreSorted {}

contract Invariant_FreezeStack is InvariantBase, TargetFreezeStack {}

contract Invariant_FreezeSorted is InvariantBase, TargetFreezeSorted {}

contract Invariant_ClassStack is InvariantBase, TargetClassStack {}

contract Invariant_ClassSorted is InvariantBase, TargetClassSorted {}

contract Invariant_BothStack is InvariantBase, TargetBothStack {}

contract Invariant_BothSorted is InvariantBase, TargetBothSorted {}

contract Invariant_BothStackTight is InvariantBase, TargetBothStackTight {}

contract Invariant_BothSortedTight is InvariantBase, TargetBothSortedTight {}

contract Invariant_CoreConsolStack is InvariantBase, TargetCoreConsolStack {}

contract Invariant_CoreConsolSorted is InvariantBase, TargetCoreConsolSorted {}

contract Invariant_FreezeConsolStack is InvariantBase, TargetFreezeConsolStack {}

contract Invariant_FreezeConsolSorted is InvariantBase, TargetFreezeConsolSorted {}

contract Invariant_ClassConsolStack is InvariantBase, TargetClassConsolStack {}

contract Invariant_ClassConsolSorted is InvariantBase, TargetClassConsolSorted {}

contract Invariant_BothConsolStack is InvariantBase, TargetBothConsolStack {}

contract Invariant_BothConsolSorted is InvariantBase, TargetBothConsolSorted {}

// The second rule ("best fit in a bounded window", window 3). The invariants look only at events and views and do
// not depend on the selection rule.

contract Invariant_CoreStackWindow is InvariantBase, TargetCoreStackWindow {}

contract Invariant_BothStackWindow is InvariantBase, TargetBothStackWindow {}

contract Invariant_BothStackWindowTight is InvariantBase, TargetBothStackWindowTight {}

contract Invariant_BothConsolStackWindow is InvariantBase, TargetBothConsolStackWindow {}

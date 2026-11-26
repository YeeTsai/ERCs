// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERCXXXX} from "../../contracts/spec/IERCXXXX.sol";
import {IERCXXXXAcceptance} from "../../contracts/spec/IERCXXXXAcceptance.sol";
import {ERCXXXXAcceptance} from "../../contracts/extensions/ERCXXXXAcceptance.sol";
import {Rule} from "../presets/Presets.sol";
import "../presets/Targets.sol";
import "../mocks/AcceptanceCheckers.sol";

/// @dev Tests of the acceptance check: clauses 1 to 10 of "Acceptance check" in the draft, and the choices of the
///      reference implementation itself (the queries and the call take place after the change of holder, the gas
///      forwarded to the receiving contract is not limited, restricted issuance and forced operations do not query).
///      The draft's sequences of operations are in test/conformance/DraftSequences.t.sol.
///      Runs only on tokens that inherit ERCXXXXAcceptance (the four contracts at the end of the file).
abstract contract AcceptanceBase is Test, TokenTarget {
    bytes32 internal constant SERIAL_SIG = keccak256("SliceTransferred(address,address,uint256,uint256)");
    bytes4 internal constant ACCEPTANCE_CHECK_ID = 0x29543499;
    bytes4 internal constant QUERY_OUT_OF_GAS = ERCXXXXAcceptance.ERCXXXXAcceptanceQueryOutOfGas.selector;

    ITestToken internal t;
    bool internal hasFreeze;
    bool internal hasClass;
    address internal admin = makeAddr("admin");
    address internal A = makeAddr("A");
    address internal B = makeAddr("B");
    address internal C = makeAddr("C");
    bytes32 internal r = "r";
    bytes32 internal w = "w";

    function setUp() public {
        (t, hasFreeze, hasClass,) = _deployToken(admin);
        assertTrue(t.supportsInterface(ACCEPTANCE_CHECK_ID));
        vm.startPrank(admin);
        if (hasFreeze) t.setReasonInfo(r, "Reason", "");
        if (hasClass) t.defineClass(w, Rule.None, 0, "Batch", "");
        t.mint(A, 100);
        vm.stopPrank();
    }

    // ───────────────────────── Helpers ─────────────────────────

    function _one(uint256 x) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = x;
    }

    function _two(uint256 x, uint256 y) internal pure returns (uint256[] memory a) {
        a = new uint256[](2);
        (a[0], a[1]) = (x, y);
    }

    function _list(uint256 a0, uint256 a1, uint256 a2, uint256 a3) internal pure returns (uint256[] memory a) {
        a = new uint256[](4);
        (a[0], a[1], a[2], a[3]) = (a0, a1, a2, a3);
    }

    function _expectRefused(address from, address to, uint256 value) internal {
        vm.expectRevert(abi.encodeWithSelector(IERCXXXX.ERCXXXXTransferRefused.selector, from, to, value));
    }

    /// @dev The number of SliceTransferred events the token emitted in the most recent batch of logs.
    function _serialTransferCount() internal returns (uint256 n) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(t) && logs[i].topics[0] == SERIAL_SIG) ++n;
        }
    }

    function _supportsInterfaceCall(bytes4 id) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(ERC165_ID, id);
    }

    function _acceptsCall(address operator, address from, uint256 value, uint256 ranges)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeCall(IERCXXXXAcceptance.acceptsERCXXXXTransfer, (operator, from, value, ranges));
    }

    /// @dev All the calls (CALL, STATICCALL, DELEGATECALL, CALLCODE) that the token made to `to` in one state diff
    ///      recording.
    function _callsTo(Vm.AccountAccess[] memory accesses, address to)
        internal
        view
        returns (VmSafe.AccountAccessKind[] memory kinds, bytes[] memory data)
    {
        uint256 n;
        for (uint256 i; i < accesses.length; ++i) {
            if (_isTokenCallTo(accesses[i], to)) ++n;
        }
        kinds = new VmSafe.AccountAccessKind[](n);
        data = new bytes[](n);
        n = 0;
        for (uint256 i; i < accesses.length; ++i) {
            if (!_isTokenCallTo(accesses[i], to)) continue;
            (kinds[n], data[n]) = (accesses[i].kind, accesses[i].data);
            ++n;
        }
    }

    function _isTokenCallTo(Vm.AccountAccess memory a, address to) private view returns (bool) {
        if (a.accessor != address(t) || a.account != to) return false;
        return a.kind == VmSafe.AccountAccessKind.Call || a.kind == VmSafe.AccountAccessKind.StaticCall
            || a.kind == VmSafe.AccountAccessKind.DelegateCall || a.kind == VmSafe.AccountAccessKind.CallCode;
    }

    /// @dev The calls the token made to `to` are exactly the three ERC-165 queries and one acceptsERCXXXXTransfer, in
    ///      that order, all of them STATICCALL.
    function _assertQueriedAndAsked(Vm.AccountAccess[] memory accesses, address to, bytes memory acceptsCall)
        internal
        view
    {
        (VmSafe.AccountAccessKind[] memory kinds, bytes[] memory data) = _callsTo(accesses, to);
        assertEq(kinds.length, 4, "number of calls to the receiver");
        for (uint256 i; i < 4; ++i) {
            assertTrue(kinds[i] == VmSafe.AccountAccessKind.StaticCall, "call to the receiver is not a STATICCALL");
        }
        assertEq(data[0], _supportsInterfaceCall(ERC165_ID), "first ERC-165 query");
        assertEq(data[1], _supportsInterfaceCall(INVALID_ID), "second ERC-165 query");
        assertEq(data[2], _supportsInterfaceCall(ACCEPT), "interface query");
        assertEq(data[3], acceptsCall, "acceptsERCXXXXTransfer arguments");
    }

    // ───────────────────────── Declaration ─────────────────────────

    /// @dev A token that supports the acceptance check returns true for 0x29543499, and does not return true for the
    ///      recipient's interface 0x4689efd4.
    function test_supportsInterface() public view {
        assertTrue(t.supportsInterface(ACCEPTANCE_CHECK_ID));
        assertEq(ACCEPTANCE_CHECK_ID, IERCXXXX.ERCXXXXTransferRefused.selector);
        assertFalse(t.supportsInterface(type(IERCXXXXAcceptance).interfaceId));
        assertFalse(t.supportsInterface(0x4689efd4));
        assertTrue(t.supportsInterface(ERC165_ID));
        assertTrue(t.supportsInterface(type(IERCXXXX).interfaceId));
        assertFalse(t.supportsInterface(INVALID_ID));
    }

    // ───────────────────────── Determining a receiving contract (clauses 2 and 4) ─────────────────────────

    /// @dev An address without code is not asked: the token makes no call to it.
    function test_noCodeRecipientIsNotCalled() public {
        vm.startStateDiffRecording();
        vm.startPrank(A);
        t.transfer(B, 1);
        t.transferSlices(B, _one(50), _one(1));
        vm.stopPrank();
        (VmSafe.AccountAccessKind[] memory kinds,) = _callsTo(vm.stopAndReturnStateDiff(), B);
        assertEq(kinds.length, 0);
        assertEq(t.balanceOf(B), 2);
    }

    /// @dev For a receiving contract, the token first queries three times as ERC-165 specifies and then asks once, all
    ///      with STATICCALL; the arguments are operator, from, value and slices.
    function test_queriesAndCallAreStaticAndInOrder() public {
        address R = address(new RangeLimitReceiver(10));

        vm.startStateDiffRecording();
        vm.prank(A);
        t.transfer(R, 7);
        _assertQueriedAndAsked(vm.stopAndReturnStateDiff(), R, _acceptsCall(A, A, 7, 1));

        vm.prank(A);
        t.approve(C, 3);
        vm.startStateDiffRecording();
        vm.prank(C);
        t.transferFrom(A, R, 3);
        _assertQueriedAndAsked(vm.stopAndReturnStateDiff(), R, _acceptsCall(C, A, 3, 1));

        vm.startStateDiffRecording();
        vm.prank(A);
        t.transferSlices(R, _two(0, 2), _two(1, 3));
        _assertQueriedAndAsked(vm.stopAndReturnStateDiff(), R, _acceptsCall(A, A, 4, 2));
        assertEq(t.balanceOf(R), 14);
    }

    /// @dev Every supportsInterface query forwards exactly 30,000 gas (the detection procedure of ERC-165, clause 5 of
    ///      "Acceptance check" in the draft).
    function test_queriesForward30000Gas() public {
        address R = address(new RangeLimitReceiver(10));
        // Control: an expectCall given only a selector matches by prefix. Elsewhere it is used with a count of 0 to
        // assert that no query and no call is made.
        vm.expectCall(R, abi.encodeWithSelector(ERC165_ID), 3);
        vm.expectCall(R, abi.encodeWithSelector(ACCEPT), 1);
        vm.expectCall(R, 0, 30_000, _supportsInterfaceCall(ERC165_ID), 1);
        vm.expectCall(R, 0, 30_000, _supportsInterfaceCall(INVALID_ID), 1);
        vm.expectCall(R, 0, 30_000, _supportsInterfaceCall(ACCEPT), 1);
        vm.prank(A);
        t.transfer(R, 1);
    }

    /// @dev Uses state changes to prove that the calls are read-only: a receiving contract that accepts only in a
    ///      read-only context accepts; a contract that declares the interface only in a read-only context and refuses
    ///      everything is treated as a receiving contract, so the transfer is refused.
    function test_staticContextIsObservable() public {
        StaticOnlyReceiver ok = new StaticOnlyReceiver();
        vm.prank(A);
        assertTrue(t.transfer(address(ok), 1));
        assertEq(ok.pokes(), 1);

        StaticOnlyErc165Receiver probe = new StaticOnlyErc165Receiver();
        _expectRefused(A, address(probe), 1);
        vm.prank(A);
        t.transfer(address(probe), 1);
        assertEq(probe.pokes(), 1);
    }

    /// @dev Contracts that are not receiving contracts receive payments as usual, and acceptsERCXXXXTransfer is not
    ///      called, including when they have this function themselves.
    function _assertNotAsked(address x) internal {
        vm.expectCall(x, abi.encodeWithSelector(ACCEPT), 0);
        vm.startPrank(A);
        assertTrue(t.transfer(x, 1));
        assertTrue(t.transferSlices(x, _one(90), _one(1)));
        t.approve(C, 1);
        vm.stopPrank();
        vm.prank(C);
        assertTrue(t.transferFrom(A, x, 1));
        assertEq(t.balanceOf(x), 3);
    }

    function test_noInterfaceContractIsNotAsked() public {
        _assertNotAsked(address(new NoInterfaceContract()));
    }

    /// @dev A contract that returns true for everything: supportsInterface(0xffffffff) is true too, so by ERC-165 it
    ///      does not implement ERC-165.
    function test_allTrueContractIsNotAsked() public {
        _assertNotAsked(address(new AllTrueContract()));
    }

    function test_erc165WithoutTheInterfaceIsNotAsked() public {
        _assertNotAsked(address(new Erc165OnlyContract()));
    }

    function test_erc165FirstQueryFalseIsNotAsked() public {
        _assertNotAsked(address(new Erc165FalseContract()));
    }

    function test_erc165SecondQueryRevertsIsNotAsked() public {
        _assertNotAsked(address(new InvalidIdRevertsContract()));
    }

    /// @dev The second query returns 2: not false, so the contract does not implement ERC-165.
    function test_erc165SecondQueryNonZeroIsNotAsked() public {
        _assertNotAsked(address(new InvalidIdMalformedContract()));
    }

    /// @dev The first query returns 2: not false, so the queries continue (as in ERC165Query of ERC-165); the next two
    ///      answer 0 and 1, so it is a receiving contract, is asked, and refuses.
    function test_erc165FirstQueryNonZeroIsAsked() public {
        _assertRefusedBy(address(new FirstQueryNonBoolReceiver()));
    }

    /// @dev supportsInterface uses up the 30,000 gas forwarded to it: when the token had ample gas, this is not a lack
    ///      of gas, and the contract is not a receiving contract.
    function test_erc165GasBurnerIsNotAskedWhenGasIsAmple() public {
        _assertNotAsked(address(new Erc165GasBurnerContract()));
    }

    /// @dev The token itself implements ERC-165 but does not return true for 0x4689efd4, so it is not a receiving
    ///      contract.
    function test_tokenAsRecipientIsNotAsked() public {
        vm.prank(A);
        assertTrue(t.transfer(address(t), 1));
        assertEq(t.balanceOf(address(t)), 1);
    }

    // ───────────────────────── Exemptions ─────────────────────────

    /// @dev Incoming transfers of zero value, with `from` equal to `to`, or with `operator` equal to `to` are exempt:
    ///      the token neither queries `to` nor calls it. Checked with S, which always reverts.
    function test_exemptTransfersAreNotQueried() public {
        PullingReceiver S = new PullingReceiver(address(t));
        address s = address(S);
        vm.expectCall(s, abi.encodeWithSelector(ERC165_ID), 0);
        vm.expectCall(s, abi.encodeWithSelector(ACCEPT), 0);

        // `operator` equals `to`: S pulls by itself, and transferFrom is called as S.
        vm.startPrank(A);
        t.approve(s, 20);
        t.approve(C, 20);
        vm.stopPrank();
        S.pull(A, 5);
        vm.prank(s);
        assertTrue(t.transferFrom(A, s, 5));
        assertEq(t.balanceOf(s), 10);

        // `value` is zero.
        vm.prank(A);
        assertTrue(t.transfer(s, 0));
        vm.prank(C);
        assertTrue(t.transferFrom(A, s, 0));

        // `from` equals `to`, `operator` is not `to`.
        vm.prank(s);
        t.approve(C, 10);
        vm.prank(C);
        assertTrue(t.transferFrom(s, s, 4));
        assertEq(t.balanceOf(s), 10);
        assertEq(t.allowance(s, C), 6);
    }

    // ───────────────────────── Acceptance and refusal ─────────────────────────

    /// @dev x refuses: transfer, transferSlices and transferFrom all revert with ERCXXXXTransferRefused, and the
    ///      balances do not change.
    function _assertRefusedBy(address x) internal {
        _expectRefused(A, x, 1);
        vm.prank(A);
        t.transfer{gas: 2_000_000}(x, 1);
        _expectRefused(A, x, 1);
        vm.prank(A);
        t.transferSlices{gas: 2_000_000}(x, _one(0), _one(1));
        vm.prank(A);
        t.approve(C, 1);
        _expectRefused(A, x, 1);
        vm.prank(C);
        t.transferFrom{gas: 2_000_000}(A, x, 1);
        assertEq(t.balanceOf(x), 0);
        assertEq(t.balanceOf(A), 100);
    }

    function test_receiverThatReverts() public {
        _assertRefusedBy(address(new PullingReceiver(address(t))));
    }

    function test_receiverThatReturnsZero() public {
        _assertRefusedBy(address(new ZeroReturnReceiver()));
    }

    function test_receiverThatReturnsTrue() public {
        _assertRefusedBy(address(new BoolReturnReceiver()));
    }

    function test_receiverThatReturnsFourBytes() public {
        _assertRefusedBy(address(new ShortReturnReceiver()));
    }

    function test_receiverThatReturnsDirtyPadding() public {
        _assertRefusedBy(address(new DirtyReturnReceiver()));
    }

    /// @dev A receiving contract that tries to write state in acceptsERCXXXXTransfer: STATICCALL makes the call fail,
    ///      which counts as a refusal.
    function test_receiverThatWritesState() public {
        WritingReceiver x = new WritingReceiver();
        _assertRefusedBy(address(x));
        assertEq(x.calls(), 0);
    }

    /// @dev acceptsERCXXXXTransfer uses up all its gas: the call fails, which counts as a refusal; the 1/64 that the
    ///      token keeps is enough to revert with the agreed error.
    function test_receiverThatBurnsAllGas() public {
        _assertRefusedBy(address(new GasBurningReceiver()));
    }

    /// @dev The agreed value followed by 64 KiB of data: this still means acceptance; the token reads only the first
    ///      32 bytes.
    function test_receiverWithLongReturnData() public {
        address x = address(new LongReturnReceiver());
        vm.prank(A);
        assertTrue(t.transfer{gas: 400_000}(x, 1));
        assertEq(t.balanceOf(x), 1);
    }

    /// @dev This implementation does not limit the gas forwarded to acceptsERCXXXXTransfer (clause 7 of "Acceptance
    ///      check" in the draft): a receiving contract that uses 200,000 gas still accepts.
    function test_noGasLimitForAcceptsCall() public {
        address x = address(new ExpensiveAcceptReceiver(200_000));
        vm.prank(A);
        assertTrue(t.transfer(x, 1));
        assertEq(t.balanceOf(x), 1);
    }

    /// @dev The arguments the token passes to the receiving contract: operator, from, value and slices; the caller is
    ///      the token.
    function test_receiverGetsExactArguments() public {
        ExactReceiver k = new ExactReceiver();
        address x = address(k);

        // transfer: operator is the sender.
        k.expect(address(t), A, A, 7, 1);
        vm.prank(A);
        assertTrue(t.transfer(x, 7));

        // transferFrom: operator is the spender.
        vm.prank(A);
        t.approve(C, 3);
        k.expect(address(t), C, A, 3, 1);
        vm.prank(C);
        assertTrue(t.transferFrom(A, x, 3));

        // transferSlices: one SliceTransferred for each named slice; two adjacent slices are also counted separately.
        k.expect(address(t), A, A, 4, 3);
        uint256[] memory starts = new uint256[](3);
        uint256[] memory amounts = new uint256[](3);
        (starts[0], starts[1], starts[2]) = (0, 1, 50);
        (amounts[0], amounts[1], amounts[2]) = (1, 1, 2);
        vm.recordLogs();
        vm.prank(A);
        assertTrue(t.transferSlices(x, starts, amounts));
        assertEq(_serialTransferCount(), 3);

        // It does not accept when the caller is not the token it knows.
        k.expect(address(0xdead), A, A, 1, 1);
        _expectRefused(A, x, 1);
        vm.prank(A);
        t.transfer(x, 1);
    }

    /// @dev In a transfer by amount, slices is the number of SliceTransferred events this transfer emits.
    ///      The transfer is first made to a receiving contract that accepts everything, and the events are counted as
    ///      n; then the state is restored and the transfer is made again, checked with arguments that accept only n
    ///      slices.
    function _assertRangesMatchLogs(uint256 value, uint256 minExpected) internal {
        ExactReceiver k = new ExactReceiver();
        address x = address(k);
        address any = address(new AcceptAllReceiver());
        uint256 snap = vm.snapshotState();
        vm.recordLogs();
        vm.prank(A);
        t.transfer(any, value);
        uint256 n = _serialTransferCount();
        assertGe(n, minExpected, "expected a fragmented transfer");
        vm.revertToState(snap);

        k.expect(address(t), A, A, value, n + 1);
        _expectRefused(A, x, value);
        vm.prank(A);
        t.transfer(x, value);
        k.expect(address(t), A, A, value, n);
        vm.recordLogs();
        vm.prank(A);
        assertTrue(t.transfer(x, value));
        assertEq(_serialTransferCount(), n, "same selection for both recipients");
        vm.revertToState(snap);
    }

    function test_slicesIsTheNumberOfSliceTransferredEvents() public {
        // One whole slice: one event.
        _assertRangesMatchLogs(100, 1);
        // Break up A's holding: transfer away serials 1, 3, 5 and 7, leaving A with 0, 2, 4, 6 and 8 to 99.
        vm.prank(A);
        t.transferSlices(C, _list(1, 3, 5, 7), _list(1, 1, 1, 1));
        // Transfer everything out: five slices not adjacent to one another, at least five events.
        _assertRangesMatchLogs(96, 5);
        _assertRangesMatchLogs(3, 1);
    }

    /// @dev A slice stored as one slice in the holding is emitted as several events when a part in its middle is
    ///      frozen.
    function test_rangesWhenOneStoredRangeIsSplitByAFreeze() public {
        vm.skip(!hasFreeze);
        vm.prank(admin);
        t.freezeSlice(40, 10, r);
        _assertRangesMatchLogs(90, 2);
    }

    /// @dev Two adjacent slices of different classes are emitted separately.
    function test_rangesWhenAStoredRangeHasTwoClasses() public {
        vm.skip(!hasClass);
        vm.prank(admin);
        t.setClass(40, 10, w);
        _assertRangesMatchLogs(100, 3);
    }

    /// @dev This implementation asks the receiving contract only after the change of holder (clause 6 of "Acceptance
    ///      check" in the draft): the balance it reads already includes this incoming transfer.
    function test_receiverSeesStateAfterTheMove() public {
        address x = address(new BalanceThresholdReceiver(5));
        vm.prank(A);
        assertTrue(t.transfer(x, 5));
        address y = address(new BalanceThresholdReceiver(5));
        _expectRefused(A, y, 4);
        vm.prank(A);
        t.transfer(y, 4);
    }

    /// @dev A refused transfer leaves no change behind.
    function test_refusedTransferChangesNothing() public {
        address x = address(new ZeroReturnReceiver());
        uint256 nA = t.sliceCount(A);
        vm.recordLogs();
        _expectRefused(A, x, 9);
        vm.prank(A);
        t.transfer(x, 9);
        assertEq(t.balanceOf(A), 100);
        assertEq(t.balanceOf(x), 0);
        assertEq(t.sliceCount(A), nA);
        assertEq(t.sliceCount(x), 0);
        assertEq(t.totalSupply(), 100);
    }

    // ───────────────────────── Clause 5: lowering the gas does not bypass the check ─────────────────────────

    /// @dev Calls the token as `caller` with every gas limit from `lo` to `hi` (in steps of `step`), asserts that no
    ///      call succeeds, and returns the number of calls that failed with ERCXXXXAcceptanceQueryOutOfGas.
    function _sweep(address caller, bytes memory callData, uint256 lo, uint256 hi, uint256 step)
        internal
        returns (uint256 outOfGas)
    {
        for (uint256 g = lo; g <= hi; g += step) {
            vm.prank(caller);
            (bool ok, bytes memory ret) = address(t).call{gas: g}(callData);
            assertFalse(ok, string.concat("a refusing receiver was paid with gas limit ", vm.toString(g)));
            if (ret.length >= 4 && bytes4(ret) == QUERY_OUT_OF_GAS) ++outOfGas;
        }
    }

    /// @dev A conforming receiving contract whose supportsInterface uses about 20,000 gas, and which refuses
    ///      everything. Whatever gas the payer gives, the transfer does not succeed; some of the gas limits leave one
    ///      of the queries short of 30,000 gas, and the token reverts with ERCXXXXAcceptanceQueryOutOfGas.
    function test_lowGasCannotBypass_heavyReceiver() public {
        address x = address(new HeavyReceiver(false));
        uint256 n = _sweep(A, abi.encodeCall(ITestToken.transfer, (x, 1)), 30_000, 250_000, 59);
        assertGt(n, 0, "the gas guard never fired");
        n = _sweep(A, abi.encodeCall(ITestToken.transferSlices, (x, _one(0), _one(1))), 30_000, 250_000, 59);
        assertGt(n, 0, "the gas guard never fired");
        // Control: the same transfer to a contract of the same kind that accepts succeeds when given ample gas.
        address y = address(new HeavyReceiver(true));
        vm.prank(A);
        assertTrue(t.transfer{gas: 250_000}(y, 1));
    }

    /// @dev A receiving contract whose supportsInterface reverts at once when it receives too little gas, returning
    ///      the unused gas to the token, and which refuses everything. An implementation that only looks at whether
    ///      the call succeeded would treat it here as not being a receiving contract and let the transfer succeed;
    ///      this implementation checks the gas before every query.
    function test_lowGasCannotBypass_gasCheckingReceiver() public {
        address x = address(new GasCheckingReceiver());
        uint256 n = _sweep(A, abi.encodeCall(ITestToken.transfer, (x, 1)), 30_000, 250_000, 59);
        assertGt(n, 0, "the gas guard never fired");
        vm.prank(A);
        t.approve(C, 100);
        n = _sweep(C, abi.encodeCall(ITestToken.transferFrom, (A, x, 1)), 30_000, 250_000, 59);
        assertGt(n, 0, "the gas guard never fired");
        n = _sweep(C, abi.encodeCall(ITestToken.openMint, (x, 1)), 30_000, 250_000, 59);
        assertGt(n, 0, "the gas guard never fired");
        assertEq(t.balanceOf(x), 0);
        // The upper end of the sweep is already past the threshold of the gas check: given ample gas, the refusal is
        // reported with the agreed error.
        _expectRefused(A, x, 1);
        vm.prank(A);
        t.transfer{gas: 250_000}(x, 1);
    }

    /// @dev Sweeps one operation against x: 0 is transfer, 1 is transferFrom, 2 is transferSlices, 3 is openMint,
    ///      which any caller can call. x refuses everything, so no gas limit can succeed; asserts that the error of the
    ///      gas check appears at least once and that x received no units.
    function _sweepOperation(address x, uint256 op) internal {
        bytes memory data;
        address caller = A;
        if (op == 0) {
            data = abi.encodeCall(ITestToken.transfer, (x, 1));
        } else if (op == 1) {
            vm.prank(A);
            t.approve(C, type(uint256).max);
            caller = C;
            data = abi.encodeCall(ITestToken.transferFrom, (A, x, 1));
        } else if (op == 2) {
            data = abi.encodeCall(ITestToken.transferSlices, (x, _one(0), _one(1)));
        } else {
            caller = C;
            data = abi.encodeCall(ITestToken.openMint, (x, 1));
        }
        uint256 n = _sweep(caller, data, 30_000, 250_000, 59);
        assertGt(n, 0, "the gas guard never fired");
        assertEq(t.balanceOf(x), 0);
    }

    /// @dev A receiving contract whose supportsInterface successfully answers false when gas is short (and true when
    ///      given the full 30,000 gas), and which refuses everything. An implementation that checks the gas only when
    ///      a query fails would, when gas is short, treat it as not being a receiving contract and let the transfer
    ///      succeed. This implementation checks the gas unconditionally before every query (the first sentence of
    ///      clause 5 of "Acceptance check" in the draft).
    function test_lowGasCannotBypass_falseOnLowGas_transfer() public {
        _sweepOperation(address(new FalseOnLowGasReceiver()), 0);
    }

    function test_lowGasCannotBypass_falseOnLowGas_transferFrom() public {
        _sweepOperation(address(new FalseOnLowGasReceiver()), 1);
    }

    function test_lowGasCannotBypass_falseOnLowGas_transferSlices() public {
        _sweepOperation(address(new FalseOnLowGasReceiver()), 2);
    }

    function test_lowGasCannotBypass_falseOnLowGas_openMint() public {
        _sweepOperation(address(new FalseOnLowGasReceiver()), 3);
    }

    /// @dev A receiving contract whose supportsInterface queries, with try/catch, a registry that uses about 12,000
    ///      gas and returns false when the subcall fails; it refuses everything. The subcall forwards gasleft() minus
    ///      the 5,000 left for the catch branch.
    function test_lowGasCannotBypass_tryCatch_transfer() public {
        _sweepOperation(address(new TryCatchReceiver(5_000)), 0);
    }

    function test_lowGasCannotBypass_tryCatch_transferFrom() public {
        _sweepOperation(address(new TryCatchReceiver(5_000)), 1);
    }

    function test_lowGasCannotBypass_tryCatch_transferSlices() public {
        _sweepOperation(address(new TryCatchReceiver(5_000)), 2);
    }

    function test_lowGasCannotBypass_tryCatch_openMint() public {
        _sweepOperation(address(new TryCatchReceiver(5_000)), 3);
    }

    /// @dev The same receiving contract, with the subcall receiving all the gas that can be forwarded and using it up
    ///      when it fails.
    function test_lowGasCannotBypass_tryCatchNoReserve_transfer() public {
        _sweepOperation(address(new TryCatchReceiver(0)), 0);
    }

    function test_lowGasCannotBypass_tryCatchNoReserve_transferFrom() public {
        _sweepOperation(address(new TryCatchReceiver(0)), 1);
    }

    function test_lowGasCannotBypass_tryCatchNoReserve_transferSlices() public {
        _sweepOperation(address(new TryCatchReceiver(0)), 2);
    }

    function test_lowGasCannotBypass_tryCatchNoReserve_openMint() public {
        _sweepOperation(address(new TryCatchReceiver(0)), 3);
    }

    /// @dev Given ample gas, both kinds of receiving contracts are receiving contracts: the transfer is asked about and
    ///      refused.
    function test_lowGasReceiversAreReceivingContracts() public {
        _assertRefusedBy(address(new FalseOnLowGasReceiver()));
        _assertRefusedBy(address(new TryCatchReceiver(5_000)));
        _assertRefusedBy(address(new TryCatchReceiver(0)));
    }

    // ───────────────────────── Clause 9: issuance, burning and forced operations ─────────────────────────

    /// @dev Restricted issuance (mint and mintWithClass by the admin), burning and forced operations do not query
    ///      receiving contracts.
    function test_restrictedIssuanceBurnAndForcedAreNotChecked() public {
        PullingReceiver S = new PullingReceiver(address(t));
        address s = address(S);
        vm.expectCall(s, abi.encodeWithSelector(ERC165_ID), 0);
        vm.expectCall(s, abi.encodeWithSelector(ACCEPT), 0);

        vm.prank(admin);
        t.mint(s, 1);
        assertEq(t.balanceOf(s), 1);

        vm.startPrank(A);
        t.burn(1);
        t.burnSlices(_one(0), _one(1));
        vm.stopPrank();
        assertEq(t.balanceOf(A), 98);

        if (hasClass) {
            vm.prank(admin);
            t.mintWithClass(s, 1, w);
            assertEq(t.balanceOf(s), 2);
        }
        if (hasFreeze) {
            vm.startPrank(admin);
            t.freezeSlice(10, 5, r);
            t.forcedTransferSlice(A, s, 10, 5);
            vm.stopPrank();
            assertEq(t.balanceOf(A), 93);
        }
    }

    /// @dev Issuance that any caller can execute asks the recipient under the acceptance check: from is the zero
    ///      address, operator is the caller, slices is 1.
    function test_openIssuanceIsChecked() public {
        PullingReceiver S = new PullingReceiver(address(t));
        address s = address(S);
        _expectRefused(address(0), s, 9);
        vm.prank(C);
        t.openMint(s, 9);
        // Issuance of zero value and issuance to the caller itself are exempt.
        vm.prank(C);
        t.openMint(s, 0);
        vm.prank(s);
        t.openMint(s, 3);
        assertEq(t.balanceOf(s), 3);
        // An address without code receives as usual.
        vm.prank(C);
        t.openMint(B, 2);
        assertEq(t.balanceOf(B), 2);

        ExactReceiver k = new ExactReceiver();
        k.expect(address(t), C, address(0), 2, 1);
        vm.startStateDiffRecording();
        vm.prank(C);
        t.openMint(address(k), 2);
        _assertQueriedAndAsked(vm.stopAndReturnStateDiff(), address(k), _acceptsCall(C, address(0), 2, 1));
        assertEq(t.balanceOf(address(k)), 2);
        k.expect(address(t), C, address(0), 2, 2);
        _expectRefused(address(0), address(k), 2);
        vm.prank(C);
        t.openMint(address(k), 2);
    }

    function test_openIssuanceWithClassIsChecked() public {
        vm.skip(!hasClass);
        address x = address(new ZeroReturnReceiver());
        _expectRefused(address(0), x, 9);
        vm.prank(C);
        t.openMintWithClass(x, 9, w);
        address y = address(new RangeLimitReceiver(1));
        vm.prank(C);
        t.openMintWithClass(y, 9, w);
        assertEq(t.balanceOf(y), 9);
    }

    // ───────────────────────── Clause 10: approve and allowance ─────────────────────────

    /// @dev approve does not revert because spender or the caller would refuse, a refusal does not change an allowance,
    ///      and transferableBalanceOf does not reflect refusal.
    function test_approveAndAllowancesIgnoreRefusal() public {
        PullingReceiver S = new PullingReceiver(address(t));
        address s = address(S);
        address z = address(new ZeroReturnReceiver());
        vm.startPrank(A);
        assertTrue(t.approve(s, 5));
        assertTrue(t.approve(z, 5));
        assertTrue(t.approve(C, 5));
        vm.stopPrank();
        // A contract that refuses everything can itself approve.
        vm.prank(s);
        assertTrue(t.approve(A, 1));

        _expectRefused(A, z, 5);
        vm.prank(C);
        t.transferFrom(A, z, 5);
        assertEq(t.allowance(A, C), 5);
        assertEq(t.allowance(A, s), 5);
        assertEq(t.transferableBalanceOf(A, s), 100);
        assertEq(t.transferableBalanceOf(A, z), 100);
    }
}

contract Acceptance_AcceptStack is AcceptanceBase, TargetAcceptStack {}

contract Acceptance_AcceptSorted is AcceptanceBase, TargetAcceptSorted {}

contract Acceptance_AllStack is AcceptanceBase, TargetAllStack {}

contract Acceptance_AllSorted is AcceptanceBase, TargetAllSorted {}

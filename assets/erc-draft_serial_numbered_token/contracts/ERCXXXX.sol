// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20, IERC20Metadata, IERC20Errors, IERC165} from "./utils/IERC20.sol";
import {IERCXXXX} from "./spec/IERCXXXX.sol";
import {SerialHoldings} from "./holdings/SerialHoldings.sol";

/// @title ERCXXXX: reference implementation of the core interface of this proposal
/// @notice An ERC-20 token in which every smallest unit has a permanent serial. It implements only the core
///         interface (IERCXXXX); minting, burning, freezing and classification are in extension contracts, and how
///         holdings are stored is decided by a backend contract (a contract that inherits SerialHoldings).
///         Consolidation is part of the core interface but is closed by default (clause 7 of "Consolidation" in the
///         draft): consolidateSlices always reverts, and consolidatedSpanAt reports no consolidated serials. A token
///         that opens consolidation also inherits the module ERCXXXXConsolidation and links the library
///         SerialConsolidations (which holds the consolidation records and the core's argument checks for
///         consolidation); with the slice stack backend it also links the library SerialStackBatch (the scan that
///         removes several slices by serial in one go for consolidation; see the end of SerialHoldingsStack). A
///         token that does not open consolidation calls neither library and need not link them.
///         The token contract has to inherit both this contract and a backend, for example:
///
///             contract MyToken is ERCXXXX, SerialHoldingsStack { ... }
///
///         The constructor of the slice stack takes a deployment parameter selectionWindow, which sets the selection
///         rule for selection by amount (see "Selection rule for selection by amount" below).
///
/// @dev Organization of holdings (an implementation detail that the draft does not specify):
///      - Each account's holding is divided into several piles. The default pile has the key 0, and the other piles
///        are defined by extensions: the freezing extension puts frozen slices into the frozen pile _FROZEN_PILE,
///        and the classification extension puts slices of a non-zero class into a pile keyed by the class.
///      - A slice received goes directly into the pile where it belongs according to its state at the time of
///        receipt (on minting, the caller specifies the pile).
///      - A pile is only a hint. Freezing, unfreezing and setting a class change only the state recorded on the
///        serials and do not touch holdings, so a slice whose state changes after it is received stays in its
///        original pile. Whether serials are transferable is always decided by their current state (_segmentAt and
///        _pileUsable).
///      - When a transfer by amount meets such a slice that is not transferable, it moves the slice to the pile
///        where it belongs (lazy sorting into piles), and later transfers skip that whole pile directly.
///        Each transfer moves at most _maxPileMoves() slices and skips the rest in place, leaving them for later
///        transfers to continue tidying. The writes for moving between piles in each transfer are therefore
///        bounded, but skipping in place still reads slice by slice: when there are many misplaced slices (about
///        2000 on the slice stack), the first transfer already exceeds the gas limit of a single transaction, and
///        after it reverts no slice has been moved either. In that case, use _tidy below to tidy in several calls.
///      - The cost of skipping therefore does not grow with the number of slices that are not transferable, in the
///        amortized sense (the SHOULD in clause 4 of "Transferable balance" in the draft): until the misplaced
///        slices are tidied, every transfer still pays the cost of skipping them in place.
///      - Tidying is also possible without transferring: _tidy moves the misplaced slices in one pile to the piles
///        where they belong, at most a given number of slices per call; the public function is in the extension
///        ERCXXXXTidy. It also moves back the slices that stay in the frozen pile after they are unfrozen.
///        _tidy walks the indexes from high to low, and _removeAt changes the positions only of slices at indexes
///        not less than the current one, all of which have already been visited; the slices moved away are written
///        grouped by destination pile, and for the sorted array a batch from one source pile is in strictly
///        descending order (see SerialHoldings._addRanges).
///      - Locating by serial requires searching the holding. Forced operations can instead take the position from
///        the caller (_moveRangeAt; the position is read with _positionOf), at constant cost on the slice stack;
///        when the position is no longer valid, the call only reverts and does not touch other serials.
///
///      Selection rule for selection by amount (clause 2 of "Transfers" in the draft asks for it to be documented).
///      The rule is set by a deployment parameter of the backend (_selectionWindow(), immutable, unchanged after
///      deployment). Transfers and burns by amount (transfer, transferFrom, burn, burnFrom) all select by it;
///      transferSlices, burnSlices, forced operations and consolidation name serials and are not affected by it.
///      - First pass: first the non-default piles that are usable for (from, to), then the default pile. In each
///        pile, pick a slice by the rule and take from the end of that slice with the largest serials.
///        - The default rule: always pick the first slice in the backend's "selection order" (index n - 1; on the
///          slice stack this is the top of the stack, that is, last-in-first-out).
///        - The second rule, "best fit in a bounded window", with window size W: when r units remain to be paid,
///          look at the recorded lengths of the at most W slices at indexes [n - W, n). If some are at least r
///          long, pick the shortest of them; if none is, pick the longest; among slices of equal length, pick the
///          one with the larger index. Take min(r, length of that slice) units from the end of the picked slice
///          with the largest serials and subtract them from r; while r is not yet zero, pick again in the window as
///          it then is, until the amount is paid or the pile is empty.
///          Each pick reads at most W slices. Every pile picks by the second rule on its own, and the order of the
///          piles is the same as under the default rule.
///      - Coordination with lazy sorting into piles (the same under both rules): if the end of the picked slice
///        with the largest serials is not transferable, that part is moved to the pile where it belongs (or skipped
///        in place once the budget is used up); when only part of that end has the same state, only that part is
///        taken, and the contract then picks again. So the second rule compares the length recorded in the pile,
///        not the transferable length: a picked slice might pay less than r, in which case the contract goes on to
///        pick the next slice. Once the budget for moving between piles is used up, the rest of this pile is
///        checked in place, by index from high to low.
///      - Second pass: when the first pass does not reach the amount, the piles that are not usable are checked in
///        place (for example slices still in the frozen pile after they are unfrozen) and their transferable parts
///        are taken. The second pass does not depend on the rule and always goes by index from high to low.
///        Together the two passes ensure clause 4 of "Transferable balance" in the draft: as long as the amount
///        does not exceed the transferable balance, a transfer does not fail because the sender holds serials that
///        are not transferable.
abstract contract ERCXXXX is SerialHoldings, IERC20Metadata, IERC20Errors, IERC165, IERCXXXX {
    /// @dev The balance and the number of slices in the default pile share one storage slot, so the first receipt
    ///      of a payee writes only one new slot.
    struct Account {
        uint128 balance;
        uint64 defaultRanges; // number of slices in the default pile
        uint64 otherRanges; // total number of slices in the other piles
    }

    /// @dev A batch in memory of slices waiting to be credited, each with its destination pile. Its capacity doubles
    ///      when it runs out.
    struct PileBatch {
        bytes32[] piles;
        uint256[] starts;
        uint256[] lens;
        uint256 m;
    }

    /// @dev The state of one selection by amount.
    struct Take {
        address from;
        address to;
        uint256 remaining;
        uint256 budget; // how many more slices this transfer may move
        bool restricted;
        uint256 delivered; // number of SliceTransferred events emitted so far
        PileBatch out; // slices delivered to `to`
        PileBatch moved; // slices that `from` moves between its own piles
    }

    /// @dev The key of the default pile.
    bytes32 internal constant _DEFAULT_PILE = bytes32(0);
    /// @dev The pile that holds frozen slices. The classification extension does not allow it to be used as a class.
    bytes32 internal constant _FROZEN_PILE = keccak256("ERCXXXX.pile.frozen");

    /// @notice Invalid arguments to transferSlices / burnSlices: the arrays are empty or differ in length, an amount
    ///         is zero, or the slices are not in ascending order or overlap.
    error ERCXXXXInvalidRanges();
    /// @notice The slice is empty or extends beyond the issued serials.
    error ERCXXXXInvalidRange(uint256 start, uint256 amount);
    /// @notice This contract does not open consolidation (clause 7 of "Consolidation" in the draft).
    error ERCXXXXConsolidationClosed();
    /// @notice The serial space is exhausted: the number of issued serials cannot exceed 2^128 - 1.
    error ERCXXXXIssuanceOverflow(uint256 issued, uint256 value);
    /// @notice The index passed to sliceAt is out of bounds.
    error ERCXXXXRangeIndexOutOfBounds(address account, uint256 index);
    /// @notice An operation that takes a position hint: pile of account has no slice at index, or that slice does
    ///         not contain the specified slice.
    ///         After holdings change, an old position may no longer be valid; read the position again and call again.
    error ERCXXXXStaleHint(address account, bytes32 pile, uint256 index);

    mapping(address account => Account) private _accounts;
    /// @dev The non-default piles of each account that are not empty.
    mapping(address account => bytes32[]) private _pileKeys;
    /// @dev The number of slices of a non-default pile (low 128 bits) and its index in _pileKeys plus 1 (high 128
    ///      bits).
    mapping(address account => mapping(bytes32 pile => uint256)) private _pileInfo;
    mapping(address account => mapping(address spender => uint256)) private _allowances;

    uint128 private _totalSupply;
    /// @dev The number of issued serials, which is also the next serial to be issued.
    uint128 private _issued;

    string private _name;
    string private _symbol;

    constructor(string memory name_, string memory symbol_) {
        _name = name_;
        _symbol = symbol_;
    }

    // ───────────────────────── ERC-165 ─────────────────────────

    function supportsInterface(bytes4 interfaceId) public view virtual returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IERCXXXX).interfaceId;
    }

    // ───────────────────────── ERC-20 ─────────────────────────

    function name() public view virtual returns (string memory) {
        return _name;
    }

    function symbol() public view virtual returns (string memory) {
        return _symbol;
    }

    function decimals() public view virtual returns (uint8) {
        return 18;
    }

    function totalSupply() public view virtual returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view virtual returns (uint256) {
        return _accounts[account].balance;
    }

    function allowance(address owner, address spender) public view virtual returns (uint256) {
        return _allowances[owner][spender];
    }

    /// @dev Does not check whether serials are transferable (clause 7 of "Transferable balance" in the draft).
    function approve(address spender, uint256 value) public virtual returns (bool) {
        _approve(msg.sender, spender, value, true);
        return true;
    }

    function transfer(address to, uint256 value) public virtual returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) public virtual returns (bool) {
        _spendAllowance(from, msg.sender, value);
        _transfer(from, to, value);
        return true;
    }

    // ───────────────────────── IERCXXXX ─────────────────────────

    function serialsIssued() public view virtual returns (uint256) {
        return _issued;
    }

    function sliceCount(address account) public view virtual returns (uint256) {
        Account storage a = _accounts[account];
        return uint256(a.defaultRanges) + a.otherRanges;
    }

    /// @dev Lists the default pile first, then the other piles in the order of _pileKeys.
    function sliceAt(address account, uint256 index) public view virtual returns (uint256 start, uint256 amount) {
        Account memory a = _accounts[account];
        if (index < a.defaultRanges) return _rangeAt(account, _DEFAULT_PILE, index);
        uint256 i = index - a.defaultRanges;
        if (i >= a.otherRanges) revert ERCXXXXRangeIndexOutOfBounds(account, index);
        bytes32[] storage keys = _pileKeys[account];
        for (uint256 k;; ++k) {
            bytes32 p = keys[k];
            uint256 n = _pileCount(account, p);
            if (i < n) return _rangeAt(account, p, i);
            i -= n;
        }
    }

    function transferSlices(address to, uint256[] calldata starts, uint256[] calldata amounts)
        public
        virtual
        returns (bool)
    {
        _transferSlices(msg.sender, to, starts, amounts);
        return true;
    }

    function transferableBalanceOf(address from, address to) public view virtual returns (uint256) {
        return _transferableUpTo(from, to, type(uint256).max);
    }

    /// @dev Consolidation is closed by default: reverts with ERCXXXXConsolidationClosed for every caller and every
    ///      argument (clause 7 of "Consolidation" in the draft).
    ///      A token that opens consolidation inherits ERCXXXXConsolidation, which overrides this function and
    ///      consolidatedSpanAt.
    function consolidateSlices(uint256[] calldata, uint256[] calldata) public virtual returns (uint256) {
        revert ERCXXXXConsolidationClosed();
    }

    /// @dev Consolidation is closed by default, so there are no consolidated serials: for an issued serial, returns
    ///      (false, 0, serialsIssued() - serial), that is, the whole span from it to the last issued serial; for a
    ///      serial not yet issued, returns (false, 0, 0) (clauses 9 and 10 of "Consolidation" in the draft).
    function consolidatedSpanAt(uint256 serial)
        public
        view
        virtual
        returns (bool consolidated, uint256 successor, uint256 length)
    {
        uint256 issued = _issued;
        if (serial < issued) length = issued - serial;
        return (false, 0, length);
    }

    // ───────────────────────── Internal functions for extensions and the token ─────────────────────────

    /// @dev Issues value units in the default state to `to` and returns the first serial.
    function _mint(address to, uint256 value) internal virtual returns (uint256 start) {
        return _issue(to, value, _DEFAULT_PILE);
    }

    /// @dev Issues value units to `to`, puts them into pile in the holding of `to`, and returns the first serial.
    ///      When value is zero, only emits Transfer.
    ///      pile has to be the pile where these new serials belong: new serials cannot already be frozen, and their
    ///      class is decided by the caller (the classification extension passes the class).
    ///      All issuance goes through here. An extension that freezes serials or sets their class at issuance has
    ///      to emit the corresponding events after this function (the draft requires them to come after the Transfer
    ///      of the issuance).
    function _issue(address to, uint256 value, bytes32 pile) internal virtual returns (uint256 start) {
        if (to == address(0)) revert ERC20InvalidReceiver(address(0));
        start = _issued;
        if (value > type(uint128).max - start) revert ERCXXXXIssuanceOverflow(start, value);
        _issued = uint128(start + value);
        _totalSupply += uint128(value);
        if (value != 0) {
            _addToPile(to, pile, start, value);
            emit SliceTransferred(address(0), to, start, value);
            unchecked {
                // Cannot overflow: a balance does not exceed the total supply, which does not exceed the number of
                // issued serials.
                _accounts[to].balance += uint128(value);
            }
        }
        emit Transfer(address(0), to, value);
    }

    /// @dev Transfer by amount; the implementation's selection rule decides which serials are transferred.
    function _transfer(address from, address to, uint256 value) internal virtual {
        if (from == address(0)) revert ERC20InvalidSender(address(0));
        if (to == address(0)) revert ERC20InvalidReceiver(address(0));
        uint256 bal = _accounts[from].balance;
        if (bal < value) revert ERC20InsufficientBalance(from, bal, value);
        if (value != 0) {
            if (from == to) {
                // Moves no serials, but the transferable balance is still checked
                // (clause 3 of "Transferable balance" in the draft).
                _requireTransferableAmount(from, to, value);
            } else {
                uint256 ranges = _takeAmount(from, to, value);
                unchecked {
                    _accounts[from].balance = uint128(bal - value);
                    _accounts[to].balance += uint128(value);
                }
                _checkAcceptance(from, to, value, ranges);
            }
        }
        emit Transfer(from, to, value);
    }

    /// @dev Burn by amount.
    function _burn(address from, uint256 value) internal virtual {
        if (from == address(0)) revert ERC20InvalidSender(address(0));
        uint256 bal = _accounts[from].balance;
        if (bal < value) revert ERC20InsufficientBalance(from, bal, value);
        if (value != 0) {
            _takeAmount(from, address(0), value);
            unchecked {
                _accounts[from].balance = uint128(bal - value);
                _totalSupply -= uint128(value);
            }
        }
        emit Transfer(from, address(0), value);
    }

    /// @dev Transfer by serial. When `to` equals `from`, only checks and does not move.
    function _transferSlices(address from, address to, uint256[] calldata starts, uint256[] calldata amounts)
        internal
        virtual
    {
        if (to == address(0)) revert ERC20InvalidReceiver(address(0));
        uint256 value = _moveSerials(from, to, starts, amounts);
        if (from != to) {
            unchecked {
                _accounts[from].balance -= uint128(value);
                _accounts[to].balance += uint128(value);
            }
            // _moveSerials emits one SliceTransferred for each named slice.
            _checkAcceptance(from, to, value, starts.length);
        }
        emit Transfer(from, to, value);
    }

    /// @dev Burn by serial.
    function _burnSlices(address from, uint256[] calldata starts, uint256[] calldata amounts) internal virtual {
        uint256 value = _moveSerials(from, address(0), starts, amounts);
        unchecked {
            _accounts[from].balance -= uint128(value);
            _totalSupply -= uint128(value);
        }
        emit Transfer(from, address(0), value);
    }

    /// @dev Gives [start, start + amount), held by `from`, to `to` (`to` being the zero address means destruction),
    ///      without checking whether the serials are transferable.
    ///      For forced operations, and for privileged operations that an implementation defines itself and that are
    ///      not subject to transferability. When `to` equals `from`, only checks and does not move.
    ///      Emits SliceTransferred and Transfer; a forced operation has to emit SliceForciblyTransferred after it.
    function _moveRange(address from, address to, uint256 start, uint256 amount) internal virtual {
        uint256 end = _movableEnd(from, start, amount);
        if (from == to) {
            if (_heldIn(from, start, end) != amount) revert ERCXXXXNotHeld(from, start, amount);
            emit Transfer(from, to, amount);
            return;
        }
        if (_removeFromAll(from, start, end) != amount) revert ERCXXXXNotHeld(from, start, amount);
        _settleMove(from, to, start, amount);
    }

    /// @dev The same as _moveRange, but does not search the holding: the caller gives the position of these serials,
    ///      that is, the slice at index in pile of `from` (read with _positionOf). [start, start + amount) has to lie
    ///      entirely within that slice, otherwise the call reverts with ERCXXXXStaleHint.
    ///      The other checks and their order are the same as in _moveRange.
    ///      The cost depends on the backend's _removeAt: constant on the slice stack; on the sorted array, taking
    ///      from the middle shifts the following slices, and the position hint cannot save that part.
    function _moveRangeAt(address from, address to, uint256 start, uint256 amount, bytes32 pile, uint256 index)
        internal
        virtual
    {
        uint256 end = _movableEnd(from, start, amount);
        uint256 n = _pileCount(from, pile);
        if (index >= n) revert ERCXXXXStaleHint(from, pile, index);
        (uint256 s, uint256 len) = _rangeAt(from, pile, index);
        if (start < s || end > s + len) revert ERCXXXXStaleHint(from, pile, index);
        if (from == to) {
            emit Transfer(from, to, amount);
            return;
        }
        uint256 newN = _removeAt(from, pile, n, index, start, end);
        if (newN != n) _setPileCount(from, pile, n, newN);
        _settleMove(from, to, start, amount);
    }

    /// @dev The position of serial in the holding of account: its pile, its index in the pile, and the whole slice
    ///      at that position. held is false when account does not hold serial.
    ///      Scans all piles slice by slice, at a cost that grows linearly with the number of slices; meant for
    ///      reading positions off-chain.
    function _positionOf(address account, uint256 serial)
        internal
        view
        returns (bool held, bytes32 pile, uint256 index, uint256 rangeStart, uint256 rangeAmount)
    {
        (held, index, rangeStart, rangeAmount) = _findIn(account, _DEFAULT_PILE, serial);
        if (held || _accounts[account].otherRanges == 0) return (held, _DEFAULT_PILE, index, rangeStart, rangeAmount);
        bytes32[] storage keys = _pileKeys[account];
        for (uint256 k; k < keys.length; ++k) {
            pile = keys[k];
            (held, index, rangeStart, rangeAmount) = _findIn(account, pile, serial);
            if (held) return (true, pile, index, rangeStart, rangeAmount);
        }
        return (false, _DEFAULT_PILE, 0, 0, 0);
    }

    /// @dev Moves the slices in pile of account that do not belong in that pile to the piles where they belong, at
    ///      most maxMoves slices, and returns how many slices it moved; a return value less than maxMoves means that
    ///      the pile is fully tidied. Changes no holder, balance or transferable balance, and emits no events; the
    ///      order and number of the slices reported by sliceAt may change. Starts from the first slice in selection
    ///      order, and within each slice from the end with the largest serials.
    ///      Looks at one pile only; the number of slices read is "the number of in-place slices that come before the
    ///      misplaced slices" plus the number of slices moved, independent of the size of other piles.
    ///      maxMoves limits only the number of slices moved: the in-place slices that come first are read as well;
    ///      when the sorted array inserts slices near the front of the destination pile, it also rewrites all the
    ///      slices that come after them in the destination pile.
    function _tidy(address account, bytes32 pile, uint256 maxMoves) internal returns (uint256 moved) {
        if (maxMoves == 0) return 0;
        uint256 n0 = _pileCount(account, pile);
        uint256 n = n0;
        PileBatch memory batch;
        for (uint256 i = n0; i != 0 && moved < maxMoves; --i) {
            (uint256 s, uint256 len) = _rangeAt(account, pile, i - 1);
            uint256 x = s + len;
            while (x > s) {
                (uint256 segLo,, bytes32 q) = _segmentAt(x - 1);
                uint256 lo = segLo > s ? segLo : s;
                if (q != pile) {
                    if (moved == maxMoves) break;
                    n = _removeAt(account, pile, n, i - 1, lo, x);
                    _push(batch, q, lo, x - lo);
                    ++moved;
                }
                x = lo;
            }
        }
        if (n != n0) _setPileCount(account, pile, n0, n);
        _flush(account, batch);
    }

    function _approve(address owner, address spender, uint256 value, bool emitEvent) internal virtual {
        if (owner == address(0)) revert ERC20InvalidApprover(address(0));
        if (spender == address(0)) revert ERC20InvalidSpender(address(0));
        _allowances[owner][spender] = value;
        if (emitEvent) emit Approval(owner, spender, value);
    }

    function _spendAllowance(address owner, address spender, uint256 value) internal virtual {
        uint256 current = _allowances[owner][spender];
        if (current != type(uint256).max) {
            if (current < value) revert ERC20InsufficientAllowance(spender, current, value);
            unchecked {
                _approve(owner, spender, current - value, false);
            }
        }
    }

    /// @dev Checks that [start, start + amount) is a non-empty slice of issued serials and returns its end. Used by
    ///      freezing and by setting classes.
    function _checkedRange(uint256 start, uint256 amount) internal view returns (uint256 end) {
        uint256 issued = _issued;
        if (amount == 0 || start >= issued || amount > issued - start) revert ERCXXXXInvalidRange(start, amount);
        return start + amount;
    }

    /// @dev All slices held by account, in the same order as sliceAt. For the query functions of extensions.
    function _heldRanges(address account) internal view returns (uint256[] memory starts, uint256[] memory lens) {
        Account memory a = _accounts[account];
        uint256 total = uint256(a.defaultRanges) + a.otherRanges;
        starts = new uint256[](total);
        lens = new uint256[](total);
        uint256 k;
        for (uint256 i; i < a.defaultRanges; ++i) {
            (starts[k], lens[k]) = _rangeAt(account, _DEFAULT_PILE, i);
            ++k;
        }
        if (a.otherRanges == 0) return (starts, lens);
        bytes32[] storage keys = _pileKeys[account];
        for (uint256 j; j < keys.length; ++j) {
            bytes32 p = keys[j];
            uint256 n = _pileCount(account, p);
            for (uint256 i; i < n; ++i) {
                (starts[k], lens[k]) = _rangeAt(account, p, i);
                ++k;
            }
        }
    }

    // ───────────────────────── The two steps of consolidation (for the consolidation module) ─────────────────────────
    // Consolidation gives a holder's units new serials ("Consolidation" in the draft). It changes neither balances
    // nor the total supply and emits no Transfer, so it cannot be put together from issuance and burning.
    // The two functions below must be used as a pair in the same call and with the same value, otherwise balances
    // and holdings disagree. The events are emitted by the consolidation module.
    // Transfers by amount, transferSlices and forced operations call neither of them and do not read the
    // consolidation records.

    /// @dev First step of consolidation: removes the named serials from the piles of account. Changes no balance and
    ///      emits no events.
    ///      Before the call, the consolidation module has already checked starts / amounts by the rules of
    ///      transferSlices in the linked library SerialConsolidations (consolidation): by i in ascending order, first
    ///      the form (ERCXXXXInvalidRanges) and then whether the serials are issued.
    ///      los / his are the endpoints [los[i], his[i]) of the slices returned there, and value is the sum of the
    ///      amounts.
    ///      The serials are removed here in one go, and when some serial is not held by account (including one that is
    ///      destroyed or consolidated), the call reverts with ERCXXXXNotHeld(account, starts[i], amounts[i]) for the
    ///      first such slice.
    ///      The removal uses the backend's _removeSerialsBatch, which scans each pile once rather than searching once
    ///      for each slice; for the slice stack backend the scan is in the linked library SerialStackBatch, one
    ///      DELEGATECALL for each pile that is not empty.
    function _detachSlices(
        address account,
        uint256[] calldata starts,
        uint256[] calldata amounts,
        uint256[] memory los,
        uint256[] memory his,
        uint256 value
    ) internal {
        uint256[] memory got = new uint256[](los.length);
        if (_removeBatchFromAll(account, los, his, got, value) != value) {
            for (uint256 k;; ++k) {
                if (got[k] != amounts[k]) revert ERCXXXXNotHeld(account, starts[k], amounts[k]);
            }
        }
    }

    /// @dev Second step of consolidation: records the value new serials [serialsIssued(), serialsIssued() + value)
    ///      in pile of account, and increases serialsIssued() by value (clause 1 of "Serial model" in the draft).
    ///      Changes neither balances nor the total supply and emits no events. Returns the first new serial.
    ///      When the serial space is exhausted, reverts with ERCXXXXIssuanceOverflow, as issuance does.
    function _issueConsolidated(address account, uint256 value, bytes32 pile) internal returns (uint256 start) {
        start = _issued;
        if (value > type(uint128).max - start) revert ERCXXXXIssuanceOverflow(start, value);
        _issued = uint128(start + value);
        _addToPile(account, pile, start, value);
    }

    // ───────────────────────── Consolidation hooks (overridden by the module and extensions) ─────────────────────────

    /// @dev The successors of the consolidated serials in [start, end), the successors of the consolidated serials
    ///      among those successors, and so on, until no serial is consolidated; parts that fall within [start, end)
    ///      are excluded. The returned slices [starts[i], ends[i]) are in ascending order of start and pairwise
    ///      disjoint, and adjacent ones are merged. The freezing extension uses it to propagate freezes and
    ///      unfreezes to successors (clauses 2 and 3 of "Freezing and consolidation" in the draft).
    ///      By default there are no consolidation records and it returns empty arrays; the consolidation module
    ///      ERCXXXXConsolidation overrides it.
    ///      The empty arrays allocate no memory (an unassigned memory array points to the zero slot, whose length is
    ///      0), and callers read only their length. On a token that does not open consolidation, freezing and
    ///      unfreezing therefore cost only one extra internal call; allocating two empty arrays would shift all
    ///      later memory allocations and make a freeze cost more.
    function _successorPieces(uint256 start, uint256 end)
        internal
        view
        virtual
        returns (uint256[] memory starts, uint256[] memory ends)
    {
        start;
        end;
        return (starts, ends);
    }

    /// @dev Called after a consolidation has given the units the new serials [newStart, newStart + amount), when all
    ///      SliceConsolidated events have already been emitted. pile is the pile where the old serials belong, which
    ///      is also the pile the new serials are put into. The classification extension overrides it to give the new
    ///      serials the class of the old serials and emit SliceClassified (clause 2 of "Classes and consolidation"
    ///      in the draft).
    function _afterConsolidation(uint256 newStart, uint256 amount, bytes32 pile) internal virtual {
        newStart;
        amount;
        pile;
    }

    // ───────────────────────── Restriction hooks (overridden by extensions) ─────────────────────────

    /// @dev Whether any restriction attached to serials exists. When false, every held serial is transferable, and
    ///      selection need not check slice by slice.
    function _hasRestrictions() internal view virtual returns (bool) {
        return false;
    }

    /// @dev The slice [lo, hi) of serials with the same state that contains serial, and the pile where these serials
    ///      belong.
    ///      The pile where they belong depends only on the state of the serials, not on whom they are transferred to;
    ///      whether they are transferable is decided by _pileUsable(pile, from, to).
    ///      An override first calls super, then narrows [lo, hi) to the part where its own state is also the same.
    function _segmentAt(uint256 serial) internal view virtual returns (uint256 lo, uint256 hi, bytes32 pile) {
        serial;
        return (0, type(uint256).max, _DEFAULT_PILE);
    }

    /// @dev Whether serials that belong in pile are transferable for (from, to).
    function _pileUsable(bytes32 pile, address from, address to) internal view virtual returns (bool) {
        from;
        to;
        return pile == _DEFAULT_PILE;
    }

    /// @dev The hook for the acceptance check (the section "Acceptance check" of the draft), overridden by the
    ///      extension ERCXXXXAcceptance; reverts when `to` refuses.
    ///      By default it does nothing, so a token that does not inherit that extension does not support the
    ///      acceptance check and makes no external calls.
    ///      Called only in transfers initiated by the holder (_transfer and _transferSlices), and only when
    ///      from != to and value != 0; issuance (_issue), forced operations (_moveRange, _moveRangeAt) and burning
    ///      do not call it.
    ///      When it is called, the serials and the balance of this incoming transfer are already recorded for `to`,
    ///      SliceTransferred has been emitted, and Transfer has not yet been emitted.
    ///      ranges is the number of SliceTransferred events emitted for this incoming transfer. The function is
    ///      view, so its calls to the recipient can only be STATICCALL.
    function _checkAcceptance(address from, address to, uint256 value, uint256 ranges) internal view virtual {}

    /// @dev The maximum number of slices that are not transferable that one transfer by amount moves to the piles
    ///      where they belong.
    ///      Moving a slice writes storage; the slices beyond this limit are skipped in place, at a smaller cost per
    ///      slice per transfer, and left for later transfers to continue tidying.
    function _maxPileMoves() internal view virtual returns (uint256) {
        return 32;
    }

    // ───────────────────────── Selection by amount ─────────────────────────

    /// @dev Takes from `from` value units that are transferable for (from, to), delivers them to `to`, and emits
    ///      SliceTransferred. Does not change balances.
    ///      Returns the number of SliceTransferred events emitted.
    function _takeAmount(address from, address to, uint256 value) private returns (uint256) {
        Take memory c;
        c.from = from;
        c.to = to;
        c.remaining = value;
        c.restricted = _hasRestrictions();
        c.budget = _maxPileMoves();
        // First pass: the usable non-default piles, then the default pile.
        if (_accounts[from].otherRanges != 0) {
            bytes32[] storage keys = _pileKeys[from];
            // From back to front: while a pile is handled, it may be removed by swap and pop, and the pile swapped
            // into its place is one already handled, or one just registered that is not usable.
            for (uint256 k = keys.length; k != 0 && c.remaining != 0; --k) {
                bytes32 p = keys[k - 1];
                if (c.restricted && !_pileUsable(p, from, to)) continue;
                _takeFromPile(c, p);
            }
        }
        if (c.remaining != 0 && (!c.restricted || _pileUsable(_DEFAULT_PILE, from, to))) {
            _takeFromPile(c, _DEFAULT_PILE);
        }
        // Second pass: the usable piles were all examined in the first pass; here the piles that are not usable
        // are checked in place.
        if (c.remaining != 0 && c.restricted) {
            if (!_pileUsable(_DEFAULT_PILE, from, to)) _takeInPlaceFromPile(c, _DEFAULT_PILE);
            bytes32[] storage keys = _pileKeys[from];
            for (uint256 k = keys.length; k != 0 && c.remaining != 0; --k) {
                bytes32 p = keys[k - 1];
                if (!_pileUsable(p, from, to)) _takeInPlaceFromPile(c, p);
            }
        }
        if (c.remaining != 0) {
            // The two passes went through the whole holding, so the units taken are all of the transferable units.
            revert ERCXXXXInsufficientTransferableBalance(from, to, value, value - c.remaining);
        }
        return c.delivered;
    }

    /// @dev First pass: takes from the usable pile p, starting from the first slice in selection order. A part that
    ///      is not transferable is moved to the pile where it belongs while the budget lasts; once the budget is used
    ///      up, the remaining slices of this pile are checked in place.
    function _takeFromPile(Take memory c, bytes32 p) private {
        uint256 w = _selectionWindow();
        if (w != 0) {
            _takeFromPileWindow(c, p, w);
            return;
        }
        uint256 n0 = _pileCount(c.from, p);
        uint256 n = n0;
        while (c.remaining != 0 && n != 0) {
            (uint256 s, uint256 len) = _rangeAt(c.from, p, n - 1);
            uint256 x = s + len;
            uint256 lo = s;
            bytes32 q = _DEFAULT_PILE;
            if (c.restricted) {
                uint256 segLo;
                (segLo,, q) = _segmentAt(x - 1);
                if (segLo > lo) lo = segLo;
                if (q != p && !_pileUsable(q, c.from, c.to)) {
                    if (c.budget == 0) {
                        n = _takeInPlace(c, p, n);
                        break;
                    }
                    --c.budget;
                    // q is not usable, so it cannot be p; once moved away, this part is not met again in this pile.
                    n = _setTopLen(c.from, p, n, lo - s);
                    _push(c.moved, q, lo, x - lo);
                    continue;
                }
            }
            uint256 take = x - lo < c.remaining ? x - lo : c.remaining;
            n = _setTopLen(c.from, p, n, len - take);
            c.remaining -= take;
            _deliver(c, q, x - take, take);
        }
        if (n != n0) _setPileCount(c.from, p, n0, n);
        _flush(c.from, c.moved);
        if (c.to != address(0)) _flush(c.to, c.out);
    }

    /// @dev The first pass under the second rule: each time picks a slice in the window of pile p (_pickInWindow);
    ///      otherwise the same as _takeFromPile.
    ///      What is taken or moved away is always at the end of the picked slice with the largest serials, so
    ///      _removeAt does not append a remainder at the end: when only part is taken, the lower remainder stays in
    ///      place; when the whole slice is taken, the backend moves the last slice into this position (slice
    ///      stack), and that slice is still in the window afterward.
    function _takeFromPileWindow(Take memory c, bytes32 p, uint256 w) private {
        uint256 n0 = _pileCount(c.from, p);
        uint256 n = n0;
        while (c.remaining != 0 && n != 0) {
            (uint256 i, uint256 lo, uint256 x) = _pickInWindow(c.from, p, n, w, c.remaining);
            bytes32 q = _DEFAULT_PILE;
            if (c.restricted) {
                uint256 segLo;
                (segLo,, q) = _segmentAt(x - 1);
                if (segLo > lo) lo = segLo;
                if (q != p && !_pileUsable(q, c.from, c.to)) {
                    if (c.budget == 0) {
                        n = _takeInPlace(c, p, n);
                        break;
                    }
                    --c.budget;
                    n = _removeAt(c.from, p, n, i, lo, x);
                    _push(c.moved, q, lo, x - lo);
                    continue;
                }
            }
            uint256 take = x - lo < c.remaining ? x - lo : c.remaining;
            n = _removeAt(c.from, p, n, i, x - take, x);
            c.remaining -= take;
            _deliver(c, q, x - take, take);
        }
        if (n != n0) _setPileCount(c.from, p, n0, n);
        _flush(c.from, c.moved);
        if (c.to != address(0)) _flush(c.to, c.out);
    }

    /// @dev One pick under the second rule: among indexes [n - w, n) of pile p (the whole pile when it has fewer
    ///      than w slices), if some slices have a recorded length of at least need, picks the shortest of them,
    ///      otherwise picks the longest; among slices of equal length, picks the one with the larger index. Returns
    ///      the index i and the slice [s, x). The caller ensures that n is not zero.
    ///      Reads from the end with the larger indexes downward and stops at a slice whose length is exactly need:
    ///      a shorter slice is not enough, and a slice of the same length has a smaller index.
    function _pickInWindow(address account, bytes32 p, uint256 n, uint256 w, uint256 need)
        private
        view
        returns (uint256 i, uint256 s, uint256 x)
    {
        uint256 end = n > w ? n - w : 0;
        uint256 best = type(uint256).max;
        for (uint256 k = n; k != end;) {
            unchecked {
                --k;
            }
            (uint256 ks, uint256 len) = _rangeAt(account, p, k);
            // Slices that are long enough are compared by how many units they exceed need by; slices that are not
            // long enough rank after all of those and are compared by how many units they fall short; in both
            // cases smaller is better.
            // Lengths and need are both less than 2^128, so this cannot overflow.
            uint256 score = len >= need ? len - need : (1 << 128) + need - len;
            if (score < best) {
                (best, i, s, x) = (score, k, ks, ks + len);
                if (score == 0) break;
            }
        }
    }

    /// @dev Second pass: checks pile p in place and takes its transferable parts.
    function _takeInPlaceFromPile(Take memory c, bytes32 p) private {
        uint256 n0 = _pileCount(c.from, p);
        uint256 n = _takeInPlace(c, p, n0);
        if (n != n0) _setPileCount(c.from, p, n0, n);
        if (c.to != address(0)) _flush(c.to, c.out);
    }

    /// @dev Checks indexes [0, n) of pile p in place, from high to low and within each slice from the end with the
    ///      largest serials, takes the transferable parts, and returns the new number of slices.
    ///      _removeAt changes the positions only of slices at indexes not less than the current one, all of which
    ///      have already been visited.
    function _takeInPlace(Take memory c, bytes32 p, uint256 n) private returns (uint256) {
        for (uint256 i = n; i != 0 && c.remaining != 0; --i) {
            (uint256 s, uint256 len) = _rangeAt(c.from, p, i - 1);
            uint256 x = s + len;
            while (x > s && c.remaining != 0) {
                (uint256 segLo,, bytes32 q) = _segmentAt(x - 1);
                uint256 lo = segLo > s ? segLo : s;
                if (_pileUsable(q, c.from, c.to)) {
                    uint256 take = x - lo < c.remaining ? x - lo : c.remaining;
                    n = _removeAt(c.from, p, n, i - 1, x - take, x);
                    c.remaining -= take;
                    _deliver(c, q, x - take, take);
                    x -= take;
                } else {
                    x = lo;
                }
            }
        }
        return n;
    }

    /// @dev Emits SliceTransferred and adds this slice to the batch to be delivered to `to` (into pile q of `to`).
    function _deliver(Take memory c, bytes32 q, uint256 start, uint256 len) private {
        emit SliceTransferred(c.from, c.to, start, len);
        unchecked {
            ++c.delivered;
        }
        if (c.to != address(0)) _push(c.out, q, start, len);
    }

    /// @dev Does nothing when the amount does not exceed the transferable balance; otherwise reverts with the exact
    ///      transferable balance.
    function _requireTransferableAmount(address from, address to, uint256 value) private view {
        uint256 t = _transferableUpTo(from, to, value);
        if (t < value) revert ERCXXXXInsufficientTransferableBalance(from, to, value, t);
    }

    /// @dev The number of units held by `from` that are transferable for (from, to); stops counting once the total
    ///      reaches need.
    function _transferableUpTo(address from, address to, uint256 need) private view returns (uint256 total) {
        Account memory a = _accounts[from];
        if (!_hasRestrictions()) return a.balance;
        total = _pileTransferable(from, to, _DEFAULT_PILE, need, total);
        if (a.otherRanges == 0) return total;
        bytes32[] storage keys = _pileKeys[from];
        for (uint256 k; k < keys.length && total < need; ++k) {
            total = _pileTransferable(from, to, keys[k], need, total);
        }
    }

    function _pileTransferable(address from, address to, bytes32 p, uint256 need, uint256 total)
        private
        view
        returns (uint256)
    {
        uint256 n = _pileCount(from, p);
        for (uint256 i; i < n && total < need; ++i) {
            (uint256 s, uint256 len) = _rangeAt(from, p, i);
            uint256 e = s + len;
            uint256 x = s;
            while (x < e) {
                (, uint256 hi, bytes32 q) = _segmentAt(x);
                if (hi > e) hi = e;
                if (_pileUsable(q, from, to)) total += hi - x;
                x = hi;
            }
        }
        return total;
    }

    // ───────────────────────── Moving by serial ─────────────────────────

    /// @dev The part shared by transferSlices and burnSlices. `to` being the zero address means a burn; when `to`
    ///      equals `from`, only checks and does not move.
    ///      Emits one SliceTransferred for each named slice. Returns the sum of the amounts of the slices. Does not
    ///      change balances.
    function _moveSerials(address from, address to, uint256[] calldata starts, uint256[] calldata amounts)
        private
        returns (uint256 value)
    {
        uint256 count = starts.length;
        if (count == 0 || count != amounts.length) revert ERCXXXXInvalidRanges();
        Take memory c;
        c.from = from;
        c.to = to;
        c.restricted = _hasRestrictions();
        uint256 previousEnd;
        for (uint256 k; k < count; ++k) {
            uint256 len = amounts[k];
            if (len == 0 || (k != 0 && starts[k] < previousEnd)) revert ERCXXXXInvalidRanges();
            previousEnd = _moveOneRange(c, starts[k], len);
            value += len;
        }
        if (from != to && to != address(0)) _flush(to, c.out);
    }

    /// @dev Checks and moves one named slice [a, a + len) and returns its end. The parts for `to` are added to c.out
    ///      (in ascending order of start).
    function _moveOneRange(Take memory c, uint256 a, uint256 len) private returns (uint256 b) {
        uint256 issued = _issued;
        if (a >= issued || len > issued - a) revert ERCXXXXNotHeld(c.from, a, len);
        b = a + len;
        bool credit = c.from != c.to && c.to != address(0);
        // The cheap transferability check comes first, then the locating, whose cost grows with the number of
        // slices; the draft does not specify which of the two errors comes first.
        if (c.restricted) {
            uint256 x = a;
            while (x < b) {
                (, uint256 hi, bytes32 q) = _segmentAt(x);
                if (hi > b) hi = b;
                if (!_pileUsable(q, c.from, c.to)) revert ERCXXXXNotTransferable(c.from, c.to, a, len);
                if (credit) _push(c.out, q, x, hi - x);
                x = hi;
            }
        } else if (credit) {
            _push(c.out, _DEFAULT_PILE, a, len);
        }
        if (c.from == c.to) {
            if (_heldIn(c.from, a, b) != len) revert ERCXXXXNotHeld(c.from, a, len);
        } else {
            if (_removeFromAll(c.from, a, b) != len) revert ERCXXXXNotHeld(c.from, a, len);
            emit SliceTransferred(c.from, c.to, a, len);
        }
    }

    /// @dev The checks shared by _moveRange and _moveRangeAt before the move: the slice is not empty and is issued.
    ///      Returns its end.
    function _movableEnd(address from, uint256 start, uint256 amount) private view returns (uint256) {
        if (amount == 0) revert ERCXXXXInvalidRange(start, amount);
        uint256 issued = _issued;
        if (start >= issued || amount > issued - start) revert ERCXXXXNotHeld(from, start, amount);
        return start + amount;
    }

    /// @dev The final steps shared by _moveRange and _moveRangeAt: the serials have been removed from `from`;
    ///      credits them to `to`, emits the events and updates the balances.
    function _settleMove(address from, address to, uint256 start, uint256 amount) private {
        if (to != address(0)) _credit(to, start, start + amount);
        emit SliceTransferred(from, to, start, amount);
        unchecked {
            _accounts[from].balance -= uint128(amount);
            if (to == address(0)) _totalSupply -= uint128(amount);
            else _accounts[to].balance += uint128(amount);
        }
        emit Transfer(from, to, amount);
    }

    /// @dev Removes the serials that fall within [a, b) from all piles of `from` and returns the number removed.
    ///      Looks in the default pile first.
    function _removeFromAll(address from, uint256 a, uint256 b) private returns (uint256 removed) {
        uint256 want = b - a;
        removed = _removeFromPile(from, _DEFAULT_PILE, a, b);
        if (removed == want || _accounts[from].otherRanges == 0) return removed;
        bytes32[] storage keys = _pileKeys[from];
        for (uint256 k = keys.length; k != 0 && removed < want; --k) {
            removed += _removeFromPile(from, keys[k - 1], a, b);
        }
    }

    /// @dev Removes in one go, from all piles of account, the serials that fall within the given slices, and
    ///      returns the number removed. Looks in the default pile first.
    function _removeBatchFromAll(
        address account,
        uint256[] memory los,
        uint256[] memory his,
        uint256[] memory got,
        uint256 want
    ) private returns (uint256 total) {
        total = _removeFromPileBatch(account, _DEFAULT_PILE, los, his, got, want);
        if (total == want || _accounts[account].otherRanges == 0) return total;
        bytes32[] storage keys = _pileKeys[account];
        // From back to front: when a pile becomes empty, the last pile is swapped into its place, and that pile
        // has already been visited.
        for (uint256 k = keys.length; k != 0 && total < want; --k) {
            total += _removeFromPileBatch(account, keys[k - 1], los, his, got, want - total);
        }
    }

    /// @dev Removes in one go, from pile p of account, the serials that fall within the given slices, and returns
    ///      the number removed.
    function _removeFromPileBatch(
        address account,
        bytes32 p,
        uint256[] memory los,
        uint256[] memory his,
        uint256[] memory got,
        uint256 want
    ) private returns (uint256 removed) {
        uint256 n0 = _pileCount(account, p);
        if (n0 == 0) return 0;
        uint256 n;
        (n, removed) = _removeSerialsBatch(account, p, n0, los, his, got, want);
        if (n != n0) _setPileCount(account, p, n0, n);
    }

    function _removeFromPile(address from, bytes32 p, uint256 a, uint256 b) private returns (uint256 removed) {
        uint256 n0 = _pileCount(from, p);
        if (n0 == 0) return 0;
        uint256 n;
        (n, removed) = _removeSerials(from, p, n0, a, b);
        if (n != n0) _setPileCount(from, p, n0, n);
    }

    /// @dev The number of serials held by `from` that fall within [a, b).
    function _heldIn(address from, uint256 a, uint256 b) private view returns (uint256 total) {
        (uint256[] memory starts, uint256[] memory lens) = _heldRanges(from);
        for (uint256 i; i < starts.length; ++i) {
            uint256 s = starts[i];
            uint256 e = s + lens[i];
            if (s >= b || e <= a) continue;
            total += (e < b ? e : b) - (s > a ? s : a);
        }
    }

    // ───────────────────────── Locating and tidying ─────────────────────────

    /// @dev Searches pile p slice by slice for the slice that contains serial.
    function _findIn(address account, bytes32 p, uint256 serial)
        private
        view
        returns (bool held, uint256 index, uint256 start, uint256 len)
    {
        uint256 n = _pileCount(account, p);
        for (uint256 i; i < n; ++i) {
            (start, len) = _rangeAt(account, p, i);
            if (serial >= start && serial - start < len) return (true, i, start, len);
        }
        return (false, 0, 0, 0);
    }

    // ───────────────────────── Piles ─────────────────────────

    /// @dev Puts [a, b) into the piles of `to` where its parts belong according to their current state. Used for
    ///      credits that do not go through selection (forced transfers).
    function _credit(address to, uint256 a, uint256 b) private {
        if (!_hasRestrictions()) {
            _addToPile(to, _DEFAULT_PILE, a, b - a);
            return;
        }
        uint256 x = a;
        while (x < b) {
            (, uint256 hi, bytes32 q) = _segmentAt(x);
            if (hi > b) hi = b;
            _addToPile(to, q, x, hi - x);
            x = hi;
        }
    }

    function _addToPile(address account, bytes32 p, uint256 start, uint256 len) private {
        uint256 n = _pileCount(account, p);
        uint256 newN = _addRange(account, p, n, start, len);
        if (newN != n) _setPileCount(account, p, n, newN);
    }

    /// @dev Writes a batch of slices into the holding of account, grouped by destination pile, then empties the
    ///      batch. Each group keeps the original relative order, so it is still strictly monotonic (see
    ///      SerialHoldings._addRanges).
    function _flush(address account, PileBatch memory b) private {
        uint256 m = b.m;
        if (m == 0) return;
        b.m = 0;
        if (m == 1) {
            _addToPile(account, b.piles[0], b.starts[0], b.lens[0]);
            return;
        }
        bool[] memory done = new bool[](m);
        uint256[] memory gs = new uint256[](m);
        uint256[] memory gl = new uint256[](m);
        for (uint256 i; i < m; ++i) {
            if (done[i]) continue;
            bytes32 p = b.piles[i];
            uint256 g;
            for (uint256 j = i; j < m; ++j) {
                if (done[j] || b.piles[j] != p) continue;
                done[j] = true;
                (gs[g], gl[g]) = (b.starts[j], b.lens[j]);
                ++g;
            }
            uint256 n = _pileCount(account, p);
            uint256 newN = _addRanges(account, p, n, gs, gl, g);
            if (newN != n) _setPileCount(account, p, n, newN);
        }
    }

    /// @dev Appends a slice to a batch, doubling its capacity when it runs out.
    function _push(PileBatch memory b, bytes32 pile, uint256 start, uint256 len) private pure {
        uint256 m = b.m;
        if (m == b.starts.length) {
            uint256 cap = m == 0 ? 4 : 2 * m;
            bytes32[] memory np = new bytes32[](cap);
            uint256[] memory ns = new uint256[](cap);
            uint256[] memory nl = new uint256[](cap);
            for (uint256 i; i < m; ++i) {
                (np[i], ns[i], nl[i]) = (b.piles[i], b.starts[i], b.lens[i]);
            }
            (b.piles, b.starts, b.lens) = (np, ns, nl);
        }
        (b.piles[m], b.starts[m], b.lens[m]) = (pile, start, len);
        b.m = m + 1;
    }

    function _pileCount(address account, bytes32 p) private view returns (uint256) {
        if (p == _DEFAULT_PILE) return _accounts[account].defaultRanges;
        return uint128(_pileInfo[account][p]);
    }

    /// @dev Updates the number of slices of a pile. A non-default pile is registered when it goes from empty to
    ///      non-empty, and deregistered when it goes from non-empty to empty (removed by swap and pop).
    ///      Reads and writes storage directly and does not rely on an Account cached by the caller.
    function _setPileCount(address account, bytes32 p, uint256 oldN, uint256 newN) private {
        Account storage acct = _accounts[account];
        if (p == _DEFAULT_PILE) {
            acct.defaultRanges = uint64(newN);
            return;
        }
        acct.otherRanges = uint64(uint256(acct.otherRanges) + newN - oldN);
        mapping(bytes32 => uint256) storage info = _pileInfo[account];
        bytes32[] storage keys = _pileKeys[account];
        if (oldN == 0) {
            keys.push(p);
            info[p] = (keys.length << 128) | newN;
        } else if (newN == 0) {
            uint256 slot = info[p] >> 128;
            uint256 last = keys.length;
            if (slot != last) {
                bytes32 moved = keys[last - 1];
                keys[slot - 1] = moved;
                info[moved] = (slot << 128) | uint128(info[moved]);
            }
            keys.pop();
            delete info[p];
        } else {
            info[p] = (info[p] >> 128 << 128) | newN;
        }
    }
}

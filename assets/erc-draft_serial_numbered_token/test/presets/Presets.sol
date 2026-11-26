// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERCXXXX} from "../../contracts/ERCXXXX.sol";
import {ERCXXXXBurnable} from "../../contracts/extensions/ERCXXXXBurnable.sol";
import {ERCXXXXFreezable} from "../../contracts/extensions/ERCXXXXFreezable.sol";
import {ERCXXXXClassified} from "../../contracts/extensions/ERCXXXXClassified.sol";
import {ERCXXXXAllowlist} from "../../contracts/extensions/ERCXXXXAllowlist.sol";
import {ERCXXXXTidy} from "../../contracts/extensions/ERCXXXXTidy.sol";
import {ERCXXXXAcceptance} from "../../contracts/extensions/ERCXXXXAcceptance.sol";
import {ERCXXXXConsolidation} from "../../contracts/extensions/ERCXXXXConsolidation.sol";
import {SerialHoldingsStack} from "../../contracts/holdings/SerialHoldingsStack.sol";
import {SerialHoldingsSorted} from "../../contracts/holdings/SerialHoldingsSorted.sol";

/// @dev Flow rules of the test tokens. The allowlist rule uses the example class ERCXXXXAllowlist; under the "lock
///      until a time" rule, units cannot be burned before the unlock time either.
enum Rule {
    None,
    Allowlist,
    LockUntil
}

/// @dev A single admin for testing, in charge of minting, freezing, forced operations, registering reasons, and
///      defining and setting classes.
abstract contract TestAdmin {
    error NotAdmin();

    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);

    address public admin;

    modifier onlyAdmin() {
        _checkAdmin(msg.sender);
        _;
    }

    constructor(address admin_) {
        admin = admin_;
        emit AdminTransferred(address(0), admin_);
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        emit AdminTransferred(admin, newAdmin);
        admin = newAdmin;
    }

    function _checkAdmin(address caller) internal view {
        if (caller != admin) revert NotAdmin();
    }
}

/// @dev The part common to every combination: the core, burning and minting.
abstract contract PresetBase is ERCXXXXBurnable, TestAdmin {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_, address admin_)
        ERCXXXX(name_, symbol_)
        TestAdmin(admin_)
    {
        _decimals = decimals_;
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 value) external onlyAdmin {
        _mint(to, value);
    }
}

/// @dev Admin functions of the freezing extension.
abstract contract FreezeAdmin is ERCXXXXFreezable, TestAdmin {
    function setReasonInfo(bytes32 reason, string calldata name_, string calldata uri) external onlyAdmin {
        _setReasonInfo(reason, name_, uri);
    }

    function _authorizeFreeze(address caller, bytes32, bool) internal view override {
        _checkAdmin(caller);
    }

    function _authorizeForced(address caller, address, address) internal view override {
        _checkAdmin(caller);
    }
}

/// @dev Admin functions of the classification extension, and the "lock until a time" rule.
abstract contract ClassAdmin is ERCXXXXAllowlist, TestAdmin {
    mapping(bytes32 => bool) private _isLock;
    mapping(bytes32 => uint64) private _unlockTime;

    function mintWithClass(address to, uint256 value, bytes32 classId) external onlyAdmin {
        _mintWithClass(to, value, classId);
    }

    /// @notice The allowlist rule is defined with _defineAllowlistClass, the other rules with _defineClass. The most
    ///         recent definition decides the rule.
    function defineClass(bytes32 classId, Rule rule, uint64 unlockTime, string calldata name_, string calldata uri)
        external
        onlyAdmin
    {
        if (rule == Rule.Allowlist) _defineAllowlistClass(classId, name_, uri);
        else _defineClass(classId, name_, uri);
        _isLock[classId] = rule == Rule.LockUntil;
        _unlockTime[classId] = unlockTime;
    }

    function setAllowed(bytes32 classId, address account, bool allowed) external onlyAdmin {
        _setDesignatedRecipient(classId, account, allowed);
    }

    function setClass(uint256 start, uint256 amount, bytes32 classId) external onlyAdmin {
        _setClass(start, amount, classId);
    }

    function _classAllows(bytes32 classId, address from, address to) internal view virtual override returns (bool) {
        if (_isLock[classId]) return block.timestamp >= _unlockTime[classId];
        return super._classAllows(classId, from, to);
    }
}

// ───────────────────────── Four combinations ─────────────────────────
// The combinations with freezing or classification include the tidying function ERCXXXXTidy; the combination with
// only the core has no slices outside the pile where they belong and does not need it.

abstract contract PresetCore is PresetBase {}

abstract contract PresetFreeze is PresetBase, FreezeAdmin, ERCXXXXTidy {
    function decimals() public view override(ERCXXXX, PresetBase) returns (uint8) {
        return super.decimals();
    }

    function supportsInterface(bytes4 id) public view override(ERCXXXX, ERCXXXXFreezable) returns (bool) {
        return super.supportsInterface(id);
    }

    function _hasRestrictions() internal view override(ERCXXXX, ERCXXXXFreezable) returns (bool) {
        return super._hasRestrictions();
    }

    function _segmentAt(uint256 serial)
        internal
        view
        override(ERCXXXX, ERCXXXXFreezable)
        returns (uint256, uint256, bytes32)
    {
        return super._segmentAt(serial);
    }
}

abstract contract PresetClass is PresetBase, ClassAdmin, ERCXXXXTidy {
    function decimals() public view override(ERCXXXX, PresetBase) returns (uint8) {
        return super.decimals();
    }

    function supportsInterface(bytes4 id) public view override(ERCXXXX, ERCXXXXClassified) returns (bool) {
        return super.supportsInterface(id);
    }

    function _hasRestrictions() internal view override(ERCXXXX, ERCXXXXClassified) returns (bool) {
        return super._hasRestrictions();
    }

    function _segmentAt(uint256 serial)
        internal
        view
        override(ERCXXXX, ERCXXXXClassified)
        returns (uint256, uint256, bytes32)
    {
        return super._segmentAt(serial);
    }

    function _pileUsable(bytes32 pile, address from, address to)
        internal
        view
        override(ERCXXXX, ERCXXXXClassified)
        returns (bool)
    {
        return super._pileUsable(pile, from, to);
    }

    function _afterConsolidation(uint256 newStart, uint256 amount, bytes32 pile)
        internal
        override(ERCXXXX, ERCXXXXClassified)
    {
        super._afterConsolidation(newStart, amount, pile);
    }
}

abstract contract PresetBoth is PresetBase, FreezeAdmin, ClassAdmin, ERCXXXXTidy {
    function decimals() public view override(ERCXXXX, PresetBase) returns (uint8) {
        return super.decimals();
    }

    function supportsInterface(bytes4 id)
        public
        view
        override(ERCXXXX, ERCXXXXFreezable, ERCXXXXClassified)
        returns (bool)
    {
        return super.supportsInterface(id);
    }

    function _hasRestrictions()
        internal
        view
        override(ERCXXXX, ERCXXXXFreezable, ERCXXXXClassified)
        returns (bool)
    {
        return super._hasRestrictions();
    }

    function _segmentAt(uint256 serial)
        internal
        view
        override(ERCXXXX, ERCXXXXFreezable, ERCXXXXClassified)
        returns (uint256, uint256, bytes32)
    {
        return super._segmentAt(serial);
    }

    function _pileUsable(bytes32 pile, address from, address to)
        internal
        view
        override(ERCXXXX, ERCXXXXClassified)
        returns (bool)
    {
        return super._pileUsable(pile, from, to);
    }

    function _afterConsolidation(uint256 newStart, uint256 amount, bytes32 pile)
        internal
        override(ERCXXXX, ERCXXXXClassified)
    {
        super._afterConsolidation(newStart, amount, pile);
    }
}

// ───────────────────────── Acceptance check ─────────────────────────
// The acceptance check does not depend on state attached to serials, so it forms a group of its own: the core with
// only the acceptance check, and all three extensions together.
// The admin's mint and mintWithClass are restricted issuance and do not query receiving contracts; openMint and
// openMintWithClass can be called by anyone and serve to test clause 9 of "Acceptance check" in the draft.

abstract contract AcceptanceOpen is ERCXXXXAcceptance {
    function openMint(address to, uint256 value) external {
        _mintAccepted(to, value);
    }
}

abstract contract PresetAccept is PresetBase, AcceptanceOpen {
    function decimals() public view override(ERCXXXX, PresetBase) returns (uint8) {
        return super.decimals();
    }

    function supportsInterface(bytes4 id) public view override(ERCXXXX, ERCXXXXAcceptance) returns (bool) {
        return super.supportsInterface(id);
    }

    function _checkAcceptance(address from, address to, uint256 value, uint256 ranges)
        internal
        view
        override(ERCXXXX, ERCXXXXAcceptance)
    {
        super._checkAcceptance(from, to, value, ranges);
    }
}

abstract contract PresetAll is PresetBase, FreezeAdmin, ClassAdmin, ERCXXXXTidy, AcceptanceOpen {
    /// @dev Issuance with a class that any caller can execute: after the issuance, it asks the recipient under the
    ///      acceptance check.
    function openMintWithClass(address to, uint256 value, bytes32 classId) external {
        _mintWithClass(to, value, classId);
        _requireIssuanceAccepted(to, value);
    }

    function decimals() public view override(ERCXXXX, PresetBase) returns (uint8) {
        return super.decimals();
    }

    function supportsInterface(bytes4 id)
        public
        view
        override(ERCXXXX, ERCXXXXFreezable, ERCXXXXClassified, ERCXXXXAcceptance)
        returns (bool)
    {
        return super.supportsInterface(id);
    }

    function _hasRestrictions()
        internal
        view
        override(ERCXXXX, ERCXXXXFreezable, ERCXXXXClassified)
        returns (bool)
    {
        return super._hasRestrictions();
    }

    function _segmentAt(uint256 serial)
        internal
        view
        override(ERCXXXX, ERCXXXXFreezable, ERCXXXXClassified)
        returns (uint256, uint256, bytes32)
    {
        return super._segmentAt(serial);
    }

    function _pileUsable(bytes32 pile, address from, address to)
        internal
        view
        override(ERCXXXX, ERCXXXXClassified)
        returns (bool)
    {
        return super._pileUsable(pile, from, to);
    }

    function _afterConsolidation(uint256 newStart, uint256 amount, bytes32 pile)
        internal
        override(ERCXXXX, ERCXXXXClassified)
    {
        super._afterConsolidation(newStart, amount, pile);
    }

    function _checkAcceptance(address from, address to, uint256 value, uint256 ranges)
        internal
        view
        override(ERCXXXX, ERCXXXXAcceptance)
    {
        super._checkAcceptance(from, to, value, ranges);
    }
}

// ───────────────────────── Consolidation opened ─────────────────────────
// Core, freezing, classification and both, each with the consolidation module ERCXXXXConsolidation added. The
// combinations above do not inherit it, and consolidation is closed in them (the default implementation of the core).
// The deployment parameters all keep their defaults: any holder can consolidate, at least 1 group per consolidation,
// and no limit on the number of slices of the account.

abstract contract PresetCoreConsol is PresetBase, ERCXXXXConsolidation {
    function consolidateSlices(uint256[] calldata starts, uint256[] calldata amounts)
        public
        override(ERCXXXX, ERCXXXXConsolidation)
        returns (uint256)
    {
        return super.consolidateSlices(starts, amounts);
    }

    function consolidatedSpanAt(uint256 serial)
        public
        view
        override(ERCXXXX, ERCXXXXConsolidation)
        returns (bool, uint256, uint256)
    {
        return super.consolidatedSpanAt(serial);
    }

    function decimals() public view override(ERCXXXX, PresetBase) returns (uint8) {
        return super.decimals();
    }

    function _successorPieces(uint256 start, uint256 end)
        internal
        view
        override(ERCXXXX, ERCXXXXConsolidation)
        returns (uint256[] memory, uint256[] memory)
    {
        return super._successorPieces(start, end);
    }
}

abstract contract PresetFreezeConsol is PresetBase, FreezeAdmin, ERCXXXXTidy, ERCXXXXConsolidation {
    function consolidateSlices(uint256[] calldata starts, uint256[] calldata amounts)
        public
        override(ERCXXXX, ERCXXXXConsolidation)
        returns (uint256)
    {
        return super.consolidateSlices(starts, amounts);
    }

    function consolidatedSpanAt(uint256 serial)
        public
        view
        override(ERCXXXX, ERCXXXXConsolidation)
        returns (bool, uint256, uint256)
    {
        return super.consolidatedSpanAt(serial);
    }

    function decimals() public view override(ERCXXXX, PresetBase) returns (uint8) {
        return super.decimals();
    }

    function supportsInterface(bytes4 id) public view override(ERCXXXX, ERCXXXXFreezable) returns (bool) {
        return super.supportsInterface(id);
    }

    function _hasRestrictions() internal view override(ERCXXXX, ERCXXXXFreezable) returns (bool) {
        return super._hasRestrictions();
    }

    function _segmentAt(uint256 serial)
        internal
        view
        override(ERCXXXX, ERCXXXXFreezable)
        returns (uint256, uint256, bytes32)
    {
        return super._segmentAt(serial);
    }

    function _successorPieces(uint256 start, uint256 end)
        internal
        view
        override(ERCXXXX, ERCXXXXConsolidation)
        returns (uint256[] memory, uint256[] memory)
    {
        return super._successorPieces(start, end);
    }
}

abstract contract PresetClassConsol is PresetBase, ClassAdmin, ERCXXXXTidy, ERCXXXXConsolidation {
    function consolidateSlices(uint256[] calldata starts, uint256[] calldata amounts)
        public
        override(ERCXXXX, ERCXXXXConsolidation)
        returns (uint256)
    {
        return super.consolidateSlices(starts, amounts);
    }

    function consolidatedSpanAt(uint256 serial)
        public
        view
        override(ERCXXXX, ERCXXXXConsolidation)
        returns (bool, uint256, uint256)
    {
        return super.consolidatedSpanAt(serial);
    }

    function decimals() public view override(ERCXXXX, PresetBase) returns (uint8) {
        return super.decimals();
    }

    function supportsInterface(bytes4 id) public view override(ERCXXXX, ERCXXXXClassified) returns (bool) {
        return super.supportsInterface(id);
    }

    function _hasRestrictions() internal view override(ERCXXXX, ERCXXXXClassified) returns (bool) {
        return super._hasRestrictions();
    }

    function _segmentAt(uint256 serial)
        internal
        view
        override(ERCXXXX, ERCXXXXClassified)
        returns (uint256, uint256, bytes32)
    {
        return super._segmentAt(serial);
    }

    function _pileUsable(bytes32 pile, address from, address to)
        internal
        view
        override(ERCXXXX, ERCXXXXClassified)
        returns (bool)
    {
        return super._pileUsable(pile, from, to);
    }

    function _successorPieces(uint256 start, uint256 end)
        internal
        view
        override(ERCXXXX, ERCXXXXConsolidation)
        returns (uint256[] memory, uint256[] memory)
    {
        return super._successorPieces(start, end);
    }

    function _afterConsolidation(uint256 newStart, uint256 amount, bytes32 pile)
        internal
        override(ERCXXXX, ERCXXXXClassified)
    {
        super._afterConsolidation(newStart, amount, pile);
    }
}

abstract contract PresetBothConsol is PresetBase, FreezeAdmin, ClassAdmin, ERCXXXXTidy, ERCXXXXConsolidation {
    function consolidateSlices(uint256[] calldata starts, uint256[] calldata amounts)
        public
        override(ERCXXXX, ERCXXXXConsolidation)
        returns (uint256)
    {
        return super.consolidateSlices(starts, amounts);
    }

    function consolidatedSpanAt(uint256 serial)
        public
        view
        override(ERCXXXX, ERCXXXXConsolidation)
        returns (bool, uint256, uint256)
    {
        return super.consolidatedSpanAt(serial);
    }

    function decimals() public view override(ERCXXXX, PresetBase) returns (uint8) {
        return super.decimals();
    }

    function supportsInterface(bytes4 id)
        public
        view
        override(ERCXXXX, ERCXXXXFreezable, ERCXXXXClassified)
        returns (bool)
    {
        return super.supportsInterface(id);
    }

    function _hasRestrictions()
        internal
        view
        override(ERCXXXX, ERCXXXXFreezable, ERCXXXXClassified)
        returns (bool)
    {
        return super._hasRestrictions();
    }

    function _segmentAt(uint256 serial)
        internal
        view
        override(ERCXXXX, ERCXXXXFreezable, ERCXXXXClassified)
        returns (uint256, uint256, bytes32)
    {
        return super._segmentAt(serial);
    }

    function _pileUsable(bytes32 pile, address from, address to)
        internal
        view
        override(ERCXXXX, ERCXXXXClassified)
        returns (bool)
    {
        return super._pileUsable(pile, from, to);
    }

    function _successorPieces(uint256 start, uint256 end)
        internal
        view
        override(ERCXXXX, ERCXXXXConsolidation)
        returns (uint256[] memory, uint256[] memory)
    {
        return super._successorPieces(start, end);
    }

    function _afterConsolidation(uint256 newStart, uint256 amount, bytes32 pile)
        internal
        override(ERCXXXX, ERCXXXXClassified)
    {
        super._afterConsolidation(newStart, amount, pile);
    }
}

/// @dev A combination with adjustable deployment parameters (with freezing, classification and consolidation), to
///      test the three hooks of consolidation.
///      When gated is true, only accounts registered by the admin can consolidate.
abstract contract PresetBothConsolTuned is PresetBothConsol {
    error ConsolidationNotAllowed(address caller);

    uint256 private immutable _minSlices;
    uint256 private immutable _threshold;
    bool private immutable _gated;
    mapping(address => bool) public consolidator;

    constructor(uint256 minSlices_, uint256 threshold_, bool gated_) {
        _minSlices = minSlices_;
        _threshold = threshold_;
        _gated = gated_;
    }

    function setConsolidator(address account, bool allowed) external onlyAdmin {
        consolidator[account] = allowed;
    }

    function _authorizeConsolidation(address caller) internal view override {
        if (_gated && !consolidator[caller]) revert ConsolidationNotAllowed(caller);
    }

    function _minConsolidationSlices() internal view override returns (uint256) {
        return _minSlices;
    }

    function _consolidationThreshold() internal view override returns (uint256) {
        return _threshold;
    }
}

// ───────────────────────── Two backends ─────────────────────────

contract PresetCoreStack is PresetCore, SerialHoldingsStack {
    constructor(string memory n, string memory s, uint8 d, address a) PresetBase(n, s, d, a) SerialHoldingsStack(0) {}
}

contract PresetCoreSorted is PresetCore, SerialHoldingsSorted {
    constructor(string memory n, string memory s, uint8 d, address a) PresetBase(n, s, d, a) {}
}

contract PresetFreezeStack is PresetFreeze, SerialHoldingsStack {
    constructor(string memory n, string memory s, uint8 d, address a) PresetBase(n, s, d, a) SerialHoldingsStack(0) {}
}

contract PresetFreezeSorted is PresetFreeze, SerialHoldingsSorted {
    constructor(string memory n, string memory s, uint8 d, address a) PresetBase(n, s, d, a) {}
}

contract PresetClassStack is PresetClass, SerialHoldingsStack {
    constructor(string memory n, string memory s, uint8 d, address a) PresetBase(n, s, d, a) SerialHoldingsStack(0) {}
}

contract PresetClassSorted is PresetClass, SerialHoldingsSorted {
    constructor(string memory n, string memory s, uint8 d, address a) PresetBase(n, s, d, a) {}
}

contract PresetBothStack is PresetBoth, SerialHoldingsStack {
    constructor(string memory n, string memory s, uint8 d, address a) PresetBase(n, s, d, a) SerialHoldingsStack(0) {}
}

contract PresetBothSorted is PresetBoth, SerialHoldingsSorted {
    constructor(string memory n, string memory s, uint8 d, address a) PresetBase(n, s, d, a) {}
}

contract PresetAcceptStack is PresetAccept, SerialHoldingsStack {
    constructor(string memory n, string memory s, uint8 d, address a) PresetBase(n, s, d, a) SerialHoldingsStack(0) {}
}

contract PresetAcceptSorted is PresetAccept, SerialHoldingsSorted {
    constructor(string memory n, string memory s, uint8 d, address a) PresetBase(n, s, d, a) {}
}

contract PresetAllStack is PresetAll, SerialHoldingsStack {
    constructor(string memory n, string memory s, uint8 d, address a) PresetBase(n, s, d, a) SerialHoldingsStack(0) {}
}

contract PresetAllSorted is PresetAll, SerialHoldingsSorted {
    constructor(string memory n, string memory s, uint8 d, address a) PresetBase(n, s, d, a) {}
}

contract PresetCoreConsolStack is PresetCoreConsol, SerialHoldingsStack {
    constructor(string memory n, string memory s, uint8 d, address a) PresetBase(n, s, d, a) SerialHoldingsStack(0) {}
}

contract PresetCoreConsolSorted is PresetCoreConsol, SerialHoldingsSorted {
    constructor(string memory n, string memory s, uint8 d, address a) PresetBase(n, s, d, a) {}
}

contract PresetFreezeConsolStack is PresetFreezeConsol, SerialHoldingsStack {
    constructor(string memory n, string memory s, uint8 d, address a) PresetBase(n, s, d, a) SerialHoldingsStack(0) {}
}

contract PresetFreezeConsolSorted is PresetFreezeConsol, SerialHoldingsSorted {
    constructor(string memory n, string memory s, uint8 d, address a) PresetBase(n, s, d, a) {}
}

contract PresetClassConsolStack is PresetClassConsol, SerialHoldingsStack {
    constructor(string memory n, string memory s, uint8 d, address a) PresetBase(n, s, d, a) SerialHoldingsStack(0) {}
}

contract PresetClassConsolSorted is PresetClassConsol, SerialHoldingsSorted {
    constructor(string memory n, string memory s, uint8 d, address a) PresetBase(n, s, d, a) {}
}

contract PresetBothConsolStack is PresetBothConsol, SerialHoldingsStack {
    constructor(string memory n, string memory s, uint8 d, address a) PresetBase(n, s, d, a) SerialHoldingsStack(0) {}
}

contract PresetBothConsolSorted is PresetBothConsol, SerialHoldingsSorted {
    constructor(string memory n, string memory s, uint8 d, address a) PresetBase(n, s, d, a) {}
}

contract PresetBothConsolTunedStack is PresetBothConsolTuned, SerialHoldingsStack {
    constructor(string memory n, string memory s, uint8 d, address a, uint256 minSlices, uint256 threshold, bool gated)
        PresetBase(n, s, d, a)
        PresetBothConsolTuned(minSlices, threshold, gated)
        SerialHoldingsStack(0)
    {}
}

// ───────────────────────── Second rule: "best fit in a bounded window" ─────────────────────────
// The same combinations as above, except that the deployment parameter selectionWindow of the slice stack is given
// by the caller (0 is the default rule).

contract PresetCoreStackWindow is PresetCore, SerialHoldingsStack {
    constructor(string memory n, string memory s, uint8 d, address a, uint256 w)
        PresetBase(n, s, d, a)
        SerialHoldingsStack(w)
    {}
}

contract PresetBothStackWindow is PresetBoth, SerialHoldingsStack {
    constructor(string memory n, string memory s, uint8 d, address a, uint256 w)
        PresetBase(n, s, d, a)
        SerialHoldingsStack(w)
    {}
}

contract PresetBothConsolStackWindow is PresetBothConsol, SerialHoldingsStack {
    constructor(string memory n, string memory s, uint8 d, address a, uint256 w)
        PresetBase(n, s, d, a)
        SerialHoldingsStack(w)
    {}
}

/// @dev The second rule with a tight budget, to test the branches taken under the second rule once the budget for
///      moving between piles is used up.
contract PresetBothStackWindowTight is PresetBothStackWindow {
    constructor(string memory n, string memory s, uint8 d, address a, uint256 w) PresetBothStackWindow(n, s, d, a, w) {}

    function _maxPileMoves() internal pure override returns (uint256) {
        return 1;
    }
}

// ───────────────────────── Tight budget ─────────────────────────
// Each transfer moves at most 1 slice to the pile where it belongs and skips the rest in place. Used to test the
// branches taken once the budget is used up.

contract PresetBothStackTight is PresetBothStack {
    constructor(string memory n, string memory s, uint8 d, address a) PresetBothStack(n, s, d, a) {}

    function _maxPileMoves() internal pure override returns (uint256) {
        return 1;
    }
}

contract PresetBothSortedTight is PresetBothSorted {
    constructor(string memory n, string memory s, uint8 d, address a) PresetBothSorted(n, s, d, a) {}

    function _maxPileMoves() internal pure override returns (uint256) {
        return 1;
    }
}

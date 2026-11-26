// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {ERCXXXX} from "../ERCXXXX.sol";
import {ERCXXXXFreezable} from "../extensions/ERCXXXXFreezable.sol";
import {ERCXXXXClassified} from "../extensions/ERCXXXXClassified.sol";
import {ERCXXXXAllowlist} from "../extensions/ERCXXXXAllowlist.sol";
import {ERCXXXXAcceptance} from "../extensions/ERCXXXXAcceptance.sol";
import {ERCXXXXConsolidation} from "../extensions/ERCXXXXConsolidation.sol";
import {ERCXXXXTidy} from "../extensions/ERCXXXXTidy.sol";
import {SerialHoldingsStack} from "../holdings/SerialHoldingsStack.sol";

/// @title ERCXXXXExampleToken
/// @notice One concrete token that combines the core with the freezing extension, the classification
///         extension with the example allowlist class, the acceptance check, open consolidation and the
///         tidying entry point `tidySlices`, on the slice stack with the default selection rule.
///         It has no burn module. A single admin mints, describes reasons, defines classes, sets permitted
///         recipients and classes, and is the only caller that can freeze, unfreeze and execute forced
///         operations.
///
///         This is an example for reading. It is not audited, and its single admin is not a recommendation
///         of a permission model.
///
///         As a single contract its runtime code is 39,333 bytes (solc 0.8.36, optimizer on, 200 runs),
///         above the 24,576-byte limit of EIP-170, so it cannot be deployed on Ethereum mainnet as it stands.
///         It is included so that a reader has one concrete token showing how the modules are combined and
///         which overrides the combination needs. The combinations that do fit are listed in the package
///         README.
contract ERCXXXXExampleToken is
    ERCXXXXFreezable,
    ERCXXXXAllowlist,
    ERCXXXXAcceptance,
    ERCXXXXConsolidation,
    ERCXXXXTidy,
    SerialHoldingsStack
{
    /// @notice The caller is not the admin.
    error NotAdmin(address caller);

    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);

    address public admin;

    modifier onlyAdmin() {
        _checkAdmin(msg.sender);
        _;
    }

    /// @dev Keeps the core's default `decimals()` (18). Selection window 0 is the default selection rule.
    constructor(string memory name_, string memory symbol_, address admin_)
        ERCXXXX(name_, symbol_)
        SerialHoldingsStack(0)
    {
        admin = admin_;
        emit AdminTransferred(address(0), admin_);
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        emit AdminTransferred(admin, newAdmin);
        admin = newAdmin;
    }

    // Issuance. Both are restricted issuance, so the recipient is not queried by the acceptance check.

    function mint(address to, uint256 value) external onlyAdmin returns (uint256 start) {
        return _mint(to, value);
    }

    function mintWithClass(address to, uint256 value, bytes32 classId) external onlyAdmin returns (uint256 start) {
        return _mintWithClass(to, value, classId);
    }

    // Reasons and classes.

    /// @notice Registers or changes the description of a freeze reason. A reason needs a name before use.
    function setReasonInfo(bytes32 reason, string calldata name_, string calldata uri) external onlyAdmin {
        _setReasonInfo(reason, name_, uri);
    }

    /// @notice Defines or redefines an allowlist class: its units can only go to its permitted recipients.
    function defineAllowlistClass(bytes32 classId, string calldata name_, string calldata uri) external onlyAdmin {
        _defineAllowlistClass(classId, name_, uri);
    }

    function setPermittedRecipient(bytes32 classId, address account, bool permitted) external onlyAdmin {
        _setDesignatedRecipient(classId, account, permitted);
    }

    /// @notice Sets the class of the `amount` serials starting at `start`; zero is the default class.
    function setClass(uint256 start, uint256 amount, bytes32 classId) external onlyAdmin {
        _setClass(start, amount, classId);
    }

    // Authorization hooks of the freezing extension.

    function _authorizeFreeze(address caller, bytes32, bool) internal view override {
        _checkAdmin(caller);
    }

    function _authorizeForced(address caller, address, address) internal view override {
        _checkAdmin(caller);
    }

    function _checkAdmin(address caller) private view {
        if (caller != admin) revert NotAdmin(caller);
    }

    // Consolidation keeps the module's defaults: any holder, at least 1 group, no slice threshold.
    // A real token should override _minConsolidationSlices and _consolidationThreshold
    // (see "Costs of consolidation" in the draft).

    // The overrides below only resolve the linearization.

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERCXXXX, ERCXXXXFreezable, ERCXXXXClassified, ERCXXXXAcceptance)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function consolidateSlices(uint256[] calldata starts, uint256[] calldata amounts)
        public
        override(ERCXXXX, ERCXXXXConsolidation)
        returns (uint256)
    {
        return super.consolidateSlices(starts, amounts);
    }

    function consolidatedRunAt(uint256 serial)
        public
        view
        override(ERCXXXX, ERCXXXXConsolidation)
        returns (bool, uint256, uint256)
    {
        return super.consolidatedRunAt(serial);
    }

    function _hasRestrictions() internal view override(ERCXXXX, ERCXXXXFreezable, ERCXXXXClassified) returns (bool) {
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

    function _checkAcceptance(address from, address to, uint256 value, uint256 slices)
        internal
        view
        override(ERCXXXX, ERCXXXXAcceptance)
    {
        super._checkAcceptance(from, to, value, slices);
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

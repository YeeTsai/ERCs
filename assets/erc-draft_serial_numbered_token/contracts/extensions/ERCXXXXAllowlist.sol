// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERCXXXXClassified} from "./ERCXXXXClassified.sol";

/// @title ERCXXXXAllowlist: an example class that restricts destinations by payee address
/// @notice A class defined with _defineAllowlistClass carries a list of permitted recipients: units of such a class
///         can only be transferred to addresses on the list, and can also be burned. Whether a transfer is allowed
///         depends only on to, not on from. Who can maintain the list is decided by the token.
abstract contract ERCXXXXAllowlist is ERCXXXXClassified {
    /// @notice The list of permitted recipients has changed. The draft does not require this event; this
    ///         implementation emits it so that indexers can track the list.
    event DesignatedRecipientSet(bytes32 indexed classId, address indexed account, bool allowed);

    mapping(bytes32 classId => bool) private _isAllowlist;
    mapping(bytes32 classId => mapping(address account => bool)) private _recipients;

    /// @notice Whether account is a permitted recipient of the class classId.
    function isDesignatedRecipient(bytes32 classId, address account) public view virtual returns (bool) {
        return _recipients[classId][account];
    }

    /// @dev Adds account to, or removes it from, the list of permitted recipients of the class classId. classId has
    ///      to be a defined allowlist class.
    function _setDesignatedRecipient(bytes32 classId, address account, bool allowed) internal virtual {
        if (!_isAllowlist[classId]) revert ERCXXXXInvalidClass(classId);
        _recipients[classId][account] = allowed;
        emit DesignatedRecipientSet(classId, account, allowed);
    }

    /// @dev Defines or modifies an allowlist class, with the same requirements as _defineClass. Whether a class is
    ///      an allowlist class is decided by its most recent definition: an allowlist class redefined with
    ///      _defineClass is no longer an allowlist class, and vice versa. Redefinition does not clear the list.
    function _defineAllowlistClass(bytes32 classId, string memory name_, string memory uri) internal virtual {
        _defineClass(classId, name_, uri);
        _isAllowlist[classId] = true;
    }

    /// @dev A class defined or redefined with _defineClass is not an allowlist class.
    function _defineClass(bytes32 classId, string memory name_, string memory uri) internal virtual override {
        super._defineClass(classId, name_, uri);
        _isAllowlist[classId] = false;
    }

    function _classAllows(bytes32 classId, address from, address to) internal view virtual override returns (bool) {
        if (_isAllowlist[classId]) return to == address(0) || _recipients[classId][to];
        return super._classAllows(classId, from, to);
    }
}

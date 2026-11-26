// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

/// @title Serial-Numbered Fungible Tokens, optional classification extension
/// @dev A compliant contract MUST also implement IERCXXXX.
interface IERCXXXXClassified /* is IERCXXXX */ {
    /// @notice Emitted when the class of the `amount` consecutive serials starting at `start` is
    ///         set to `classId`.
    event SliceClassified(uint256 start, uint256 amount, bytes32 classId);

    /// @notice The class of `serial`, and a span of serials of that class. Zero is the default
    ///         class.
    /// @dev The `length` consecutive serials starting at `serial` all have the class `classId`.
    ///      `length` is zero if `serial` has not been issued.
    function classSpanAt(uint256 serial) external view returns (bytes32 classId, uint256 length);

    /// @notice Whether the class `classId` allows a serial of that class held by `from` to be
    ///         moved to `to` at present.
    /// @dev `to` is the zero address for a burn. Freezing is not taken into account.
    function classAllows(bytes32 classId, address from, address to) external view returns (bool);

    /// @notice The balance of `account` broken down by class.
    /// @dev `amounts[i]` is the number of serials held by `account` whose class is `classIds[i]`.
    ///      Frozen serials are included.
    function classesOf(address account)
        external
        view
        returns (bytes32[] memory classIds, uint256[] memory amounts);

    /// @notice A description of the class `classId`.
    /// @dev `name` is a short human-readable name, and `uri` points to a JSON document or is an
    ///      empty string.
    function classInfo(bytes32 classId) external view returns (string memory name, string memory uri);
}

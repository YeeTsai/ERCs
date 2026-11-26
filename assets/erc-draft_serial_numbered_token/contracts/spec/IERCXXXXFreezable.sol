// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

/// @title Serial-Numbered Fungible Tokens, optional freezing extension
/// @dev A compliant contract MUST also implement IERCXXXX.
interface IERCXXXXFreezable /* is IERCXXXX */ {
    /// @notice Emitted to report that the `amount` consecutive serials starting at `start` are
    ///         frozen for `reason`.
    event SliceFrozen(bytes32 indexed reason, uint256 start, uint256 amount);

    /// @notice Emitted to report that the `amount` consecutive serials starting at `start` are
    ///         not frozen for `reason`.
    event SliceUnfrozen(bytes32 indexed reason, uint256 start, uint256 amount);

    /// @notice Emitted when the `amount` consecutive serials starting at `start` are moved from
    ///         `from` to `to`, or destroyed, without the consent of `from`.
    /// @dev `to` is the zero address when the serials are destroyed.
    event SliceForciblyTransferred(address indexed from, address indexed to, uint256 start, uint256 amount);

    /// @notice Freezes the `amount` consecutive serials starting at `start` for `reason`.
    /// @dev Serials that are already frozen for `reason` remain so. The successors of consolidated
    ///      serials among them are frozen as well.
    function freezeSlice(uint256 start, uint256 amount, bytes32 reason) external;

    /// @notice Releases the `amount` consecutive serials starting at `start` from `reason`.
    /// @dev A serial stays frozen for as long as it is frozen for any other reason. The successors
    ///      of consolidated serials among them are released as well.
    function unfreezeSlice(uint256 start, uint256 amount, bytes32 reason) external;

    /// @notice Moves the `amount` consecutive serials starting at `start` from `from` to `to`
    ///         without the consent of `from`.
    /// @dev Does not change whether the serials are frozen.
    function forcedTransferSlice(address from, address to, uint256 start, uint256 amount) external;

    /// @notice Destroys the `amount` consecutive serials starting at `start`, which are held by
    ///         `from`, without the consent of `from`.
    function destroySlice(address from, uint256 start, uint256 amount) external;

    /// @notice Whether `serial` is frozen for at least one reason, and a span of serials sharing
    ///         that status.
    /// @dev The `length` consecutive serials starting at `serial` are all frozen or all not
    ///      frozen. `length` is zero if `serial` has not been issued.
    function frozenSpanAt(uint256 serial) external view returns (bool frozen, uint256 length);

    /// @notice The number of serials held by `account` that are frozen for at least one reason.
    function frozenBalanceOf(address account) external view returns (uint256);

    /// @notice The reasons for which serials held by `account` are frozen.
    /// @dev `amounts[i]` is the number of serials held by `account` that are frozen for
    ///      `reasons[i]`. A serial frozen for several reasons is counted under each of them, so
    ///      the amounts can add up to more than `frozenBalanceOf(account)`.
    function freezeReasonsOf(address account)
        external
        view
        returns (bytes32[] memory reasons, uint256[] memory amounts);

    /// @notice A description of the freeze reason `reason`.
    /// @dev `name` is a short human-readable name, and `uri` points to a JSON document or is an
    ///      empty string.
    function freezeReasonInfo(bytes32 reason) external view returns (string memory name, string memory uri);
}

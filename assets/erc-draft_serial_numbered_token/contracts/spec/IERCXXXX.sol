// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

/// @title Serial-Numbered Fungible Tokens, core interface
/// @dev A compliant contract MUST also implement ERC-20 and ERC-165.
interface IERCXXXX /* is IERC20, IERC165 */ {
    /// @notice Emitted when the `amount` consecutive serials starting at `start` change holder.
    /// @dev `from` is the zero address when the serials are issued, and `to` is the zero address
    ///      when they are destroyed.
    event SliceTransferred(address indexed from, address indexed to, uint256 start, uint256 amount);

    /// @notice Emitted when the units with the `amount` consecutive serials starting at `start`,
    ///         held by `account`, are given the `amount` consecutive serials starting at
    ///         `newStart`.
    /// @dev The unit with the serial `start + i` receives the serial `newStart + i`.
    event SliceConsolidated(address indexed account, uint256 start, uint256 newStart, uint256 amount);

    /// @notice `from` holds at least `amount` units, but only `transferable` of them may currently
    ///         be moved to `to`.
    error ERCXXXXInsufficientTransferableBalance(address from, address to, uint256 amount, uint256 transferable);

    /// @notice Some of the `amount` consecutive serials starting at `start` are not held by `from`.
    error ERCXXXXNotHeld(address from, uint256 start, uint256 amount);

    /// @notice Some of the `amount` consecutive serials starting at `start` may not currently be
    ///         moved from `from` to `to` because of state attached to them, such as a freeze.
    error ERCXXXXNotTransferable(address from, address to, uint256 start, uint256 amount);

    /// @notice `to` refuses a transfer of `value` units from `from`.
    error ERCXXXXTransferRefused(address from, address to, uint256 value);

    /// @notice Some of the `amount` consecutive serials starting at `start`, held by `account`,
    ///         may not currently be consolidated because of state attached to them, such as a
    ///         freeze.
    error ERCXXXXNotConsolidatable(address account, uint256 start, uint256 amount);

    /// @notice The number of serials issued so far, including serials that were later destroyed
    ///         or consolidated.
    /// @dev The next unit to be issued receives the serial `serialsIssued()`.
    function serialsIssued() external view returns (uint256);

    /// @notice The number of slices that `sliceAt` exposes for `account`.
    function sliceCount(address account) external view returns (uint256);

    /// @notice One of the slices of serials held by `account`.
    /// @dev The slice covers the serials `start`, `start + 1`, ..., `start + amount - 1`.
    ///      MUST revert if `index >= sliceCount(account)`.
    function sliceAt(address account, uint256 index) external view returns (uint256 start, uint256 amount);

    /// @notice Moves the serials in the slices `(starts[i], amounts[i])` from the caller to `to`.
    /// @dev MUST revert if the arrays are empty or differ in length, if any amount is zero, if the
    ///      slices are not in ascending order of `start` or overlap, if `to` is the zero address,
    ///      or if any of these serials is not held by the caller or may not currently be moved
    ///      to `to`.
    function transferSlices(address to, uint256[] calldata starts, uint256[] calldata amounts)
        external
        returns (bool);

    /// @notice The number of serials held by `from` that may currently be moved to `to`.
    /// @dev `to` is the zero address for a burn.
    function transferableBalanceOf(address from, address to) external view returns (uint256);

    /// @notice Gives the units with the serials in the slices `(starts[i], amounts[i])`, held by
    ///         the caller, new consecutive serials starting at `newStart`.
    /// @dev The units receive the new serials in ascending order of their old serials. MUST revert
    ///      if the arrays are empty or differ in length, if any amount is zero, if the slices are
    ///      not in ascending order of `start` or overlap, or if any of these serials is not held
    ///      by the caller.
    function consolidateSlices(uint256[] calldata starts, uint256[] calldata amounts)
        external
        returns (uint256 newStart);

    /// @notice Whether `serial` has been consolidated, the serial its unit received, and a span of
    ///         serials that were consolidated together with it.
    /// @dev If `consolidated` is true, the unit that had the serial `serial + i` received the
    ///      serial `successor + i`, for every `i < length`. If it is false, none of the `length`
    ///      consecutive serials starting at `serial` has been consolidated and `successor` is
    ///      zero. `length` is zero if `serial` has not been issued.
    function consolidatedSpanAt(uint256 serial)
        external
        view
        returns (bool consolidated, uint256 successor, uint256 length);
}

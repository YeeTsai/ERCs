// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {SerialHoldings} from "./SerialHoldings.sol";

/// @title SerialHoldingsArray
/// @notice Stores the slices of each pile in an "index -> slice" mapping, one storage slot per slice (128 bits each
///         for the start and the length). The two backends, the stack and the sorted array, share this layer and
///         differ only in how they add and remove slices.
abstract contract SerialHoldingsArray is SerialHoldings {
    mapping(address account => mapping(bytes32 pile => mapping(uint256 index => uint256 packed))) private _slots;

    function _rangeAt(address account, bytes32 pile, uint256 i)
        internal
        view
        virtual
        override
        returns (uint256 start, uint256 len)
    {
        uint256 v = _slots[account][pile][i];
        return (v >> 128, v & type(uint128).max);
    }

    function _setTopLen(address account, bytes32 pile, uint256 n, uint256 newLen)
        internal
        virtual
        override
        returns (uint256)
    {
        if (newLen == 0) {
            delete _slots[account][pile][n - 1];
            return n - 1;
        }
        (uint256 start,) = _rangeAt(account, pile, n - 1);
        _writeRange(account, pile, n - 1, start, newLen);
        return n;
    }

    function _writeRange(address account, bytes32 pile, uint256 i, uint256 start, uint256 len) internal {
        _slots[account][pile][i] = (start << 128) | len;
    }

    function _copyRange(address account, bytes32 pile, uint256 from, uint256 to) internal {
        _slots[account][pile][to] = _slots[account][pile][from];
    }

    function _clearRange(address account, bytes32 pile, uint256 i) internal {
        delete _slots[account][pile][i];
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev The ERC-20 interface. It is the same as OpenZeppelin's interface of the same name and is written out here,
///      so that the reference implementation does not depend on external libraries.
interface IERC20 {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

/// @dev The optional metadata of ERC-20. This proposal requires them to be implemented (clause 2 of
///      "Requirements on ERC-20 behavior").
interface IERC20Metadata is IERC20 {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

/// @dev The errors that ERC-6093 defines for ERC-20.
interface IERC20Errors {
    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);
    error ERC20InvalidSender(address sender);
    error ERC20InvalidReceiver(address receiver);
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);
    error ERC20InvalidApprover(address approver);
    error ERC20InvalidSpender(address spender);
}

/// @dev The ERC-165 interface.
interface IERC165 {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

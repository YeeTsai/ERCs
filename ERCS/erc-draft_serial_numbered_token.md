---
title: Serial-Numbered Fungible Tokens
description: Fungible tokens whose units each have a serial number; ERC-20 compatible, with optional freezing and classification by slice.
author: Yi Cai (@YeeTsai) <yee.tsai@gmail.com>, Yan Meng (@ymonk) <myan@unizon.au>
discussions-to: https://ethereum-magicians.org/t/erc-xxxx-serial-numbered-fungible-tokens/30519
status: Draft
type: Standards Track
category: ERC
created: 2026-11-16
requires: 20, 165, 6093
---

## Abstract

This proposal defines a fungible token, compatible with [ERC-20](./eip-20.md), in which every smallest unit carries a unique serial number, in the way a banknote does. An account's balance is the number of serials it holds, and a transfer changes the holder of some serials without ever renumbering them, so however many times an amount is split or forwarded, its units stay inside the slice of serials they came from. Holdings and movements are exposed as slices of consecutive serials, and a holder can also name which serials are sent; the contract remains a plain ERC-20 token for wallets, exchanges and other contracts. A holder that has received many scattered units can consolidate them onto one new slice of consecutive serials, and the correspondence between old and new serials is recorded in the contract. Two optional extensions attach state to serials by slice: the freezing extension, in which every freeze carries a reason and follows the units themselves however they are later divided or consolidated, and which lets an authorized party destroy or forcibly transfer units; and the classification extension, which gives every serial a class that can restrict to whom its units can be transferred. Reasons and classes can both describe themselves through the contract, so a wallet can break down and display a balance without prior knowledge of a particular token's rules. A token can also choose to support the acceptance check, which lets a receiving contract refuse incoming transfers.

## Motivation

An ERC-20 balance is a single number. Units have no identity, so the question "which tokens are these?" has no on-chain answer. This becomes a practical problem when an issuer has to act on specific funds, for example after a theft.

Existing mechanisms act on accounts. An issuer can block an address outright, or freeze a given amount inside an address as [ERC-3643](./eip-3643.md) and [ERC-7943](./eip-7943.md) allow. Neither follows the funds. Once stolen tokens are split across fresh addresses, forwarded, or mixed with other balances, nothing on-chain says which units are the stolen ones. Tracing then depends on off-chain conventions (first-in-first-out, pro-rata, or treating everything touched as tainted) that different parties apply differently, and enforcement becomes a race in which each new address has to be found and frozen while the funds keep moving.

Physical cash addresses identification with serial numbers. Ledgers built on unspent outputs, such as Bitcoin or the cell model of Nervos CKB, give every output an identity, but that identity changes each time the output is spent, and for every spend, whoever spends the output has to choose the inputs off-chain. Neither property fits `transfer(address,uint256)`, which names an amount and nothing else. Token designs that attach identity to positions, such as [ERC-3525](./eip-3525.md), build on [ERC-721](./eip-721.md), whose `balanceOf`, `approve` and `transferFrom` share selectors with ERC-20 while meaning something different, so one contract cannot serve both.

[ERC-8047](./eip-8047.md) gives funds an on-chain lineage for the same purpose, but it is an [ERC-1155](./eip-1155.md) token in which every transfer creates a new token id, so it cannot be used where ERC-20 is expected.

State that needs to rest on specific units comes in more than one form. The same units might first be pledged and later be put under a judicial freeze, and it has to be possible to lift each of the two on its own. An issuer might also want some units to be freely transferable and others to be payable only to designated addresses. What these states have in common is that they are attached to units and have to remain in effect after the units are split and forwarded. Once units have a stable identity, all of these states have something to attach to.

A stable identity is useful even when no state is attached to it. Which serials every movement transferred is recorded on-chain, and so is the correspondence between old and new serials when units are consolidated, so where a given set of units went is a fact that can be read directly and no longer has to be inferred with the conventions above. An exchange can check, before it credits an incoming transfer, whether the transfer contains serials taken in a theft, and investigators and courts rely on the same record. A token that provides no freezing offers all of this as well. What it establishes is where the units are, not who is responsible (see "Selection order can be influenced", "Holders can choose which units to send" and "Reduced fungibility and privacy").

What is missing is a token whose units keep a stable identity across splits and transfers, with that identity recorded on-chain, while the token still behaves as ERC-20 everywhere ERC-20 is expected.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in RFC 2119 and RFC 8174.

### Definitions

- **Unit**: the smallest indivisible amount of the token, that is, `1` in the `uint256` values used by ERC-20.
- **Serial**: a non-negative integer that identifies exactly one unit.
- **Slice** `(start, amount)`: the `amount` consecutive serials `start`, `start + 1`, ..., `start + amount - 1`, where `amount > 0`.
- **Holder**: the address that currently owns a serial.
- **Issued**: a serial that has been assigned to a unit by a mint.
- **Destroyed**: an issued serial whose unit no longer exists. Both a burn by the holder and destruction by an authorized party make a serial destroyed. A destroyed serial has no holder.
- **Consolidated**: an issued serial whose unit has been given a new serial by a consolidation. A consolidated serial has no holder, but its unit still exists.
- **Successor**: the new serial that the unit of a consolidated serial received in that consolidation.
- **Reason**: a `bytes32` value that identifies the cause of a freeze.
- **Frozen**: a serial is frozen when it is frozen for at least one reason.
- **Span**: the sequence of consecutive serials that `frozenSpanAt`, `classSpanAt` and `consolidatedSpanAt` return: it starts at the serial queried, and every serial in it has the same state as that serial. The state is whether a serial is frozen, its class, or whether it is consolidated. A span is thus a slice whose serials share one state, given by the serial queried and the length returned. It starts at the serial queried, which need not be where that state begins, and it need not reach where that state ends, because these queries are not required to return the longest one. In a span returned by `consolidatedSpanAt`, the successors of the serials are consecutive as well. A span is independent of holders: it can contain the serials of several holders, and it can include destroyed or consolidated serials. It is up to a caller that is interested in only one holding to truncate the span to the slices of that holding.

### Core interface

Every contract that conforms to this proposal MUST implement ERC-20, [ERC-165](./eip-165.md) and the `IERCXXXX` interface.

```solidity
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
```

`supportsInterface` MUST return `true` for `0x668ccf00`, the ERC-165 identifier of `IERCXXXX`.

### Serial model

1. Serials MUST be issued consecutively starting from `0`. An operation that assigns new serials to `v` units, that is, an operation that creates these units or a consolidation as defined in "Consolidation", MUST assign them the serials `serialsIssued()` through `serialsIssued() + v - 1`, as read before the operation, and MUST then increase `serialsIssued()` by `v`. `serialsIssued()` MUST NOT change in any other way.
2. Every issued serial MUST, at all times, be in exactly one of the following states: it has exactly one holder, which is not the zero address; it is destroyed; it is consolidated.
3. A destroyed or consolidated serial MUST NOT have a holder again. Serials are never reused.
4. `balanceOf(account)` MUST equal the number of serials held by `account`.
5. `totalSupply()` MUST equal the number of serials that have a holder, that is, the issued serials that are neither destroyed nor consolidated.

Apart from a consolidation, no operation changes the serial of a unit: operations change the holder of a serial. In a contract that does not open consolidation (see clause 7 of "Consolidation"), a unit therefore keeps its serial for its entire life.

### Requirements on ERC-20 behavior

ERC-20 leaves a choice open in several places, or only makes a recommendation. A contract that conforms to this proposal MUST behave as this section specifies. Every clause of this section is behavior that ERC-20 permits, so a contract that conforms to this proposal also conforms to ERC-20.

1. `transfer`, `transferFrom` and `approve` MUST return `true` on success and MUST revert on failure. They MUST NOT signal failure by returning `false`.
2. The contract MUST implement `name`, `symbol` and `decimals`. The value returned by `decimals` MUST NOT change.
3. `transfer` and `transferFrom` MUST revert when `to` is the zero address. Units are destroyed only through an explicit burn or destruction operation.
4. When a failure is a case described by one of the errors that [ERC-6093](./eip-6093.md) defines for ERC-20, the contract SHOULD revert with that error: for example `ERC20InsufficientBalance` when the balance is insufficient, `ERC20InsufficientAllowance` when the allowance is insufficient, and `ERC20InvalidReceiver` when `to` is the zero address. When a failure matches several of the errors that ERC-6093 or this proposal recommends, which one is used is not specified.
5. The contract MAY let holders burn their own units. A contract that provides this SHOULD use the signatures `burn(uint256 value)` and `burnFrom(address account, uint256 value)`: the former burns `value` units of the caller; the latter burns `value` units of `account` and consumes the caller's allowance from `account` in the same way as `transferFrom`. Which serials these two functions burn is determined by the implementation's selection rule.
6. The contract MAY let holders name the serials to burn. A contract that provides this SHOULD use the signature `burnSlices(uint256[] calldata starts, uint256[] calldata amounts)`, which returns no value. It burns all serials in the slices `(starts[i], amounts[i])`, all of which have to be held by the caller. Its requirements on the arguments are the same as those of `transferSlices`: the call MUST revert in the cases listed in clauses 2 to 4 of "Transfers by serial", and when serials are not held by the caller it likewise SHOULD revert with `ERCXXXXNotHeld(msg.sender, starts[i], amounts[i])`. A successful call MUST emit exactly one `Transfer(msg.sender, address(0), value)`, where `value` is the sum of the entries of `amounts`, and emit `SliceTransferred` events as specified in "Events". It MUST NOT change any allowance. This proposal defines no function by which a spender burns by serial.
7. `burn`, `burnFrom` and `burnSlices` are not part of `IERCXXXX` and do not count toward its ERC-165 identifier.

ERC-20 only recommends emitting a `Transfer` event when units are issued, and does not specify whether one is emitted when they are destroyed; this proposal makes both a requirement in "Events".

### Transfers

`transfer` and `transferFrom` MUST behave as specified by ERC-20, with the following additions.

1. A successful transfer of `value` units from `from` to `to`, where `from != to`, MUST change the holder of exactly `value` serials held by `from` to `to`, and MUST NOT change the holder of any other serial.
2. Which of the sender's serials are moved is chosen by the implementation. Implementations SHOULD document their selection rule.
3. A transfer where `from == to` or `value == 0` MUST NOT change the holder of any serial.

### Transfers by serial

`transferSlices(to, starts, amounts)` lets a holder name the serials to transfer. It names all serials in the slices `(starts[i], amounts[i])`. In this section, the caller is `msg.sender`, and `value` is the sum of the entries of `amounts`.

1. A successful call MUST change the holder of every named serial from the caller to `to`, MUST NOT change the holder of any other serial, and MUST return `true`.
2. The call MUST revert if the two arrays differ in length, if their length is zero, or if any `amounts[i]` is zero.
3. The slices have to be given in ascending order of start and without overlap: the call MUST revert if, for some `i > 0`, `starts[i]` is less than `starts[i - 1] + amounts[i - 1]`. Adjacent slices MAY be given separately.
4. The call MUST revert if any of the named serials is not held by the caller, including a serial that has not been issued, has been destroyed or is consolidated. The contract SHOULD revert with `ERCXXXXNotHeld(msg.sender, starts[i], amounts[i])`, where `(starts[i], amounts[i])` is a slice that contains such a serial.
5. A successful call MUST emit exactly one `Transfer(msg.sender, to, value)`, and emit `SliceTransferred` events according to the rules of "Events".
6. If `to` is the caller, clauses 2 to 4 still apply; a successful call changes the holder of no serial.
7. The call MUST revert if `to` is the zero address.
8. `transferSlices` MUST NOT change any allowance.

### Events

Every operation that changes the holder of serials MUST emit the ERC-20 `Transfer(from, to, value)` event, where `value` is the number of serials whose holder changes from `from` to `to` as reported by that event. `from` is the zero address when serials are issued, and `to` is the zero address when serials are destroyed. This includes destruction that is not initiated by the holder. The holder of a serial MUST NOT change in any way that is not reported by a `Transfer` event. A consolidation is the only exception: it changes no account's balance, emits neither `Transfer` nor `SliceTransferred`, and is reported by `SliceConsolidated` events (see "Consolidation").

For every ERC-20 `Transfer(from, to, value)` event with `from != to` and `value > 0`, including mints (`from` is the zero address) and burns (`to` is the zero address), the contract MUST emit one or more `SliceTransferred` events such that:

1. each has the same `from` and `to` as the `Transfer` event;
2. each has `amount > 0`;
3. their slices are pairwise disjoint and together are exactly the serials whose holder changes from `from` to `to` as reported by that `Transfer` event;
4. their `amount` values sum to `value`;
5. they are emitted before that `Transfer` event and after any earlier `Transfer` event emitted by the same contract in the same transaction.

The contract MUST NOT emit `SliceTransferred` in any other circumstance. In particular, a `Transfer` event with `from == to` or `value == 0` has no `SliceTransferred` events.

Under clause 5, the `SliceTransferred` events belonging to a `Transfer` event are exactly those emitted by the contract between the previous `Transfer` event of the same transaction (or the start of the transaction) and that `Transfer` event.

### Enumeration

For any `account`, the slices returned by `sliceAt(account, i)` for `0 <= i < sliceCount(account)` MUST be pairwise disjoint, MUST each have `amount > 0`, and together MUST be exactly the set of serials held by `account`. `sliceAt(account, index)` MUST revert when `index >= sliceCount(account)`.

The order of the slices is not specified and MAY change with any state-changing operation. Two slices that are adjacent MAY be reported separately. Callers MUST NOT assume that an index still refers to the same slice after any state-changing operation.

### Transferable balance

The extensions of this proposal, and restrictions attached to serials that an implementation defines itself, can leave some units temporarily unable to be transferred out, or transferable only to some addresses. The core interface reports the result through one query, so that wallets and contracts obtain the amount that can be transferred out in the same way whichever extensions a token implements.

For a pair of addresses `(from, to)`, a serial is *transferable* if and only if it is held by `from` and the contract does not prohibit its transfer from `from` to `to` because of state attached to that serial. The freezes and flow rules defined by the extensions of this proposal are such state, and so are restrictions attached to serials that an implementation defines itself. For a burn, `to` is the zero address. In a contract that places no restriction on serials, every serial held by `from` is transferable.

1. `transferableBalanceOf(from, to)` MUST equal the number of serials that are transferable for `(from, to)`. It never exceeds `balanceOf(from)`.

Clauses 2 to 5 apply to every operation that transfers or burns units and is initiated by the holder or by a spender, whatever function provides it. This includes `transfer`, `transferFrom`, `transferSlices`, `burn`, `burnFrom` and `burnSlices`, and any other such function an implementation provides, for example a function that notifies the recipient on a transfer. In these operations, `from` is the holder of the units that are transferred or burned.

2. These operations MUST NOT change the holder of a serial that is not transferable for `(from, to)`.
3. A transfer or burn of `value` units from `from` to `to` with `value` greater than `transferableBalanceOf(from, to)` MUST revert. If `value <= balanceOf(from)`, the contract SHOULD revert with `ERCXXXXInsufficientTransferableBalance(from, to, value, transferable)`, where `transferable` is `transferableBalanceOf(from, to)`. If `value > balanceOf(from)`, the contract SHOULD revert with the `ERC20InsufficientBalance` error of ERC-6093.
4. If `value` is not greater than `transferableBalanceOf(from, to)`, these operations MUST NOT revert because `from` holds serials that are not transferable. The implementation's selection rule therefore has to be able to skip serials that are not transferable. Which of the transferable serials are selected is still chosen by the implementation. This clause does not require an operation to still succeed when gas runs out; an implementation SHOULD avoid letting the cost of skipping serials that are not transferable grow with the number of slices they form, for example by storing slices separately by frozen state and class (see "Fragmentation and gas").
5. Clauses 3 and 4 do not apply to operations in which the initiator names the serials, such as `transferSlices` and `burnSlices`; in these two functions, `from` is the caller. When any of the serials such an operation names is not transferable for `(from, to)`, the call MUST revert; for a burn, `to` is the zero address. If one of the named serials is prohibited from being transferred from `from` to `to` because of state attached to it, whether or not it is held by `from`, the contract SHOULD revert with `ERCXXXXNotTransferable(from, to, starts[i], amounts[i])`, where `(starts[i], amounts[i])` is a slice that contains such a serial. When the named serials include both one that is not held by `from` and one that is prohibited in this way, both errors match, and which one is used is not specified (see clause 4 of "Requirements on ERC-20 behavior").
6. `transferableBalanceOf` reflects only state attached to serials. An implementation MAY reject any operation, including transfers, burns, `approve` and issuance, on other grounds, for example restrictions on accounts or a global pause; `transferableBalanceOf` does not reflect these grounds. The section "Acceptance check", which a contract can choose whether to support, defines one of them: refusal by the recipient.
7. Allowances are independent of whether serials are transferable. `approve` MUST NOT revert because serials held by the caller are not transferable. The value returned by `allowance` MUST NOT change because serials become transferable or not transferable, so freezing, unfreezing and setting a class change no allowance. Whether serials are transferable is checked only when units are transferred or burned: `transferFrom` and `burnFrom` behave according to clauses 2 to 4, and the amount they can move is limited by both the allowance and `transferableBalanceOf(from, to)`.

### Consolidation

When an account receives units whose serials are not adjacent, the number of slices it holds grows, and so does the cost of its later transfers (see "Fragmentation and gas"). This section specifies how units held by one account are given one new slice of consecutive serials, and how the correspondence between old and new serials is recorded and queried. It does not specify who can consolidate, nor how many slices a consolidation has to include at least; these are left to the implementation.

In this section, a *consolidation* is an operation that assigns new serials to units held by one account. `consolidateSlices(starts, amounts)` consolidates all the serials in the slices `(starts[i], amounts[i])`, which are held by the caller. In this section `v` is the sum of the elements of `amounts`, `n` is `serialsIssued()` before the call, and `p_i` is the sum of `amounts[0]` through `amounts[i - 1]`, with `p_0` being zero.

1. A successful call to `consolidateSlices` MUST assign the serials `n` through `n + v - 1` to the named units, and MUST return `n`. New serials are assigned in ascending order of the old serials: the unit whose serial was `starts[i] + k` receives the serial `n + p_i + k`, where `0 <= k < amounts[i]`.
2. After the call, the new serials MUST all be held by the caller, and the named old serials MUST all be consolidated, their successors being the new serials assigned under clause 1. Under clause 1 of "Serial model", `serialsIssued()` increases by `v`.
3. A consolidation MUST NOT change the holder of any other serial, MUST NOT change the `balanceOf` of any account, and MUST NOT change `totalSupply()` or any allowance.
4. `consolidateSlices` has the same requirements on its arguments as `transferSlices`: the call MUST revert in the cases listed in clauses 2 to 4 of "Transfers by serial", and when serials are not held by the caller it likewise SHOULD revert with `ERCXXXXNotHeld(msg.sender, starts[i], amounts[i])`.
5. Every consolidation MUST emit one or more `SliceConsolidated(account, start, newStart, amount)` events, where `account` is the holder of these units. Each event has `amount > 0`; their slices `(start, amount)` are pairwise disjoint and together are exactly the old serials of this consolidation; and for every `0 <= k < amount`, the successor of the serial `start + k` is `newStart + k`. `consolidateSlices` MUST emit exactly one `SliceConsolidated(msg.sender, starts[i], n + p_i, amounts[i])` for each `i`, in ascending order of `i`.
6. A consolidation MUST NOT emit `Transfer` or `SliceTransferred` events. The serials a consolidation assigns are reported as issued by the `SliceConsolidated` events: for these serials, "the `Transfer` event that issues the serials it covers" in clause 4 of "Freezing and unfreezing" and in clause 5 of "Classes" means the `SliceConsolidated` event that reports them.
7. `consolidateSlices` consolidates the caller's own units. An implementation MAY restrict who can call it, and MAY refuse a call for other reasons, for example by requiring a consolidation to include at least a certain number of slices, or by allowing only accounts that hold more than a certain number of slices to consolidate (see "Costs of consolidation"). Implementations SHOULD document these conditions. A contract that does not open consolidation MAY make `consolidateSlices` revert for every caller; such a contract has no consolidated serials.
8. An implementation MAY provide other functions that perform a consolidation, for example a function with which a party authorized by the holder consolidates on the holder's behalf. Every such consolidation MUST involve only serials held by one account, MUST assign them consecutive serials starting at `serialsIssued()` in ascending order of the old serials, and MUST follow clauses 2, 3, 5 and 6, with that account in place of the caller.

A consolidation does not transfer units. It is not among the operations that "Transferable balance" addresses, it is not subject to flow rules, and it does not go through the acceptance check. When the contract implements the freezing extension or the classification extension, a consolidation is also subject to "Freezing and consolidation" or "Classes and consolidation"; the rules of these two subsections apply to every kind of consolidation an implementation provides. When a failed consolidation fits several of the errors this proposal recommends, for example when the serials named include some that are not held by the caller and some that are frozen, which one is used is not specified (see clause 4 of "Requirements on ERC-20 behavior").

Clauses 9 to 11 specify the queries on consolidation records.

9. `consolidatedSpanAt(serial)` reports whether `serial` is consolidated, its successor, and a span starting at it (see "Definitions"). For an issued `serial`, it MUST return a `(consolidated, successor, length)` that satisfies the following conditions: `length` is at least 1; `serial + length` is not greater than `serialsIssued()`; if `consolidated` is `true`, the serials `serial` through `serial + length - 1` are all consolidated and, for every `0 <= k < length`, the successor of the serial `serial + k` is `successor + k`; if `consolidated` is `false`, none of these serials is consolidated and `successor` is zero. For a `serial` that has not been issued, it MUST return `(false, 0, 0)`.
10. `consolidatedSpanAt` SHOULD return the largest `length` that satisfies clause 9. Callers MUST NOT assume that the returned span is the longest.
11. A successor can itself be consolidated by a later consolidation. To obtain the serial a unit has now, a caller starts from any serial the unit has had and queries repeatedly until `consolidated` is `false`. This proposal defines no function that looks up the old serial from the new one; the correspondence in that direction is given by the `SliceConsolidated` events.

### Operations outside the core interface

The core interface contains no function that issues units, and none that freezes units or that destroys or transfers units without the holder's consent; the latter are defined by the freezing extension, which a contract can choose whether to implement. These operations, whatever function provides them, MUST follow the rules of "Serial model" and "Events". Transfer and burn functions that an implementation provides outside the core interface and that are initiated by the holder or by a spender MUST likewise follow these two sections, and are subject to clauses 2 to 5 of "Transferable balance"; on a contract that supports the acceptance check, those of them that transfer units are also subject to "Acceptance check".

### Acceptance check

The acceptance check is OPTIONAL. A token contract that supports the acceptance check asks the recipient, when units are transferred, whether it accepts them, so that a recipient can refuse units that others transfer to it. A recipient answers by implementing the `IERCXXXXAcceptance` interface. The interface is only a query: the token calls it read-only, it is not a receipt notification, and the recipient cannot change state in it.

```solidity
interface IERCXXXXAcceptance /* is IERC165 */ {
    /// @notice Whether this contract accepts a transfer of `value` units from `from` that is
    ///         initiated by `operator` and delivered in `slices` slices. The caller is the token
    ///         contract.
    /// @dev Returns `IERCXXXXAcceptance.acceptsERCXXXXTransfer.selector` to accept.
    function acceptsERCXXXXTransfer(address operator, address from, uint256 value, uint256 slices)
        external
        view
        returns (bytes4);
}
```

This interface is implemented by the recipient, not by the token. A contract that implements it MUST implement ERC-165, and its `supportsInterface` MUST return `true` for `0x4689efd4`, the ERC-165 identifier of `IERCXXXXAcceptance`.

A token contract *supports the acceptance check* if it follows clauses 1 to 10 of this section. The acceptance check has no function on the token side, so a token declares it with an agreed identifier: a contract that supports the acceptance check MUST return `true` from `supportsInterface` for `0x29543499`, the ERC-165 identifier of the acceptance check, and a contract that does not support it MUST return `false`. This value is the selector of the error `ERCXXXXTransferRefused(address,address,uint256)`; it is not computed from function selectors in the way ERC-165 defines. It is a different identifier from `0x4689efd4`: a token contract MUST NOT return `true` for `0x4689efd4` because it supports the acceptance check, otherwise other tokens would treat it as a receiving contract and query it. In the rest of this section, "the contract" means a token contract that supports the acceptance check.

In this section, an *incoming transfer* is the movement of `value` units from `from` to `to` by an operation, reported by one `Transfer(from, to, value)` event; `to` is not the zero address. `operator` is the `msg.sender` that initiated the operation. `slices` is the number of `SliceTransferred` events the contract emits for that `Transfer` event (see "Events"). When an operation contains several incoming transfers, each is judged separately.

An incoming transfer is *exempt* if and only if at least one of the following holds:

- `value` is zero;
- `from` equals `to`;
- `operator` equals `to`.

`to` is a *receiving contract* if and only if `to` has code and, by the detection procedure that ERC-165 specifies, `to` implements ERC-165 and its `supportsInterface(0x4689efd4)` returns `true`.

1. Clauses 2 to 8 apply to every operation that transfers units and is initiated by the holder or by a spender, whatever function provides it. This includes `transfer`, `transferFrom` and `transferSlices`, and any other such function an implementation provides.
2. For every incoming transfer that is not exempt, the contract MUST determine whether `to` is a receiving contract. If `to` is a receiving contract, the contract MUST call `acceptsERCXXXXTransfer(operator, from, value, slices)` on `to` with `STATICCALL`. If the call succeeds and returns the `bytes4` value `0x4689efd4`, the selector of this function, `to` accepts the incoming transfer. In every other case `to` *refuses* the incoming transfer, including when the call reverts and when it returns other data.
3. When an incoming transfer is refused, the operation MUST revert. The contract SHOULD revert with `ERCXXXXTransferRefused(from, to, value)`.
4. If `to` is not a receiving contract, the contract MUST NOT call `acceptsERCXXXXTransfer` and MUST NOT reject the incoming transfer because `to` is not a receiving contract. Incoming transfers to an address without code, or to a contract that does not implement this interface, are therefore never refused under this section. For an exempt incoming transfer, the contract MUST NOT call `acceptsERCXXXXTransfer`.
5. The contract MUST NOT treat a receiving contract as not being one because too little gas was available. ERC-165 requires `supportsInterface` to use at most 30,000 gas. When the contract could not forward 30,000 gas to a `supportsInterface` query, it MUST NOT conclude from that query that `to` is not a receiving contract; the operation MUST revert.
6. The queries and the call to `to` MUST take place either before the operation has made any of its changes to the holders of serials or after it has made all of them; which of the two is not specified.
7. An implementation MAY limit the gas forwarded to `acceptsERCXXXXTransfer`. An implementation that does so SHOULD document the limit. When this call fails for lack of gas, the incoming transfer is refused.
8. In a transfer by amount, `slices` depends on the implementation's selection rule. This proposal does not require an implementation to look for a selection that would be accepted: when an incoming transfer by amount is refused, the operation reverts even if other serials held by the sender would have made it acceptable. Clause 4 of "Transferable balance" concerns only serials that are not transferable and does not apply here.
9. An issuance operation that an implementation provides, if any caller can execute it and name the receiving address, for example minting to an arbitrary address against a deposit of another asset, MUST treat its incoming transfers according to clauses 2 to 8, with `from` being the zero address. Issuance that only restricted callers can execute, and forced operations, which do not need the holder's consent, are not subject to this section; whether they query receiving contracts is up to the implementation, which SHOULD document it. Burning and destruction have no recipient and are not subject to this section.
10. `approve` MUST NOT revert because `spender` or the caller would refuse incoming transfers. A refusal MUST NOT change any allowance.
11. The value a receiving contract returns SHOULD depend only on the arguments of the call, on the token contract calling it and on the receiving contract's own state, not on the state of the token during the call. Under clause 6 the call can take place before the changes of holder or after them; a receiving contract that reads token state can answer differently on different implementations.

The rest of this section is informative.

A contract that needs to act when it receives units can use [ERC-1363](./eip-1363.md), which a token can implement as well. How a receiving contract decides is not specified. Why this proposal defines no notification of its own, the considerations behind the design of the acceptance check, and how a payer can find out in advance whether an incoming transfer would be refused are explained in "Dust, the acceptance check and receipt notification".

### Freezing extension

The freezing extension is OPTIONAL. A contract that implements it MUST implement the core interface and the `IERCXXXXFreezable` interface.

```solidity
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
```

`supportsInterface` MUST return `true` for `0x6eb84bb0`, the ERC-165 identifier of `IERCXXXXFreezable`.

This extension specifies how serials are frozen and unfrozen, and how an authorized party makes forced transfers of serials or destroys them. It does not specify which reasons exist or who can perform these operations; these are up to the implementation.

In a contract that implements this extension, a frozen serial is not transferable for any `(from, to)`. The frozen state is one of the states attached to a serial that "Transferable balance" refers to.

#### Freezing and unfreezing

1. Freezes are recorded per reason. For every reason, each issued serial either is frozen for that reason or is not. A reason can be any `bytes32` value, including zero; its meaning is defined by the implementation.
2. A serial is *frozen* if and only if it is frozen for at least one reason.
3. After every state-changing call has completed, whether a serial is frozen for the reason `reason` MUST be determined by the most recent event so far among the `SliceFrozen` and `SliceUnfrozen` events that have the same `reason` and cover the serial: if it is `SliceFrozen`, the serial is frozen for `reason`; if it is `SliceUnfrozen`, or if there is no such event, the serial is not frozen for `reason`. Any operation that changes the frozen state, including one that freezes serials at issuance, therefore has to emit the corresponding events. An event can cover serials whose state does not change.
4. Every `SliceFrozen` and `SliceUnfrozen` event MUST have `amount > 0` and `start + amount <= serialsIssued()`, and MUST be emitted after the `Transfer` event that issues the serials it covers. An operation that freezes serials at issuance therefore has to emit the `Transfer` event of the issuance first and `SliceFrozen` after it.
5. Freezing follows the serial. Under clause 3, a change of a serial's holder does not change the reasons for which it is frozen, unless the same operation emits the corresponding events for it.
6. After a successful call to `freezeSlice(start, amount, reason)` completes, the serials `start` through `start + amount - 1` MUST all be frozen for `reason`.
7. After a successful call to `unfreezeSlice(start, amount, reason)` completes, the serials `start` through `start + amount - 1` MUST all be not frozen for `reason`.
8. `freezeSlice` and `unfreezeSlice` MUST NOT change the frozen state of any other serial, and MUST NOT change whether any serial is frozen for any other reason. The propagation required by "Freezing and consolidation" is not limited by the preceding sentence.
9. `freezeSlice` and `unfreezeSlice` MUST revert if `amount` is zero or if `start + amount` is greater than `serialsIssued()`.
10. An implementation MUST restrict who can call `freezeSlice` and `unfreezeSlice`. Who can call them for which reason is up to the implementation, which SHOULD document it. An implementation MAY reject a call on other grounds, for example by requiring a delay or approval by several parties.
11. An implementation MAY provide other functions that change the frozen state. These functions MUST follow clauses 3 to 5 and, as in clause 10, MUST restrict who can call them.

#### Freeze queries

A reason is *in use* if and only if some serial that is issued and not destroyed is currently frozen for it.

1. `frozenSpanAt(serial)` reports whether `serial` is frozen, together with a sequence of consecutive serials starting at it that share the same frozen state, that is, a span (see "Definitions"). For an issued `serial`, it MUST return a `(frozen, length)` that satisfies the following conditions: `length` is at least 1; `serial + length` is not greater than `serialsIssued()`; the serials `serial` through `serial + length - 1` are all frozen if `frozen` is `true` and are all not frozen if `frozen` is `false`. The state here is only whether a serial is frozen; the reasons for which these serials are frozen can differ from one serial to another. Destroyed and consolidated serials have a frozen state too (see clauses 1 and 3 of "Freezing and unfreezing"), and this clause applies to them as well. For a `serial` that has not been issued, it MUST return `(false, 0)`.
2. `frozenSpanAt` SHOULD return the largest `length` that satisfies clause 1. Callers MUST NOT assume that the returned span is the longest.
3. `frozenBalanceOf(account)` MUST equal the number of frozen serials held by `account`.
4. `freezeReasonsOf(account)` MUST return two arrays of the same length. The values in `reasons` MUST be pairwise distinct; every `amounts[i]` MUST be greater than zero and MUST equal the number of serials held by `account` that are frozen for `reasons[i]`. Every reason for which some serial held by `account` is frozen MUST appear in `reasons`. The order of the entries in the arrays is not specified.
5. A serial that is frozen for several reasons is counted once under each of them, so the sum of `amounts` can be greater than `frozenBalanceOf(account)`.
6. `freezeReasonInfo(reason)` MUST NOT revert. For every reason in use, the returned `name` MUST be non-empty. `name` SHOULD be short enough to be displayed on one line.
7. `uri` MAY be the empty string. When it is not empty, it SHOULD give the description document of this reason (see "Description document"). When the `name` in the document differs from the `name` returned by `freezeReasonInfo`, the latter prevails.

#### Forced transfer and destruction

In this subsection, a *forced operation* is an operation that is initiated by an authorized party, does not need the holder's consent, and either transfers serials from their holder to another address or destroys them.

1. A forced operation SHOULD act only on frozen serials: when any of the serials that a forced operation names is not frozen, the contract SHOULD revert. This applies to every forced operation the contract provides, not only to the two functions of this interface. An implementation SHOULD document whether it requires the serials to be frozen first.
2. A successful call to `forcedTransferSlice(from, to, start, amount)` MUST change the holder of the serials `start` through `start + amount - 1` from `from` to `to`, and MUST NOT change the holder of any other serial.
3. A successful call to `destroySlice(from, start, amount)` MUST destroy the serials `start` through `start + amount - 1`, and MUST NOT change the holder of any other serial.
4. These two functions MUST revert in any of the following cases: `amount` is zero; any of these serials is not held by `from`, including serials that have not been issued and serials that are destroyed or consolidated. `forcedTransferSlice` MUST revert when `to` is the zero address or equals `from`. When serials are not held by `from`, the contract SHOULD revert with `ERCXXXXNotHeld(from, start, amount)`.
5. These two functions MUST NOT change the frozen state of any serial and MUST NOT change any allowance. If the serials moved by a forced transfer are frozen, they are still frozen for the same reasons once `to` holds them; unfreezing them is still done through `unfreezeSlice`.
6. Forced operations are not among the operations that "Transferable balance" addresses. They are not subject to clauses 2 to 5 of that section, nor to the flow rules of the classification extension.
7. A forced operation emits `SliceTransferred` and `Transfer` events as specified in "Events"; in a destruction, `to` is the zero address. In addition, for every `Transfer(from, to, value)` event emitted by a forced operation, the contract MUST emit, after that event and before it emits the next `Transfer` event, one or more `SliceForciblyTransferred(from, to, start, amount)` events: each has the same `from` and `to` as that `Transfer` event, and their slices are pairwise disjoint and together are exactly the serials reported by the `SliceTransferred` events that belong to that `Transfer` event. `forcedTransferSlice` and `destroySlice` MUST emit exactly one such event, whose `start` and `amount` are the same as the arguments of the call.
8. An implementation MUST restrict who can call `forcedTransferSlice` and `destroySlice`. Who can call them is up to the implementation, which SHOULD document it. An implementation MAY reject a call on other grounds, for example by requiring a delay or approval by several parties. A contract that does not provide forced transfer or destruction MAY make the corresponding function revert for any caller.
9. An implementation MAY provide other functions that perform forced operations, for example functions that take a position hint or that handle several slices in one call. They MUST follow clauses 5 and 7 and, as in clause 8, MUST restrict who can call them; the recommendation in clause 1 applies to them as well.

#### Freezing and consolidation

1. Frozen serials cannot be consolidated: a consolidation MUST revert if any of the named serials is frozen. The contract SHOULD revert with `ERCXXXXNotConsolidatable(account, starts[i], amounts[i])`, where `account` is the holder of these serials and `(starts[i], amounts[i])` is a slice that contains a frozen serial. The new serials are therefore not frozen for any reason when the consolidation completes, which is the state their old serials had at the time of the consolidation.
2. A freeze propagates to successors. After a successful call to `freezeSlice(start, amount, reason)`, the successor of every consolidated serial among the serials `start` through `start + amount - 1` MUST also be frozen for `reason`; when that successor is itself consolidated, the same holds for its successor, and so on up to a serial that is not consolidated.
3. An unfreeze propagates in the same way. After a successful call to `unfreezeSlice(start, amount, reason)`, the successors described in clause 2 MUST all be not frozen for `reason`.
4. Under clause 3 of "Freezing and unfreezing", every change that propagation makes to the state of a successor has to be reported by the corresponding `SliceFrozen` or `SliceUnfrozen` event.
5. Other functions that change the frozen state, which an implementation provides under clause 11 of "Freezing and unfreezing", MUST propagate in the same way.

Propagation makes the cost of a freeze or an unfreeze grow with the number of consolidation records it passes through. When a call does not fit in one transaction, the caller can split the slice into several calls, or freeze later serials of these units instead: a freeze of a serial passes only through the consolidation records from that serial onward. Clause 2 holds for consolidated serials of every generation, so freezing any serial a unit has had has the same effect; if these serials are consolidated again after the call is sent and before it executes, the freeze still propagates to the new successors. Propagation goes only toward successors and happens only at the time of a call: unfreezing a successor directly does not change the state of its earlier serials, which stay frozen for the reason while the successor no longer is; a later freeze of an earlier serial propagates to this successor again. Forced transfer and destruction act on the serial a unit has now: a consolidated serial has no holder (see clause 4 of "Forced transfer and destruction"). A contract that does not open consolidation has no consolidated serials, and the rules of this subsection hold trivially.

### Classification extension

The classification extension is OPTIONAL. A contract that implements it MUST implement the core interface and the `IERCXXXXClassified` interface.

```solidity
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
```

`supportsInterface` MUST return `true` for `0xb62c1e43`, the ERC-165 identifier of `IERCXXXXClassified`.

This extension specifies how classes are attached to serials, how they are reported, and how transfers obey the flow rules of classes. It does not specify which classes exist, or who can set or change them; these are up to the implementation. It does, however, require that every class an implementation uses can describe itself through the contract. How classes can be used is shown in "Examples of classes".

#### Classes

1. Every issued serial has a class, which is a `bytes32` value, written `classId` in the interface. Zero is the default class.
2. The meaning of a non-zero class is defined by the implementation and described through `classInfo` (see "Description"). An implementation SHOULD also document who can set and change classes.
3. `classSpanAt(serial)` reports the class of `serial` together with a sequence of consecutive serials starting at it that have the same class, that is, a span (see "Definitions"). For an issued `serial`, it MUST return a `(classId, length)` that satisfies the following conditions: `classId` is the current class of `serial`; `length` is at least 1; `serial + length` is not greater than `serialsIssued()`; and the serials `serial` through `serial + length - 1` all have the class `classId`. For a `serial` that has not been issued, it MUST return `(bytes32(0), 0)`. It SHOULD return the largest `length` that satisfies these conditions, and callers MUST NOT assume that the returned span is the longest.
4. After every state-changing call has completed, the class of a serial MUST equal the `classId` of the most recent `SliceClassified` event so far that covers it; if there is no such event, it MUST be zero. Any operation that changes a class, including one that issues serials with a non-zero class, therefore has to emit the corresponding event. An event can cover serials whose class does not change.
5. Every `SliceClassified(start, amount, classId)` event MUST satisfy `amount > 0` and `start + amount <= serialsIssued()`, and MUST be emitted after the `Transfer` event that issues the serials it covers. An operation that issues serials with a non-zero class therefore has to emit the `Transfer` event of the issuance first and `SliceClassified` after it.
6. A class follows its serial. Under clause 4, neither a change of the holder of a serial nor the destruction or consolidation of the serial changes its class, unless the same operation emits a `SliceClassified` event for it.
7. In a contract that also implements the freezing extension, classes and freezes are recorded separately. Under clause 4 of this section and clause 3 of "Freezing and unfreezing", freezing or unfreezing a serial does not change its class, and setting the class of a serial does not change its frozen state.

#### Flow rules

A class can carry a flow rule, which restricts from whom and to whom units of that class can be transferred. When a flow rule restricts the destination by the payee's address, an address it allows transfers to is called a *permitted recipient* of the class.

1. `classAllows(classId, from, to)` reports whether a serial of class `classId` held by `from` is currently allowed by its class to be transferred to `to`. `to` being the zero address denotes a burn. The function does not take into account whether the serial is frozen.
2. `classAllows(bytes32(0), from, to)` MUST return `true` for all `from` and `to`.
3. `classAllows` MUST NOT revert. For a non-zero class that is not in use (see "Description"), the return value is not specified.
4. The return value MAY depend on time and on other state of the contract, for example a list of addresses. No event has to be emitted when the return value changes.
5. In a contract that implements this extension, let `c` be the class of a serial `serial`: when `classAllows(c, from, to)` returns `false`, `serial` is not transferable for `(from, to)`. The flow rule of a class is one of the states attached to a serial that "Transferable balance" refers to. Therefore, in a contract that implements this extension and has no other restrictions attached to serials, `transferableBalanceOf(from, to)` equals the number of serials held by `from` whose class `c` makes `classAllows(c, from, to)` return `true`; when the freezing extension is implemented as well, frozen serials have to be excluded too.

#### Classes and consolidation

1. The serials of one consolidation have to belong to the same class: a consolidation MUST revert if the named serials do not all have the same class. The contract SHOULD revert with `ERCXXXXNotConsolidatable(account, starts[i], amounts[i])`, where `account` is the holder of these serials and `(starts[i], amounts[i])` is a slice that contains a serial whose class differs from that of the serial `starts[0]`.
2. After the consolidation, the class of the new serials MUST be the class the old serials had at the time of the consolidation. When this class is not zero, under clause 4 of "Classes" the contract has to emit a `SliceClassified` event for the new serials after the `SliceConsolidated` events.
3. This proposal does not require a change of class to propagate to successors: setting the class of a consolidated serial after the consolidation need not change the class of its successor. When an implementation makes such an operation act on successors as well, it likewise has to emit events for the successors under clause 4 of "Classes".

#### Description

A class is *in use* if and only if some serial that is issued and not destroyed currently belongs to it.

1. `classesOf(account)` MUST return two arrays of the same length. The values in `classIds` MUST be pairwise distinct; every `amounts[i]` MUST be greater than zero and MUST equal the number of serials held by `account` whose class is `classIds[i]`. Every serial held by `account` MUST be counted, including frozen serials; serials of the default class are counted under zero. The order of the entries in the arrays is not specified.
2. The sum of `amounts` therefore equals `balanceOf(account)`.
3. `classInfo(classId)` MUST NOT revert. For every non-zero class that is in use, the returned `name` MUST be non-empty. `name` SHOULD be short enough to be displayed on one line.
4. `uri` MAY be the empty string. When it is not empty, it SHOULD give the description document of the class (see "Description document"). When the `name` in the document differs from the `name` returned by `classInfo`, the latter prevails.

### Description document

When the `uri` returned by `freezeReasonInfo` or `classInfo` is not empty, it gives a *description document* that explains the reason or class. The freezing extension and the classification extension use the same document format.

1. `uri` SHOULD be a data URI that begins with `data:application/json` and contains the document directly. It MAY be another URI that points to the document.
2. The document SHOULD be a JSON object that conforms to the structure below. `name` and `description` have to be present: `name` is the name of the reason or class, and `description` is an explanation intended for holders. `image` and `properties` can be omitted.
3. `properties` is an object that holds properties of the reason or class, for example parameters encoded in the class. Its internal structure is not specified, and its values can be strings, numbers, objects or arrays.
4. The document MAY contain fields that are not defined here. A party that reads the document SHOULD ignore fields it does not recognize.

```json
{
  "title": "Description Document",
  "type": "object",
  "required": ["name", "description"],
  "properties": {
    "name": {
      "type": "string",
      "description": "The name of the freeze reason or class."
    },
    "description": {
      "type": "string",
      "description": "An explanation of the freeze reason or class, intended for holders."
    },
    "image": {
      "type": "string",
      "description": "Optional. A URI pointing to a resource with mime type image/*, or a data URI containing the image."
    },
    "properties": {
      "type": "object",
      "description": "Optional. Arbitrary properties. Values may be strings, numbers, objects or arrays."
    }
  }
}
```

The following is an example of a description document for a class.

```json
{
  "name": "Locked until 2030",
  "description": "Units of this class cannot be transferred before 1 January 2030 (UTC).",
  "image": "data:image/svg+xml;base64,PHN2Zy8+",
  "properties": {
    "unlock_time": 1893456000
  }
}
```

`name`, `description` and `image` are the same as in the metadata of [ERC-721](./eip-721.md), and `properties` is the same as in the metadata of [ERC-1155](./eip-1155.md).

## Rationale

This section summarizes the design decisions and the main reasons for them. The full discussion, including the alternatives that were considered and the point-by-point comparisons with other standards, is in [rationale.md](../assets/erc-draft_serial_numbered_token/rationale.md).

### Applicability

This proposal suits assets in which every unit represents the same right, with the same face value and the same terms, while some units need to be treated individually. Examples are stablecoins and deposit receipts for which action can be taken against specific funds, a single bond issue, subsidies and consumption vouchers that can only be paid to designated addresses, in-game currency, and points. Units differ only in whether they can be transferred out, to whom they can be transferred, and where they came from.

The following cases do not suit this proposal, or cannot conform to it.

- Measures against accounts, for example blocking an address. These need a separate account-based mechanism, such as those defined by ERC-3643 and ERC-7943; such a mechanism can be used on the same token as this proposal.
- Assets with different rights in one contract. Such assets should use one contract each, or a standard that keeps separate accounts for each asset, for example ERC-3525, ERC-1155 and [ERC-7518](./eip-7518.md) (see "Classes do not represent different rights").
- Tokens that charge a fee on transfer, or that change balances without issuance or destruction, for example tokens that scale balances proportionally. They cannot conform to this proposal: a transfer has to move exactly `value` serials, and a balance changes only together with a `Transfer` event.
- Assets that need privacy (see "Reduced fungibility and privacy").

Assets that suit this proposal also enter contracts with frequent transfers, such as market-making pools and lending pools; stablecoins are an example. A token that conforms to this proposal is an ERC-20 token, and these contracts interact with it as with any ERC-20 token (see "Backwards Compatibility"). Integrators need to consider three things in particular. The cost of a transfer grows with the number of slices (see "Fragmentation and gas"). Units in a pool might later be frozen, and integrators should treat such a token as they would any token whose issuer can freeze funds (see "Freezing follows units, not people"). Units subject to a flow rule might be impossible to pay out (see "Destination-dependent flow rules and contracts").

### Design of serials

The specification describes state as a mapping from serials to holders, and slices are only the encoding used by events and views. How holdings are stored, and which units a transfer by amount draws on, are up to the implementation; the specification instead requires every movement to be reported, so the rule actually in use is observable.

Serials are issued consecutively from `0`, and a transfer does not change the serial of a unit. The units descended from a holding are therefore exactly the serials that holding consisted of, transfers create no ancestry graph that has to be recorded or traversed, and freezing by slice is complete and free of races. The only operation that renumbers units is a consolidation, which records the correspondence between old and new serials in the contract, and freezes propagate along that record (see "Design of consolidation"). On a token that does not open consolidation, where holdings really do need to be consolidated, the issuer can exchange them: the holder transfers the units to the issuer, the issuer burns them after confirming that they are not involved in anything that calls for a freeze, and then issues the same number of new units to the holder.

`transferSlices` lets a holder name the units it sends. It is part of the core because it is a function called by wallets, which every token that conforms to this proposal has to provide in the same way. On a token whose holders can freely use several accounts, it gives holders no new capability: transferring by amount back and forth between accounts the holder controls can single out particular units just as well. On a token that only registered accounts can hold, it gives holders a choice they did not have before. This proposal defines no function for a spender to transfer by serial, because `approve` did not originally grant the power to choose which units are drawn on.

### Relation to ERC-20

This proposal changes none of the functions or events of ERC-20 and only settles a few points that ERC-20 leaves open or merely recommends, for example that a failure reverts instead of returning `false`, that the number of decimals must not change, and that a transfer to the zero address cannot be used to destroy units; it also recommends the errors of ERC-6093 and the signatures of the burn functions `burn`, `burnFrom` and `burnSlices` (see "Requirements on ERC-20 behavior"). The `approve` race and approval by signature (for example [ERC-2612](./eip-2612.md)) are unrelated to the identity of units and are left to existing proposals.

`balanceOf` changes only together with a `Transfer` event, so frozen units remain counted in the balance, and the transferable balance is given separately by `transferableBalanceOf`. Otherwise indexers that compute balances by summing `Transfer` events would get wrong results, and `totalSupply` would either no longer equal the sum of the account balances or turn freezing into a reduction of supply. An allowance keeps its ERC-20 meaning and is only an upper limit on an amount; neither freezing nor the rules of classes change it.

### Form of the queries and events

`transferableBalanceOf` is part of the core and takes the destination as a parameter. Wallets and contracts then need to ask only one question, namely how much can be transferred from here to there now, whichever extensions the token implements. `frozenSpanAt` and `classSpanAt` return, together with the state of a serial, the length of the span of serials in the same state that starts at it, because a token with 18 decimals has 10^18 serials per whole token and querying serial by serial would be pointless. This proposal provides no on-chain lookup of the holder of a serial, because that would need an ordered index that is updated on every transfer; the holder of a serial can be derived from the events.

The slices a transfer moves are reported slice by slice in `SliceTransferred` events, one slice per event, and a batch event carrying arrays is not used: the most common transfer moves a single slice, for which a single event is cheaper, and indexers need to support only one encoding. The `SliceTransferred` event accompanies the ERC-20 `Transfer` event and never replaces it, which differs from [ERC-2309](./eip-2309.md). The order of the events is specified, so an indexer can attribute every `SliceTransferred` event to the `Transfer` it belongs to without heuristics.

### Dust, the acceptance check and receipt notification

Every non-adjacent slice a recipient holds has a cost (see "Dust attacks"). This cost comes from the identity this proposal keeps for every unit. This proposal chooses to keep that identity, and makes the following choices among the ways of dealing with dust.

- **No minimum transfer amount is set.** Rejecting incoming transfers by amount would expose payers that know only ERC-20 to failure when paying any account. A minimum amount also does not stop fragmentation; it only makes each slice of dust cost a little more value. The right threshold differs from token to token and from account to account.
- **The acceptance check is optional and read-only.** A receiving contract can refuse an incoming transfer, and the token asks it at the time of the transfer. The check is optional because the core only adds serials and does not change whether any transfer succeeds or fails. It applies to every form of transfer initiated by a holder or by a spender, with no separate safe transfer, because the sender chooses which path to take and a check on a separate path cannot stop something that is sent on purpose. It asks only contracts that declare through ERC-165 that they implement the acceptance interface, so existing contracts that know only ERC-20 are paid as usual. Unlike the callbacks of ERC-721, ERC-1155, [ERC-777](./eip-777.md) and ERC-3525, it is a query made with `STATICCALL`, not a notification: the called contract cannot emit an event or complete another transfer. A payer can simulate the transfer in advance, or query the receiving contract as the token would (with the caller set to the token contract's address); for a transfer by amount the number of slices is not known in advance, so only a simulation works. The receiving contract sees the number of slices, because its cost is counted per slice.
- **No registered checker is defined.** If every account could register a checker contract with the token, addresses without code could use arbitrary rules as well. This proposal does not adopt that approach: the token would have to store a registration for every account, a shared checker contract raises a new question of trust, and the contracts that most need rules of their own can implement the acceptance interface themselves; an address that has set a delegation under [EIP-7702](./eip-7702.md) has code as well, and it is likewise a receiving contract when its delegation target implements the interface. An implementation can still provide, on its own, limits set by accounts, for example a receive limit for accounts (see "The acceptance check and failed payments").
- **No receipt notification is defined.** A contract that needs to act when it receives units can use ERC-1363, which a token can implement as well. This proposal defines no notification attached to every transfer: with such a notification, any contract that pays out would run the payee's code when it pays, although the paying contract is not the party that chose the notification; and if the notification could make a transfer fail, the read-only acceptance check could no longer tell whether a transfer would succeed. A contract that needs to know which serials an incoming transfer brought, for example a custody contract, can give every payer a dedicated deposit address, where a small contract moves the units it receives to the main contract with `transferSlices`.

### Design of the freezing extension

Freezing is an optional extension, because freezing with reasons is not cheap to implement and an issuer that only wants to sort units into a few classes has no use for it. A freeze is aimed at specific units, wherever they are; ERC-3643 and ERC-7943 freeze an account or a given amount within an account. The two complement each other, and a token can use both.

Freezes carry a reason, because several parties can have the right to freeze the same units at the same time, for example when units are first pledged and later put under a judicial freeze. Unfreezing lifts only one reason, and a serial stays frozen until its last reason is lifted. The freeze functions are part of the interface, because a pledge contract, a custodian and an agency carrying out a court order deal with many different tokens; who can call them for which reason is up to the implementation.

Destruction and forced transfer are in the same extension as freezing, because an issuer that has the right to freeze units usually also needs to dispose of them after freezing. A forced transfer does not change frozen state; otherwise the party executing it could lift reasons set by others. Nor can it be replaced by destruction followed by a new issuance, because the newly issued units have new serials, and neither the history, nor the class, nor the freeze reasons of the original units would be kept. This proposal recommends that forced operations act only on frozen serials, but does not make it a requirement, because a contract could freeze and dispose in the same transaction (see "Powers of the authorized party"). The `SliceForciblyTransferred` event distinguishes forced operations from the holder's own transfers; without it, a forced transfer would be indistinguishable in the events from an ordinary transfer.

### Design of consolidation

Every time an account receives units whose serials are not adjacent to those it already has, it holds one more slice. A selection rule can change which accounts accumulate scattered slices, but it cannot eliminate them: an account that collects payments over a long time and then pays out in bulk, such as a merchant, an exchange or a pool, sees its number of slices keep growing until a transfer no longer fits in one transaction. Consolidation lets such an account renumber its scattered units into one slice. It concentrates the cost in the consolidation, paid by the consolidating account at a time of its choosing; without consolidation, the cost of these scattered slices is paid again every time they change hands, and it is passed on to the next holder with each payment.

Renumbering units would break tracing by serial, and this proposal preserves it with three rules. First, the correspondence between old and new serials is recorded in the contract, and freezes and unfreezes propagate along it, so freezing any serial a unit has had freezes the serial it has now. Second, propagation holds from the serials of every generation, so consolidating ahead of a freeze does not make the freeze miss. Third, frozen units cannot be consolidated, so a consolidation never has to move any frozen state. Transfers do not consult the record, and their cost is not affected; the cost falls on consolidations and on the freezes that pass through consolidation records, and both operations are far less frequent than transfers.

New serials are assigned in ascending order of the old serials, so the units of one consolidation that come from the same old slice receive new serials that are still adjacent. A holder therefore cannot use the order of the list to interleave a slice that might later be frozen with other units, which would multiply the slices a freeze has to pass through.

A consolidation emits no `Transfer`, because no balance changes; reporting it as a burn followed by an issuance would make a party that looks only at ERC-20 events believe that the supply had changed. The units of one consolidation have to belong to the same class, because classes are recorded by serial and the new serials need one definite class.

Consolidation is in the core for two reasons. Fragmentation comes from keeping accounts by serial itself, and every account that collects payments over a long time runs into it, so the remedy should not depend on which extensions a token chose. And `consolidateSlices` is a function called by wallets, so every token has to offer it in the same way, and indexers need only one way of handling it.

Who can consolidate is left to the implementation. When it is open to all holders, the issuer does not need to know in advance which accounts will use it, and does not need to vet and authorize them one by one; the price is that the number of records a freeze passes through is decided by holders. When only listed accounts can consolidate, that number is under control, and the price is maintaining the list. Both approaches use the same interface. An implementation can also require a consolidation to include at least a certain number of slices, so that creating a record costs no less than a freeze passing through it (see "Costs of consolidation"). A token that does not want units to be renumbered can make `consolidateSlices` revert for every caller; on such a token a unit keeps its serial for its entire life.

### Design of the classification extension

A class answers "where does this unit come from and where can it go"; freezing answers "can this unit move now"; the two are recorded separately. A class is an opaque `bytes32` whose meaning is up to the implementation. `classAllows` takes a class rather than a serial as its parameter, so a rule can change with time or with a list without state having to be updated for every affected serial.

Units of all classes are counted in the same ERC-20 balance. Classes are therefore not partitions in the sense of ERC-7518; they distinguish only where units can go and where they come from, not rights (see "Classes do not represent different rights").

Classes also differ from wrapper contracts, such as the purpose bound money defined by [ERC-7291](./eip-7291.md). A wrapper token is a different asset and can be transferred freely among holders without the constraint being defeated. Units constrained by a class remain the same token, and the constraint must be written into the flow rule: if a class allows its units to be transferred to any address, they can be used as ordinary units. When the constraint is set by the token's issuer, classes can be used; when it is set by someone else, and the token's implementation provides that party no entry point for setting classes and rules, a wrapper contract should be used.

### Examples of classes

This proposal does not specify which classes exist. The following examples are arranged by asset. The "Flow rules" column gives the value that `classAllows(classId, from, to)` returns when `to` is not the zero address.

| Asset | Class | Flow rules |
|---|---|---|
| Stablecoin | Purpose bound funds, for example subsidies and consumption vouchers | Returns `true` only when `to` is a permitted recipient (for example a participating merchant) |
| Stablecoin | Purpose bound funds with a validity period | Same as above during the validity period; after expiry, returns `false` for any `to` |
| Stablecoin | Issuance batch or issuance channel | No flow rule; always returns `true` |
| Securities (for example company shares or fund shares) | Securities subject to a lock-up period | Returns `false` until the lock-up is lifted, and always returns `true` afterwards |
| Securities (for example company shares or fund shares) | Offering round | No flow rule |
| Bonds | The part of an issuance that is placed privately | Returns `true` only when `to` is a qualified investor registered by the issuer |
| Bonds | Subscription batch | No flow rule |
| Points | Points from different sources, for example points earned by spending and points given away in promotions | No flow rule |
| Points | Points that cannot be transferred between users | Returns `true` only when `to` is the issuer or a merchant |
| Points | Points that expire by the year in which they were earned | Follows its original rule until expiry; after expiry, returns `false` for any `to` |

**Permitted recipients.** When a flow rule restricts the destination by the payee's address, units of the class can only be transferred to its permitted recipients (see "Flow rules"). Which class a unit belongs to once it is in the hands of a permitted recipient is up to the implementation: it can still belong to its original class, or it can be changed to the default class in that transfer, in which case the constraint falls only on the payer (see "Destination-dependent flow rules and contracts"). In a payment by amount to a permitted recipient, the selection rule might use up units of the default class first; an implementation can make its selection rule use the restricted units first in such payments, and a holder can also name them with `transferSlices`.

**Lock-up and expiry.** A lock-up is lifted automatically when its period ends, without anyone having to unfreeze anything, so it is suitably represented by a class; pledges and judicial freezes have to be released by a party with the authority to do so, and are represented by freezes. Expired units are not transferable to any destination but still count toward `balanceOf` (see "Balance includes units that cannot be transferred").

### Describing reasons and classes

Once the meaning of reasons and classes is left to the implementation, a wallet faces a `bytes32` it does not recognize. The specification therefore requires every reason in use and every non-zero class in use to have an on-chain name, which a wallet can obtain with read-only calls alone; longer descriptions go into an optional description document.

`classInfo` returns only a name and a `uri`; there is no identifier field for programs to recognize. Such an identifier is useful only when its values are agreed on and constrain how a class behaves, and the rules of real-world classes are often a combination of several conditions, for example a restriction on payees together with a validity period, which a single value cannot declare. A program that knows a token can recognize its classes by `classId`, and parameters meant for programs can go in the `properties` of the description document. A later proposal that defines identifiers common to all tokens can declare them through an interface of its own.

### Relation to ERC-8047

ERC-8047 is a draft at the time of writing. It has the same goal as this proposal and takes a graph approach: every transfer creates a new token id that records its parent. This proposal differs in four respects.

- The token remains an ERC-20 token, so existing wallets, exchanges and contracts can use it without modification.
- Transfers do not renumber units, so transfers create no graph that has to be maintained. If each slice of consecutive serials that a holding originally contained is frozen once, the freezes name exactly all of the units descended from that holding, however many holders they have since been divided among. Only a consolidation renumbers units: it is initiated by the holder, it records a one-to-one correspondence from old serials to new ones, and the contract propagates freezes along that record.
- The balance and the transferable balance are given on-chain and do not have to be computed by off-chain services.
- Putting together units received in several payments creates no new identity. An implementation can store adjacent serials as one slice, but the serials themselves do not change.

The two designs pay the same price: holdings fragment, and the cost of a transfer depends on how many pieces it moves.

### What a wallet needs to support this proposal

A wallet that does not know this proposal can use a token that conforms to this proposal as an ERC-20 token as usual, except that the balance it displays can include units that cannot be sent. All of the queries needed to support this proposal fully can be made with read-only calls and need no indexer. The steps in detail, and how to explain to the user why part of a balance cannot be sent, are in [wallet-support.md](../assets/erc-draft_serial_numbered_token/wallet-support.md).

## Backwards Compatibility

This proposal adds to ERC-20 and changes none of its functions or events, so existing wallets, exchanges and contracts interact with a token that conforms to this proposal as with any ERC-20 token. In several places where ERC-20 leaves a choice, this proposal specifies the behavior (see "Requirements on ERC-20 behavior"), and everything it specifies there is within what ERC-20 allows. Several behaviors differ from a minimal ERC-20 implementation and can matter to integrators:

- The gas cost of a transfer is not constant. It grows with the number of slices the transfer has to move.
- A transfer to the zero address reverts. A contract that relies on "transferring to the zero address" to destroy tokens needs to use a burn function instead.
- When the freezing extension or the classification extension is implemented, a transfer can revert although `balanceOf` is sufficient, and `balanceOf` can exceed the amount an account is actually able to transfer. When the classification extension is implemented, the amount that can be transferred can also depend on the destination.
- When the freezing extension is implemented, an account's balance can decrease without the holder initiating it, as with other tokens that give an issuer confiscation powers.
- On a token that supports the acceptance check, a transfer to a contract that implements the acceptance interface can revert even though the sender's balance and transferable balance are both sufficient (see "Acceptance check"); a transfer to an address with code also pays the extra gas of querying it. Addresses without code and contracts that do not implement this interface are not affected. Tokens that do not support the acceptance check have none of these differences.
- The serial of a unit can change through a consolidation. A consolidation changes no balance and emits no `Transfer`, so integrators that use only ERC-20 functions and events are not affected. An indexer that reconstructs holdings from `SliceTransferred` events also has to process `SliceConsolidated` events.

## Test Cases

The test cases are in [test-cases.md](../assets/erc-draft_serial_numbered_token/test-cases.md). They are sequences of operations, which check, in order, issuance and transfers by amount, freezing and unfreezing, `transferSlices` and `burnSlices`, the classification extension, forced transfer and destruction, consolidation, and the acceptance check. Each sequence lists, step by step, the calls, the events that are to be emitted and the values that the queries return. Under the assumptions stated in that file, the sequences hold for every implementation that conforms to this proposal, whatever its selection rule.

## Reference Implementation

A reference implementation accompanies this proposal. Its code and tests are placed with the other assets of this proposal, and [README.md](../assets/erc-draft_serial_numbered_token/README.md) describes the layout of the directory and how to run the tests. It implements the core interface, the freezing extension and the classification extension, supports the acceptance check, and in addition provides `burn`, `burnFrom` and `burnSlices`, as well as two groups of functions that this proposal does not define: forced transfer and destruction that take a position hint, provided under clause 9 of "Forced transfer and destruction", and `tidySlices`, which only tidies holdings and transfers nothing. It does not implement ERC-1363.

The core contract `ERCXXXX` implements ERC-20 and the core interface, and keeps consolidation closed by default. The freezing extension, the classification extension, an example class that restricts destinations by payee address, the acceptance check, burning, tidying and the module that opens consolidation are each a separate contract, which a token inherits as needed. Who can freeze, force transfers, and define and set classes is decided by authorization functions that the token implements itself. The storage of holdings sits behind an abstraction layer and has two interchangeable implementations: a slice stack (last-in-first-out) and a sorted array in ascending order of start. Both use one storage slot per slice; they serve to compare the gas of different data structures.

The reference implementation falls short of this proposal's recommendations in several places: the cost of skipping serials that are not transferable is bounded only in the amortized sense; the cost of locating by serial is bounded only for the functions that take a position hint, and only on the slice stack; the default selection rule pays out first the units received most recently or the units with the largest serials; the consolidation module does not by default limit how many slices a consolidation includes; and no receive limit for accounts is provided. Nor has its code been reduced in size: a token with only the core interface, consolidation included, is within the contract code size limit, and it is the optional extensions that take a token over that limit, the freezing extension most of all, so combinations that include the freezing extension cannot at present be deployed as a single contract; the sizes of the combinations are listed in README.md. These places are described in [reference-implementation.md](../assets/erc-draft_serial_numbered_token/reference-implementation.md), together with the storage of holdings, the two selection rules, the storage of consolidation records, and what the reference implementation does in the places that "Acceptance check" leaves up to the implementation.

## Security Considerations

This section states, item by item, the risks that implementers, integrators and wallets need to know about, and the recommended practice. The three subsections "Fragmentation and gas", "Dust attacks" and "The acceptance check and failed payments" are summaries; the full analysis is in [security-considerations.md](../assets/erc-draft_serial_numbered_token/security-considerations.md).

### Freezing follows units, not people

Freezing a slice affects whoever holds those units when the freeze takes effect. If a thief sells stolen units before they are frozen, the units that end up frozen or destroyed belong to the buyer or to the liquidity pool that took them, while the thief keeps the proceeds. A recipient cannot know in advance that the units it accepts will later be frozen. A thief who observes a pending freeze can also try to sell ahead of it. Issuers need a clear policy on how quickly and under which conditions slices are frozen and on how innocent recipients are treated, and integrators have to treat a token that implements the freezing extension as they would any token whose issuer can freeze funds.

### Descriptions are the token's own claims

The names and documents returned by `freezeReasonInfo` and `classInfo` are all supplied by the token contract itself, and no third party verifies them. How a token actually behaves is determined by the values that `transferableBalanceOf` and `classAllows` return and by the outcome of the transfers themselves; when what a name says disagrees with that, a wallet cannot detect it from the interface alone. Nor does the interface say who can freeze and unfreeze or who can set classes: two tokens that both conform to this proposal can give holders entirely different guarantees, and integrators must read a token's own documentation and code before integrating it.

Wallets must treat these strings as untrusted input: limit their length, filter out control characters and easily confused characters, and not parse them as markup. When `uri` is a data URI, the description document is in the return value of the call itself, and wallets should limit its length. When `uri` points to an external resource, fetching it reveals the user's network address to an external server, and the document can also become unavailable or be replaced. Even when the document is on-chain, the `image` in it can still point to an external resource, with the same problems; the image itself is untrusted content too, for example an SVG can contain scripts. Wallets should therefore not depend on the description document to complete their display. The `properties` in the document are likewise only the token's own claims, and a wallet cannot use them to decide whether a unit can be transferred out. The result of `classAllows` can change over time or as a list changes, and callers should not cache it.

The arrays returned by `freezeReasonsOf` and `classesOf` have no upper bound on their length. An implementation that encodes parameters into the class, for example by using a different unlock time for every lock, can leave one account holding a great many different classes, and a third party can also increase that number by transferring in units of different classes. Contracts that call these functions on-chain must take this into account.

### Number of reasons

A serial can be frozen for several reasons at the same time. The cost of determining whether a serial is frozen can grow with the number of reasons in use, and every transfer has to make that determination. Implementations should limit the number of reasons that can be in use at the same time, or use a storage layout whose cost does not grow with the number of reasons. "In use" counts only serials that are not destroyed, while destroyed serials still keep their frozen state: issuing, freezing and then destroying, over and over, can leave behind many reasons that are no longer in use but still have records. Limiting only the number of reasons in use does not limit the growth of these records; implementations should make sure that transfers and account-level queries do not need to scan them.

The interface separates the power to freeze by reason, but it does not by itself guarantee that one party cannot lift another party's reason: who can unfreeze for which reason is up to the implementation. A party that relies on a reason, for example a pledgee, must confirm that the token's implementation does not allow anyone else to lift it. A reason only prevents the holder from transferring the units out, so that party also needs to confirm who can destroy or forcibly transfer frozen units.

### Selection order can be influenced

Units held by a shared contract, such as a pool or vault, are paid out according to the implementation's selection rule. Under last-in-first-out, the most recently deposited units are the next to leave, so a depositor can make it likely that particular units are passed on to the next withdrawer; under first-in-first-out they would instead sit behind earlier deposits. Whoever designs a token on this proposal has to consider how the rule distributes units that may later be frozen.

### Holders can choose which units to send

A holder can use `transferSlices` to name the units it sends, for example to pay others first with the units it believes might later be frozen. How far this is a new capability depends on whether holders can freely use several accounts (see "Design of serials"). A recipient that cares which units it receives must check the serials reported by the `SliceTransferred` events and cannot look at the amount alone. This check can only be made off-chain: a contract cannot read events during execution, and this proposal has no function that makes a transfer by amount return the serials selected. A contract that needs to confirm on-chain which units it received needs to agree on a separate way of interacting with the payer, for example having the payer transfer in specified serials with `transferSlices`, and to bear the cost of checking its holding with queries such as `sliceAt`.

### Fragmentation and gas

The cost of a transfer grows with the number of slices it moves: when the serials a transfer moves together form k non-adjacent slices, the contract has to emit at least k `SliceTransferred` events. Two accounts with the same balance and the same transferable balance can therefore pay very different costs for paying out the same amount, and in the extreme a single transfer can exceed the gas available to a transaction. The number of slices in an account can be inflated by others (see "Dust attacks"), which is most damaging for contracts that cannot split their outgoing transfers. Contracts that forward a fixed amount of gas with token transfers are not safe to use with these tokens. For accounts that receive payments over a long period, such as merchants, pools and vaults, integrators should evaluate on the target chain how much one transaction can actually transfer out of the account.

An implementation can reduce this cost in the following three areas.

- **The selection rule.** An implementation's selection rule should not pay out recently received small slices first; it can, for example, prefer a single slice that is enough to pay the whole amount. Such a rule likewise affects which units are paid to whom (see "Selection order can be influenced"). A selection rule changes which accounts accumulate scattered slices; it cannot eliminate fragmentation: an account that keeps receiving many payments of non-adjacent units still sees its number of slices grow.
- **Slices that are not transferable.** A transfer by amount has to skip serials that are not transferable (see clause 4 of "Transferable balance"). If an implementation leaves these slices on the selection path, every transfer pays for every slice it skips. This cost can be driven up by others, for example by transferring to a permitted recipient many small scattered slices of units that are subject to a flow rule: when the units still belong to their original class after they arrive, every later transfer by that recipient to an address the class does not allow has to skip them. Small scattered units that are frozen after they are transferred in give rise to the same situation. When enough slices are skipped, a transfer that does not exceed the transferable balance might not fit in one transaction. Implementations should take slices that are not transferable off the selection path.
- **Locating by serial.** `transferSlices`, `forcedTransferSlice` and `destroySlice` have to locate the named serials in the account's holding. In an implementation that locates them by scanning, the cost grows with the number of slices the account holds, and that number can be inflated deliberately: a holder can split its own holding into many slices beforehand, and after a freeze others can still transfer small scattered amounts of units to the account. In the extreme, a forced operation no longer fits in one transaction. Implementations should use a storage layout in which the cost of locating serials is bounded, or, as the freezing extension allows, provide additional functions that take the position of the slice as a hint and verify it.

A holder can use `transferSlices` to transfer the units out of a fragmented account over several transactions, but this does not help contracts that can only call `transfer`. A holder can consolidate scattered slices into one (see "Consolidation"). On a token that does not open consolidation, non-adjacent slices cannot become one slice; when a holding really needs to be consolidated, the issuer can exchange it (see "Design of serials").

### Dust attacks

A dust attack is the sending of very small amounts of units to someone else's account. In an ordinary ERC-20 token, the recipient bears no cost for a received amount. This proposal changes that: a received amount that is not adjacent to the serials the recipient already holds adds a slice to its holding, and that slice stays in the holding until it is transferred out, burned or destroyed; received units might also be frozen later. By the attacker's aim, the following cases can be distinguished.

- **Raising costs.** The attacker sends many very small non-adjacent slices into an account, raising the cost of its later transfers, operations by serial and account-level queries (see "Fragmentation and gas" and "Balance includes units that cannot be transferred"). If the selection rule pays out the most recently received units first, or the units with the highest serials first, the victim's later payments also draw on the dust first and pass it on to the payees. The less a unit is worth, the cheaper dust is for the attacker; this should be considered when choosing the number of decimals, and "Finite serial space" needs to be considered as well.
- **Passing on history.** Someone who holds stolen units, or units involved in a case, can split them into very small amounts before they are frozen and scatter them across a large number of unrelated addresses. The number of freezes needed does not change, because the scattered units are still within the few slices of consecutive serials they were in originally. The recipient's other units are not affected either, because history follows units, not accounts. What increases is the work of disposal: an issuer's policy should state how very small amounts scattered to unrelated accounts are treated. Exchanges and compliance screening should assess an account's exposure by serial, rather than treating the whole account as suspect because it once received units from a certain address.
- **Tracking markers.** The attacker knows the serials it sent, and after these units enter a contract that mixes many people's funds, such as a pool or an exchange, it can still tell from the serials paid out where they went (see also "Reduced fungibility and privacy").
- **Zero-value transfers.** This proposal emits no `SliceTransferred` event for a zero-value `Transfer` (see "Events"), so a wallet that displays history by `SliceTransferred` events does not show the zero-value entries that address poisoning forges. A very small real transfer sent from a look-alike address still has a `SliceTransferred` event, so wallets should not let users copy a payee address from the transaction history.

Dust can be dealt with in the following ways. On a token that supports the acceptance check, a receiving contract can refuse incoming transfers (see "Acceptance check"). An implementation can let accounts set a receive limit for themselves (see "The acceptance check and failed payments"), and can reduce the cost of dust through its selection rule and storage layout (see "Fragmentation and gas"). A holder can avoid the dust by using `transferSlices` to pay only units of its own choosing; on a token that provides burning by holders, it can also burn the dust, but frozen dust and dust whose class does not allow burning cannot be cleaned up this way.

The acceptance check is optional, and only contracts that implement the acceptance interface can refuse: on a token that does not support it, dust can be sent to any address; on a token that supports it, dust can still be sent to addresses without code and to contracts that do not implement the interface. A token that circulates publicly and will be held by contracts needs the acceptance check and a receive limit for accounts all the more. On a token that does not support the acceptance check, a contract that receives payments over a long period and cannot split its outgoing transfers can use `transferSlices` to pay only units of its own choosing, or can decline to integrate the token.

### The acceptance check and failed payments

On a token that supports the acceptance check, a receiving contract can make transfers paid to it fail. This is what the acceptance check is for, and it also has the following consequences.

- **A payer can be blocked.** A contract that pushes payments to addresses named by others, for example an auction that refunds the previous bidder when it receives a new bid, can have a whole operation fail because one payee refuses. Such contracts should let payees withdraw for themselves, or record a payment when it fails. A receiving contract can change its answer at any time, and the result of a query or a simulation made in advance does not guarantee that the transfer that follows succeeds. When a recipient refuses by number of slices, a normal payment from a payer with a fragmented holding can be refused as well, and that holding might have been fragmented precisely by dust that others scattered on it; the payer can name longer slices with `transferSlices`.
- **A receiving contract is arbitrary code of the payee.** The gas it consumes is borne by the payer, and wallets should estimate gas for every transaction individually; an implementation can limit the gas forwarded to it and read only the first 32 bytes of the return data. The read-only call prevents reentrancy and misplaced events; it does not prevent a receiving contract from depending on external state that the payer can manipulate.
- **Lowering the gas could bypass the query.** The query that determines whether the payee is a receiving contract is taken as "not a receiving contract" when it fails or answers "no". A payer that can, by lowering the gas, make this query fail or answer "no" while the rest of the transfer succeeds has bypassed the acceptance check. That is why clause 5 of "Acceptance check" requires the contract to revert when it could not forward 30,000 gas to a query; an implementation needs to check the available gas before every query and cannot look only at whether the call succeeded.
- **What the acceptance check does not stop.** Addresses without code cannot implement the acceptance interface, and a contract that is already deployed and cannot be upgraded cannot implement it after the fact. Incoming transfers that the recipient pulls itself, restricted issuance and forced operations are not subject to the acceptance check; a contract that lets anyone trigger it to pull needs to set limits in its own entry points.

**Limits set by accounts themselves.** This proposal specifies no way for addresses without code to refuse; an implementation can provide one itself (see clause 6 of "Transferable balance"). One suggested approach is a receive limit for accounts: every account sets a number for itself on the token, namely how many units, at least, an incoming transfer has to contain per slice on average, and the token rejects an incoming transfer that falls short of it; the number of slices is the number of `SliceTransferred` events of that incoming transfer. The threshold is counted per slice because the recipient's cost is counted per slice; a limit of this kind raises the price and does not block. The threshold of accounts that have never set one can be decided by the issuer. When it is not zero, small transfers paid to those accounts fail, and payers that know only ERC-20 do not expect such failures. A party that can change the threshold of accounts that have never set one can make all of those accounts refuse small amounts together; deployments should put this power under the same controls as the right to freeze (see "Powers of the authorized party"). An implementation can also provide other limits set by accounts, for example a list of trusted senders.

### Costs of consolidation

This subsection applies to tokens that open consolidation.

- **The cost of a freeze grows with consolidation records.** Without consolidation, the cost of freezing a slice does not depend on how many holders the units have since been divided among. With consolidation, a freeze propagates once more for every consolidation record it passes through, and the number of records depends on how many times the holders of these units have consolidated. Whoever holds stolen units can divide them among many accounts and consolidate once in each, or consolidate the same units again and again, so that one freeze has to pass through many records. Each of these consolidations costs its caller gas as well. An implementation should make creating a record cost no less than a freeze passing through it, for example by requiring a consolidation to include at least a certain number of slices (clause 7 of "Consolidation"). A consolidation whose serials all lie inside one slice that `sliceAt` reports removes no slice and only leaves a record; an implementation can refuse it. An implementation in which only listed accounts can consolidate is not affected.
- **A freeze might take several transactions.** A freeze of any serial a unit has had propagates to the serial it has now, so consolidating ahead of a freeze does not make the freeze miss. But when a freeze passes through too many records, it does not fit in one transaction. The authorized party can split the slice into several calls; when a unit has been consolidated many times, it can also freeze the serial the unit has now, and such a freeze passes only through the records created after that serial was looked up. The serial a unit has now can be found by calling `consolidatedSpanAt` step by step, or computed from the `SliceConsolidated` events. Between these calls, units that are not yet frozen can still be transferred away; a transfer does not change serials, so the later calls still freeze them. The authorized party should first estimate the cost of a freeze with a read-only call.
- **Cost and limit of a consolidation.** A consolidation pays the storage cost of the record it leaves, and the number of slices one consolidation can handle is limited by the gas available to a transaction. An account with very many slices has to consolidate over several transactions, each of which yields one new slice.
- **Consolidating on behalf of another account.** After serials change, calls that name units by their old serials fail, for example a `transferSlices` or `burnSlices` that has been signed and is not yet included. An implementation that provides a function for consolidating on behalf of another account therefore must restrict who can call it, or open it only for accounts that hold more than a certain number of slices; otherwise anyone can make other holders' transfers by serial fail. A party that needs certain units to keep their serials, for example a contract that registers collateral by serial, can freeze these units: frozen units cannot be consolidated.
- **Serials kept off-chain.** After a consolidation, a list of serials kept off-chain is not updated automatically. A party that screens the units it receives by serial (see "Holders can choose which units to send") has to follow the `SliceConsolidated` events, or use `consolidatedSpanAt`, to translate the serials on its list into the serials the units have now; the new serials alone do not show where the units come from.
- **Serial space.** Each consolidation consumes as many new serials as the number of units it consolidates (see "Finite serial space").

### Balance includes units that cannot be transferred

When the freezing extension is implemented, `balanceOf` includes frozen units; when the classification extension is implemented, it also includes units that can only be transferred to some addresses. Contracts that derive reserves, collateral value or withdrawable amounts from `balanceOf` can overestimate what is available and have to use `transferableBalanceOf` instead. Computing `transferableBalanceOf` can require iterating over an account's slices and may be expensive to call on-chain; the same can be true of `frozenBalanceOf`, `freezeReasonsOf` and `classesOf`. The number of slices of an account can be raised by a third party that transfers in small scattered amounts of units (see "Dust attacks"), so the cost of these queries is not entirely under the account's own control.

### Classes do not represent different rights

`balanceOf` and `totalSupply` add up the units of all classes, and integrators that know only ERC-20 will price, collateralize and exchange them as one and the same asset. Classes should therefore only be used to distinguish where units can go and where they come from. Making assets with different rights, for example several bonds with different maturity dates or yields, into several classes of one token does not violate the interface, but integrators will treat them at the same price, and holders of the worse class can profit from that. Such assets should each use a contract of their own.

Even when all classes carry the same rights, units that are subject to a flow rule are of less use to their holder than units of the default class, and the same is true of frozen units (see "Balance includes units that cannot be transferred" and "Destination-dependent flow rules and contracts").

### Destination-dependent flow rules and contracts

Under a flow rule that restricts destinations by payee address (see "Examples of classes"), whether a unit can be transferred out depends on the destination. A liquidity pool, a vault or any other contract that needs to pay arbitrary addresses, if it takes in such units, can end up holding balance it cannot pay out, and withdrawals can fail as a result.

An issuer has two ways to avoid this. One is to list only terminal accounts as permitted recipients, that is, accounts that do not need to transfer units onward to arbitrary addresses after receiving them. The other is to have units change to the default class when they arrive at a permitted recipient (see "Permitted recipients" in "Examples of classes"). A permitted recipient then receives unrestricted units that it can pay on to anyone, and so does not have to be a terminal account; the practice described in "Fragmentation and gas", of transferring small scattered amounts of restricted units to a permitted recipient to raise the cost of its transfers, no longer works either; the scattered units themselves are still dust (see "Dust attacks"). The price is that once units have changed to the default class, the issuer can no longer constrain where they go. When units still belong to their original class once they are in a permitted recipient's hands, the issuer should use the first way.

### Powers of the authorized party

A party that can freeze units holds substantial power over holders, and a party that can destroy or forcibly transfer units holds even more. A compromise of their keys allows arbitrary units to be frozen and then destroyed or transferred away. Deployments are advised to place these functions behind multi-party control, to separate the right to freeze from the right of disposal, and to leave a delay between freezing and disposal so that mistaken freezes can be contested. Every change of frozen state is visible in the `SliceFrozen` and `SliceUnfrozen` events, and every forced operation is visible in the `SliceForciblyTransferred` events.

A party that can set classes or change flow rules holds a power close to that of freezing: changing units to a class that does not allow transfer to anyone, or emptying a class's list of permitted recipients, has the same effect as a freeze. Unlike a freeze, a change to a flow rule emits no event (see clause 4 of "Flow rules"), and the name and `uri` of a reason or a class can also change without an event, so holders can discover these changes only by querying. Deployments should put these powers under the same controls as the right to freeze.

The declaration of an interface does not say which powers a token actually has. On a token that declares the freezing extension, the destruction and forced transfer functions might revert for every caller, or might be usable at any time. A token that does not declare the freezing extension can still freeze, destroy or transfer units with functions outside this proposal, and an upgradeable contract can also add them later. "Freeze first, then dispose" is only a recommendation in this proposal. A token that declares the freezing extension might also destroy or transfer away units without freezing them; unless the token's own documentation and code guarantee it, holders and integrators cannot assume that a visible freeze comes before disposal. Integrators must read the token's own code.

### External calls and event attribution

Indexers attribute `SliceTransferred` and `SliceForciblyTransferred` events by the order of events (see "Events" and clause 7 of "Forced transfer and destruction"). An implementation that calls an external contract between the events of one operation, for example notifying the recipient after emitting `SliceTransferred` and before emitting the corresponding `Transfer`, or making a callback between `Transfer` and `SliceForciblyTransferred`, gives the called contract the opportunity to reenter and complete another transfer. Once the events of that other transfer are interleaved, events are attributed wrongly, and the contract also violates the ordering requirements stated in those two places. Implementations should complete their state updates and emit all events of the operation before calling any external contract, or prevent reentrancy. Functions that notify the recipient on transfer, such as those defined by ERC-1363, should call the recipient only after all of these events have been emitted. The queries and the call to the recipient under "Acceptance check" are not such a case: they are read-only, and the called contract can neither emit events nor complete another transfer, so they can take place before the events are emitted; for their timing relative to the changes of holder, see clause 6 of "Acceptance check".

### Reduced fungibility and privacy

Units are distinguishable by design. The complete history of every unit is public, and markets can price units differently according to that history, for instance by avoiding units that passed through a particular address. Issuers and users have to accept this as an inherent property of the token.

### Finite serial space

Serials are never reused, so the total number of units ever issued, including those later destroyed, is limited by the integer width the implementation uses for serials. Tokens with frequent mint-and-burn cycles consume this space continuously and have to size it, or choose their number of decimals, accordingly. Consolidated serials are likewise never used again: each consolidation consumes as many new serials as the number of units it consolidates, and an account that repeatedly consolidates a large holding can consume serials far faster than issuance does. A token that opens consolidation has to size the width for its use of consolidation, and can limit that use with conditions such as a minimum number of slices per consolidation.

## Copyright

Copyright and related rights waived via [CC0](../LICENSE.md).

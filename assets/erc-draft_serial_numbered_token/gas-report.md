# Gas measurements: transfers, freezing, consolidation

> This file accompanies the draft ERC "Serial-Numbered Fungible Tokens". It reports gas measurements of the reference implementation in this directory, compared with a plain ERC-20 and a gas-optimized variant.

The figures compare three tokens:

- **Plain ERC-20**: a minimal ERC-20 with a balance mapping and an event and nothing else, as the baseline.
- **Reference implementation**: the one in this directory, that is, the reference implementation in the draft's assets. Each slice of a holding takes one storage slot and serials are 128-bit, so it works with any number of decimals, 18 included. The parts of freezing, classification and consolidation that transfers do not use are in linked libraries, so that every combination of modules on the slice stack is within the contract size limit of 24,576 bytes.
- **Gas-optimized variant**: the same contracts with a compact storage layout for tokens with few decimals (described below). It will be published separately and is not in the draft's assets.

Each figure is the gas paid for one transaction, after refunds, including the 21,000 base cost and calldata. Where a transaction comes near the per-transaction limit of 16,777,216 (EIP-7825), the gas needed before refunds is given in brackets, since that is what has to fit.

Setup: solc 0.8.36, optimizer on with 200 runs (the package's settings). Foundry runs with `--isolate`, so every call is a separate transaction with cold storage. Unless a row says otherwise, both serial tokens have the freezing and classification extensions on the slice-stack backend ("full token" below).

## The two storage layouts

In the reference implementation each slice is one storage slot: a 128-bit start and a 128-bit length.

In the gas-optimized variant two slices share a storage slot, each slice being a 72-bit start and a 56-bit length. The slice that a transfer takes first is kept in the account's own slot, together with the balance and the slice counts. Serials and balances stay below 2^72, so the total ever issued is capped at 2^72 − 1 smallest units: about 4.7 × 10^15 tokens at 6 decimals, about 4.7 × 10^13 at 8, but only about 4,722 at 18. A slice longer than 2^56 − 1 units is stored as several adjacent slices.

Runtime code size in bytes:

| Token | Reference implementation | Gas-optimized variant |
|---|---:|---:|
| Core only | 12,453 | 13,996 |
| Full token | 21,503 | 33,482 |
| Full token with consolidation | 24,103 | 41,352 |

The reference implementation links four libraries, each deployed once and shared by every token that uses it: the freeze operations (11,282 bytes), the class operations (5,609), the consolidation records (6,941) and a batch removal used by consolidation on the slice stack (1,658). The gas-optimized variant keeps all its code in the token, so every combination with the freezing extension exceeds the current limit. It fits the limit of 65,536 bytes that EIP-7954 introduces, which is not active on mainnet yet.

## Transfers

| Transfer | Plain ERC-20 | Reference implementation | Gas-optimized variant |
|---|---:|---:|---:|
| 10 units to an address with no holdings (sender holds one slice) | 51,195 | 89,789 | 62,204 |
| 10 more units to the same address (joins the recipient's last slice) | 34,095 | 55,841 | 44,287 |
| 10 units to an address holding 1 (or 3) separate slices | | 75,378 | 69,356 |
| 10 units to an address holding 2 separate slices | | 75,378 | 52,253 |
| `transferFrom` with a finite allowance, to an address with no holdings | | 97,044 | 69,422 |

A token with only the core pays about 2,500 less on each row in both versions, and about 3,800 less for `transferFrom`.

In the gas-optimized variant, a received slice that does not join an existing one costs alternately more and less: every second such slice needs a new storage slot, which costs about 17,000 more. In the reference implementation every such slice needs a new slot.

A transfer that pays out many slices costs more for each slice it moves:

| Slices moved in one transfer | Reference implementation | Gas-optimized variant |
|---|---:|---:|
| 1 | 65,753 | 65,746 |
| 10 | 331,073 | 210,134 |
| 100 | 2,957,546 (3,442,346) | 1,738,157 (1,982,957) |
| 500 | does not fit: 14,601,742 (17,006,542) | 8,500,353 (9,705,153) |
| Most slices in one transaction | 492 | 857 |

Each further slice adds about 29,200 gas paid in the reference implementation (34,000 before refunds) and about 16,900 in the gas-optimized variant (19,300 before refunds). The last row is measured on an account holding 1,000 separate one-unit slices.

The sorted-array backend costs about the same for single transfers: 90,070 for the first row in the reference implementation and 62,795 in the gas-optimized variant. It costs more per slice moved, about 4% more in the reference implementation and 10% more in the gas-optimized variant, and fits 478 and 783 slices in one transfer.

Transfers do not read the consolidation records. In a separate benchmark, a transfer costs the same whether consolidation is open or closed, and with 0 or 100,200 records stored.

The opening post's figure of 465 slices per transaction is the reference implementation with the optimizer off. With the optimizer off, the gas-optimized variant fits 827.

## Freezing

A freeze names serials, so its cost does not depend on how many holders the units have reached:

| Freeze | Reference implementation | Gas-optimized variant |
|---|---:|---:|
| 1,000 units held by one holder (first freeze on the token) | 265,675 | 260,290 |
| the same 1,000 units after they were spread over 10 holders | 265,699 | 260,314 |
| the same 1,000 units after they were spread over 100 holders | 265,699 | 260,314 |

For comparison, we wrote a minimal model of an amount-based freeze per address, in the style of ERC-3643; it is lighter than real implementations. It paid 48,173 for one holder, 291,349 for 10 holders and 2,711,449 for 100. It also needs the holders and their amounts to be traced off-chain first.

In the reference implementation every freeze, unfreeze, class setting, forced operation and consolidation calls a linked library. Compared with the same code compiled into the token, this adds about 5,400 to a freeze and about 3,300 to setting a class or destroying frozen units. Compiled into the token, the reference implementation's freeze costs the same 260,290 as the gas-optimized variant's, so the difference between the columns of the two freeze tables comes from the library call, not from the layout. Transfers make no library calls and cost the same as before the split, within 100 gas.

Freezing gets more expensive as separately frozen ranges accumulate on the token, because the implementation rebuilds the freeze step function in memory on every freeze. Setting a class behaves the same way.

| Separately frozen ranges already on the token | Reference implementation | Gas-optimized variant |
|---|---:|---:|
| 0 | 265,675 | 260,290 |
| 16 | 340,954 | 335,632 |
| 128 | 1,820,706 | 1,815,321 |
| 256 | 3,562,298 | 3,556,840 |

Destroying frozen units:

| Destroy | Reference implementation | Gas-optimized variant |
|---|---:|---:|
| with a position hint (`destroySliceAt`), holder has one slice | 52,086 | 49,627 |
| with a position hint, oldest of 10, 100 or 500 slices | 62,271 | 61,691 |
| without a hint (`destroySlice`), 10 slices | 86,024 | 75,417 |
| without a hint, 100 slices | 336,494 | 236,067 |
| without a hint, 500 slices | 1,449,694 | 950,067 |

Without a hint, the slice stack scans the pile. Forced transfers and unfreezing have no benchmark of their own yet.

**Effect on the holder's later transfers.** Slices that are frozen after the holder received them stay where they are until a transfer meets them, and each transfer moves at most 32 of them aside:

| Slices frozen after receipt | Reference implementation | Gas-optimized variant |
|---|---:|---:|
| 100: next transfer of 10 units | 1,339,917 (1,493,517) | 876,828 (953,628) |
| 500: next transfer of 10 units | 3,073,117 (3,226,717) | 2,276,428 (2,353,228) |
| `tidySlices`, 32 slices per call | 1,010,985 (1,164,585) | 653,766 (730,566) |

With 100 such slices the fifth transfer is back to the normal cost (61,912 in the reference implementation, 48,629 in the gas-optimized variant), with 500 the 17th. Instead of waiting for transfers, anyone can call `tidySlices`.

**Freezing through consolidation.** A freeze on serials that were consolidated follows them to the new serials:

| | Reference implementation | Gas-optimized variant |
|---|---:|---:|
| contiguous new serials: per record passed | 6,300 to 8,800 | 6,300 to 8,800 |
| 300 records, old serials close together | 1,901,819 | 1,895,094 |
| 300 records, old serials far apart | 2,635,818 | 2,629,087 |
| most records one freeze passes through | 2,183 | 2,181 |
| scattered successors: per record passed | 88,000 to 96,000 | 87,000 to 94,000 |
| scattered successors: 100 records | 8,862,729 to 9,608,345 | 8,783,163 to 9,529,187 |
| scattered successors: most records | 176 | 178 |

## Consolidation

The full token plus the consolidation module, consolidating k separate one-unit slices of one holder:

| Old serials | Per slice (k ≥ 50), reference | Most per transaction, reference | Per slice (k ≥ 50), optimized | Most per transaction, optimized |
|---|---:|---:|---:|---:|
| close together (one unit apart) | about 33,800 | 434 | about 34,100 | 459 |
| far apart (2^32 units apart) | about 57,000 | 271 | about 57,000 | 281 |
| close together, the units between them frozen | about 45,000 | 333 | about 45,900 | 347 |
| close together, all in an allowlist class | about 47,800 | 318 | about 47,700 | 334 |

Small consolidations cost more per slice because of fixed costs. Consolidating 2 slices costs 165,100 close together and 297,657 far apart in the reference implementation, and 148,758 and 281,336 in the gas-optimized variant.

The cost stays flat as records accumulate. With 100,000 records already stored, 100 far-apart slices cost about 58,200 per slice in the reference implementation when those records lie elsewhere, and 65,100 when they lie between the slices; with no records stored they cost 57,500. The gas-optimized variant's figures are 58,400, 65,300 and 57,700.

Consolidation does not save gas by itself. Paying out 400 close-together slices directly costs 11,752,428 in the reference implementation and 6,873,021 in the gas-optimized variant. Consolidating them first costs 13,546,339 and 13,647,901, and the payment then costs 80,176 and 58,606. It pays off only through later transfers and freezes that would otherwise have to move or pass through those slices one by one.

## Reproducing

The benchmark code is not in this directory yet. It is kept in the repository in which the draft and the implementation are developed, which is not public; it will be published together with the gas-optimized variant, so that both columns can be reproduced. The reference implementation's column was measured on the code in this directory, with the benchmark files added.

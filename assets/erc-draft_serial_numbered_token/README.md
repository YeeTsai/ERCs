# Reference implementation of "Serial-Numbered Fungible Tokens"

This directory holds the reference implementation of the draft ERC "Serial-Numbered Fungible Tokens" as a self-contained Foundry package, next to the other assets of the draft. It has no dependency other than `forge-std`, which only the tests use.

The implementation is written to check that the specification can be implemented and to be read alongside it. It is not audited and not optimized, and most combinations of its modules are too large to deploy as one contract (see "Code size").

The draft has no number yet, so every name uses the placeholder prefix `ERCXXXX` (`IERCXXXX`, `ERCXXXXFreezable`, `acceptsERCXXXXTransfer`, ...). The two identifiers that depend on these names, `0x4689efd4` and `0x29543499`, change when the number is assigned.

What the implementation does and where it falls short of the draft's recommendations is described in [reference-implementation.md](./reference-implementation.md). The sequences that `test/conformance/DraftSequences.t.sol` follows are in [test-cases.md](./test-cases.md).

## Layout

| Path | Content |
|---|---|
| `contracts/spec/` | The four interfaces of the draft: `IERCXXXX` (core), `IERCXXXXFreezable`, `IERCXXXXClassified`, and `IERCXXXXAcceptance`, which a receiving contract implements. From `interface` on, each file is identical to the code block in the draft. |
| `contracts/ERCXXXX.sol` | The core: ERC-20 and the core interface, holdings divided into piles, selection by amount. Consolidation is closed by default. Abstract. |
| `contracts/extensions/` | One abstract contract per module: `ERCXXXXFreezable` (freezing extension, with the forced operations that take a position hint), `ERCXXXXClassified` (classification extension), `ERCXXXXAllowlist` (the example class that restricts destinations by payee address), `ERCXXXXAcceptance` (acceptance check), `ERCXXXXConsolidation` (opens consolidation), `ERCXXXXBurnable` (`burn`, `burnFrom`, `burnSlices`), `ERCXXXXTidy` (`tidySlices`). |
| `contracts/holdings/` | The storage of holdings: the abstract layer `SerialHoldings`, and its two implementations, the slice stack `SerialHoldingsStack` and the sorted array `SerialHoldingsSorted`. |
| `contracts/utils/` | The ERC-20 and ERC-165 interfaces and the ERC-6093 errors; the step function library `SerialSteps`; `SerialBounds`; the consolidation record library `SerialConsolidations`. |
| `contracts/examples/` | `ERCXXXXExampleToken`: one concrete token with every module except burning, on the slice stack, with a single admin. It is there to show how the modules are combined; it exceeds the code size limit. |
| `test/presets/` | The concrete tokens the tests run against: combinations of the modules on both storage backends, with a single test admin (`Presets.sol`), and the list of targets (`Targets.sol`). |
| `test/conformance/` | Run against every combination: the sequences of the draft's test cases (`DraftSequences`), the errors and description queries of this implementation (`Errors`), and random walks and invariant tests against a shadow model that is rebuilt from events only (`Invariant`). |
| `test/extensions/` | Tests of the acceptance check, consolidation, the forced operations that take a position hint and `tidySlices`, the second selection rule, and the bounds kept for restrictions. |
| `test/holdings/`, `test/utils/` | Fuzz tests of the two storage backends against a bitmap model, and of the consolidation record library against an oracle. |
| `test/mocks/` | Receiving contracts for the acceptance check tests. |
| `test/examples/` | A short test of the example token. |
| `test/InterfaceIds.t.sol` | Asserts the ERC-165 identifiers written in the draft against the values the compiler computes. |

## Running the tests

Install `forge-std` into `lib/` from this directory. `--no-git` keeps it from being registered as a submodule of the surrounding repository:

```bash
forge install foundry-rs/forge-std --no-git
```

Then:

```bash
forge test
```

Expected result: 887 tests passed, 0 failed, 155 skipped, 1,042 in total, in 91 test suites.

A skipped test is one that does not apply to the combination it runs against, for example a freezing test on a token without the freezing extension. The invariant tests take most of the time; the whole run takes one to two minutes.

These results were obtained with forge 1.8.0 and forge-std 1.17.0, with the settings of `foundry.toml`: solc 0.8.36, optimizer on, 200 runs.

## Snapshot

The code is a snapshot of commit `cd940c97cd800e07bfd2f507932b0a67f248dd7e` of the repository in which the draft and this implementation are developed. Against that commit, the snapshot has the name prefix replaced by `ERCXXXX`, comments translated to English, gas benchmarks and experimental variants left out, and the example token added.

## Code size

EIP-170 limits the runtime code of a contract to 24,576 bytes. Most combinations of the modules exceed it.

The table gives the runtime size in bytes of the test presets in `test/presets/Presets.sol` and of the example token, as reported by `forge build --sizes` with solc 0.8.36, optimizer on, 200 runs, without `via_ir`. Every preset also contains the burn module and the admin functions of the tests, and every preset with the freezing or the classification extension contains `tidySlices`.

| Combination | Contract measured (stack / sorted array) | Slice stack | Sorted array | Fits |
|---|---|---:|---:|---|
| Core | `PresetCoreStack` / `PresetCoreSorted` | 12,454 | 14,760 | yes |
| Core, acceptance check | `PresetAcceptStack` / `PresetAcceptSorted` | 13,172 | 15,478 | yes |
| Core, consolidation | `PresetCoreConsolStack` / `PresetCoreConsolSorted` | 17,634 | 20,592 | yes |
| Classes | `PresetClassStack` / `PresetClassSorted` | 20,491 | 22,798 | yes |
| Classes, consolidation | `PresetClassConsolStack` / `PresetClassConsolSorted` | 25,840 | 28,799 | no |
| Freezing | `PresetFreezeStack` / `PresetFreezeSorted` | 27,040 | 29,338 | no |
| Freezing, consolidation | `PresetFreezeConsolStack` / `PresetFreezeConsolSorted` | 34,725 | 37,684 | no |
| Freezing, classes | `PresetBothStack` / `PresetBothSorted` | 31,896 | 34,194 | no |
| Freezing, classes, acceptance check | `PresetAllStack` / `PresetAllSorted` | 32,665 | 34,963 | no |
| Freezing, classes, consolidation | `PresetBothConsolStack` / `PresetBothConsolSorted` | 39,717 | 42,676 | no |
| Freezing, classes, acceptance check, consolidation, no burning | `ERCXXXXExampleToken` | 39,333 | | no |

So, as single contracts, only the core, the core with the acceptance check, the core with consolidation, and the classification extension without consolidation can be deployed where EIP-170 applies. Every combination that includes the freezing extension is over the limit, the freezing extension alone by about 2,500 bytes on the slice stack.

Nothing in this package reduces the size: no module is split into separately deployed contracts or libraries, and no compiler setting was tuned for size. The tests are not affected, because the test EVM of forge does not enforce the limit by default. `forge build --sizes` exits with an error for the same reason the table has rows marked "no".

## Copyright

Copyright and related rights waived via [CC0](../../LICENSE.md).

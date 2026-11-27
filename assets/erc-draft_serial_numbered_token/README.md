# Reference implementation of "Serial-Numbered Fungible Tokens"

This directory holds the reference implementation of the draft ERC "Serial-Numbered Fungible Tokens" as a self-contained Foundry package, next to the other assets of the draft. It has no dependency other than `forge-std`, which only the tests use.

The implementation is written to check that the specification can be implemented and to be read alongside it. It is not audited and not optimized. The parts of the freezing extension, the classification extension and consolidation that transfers do not use are in four libraries, which are deployed separately and linked into a token, so that every combination of modules on the slice stack is within the contract code size limit (see "Code size").

The draft has no number yet, so every name uses the placeholder prefix `ERCXXXX` (`IERCXXXX`, `ERCXXXXFreezable`, `acceptsERCXXXXTransfer`, ...). The two identifiers that depend on these names, `0x4689efd4` and `0x29543499`, change when the number is assigned.

What the implementation does and where it falls short of the draft's recommendations is described in [reference-implementation.md](./reference-implementation.md). The sequences that `test/conformance/DraftSequences.t.sol` follows are in [test-cases.md](./test-cases.md).

## Layout

| Path | Content |
|---|---|
| `contracts/spec/` | The four interfaces of the draft: `IERCXXXX` (core), `IERCXXXXFreezable`, `IERCXXXXClassified`, and `IERCXXXXAcceptance`, which a receiving contract implements. From `interface` on, each file is identical to the code block in the draft. |
| `contracts/ERCXXXX.sol` | The core: ERC-20 and the core interface, holdings divided into piles, selection by amount. Consolidation is closed by default. Abstract. |
| `contracts/extensions/` | One abstract contract per module: `ERCXXXXFreezable` (freezing extension, with the forced operations that take a position hint), `ERCXXXXClassified` (classification extension), `ERCXXXXAllowlist` (the example class that restricts destinations by payee address), `ERCXXXXAcceptance` (acceptance check), `ERCXXXXConsolidation` (opens consolidation), `ERCXXXXBurnable` (`burn`, `burnFrom`, `burnSlices`), `ERCXXXXTidy` (`tidySlices`). The files of the freezing and the classification extensions also hold their libraries, `SerialFreezeOps` and `SerialClassOps`. |
| `contracts/holdings/` | The storage of holdings: the abstract layer `SerialHoldings`, and its two implementations, the slice stack `SerialHoldingsStack` (with the library `SerialStackBatch`, which consolidation uses) and the sorted array `SerialHoldingsSorted`. |
| `contracts/utils/` | The ERC-20 and ERC-165 interfaces and the ERC-6093 errors; the step function library `SerialSteps`; `SerialBounds`; the consolidation record library `SerialConsolidations`. `SerialSteps` and `SerialBounds` are compiled into the token; `SerialConsolidations` is deployed separately. |
| `contracts/examples/` | `ERCXXXXExampleToken`: one concrete token with every module except burning, on the slice stack, with a single admin. It is there to show how the modules are combined; with its libraries linked, it is within the code size limit. |
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

A skipped test is one that does not apply to the combination it runs against, for example a freezing test on a token without the freezing extension. The invariant tests take most of the time; the whole run takes one to two minutes. forge deploys and links the libraries by itself.

These results were obtained with forge 1.8.0 and forge-std 1.17.0, with the settings of `foundry.toml`: solc 0.8.36, optimizer on, 200 runs.

## Snapshot

The code is a snapshot of commit `fff05db08ea3e444e64659142775aa6f6bea84d3` of the repository in which the draft and this implementation are developed. Against that commit, the snapshot has the name prefix replaced by `ERCXXXX`, comments translated to English, gas benchmarks and experimental variants left out, the example token added, and a few local variables renamed for the spelling check of the ERCs repository.

## Code size

EIP-170 limits the runtime code of a contract to 24,576 bytes. To stay within it, the parts of the freezing extension, the classification extension and consolidation that transfers do not use are in four libraries with external functions:

| Library | File | Content | Runtime size |
|---|---|---|---:|
| `SerialFreezeOps` | `contracts/extensions/ERCXXXXFreezable.sol` | Freezing and unfreezing (rebuilding the step function, emitting the events), reason descriptions, the counting behind `freezeReasonsOf`, `frozenSpanAt` and `frozenBalanceOf`, the check that the units of a forced operation are frozen | 11,282 |
| `SerialClassOps` | `contracts/extensions/ERCXXXXClassified.sol` | Setting classes and issuing with a class, carrying classes over after a consolidation, class descriptions, the counting behind `classesOf` | 5,609 |
| `SerialConsolidations` | `contracts/utils/SerialConsolidations.sol` | Checking the arguments of a consolidation, writing its records and emitting `SliceConsolidated`, `consolidatedSpanAt`, and the lookups that let a freeze follow consolidated serials | 6,941 |
| `SerialStackBatch` | `contracts/holdings/SerialHoldingsStack.sol` | Taking several slices out of the slice stack at once during a consolidation | 1,658 |

Each library is deployed once, and a token that uses it has the library's address linked into its code when it is deployed; tokens on the same chain can share the same deployed libraries. `forge test` deploys and links them by itself. To deploy a token, deploy the libraries first, or use ones already deployed on the chain, and give their addresses to the linker, for example with forge's `--libraries` option.

Transfers make no library calls. Freezing, unfreezing, setting a class, forced operations and consolidation call a library, which costs somewhat more than the same code compiled into the token would.

To save code, `classesOf`, `classInfo`, `freezeReasonsOf`, `freezeReasonInfo` and `frozenSpanAt` are declared `external` and return the data that the library has already ABI-encoded. A contract that inherits them can override them, but cannot call them internally or through `super`.

The table gives the runtime size in bytes of the test presets in `test/presets/Presets.sol` and of the example token, without the libraries, as reported by `forge build --sizes` with solc 0.8.36, optimizer on, 200 runs, without `via_ir`. Every preset also contains the burn module and the admin functions of the tests, and every preset with the freezing or the classification extension contains `tidySlices`.

| Combination | Contract measured (stack / sorted array) | Slice stack | Sorted array | Fits (stack / sorted array) |
|---|---|---:|---:|---|
| Core | `PresetCoreStack` / `PresetCoreSorted` | 12,453 | 14,759 | yes / yes |
| Core, acceptance check | `PresetAcceptStack` / `PresetAcceptSorted` | 13,171 | 15,477 | yes / yes |
| Core, consolidation | `PresetCoreConsolStack` / `PresetCoreConsolSorted` | 14,800 | 17,897 | yes / yes |
| Classes | `PresetClassStack` / `PresetClassSorted` | 16,984 | 19,291 | yes / yes |
| Classes, consolidation | `PresetClassConsolStack` / `PresetClassConsolSorted` | 19,377 | 22,533 | yes / yes |
| Freezing | `PresetFreezeStack` / `PresetFreezeSorted` | 18,495 | 20,802 | yes / yes |
| Freezing, consolidation | `PresetFreezeConsolStack` / `PresetFreezeConsolSorted` | 21,024 | 24,180 | yes / yes |
| Freezing, classes | `PresetBothStack` / `PresetBothSorted` | 21,503 | 23,810 | yes / yes |
| Freezing, classes, acceptance check | `PresetAllStack` / `PresetAllSorted` | 22,272 | 24,579 | yes / no |
| Freezing, classes, consolidation | `PresetBothConsolStack` / `PresetBothConsolSorted` | 24,103 | 27,259 | yes / no |
| Freezing, classes, acceptance check, consolidation, no burning | `ERCXXXXExampleToken` | 23,699 | | yes |

So every combination on the slice stack can be deployed where EIP-170 applies, together with its libraries. On the sorted array, which is there to compare data structures, the freezing and classification extensions together with the acceptance check or with consolidation are over the limit. The margins are small: `PresetBothConsolTunedStack`, the same combination as `PresetBothConsolStack` with the deployment parameters of consolidation overridden, is 24,522 bytes, 54 below the limit, and another compiler version or setting can take a combination over it.

EIP-7954 raises the limit to 65,536 bytes. It is scheduled for the Glamsterdam upgrade, which was not active on mainnet when this was written (November 2026). Every contract in the tables is below that limit.

No compiler setting was tuned for size. The tests are not affected by the limit, because the test EVM of forge does not enforce it by default. `forge build --sizes` exits with an error because of the two rows over the limit on the sorted array.

## License

The code in `contracts/` and `test/` is licensed under the MIT License, as the header of each file states; the text of the license and the copyright notice are in [LICENSE.md](./LICENSE.md). The four interface files in `contracts/spec/` are the exception: they are identical to the code blocks of the draft, and for them, as for the draft and the documents in this directory, copyright and related rights are waived via [CC0](../../LICENSE.md).

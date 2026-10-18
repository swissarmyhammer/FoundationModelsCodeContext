---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m57qaxkwf48x19hhnmbtw7fe
  text: |-
    Research:
    - `Walker.TreeWalk.visitChild` reads `URL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])`. On an error it calls `skip`, which adds the path to `unexaminedPaths`.
    - `URLResourceValues.isDirectory` has no setter, thus the seam cannot return `URLResourceValues`. Plan: add `Walker.EntryType` (isDirectory, isSymbolicLink), `Walker.EntryTypeReader` (an internal `@Sendable (URL) throws -> EntryType`) and `Walker.entryType(at:)` (the default, which reads `URL.resourceValues`).
    - `walkTree` and `walk` get a `readEntryType` parameter with the default. Callers that do not give it (`PathFilter.load`, `walkEntries`, `enumerateFiles`, `CodeContext`) do not change.
    - `Reconciler.reconcile(store:rootDirectory:)` is public. To keep the seam internal, the public function calls a new internal overload `reconcile(store:rootDirectory:readEntryType:)`, which has no default (a default would make the two calls ambiguous).
    - Prior art for a function-value seam: `ServerSpecsForProjects` in ProjectDetection.swift.
  timestamp: 2026-10-18T14:41:00.540846+00:00
- actor: claude-code
  id: 01m57qe8y3k0s3a35vt2a94ta2
  text: |-
    TDD:
    - RED: `swift test --filter 'WalkerTests/walkSkipsAFileWhoseTypeItCannotRead'` failed to build: "'EntryTypeReader' is not a member type of enum 'Walker'" and "extra argument 'readEntryType' in call". This is the expected failure: the seam did not exist.
    - GREEN: added `Walker.EntryType`, `Walker.EntryTypeReader`, `Walker.entryType(at:)`, the `readEntryType` parameter on `walkTree` and `walk`, the stored reader in `TreeWalk`, and the internal `Reconciler.reconcile(store:rootDirectory:readEntryType:)`. `swift test --filter 'WhoseType'`: 2 tests in 2 suites passed.
    - The "missing creator for mutated node" build warning is not from this change. Task ^w00hcn tracks it.
  timestamp: 2026-10-18T14:42:50.435683+00:00
- actor: claude-code
  id: 01m57qsm9pswmye9nj6wjkx0r3
  text: |-
    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsCodeContext/Index/Walker.swift, Sources/FoundationModelsCodeContext/Index/Reconciler.swift, Tests/FoundationModelsCodeContextTests/ReconcilerTests.swift. `swift test` (full unit suite, one run): 1014 tests in 90 suites passed, 0 failures. After that run, the rule "A function belongs to a type" (swift/immutability) moved the test helper into `private enum EntryTypeReaders`. `swift test --filter 'WhoseType'` then ran one time: 2 tests in 2 suites passed. The only build warning is "missing creator for mutated node" for the mlx-swift_Cmlx bundle. This change did not cause it, and ^w00hcn tracks it.
    - Seam: `Walker.EntryTypeReader` (internal, `@Sendable (URL) throws -> EntryType`), default `Walker.entryType(at:)`. The signature of the public `Reconciler.reconcile(store:rootDirectory:)` does not change. It calls the new internal overload with the default reader.
    - Acceptance criteria box checked: walker test and reconcile test now exist for each cause (an unlistable directory, an unreadable entry type, an unreadable file for the hash).
    - next: /review
  timestamp: 2026-10-18T14:49:02.518997+00:00
- actor: claude-code
  id: 01m57qw0j8gxpdv9m4j93g7t6s
  text: |-
    ### test — green
    - evidence: swift test (root package) — 1014 tests in 90 suites passed, 0 failed, 0 skipped. Only warning in output is the SwiftPM "missing creator for mutated node ... mlx-swift_Cmlx.bundle" warning from a dependency (task ^kw00hcn). The IntegrationTests package was not run.
    - next: review
  timestamp: 2026-10-18T14:50:20.616113+00:00
position_column: doing
position_ordinal: '80'
title: 'Walker: test the entry whose type the walk cannot read'
---
## Problem
`Walker.TreeWalk.visitChild` records an entry as unexamined when `URL.resourceValues(forKeys:)` fails. The reconcile then keeps the rows at or below that path. No test runs this path.

The tests of ^2rny171 cover the two other unexamined-path causes: a directory that the walk cannot list (mode 0o000), and a file that the walk cannot read for the hash (mode 0o000).

A test cannot make the type read fail with permissions:
- A directory with mode 0o444 (read, no search) does not reach this path. `FileManager.contentsOfDirectory` fails on it, so the walk records the directory as unlistable (measured: `unexaminedPaths == ["blocked"]`).
- The children of a subdirectory come from `contentsOfDirectory(at:includingPropertiesForKeys:)`, which can prefetch the resource values. Thus the type read of these children can succeed from the cache.
- For a child of the root, the type read fails only when the entry is removed between the list and the read. This is a race, and a unit test must not depend on a race.

## Change
- Add a seam in `Walker` for the read of the entry type (for example, a function value that `walkTree` takes, with the `URL.resourceValues` read as the default). Keep the seam internal.
- Add a walker test: the seam fails for one file. Assert that the walk returns the other files and that `unexaminedPaths` holds the path of that file.
- Add a reconcile test in the style of `reconcileKeepsTheRowsUnderAnUnreadableDirectory`: index the file, make the type read fail, reconcile, and assert `stats.removed == 0`, `stats.skipped == 1`, and that the row of the file is still in `indexed_files`.

## Tests
- The walker test and the reconcile test above.

## Acceptance criteria
- [x] Each unexamined-path cause in `Walker` has a walker test and a reconcile test. #lsp-fix
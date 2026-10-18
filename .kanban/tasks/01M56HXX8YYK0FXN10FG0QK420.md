---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m57nvd9js93yrcbgb2tf6tjc
  text: |-
    Research:
    - Three tests write `../secret.swift` from a root that `withTemporaryWorkspace` makes. The parent of that root is `TemporaryItem.root`, thus the file stays in `TemporaryItem.root` after each run: LSPIndexWorkerTests.drainBatchRejectsAPathTraversalRelativePathWithoutTouchingTheConnection, TreeSitterWorkerTests.runRejectsAPathTraversalRelativePathWithoutReadingTheFile, LayeredOpsTests.definitionRejectsAPathTraversalFilePathWithoutTouchingTheConnectionOrDiskOutsideTheWorkspace.
    - Other `..` paths in the tests (PathFilterTests, LanguageServerDocumentTests) only read. They write no file.
    - Plan: add a static helper on `TemporaryItem` that makes the workspace root one level below a new `withTemporaryWorkspace` directory. Then `..` is that private directory, each test has its own outside directory, and the removal of the directory removes the file. The swift immutability rule says "A function belongs to a type", thus the helper is a static func on the `TemporaryItem` enum.
    - Note: ConnectionTests calls `ScriptedLSPServerScript.path(in: TemporaryItem.root)`. This writes one cached script file per source digest into `TemporaryItem.root` by design (a cache that each run uses again). It is not a `../` write of a test body, and this card does not change it.
  timestamp: 2026-10-18T14:15:03.730291+00:00
- actor: claude-code
  id: 01m57p0renxbejfjjzefcx2q51
  text: |-
    Implementation:
    - Added `TemporaryItem.withNestedWorkspace(_:)` in TestSupport.swift. It uses `withTemporaryWorkspace` again and makes the root at `<private directory>/workspace`. Thus `..` of the root is a directory of that test only, and the removal of the directory also removes `../secret.swift`.
    - The three path-traversal tests (LSPIndexWorkerTests, TreeSitterWorkerTests, LayeredOpsTests) now use `TemporaryItem.withNestedWorkspace`. Their assertions did not change.
    - New tests in TemporaryItemTests: `theParentOfANestedWorkspaceIsAPrivateDirectoryBelowTheSharedDirectory`, `aFileThatATestWritesInTheParentOfANestedWorkspaceIsRemovedAfterTheTest`. RED was a compile failure (the helper did not exist). GREEN was 6/6.
    - I removed the old `/tmp/FoundationModelsCodeContextTests-501/secret.swift` from the earlier runs. After `swift test --filter 'LayeredOpsTests|TreeSitterWorkerTests|LSPIndexWorkerTests|TemporaryItemTests'` (70 tests, 0 failures) and after the full `swift test` (1011 tests in 90 suites, 0 failures), `TemporaryItem.root` holds no `secret.swift` and no workspace directory.

    BLOCKER (open requirement): The card says "Make sure that no test writes into `TemporaryItem.root` directly." One direct write remains. ConnectionTests calls `ScriptedLSPServerScript.path(in: TemporaryItem.root)` in two places, and that call writes `scripted-lsp-server-<sha256>.swift` directly into `TemporaryItem.root`. The cache is deliberate: each run and each parallel test uses the same file again (ScriptedLSPServerScriptTests.twoCallsWithTheSameSourcesGiveTheSamePath). Each change of the script source adds one more file, and no test removes the old files. 7 such files are in `TemporaryItem.root` now. If a test removes the cache file after it runs, that removal races with parallel ConnectionTests that use the same path. If the cache moves to a subdirectory, the stale files stay. A person must decide one of these:
    (a) This requirement covers only the `../secret.swift` writes, and the cache stays as it is.
    (b) Move the cache into a fixed subdirectory, for example `TemporaryItem.root/scripted-lsp-server/`.
    (c) Give each ConnectionTests call its own directory and remove it after the test. Then no cache remains.
    The build also shows one SwiftPM warning that existed before this change: "missing creator for mutated node: ... mlx-swift_Cmlx.bundle/Contents/MacOS". It comes from the mlx dependency bundle, not from source.
  timestamp: 2026-10-18T14:17:58.997133+00:00
- actor: claude-code
  id: 01m57p0xj369jvrda460x3je5w
  text: |-
    ### implement — stuck
    - evidence: 5 files changed: Tests/FoundationModelsCodeContextTests/TestSupport.swift, TemporaryItemTests.swift, LSPIndexWorkerTests.swift, TreeSitterWorkerTests.swift, LayeredOpsTests.swift. `swift test --filter 'LayeredOpsTests|TreeSitterWorkerTests|LSPIndexWorkerTests|TemporaryItemTests'` gave 70 tests passed, 0 failed. `swift test` gave 1011 tests in 90 suites passed, 0 failed. After each run, `TemporaryItem.root` holds no `secret.swift`.
    - gap: The requirement "no test writes into TemporaryItem.root directly" is not complete. ConnectionTests still writes the scripted-lsp-server cache file through `ScriptedLSPServerScript.path(in: TemporaryItem.root)`. A person must select option (a), (b) or (c) from the comment above.
    - next: A person decides on the cache. Then implement again, or continue to /review if the decision is (a).
  timestamp: 2026-10-18T14:18:04.227588+00:00
- actor: claude-code
  id: 01m57p1txr1kf5wj14tjppw1qy
  text: 'Decision (from the coordinator): option (b). The card text is the requirement: no test writes directly into `TemporaryItem.root`. Move the scripted-lsp-server cache into one fixed subfolder of `TemporaryItem.root`. One shared constant or helper holds the subfolder. Remove the 7 old `scripted-lsp-server-*.swift` files that are directly in `/tmp/FoundationModelsCodeContextTests-501` after an examination of each one.'
  timestamp: 2026-10-18T14:18:34.296630+00:00
- actor: claude-code
  id: 01m57p54qx1spqefe4qrn1yvh5
  text: |-
    ### implement — changed
    - evidence: Option (b) is done. `TemporaryItem.scriptedLSPServerDirectory` (TestSupport.swift) is the one constant for the subfolder `TemporaryItem.root/scripted-lsp-server/`. ConnectionTests has one helper, `scriptedServerPath()`, and both of its call sites use it. No test calls `ScriptedLSPServerScript.path(in: TemporaryItem.root)` now. New test: TemporaryItemTests.theScriptedServerDirectoryIsASubfolderOfTheSharedDirectoryAndNotTheSharedDirectory (RED: compile failure, no member `scriptedLSPServerDirectory`). I examined the 7 old `scripted-lsp-server-<sha256>.swift` files that were directly in `/tmp/FoundationModelsCodeContextTests-501`. Each one started with the Framing.swift header, and its SHA-256 was the same as the digest in its name, thus each was a generated cache file. I removed all 7. `swift test` (one run) gave 1012 tests in 90 suites passed, 0 failed. After the run, `TemporaryItem.root` holds only `scripted-lsp-server/` with one cache file. It holds no `secret.swift` and no file directly in it. The one build warning, "missing creator for mutated node ... mlx-swift_Cmlx.bundle", existed before this change and comes from the mlx dependency.
    - files: Tests/FoundationModelsCodeContextTests/TestSupport.swift, TemporaryItemTests.swift, ConnectionTests.swift, LSPIndexWorkerTests.swift, TreeSitterWorkerTests.swift, LayeredOpsTests.swift
    - note: The IntegrationTests package writes its script cache into `/tmp` directly (IntegrationSupport.scriptDirectory). That is outside `TemporaryItem.root` and outside the unit target, thus this card does not change it.
    - next: /review
  timestamp: 2026-10-18T14:20:22.653035+00:00
- actor: claude-code
  id: 01m57pa1n25pqstfathr4sp72j
  text: |-
    ### test — green
    - evidence: swift test (root package) — 1012 tests in 90 suites passed, 0 failed, 0 skipped. The only warning is the SwiftPM warning "missing creator for mutated node ... mlx-swift_Cmlx.bundle", from a dependency.
    - change: The first run had one log warning from the repo: "the walk cannot read an ignore rule file and continues without its rules". The test loadThrowsWhenARuleFileCannotBeRead caused it, on purpose, and the default log handler printed it. The test now captures the log with CapturedLogRecords, uses a unique rule file path, checks the exact LoadError, and checks the warning record. The file is Tests/FoundationModelsCodeContextTests/PathFilterTests.swift.
    - next: none. No commit was made.
  timestamp: 2026-10-18T14:23:03.330193+00:00
position_column: doing
position_ordinal: '80'
title: Tests that write ../secret.swift must remove the file
---
## Problem
LayeredOpsTests, TreeSitterWorkerTests and LSPIndexWorkerTests write `../secret.swift` into the parent directory of the workspace, to test a path outside the root. No test removes this file. The tests run in parallel, thus three tests write the same file at the same time.

Before ^w29j74j, the parent was `$TMPDIR` itself, thus each run left a file directly in `$TMPDIR`. Now the parent is `TemporaryItem.root` (`/tmp/FoundationModelsCodeContextTests-<uid>`), and the file stays there after each run.

## Change
- Give each of these tests its own outside directory (for example a second `withTemporaryWorkspace`, or a nested root below the workspace so that `..` stays in the workspace), and remove the file after the test.
- Make sure that no test writes into `TemporaryItem.root` directly.

## Tests
- After a run of the three suites, `TemporaryItem.root` holds no `secret.swift`. #test-hygiene
---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5a44t0d8r749jt9cfcx4t8z
  text: |-
    Research:
    - `TreeSitterWorker.run` today: `readAndChunk` returns nil for every failure (unsafe path, no module, read error, not UTF-8) and the caller only calls `store.markIndexed(.treeSitter)`; the stale chunks/symbols/edges of a deleted file stay until the watcher or the next reconcile deletes the row.
    - Watcher `.removed` and Reconciler both call `Store.deleteFile(filePath:)`, which deletes the `indexed_files` row; FKs cascade to `ts_chunks` (embeddings live there), `lsp_symbols` and `lsp_call_edges`. `SearchCorpus.snapshot()` evicts files whose chunks are gone. So the missing-file path should call `store.deleteFile` to agree with the two delete paths.
    - `LSPIndexWorker.processFile` has the same pattern: `LanguageServerDocument.readText()` folds missing / not UTF-8 / other errors into one `.warning` "the LSP index worker cannot read a file and marks the file indexed" through `skipFile`. Existing test `drainBatchMarksAnUnreadableFileIndexedWithoutTouchingTheConnection` uses a missing file.
    - `Data(contentsOf:)` throws `CocoaError(.fileReadNoSuchFile)` for ENOENT and `.fileReadNoPermission` for EACCES.
    - Log capture in tests: `CapturedLogRecords` (LoggingContentTests.swift), match by `filePath` metadata with a unique path.
    - Related, out of the card's scope: `Watcher.applyChange` also warns "the watcher cannot read a changed file and skips it in this flush" when a created file is gone before the debounced flush -- same noise source; will file as a separate task.
  timestamp: 2026-10-19T13:03:20.589641+00:00
- actor: claude-code
  id: 01m5a4j3agv8c8vhv89jefnnft
  text: |-
    Implementation landed (TDD: 5 new tests watched RED for the expected reason, then GREEN):
    - New `Sources/FoundationModelsCodeContext/Index/SourceText.swift`: `SourceText.read(at:) throws(SourceText.ReadFailure) -> String` with cases `.missing` (CocoaError `.fileReadNoSuchFile`), `.notUTF8`, `.unreadable(errorType:)` (type name via `Log.errorType(of:)`, never the description).
    - `TreeSitterWorker`: `readAndChunk` now returns a private `ReadOutcome` (`.parsed` / `.missing` / `.skipped`); new `indexFile(relativePath:rootDirectory:store:)` calls `store.deleteFile(filePath:)` for `.missing` (same delete as the watcher `.removed` path and the reconcile, cascades to ts_chunks+embeddings, lsp_symbols, lsp_call_edges). `outcome(of:relativePath:)` logs: missing -> debug "the tree-sitter index worker finds no file at a dirty path and removes the file from the index"; not UTF-8 -> info "the tree-sitter index worker skips a file that is not UTF-8 text and marks the file indexed"; other -> the existing warning "the tree-sitter index worker cannot read the file" plus `error_type`.
    - `LSPIndexWorker`: same split through new `skipUnreadFile(relativePath:failure:store:)`; `skipFile` gained a defaulted `metadata:` parameter (all callers unchanged). LSP missing case stays mark-indexed at debug, matching the existing path-filter case: the filter already rejects a path with no real path, so this branch is only the race between the filter check and the read; the tree-sitter pass / watcher / reconcile remove the row.
    - `LanguageServerDocument`: new `read() throws(SourceText.ReadFailure)`; static `readText` now delegates to `SourceText` (same behavior).
    - Discovery: in the LSP worker a deleted file never reached `readText()` -- `PathFilter.acceptsDocument` needs `realpath(3)`, so a missing file was already logged at debug by the path-filter branch. The LSP warning in practice came from not-UTF-8 and permission errors.
    - Follow-up filed: ^qbvnks9 (watcher warns for a file removed before the debounced flush).
    - Note: `swift test` still prints the build-system line `warning: missing creator for mutated node: ...mlx-swift_Cmlx.bundle/Contents/MacOS` in both packages; it predates this change (no manifest touched), and its task ^... (01M57PR2SXQJ4353TJRKW00HCN) is in done.
  timestamp: 2026-10-19T13:10:36.112146+00:00
- actor: claude-code
  id: 01m5a4j9f2yzqt8fympzgvyd0y
  text: |-
    ### implement — changed
    - evidence: 6 files — Sources/FoundationModelsCodeContext/Index/SourceText.swift (new), Index/TreeSitterWorker.swift, Index/LSPIndexWorker.swift, Index/LanguageServerDocument.swift, Tests/FoundationModelsCodeContextTests/TreeSitterWorkerTests.swift (+3 tests), Tests/FoundationModelsCodeContextTests/LSPIndexWorkerTests.swift (+2 tests). `swift test`: 1020 tests in 90 suites passed; `swift test --package-path IntegrationTests`: 22 tests in 16 suites passed. Only warning printed is the pre-existing SwiftPM line "missing creator for mutated node ... mlx-swift_Cmlx.bundle".
    - next: /review
  timestamp: 2026-10-19T13:10:42.402156+00:00
- actor: claude-code
  id: 01m5a4p95zzr29erj8sda69tzj
  text: |-
    ### test — green
    - evidence: `swift test` — 1020 tests in 90 suites passed, 0 failed, 0 skipped; `swift test --package-path IntegrationTests` — 22 tests in 16 suites passed, 0 failed, 0 skipped. Only warning: pre-existing mlx-swift_Cmlx "missing creator for mutated node" SwiftPM warning (reported, not chased).
    - next: review/commit
  timestamp: 2026-10-19T13:12:53.183980+00:00
- actor: claude-code
  id: 01m5a4pxkw5khr4154xamwrc1h
  text: |-
    ### commit — changed
    - evidence: f2bc7ab fix(index): tell a gone file from a non-UTF-8 file and from a read error ^b91evm0
    - next: review
  timestamp: 2026-10-19T13:13:14.108683+00:00
- actor: claude-code
  id: 01m5a4z2jp7mmck4waqp0tkep4
  text: |-
    ### review — findings
    - evidence: review sha HEAD~2..HEAD — 1 finding (1 confirmed, 2 refuted) — Sources/FoundationModelsCodeContext/Index/LSPIndexWorker.swift:697 `swift/error-handling`
    - next: implement the open `## Review Findings (2026-10-19 08:13)` item, then test, commit, re-review
  timestamp: 2026-10-19T13:17:41.334900+00:00
- actor: claude-code
  id: 01m5a4zdyzbmbjdmhzwvfkng3z
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 6 files (SourceText.swift new, TreeSitterWorker, LSPIndexWorker, LanguageServerDocument, 2 test files, +5 tests)
    - test: green — swift test 1020 passed, IntegrationTests 22 passed, 0 skipped
    - commit: f2bc7ab (+ a4dda79 kanban)
    - review: findings — Sources/FoundationModelsCodeContext/Index/LSPIndexWorker.swift:697 (swift/error-handling missing explicit return)
  timestamp: 2026-10-19T13:17:52.991816+00:00
- actor: claude-code
  id: 01m5a52wqy04nactkrbjn27pxp
  text: |-
    Finding `swift/error-handling` (LSPIndexWorker.swift skipUnreadFile) applied:
    - `skipUnreadFile(relativePath:failure:store:)`: each of the three cases (`.missing`, `.notUTF8`, `.unreadable`) now says `return await skipFile(...)`. Before, the switch was the implicit return (Swift 5.9 switch expression), so it compiled, but the finding asks for the explicit return.
    - The same cause elsewhere in the file: `kindString(for:)` was also an implicit-return switch expression (26 cases `case .file: "file"`). Each case now says `return "..."`, so every value-returning switch in LSPIndexWorker.swift returns explicitly and the same way.
    - TreeSitterWorker.swift: no change needed. `outcome(of:relativePath:)` already returns explicitly in each case (`return .missing` / `return .skipped`), and `indexFile(relativePath:rootDirectory:store:)` returns `Void` (each case is a statement).
    - TDD note: this is a syntax refactor that changes no behavior, so no new test could fail first. The existing tests `drainBatchMarksAnUnreadableFileIndexedWithoutTouchingTheConnection`, `drainBatchKeepsTheWarningWithTheErrorTypeForAFileThatCannotBeRead` and the not-UTF-8 LSP test cover the three branches, and the kindString mapping is covered through the symbol-persistence tests.
    - `swift test --filter "LSPIndexWorkerTests|TreeSitterWorkerTests"`: 30 tests in 2 suites passed. Only warning is the SwiftPM line `missing creator for mutated node ... mlx-swift_Cmlx.bundle`, already recorded on this card.
  timestamp: 2026-10-19T13:19:46.430961+00:00
- actor: claude-code
  id: 01m5a52z0qc8npp8a7605edzz1
  text: |-
    ### implement — changed
    - evidence: 1 file — Sources/FoundationModelsCodeContext/Index/LSPIndexWorker.swift (`skipUnreadFile` 3 cases `return await skipFile(...)`; `kindString(for:)` 26 cases `return "..."`). TreeSitterWorker.swift already explicit, unchanged. `swift test --filter "LSPIndexWorkerTests|TreeSitterWorkerTests"`: 30 passed, 0 failed. Finding flipped to `- [x]`.
    - next: test, commit, /review
  timestamp: 2026-10-19T13:19:48.759958+00:00
- actor: claude-code
  id: 01m5a59vyn8vhesgcqrqj0jv7s
  text: |-
    ### test — green
    - evidence: `swift test` — 1020 tests in 90 suites passed, 0 failures, 0 skipped, no compiler warnings. `swift test --package-path IntegrationTests` — final run 22 tests in 16 suites passed.
    - The first integration run had 1 failure: LanguageServerGrandchildTests.forceRestartKillsTheGrandchildOfTheOldServer() recorded `.handshakeFailed("operation timed out after 30.0 seconds")` while LiveSourceKit and the scale tests ran in parallel. The suite alone passed (3 tests, 0.8 s) and the final full run passed. The code did not change between runs. The cause is not proven. Likely load on the `swift <script>` startup of the scripted server. Not fixed.
    - Only warning: the pre-existing mlx-swift_Cmlx "missing creator for mutated node" SwiftPM warning. Reported, not chased.
    - next: review
  timestamp: 2026-10-19T13:23:34.997146+00:00
- actor: claude-code
  id: 01m5a5dgrk8bak3c7p9xeexb5y
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (09a6c1e) — 0 findings (0 confirmed, 0 refuted; 7 validator runs, 0 failed); 1 file reviewed (LSPIndexWorker.swift), 4 .kanban files excluded by .reviewignore. Prior finding LSPIndexWorker.swift:697 swift/error-handling verified fixed: all three skipUnreadFile cases now `return await skipFile(...)`.
    - next: none — task moved to done
  timestamp: 2026-10-19T13:25:34.611381+00:00
- actor: claude-code
  id: 01m5a5dzsy2a1fmnj1zww5wbn6
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — LSPIndexWorker.swift explicit returns (skipUnreadFile, kindString)
    - test: green — swift test 1020 passed; IntegrationTests 22 passed on final run (1 flake in LanguageServerGrandchildTests on first run → tracked as ^t71wvkm)
    - commit: 09a6c1e
    - review: clean — 0 findings; task in done
  timestamp: 2026-10-19T13:25:50.014198+00:00
position_column: done
position_ordinal: fa80
title: 'Tree-sitter worker: a file deleted between the watch event and the read is not a warning'
---
## What
SWE-bench run of 2026-10-18, 16:00:02: one warning
`the tree-sitter index worker cannot read the file file.path=check_mcf_fix.py`.
The agent most likely deleted a scratch file between the watcher event and the read.

## Where
`Sources/FoundationModelsCodeContext/Index/TreeSitterWorker.swift` `readAndChunk(relativePath:rootDirectory:)` (~line 228): `try? Data(contentsOf:)` folds every failure (gone, permission, not UTF-8) into one warning.

## Approach
- Split the cases:
  - File does not exist (ENOENT / `NSFileReadNoSuchFileError`) → debug level, and make sure the caller removes the file's rows (chunks, symbols, embeddings, call edges) from the store instead of only marking it indexed. Check what the caller does with `nil` today and how the reconcile / watcher handles deletes, so the two paths agree.
  - Not UTF-8 → its own message (info or warning).
  - Other read errors (EACCES, EIO) → keep the warning, add the error type name (no content).
- Check `LSPIndexWorker` for the same pattern.

## TDD
1. Failing test: index a file, mark it dirty, delete it, run the tree-sitter pass; assert no warning record is logged (capture `Log.index`) and the file's rows are gone from the store.
2. Test: a file with invalid UTF-8 → the not-UTF-8 message.
3. Test: an unreadable file (chmod 000) → the warning stays.
4. Implement; run the suite. #index #bug

## Review Findings (2026-10-19 08:13)

> Scope: `review sha HEAD~2..HEAD` — reviewed the diffs only — lines this change added or modified. 6 file(s) reviewed, 6 not reviewed.

> 6 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 6 file(s)

- [x] `Sources/FoundationModelsCodeContext/Index/LSPIndexWorker.swift:697` `swift/error-handling` — Function declares return type `Bool` but this switch case does not return a value. The `await skipFile(...)` call result must be returned. Add `return` before `await skipFile(...)`: `return await skipFile(...)`.

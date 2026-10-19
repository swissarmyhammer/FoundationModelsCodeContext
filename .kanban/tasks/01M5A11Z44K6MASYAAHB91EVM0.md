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
position_column: doing
position_ordinal: '80'
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
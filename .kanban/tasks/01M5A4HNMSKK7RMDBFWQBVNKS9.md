---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5a5g3z2m794fb90nfmk20w2
  text: 'Research: Watcher.applyChange uses `try? Walker.hashFile` and logs one warning for every read failure. Walker.hashFile reads raw bytes (Data(contentsOf:)), so `.notUTF8` can never apply; the walker''s own use (logSkippedEntry with Log.errorDetail) must stay as is. The classification lives in the private `SourceText.failure(of:)` (CocoaError.fileReadNoSuchFile -> .missing). Plan: expose that check from SourceText as one internal predicate that `failure(of:)` also uses (one copy), and in the watcher catch the hashFile error: missing -> debug record + `store.deleteFile` (same write and retry path as `.removed`, via a shared helper); other errors -> keep the warning, with `failureMetadata` (Log.errorDetail, which holds the errorType key). Tests in WatcherTests use FakeFileEventSource + ManualClock + CapturedLogRecords, and `withPermissions(noAccessPermissions, ...)` from TestSupport for chmod 000. No ARCHITECTURE.md.'
  timestamp: 2026-10-19T13:26:59.810697+00:00
- actor: claude-code
  id: 01m5a5ry2sv1dryjppner5mhx9
  text: 'Implementation landed. `SourceText.isMissingFile(_:)` is now the single CocoaError.fileReadNoSuchFile check; `SourceText.failure(of:)` and the watcher both call it (no second copy, and no dead `.notUTF8` arm in the watcher, because `Walker.hashFile` reads bytes). In `Watcher.applyChange`, the `try?` is gone: the hashFile error goes to the new `skipUnreadFile(relativePath:error:)`. A gone file is logged at debug ("the watcher finds no file at a changed path and removes the file from the index") and its row is deleted through the new `deleteFile(relativePath:)`, which the `.removed` path uses too, so a failed delete of a gone file gets the same warning and retry as a `.removed` change. Any other read error keeps the warning "the watcher cannot read a changed file and skips it in this flush", and its metadata now comes from `failureMetadata` (Log.errorDetail), which holds the `errorType` key. The type doc of `Watcher` is updated to match. Note: `Walker.hashFile` and the walker''s own `logSkippedEntry` are unchanged. The `missing creator for mutated node` build warning still shows on every build; it is the known upstream Swift Build / mlx-swift Cmlx warning that ^kw00hcn accepted.'
  timestamp: 2026-10-19T13:31:48.697749+00:00
- actor: claude-code
  id: 01m5a5s2j596c2633zkjgevdzg
  text: |-
    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsCodeContext/Index/SourceText.swift, Sources/FoundationModelsCodeContext/Index/Watcher.swift, Tests/FoundationModelsCodeContextTests/WatcherTests.swift. New tests `aCreatedEventForAPathWithNoFileRemovesTheRowAndLogsNoWarning` and `aChangedFileThatTheFlushCannotReadKeepsTheWarningWithTheErrorType`: RED before the change (row still present plus a warning; no errorType key), GREEN after. `swift test`: 1022 tests in 90 suites passed. `swift test --package-path IntegrationTests`: 22 tests in 16 suites passed. The only warning is the known upstream `missing creator for mutated node` (mlx-swift Cmlx bundle, ^kw00hcn).
    - next: /review
  timestamp: 2026-10-19T13:31:53.285580+00:00
- actor: claude-code
  id: 01m5a5wqxcqrshh8kf5t1ev0g2
  text: |-
    ### test — green
    - evidence: `swift test` — 1022 tests in 90 suites passed, 0 failed, 0 skipped; `swift test --package-path IntegrationTests` — 22 tests in 16 suites passed, 0 failed, 0 skipped. Only warning: pre-existing mlx-swift_Cmlx "missing creator for mutated node" (not chased). LanguageServerGrandchildTests flake (^t71wvkm) did not appear.
    - next: review/commit
  timestamp: 2026-10-19T13:33:53.452494+00:00
- actor: claude-code
  id: 01m5a60nzjxc4g7m95g8t819sf
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (43cb267): 0 findings, 0 confirmed, 0 refuted; 3 files reviewed, 4 .kanban/ files excluded by .reviewignore
    - next: none — task moved to done
  timestamp: 2026-10-19T13:36:02.546039+00:00
- actor: claude-code
  id: 01m5a60yb0frgjs08zdtqtqh8z
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — SourceText.swift, Watcher.swift, WatcherTests.swift (+2 tests)
    - test: green — swift test 1022 passed, IntegrationTests 22 passed, 0 skipped
    - commit: 43cb267
    - review: clean — 0 findings; task in done
  timestamp: 2026-10-19T13:36:11.104665+00:00
position_column: done
position_ordinal: fb80
title: 'Watcher: a file removed before the debounced flush is not a warning'
---
## What
`Watcher.applyChange(relativePath:kind:)` (`Sources/FoundationModelsCodeContext/Index/Watcher.swift`) logs the warning `the watcher cannot read a changed file and skips it in this flush` when `Walker.hashFile` fails for a `.created`/`.modified` event. An agent that writes a scratch file and deletes it within the debounce window produces this warning, the same noise source that ^b91evm0 removed from the tree-sitter and LSP index workers.

## Approach
- Split the failure of `Walker.hashFile` the same way as `SourceText.read(at:)` (`Index/SourceText.swift`): no file at the path (`CocoaError.fileReadNoSuchFile`) -> debug level, and delete the row (`store.deleteFile(filePath:)`) as for a `.removed` event; other read errors keep the warning and add the error type name (`Log.errorType(of:)`).
- Reuse the classification of `SourceText` instead of a second copy.

## TDD
1. Failing test: a `.created` change for a path with no file -> no warning record for the path, and its `indexed_files` row is gone.
2. Test: an unreadable file (chmod 000) -> the warning stays, with the error type. #index #bug
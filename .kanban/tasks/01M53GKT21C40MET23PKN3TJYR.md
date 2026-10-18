---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m563y246mpv4p3n4xzkvt4xw
  text: |-
    Research:
    - `CodeContext` owns one `SharedPathFilter` (`pathFilter`) and gives it to the watcher. The watcher loads the rules in `Watcher.start()`.
    - The `syncOpen` points: `LSPIndexWorker.syncAndFetchSymbols` (called by `processFile` and by the references fallback `fetchCallableSymbols`), `LiveOpsCore.syncLiveDocument` (8 live ops in `LiveOpsCore` and `LiveOpsExtended`), and `DiagnosticsOps.syncAndPull`.
    - The references fallback also opens files that a `textDocument/references` answer names. These paths come from the server, thus the fallback must use the same check. Plan: `processFile` reads the filter one time and gives the value to the fallback.
    - Plan: add `PathFilter.acceptsDocument(relativePath:)` (safe relative path, not ignored, real path from `realpath(3)` in the root) and a `SharedPathFilter` form. Add a required `pathFilter: SharedPathFilter` parameter to `LSPIndexWorker.run`/`drainBatch`, the live ops and `DiagnosticsOps.diagnostics`. No default value, because a default makes a separate copy of the filter.
    - Gap found: when the host gives no event source, `CodeContext` makes no watcher, thus nothing loads the rules and the filter has only the hidden-path and hard-skip rules. This is outside the Change list of this card. I record it as a new task.
  timestamp: 2026-10-17T23:42:41.798421+00:00
- actor: claude-code
  id: 01m564eehc4jnvf1tmndhyx9h1
  text: |-
    Progress:
    - Added `PathFilter.acceptsDocument(relativePath:)` and `SharedPathFilter.acceptsDocument(relativePath:)`, and `WorkspaceRoot.realURL(of:)` (the `realpath(3)` code moved out of `canonicalURL(of:)`). The PathFilterTests for these failed first (no member), then passed (15 tests).
    - Added the required `pathFilter: SharedPathFilter` parameter to `LSPIndexWorker.run/drainBatch/indexFiles/processFile`, the 8 live ops, `syncLiveDocument` and `DiagnosticsOps.diagnostics`. No behavior change yet.
    - New test file Tests/FoundationModelsCodeContextTests/LSPPathCheckTests.swift for the worker, the references fallback, a live op and diagnostics.
    - Note: the sah `files` tool `replace_all` flag did not replace more than one match in this session; each edit changed one match.
  timestamp: 2026-10-17T23:51:38.796640+00:00
- actor: claude-code
  id: 01m565dghh2ac6vdp4t3qjb3sy
  text: |-
    Implementation landed:
    - `LSPIndexWorker.processFile` reads the shared filter one time and calls `PathFilter.acceptsDocument(relativePath:)` before it reads the file. A path that the filter does not accept is marked LSP-indexed (debug log, not an error). The three skip paths now use one helper `skipFile(relativePath:store:level:message:)` (it replaces `markIndexedIgnoringErrors`). The same filter value goes to the references fallback, thus `fetchCallableSymbols` does not open an ignored file that a `references` answer names.
    - `LiveOpsCore.syncLiveDocument` and `DiagnosticsOps.syncAndPull` call `SharedPathFilter.acceptsDocument(relativePath:)` first. `syncAndPull` then sends no `didOpen` and pulls no diagnostics.
    - `CodeContext` gives its one `pathFilter` (the watcher instance) to the worker, the 8 live ops and diagnostics.
    - RED: 7 of the 9 new LSPPathCheckTests failed before the guards (didOpen/pull seen). GREEN after the guards.

    ### implement — changed
    - evidence: `swift test` 904 tests in 80 suites passed; `swift test --filter LSPPathCheckTests` 9 passed; `swift test --filter PathFilterTests` 15 passed. Files: Sources/FoundationModelsCodeContext/{CodeContext.swift, Diagnostics/Diagnose.swift, Index/LSPIndexWorker.swift, Index/LSPIndexWorker+References.swift, Index/PathFilter.swift, Index/RelativePath.swift, Ops/LiveOpsCore.swift, Ops/LiveOpsExtended.swift}; Tests: LSPPathCheckTests.swift (new), PathFilterTests.swift, TestSupport.swift, and the call sites in DiagnosticsTests, LSPIndexWorkerTests, LSPIndexWorkerReferencesTests, LayeredOpsTests, LiveOpsExtendedTests, MetricsTests, TelemetryContentSafetyTests.
    - next: /review. Follow-up task ^pc7m1z6 records the no-watcher gap (the filter has no rule-file rules when CodeContext has no event source).
  timestamp: 2026-10-18T00:08:36.657336+00:00
- actor: claude-code
  id: 01m5663m2zbtr6eqfjewsq5bky
  text: |-
    ### test — green
    - evidence: swift test — 904 tests in 80 suites passed, 0 failed, 0 skipped, 0 warnings from this package (only the SwiftPM build-system note "missing creator for mutated node" on the mlx-swift_Cmlx.bundle dependency); swift build --package-path IntegrationTests --build-tests — Build complete, 0 errors. An earlier full run had 2 timing failures in LspSupervisorTests (unchanged code) while the IntegrationTests build ran at the same time and starved the host; they passed alone (22/22) and the clean full re-run passed.
    - next: commit
  timestamp: 2026-10-18T00:20:41.183507+00:00
- actor: claude-code
  id: 01m566jpgqznpch0m9wg0n6z2q
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (e850544): 0 findings, 0 confirmed, 1 refuted, 28 attempted, 0 failed. 18 files reviewed. 8 .kanban/ files not reviewed (.reviewignore). The task has no prior Review Findings sections. Acceptance criteria: LSPPathCheckTests.swift has tests for an ignored dirty row (no didOpen, row not selected again), a symlink out of the root (worker, live op, diagnostics) and no pull of diagnostics for a path that fails the check.
    - next: none. The task moved to done.
  timestamp: 2026-10-18T00:28:55.191663+00:00
- actor: claude-code
  id: 01m566jyjj6a88exp1x1hag31x
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 8 source files, 10 test files
    - test: green — swift test, 904 passed
    - commit: e850544
    - review: clean — 0 findings
  timestamp: 2026-10-18T00:29:03.442096+00:00
depends_on:
- 01M53GKH8NBN2B0MCXS2RNY171
position_column: done
position_ordinal: e480
title: Do not send ignored paths or paths outside the root to the LSP
---
## Problem
No code checks the ignore rules before it sends `textDocument/didOpen` to a language server.

- `LspSession.syncOpen` (`Sources/FoundationModelsCodeContext/LSP/LspSession.swift:268-281`) opens any URI.
- `LSPIndexWorker.dirtyFiles` (`Index/LSPIndexWorker.swift:251-271`) selects rows by `lsp_indexed = 0` and the extension only.
- The path check `RelativePath.isSafeRelativePath` (`Index/RelativePath.swift:70-75`) is a text check only. It does not resolve symlinks.
- `Diagnose.syncAndPull` (`Diagnostics/Diagnose.swift:146-149`) calls `pullDiagnostics` also when that path check fails.

## Change
- Use the shared path filter from the dependency task at the one point before `syncOpen`: in `LSPIndexWorker.processFile`, `LiveOpsCore.syncLiveDocument` and `Diagnose.syncAndPull`.
- Resolve symlinks and make sure that the path is in the workspace root.
- For an ignored path, the worker deletes the row or marks it LSP-indexed. It must not keep the row dirty, because then it reads the row again.
- In `Diagnose.syncAndPull`, do not pull diagnostics when the path check fails.
- A skipped path is not an error.

## Tests
- A dirty row for an ignored path does not cause `didOpen` (use the fake connection), and the worker does not select that row again.
- A symlink that points out of the root is not opened.
- `Diagnose` does not pull diagnostics for a path that fails the check.

## Acceptance criteria
- [x] No `didOpen` for ignored paths or for paths outside the root.
- [x] The tests above pass.

#lsp-fix
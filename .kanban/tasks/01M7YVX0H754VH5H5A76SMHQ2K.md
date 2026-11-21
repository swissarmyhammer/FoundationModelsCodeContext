---
assignees:
- claude-code
position_column: done
position_ordinal: '80'
title: The idle index loop runs a pass only when the store has a dirty file
---
The index loop of `CodeContext` sleeps 300 ms and then runs an index pass again, also when no file is dirty. Each pass writes one "enter FoundationModelsCodeContext.index.pass" log record at the info level. Thus each idle context writes about 3 records each second. In the AgentViewKit Integration CI job 136741707622, the log had 66,138 such lines in 3 hours.

## Change
- The idle loop requests a pass only when the store has a file with `ts_indexed = 0`, a file with `embedded = 0` (when an embedder is set), or a file with `lsp_indexed = 0` whose extension no LSP server covers.
- The first pass after `start()`, the watcher nudge and `rebuildIndex(layer:)` continue to request passes.

## Acceptance
- [x] With a fake clock and no dirty file, 10 idle sleeps run 0 passes after the first pass. Each pass writes its "enter index.pass" record in its span, thus they write 0 records (`TracingSpanTests.anIdleIndexLoopRunsNoPassAfterTheFirstPass`).
- [x] A dirty file that no watcher event reports gets indexed by the idle loop (`TracingSpanTests.theIdleIndexLoopRunsAPassForADirtyFileThatNoEventReports`).
- [x] An idle sleep with no pass work republishes `state.indexing`, because each `LSPIndexWorker` indexes outside a pass (`TracingSpanTests.anIdleSleepWithNoPassRepublishesTheIndexingStatus`). The CI of 90f3003 failed in `LiveSourceKitTests.liveSourceKitSurvivesACrashAndAutoRestarts` with no such refresh.
- [x] `swift test` passes: 1151 tests in 101 suites. `LiveSourceKitTests` passes on this machine.
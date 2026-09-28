---
comments:
- actor: claude-code
  id: 01m3mvnrncy6jq8f2ehh4kv0fv
  text: |-
    Research done. Findings:
    - `CodeContext.runOneIndexPass()` calls `TreeSitterWorker.run(...)`, which already returns the count of drained files. The index loop starts a pass each 300 ms on the injected clock, so a test with `ManualClock` gets exactly one pass.
    - LSP files are not indexed in the index pass. `LSPIndexWorker.run` indexes them in its own loop. Decision: `filesIndexed` has the dimension `index.layer`: `treesitter` for the index pass, `lsp` for each batch of `LSPIndexWorker`.
    - `ProcessLanguageServerConnection.performRequest` gives raw bytes; the server error is decoded later in `request(...)` and in `pullDiagnostics`. Decision: time the request together with the decode, so a server error response has the outcome `error`. Outcome is a dimension (`lsp.outcome`: ok, error, timeout) on the timer, not a separate counter.
    - `ServerSpec.command` can be an absolute path when the binary is in an installer directory (`LSPDaemon.spawnSpec`). Decision: the `lsp.server` dimension is the last path component of the command, so no home folder path goes into a metric.
    - Restart reasons: `restartWithBackoff()` = `health`; `LspSupervisor.startInstallTask` -> `forceRestart` = `install`; other `forceRestart` = `forced`. Count at the attempt, before `start()`.
    - Factory: an internal `CodeContextMetrics` value with an optional explicit `MetricsFactory`; `nil` reads `MetricsSystem.factory` at record time (same rule as `CodeContextTracing.tracer(explicit:)`). Tests inject `TestMetrics`, so parallel tests share no global state.
    - Name clash: the test target has an actor `Counter` and Foundation has `Timer`. The new source file imports only `Metrics` (no Foundation).
    - Partitioning: the scripted-LSP-server metric test starts a real subprocess, so it goes in `IntegrationTests`. The unit target tests the LSP request recording through `CodeContextMetrics` directly.
  timestamp: 2026-09-28T20:35:34.188837+00:00
- actor: claude-code
  id: 01m3mw5rkxbg663vpjczk9ktjd
  text: |-
    Implementation landed.
    - New `Sources/FoundationModelsCodeContext/Tracing/CodeContextMetrics.swift`: internal struct with an optional explicit `MetricsFactory` (nil = `MetricsSystem.factory` at record time). Timers use `preferredDisplayUnit: .seconds`. Enums `LSPRequestOutcome` (ok/error/timeout, `init(classifying:)`) and `RestartReason` (health/install/forced).
    - `CodeContext.runOneIndexPass()` records `indexDuration` and adds the drained count under `index.layer=treesitter`; a pass that throws records nothing. `TreeSitterWorker` needed no change: `run` already returns the count.
    - `LSPIndexWorker`: new private `indexFiles(...)` is the shared body of `run` and `drainBatch`; it adds the batch count under `index.layer=lsp`.
    - `ProcessLanguageServerConnection.performRequest(method:params:decode:)` now times send + wait + decode, so a server error response gets outcome `error`. The old body is `sendRequest`. The server dimension is the last path component of the command.
    - `LSPDaemon.restartWithBackoff()` counts `health` after the backoff sleep; `forceRestart(reason:)` (default `.forced`) counts before `start()`; `LspSupervisor.startInstallTask` passes `.install`. The metrics value goes CodeContext -> LspSupervisor -> LSPDaemon, and `processConnectionFactory(clock:metrics:)`.
    - Partition: the scripted-server request test is in `IntegrationTests/.../LSPRequestMetricsTests.swift` (real subprocess). The script path helper moved from `LoggingContentTests` into `IntegrationSupport.swift` as `ScriptedLSPServer.path`, so the two integration tests share it. `IntegrationTests/Package.swift` now depends on `swift-metrics` (`MetricsTestKit`).
    - Pre-existing swiftlint `no_magic_numbers` hits remain in lines this change did not touch (for example `LSPIndexWorker` configuration defaults); the new files are clean.
  timestamp: 2026-09-28T20:44:18.429483+00:00
- actor: claude-code
  id: 01m3mw5wq8c1ge4yyttf4dsj6a
  text: |-
    ### implement — changed
    - evidence: 13 files — Sources/FoundationModelsCodeContext/Tracing/CodeContextMetrics.swift (new), Sources/FoundationModelsCodeContext/Tracing/CodeContextTracing.swift, Sources/FoundationModelsCodeContext/CodeContext.swift, Sources/FoundationModelsCodeContext/Index/LSPIndexWorker.swift, Sources/FoundationModelsCodeContext/LSP/LSPDaemon.swift, Sources/FoundationModelsCodeContext/LSP/LspSupervisor.swift, Sources/FoundationModelsCodeContext/LSP/ProcessLanguageServerConnection.swift, Package.swift, Tests/FoundationModelsCodeContextTests/MetricsTests.swift (new), IntegrationTests/Package.swift, IntegrationTests/Tests/FoundationModelsCodeContextIntegrationTests/{LSPRequestMetricsTests.swift (new), IntegrationSupport.swift, LoggingContentTests.swift}. `swift test --parallel`: 713 tests in 66 suites passed, 0 failures, 0 source warnings. `swift test --filter 'FoundationModelsCodeContextTests\.MetricsTests'`: 8 tests passed. `swift test --package-path IntegrationTests --filter '...(LSPRequestMetricsTests|LoggingContentTests)'`: 2 tests passed.
    - next: /review
  timestamp: 2026-09-28T20:44:22.632459+00:00
- actor: claude-code
  id: 01m3mwavqma5268sw3tbs2320n
  text: |-
    ### test - green
    - evidence: root package `swift test --parallel`: 713 tests in 66 suites passed, 0 failed, 0 skipped, exit 0. Integration package (`swift test` in IntegrationTests): 4 tests in 4 suites passed, 0 failed, 0 skipped, exit 0. Build complete in both. No Swift compiler warnings or errors in either output.
    - note: SwiftPM prints "failed loading cached manifest ... disk I/O error" lines. They come from the SwiftPM manifest cache in this environment. They are not from source code.
    - next: review
  timestamp: 2026-09-28T20:47:05.460589+00:00
depends_on:
- 01M3MNFXGGMN1K0Q2A0SA5VZ5M
position_column: doing
position_ordinal: '80'
title: 'OTel D: add metrics for index duration, files indexed, LSP request latency by method and LSP server restarts'
---
## What

Part of the OpenTelemetry design that the user approved on 2026-09-28 (copy: /private/tmp/claude-501/-Users-wballard-github-swissarmyhammer/9f4fa2e8-6833-46c6-bb95-5091ae3613fa/scratchpad/otel-design.md). Rules 1, 3 and 4. Add metrics through the `swift-metrics` API: index duration, files indexed, LSP request latency by method, and LSP server restarts. A metric dimension is a name only (method name, server command name), never content.

Research (where each metric goes):
- Index duration and files indexed: `CodeContext.runOneIndexPass()` in `Sources/FoundationModelsCodeContext/CodeContext.swift` (near 829). The workers that index files: `Index/TreeSitterWorker.swift` and `Index/LSPIndexWorker.swift`. `Reconciler.reconcile` returns `CleanupStats` in `Index/Reconciler.swift`. Decide if "files indexed" counts per worker (dimension `layer`: `treesitter` or `lsp`), and document it.
- LSP request latency: `ProcessLanguageServerConnection.performRequest(method:params:)` in `LSP/ProcessLanguageServerConnection.swift` (near 504). Dimensions: `lsp.method` and `lsp.server`. Both have a small, fixed set of values. Also record the outcome (`ok`, `error`, `timeout`) as a dimension, or as a separate counter; decide.
- LSP server restarts: `LSPDaemon.restartWithBackoff()` (near 355) and `LSPDaemon.forceRestart()` (near 373) in `LSP/LSPDaemon.swift`, called from `LSP/LspSupervisor.swift` (near 326 and 390). Dimension: `lsp.server`, and `reason` (`health`, `install`, `forced`) if simple.

Do this:
- [x] Depends on the vocabulary task of this board (metric names in `CodeContextTracing.MetricName`, dimension keys in `AttributeKey`).
- [x] Use `Metrics.Timer` for durations (nanoseconds, or `preferredDisplayUnit` seconds) and `Metrics.Counter` for counts. Create each metric object with a label from the vocabulary file.
- [x] Decide if the metrics factory is the global `MetricsSystem` or an injected `MetricsFactory` (for tests); prefer the injectable form with the global factory as the default, so that parallel tests do not share global state. Document the choice.
- [x] Doc comments in ASD-STE100 Simplified Technical English.

## Files to change
- `Sources/FoundationModelsCodeContext/CodeContext.swift`
- `Sources/FoundationModelsCodeContext/Index/TreeSitterWorker.swift`, `Sources/FoundationModelsCodeContext/Index/LSPIndexWorker.swift`
- `Sources/FoundationModelsCodeContext/LSP/ProcessLanguageServerConnection.swift`
- `Sources/FoundationModelsCodeContext/LSP/LSPDaemon.swift`, `Sources/FoundationModelsCodeContext/LSP/LspSupervisor.swift`
- `Sources/FoundationModelsCodeContext/Tracing/CodeContextTracing.swift` (add names if needed)
- `Package.swift` (test target: product `MetricsTestKit` of `swift-metrics`)
- New: `Tests/FoundationModelsCodeContextTests/MetricsTests.swift`

## Acceptance Criteria
- [x] One index pass records one `indexDuration` value and adds the count of indexed files to `filesIndexed`.
- [x] Each LSP request records one `lspRequestDuration` value with the method and server dimensions.
- [x] Each restart of a language server adds 1 to `lspServerRestarts` with the server dimension.
- [x] No dimension value is a file content, a query or a payload.

## Tests
- [x] New `Tests/FoundationModelsCodeContextTests/MetricsTests.swift` with `TestMetrics` from `MetricsTestKit`:
  - [x] an index pass over a small fixture folder: one timer value and the expected counter value;
  - [x] a scripted LSP request (`Support/scripted-lsp-server.swift`): one timer value with dimension `lsp.method` equal to the method name; (the test starts a real subprocess, so it is in `IntegrationTests/.../LSPRequestMetricsTests.swift`; the unit target tests the recording with fakes)
  - [x] a forced restart: the restart counter is 1 for that server.
- [x] `swift test --parallel` passes. With `swift test --filter`, use a regex with the target name and check that the count of tests that ran is not zero.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
- Do not run `swift format`.
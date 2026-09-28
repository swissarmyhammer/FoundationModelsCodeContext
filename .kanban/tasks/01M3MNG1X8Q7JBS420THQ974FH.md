---
depends_on:
- 01M3MNFXGGMN1K0Q2A0SA5VZ5M
position_column: todo
position_ordinal: '8280'
title: 'OTel D: add metrics for index duration, files indexed, LSP request latency by method and LSP server restarts'
---
## What

Part of the OpenTelemetry design that the user approved on 2026-09-28 (copy: /private/tmp/claude-501/-Users-wballard-github-swissarmyhammer/9f4fa2e8-6833-46c6-bb95-5091ae3613fa/scratchpad/otel-design.md). Rules 1, 3 and 4. Add metrics through the `swift-metrics` API: index duration, files indexed, LSP request latency by method, and LSP server restarts. A metric dimension is a name only (method name, server command name), never content.

Research (where each metric goes):
- Index duration and files indexed: `CodeContext.runOneIndexPass()` in `Sources/FoundationModelsCodeContext/CodeContext.swift` (near 829). The workers that index files: `Index/TreeSitterWorker.swift` and `Index/LSPIndexWorker.swift`. `Reconciler.reconcile` returns `CleanupStats` in `Index/Reconciler.swift`. Decide if "files indexed" counts per worker (dimension `layer`: `treesitter` or `lsp`), and document it.
- LSP request latency: `ProcessLanguageServerConnection.performRequest(method:params:)` in `LSP/ProcessLanguageServerConnection.swift` (near 504). Dimensions: `lsp.method` and `lsp.server`. Both have a small, fixed set of values. Also record the outcome (`ok`, `error`, `timeout`) as a dimension, or as a separate counter; decide.
- LSP server restarts: `LSPDaemon.restartWithBackoff()` (near 355) and `LSPDaemon.forceRestart()` (near 373) in `LSP/LSPDaemon.swift`, called from `LSP/LspSupervisor.swift` (near 326 and 390). Dimension: `lsp.server`, and `reason` (`health`, `install`, `forced`) if simple.

Do this:
- [ ] Depends on the vocabulary task of this board (metric names in `CodeContextTracing.MetricName`, dimension keys in `AttributeKey`).
- [ ] Use `Metrics.Timer` for durations (nanoseconds, or `preferredDisplayUnit` seconds) and `Metrics.Counter` for counts. Create each metric object with a label from the vocabulary file.
- [ ] Decide if the metrics factory is the global `MetricsSystem` or an injected `MetricsFactory` (for tests); prefer the injectable form with the global factory as the default, so that parallel tests do not share global state. Document the choice.
- [ ] Doc comments in ASD-STE100 Simplified Technical English.

## Files to change
- `Sources/FoundationModelsCodeContext/CodeContext.swift`
- `Sources/FoundationModelsCodeContext/Index/TreeSitterWorker.swift`, `Sources/FoundationModelsCodeContext/Index/LSPIndexWorker.swift`
- `Sources/FoundationModelsCodeContext/LSP/ProcessLanguageServerConnection.swift`
- `Sources/FoundationModelsCodeContext/LSP/LSPDaemon.swift`, `Sources/FoundationModelsCodeContext/LSP/LspSupervisor.swift`
- `Sources/FoundationModelsCodeContext/Tracing/CodeContextTracing.swift` (add names if needed)
- `Package.swift` (test target: product `MetricsTestKit` of `swift-metrics`)
- New: `Tests/FoundationModelsCodeContextTests/MetricsTests.swift`

## Acceptance Criteria
- [ ] One index pass records one `indexDuration` value and adds the count of indexed files to `filesIndexed`.
- [ ] Each LSP request records one `lspRequestDuration` value with the method and server dimensions.
- [ ] Each restart of a language server adds 1 to `lspServerRestarts` with the server dimension.
- [ ] No dimension value is a file content, a query or a payload.

## Tests
- [ ] New `Tests/FoundationModelsCodeContextTests/MetricsTests.swift` with `TestMetrics` from `MetricsTestKit`:
  - [ ] an index pass over a small fixture folder: one timer value and the expected counter value;
  - [ ] a scripted LSP request (`Support/scripted-lsp-server.swift`): one timer value with dimension `lsp.method` equal to the method name;
  - [ ] a forced restart: the restart counter is 1 for that server.
- [ ] `swift test --parallel` passes. With `swift test --filter`, use a regex with the target name and check that the count of tests that ran is not zero.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
- Do not run `swift format`.
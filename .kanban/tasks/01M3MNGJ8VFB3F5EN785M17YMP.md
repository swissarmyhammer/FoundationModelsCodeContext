---
comments:
- actor: claude-code
  id: 01m3n0zx9dc3ncjzkb41q79cty
  text: |-
    Research (implement step):
    - The Extras product `TelemetryTestSupport` exists on Extras main (commit 53c797f). `TelemetryCapture.run(forbidding:_:)` is the only public way to get the leak check. `TelemetryCapture.Context.init` is internal.
    - `TelemetryCapture` calls `LoggingSystem.bootstrap` one time for each process (`TelemetryLogRouting.bootstrapOnce`). `CapturedLogRecords` also calls `LoggingSystem.bootstrap`. Both in one process stop the process.
    - `TelemetryCapture` sends each log record to the capture of the current task (task-local). Its doc says: "A detached task gets no capture." The record goes nowhere.
    - The `lspRequest` span, the `lsp.request.duration` timer, the `lsp-wire` records and the stderr records exist only in `ProcessLanguageServerConnection`. That type always starts a real subprocess (`Process.run()`). No fake connection opens the `lspRequest` span or records the request metric.
    - `ProcessLanguageServerConnection` writes the stderr records (`runStderrDrainLoop`, `Log.lsp.debug`) and the "from server" wire records (`runReaderLoop`) in `Task.detached`. Thus `TelemetryCapture` cannot see these records.
    - `IntegrationTests/.../LoggingContentTests.swift` expects the stderr records and the wire records to be not empty (it reads them from `CapturedLogRecords`, which captures records of all tasks).
  timestamp: 2026-09-28T22:08:29.485126+00:00
- actor: claude-code
  id: 01m3n1073xmy3gpkdze1a20wf1
  text: |-
    ### implement — stuck
    - evidence: no files changed. Research only (see the comment before this one).
    - blocker 1 (card against rule `test-integrity/test-partitioning`): the card puts one test in the unit target (`Tests/FoundationModelsCodeContextTests/TelemetryContentSafetyTests.swift`) that runs "a scripted LSP request" with "the scripted LSP server response and its stderr". The `lspRequest` span, the `lsp.request.duration` timer, the `lsp-wire` records and the stderr records exist only in `ProcessLanguageServerConnection`, which always starts a real subprocess. The rule says: a test that starts a real subprocess must go in the nested `IntegrationTests` package. The two cannot both be correct for one test in one file.
    - blocker 2 (card against the Extras helper design): the card wants the Extras helper to fail on the marker in the stderr text and the LSP wire payload. `TelemetryCapture` routes log records by task-local, and "a detached task gets no capture". `ProcessLanguageServerConnection` writes the stderr records and the "from server" wire records in `Task.detached`. Thus the helper cannot see these records, and the test cannot prove the no-content rule for them.
    - blocker 3 (one bootstrap per process): to use `TelemetryCapture` in `IntegrationTests`, `CapturedLogRecords` there must move onto `TelemetryCapture`. Then `IntegrationTests/.../LoggingContentTests.swift` loses the stderr and wire records (same detached-task cause) and its `!stderrRecords.isEmpty` and `!wireRecords.isEmpty` expectations fail.
    - options for a person to decide:
      (a) Split the test: a unit test with fakes in `TelemetryContentSafetyTests.swift` (index pass, embed, watcher batch, `searchCode`, forced restart through `LSPDaemon` with a fake connection and a marker `stderrTail`, an `LspSession` request with a fake marker response), plus a second content-safety test in `IntegrationTests` for the `ProcessLanguageServerConnection` paths.
      (b) Change `TelemetryCapture` in Extras so that a record with no task capture goes to a process-wide capture (or to each open capture), so that detached-task records are visible. Then move both `CapturedLogRecords` copies onto it.
      (c) Change `ProcessLanguageServerConnection` so that the reader loop and the stderr drain loop keep the task-locals of the caller (not `Task.detached`). This changes concurrency behavior of a blocking read loop and needs a separate decision.
    - next: a person picks an option and updates the card.
  timestamp: 2026-09-28T22:08:39.549184+00:00
- actor: claude-code
  id: 01m3n10n9x1ced3en5an34pr08
  text: |-
    ### finish iteration 1 — stuck
    - implement: stuck — no files changed. The card conflicts with test-integrity/test-partitioning: the LSP request span, metric, wire and stderr paths exist only in ProcessLanguageServerConnection, which starts a real subprocess. TelemetryCapture does not capture records from Task.detached. Moving IntegrationTests CapturedLogRecords onto TelemetryCapture breaks LoggingContentTests.
    - test: not run
    - commit: not run
    - review: not run
    - next: a person must pick option (a) split the test, (b) change TelemetryCapture in Extras, or (c) change the ProcessLanguageServerConnection read loops, and then update the card.
  timestamp: 2026-09-28T22:08:54.077037+00:00
- actor: claude-code
  id: 01m3pg10dvmaxgkzhyr2a1eraf
  text: |-
    Research (implement step, split plan of 2026-09-29):
    - The Extras `TelemetryTestSupport` product has no public content-check function that works without `TelemetryCapture.run`. `leaks(forbidding:)` is on `TelemetryCapture.Context`, and `Context.init` is internal. `MetricRecord.places` is internal. Thus each test package gets one small shared check function (`TelemetryContentCheck`), per the card. No package manifest change is necessary.
    - Both packages already have `CapturedLogRecords` with `entries(holding:)`. The check function uses it for the log records.
    - Unit paths with fakes: index pass (`CodeContext` with `tracer:` and `metrics:`, tree-sitter chunks and embed), watcher batch (`Watcher` with `tracer:`), `searchCode`, `searchSymbol` and `grepCode` (search spans and embed span), forced restart (`LSPDaemon.forceRestart` with a fake connection; restart counter and lifecycle logs), and an LSP request through `LspSession` (`LSPIndexWorker.drainBatch`: `lsp` files-indexed counter and the `logFailure` record for a `WireError.serverError` that holds the marker).
    - Integration paths: `ProcessLanguageServerConnection` with the scripted server (stderr marker, hover response with the marker, error response with the marker): `lspRequest` spans, "enter" records, `lsp-wire` records, stderr records and `lsp.request.duration` timers.
  timestamp: 2026-09-29T11:50:28.539293+00:00
- actor: claude-code
  id: 01m3pgq2s2g2wxxkqa0m9jkc71
  text: |-
    Implementation landed (split plan):
    - Unit test `Tests/FoundationModelsCodeContextTests/TelemetryContentSafetyTests.swift`: one test with fakes. The marker is a Swift identifier, so it is the function name and the body of `Marked.swift`, the search query, the symbol-search query, the grep pattern and the embed input. The test also drives a watcher batch, an `LSPIndexWorker.drainBatch` through an `LspSession` (symbol name = marker, `prepareCallHierarchy` refused with a `WireError.serverError` whose message is the marker), and a forced restart of an `LSPDaemon` whose second handshake fails with an error whose description is the marker and whose `stderrTail` is the marker. It checks that the spans (index pass, watcher batch, embed, search, search_symbol, grep_code) and the metrics (index duration, files indexed, restarts) exist, and that the session failure record and the daemon failure record exist, so the check is not empty. Runtime about 0.05 s.
    - Integration test `IntegrationTests/Tests/FoundationModelsCodeContextIntegrationTests/TelemetryContentSafetyTests.swift`: the scripted server writes the marker to stderr, sends it in a `window/logMessage` notification, in the first hover answer, and in the error message of the second answer. The document URI holds the marker too. The test checks 2 `lspRequest` spans, 2 `lsp.request.duration` timers (ok and error), the stderr records and the `lsp-wire` records.
    - Content check: the Extras `TelemetryTestSupport` has no public check without `TelemetryCapture.run`, so each package has one `TelemetryContentCheck` enum (the integration one is a local copy, as `CapturedLogRecords` is). It reads span names, attributes, events, status messages and recorded errors, the metric names and dimensions of all four metric kinds, and the log records through `CapturedLogRecords.entries(holding:)`.
    - Deliberate-leak check, done and reverted: (1) the embed span got the first input text as an attribute: the unit test failed with 2 leaks. (2) the `lspRequest` span got the response body as an attribute: the integration test failed with 2 leaks. `git status -- Sources` shows only the `CodeContextTracing` doc comment change.
    - No source file leaked content. No package manifest change was necessary.
    - The health and install restart reasons use the same `CodeContextMetrics.addServerRestart` path that the forced restart drives.
  timestamp: 2026-09-29T12:02:31.842752+00:00
- actor: claude-code
  id: 01m3pgq767bddzdeme4axdn6w6
  text: |-
    ### implement — changed
    - evidence: 3 files — Tests/FoundationModelsCodeContextTests/TelemetryContentSafetyTests.swift (new), IntegrationTests/Tests/FoundationModelsCodeContextIntegrationTests/TelemetryContentSafetyTests.swift (new), Sources/FoundationModelsCodeContext/Tracing/CodeContextTracing.swift (doc comment). Root `swift test --parallel`: 726 tests in 68 suites passed, 0 compiler warnings. `IntegrationTests/` `swift test`: 8 tests in 6 suites passed, 0 compiler warnings. Filter runs: `swift test --filter 'FoundationModelsCodeContextTests\.TelemetryContentSafetyTests'` ran 1 test; `swift test --filter 'FoundationModelsCodeContextIntegrationTests\.TelemetryContentSafetyTests'` ran 1 test.
    - next: /review. Task stays in doing. Not committed.
  timestamp: 2026-09-29T12:02:36.359049+00:00
- actor: claude-code
  id: 01m3pgxkp1dat2yb5bb18a3dxc
  text: |-
    ### test - green
    - evidence: root package `swift test --parallel`: 726 tests in 68 suites passed, 0 failed, 0 skipped. Nested package `swift test` in IntegrationTests: 8 tests in 6 suites passed, 0 failed, 0 skipped. No Swift compiler warnings or errors in either build.
    - note: SwiftPM prints "failed loading cached manifest ... disk I/O error" lines. They come from the SwiftPM manifest cache, not from project source. No source file has a warning.
    - next: review
  timestamp: 2026-09-29T12:06:05.761759+00:00
- actor: claude-code
  id: 01m3pgy21b8nnm307s6nptxppq
  text: |-
    ### commit — changed
    - evidence: local commit "test(telemetry): add content-safety tests for spans, logs and metrics" (not pushed)
    - next: review
  timestamp: 2026-09-29T12:06:20.459576+00:00
depends_on:
- 01M3MNG1QASG67M11BWYDV23N3
- 01M3MNGDM83M4WET55KH1CN8B7
- 01M3MNG1X8Q7JBS420THQ974FH
position_column: doing
position_ordinal: '80'
title: 'OTel E: add the content-safety test for spans, logs and metrics of this package'
---
## What

Part of the OpenTelemetry design that the user approved on 2026-09-28 (copy: /private/tmp/claude-501/-Users-wballard-github-swissarmyhammer/9f4fa2e8-6833-46c6-bb95-5091ae3613fa/scratchpad/otel-design.md). Rules 4 and 5. Prove the no content rule for this package: no span attribute, log message, log metadata value or metric dimension carries source code, file content, query text, embed input text or an LSP wire payload.

## Decision (user, 2026-09-29): split the test

The first plan put all paths in one unit test. That plan conflicts with the `test-integrity/test-partitioning` rule. The LSP request span, the `lsp.request.duration` timer, the `lsp-wire` records and the stderr records exist only in `ProcessLanguageServerConnection`, and that type always starts a real subprocess. Thus the user chose to split the test in two:

1. A **unit test** with fakes, in the unit test target.
2. An **integration test** for the `ProcessLanguageServerConnection` paths, in the nested `IntegrationTests` package.

Rules for log capture:
- Set up the logging system one time per process only. Each test package already does this in its `CapturedLogRecords`. Use that capture. Do NOT move it onto the Extras `TelemetryCapture`: `TelemetryCapture` does not see records from `Task.detached`, and the stderr and reader loops of `ProcessLanguageServerConnection` write from detached tasks.
- You can use a content-check function from the Extras `TelemetryTestSupport` product if it only checks captured values and does not set up the logging system. If it cannot do that, write one small shared check function in each test package (no near-duplicate copies inside one package).

Do this:
- [x] Depends on the span task, the swift-log task and the metrics task of this board.
- [x] Unit test: new `Tests/FoundationModelsCodeContextTests/TelemetryContentSafetyTests.swift`. Use a fixture with a unique marker string in: a source file body, a symbol name that is not in any attribute, the search query and the text that goes to the test `TextEmbedding`. Run an index pass, a watcher batch, a `searchCode` call (with embed), a forced LSP restart and a request through `LspSession` with a fake connection. Then check the captured spans, log records and metrics, and fail on any value that contains the marker.
- [x] Integration test: new `IntegrationTests/Tests/FoundationModelsCodeContextIntegrationTests/TelemetryContentSafetyTests.swift`. Put the marker in the scripted LSP server response and its stderr. Send a scripted LSP request through `ProcessLanguageServerConnection`. Check the captured spans (the `lspRequest` span), log records (the `lsp-wire` and stderr records) and metrics (the `lsp.request.duration` timer), and fail on any value that contains the marker.
- [x] Update the doc comment of `CodeContextTracing` to name both tests, as `RouterTracing` names `SpanContentSafetyTests`.
- [x] Doc comments in ASD-STE100 Simplified Technical English.

## Files to change
- `Package.swift` and `IntegrationTests/Package.swift` (test target dependencies, only if needed)
- New: `Tests/FoundationModelsCodeContextTests/TelemetryContentSafetyTests.swift`
- New: `IntegrationTests/Tests/FoundationModelsCodeContextIntegrationTests/TelemetryContentSafetyTests.swift`
- `Sources/FoundationModelsCodeContext/Tracing/CodeContextTracing.swift` (doc comment)
- Any source file where a test finds content (fix it there, not in the test).

## Acceptance Criteria
- [x] Together, the two tests drive every span, log and metric path of this package that the other OTel tasks added.
- [x] Each test fails when a span attribute, a log message, a log metadata value or a metric dimension contains the marker (check this one time by adding the marker to one attribute on purpose, then remove it).
- [x] Both tests pass on the final code.

## Tests
- [x] The unit test uses an explicit `InMemoryTracer`, the package `CapturedLogRecords` and a test metrics factory. It does not set up global systems in a way that breaks parallel tests.
- [x] Root `swift test --parallel` passes, and `swift test` in `IntegrationTests/` passes. With `swift test --filter`, use a regex with the target name and check that the count of tests that ran is not zero.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
- Do not run `swift format`.
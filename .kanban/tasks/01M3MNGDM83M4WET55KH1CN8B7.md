---
comments:
- actor: claude-code
  id: 01m3mx3bfqbece3e0wt8r8r40d
  text: |-
    Research:
    - The Extras helper is `TracedCall.run(_:ofKind:tracer:logger:attributes:metadata:_:)` in the `FoundationModelsExtras` product (Extras commit 736820a). This package links only the `Operations` product, and Package.resolved pins Extras at 8ec26d4, which does not have `TracedCall`. The fix: add the `FoundationModelsExtras` product to the library target and move the pin to Extras main (origin/main 6c399a4).
    - `TelemetryCapture` (Extras TelemetryTestSupport) calls `LoggingSystem.bootstrap` one time for each process. The unit target and the IntegrationTests target each already bootstrap logging in `CapturedLogRecords` (LoggingContentTests). A second bootstrap stops the process (swift-log precondition). Thus the tests cannot call `TelemetryCapture.run`. The "enter" record tests use `CapturedLogRecords.entries(matching:)` instead, which is the capture that this package already bootstraps.
    - `WireError.serverError` holds the server message (content). `withSpan` records the thrown error value on the span. Thus the span helper must record only the error type, not the error value.
    - The reconcile runs only in `start()`, not in each pass. The pass span carries the count of files that `TreeSitterWorker.run` drained.
    - The metrics pattern is an internal init parameter with a default (`CodeContextMetrics()`). The tracer follows the same pattern: an internal `tracer: (any Tracer)?` parameter, `nil` by default, which reads `InstrumentationSystem.tracer` at call time. `CodeContextManager` does not take a tracer, the same as it does not take metrics.
    - The LSP request test starts the scripted subprocess, thus it goes in IntegrationTests.
  timestamp: 2026-09-28T21:00:28.023242+00:00
- actor: claude-code
  id: 01m3myr8x4ybf5vy4q3s5x84wk
  text: |-
    Implementation landed (TDD: RED seen for the unit tests as a compile failure on the missing `tracer:` arguments, and for the integration tests as 3 failing tests with 5 issues; then GREEN).

    Decisions:
    - Tracer injection follows the `CodeContextMetrics` pattern: an internal `tracer: (any Tracer)? = nil` on `CodeContext.init(...connectionFactory:)`, `ProcessLanguageServerConnection.init`, and a defaulted `tracer:` on the public `Watcher.init`, `TreeSitterWorker.run` and `SearchCode.run`. `nil` reads `InstrumentationSystem.tracer` at call time through `CodeContextTracing.tracer(explicit:)`. The public `CodeContext` and `CodeContextManager` initializers do not take a tracer (the same as metrics); a host bootstraps its tracer. `ManagerQueries.searchCode` needs no change: each root gives its own `search` span through `CodeContext.searchCode`.
    - New `Tracing/CodeContextSpans.swift`: `withEnterRecord` (wraps `TracedCall.run` of FoundationModelsExtras) for the index pass, each LSP request and each embed call; `withSpan` (no enter record) for the search, `searchSymbol` and `grepCode`. The watcher batch uses `CodeContextTracing.tracer(explicit:).withSpan` directly, because its body cannot throw. `CodeContextSpans.embed` is the one embed-span helper that `TreeSitterWorker` and `SearchCode` share.
    - Error rule: the helpers catch the error of the body, record only `SpanErrorType` (description = the type name, for example `FoundationModelsCodeContext.WireError`) and set the status to error, then rethrow the original error. Thus `WireError.serverError` never puts the server message on a span.
    - LSP span: kind `.client`; attributes server (last path component, `CodeContextMetrics.serverName(ofCommand:)`, now internal), method, request id, request bytes, response bytes, outcome. No trace context goes into the wire.
    - Index pass span: `index.layer` = `treesitter` (`CodeContextMetrics.dimensionValue(of:)`, now internal) and `index.files_indexed`. The reconcile is not part of a pass, thus `Reconciler.swift` did not change.
    - Also added spans for `searchSymbol` and `grepCode` (the optional item) with limit and result count.
    - Package: the library target now links the `FoundationModelsExtras` product for `TracedCall`. IntegrationTests now depends on swift-distributed-tracing (`Tracing`, `InMemoryTracing`). Both Package.resolved files moved Extras to main 6c399a4 (Package.resolved is gitignored).
    - The scripted LSP server got a `respondError` action (shared `writeResponse` helper) for the error-span test.

    Deviation to note for review: the card says to use the Extras OTel B capture (`TelemetryCapture`). That helper calls `LoggingSystem.bootstrap` one time for each process, and both test processes already bootstrap logging in `CapturedLogRecords`; a second bootstrap stops the process. The "enter" record tests therefore use `CapturedLogRecords` (the capture that each test process already has). If `TelemetryCapture` must be used, the `CapturedLogRecords` bootstrap in both packages must first move onto `TelemetryCapture` (the OTel E content-safety task is a natural place).
  timestamp: 2026-09-28T21:29:22.084470+00:00
- actor: claude-code
  id: 01m3myrez6shy3ppdnj8t57pe9
  text: |-
    ### implement — changed
    - evidence: 13 files. New: Sources/FoundationModelsCodeContext/Tracing/CodeContextSpans.swift, Tests/FoundationModelsCodeContextTests/TracingSpanTests.swift, IntegrationTests/Tests/FoundationModelsCodeContextIntegrationTests/LSPRequestSpanTests.swift. Changed: Package.swift, IntegrationTests/Package.swift, CodeContext.swift, Index/TreeSitterWorker.swift, Index/Watcher.swift, LSP/ProcessLanguageServerConnection.swift, Ops/SearchCode.swift, Search/SearchCorpus.swift (doc reference), Tracing/CodeContextMetrics.swift (two helpers now internal), Tests/.../Support/scripted-lsp-server.swift (respondError). `swift build --build-tests`: 0 warnings, 0 errors. `swift test --filter FoundationModelsCodeContextTests.TracingSpanTests`: 10 passed. `swift test --parallel`: 723 tests in 67 suites passed. `swift test --package-path IntegrationTests`: 7 tests in 5 suites passed (LSPRequestSpanTests 3 of them).
    - next: /review. Reviewer: see the deviation note on TelemetryCapture in the comment above.
  timestamp: 2026-09-28T21:29:28.294076+00:00
- actor: claude-code
  id: 01m3mz43zxxhr1tes6ce0av5vd
  text: |-
    ### test — green
    - evidence: root package `swift test --parallel`: 723 tests in 67 suites passed, 0 failed, 0 skipped. Nested package `swift test` in IntegrationTests: 7 tests in 5 suites passed, 0 failed, 0 skipped. Both `swift build --build-tests --manifest-cache none` runs: build complete, 0 compiler warnings.
    - note: normal runs print SwiftPM "failed loading/storing cached manifest ... disk I/O error" lines. They come from the local SwiftPM manifest cache, not from the source. They do not appear when the manifest cache is off.
    - next: review
  timestamp: 2026-09-28T21:35:50.269588+00:00
- actor: claude-code
  id: 01m3mz4k5mxyzhd0xcjrnh18pk
  text: |-
    ### commit — changed
    - evidence: e6d62bd feat(tracing): add spans for index pass, watcher batch, LSP request, embed call and search
    - next: review
  timestamp: 2026-09-28T21:36:05.812168+00:00
- actor: claude-code
  id: 01m3mzqnvs64g3nvs0jdgw6nrx
  text: |-
    ### review — findings
    - evidence: `review sha HEAD~1..HEAD` (commit f51d60a). Counts: 1 finding, 1 confirmed, 1 refuted, 14 attempted, 0 failed. Finding: Sources/FoundationModelsCodeContext/CodeContext.swift:486 `duplication/duplication`.
    - next: Do the finding in the `## Review Findings (2026-09-28 16:36)` section. Remove the duplicate span wrap from all of CodeContext.swift, not only the line in the finding. Then run /review again.
  timestamp: 2026-09-28T21:46:31.161567+00:00
- actor: claude-code
  id: 01m3mzr29eyh39h0bbf23mh0hc
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 13 files (CodeContextSpans.swift new, TracingSpanTests.swift new, IntegrationTests LSPRequestSpanTests.swift new)
    - test: green — root swift test --parallel 723 passed; IntegrationTests swift test 7 passed; 0 failed, 0 skipped, 0 compiler warnings
    - commit: f51d60a
    - review: findings — Sources/FoundationModelsCodeContext/CodeContext.swift:486 (duplication/duplication)
  timestamp: 2026-09-28T21:46:43.886976+00:00
- actor: claude-code
  id: 01m3n095syjjrymrksnegnqchf
  text: |-
    Finding fix (duplication/duplication, CodeContext.swift searchSymbol and grepCode):
    - New shared helper `CodeContextSpans.withSearchSpan(_:tracer:limit:resultCount:_:)` (internal) in Tracing/CodeContextSpans.swift. It sets the limit attribute before the body, and the result-count attribute from the `resultCount` accessor after the body. It uses `withSpan`, thus the error rule does not change: only the error type goes on the span, and a failed body sets no result count.
    - `CodeContext.searchSymbol`, `CodeContext.grepCode` and `SearchCode.run` (the third site with the same shape) now call the helper. No other near-duplicate span wrap is in CodeContext.swift: the index pass uses `withEnterRecord` with different attributes.
    - TDD: 2 new unit tests in TracingSpanTests (`theSearchSpanHelperSetsTheLimitAndTheResultCountOfTheBody`, `theSearchSpanHelperRecordsOnlyTheErrorTypeWhenTheBodyThrows`). RED seen as a compile failure (no member `withSearchSpan`), then GREEN.
    - Subtask boxes: 15 of 16 ticked after a check of the code. One box stays open: "the enter record exists for the LSP request (use the capture of Extras task OTel B ^z6jqd9g)". The test exists (IntegrationTests LSPRequestSpanTests.aRequestWritesAnEnterRecordBeforeItIsSent), but it uses `CapturedLogRecords`, not the OTel B `TelemetryCapture`, because a second `LoggingSystem.bootstrap` stops the test process (see the earlier deviation comment). A person must accept this deviation, or OTel E must move `CapturedLogRecords` onto `TelemetryCapture`.
  timestamp: 2026-09-28T21:56:04.542603+00:00
- actor: claude-code
  id: 01m3n098axrerv81dn7vh0x98e
  text: |-
    ### implement — changed
    - evidence: 4 files — Sources/FoundationModelsCodeContext/Tracing/CodeContextSpans.swift, Sources/FoundationModelsCodeContext/CodeContext.swift, Sources/FoundationModelsCodeContext/Ops/SearchCode.swift, Tests/FoundationModelsCodeContextTests/TracingSpanTests.swift. `swift build --build-tests`: build complete, 0 source warnings. Root `swift test --parallel`: 725 tests in 67 suites passed. IntegrationTests `swift test`: 7 tests in 5 suites passed. Finding flipped to [x]. Subtasks 15/16; the open box is the OTel B capture deviation.
    - next: /review
  timestamp: 2026-09-28T21:56:07.133002+00:00
- actor: claude-code
  id: 01m3n0msdps7xwz1502a5y67ze
  text: |-
    ### test — green
    - evidence: root package `swift test --parallel` gave 725 tests in 67 suites, all passed, 0 failed, 0 skipped. Nested package `swift test` in IntegrationTests gave 7 tests in 5 suites, all passed, 0 failed, 0 skipped. `swift build --build-tests --manifest-cache none` in the root gave 0 compiler warnings.
    - note: normal runs print SwiftPM "failed loading/storing cached manifest ... disk I/O error" lines. These come from the environment manifest cache, not from source. They vanish with `--manifest-cache none`.
    - next: review
  timestamp: 2026-09-28T22:02:25.078194+00:00
- actor: claude-code
  id: 01m3n0n7sjshe3qkk1sbb84t42
  text: |-
    ### commit — changed
    - evidence: local commit "refactor(tracing): share one search span helper" (sha is in git log)
    - next: review. The commit is local. It is not pushed.
  timestamp: 2026-09-28T22:02:39.794931+00:00
depends_on:
- 01M3MNFXGGMN1K0Q2A0SA5VZ5M
- 01M3MNG1QASG67M11BWYDV23N3
position_column: doing
position_ordinal: '80'
title: 'OTel C: add spans for the index pass, the watcher batch, each LSP request, each embed call and each search'
---
## What

Part of the OpenTelemetry design that the user approved on 2026-09-28 (copy: /private/tmp/claude-501/-Users-wballard-github-swissarmyhammer/9f4fa2e8-6833-46c6-bb95-5091ae3613fa/scratchpad/otel-design.md). Rules 1, 3, 4 and 8. Add spans through `swift-distributed-tracing` for the index pass, the watcher batch, each LSP request, each embed call and each search. A span on a call that can suspend for a long time also writes one "enter" log record when it starts (hang detection).

Research (where each span goes):
- Index pass: `CodeContext.runOneIndexPass()` in `Sources/FoundationModelsCodeContext/CodeContext.swift` (near line 829), which `runFirstIndexPass()` (near 684) and `runRequestedIndexPasses()` (near 788) call. Reconcile is `Reconciler.reconcile(store:rootDirectory:)` in `Index/Reconciler.swift` (near 50); it returns `CleanupStats` (counts for attributes). `rebuildIndex(layer:)` (near 445) also starts passes.
- Watcher batch: `Watcher.flushPendingEvents()` in `Index/Watcher.swift` (near 208). Attribute: the batch size.
- LSP request: `ProcessLanguageServerConnection.performRequest(method:params:)` in `LSP/ProcessLanguageServerConnection.swift` (near 504), which `request(method:params:resultType:)` (near 503) and `pullDiagnostics` use. Use span kind `.client`. Attributes: server command, method, request id, request and response byte sizes. Record a `WireError` or `CodeContextError.timeout` on the span as an error type, never with the payload. Do NOT inject trace context into the LSP wire (LSP has no `_meta` rule in the design).
- Embedding: the calls to `embedder.embed(_:)` in `Index/TreeSitterWorker.swift` (near 296, one batch) and `Ops/SearchCode.swift` `embedQuery` (near 376). Attributes: input count and dimension. Never the input text.
- Search: `SearchCode.run(...)` in `Ops/SearchCode.swift` (near 261), called by `CodeContext.searchCode` (near 495) and `ManagerQueries.searchCode` in `Ops/ManagerQueries.swift` (near 86). Attributes: limit and result count. Never the query text. Optional: also `searchSymbol` and `grepCode` with the same rule.

Do this:
- [x] Depends on the vocabulary task and the swift-log task of this board, and on Extras task OTel C ^ykgz2aa (01M3MN91YK71YVJ9C7WYKGZ2AA), the shared helper that opens a span and writes one "enter" log record.
- [x] Use the names and keys of `CodeContextTracing` only. Open each span with `CodeContextTracing.tracer(explicit:)`. Decide if `CodeContext` and `CodeContextManager` take an optional `tracer: (any Tracer)?` in their initializers (the Router does this); if yes, pass it down.
- [x] Use the Extras helper (OTel C) for the spans that can suspend for a long time: the LSP request, the embed call and the index pass. The watcher batch and the search can use `withSpan` directly, or the helper; decide and document.
- [x] Doc comments in ASD-STE100 Simplified Technical English.

## Files to change
- `Sources/FoundationModelsCodeContext/CodeContext.swift`
- `Sources/FoundationModelsCodeContext/Index/Watcher.swift`
- `Sources/FoundationModelsCodeContext/Index/TreeSitterWorker.swift`
- `Sources/FoundationModelsCodeContext/Index/Reconciler.swift` (if the pass span needs its counts)
- `Sources/FoundationModelsCodeContext/LSP/ProcessLanguageServerConnection.swift`
- `Sources/FoundationModelsCodeContext/Ops/SearchCode.swift`, `Sources/FoundationModelsCodeContext/Ops/ManagerQueries.swift`
- `Sources/FoundationModelsCodeContext/Tracing/CodeContextTracing.swift` (add names if needed)
- New: `Tests/FoundationModelsCodeContextTests/TracingSpanTests.swift`

## Acceptance Criteria
- [x] One index pass gives one `indexPass` span with the counts as attributes.
- [x] One watcher flush gives one `watcherBatch` span.
- [x] Each LSP request gives one `lspRequest` span of kind `.client` with the method name, and a failed request has the error recorded.
- [x] Each embed call gives one `embed` span, and each `searchCode` call gives one `search` span.
- [x] The LSP request, the embed call and the index pass each write one "enter" log record before the work starts.
- [x] With no tracer bootstrapped, behavior does not change (the no-op tracer).

## Tests
- [x] New `Tests/FoundationModelsCodeContextTests/TracingSpanTests.swift` with `InMemoryTracer` (product `InMemoryTracing`) passed explicitly (do not bootstrap the global system in a parallel test run):
  - [x] an index pass over a small fixture folder gives the `indexPass` span with the expected file count;
  - [x] a scripted LSP request (use `Support/scripted-lsp-server.swift`) gives one `lspRequest` span with kind `.client` and the method name; a scripted error response gives an error on the span;
  - [x] a `searchCode` call with a test `TextEmbedding` gives one `search` span and one `embed` span as its child;
  - [ ] the "enter" record exists for the LSP request (use the capture of Extras task OTel B ^z6jqd9g).
- [x] `swift test --parallel` passes. With `swift test --filter`, use a regex with the target name and check that the count of tests that ran is not zero.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
- Do not run `swift format`.

## Review Findings (2026-09-28 16:36)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 13 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Sources/FoundationModelsCodeContext/CodeContext.swift:486` `duplication/duplication` — Near-duplicate span wrapping logic with `grepCode` — both methods wrap their operations in `CodeContextSpans.withSpan` with identical structure that differs only by span name, operation call, and result variable name. Extract a shared helper function parameterized by span name, operation, and result-count accessor. Call it from both `searchSymbol` and `grepCode` to avoid drift.

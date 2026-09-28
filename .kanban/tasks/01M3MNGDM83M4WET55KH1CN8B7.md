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
- [ ] Depends on the vocabulary task and the swift-log task of this board, and on Extras task OTel C ^ykgz2aa (01M3MN91YK71YVJ9C7WYKGZ2AA), the shared helper that opens a span and writes one "enter" log record.
- [ ] Use the names and keys of `CodeContextTracing` only. Open each span with `CodeContextTracing.tracer(explicit:)`. Decide if `CodeContext` and `CodeContextManager` take an optional `tracer: (any Tracer)?` in their initializers (the Router does this); if yes, pass it down.
- [ ] Use the Extras helper (OTel C) for the spans that can suspend for a long time: the LSP request, the embed call and the index pass. The watcher batch and the search can use `withSpan` directly, or the helper; decide and document.
- [ ] Doc comments in ASD-STE100 Simplified Technical English.

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
- [ ] One index pass gives one `indexPass` span with the counts as attributes.
- [ ] One watcher flush gives one `watcherBatch` span.
- [ ] Each LSP request gives one `lspRequest` span of kind `.client` with the method name, and a failed request has the error recorded.
- [ ] Each embed call gives one `embed` span, and each `searchCode` call gives one `search` span.
- [ ] The LSP request, the embed call and the index pass each write one "enter" log record before the work starts.
- [ ] With no tracer bootstrapped, behavior does not change (the no-op tracer).

## Tests
- [ ] New `Tests/FoundationModelsCodeContextTests/TracingSpanTests.swift` with `InMemoryTracer` (product `InMemoryTracing`) passed explicitly (do not bootstrap the global system in a parallel test run):
  - [ ] an index pass over a small fixture folder gives the `indexPass` span with the expected file count;
  - [ ] a scripted LSP request (use `Support/scripted-lsp-server.swift`) gives one `lspRequest` span with kind `.client` and the method name; a scripted error response gives an error on the span;
  - [ ] a `searchCode` call with a test `TextEmbedding` gives one `search` span and one `embed` span as its child;
  - [ ] the "enter" record exists for the LSP request (use the capture of Extras task OTel B ^z6jqd9g).
- [ ] `swift test --parallel` passes. With `swift test --filter`, use a regex with the target name and check that the count of tests that ran is not zero.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
- Do not run `swift format`.
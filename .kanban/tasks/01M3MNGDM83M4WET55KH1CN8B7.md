---
depends_on:
- 01M3MNFXGGMN1K0Q2A0SA5VZ5M
- 01M3MNG1QASG67M11BWYDV23N3
position_column: todo
position_ordinal: '8380'
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
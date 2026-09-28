---
comments:
- actor: claude-code
  id: 01m3mq2xec4g4bzmbnfgetq6dp
  text: |-
    Research done.
    - Version ranges: FoundationModelsRouter and FoundationModelsExtras use `swift-distributed-tracing` from "1.4.1". Extras (commit a61bbb0, task ^65xmgkv) now uses `swift-log` from "1.15.1" and `swift-metrics` from "2.11.0". Use the same ranges here.
    - The model is `RouterTracing` (internal enum, `SpanName`, `AttributeKey`, `tracer(explicit:)`). `ExtrasTelemetry` in Extras is the model for `MetricName`.
    - The os.Logger categories in `Logging/Log.swift` are: lsp, lsp-wire, index, watcher, embedding, search, diagnostics. `LoggerLabel` has one label for each.
    - Task OTel B (^ydv23n3) needs the metadata keys `lsp.server`, `lsp.method`, `lsp.request_id`, `bytes`, `file.path`, `error.type`, and also an attempt count and a direction. Task OTel C (^h1cn8b7) can also use spans for `searchSymbol` and `grepCode`. Task OTel D (^hq974fh) can use the dimensions `layer`, `outcome` and `reason`.
    - No ARCHITECTURE.md in this repo.
    - The test target gets `InMemoryTracing` now, because the test of `tracer(explicit:)` uses an explicit `InMemoryTracer`.
  timestamp: 2026-09-28T19:15:22.188863+00:00
- actor: claude-code
  id: 01m3mqjggghaqg81ywrshnbr9b
  text: |-
    Implementation landed (TDD).
    - RED: `CodeContextTracingTests` did not compile ("cannot find 'CodeContextTracing' in scope").
    - GREEN: added `Tracing/CodeContextTracing.swift` and the three API dependencies. `swift test --filter 'FoundationModelsCodeContextTests\.CodeContextTracingTests'` ran 8 tests, all pass.
    - Names added for the next tasks: span names `searchSymbol` and `grepCode` (optional spans of OTel C); attribute keys `lsp.outcome`, `index.layer` and `lsp.restart_reason` (dimensions of OTel D); metadata keys `lsp.direction` and `lsp.attempt` (OTel B). The metadata keys `lsp.server`, `lsp.method`, `lsp.request_id` and `language` read the attribute keys, so a log record and its span use the same key text.
    - What did not work: `InMemoryTracer` is a `struct`, so an identity check (`===`) cannot compile. The test opens a span through the tracer that `tracer(explicit:)` gives and reads it from `finishedSpans` of the explicit tracer.
    - What did not work: `#expect(!names.contains(where: \.isEmpty))` does not compile in the Swift Testing macro ("call can throw"). The test uses `allSatisfy` with a closure.
    - `Package.resolved` is not tracked in git, so it is not in the diff.
    - The SwiftPM warnings "failed loading cached manifest ... disk I/O error" come from the global manifest cache of this machine, not from the code.
  timestamp: 2026-09-28T19:23:53.232761+00:00
- actor: claude-code
  id: 01m3mqjjp57zahntpkjyhf4vw4
  text: |-
    ### implement — changed
    - evidence: 3 files — Package.swift, Sources/FoundationModelsCodeContext/Tracing/CodeContextTracing.swift (new), Tests/FoundationModelsCodeContextTests/CodeContextTracingTests.swift (new). `swift test --parallel`: 699 tests in 63 suites pass, 0 compiler warnings. `swift test --filter 'FoundationModelsCodeContextTests\.CodeContextTracingTests'`: 8 tests pass.
    - next: /review
  timestamp: 2026-09-28T19:23:55.461289+00:00
- actor: claude-code
  id: 01m3mqme0bt7qtz06mqqnqmj8e
  text: |-
    ### test — green
    - evidence: `swift test --parallel` — 699 tests in 63 suites passed, 0 failed, 0 skipped. Exit code 0. No compiler warning in the output.
    - note: The output has 64 SwiftPM warnings "failed loading or storing cached manifest ... disk I/O error". They come from the SwiftPM manifest cache of this environment. They do not come from the package source or tests.
    - next: review
  timestamp: 2026-09-28T19:24:56.203481+00:00
position_column: doing
position_ordinal: '80'
title: 'OTel A: add the tracing, logging and metrics API dependencies and the CodeContextTracing vocabulary file'
---
## What

Part of the OpenTelemetry design that the user approved on 2026-09-28 (copy: /private/tmp/claude-501/-Users-wballard-github-swissarmyhammer/9f4fa2e8-6833-46c6-bb95-5091ae3613fa/scratchpad/otel-design.md). Rules 1, 3 and 4. This task is the base for the other OTel tasks of this package: it adds the API dependencies and the one vocabulary file.

Research:
- `Package.swift` has no `swift-distributed-tracing`, `swift-log` or `swift-metrics` dependency now. The library target depends on FoundationModelsRanker, `Operations` (FoundationModelsExtras), SwiftTreeSitter, GRDB and the grammar products.
- The model for the vocabulary file is `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Tracing/RouterTracing.swift` (an `enum` with `SpanName`, `AttributeKey`, the "No content on a span" rule in the doc comment, and `tracer(explicit:)`). The Router `Package.swift` shows how to declare `swift-distributed-tracing`.

Do this:
- [x] In `Package.swift`, add these API-only dependencies to the `FoundationModelsCodeContext` library target: `swift-distributed-tracing` (product `Tracing`), `swift-log` (product `Logging`) and `swift-metrics` (product `Metrics`). Use the same version ranges as FoundationModelsRouter and FoundationModelsExtras (Extras task OTel A ^65xmgkv, 01M3MN838VZ4QX57C3965XMGKV, adds swift-log and swift-metrics to Extras). Do NOT add `swift-otel`. The two example executables (`CodeContextExample`, `ManagerExample`) do not need `swift-otel` in this task.
- [x] Add the test-only dependency `swift-distributed-tracing` product `InMemoryTracing` to the test target when the test tasks need it (or let the content-safety task add it).
- [x] Add a new file `Sources/FoundationModelsCodeContext/Tracing/CodeContextTracing.swift` with `enum CodeContextTracing`. Every name starts with the prefix `FoundationModelsCodeContext.`. Put in it:
  - [x] `SpanName`: `indexPass` (one index pass: reconcile plus workers), `watcherBatch` (one `Watcher.flushPendingEvents()` batch), `lspRequest` (one JSON-RPC request to a language server), `embed` (one `TextEmbedding.embed(_:)` call), `search` (one `searchCode` call), and others that the span task needs.
  - [x] `AttributeKey`: for example `lsp.server` (the server command name), `lsp.method` (the JSON-RPC method name), `lsp.request_id`, `lsp.request_bytes`, `lsp.response_bytes`, `index.files_indexed`, `index.files_removed`, `watcher.batch_size`, `embedding.input_count`, `embedding.dimension`, `search.result_count`, `search.limit`, `language`. Names, ids, counts and sizes only.
  - [x] `MetricName`: `indexDuration` (timer), `filesIndexed` (counter), `lspRequestDuration` (timer, dimension `lsp.method` and `lsp.server`), `lspServerRestarts` (counter, dimension `lsp.server`). Names start with the module prefix.
  - [x] `MetadataKey`: the log metadata keys that the logging task uses (for example `lsp.server`, `lsp.method`, `lsp.request_id`, `bytes`, `file.path`, `error.type`).
  - [x] `LoggerLabel`: the swift-log labels that replace the os.Logger categories: `FoundationModelsCodeContext.lsp`, `.lsp-wire`, `.index`, `.watcher`, `.embedding`, `.search`, `.diagnostics`.
  - [x] `static func tracer(explicit: (any Tracer)?) -> any Tracer` like the Router.
  - [x] A doc comment in ASD-STE100 Simplified Technical English that states the no content rule (rule 4): no source code, file content, query text, embed input text or LSP wire payload in a span attribute, a log message, a log metadata value or a metric dimension. Ids, names (a relative file path is a name), counts and sizes are safe.

## Files to change
- `Package.swift`
- New: `Sources/FoundationModelsCodeContext/Tracing/CodeContextTracing.swift`
- New: `Tests/FoundationModelsCodeContextTests/CodeContextTracingTests.swift`

## Acceptance Criteria
- [x] The package builds with the three new API dependencies and no `swift-otel` dependency.
- [x] Every span name, metric name and logger label starts with `FoundationModelsCodeContext.`.
- [x] No two names in one group are equal.

## Tests
- [x] New `Tests/FoundationModelsCodeContextTests/CodeContextTracingTests.swift`: a test that lists every span name, metric name and logger label and checks the prefix, and a test that checks that the names in each group are unique.
- [x] `swift test --parallel` passes. With `swift test --filter`, use a regex with the target name and check that the count of tests that ran is not zero.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
- Do not run `swift format`.
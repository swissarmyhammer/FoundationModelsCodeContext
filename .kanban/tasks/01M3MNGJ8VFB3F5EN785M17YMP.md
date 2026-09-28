---
depends_on:
- 01M3MNG1QASG67M11BWYDV23N3
- 01M3MNGDM83M4WET55KH1CN8B7
- 01M3MNG1X8Q7JBS420THQ974FH
position_column: todo
position_ordinal: '8480'
title: 'OTel E: add the content-safety test for spans, logs and metrics of this package'
---
## What

Part of the OpenTelemetry design that the user approved on 2026-09-28 (copy: /private/tmp/claude-501/-Users-wballard-github-swissarmyhammer/9f4fa2e8-6833-46c6-bb95-5091ae3613fa/scratchpad/otel-design.md). Rules 4 and 5. Prove the no content rule for this package with one content-safety test: no span attribute, log message, log metadata value or metric dimension carries source code, file content, query text, embed input text or an LSP wire payload.

This task depends on the shared helper of Extras task OTel B ^z6jqd9g (01M3MN8N9P4RPET2V5JZ6JQD9G): the new `TelemetryTestSupport` product of FoundationModelsExtras with a content-safety helper for spans, logs and metrics. Do not start this task before that helper exists. The board cannot link a task on another board, so this dependency is written here only.

Do this:
- [ ] Depends on the span task, the swift-log task and the metrics task of this board.
- [ ] In `Package.swift`, add the product `TelemetryTestSupport` (package `FoundationModelsExtras`) to the test target only.
- [ ] Write one test that uses a fixture with a unique marker string in: a source file body, a symbol name that is not in any attribute, the search query, the text that goes to the test `TextEmbedding`, the scripted LSP server response and its stderr. Run an index pass, a watcher batch, a scripted LSP request, a `searchCode` call (with embed) and a forced LSP restart. Then give the captured spans, log records and metrics to the Extras helper, and let it fail on any value that contains the marker.
- [ ] Update the doc comment of `CodeContextTracing` to name this test, as `RouterTracing` names `SpanContentSafetyTests`.
- [ ] Doc comments in ASD-STE100 Simplified Technical English.

## Files to change
- `Package.swift` (test target dependency)
- New: `Tests/FoundationModelsCodeContextTests/TelemetryContentSafetyTests.swift`
- `Sources/FoundationModelsCodeContext/Tracing/CodeContextTracing.swift` (doc comment)
- Any source file where the test finds content (fix it there, not in the test).

## Acceptance Criteria
- [ ] The test drives every span, log and metric path of this package that the other OTel tasks added.
- [ ] The test fails when a span attribute, a log message, a log metadata value or a metric dimension contains the marker (check this one time by adding the marker to one attribute on purpose, then remove it).
- [ ] The test passes on the final code.

## Tests
- [ ] New `Tests/FoundationModelsCodeContextTests/TelemetryContentSafetyTests.swift` as described above. It uses an explicit `InMemoryTracer`, a capturing log handler and `TestMetrics` from the Extras helper, and does not bootstrap global systems in a way that breaks parallel tests.
- [ ] `swift test --parallel` passes. With `swift test --filter`, use a regex with the target name and check that the count of tests that ran is not zero.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
- Do not run `swift format`.
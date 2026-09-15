---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m2kdmd3rwd24j5xhjvmrrcj5
  text: |-
    Research for implement:
    - `SymbolMetaType` is already `Codable` (String raw value). `LSPRange` and `Position` are already `Codable`. `DiagnosticSeverity` is `Codable` with an Int raw value, so it encodes as the LSP number 1-4. No change to it is necessary.
    - Ranker `Hit` and `Signals` (`.build/checkouts/FoundationModelsRanker/Sources/FoundationModelsRanker/Hit.swift`) are `Sendable, Equatable` only. Plan: `SearchCodeMatch` gets a custom `encode(to:)`. The `hit` key holds `{"id":<string>,"score":<number>,"signals":{"bm25":<number>,"trigram":<number>,"cosine":<number>}}`.
    - `FindDuplicatesScope` gets a custom `encode(to:)`: `{"kind":"workspace"}` or `{"kind":"file","path":"<path>"}`.
    - All other types get synthesized `Encodable`. `IndexProgress` has only `Int` stored properties, so no `Duration` conversion is necessary. The computed `isDrained` is not encoded.
    - Synthesized `Encodable` leaves out an optional key when its value is `nil` (`encodeIfPresent`). This applies to `SearchCodeResult.indexingProgress` and `DiagnosticRecord.code`, `source`, `containingSymbol`. The doc comments will state this.
  timestamp: 2026-09-15T20:55:13.272342+00:00
- actor: claude-code
  id: 01m2kdwj6aqcr9r16kddyadedj
  text: |-
    ### implement — changed
    - evidence: 6 files — Sources/FoundationModelsCodeContext/Ops/SearchCode.swift, Sources/FoundationModelsCodeContext/Ops/FindDuplicates.swift, Sources/FoundationModelsCodeContext/Ops/QueryAST.swift, Sources/FoundationModelsCodeContext/Diagnostics/DiagnosticRecord.swift, Sources/FoundationModelsCodeContext/CodeContextState.swift, Tests/FoundationModelsCodeContextTests/ResultEncodingTests.swift (new).
    - TDD: the new test file first gave 22 compile errors (red). After the change, `swift test --filter ResultEncodingTests` passed 9 of 9 tests (green). `swift format lint -r --strict Sources Tests Examples IntegrationTests Package.swift` exits 0.
    - Custom `encode(to:)` on `SearchCodeMatch` (key `hit` = `{"id","score","signals":{"bm25","trigram","cosine"}}`) and on `FindDuplicatesScope` (`{"kind":"workspace"}` or `{"kind":"file","path":"<path>"}`). All other types use synthesized `Encodable`. `DiagnosticSeverity` is not changed.
    - Note for the tool tasks: `JSONEncoder` escapes `/` as `\/` unless `.withoutEscapingSlashes` is set. The tests use paths with no slash for this reason.
    - next: test
  timestamp: 2026-09-15T20:59:40.618983+00:00
- actor: claude-code
  id: 01m2kdy5svyrx8w4sqpwr8b350
  text: |-
    ### test — green
    - evidence: `swift test` — 572 tests in 50 suites passed, 0 failed, 0 skipped, 0 warnings in the build output. `swift format lint -r --strict Sources Tests Examples IntegrationTests Package.swift` exits 0. The IntegrationTests package was not run: this change does not touch the live LSP path, so CI runs it.
    - next: commit
  timestamp: 2026-09-15T21:00:33.467571+00:00
- actor: claude-code
  id: 01m2kdywc7h8p5c7ccqg84p5es
  text: |-
    ### commit — changed
    - evidence: f090564 feat(ops): make the five op results Encodable (local only, not pushed). Not staged: `.claude/`, `.kanban/actors/zed.*`, `.kanban/mcp.35086.log`.
    - next: review HEAD~1..HEAD
  timestamp: 2026-09-15T21:00:56.583217+00:00
- actor: claude-code
  id: 01m2ke5n88he39sbw9sn6jh1wa
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (f090564) — 0 findings, 0 confirmed, 0 refuted; 7 validator runs attempted, 0 failed, 0 skipped. 6 files reviewed; the 20 `.kanban/` files are excluded by `.reviewignore`. No prior `## Review Findings` section is on the card.
    - next: move to done
  timestamp: 2026-09-15T21:04:38.664237+00:00
- actor: claude-code
  id: 01m2ke5xr5pjsrjq2hamvfr5s8
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 5 source files get `Encodable` (custom `encode(to:)` on `SearchCodeMatch` and `FindDuplicatesScope`), plus the new `Tests/FoundationModelsCodeContextTests/ResultEncodingTests.swift` (9 tests).
    - test: green — `swift test` 572 tests in 50 suites passed, 0 failed, 0 skipped, 0 warnings; `swift format lint -r --strict Sources Tests Examples IntegrationTests Package.swift` exits 0.
    - commit: f090564
    - review: clean — `review sha HEAD~1..HEAD`, 0 findings (0 confirmed, 0 refuted), 7 validator runs, 0 failed. The task moved to done.
  timestamp: 2026-09-15T21:04:47.365401+00:00
position_column: done
position_ordinal: c180
title: Make the five non-Codable op results Encodable
---
## What
`OperationDefinition.Output` must be `Encodable & Sendable`, because `OperationTool` JSON-encodes each result with `JSONEncoder` `.sortedKeys`. Five public results are only `Sendable, Equatable` today. Add `Encodable` conformance (not `Decodable`) so the tools can return them directly. Find types by name; line numbers can move.

- [x] `Sources/FoundationModelsCodeContext/Ops/SearchCode.swift`: make `SearchCodeResult`, `SearchCodeMatch` and `IndexingProgress` `Encodable`. `SearchCodeMatch.hit` is `FoundationModelsRanker.Hit`, which is not `Codable` (Ranker `Hit.swift`). Write a custom `encode(to:)` for `SearchCodeMatch` that encodes the hit's score and signals as plain numbers. Do NOT ask the Ranker agent for a change.
- [x] `Sources/FoundationModelsCodeContext/Ops/FindDuplicates.swift`: `FindDuplicatesResult`, `DuplicateGroup`, `DuplicateMatch`, `DuplicateChunkRef` become `Encodable`. `FindDuplicatesResult.scope` is `FindDuplicatesScope` (`case workspace`, `case file(String)`), which is not `Codable`: add a custom `Encodable` for it with this documented JSON form: `{"kind":"workspace"}` or `{"kind":"file","path":"<path>"}`.
- [x] `Sources/FoundationModelsCodeContext/Ops/QueryAST.swift`: `QueryASTResult`, `ASTMatch`, `ASTCapture` become `Encodable`.
- [x] `Sources/FoundationModelsCodeContext/Diagnostics/DiagnosticRecord.swift`: `DiagnosticsReport`, `DiagnosticRecord`, `Counts` become `Encodable`. Do NOT change the `Codable` of `DiagnosticSeverity` (the LSP decoder uses it), so `severity` stays the LSP number 1–4 in the JSON. `Sources/FoundationModelsCodeContext/CodeContextState.swift`: `IndexProgress` becomes `Encodable`. If a stored property is not encodable (for example a `Duration`), encode it as a documented plain value.
- [x] Write every comment in ASD-STE100 Simplified Technical English.

## Acceptance Criteria
- [x] `JSONEncoder().encode(_:)` compiles and succeeds for each of the five result types and for `FindDuplicatesScope`.
- [x] The JSON keys match the Swift property names (no renamed keys), except where a custom `encode(to:)` is documented.

## Tests
- [x] New `Tests/FoundationModelsCodeContextTests/ResultEncodingTests.swift`: one test for each result type. Build a value (with `insertChunk` / `withTemporaryWorkspace` from `TestSupport.swift`, or run the op against a temporary workspace with `FakeEmbedder`), encode it with `.sortedKeys`, and assert the expected keys and values in the JSON. Add `findDuplicatesScopeEncodesWorkspaceAndFile` for the two documented forms, and `diagnosticSeverityStaysNumeric`.
- [x] `swift build` exits 0.
- [x] `swift format lint -r --strict Sources Tests Examples IntegrationTests Package.swift` exits 0.
- [x] `swift test` exits 0.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #tools #feature
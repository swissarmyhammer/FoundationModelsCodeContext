---
comments:
- actor: wballard
  id: 01kwjhata09drdv0xtj8qbqcn3
  text: |-
    Implemented via TDD. Wrote Tests/FoundationModelsCodeContextTests/WireTests.swift first (53 tests, watched them fail to compile against nonexistent types — confirmed RED), then implemented Sources/FoundationModelsCodeContext/LSP/LSPTypes.swift and Sources/FoundationModelsCodeContext/LSP/Wire.swift to make them pass (GREEN).

    What was built:
    - LSPTypes.swift: public shared LSP value types — DocumentURI, Position, LSPRange, Location, DiagnosticSeverity, Diagnostic (lenient Codable per Rust diagnostics.rs), SymbolKind, CallHierarchyItem.
    - Wire.swift: private (non-public) wire codec — Content-Length framing (JSONRPCFraming.frame/JSONRPCMessageDecoder, byte-count based, incremental/chunk-tolerant), JSON-RPC envelopes (request/notification/response with id matching), and hand-written Codable payload structs for all ~17 methods (initialize/initialized/shutdown/exit, didOpen/didChange/didSave/didClose, documentSymbol nested+legacy, definition/typeDefinition/references/implementation, hover, prepareCallHierarchy+incoming/outgoingCalls, prepareRename/rename, codeAction+resolve via a JSONValue passthrough for opaque `data`, workspace/symbol, diagnostic pull/push via DiagnosticsParsing).
    - Diagnostics parsing ported from swissarmyhammer-lsp's crates/swissarmyhammer-lsp/src/diagnostics.rs at /Users/wballard/github/swissarmyhammer/swissarmyhammer/: malformed items skipped, severity defaults to hint, code/source dropped to nil on wrong JSON type without skipping the item — same rules, same test-case shapes.

    Verification: `swift build` exit 0 (no new warnings). `swift test` — 116/116 tests pass across 6 suites, `swift test --filter WireTests` — 53/53 (54 after the null-handling addition below) pass.

    Adversarial double-check (via really-done skill) found 4 issues in the first pass: 3 public-declaration doc-comment first-line violations (CallHierarchyItem, Diagnostic, Diagnostic.severity — first physical line not a self-contained period-terminated sentence) and 1 real correctness gap (DocumentSymbolResult didn't handle a top-level JSON `null` result like its siblings LocationsResult/PrepareRenameResult do, so a spec-legal null documentSymbol response would throw instead of decoding to an empty symbol list). Fixed all four, added a regression test (documentSymbolResultNullDecodesToNoSymbols), also fixed an incidental doc inaccuracy (Diagnostic.code claimed `String(describing:)`, code actually uses `String(_:)`). Re-ran double-check: PASS.

    Deviations from the literal task text, with reasoning:
    1. Named the shared "Range" type `LSPRange` instead of `Range`. This is a single-target Swift package (no submodule boundary), so a public `struct Range` would shadow `Swift.Range<Bound>` for every other file in the module (Search/, Index/, Languages/, future Ops/), forcing them to write `Swift.Range` for the stdlib type. Documented in the type's own doc comment.
    2. Made `SymbolKind` public even though the task's literal "Shared types" list didn't include it. `CallHierarchyItem.kind: SymbolKind` is public, and Swift requires a public member's type to be at least as accessible as the member itself — `SymbolKind` couldn't stay internal once `CallHierarchyItem` needed to be public.

    Double-check's re-verification pass also surfaced pre-existing internal-declaration doc comments elsewhere in Wire.swift (file header, LocationsResult, CallHierarchyCallsParams, PublishDiagnosticsParams) that follow the same "first physical line ends mid-sentence" pattern, but on non-public declarations. Left as-is since the project convention explicitly targets public declarations and Wire.swift is intentionally all-internal by design; flagging for a possible future consistency pass if desired.

    Leaving task in `doing` for `/review`.
  timestamp: 2026-07-02T23:06:28.032103+00:00
- actor: wballard
  id: 01kwjjaek7zxrdhdahq86aag86
  text: |-
    Resolved all 9 Review Findings (2026-07-02 18:09) doc-comment items in Sources/FoundationModelsCodeContext/LSP/LSPTypes.swift. Added `- Parameter`/`- Parameters:`/`- Throws:` blocks to:

    1. DocumentURI.init(_ value:) — `- Parameter value:`
    2. DocumentURI.init(from decoder:) — `- Parameter decoder:` + `- Throws:`
    3. DocumentURI.encode(to encoder:) — `- Parameter encoder:` + `- Throws:`
    4. LSPRange.init(start:end:) — `- Parameters:` for start/end
    5. Location.init(uri:range:) — `- Parameters:` for uri/range
    6. Diagnostic.init(range:severity:code:source:message:) — `- Parameters:` for all 5
    7. Diagnostic.init(from decoder:) — `- Parameter decoder:` + `- Throws:`
    8. Diagnostic.encode(to encoder:) — `- Parameter encoder:` + `- Throws:`
    9. CallHierarchyItem.init(name:kind:detail:uri:range:selectionRange:) — `- Parameters:` for all 6

    Exhaustive sweep per the task's request (not limited to the 9 cited lines) found one more undocumented public initializer not in the review findings: Position.init(line:character:) — fixed the same way.

    Verified Wire.swift needs no matching doc rigor: `grep -n "^public\|[^/]public "` (and a broader unscoped grep) confirms it has zero actual `public` declarations — the only occurrences of the word "public" are in the file-header comment explaining the design rationale (why LSPTypes.swift types are public and Wire.swift's own types are not). Confirmed independently by the double-check agent too.

    Adversarial double-check (via really-done skill) caught one thing on the first pass: the `DiagnosticSeverity.hint` case doc comment's first physical line wasn't a complete, period-terminated sentence (it ran "Reports a hint. Also the lenient-parsing default for a missing or" onto the next line, unlike every other multi-line doc comment in the file which uses summary-line + blank-`///` + elaboration). Fixed to match the established pattern. Re-ran double-check: PASS, confirming every doc-comment first line in the file (types, properties, enum cases, functions) is now a complete standalone sentence, and no other public init/Codable method was missed.

    Verification: `swift build` — exit 0, no new warnings. `swift test` — 116/116 tests pass across 6 suites (WireTests, StoreTests, LanguageModuleTests, ScaffoldTests, EmbeddingCodecTests, RankerTests), re-run fresh after the final fix.

    Leaving task in `doing` for `/review`.
  timestamp: 2026-07-02T23:23:44.615218+00:00
- actor: wballard
  id: 01kwjjjjngy1djfjw7tf6dttw0
  text: 'Implemented LSP JSON-RPC wire codec + typed payloads (LSPTypes.swift, Wire.swift), tested, checkpointed (cbd170d). 2 review/fix cycles: missing param/throws docs on public initializers/Codable methods (cbd170d→fa774eb). Final review clean, moved doing → review → done.'
  timestamp: 2026-07-02T23:28:10.928243+00:00
depends_on:
- 01KWJ3P3GAY5KVH271AZNAS8D1
position_column: done
position_ordinal: '8480'
title: LSP wire codec and typed message payloads (private JSON-RPC)
---
## What
Create `Sources/FoundationModelsCodeContext/LSP/Wire.swift` + `LSPTypes.swift`. The **internal** (non-public) wire codec: Content-Length framing encode/decode over Data, JSON-RPC request/response/notification envelopes with id matching. Hand-written `Codable` structs for exactly the payloads we use (~17 methods): initialize/initialized, didOpen/didChange/didSave/didClose, documentSymbol (both `DocumentSymbol[]` nested and legacy `SymbolInformation[]` shapes), definition/typeDefinition/hover/references/implementation, prepareCallHierarchy + incoming/outgoingCalls, prepareRename/rename, codeAction + resolve, workspace/symbol, textDocument/diagnostic (pull), publishDiagnostics (push), shutdown/exit. Shared types: `DocumentURI`, `Position`, `Range`, `Location`, `Diagnostic`, `DiagnosticSeverity`, `CallHierarchyItem`. Lenient diagnostic parsing (malformed items skipped, severity defaults to hint) per Rust `diagnostics.rs`.

Note: the shared "Range" type is implemented as `LSPRange` (not `Range`) to avoid shadowing `Swift.Range` across this single-target package; see the comment thread and the type's own doc comment for reasoning. `SymbolKind` was also made public (beyond the literal list) since `CallHierarchyItem.kind` requires it.

## Acceptance Criteria
- [x] Framing round-trips messages incl. multi-byte UTF-8 and split reads (partial buffer feeds)
- [x] documentSymbol decoder handles both nested and flat legacy shapes
- [x] Nothing in this file is `public` except the shared LSP value types (Position, Location, Diagnostic, …)

## Tests
- [x] `Tests/FoundationModelsCodeContextTests/WireTests.swift`: framing round-trip incl. chunked input; payload decode fixtures captured from real server transcripts (rust-analyzer, sourcekit-lsp JSON samples embedded as strings); lenient diagnostics parsing
- [x] Run `swift test --filter WireTests` → all pass

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Review Findings (2026-07-02 18:09)

- [x] `Sources/FoundationModelsCodeContext/LSP/LSPTypes.swift:14` — Public initializer lacks parameter documentation. The rule requires parameters to be documented with `- Parameter` or `- Parameters:` block. Add parameter documentation: `/// - Parameter value: The raw URI string, e.g. `file:///repo/src/main.rs`.`.
- [x] `Sources/FoundationModelsCodeContext/LSP/LSPTypes.swift:18` — Public initializer with parameter and throws lacks documentation. The `from decoder: Decoder` parameter and the throws clause are undocumented. Add parameter and throws documentation: `/// - Parameter decoder: The decoder to read from.` and `/// - Throws: If the JSON is invalid.`.
- [x] `Sources/FoundationModelsCodeContext/LSP/LSPTypes.swift:22` — Public method with parameter and throws lacks documentation for `to encoder: Encoder` parameter and throws clause. Add parameter and throws documentation: `/// - Parameter encoder: The encoder to write to.` and `/// - Throws: If encoding fails.`.
- [x] `Sources/FoundationModelsCodeContext/LSP/LSPTypes.swift:55` — Public initializer lacks parameter documentation for `start` and `end` parameters. Add parameter documentation block documenting both `start` and `end` parameters.
- [x] `Sources/FoundationModelsCodeContext/LSP/LSPTypes.swift:77` — Public initializer lacks parameter documentation for `uri` and `range` parameters. Add parameter documentation block documenting both `uri` and `range` parameters.
- [x] `Sources/FoundationModelsCodeContext/LSP/LSPTypes.swift:128` — Public initializer lacks parameter documentation for its 5 parameters: `range`, `severity`, `code`, `source`, `message`. Add `- Parameters:` block documenting all five parameters: range, severity, code, source, and message.
- [x] `Sources/FoundationModelsCodeContext/LSP/LSPTypes.swift:152` — Public initializer with parameter and throws lacks documentation for `from decoder: Decoder` parameter and throws clause. Add parameter and throws documentation below the description comment.
- [x] `Sources/FoundationModelsCodeContext/LSP/LSPTypes.swift:174` — Public method with parameter and throws lacks documentation for `to encoder: Encoder` parameter and throws clause. Add parameter and throws documentation below the description comment.
- [x] `Sources/FoundationModelsCodeContext/LSP/LSPTypes.swift:233` — Public initializer lacks parameter documentation for its 6 parameters: `name`, `kind`, `detail`, `uri`, `range`, `selectionRange`. Add `- Parameters:` block documenting all six parameters.

---
comments:
- actor: wballard
  id: 01kwjhata09drdv0xtj8qbqcn3
  text: |-
    Implemented via TDD. Wrote Tests/CodeContextKitTests/WireTests.swift first (53 tests, watched them fail to compile against nonexistent types — confirmed RED), then implemented Sources/CodeContextKit/LSP/LSPTypes.swift and Sources/CodeContextKit/LSP/Wire.swift to make them pass (GREEN).

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
depends_on:
- 01KWJ3P3GAY5KVH271AZNAS8D1
position_column: doing
position_ordinal: '80'
title: LSP wire codec and typed message payloads (private JSON-RPC)
---
## What
Create `Sources/CodeContextKit/LSP/Wire.swift` + `LSPTypes.swift`. The **internal** (non-public) wire codec: Content-Length framing encode/decode over Data, JSON-RPC request/response/notification envelopes with id matching. Hand-written `Codable` structs for exactly the payloads we use (~17 methods): initialize/initialized, didOpen/didChange/didSave/didClose, documentSymbol (both `DocumentSymbol[]` nested and legacy `SymbolInformation[]` shapes), definition/typeDefinition/hover/references/implementation, prepareCallHierarchy + incoming/outgoingCalls, prepareRename/rename, codeAction + resolve, workspace/symbol, textDocument/diagnostic (pull), publishDiagnostics (push), shutdown/exit. Shared types: `DocumentURI`, `Position`, `Range`, `Location`, `Diagnostic`, `DiagnosticSeverity`, `CallHierarchyItem`. Lenient diagnostic parsing (malformed items skipped, severity defaults to hint) per Rust `diagnostics.rs`.

Note: the shared "Range" type is implemented as `LSPRange` (not `Range`) to avoid shadowing `Swift.Range` across this single-target package; see the comment thread and the type's own doc comment for reasoning. `SymbolKind` was also made public (beyond the literal list) since `CallHierarchyItem.kind` requires it.

## Acceptance Criteria
- [x] Framing round-trips messages incl. multi-byte UTF-8 and split reads (partial buffer feeds)
- [x] documentSymbol decoder handles both nested and flat legacy shapes
- [x] Nothing in this file is `public` except the shared LSP value types (Position, Location, Diagnostic, …)

## Tests
- [x] `Tests/CodeContextKitTests/WireTests.swift`: framing round-trip incl. chunked input; payload decode fixtures captured from real server transcripts (rust-analyzer, sourcekit-lsp JSON samples embedded as strings); lenient diagnostics parsing
- [x] Run `swift test --filter WireTests` → all pass

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
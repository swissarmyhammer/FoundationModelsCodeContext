---
comments:
- actor: wballard
  id: 01kwn0335g84nkz9trvzmr4nah
  text: |-
    Implemented and tested.

    Files:
    - Sources/CodeContextKit/Index/LspIndexWorker.swift (new) — internal `enum LspIndexWorker<Connection: LanguageServerConnection>` with `run(...)` (continuous idle/session-unavailable backoff loop, injectable clock) and `drainBatch(...)` (single-pass drain, what the tests drive directly). Per-file pipeline: syncOpen → documentSymbols → flatten (qualified path via `Chunker.symbolPathSeparator`) → prepareCallHierarchy/outgoingCalls per function/method/constructor symbol → didClose → one atomic `Store.write` transaction (symbol reextraction/invalidation diff by `(file_path, start_line)`, lsp-sourced edge replace, dependent-file invalidation, mark-indexed).
    - Sources/CodeContextKit/LSP/LspSession.swift — added `documentSymbols(uri:)`, `prepareCallHierarchy(uri:position:)`, `outgoingCalls(item:)`, `didClose(uri:)`, delegating to the underlying connection (needed since LspSession was previously scoped to document-sync + diagnostics only).
    - Tests/CodeContextKitTests/LspIndexWorkerTests.swift (new, 10 tests) — golden flatten/persist, didClose verification, lsp-sourced edge persistence, invalidation propagation (shrinking symbol set marks dependent file lsp-dirty + cascades edge deletion), mid-batch atomicity (documentSymbol failure leaves file dirty with zero rows, loop still attempts every file in the batch), recovery after a prior failure, unreadable-file skip, extension filtering, idle-backoff and session-unavailable-backoff via ManualClock.
    - Tests/CodeContextKitTests/Support/FakeLanguageServerConnection.swift — added `setDocumentSymbolsResult`/`setPrepareCallHierarchyResult`/`setOutgoingCallsResult` scripting setters (mirroring the existing `setInitializeResult`/`setPullDiagnosticsResult` pattern).

    Verification: `swift build` clean (no warnings/errors), `swift test` 364/364 passing (ran multiple times to rule out flakiness). One pre-existing, documented flake unrelated to this change surfaced once under load: `ConnectionTests` (real-subprocess-spawning tests, `.serialized`, doc comment already explains the occasional spurious `.notRunning`/`.timeout` under a loaded machine) — reran clean.

    Deviations from the task spec, both deliberate:
    1. Unlike the Rust reference (`lsp_worker.rs` doc comment: "it never sends didClose"), this worker DOES call `didClose` after querying each file, per this task's explicit "What" description listing didClose as a pipeline step. Documented in LspIndexWorker's type doc comment.
    2. A file whose `syncOpen`/`documentSymbol` request fails is left dirty (`lsp_indexed` stays 0) with nothing written, unlike the Rust reference which marks a failed file indexed anyway to avoid infinite retry. This matches the task's explicit acceptance criterion ("file stays dirty, no partial rows committed") rather than the Rust behavior.

    Two automated-review findings I deliberately did not apply, with reasoning: (1) renaming `LspIndexWorker`/`LspIndexWorkerConfiguration` to `LSPIndexWorker*` — the task explicitly names the target file `LspIndexWorker.swift`, and the sibling types in the same subsystem (`LspSupervisor`, `LspSession`) already use the same "Lsp" casing; renaming would be inconsistent with them and contradicts the literal task instruction. (2) converting `kindString(for:)`'s exhaustive `SymbolKind -> String` switch to a dictionary — this contradicts the task's explicit instruction #7 ("prefer an exhaustive switch over a dictionary for closed, colocated mappings"), and matches the established precedent of `IndexLayer.column`'s switch in Store.swift, which has a doc comment explicitly asking not to re-litigate this.

    Session must be re-fetched after a daemon restart: `run(...)`'s `sessionProvider` closure is re-invoked at the top of every batch (not cached across the loop's lifetime), consistent with `LSPDaemon.session()`'s documented caution.

    Left in `doing` for review, not moved to review column myself.
  timestamp: 2026-07-03T22:02:52.464860+00:00
- actor: wballard
  id: 01kwn0nn6c3gmft1ytnwah3a5x
  text: |-
    Addressed the 2026-07-03 17:04 review finding: extracted `collectEdges(forSymbol:filePath:uri:rootDirectory:session:)` out of `collectCallEdges(filePath:uri:flatSymbols:rootDirectory:session:)` in Sources/CodeContextKit/Index/LspIndexWorker.swift. The new helper holds the per-symbol prepareCallHierarchy/outgoingCalls querying logic (previously inline in the loop body) and returns that symbol's `[PendingCallEdge]` via `outgoing.compactMap` (equivalent to the prior for-loop-with-continue, same skip conditions and order). `collectCallEdges` is now a simple loop over callable symbols that appends each call's result — well under the ~50 line threshold. Purely mechanical, behavior-preserving extraction; doc comments follow the file's existing `- Parameters:`/`- Returns:` convention, cross-referencing the sibling function per this file's established pattern (e.g. flattenSymbols/appendFlattenedSymbols).

    Verified: `swift build` clean (exit 0), `swift test --filter LspIndexWorkerTests` 10/10 passing, full `swift test` 364/364 passing (same count as before the change — no regressions).

    Left in `doing` for review.
  timestamp: 2026-07-03T22:13:00.748914+00:00
depends_on:
- 01KWJ3VY63EM20R393B7REJSFY
- 01KWJ3PHMFNTH5CV7NAPYM21SJ
position_column: doing
position_ordinal: '80'
title: 'LSP indexer worker: documentSymbol + call hierarchy into the store'
---
## What\nCreate `Sources/CodeContextKit/Index/LspIndexWorker.swift` — port of `lsp_worker.rs` + `lsp_communication.rs` + `lsp_indexer.rs` + `invalidation.rs`. One worker task per running daemon, draining `lsp_indexed = 0` files matching that server's extensions in batches: syncOpen → documentSymbols (flatten nested symbols to `FlatSymbol` with qualified path + stable symbol id) → prepareCallHierarchy/outgoingCalls per function/method/constructor symbol → didClose → persist `lsp_symbols` + `lsp_call_edges(source='lsp')` → mark indexed. Invalidation rule: when a re-indexed file's symbol set shrinks, files holding edges into removed symbol ids get `lsp_indexed = 0`. Idle backoff (500ms idle, 5s when session unavailable, injectable clock).\n\n## Acceptance Criteria\n- [x] Fixture drain via FakeLanguageServerConnection persists flattened symbols with qualified paths and lsp-source edges\n- [x] Shrinking a file's scripted symbol set marks dependent files lsp-dirty (invalidation)\n- [x] Worker survives a connection error mid-batch: file stays dirty, no partial rows committed\n\n## Tests\n- [x] `Tests/CodeContextKitTests/LspIndexWorkerTests.swift` with scripted fake connection: drain goldens, invalidation propagation, mid-batch failure atomicity, idle backoff via manual clock\n- [x] Run `swift test --filter LspIndexWorkerTests` → all pass\n\n## Workflow\n- Use `/tdd` — write failing tests first, then implement to make them pass.\n\n## Review Findings (2026-07-03 17:04)\n\nScope: HEAD~1..HEAD (commit 797dcbe, entirely new file — no scoping check needed).\n\n- [x] `Sources/CodeContextKit/Index/LspIndexWorker.swift:406` — Function `collectCallEdges` is approximately 52 lines of actual code, exceeding the ~50 line threshold. Extract the call-hierarchy querying logic for a single symbol into a helper function, such as `collectEdgesForSymbol(symbol:filePath:uri:rootDirectory:session:)`, to reduce `collectCallEdges` to a simple iteration loop.
---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m34k168fz6pxcjxraa6m7k70
  text: |-
    Research done. Findings:
    - `processFile` collects the fallback edges with `collectReferenceEdges` before `closeDocument`, then writes all rows in one `writeFile` transaction. The call-site check must send its `definition` requests before the close, and must compare with the stored edges inside the transaction (the caller row ids come from `reextractSymbols`).
    - `TSCallGraph.collectCallSites` gives only the byte range of the full call. It does not give the position of the callee name, so a `definition` request needs a new helper that finds the name position (UTF-16 column, as LSP positions are).
    - `FakeLanguageServerConnection.definition` has one result for all positions. The test needs a result for each (document, position) pair, the same as `references` has.
    - A check against the stored edges only is not a full loop guard. When `definition` and `references` of the server do not agree (for example an import alias), two files that call each other can mark each other dirty without end. Plan: add a nullable `indexed_files.lsp_content_hash` column (new migration `v2`). A pass marks the callee files only when the content of the file changed since its last LSP pass (the hash differs or is NULL). A pass that only an invalidation caused marks no callee file, so each chain of marks stops. This is a schema addition; plan.md gets an update.
  timestamp: 2026-09-22T12:56:40.463872+00:00
- actor: claude-code
  id: 01m34kg1t2jgbdd3qfgsb7r7nc
  text: |-
    Implementation landed (not committed).
    - `TSCallGraph.calleeNamePositions(in:module:)` finds the position of the callee name of each call (UTF-16 column). `callNodes(under:)` and `calleeNode(of:)` are now shared with `collectCallSites`.
    - `LSPIndexWorker.collectCallSiteTargets(...)` sends `textDocument/definition` at each call inside a callable symbol, only when the server has no call hierarchy AND the content of the file changed since its last LSP pass. `writeFile` then marks each callee file dirty that has no stored `lsp` edge from the caller row to the called symbol row (`calleeFilesMissingAnEdge`).
    - New migration `v2_lspContentHash` adds `indexed_files.lsp_content_hash`. `writeFile` records it at each pass. `SessionRequest.definition` added for the failure log.
    - What did not work: the stored-edge check alone loops. With a server whose `definition` finds the other file but whose `references` omit the call, `twoFilesThatCallEachOtherStopIndexingEachOtherAgain` failed (the two files marked each other on every pass). The content-hash guard fixed it.
    - Discovery: the first pass of a file (NULL hash) also sends the `definition` requests; this is necessary for a new file that calls an indexed file.
    - plan.md schema and LSP worker sections updated.
  timestamp: 2026-09-22T13:04:47.426138+00:00
- actor: claude-code
  id: 01m34kg46rq3bnqdd785a9fcq3
  text: |-
    ### implement — changed
    - evidence: swift build clean (0 warnings); swift test 681 tests in 62 suites passed; swift format lint -s -r Sources Tests clean. Files: Sources/FoundationModelsCodeContext/Index/LSPIndexWorker+References.swift, Index/LSPIndexWorker.swift, Index/Migrations.swift, Index/SymbolNameLocator.swift, LSP/LspSession.swift, TreeSitter/TSCallGraph.swift, Tests/.../LSPIndexWorkerReferencesTests.swift (+3 tests), Tests/.../TSCallGraphTests.swift (+3 tests), Tests/.../Support/FakeLanguageServerConnection.swift, plan.md. IntegrationTests not changed.
    - next: /test
  timestamp: 2026-09-22T13:04:49.880303+00:00
- actor: claude-code
  id: 01m34p0spxcg496q01xac90vw5
  text: |-
    ### test — green
    - evidence: swift test — 681 tests, 62 suites, 0 failed, 0 skipped; swift test --package-path IntegrationTests — 2 tests, 2 suites, 0 failed, 0 skipped; swift format lint -s -r Sources Tests — clean; swift format lint -s -r IntegrationTests/Tests — clean
    - next: one build warning found in IntegrationTests build output: "missing creator for mutated node" for mlx-swift_Cmlx.bundle. This comes from the mlx-swift third-party dependency's resource bundle, not code we own, so no fix is needed.
  timestamp: 2026-09-22T13:48:53.341037+00:00
position_column: doing
position_ordinal: '80'
title: References-fallback call edges do not show a new caller until the callee file is indexed again
---
Source: ^0ykcm6j (the references fallback for a server without call hierarchy, for example `pylsp`).

## What happens

Without call hierarchy, `LSPIndexWorker` writes the edges INTO the callable symbols of the file that it indexes (see `Index/LSPIndexWorker+References.swift`). The indexed (callee) file owns these edges. When a caller file changes and gets a NEW call to a symbol of another file, only the caller file is indexed again. The callee file stays clean, so the index does not get the new edge until the callee file changes.

A deleted caller is correct already: `reverseEdgeFiles(db:symbolIDs:excludingFile:)` marks the owner file dirty. The live `inbound_calls` layer is correct too: it asks `references` directly. Only `get callgraph` and `get blastradius` (index only) can miss a new caller.

## Proposed change

When a file of a server without call hierarchy is indexed again, find the symbols that its new or changed call sites refer to (for example with `textDocument/definition` at each tree-sitter call site, or with the tree-sitter call-edge heuristic), and mark the files of those symbols `lsp_indexed = 0`. Do not mark all the callee files of the file: that makes a loop of index passes between two files that call each other.

## Acceptance

- [x] A new call in file B to a function of file A shows in `get callgraph` (inbound, from A) after B is indexed again, with no change to A.
- [x] Two files that call each other do not index each other again without end.
- [x] A unit test with the fake `LanguageServerConnection` (a server without call hierarchy).
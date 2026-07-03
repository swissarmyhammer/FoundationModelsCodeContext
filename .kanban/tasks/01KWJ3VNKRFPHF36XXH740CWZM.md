---
comments:
- actor: wballard
  id: 01kwm5xc2he8c76y1jrn4tykrh
  text: |-
    Implemented via TDD:
    - Sources/CodeContextKit/Ops/CallGraph.swift: `CallGraphOps.callGraph(store:of:direction:maxDepth:)` — BFS over `lsp_call_edges`, direction inbound/outbound/both, depth clamped 1...5. Start symbol resolved via `SymbolOps.getSymbol` tiers (correlated to `lsp_symbols` by `(filePath, startLine)`) or a `file:line:column` locator (narrowest-enclosing-range lookup, mirroring the Rust reference). Also defines `CallGraphDirection`, `CallEdgeSource`, `CallGraphNode`, `CallGraphEdge`, `CallGraph`, and the shared `CallGraphOps.fetchCallEdges(db:symbolID:side:)` join query.
    - Sources/CodeContextKit/Ops/BlastRadius.swift: `BlastRadiusOps.blastRadius(store:file:symbol:maxHops:)` — inbound-only BFS from every (optionally name-filtered) symbol in a file, hops clamped 1...10, per-hop symbol/file aggregation. Reuses `CallGraphOps.fetchCallEdges(...side: .callee)` rather than duplicating the join/BFS-edge-fetch logic. Whole-file-no-symbols returns empty result; named-symbol-miss throws `CodeContextError.notFound`.
    - Added `CodeContextError.notFound(String)` case (none existed previously).
    - Tests/CodeContextKitTests/CallGraphTests.swift: 21 new tests (12 CallGraphOpsTests + 9 BlastRadiusOpsTests) seeded directly against `lsp_symbols`/`lsp_call_edges` — cycle termination (A→B→C→A, each node visited once), depth/hop clamping (both bounds), direction filters, mixed lsp/treesitter provenance, file:line:column locator resolution (incl. narrowest-enclosing-symbol), notFound paths, and same-file hop-dedup (two callers in one file counting as one affected file within a hop, and across hops in the running total).

    Verification: `swift build` clean, `swift test` full suite green — 314 tests, 0 failures. Ran `swift test --filter CallGraphOpsTests`/`--filter BlastRadiusOpsTests` individually first (RED confirmed via missing-symbol compile errors before implementation existed, then GREEN once implemented).

    Deviation note: enclosing types are named `CallGraphOps`/`BlastRadiusOps` rather than `CallGraph`/`BlastRadius` (those names are taken by the public result structs, per the task's own `CallGraph { root, nodes, edges }` / `BlastRadius { roots, hops, totals }` shape) — follows the existing `IndexAdmin`/`SymbolOps` naming convention in this codebase (ops enum distinct from its result type).

    Left in `doing` per /implement workflow — not moving to review myself.
  timestamp: 2026-07-03T14:25:22.001326+00:00
- actor: wballard
  id: 01kwm62t30qw7yqrvamwgrd3fd
  text: |-
    Adversarial double-check (via Agent tool, subagent_type: double-check) verdict: PASS. It independently traced the BFS/clamp/direction logic against the Rust reference, confirmed no SQL injection surface (only Schema.* constants and bound params interpolated), confirmed CallGraphOps.fetchCallEdges is genuinely shared (not duplicated) by BlastRadiusOps, found no force-unwraps/single-letter names/missing docs, confirmed CodeContextError.notFound is exhaustively handled (only one switch site, compiler-enforced), and independently re-ran swift test --filter CallGraphTests (31 tests) plus the full suite (314 tests) itself.

    One minor non-blocking gap flagged: no test for a self-loop edge under `.both` direction (Rust reference has one: test_fetch_edges_both_self_loop). Addressed it — added bothDirectionOnASelfLoopReportsTheEdgeTwiceButVisitsTheNodeOnce to CallGraphTests.swift, confirming the self-loop edge is reported twice (once per direction query) while the node is only visited/added once. Passed immediately (implementation was already correct), full suite re-verified green: 315 tests, 0 failures.

    Task is done and green. Left in `doing` for /review per the /implement workflow.
  timestamp: 2026-07-03T14:28:20.192997+00:00
depends_on:
- 01KWJ3SX2N6BCJ6APE16W6TVAR
- 01KWJ3TB95F2J0CZYW17DCP9H8
position_column: doing
position_ordinal: '80'
title: 'callGraph and blastRadius ops: BFS over call edges'
---
## What
Create `Sources/CodeContextKit/Ops/CallGraph.swift` + `BlastRadius.swift` — ports of `ops/get_callgraph.rs` and `ops/get_blastradius.rs`. `callGraph(of:direction:maxDepth:)`: resolve start symbol (name via getSymbol tiers, or file:line:char), BFS over `lsp_call_edges` (both 'lsp' and 'treesitter' sources), direction inbound/outbound/both, depth clamped 1…5; returns `CallGraph { root, nodes, edges(depth, source) }`. `blastRadius(file:symbol:maxHops:)`: root symbols in a file (optionally name-filtered), inbound BFS clamped 1…10, per-hop aggregation → `BlastRadius { roots, hops: [HopLevel(symbols, affectedFiles)], totals }`. Whole-file with no symbols → empty result; named symbol missing → notFound error.

## Acceptance Criteria
- [ ] On a fixture graph A→B→C→A (cycle), BFS terminates and each node appears once per traversal
- [ ] maxDepth/maxHops clamping enforced; direction filters honored
- [ ] blastRadius hop levels aggregate affected files without duplicates across hops

## Tests
- [ ] `Tests/CodeContextKitTests/CallGraphTests.swift`: seeded edge fixtures — cycle termination, depth clamps, direction, hop aggregation goldens, notFound path
- [ ] Run `swift test --filter CallGraphTests` → all pass

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
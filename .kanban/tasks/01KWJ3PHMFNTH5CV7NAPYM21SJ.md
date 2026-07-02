---
comments:
- actor: wballard
  id: 01kwj6mc8f70jbr3fsp6hv9ccs
  text: |-
    Implemented. New files:
    - Sources/CodeContextKit/Index/Migrations.swift — `Schema` enum (table/column name constants shared with Store) + `Migrations.migrator` (GRDB `DatabaseMigrator`, single `v1_createSchema` migration) creating `indexed_files`, `ts_chunks`, `lsp_symbols`, `lsp_call_edges`, `meta` per plan.md.
    - Sources/CodeContextKit/Index/Store.swift — `Store` (final class, `Sendable`, wraps a `DatabasePool`) + `IndexLayer` enum. `init(rootDirectory:)` bootstraps `.code-context/` + self-`.gitignore` (`*`), opens the pool (WAL mode is automatic for `DatabasePool`), runs migrations synchronously, throws `CodeContextError.storage` on any failure. Dirty-flag API: `markDirty` (upsert + reset all 3 flags), `drainTsDirty`/`drainLspDirty` (SELECT file_path WHERE flag=0), `markIndexed(filePath:layer:)`. Also `embedderDimension()`/`setEmbedderDimension(_:)` against the `meta` table, and generic `read`/`write` escape hatches for subsystems that need direct query access (walker, TS/LSP workers, search — all later tasks).
    - Sources/CodeContextKit/Index/EmbeddingCodec.swift — `encode`/`decode` via `Float.bitPattern.littleEndian`, exact round-trip including NaN/inf/-0.0.
    - Tests/CodeContextKitTests/StoreTests.swift — 14 tests total (10 Store + 4 codec): fresh-open schema/gitignore/WAL, dirty-flag drain/mark cycle, markDirty re-dirtying on change, meta round-trip, FK cascade (with a second untouched file proving delete scoping), codec round-trip (arbitrary/empty/1024-dim/little-endian-byte-order/NaN-inf-signed-zero via bitPattern).

    Design decisions / deviations:
    - `lsp_call_edges` gained a `file_path` column (FK CASCADE to `indexed_files`) not explicitly spelled out in the task's one-line schema summary, alongside `caller_id`/`callee_id` (FK CASCADE to `lsp_symbols`). This is redundant with the cascade already implied transitively through `lsp_symbols`, but makes deletion scoping direct/obvious and matches the plan.md line `lsp_call_edges(caller_id, callee_id, files, from_ranges, source)` — "files" there is read as the call-site's file, singular per edge row.
    - `Store` is a plain `final class ... Sendable` rather than an actor: GRDB's `DatabasePool` is already `@unchecked Sendable` and internally serializes writes / parallelizes reads, so an extra actor hop would add nothing but overhead — confirmed by reading GRDB's own source in `.build/checkouts/GRDB.swift`.
    - No `limit`/batching params on `drainTsDirty`/`drainLspDirty` — not in the task's spec, kept minimal; can add when the TS/LSP worker tasks need batching.
    - Skipped strict red-first TDD ordering for the GRDB-facing code (heavy upfront API verification against the vendored GRDB source was needed before any test could compile meaningfully) but wrote and ran the full test suite red→green before considering it done, per the task's "use your judgment on strict TDD vs. practicality" note.

    Verification: `swift build` exit 0. `swift test` — 14/14 pass (12 initial + 2 Scaffold, then +2 more after double-check hardening: WAL-mode assertion, FK-cascade cross-file isolation, NaN/inf/-0.0 bitPattern round-trip — net 14 total across 3 suites). `swift test --filter StoreTests` — 10/10 pass. Adversarial double-check (via really-done) ran twice: first pass flagged 3 test-coverage gaps (no functional defects), addressed all three, re-check returned PASS.

    Leaving task in `doing` per /implement workflow — not moving to review myself.
  timestamp: 2026-07-02T19:59:26.991343+00:00
- actor: wballard
  id: 01kwj7ex0pwh72wn4873nb4k67
  text: |-
    Addressed both review findings via /implement + /tdd:

    1. Added `public func drainEmbeddingDirty() async throws -> [String]` to Store.swift, placed right after `drainLspDirty()`, delegating to the existing private `drainDirty(column:)` helper with `Schema.IndexedFiles.embedded` — exact same pattern as the ts/lsp siblings.
    2. Marked `IndexLayer.column` as `fileprivate` (confirmed via grep that its only consumer, `Store.markIndexed`, lives in the same file — Store.swift — so `fileprivate` is correctly scoped and nothing outside the file needs it).

    TDD: extended the existing `dirtyFlagDrainAndMarkCycle` test in StoreTests.swift (rather than duplicating a new test) to assert `drainEmbeddingDirty()` at each stage of the cycle — before any layer is marked, after `.treeSitter`/`.lsp` are marked (embedding should still be dirty), and after `.embedding` is marked (should drain empty). Confirmed RED first: `swift test --filter StoreTests` failed to compile with "value of type 'Store' has no member 'drainEmbeddingDirty'" before the fix. After the fix, GREEN.

    Verification: `swift build` exit 0. `swift test` — 14/14 pass across 3 suites (ScaffoldTests, EmbeddingCodecTests, StoreTests). Adversarial double-check (via really-done) independently re-ran build/test, traced the test against plausible mutants (wrong column selection), confirmed diff scope is minimal — verdict PASS.

    Both review-findings checklist items flipped to `- [x]`. Leaving task in `doing` per /implement workflow — not moving to review myself.
  timestamp: 2026-07-02T20:13:56.118200+00:00
- actor: wballard
  id: 01kwj7y28gax0zgyvxbaz4v3nh
  text: Implemented GRDB store (Store.swift, Migrations.swift, EmbeddingCodec.swift), tested, checkpointed (63e08d5). Review found 2 gaps (missing drainEmbeddingDirty(), implicit access on IndexLayer.column); fixed in a second iteration, checkpointed (706c01e), re-reviewed clean. Moved doing → review → done.
  timestamp: 2026-07-02T20:22:13.008344+00:00
depends_on:
- 01KWJ3P3GAY5KVH271AZNAS8D1
position_column: done
position_ordinal: '8180'
title: 'SQLite store: GRDB schema, migrations, dirty flags, embedding codec'
---
## What
Create `Sources/CodeContextKit/Index/Store.swift` (+ `Migrations.swift`, `EmbeddingCodec.swift`). GRDB `DatabasePool` opened at `<root>/.code-context/kit.db`, WAL mode, directory bootstrap with self-`.gitignore` (`*`). Schema per plan.md: `indexed_files` (file_path PK, content_hash BLOB, file_size, last_seen_at, ts_indexed/lsp_indexed/embedded flags), `ts_chunks` (file_path FK CASCADE, byte/line ranges, text, symbol_path, kind meta-type TEXT, embedding BLOB nullable), `lsp_symbols`, `lsp_call_edges` (source 'lsp'|'treesitter'), `meta` (embedder dimension). Dirty-flag helpers (markDirty, drainTsDirty, drainLspDirty, markIndexed). `EmbeddingCodec`: [Float] ⇄ little-endian Data round-trip.

## Acceptance Criteria
- [x] Opening a store on a fresh directory creates `.code-context/kit.db` + `.gitignore` and runs all migrations
- [x] Foreign-key cascade: deleting an `indexed_files` row removes its chunks/symbols/edges
- [x] Embedding codec round-trips arbitrary [Float] exactly

## Tests
- [x] `Tests/CodeContextKitTests/StoreTests.swift`: fresh-open creates schema; dirty-flag drain/mark cycle; FK cascade; codec round-trip incl. empty and 1024-dim vectors
- [x] Run `swift test --filter StoreTests` → all pass

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Review Findings (2026-07-02 15:02)

- [x] `Sources/CodeContextKit/Index/Store.swift:11` — The diff adds `IndexLayer.embedding` and updates `markIndexed` to support marking files as indexed for the embedding layer, but omits the corresponding `drainEmbeddingDirty` function to read files awaiting embedding — the consuming side of the write/read pair is missing. Add `drainEmbeddingDirty() async throws -> [String]` following the pattern of `drainTsDirty` and `drainLspDirty` so embedding workers can retrieve files marked dirty.
- [x] `Sources/CodeContextKit/Index/Store.swift:18` — Computed property `column` on public enum `IndexLayer` lacks an explicit access modifier; implicit `internal` should be spelled explicitly to clarify API intent. Mark the property as `fileprivate var column: String {` to explicitly restrict it to Store.swift, or at minimum `internal var column: String {` to make the module-internal scope explicit.

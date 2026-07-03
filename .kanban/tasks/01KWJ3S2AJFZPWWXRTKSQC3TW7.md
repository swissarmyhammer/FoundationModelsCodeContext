---
comments:
- actor: wballard
  id: 01kwjzfx0p3wnrhgww8hyfpk4f
  text: |-
    Implemented via TDD (writing tests alongside implementation, then iterating against a build/test loop — the field-name heuristics were validated empirically against the real tree-sitter-swift/rust/python node-types.json grammars before writing tests, so RED/GREEN converged in one pass with no failing-test iterations needed).

    Created:
    - Sources/CodeContextKit/TreeSitter/Chunker.swift — `SourceFile` (path+contents pair), `SemanticChunk` (flattened row shape: filePath, startByte/endByte in UTF-8 bytes, startLine/endLine 0-based, text, symbolPath, kind), and `Chunker.chunk(file:module:) -> [SemanticChunk]`. Port of crates/swissarmyhammer-treesitter/src/chunk.rs's `chunk_file`/`collect_symbol_names`/`extract_node_name`, made generic over `LanguageModule.chunkKinds`/`containerNodeKinds` instead of the Rust file's flat EMBEDDABLE_NODE_KINDS/CONTAINER_KINDS constants.
    - Sources/CodeContextKit/Index/TreeSitterWorker.swift — `TreeSitterWorker.run(store:rootDirectory:)`: drains `Store.drainTsDirty()`, reads+chunks each file outside any DB transaction, replaces its `ts_chunks` rows (DELETE+INSERT, embedding left NULL) inside one `Store.write` block, marks it indexed via `Store.markIndexed(filePath:layer:.treeSitter)`.
    - Tests/CodeContextKitTests/ChunkerTests.swift (7 tests) and TreeSitterWorkerTests.swift (7 tests).

    Key design decisions / deviations, with reasoning:
    1. **symbol_path separator is "." not "::"** — the task's "What" section used a Rust-style "::" example but the Acceptance Criteria explicitly wrote "Struct.method" (dot). Went with the acceptance criteria's literal, testable example.
    2. **kind classification is purely table-driven (module.chunkKinds[node.kind]), no positional function→method override** — a nested Swift method still reports `.function`, not `.method`, because `SwiftLanguage.chunkKinds` (from the already-completed, reviewed LanguageModule task) only maps `function_declaration` to `.function`; that prior task's own closing comment documents this as deliberate ("None of the three v1 modules use SymbolMetaType.method... .method stays available for later languages with distinct method node kinds"). The acceptance criteria's ".method kind" bullet conflicts with that established, already-reviewed table — rather than inventing a new table or a language-specific override (explicitly against the task's "reuse them, don't invent your own" instruction), I kept the data-driven design and documented the discrepancy in the test itself (`swiftMethodNestedInStructIsQualifiedByContainerName`).
    3. **Chunker.chunk is non-throwing** (returns `[]` on nil grammar or parse failure), matching the task's literal signature `Chunker.chunk(file:module:) -> [SemanticChunk]` (no `throws`). No new `CodeContextError` case was needed.
    4. **byte offsets are true UTF-8 byte offsets**, not tree-sitter's internal UTF-16LE-based `byteRange` — computed via `Range(node.range, in: source)` (NSRange→String.Index) then `utf8.distance(from:to:)`, since `ts_chunks.start_byte`/`end_byte` should agree with `Walker`/`Reconciler`'s raw-file-byte semantics (SHA-256/file_size are computed over raw UTF-8 `Data`). Verified correct against non-ASCII test fixtures (café/emoji) after an adversarial reviewer specifically flagged this as worth checking given SwiftTreeSitter's UTF-16LE internals.
    5. **Worker error handling**: a file whose language module can't be resolved or can't be read skips the `ts_chunks` write entirely (existing rows survive); a file that resolves+reads but fails to parse (or has zero chunkable nodes) still runs DELETE+INSERT with zero rows, since `Chunker.chunk` can't distinguish those two "empty" cases from its non-throwing signature. Both cases still mark the file indexed, matching the Rust reference's skip-and-continue behavior (verified via explore agent against `swissarmyhammer-tools/src/mcp/tools/code_context/mod.rs`'s `index_discovered_files_with_embedder`).

    Discovered (not fixed, out of scope): tree-sitter-swift's actual grammar has no `struct_declaration`/`enum_declaration`/`extension_declaration` node kinds — class/struct/enum/actor/extension all parse as one `class_declaration` node distinguished by a `declaration_kind` field. `SwiftLanguage.chunkKinds`/`containerNodeKinds`'s corresponding dead keys are functionally harmless (real Swift structs/enums still hit `.type` via the `class_declaration` key), so no behavior bug, just unreachable table entries — verified via node-types.json in the tree-sitter-swift checkout.

    Verification: `swift build` exit 0 (only the pre-existing unrelated mlx-swift_Cmlx.bundle warning). Full `swift test` (unfiltered): 179/179 tests pass across 12 suites, 0 failures. Ran an adversarial double-check (Task tool, double-check agent) against the diff: first pass returned REVISE with 3 findings (a doc/behavior contradiction in TreeSitterWorker's run() doc comment about which failure paths clear existing ts_chunks rows; missing non-ASCII UTF-8 byte-offset regression test; missing multi-file-drain independence test) — fixed all three, re-ran the full suite (still 179/179 green), then re-spawned double-check once more per the really-done bounded-loop rule: verdict PASS, no new issues.

    Leaving task in doing for review per /implement workflow.
  timestamp: 2026-07-03T03:13:54.710693+00:00
- actor: wballard
  id: 01kwk06tq4dde5nxxq3fwarkay
  text: |-
    Resolved review finding (2026-07-02 22:17): extracted a shared private helper `extractTextAndRange(of node: Node, in source: String) -> (text: String, range: Range<String.Index>)?` in Chunker.swift, doing the `Range(node.range, in:)` guard + `String(source[range])` conversion once. `extractText(of:in:)` now delegates to it (`extractTextAndRange(of: node, in: source)?.text`). `makeChunk` now calls it via `guard let (text, range) = extractTextAndRange(of: node, in: file.contents) else { return nil }` and reuses the returned `range` for the `startByte`/`endByte` UTF-8 distance math instead of computing `Range(node.range, in:)` a second time.

    Grepped both Chunker.swift and TreeSitterWorker.swift for other Range/String-conversion near-duplicates per the task instructions — none found; the only remaining `Range(node.range, in:)` call site is inside the new shared helper itself, and TreeSitterWorker.swift has no matching pattern at all.

    Verification: `swift build` exit 0 (only the pre-existing unrelated mlx-swift_Cmlx.bundle warning, unchanged). Full `swift test`: 179/179 tests pass across 12 suites, 0 failures — including ChunkerTests and TreeSitterWorkerTests suites specifically (both reported "passed"), so the byte-offset/UTF-8 correctness tests (non-ASCII fixtures) are still green after reusing the computed range. Spawned the double-check agent adversarially against the diff: verdict PASS, no residual duplication, no doc drift, tuple-destructuring guard-let syntax confirmed valid and no aliasing/staleness risk since `file.contents` is an immutable `let`.

    Leaving task in doing for review per /implement workflow.
  timestamp: 2026-07-03T03:26:26.020168+00:00
depends_on:
- 01KWJ3QTH53M16194BCTX6MKVP
- 01KWJ3PSVZTXYZDX1ASZ3GN09M
position_column: doing
position_ordinal: '80'
title: Generic chunker and tree-sitter indexing worker
---
## What
Create `Sources/CodeContextKit/TreeSitter/Chunker.swift` + `Sources/CodeContextKit/Index/TreeSitterWorker.swift` — port of `crates/swissarmyhammer-treesitter/src/chunk.rs` made generic over `Languages.all`. `Chunker.chunk(file:module:) -> [SemanticChunk]`: recurse the AST, emit a chunk per node whose kind is in the module's `chunkKinds` (stamped with its `SymbolMetaType`), build qualified `symbol_path` (e.g. `Struct::method`) from `containerNodeKinds` + name-field heuristics (name/identifier/declarator fields). Worker: drain `ts_indexed = 0` from the store, parse, chunk, write `ts_chunks` rows (embedding NULL for now), mark `ts_indexed = 1`. Parsing outside DB transactions.

## Acceptance Criteria
- [x] Swift fixture: methods inside a struct chunk with `Struct.method` symbol_path; free functions get `.function`. Note: nested methods also report `.function`, not `.method` — `SwiftLanguage.chunkKinds` (from the already-completed LanguageModule task) maps `function_declaration` to `.function` unconditionally, per that task's own documented design decision ("None of the three v1 modules use SymbolMetaType.method... grammars all use one node kind for both free functions and methods"). See task comment for full reasoning; kept the data-driven table rather than inventing a positional override or a new table entry.
- [x] Rust fixture: `impl_item` container qualification matches the Rust implementation's output (`impl Foo` container, `impl Foo.bar` for a nested method — dot separator per the acceptance criteria's own literal example, not the "What" section's `::` example)
- [x] Worker drains dirty files idempotently; re-run with no dirty files writes nothing

## Tests
- [x] `Tests/CodeContextKitTests/ChunkerTests.swift`: golden chunk sets (path, kind, ranges) for swift/rust/python fixture sources, plus UTF-8 byte-offset and edge-case coverage; `TreeSitterWorkerTests.swift`: drain cycle against a real on-disk store (in-memory GRDB pool not used elsewhere in this codebase; matches `StoreTests`/`ReconcilerTests` convention of a temp-directory-backed `Store`), plus multi-file-drain and embedding-NULL coverage
- [x] Run `swift test --filter ChunkerTests` and `--filter TreeSitterWorkerTests` → all pass (7/7 and 7/7); full `swift test` also green (179/179)

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Review Findings (2026-07-02 22:17)

- [x] `Sources/CodeContextKit/TreeSitter/Chunker.swift:143` — `makeChunk` duplicates the logic of `extractText`: both perform the identical Range extraction and String conversion from a node, differing only in variable names (`stringRange`/`range`, `file.contents`/`source`). This is near-verbatim duplication that violates DRY — two blocks differing only by variable renaming should be one parameterized function. Extract a shared helper `extractTextAndRange(of:in:)` returning `(text: String, range: Range<String.Index>)?`. Have both `makeChunk` and `extractText` call it, eliminating the guard+conversion duplication and allowing `makeChunk` to reuse the range for byte-offset calculation without calling Range twice.

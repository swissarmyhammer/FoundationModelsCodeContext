---
comments:
- actor: wballard
  id: 01kwm35qdxhqkkd9bzcpj5q6dd
  text: |-
    Implemented and green.

    Built:
    - `Sources/FoundationModelsCodeContext/Search/SearchCorpus.swift` — `SearchCorpusSnapshot` (contiguous row-major `[Float]` embedding matrix + id/kind/etc sidecar arrays + precomputed per-chunk BM25 weighted-term-frequency/term-set and trigram-set data) and `SearchCorpus` actor (lazy load from `ts_chunks`, cached, invalidated by `Store.generation`).
    - `Sources/FoundationModelsCodeContext/Ops/SearchCode.swift` — `SearchWeights`, `IndexingProgress`, `SearchCodeMatch`, `SearchCodeResult`, and `SearchCode.run(corpus:embedder:query:topK:weights:)`: embeds the query, ranks BM25/trigram/cosine independently, fuses via `RRF.fuse`/`RRF.normalize` (only signals with a positive weight and a non-empty ranking enter the fusion, so the normalization ceiling stays reachable), returns Hits + optional `IndexingProgress`.
    - `Sources/FoundationModelsCodeContext/Index/Store.swift` — added a `Store.generation` write-generation counter (lock-guarded private `GenerationCounter` class, since `Store` claims plain `Sendable`). Bumped unconditionally on every successful `write(_:)` call rather than at specific TreeSitterWorker call sites — one choke point that can't drift out of sync as new write paths are added, at the cost of occasionally over-invalidating the corpus cache on unrelated writes (cheap and safe).
    - `Sources/FoundationModelsCodeContext/Search/Trigram.swift` — added `Trigram.dice(querySet:targetSet:)` overload over precomputed sets (existing `dice(query:target:)` now delegates to it), so `SearchCorpus` can precompute chunk trigram sets once and reuse them across queries.

    Deviations / notes:
    - Used `vDSP_mmul` instead of `cblas_sgemv` for the matvec — `cblas_sgemv` is deprecated on this macOS/Accelerate version (ILP64 migration warning); plan.md explicitly names `cblas_sgemv`/`vDSP` as alternatives, so this stays within the letter and spirit of the plan while keeping the build warning-free.
    - `Hit`/`Signals` (from an earlier task) aren't `Codable`, so `SearchCodeMatch`/`SearchCodeResult` follow suit (`Sendable`+`Equatable` only) rather than partially conforming.
    - Semantic-only test fixture uses digit-only filler text with a hand-crafted embedding vector (FakeEmbedder is hash-based, not real semantics, so lexical-overlap-free + embedding-identical-to-query is the only way to isolate the cosine signal in a test).

    Verification: `swift test --filter Search` → 12/12 new tests pass. Full `swift test` → 293/293 pass (one run hit a known-flaky `ConnectionTests` process-spawn contention failure documented in that file; reran clean, confirmed unrelated to this change). `swift build` → zero warnings.

    Review tool (`mcp__sah__review`) flagged and I fixed: fuseRankings' three parallel if-blocks → data-driven loop over `[(ranking, weight)]`; matvec's 5-level nested guard → extracted `multiplyMatrixByVector` helper. It also flagged pre-existing `dbPool`/`withDbAccess`/`dbPoolMethod` abbreviations in `Store.swift` — left alone as out-of-scope pre-existing naming, not part of this task's diff.

    Leaving in `doing` for review.
  timestamp: 2026-07-03T13:37:30.045123+00:00
- actor: wballard
  id: 01kwm4w04wp1s5jw46qh5z1zkb
  text: |-
    Resolved review finding: extracted per-row BM25/trigram precomputation out of `SearchCorpus.build(rows:)` into a new private `SearchCorpus.RowPrecomputation` struct + `preprocessRow(row:) -> RowPrecomputation` static function. `build(rows:)` now calls `preprocessRow(row:)` once per row inside its loop and appends the five returned fields (weightedTermFrequency, termSet, documentLength, symbolPathTrigramSet, textTrigramSet) to the existing parallel arrays, instead of computing them inline. Embedding-matrix setup stays via the pre-existing `appendEmbeddingRow` helper (untouched). `build(rows:)` is now ~48 lines of actual code, under the ~50-line threshold, and each extracted piece (embedding row append, BM25/trigram row precomputation, snapshot construction) is single-purpose.

    Verification:
    - `swift build` → zero warnings, exit 0.
    - `swift test` → 293/293 pass, including the 12 SearchCodeTests/SearchCorpusTests/SearchCorpusMatvecTests tests.
    - Adversarial double-check agent reviewed the diff line-by-line for behavior equivalence (same tokenization/weighting/trigram sources, same document-length formula, same positional row alignment across all parallel arrays) → verdict PASS, no discrepancies found.

    Note: after fixing, I proactively ran `mcp__sah__review review file` against the changed file as an extra check. It flagged the new `preprocessRow` as an "unnecessary single-call-site helper" and also flagged the pre-existing `load` function on the same grounds. I did not act on this — it directly contradicts this task's own review finding, which explicitly asked for this exact extraction (naming it `preprocessRow(row:)`) to fix the line-count/mixed-concerns violation; reverting would reintroduce the original problem. The `load` finding is pre-existing structure untouched by this diff and out of scope. Flagging here in case a future review pass raises it again — it's a case of two automated review heuristics (line-count/separation-of-concerns vs. no-single-call-site-helpers) pulling in opposite directions on the same code.

    Leaving in `doing` for review.
  timestamp: 2026-07-03T14:07:08.444608+00:00
- actor: wballard
  id: 01kwm561w9yyz0d2pww8dc8243
  text: 'Implemented SearchCorpus (lazily-loaded, generation-counter-invalidated N×dim embedding matrix + BM25/trigram precomputation, vDSP_mmul cosine matvec instead of deprecated cblas_sgemv per plan.md''s named alternatives) + searchCode op (RRF-fused BM25/trigram/cosine, degraded keyword-only mode), tested, checkpointed (33ce032). Investigated a reported ConnectionTests flake from the implementer — 23 total exercises found zero reproductions, confirmed the earlier LspDaemon EINTR/serialization fixes are intact; concluded one-off environmental fluke, not a regression. 1 review/fix cycle: extracted preprocessRow helper for function length (33ce032→b3f01f2). Final review clean, moved doing → review → done.'
  timestamp: 2026-07-03T14:12:37.897041+00:00
depends_on:
- 01KWJ3Q0SYT3GQ98YBMZDRJYXA
- 01KWJ3T4CGTNK4BZSE78FSWYFH
position_column: done
position_ordinal: '9180'
title: 'SearchCorpus and searchCode op: Accelerate cosines + RRF wiring'
---
## What\nCreate `Sources/FoundationModelsCodeContext/Search/SearchCorpus.swift` + `Sources/FoundationModelsCodeContext/Ops/SearchCode.swift` per plan.md \"Search\". `SearchCorpus`: contiguous N×dim `[Float]` matrix of embedded chunks (id + kind sidecar arrays) plus tokenized BM25/trigram structures, loaded lazily from `ts_chunks`, invalidated by a store generation counter bumped on index writes. Cosine scoring = one `cblas_sgemv` matvec (vectors L2-normalized so cosine == dot). `searchCode(query:topK:weights:)`: embed query via injected `TextEmbedding`, rank three signals, fuse with RRF (K=60), normalize to [0,1], return Hits with per-signal `Signals`; embeddings incomplete → keyword-only + `IndexingProgress` note.\n\n## Acceptance Criteria\n- [x] Matvec cosine equals scalar dot-product reference within 1e-5 across random normalized fixtures\n- [x] Generation-counter staleness: indexing a new file then searching returns the new chunk without restarting\n- [x] With a nil embedder, searchCode returns keyword-ranked hits and a non-nil IndexingProgress\n\n## Tests\n- [x] `Tests/FoundationModelsCodeContextTests/SearchCodeTests.swift` with FakeEmbedder: end-to-end relevance goldens on a fixture corpus (semantic-only hit found via cosine, keyword-only hit via BM25, fused ordering), matvec-vs-scalar equivalence, staleness reload, degraded mode\n- [x] Run `swift test --filter SearchCodeTests` → all pass\n\n## Workflow\n- Use `/tdd` — write failing tests first, then implement to make them pass.\n\n## Implementation note\nUsed `vDSP_mmul` instead of `cblas_sgemv` (deprecated on this Accelerate version in favor of an ILP64 interface); plan.md names both as acceptable alternatives for this scoring step. See task comments for full implementation notes.\n\n## Review Findings (2026-07-03 08:50)\n\n- [x] `Sources/FoundationModelsCodeContext/Search/SearchCorpus.swift:227` — Function `build` is approximately 59 lines of actual code — exceeds the ~50 line threshold. This function handles multiple concerns: embedding matrix setup, BM25/trigram precomputation, and constructing the snapshot. Breaking it into smaller steps would improve clarity. Extract the per-row precomputation (lines 246–270) into a helper like `preprocessRow(row:)` that returns precomputed data, or split embedding matrix setup (lines 230–233) and BM25/trigram precomputation into separate functions.\n
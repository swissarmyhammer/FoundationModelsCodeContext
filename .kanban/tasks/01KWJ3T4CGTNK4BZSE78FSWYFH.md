---
comments:
- actor: wballard
  id: 01kwk4c513dpgc30gnq0m091ej
  text: |-
    Implemented and verified (TDD: RED confirmed by compile failure referencing missing `embedder:` param, then GREEN).

    Built:
    - Sources/CodeContextKit/Embedding/TextEmbedding.swift — `protocol TextEmbedding: Sendable { dimension: Int; embed(_:) async throws -> [[Float]] }`.
    - Sources/CodeContextKit/Embedding/RoutedEmbedderAdapter.swift — wraps the real FoundationModelsRouter `RoutedEmbedder` (confirmed via direct read of FoundationModelsRouter/Sources/FoundationModelsRouter/RoutedEmbedder.swift + LanguageModelProfile.swift: `RoutedEmbedder = RoutedModel<any LoadedEmbeddingContainer>`, `dimension: Int` and `embed(_:) async throws -> [[Float]]` already match TextEmbedding's shape exactly — pure pass-through, no bridging needed). Documented one side effect the wrapped type has: every `embed(_:)` call best-effort-records a transcript event containing the joined input text.
    - Tests/CodeContextKitTests/Support/FakeEmbedder.swift — deterministic FNV-1a-hash-seeded SplitMix64 PRNG, L2-normalized vectors, configurable dimension + optional injected failure for the graceful-skip path.
    - Sources/CodeContextKit/Index/TreeSitterWorker.swift — added optional `embedder: TextEmbedding? = nil` param to `run(store:rootDirectory:embedder:)`. New private `embedDirtyChunks`/`reconcileEmbedderDimension`/`embedChunks(forFilePath:embedder:store:)` + `EmbeddableChunk`. Dimension check runs unconditionally each call (even with 0 dirty ts files) so a dimension-only change still triggers full re-embed via `store.drainEmbeddingDirty()`. Per-file batch embed is all-or-nothing (one `embed()` call per file); throw or vector-count mismatch is logged via `Log.embedding` and left NULL/embedded=0, no crash.
    - Tests/CodeContextKitTests/EmbeddingSeamTests.swift — 7 tests: FakeEmbedder determinism/distinctness/normalization, worker happy path, worker throwing-embedder graceful skip, worker no-embedder skip, dimension-change full re-embed.

    Verification: `swift build` clean, full `swift test` green 202/202 (14 suites), including all pre-existing TreeSitterWorkerTests unchanged. Adversarial double-check (via really-done) returned PASS; addressed its one cheap non-blocking finding (documented RoutedEmbedder's transcript-recording side effect on the adapter's doc comment). Its other non-blocking finding (a latent same-file-concurrent-invocation race in embedChunks/markIndexed) is not reachable by any current caller — TreeSitterWorker.run is only ever called sequentially — so left as a documented known limitation, not fixed, to stay in scope.

    Leaving task in `doing` per /implement workflow — ready for /review.
  timestamp: 2026-07-03T04:39:14.723771+00:00
depends_on:
- 01KWJ3S2AJFZPWWXRTKSQC3TW7
position_column: doing
position_ordinal: '80'
title: 'Embedding seam: TextEmbedding protocol, fake, RoutedEmbedder adapter, worker integration'
---
## What
Create `Sources/CodeContextKit/Embedding/TextEmbedding.swift` (`protocol TextEmbedding: Sendable { var dimension: Int; func embed(_ texts: [String]) async throws -> [[Float]] }`), `RoutedEmbedderAdapter.swift` (wraps FoundationModelsRouter's `RoutedEmbedder` — pure pass-through), and `Tests/.../Support/FakeEmbedder.swift` (deterministic hash-based L2-normalized vectors, configurable dimension). Integrate into the tree-sitter worker: batch-embed chunk texts after parsing, write via the store's embedding codec, set `embedded = 1` only when every chunk embedded; embedder absent/throwing → chunks persist with NULL embedding and `embedded = 0` (graceful skip). Record embedder dimension in the `meta` table; on mismatch with stored dimension, mark all chunks un-embedded for re-embedding.

## Acceptance Criteria
- [ ] Worker with FakeEmbedder produces normalized vectors of the configured dimension for every chunk
- [ ] Worker with a throwing embedder still writes chunks (NULL embedding, embedded=0) and logs, no crash
- [ ] Changing FakeEmbedder dimension between runs triggers full re-embed via the meta-table check

## Tests
- [ ] `Tests/CodeContextKitTests/EmbeddingSeamTests.swift`: happy path, graceful-skip path, dimension-change re-embed; FakeEmbedder determinism (same text → same vector)
- [ ] Run `swift test --filter EmbeddingSeamTests` → all pass

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
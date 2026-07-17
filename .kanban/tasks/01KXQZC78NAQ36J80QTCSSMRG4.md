---
comments:
- actor: claude-code
  id: 01kxrzs2509bqfctpse8ta7bb0
  text: |-
    Implementation landed and green (really-done: full suite 541 tests pass; SearchCorpus.swift diagnostics 0 errors / 0 warnings).

    Changes (committed diff is source-only):
    - Sources/.../Search/SearchCorpus.swift — rewrote the actor for incremental per-file re-index. Keeps a per-file cache (keyed by ts_chunks.file_path) of decoded embedding vectors + precomputed RankedDocuments. snapshot() short-circuits on unchanged generation; otherwise rebuild() does a cheap signature scan (SELECT id, COALESCE(LENGTH(embedding),0) — no text, no blobs) diffed against the cache, reloads only changed/new files, drops removed files, and repacks the cosine matrix from cached vectors (memcpy). Cold start / empty cache = full bulk load (the preserved fallback). SearchCorpusSnapshot unchanged.
    - Tests/.../SearchCorpusIncrementalTests.swift (new) — equivalence vs from-scratch (results + BM25 signals + chunkIds/matrix), perf-guard seams (re-tokenize/re-decode only the edited file), cosine repack preserves untouched vectors, deletion, no-op generation bump, and the dimension-change regression below.

    Note: Package.resolved is gitignored/untracked in this repo (commit 674553d) — not part of the commit. Locally it pins FoundationModelsRanker 29ed9dd; CI resolves main fresh from Package.swift, which now carries the streaming corpus APIs.

    double-check (really-done adversarial gate) verdict was REVISE, one real High finding: the original (id, hasEmbedding) change signature missed an in-place embedder DIMENSION change (reconcileEmbedderDimension clears all embeddings to NULL then re-embeds at the new width in place — same ids, NULL-ness nets unchanged), which would have served stale vectors + a wrong embeddingDimension and silently zeroed cosine. FIXED: the signature now carries embedding byte length (SQLite LENGTH(), no blob transfer), which subsumes presence and catches dimension changes; added inPlaceEmbeddingDimensionChangeIsPickedUpIncrementally to lock it in. Also fixed Finding 3 (counters now computed as locals and assigned once after the last await, reentrancy-safe). Finding-1 residual (a same-id, same-byte-width re-embed under a *different* embedder, only via IndexAdmin.rebuildIndex(.embedding)) is a logged accepted limitation, documented in SignatureEntry — closing it would require hashing every blob on every scan, defeating the cheap-scan design; it self-heals on the next re-chunk or dimension change.

    Left in `doing` for /review.
  timestamp: 2026-07-17T21:30:03.296176+00:00
- actor: claude-code
  id: 01kxrzt4rdybyat219bapfeccp
  text: 'Iteration 1 — /implement landed green in `doing`. SearchCorpus rewritten for per-file incremental re-index (cache keyed by ts_chunks.file_path; generation short-circuit; signature diff carries embedding byte-length to catch dimension changes). Added SearchCorpusIncrementalTests. Full suite green (541 tests, 0 failures). NOTE: implementer adopted Ranker''s additive streaming *pattern* + RankedDocument primitive rather than wrapping FoundationModelsRanker.SearchCorpus directly (its add() hardcodes item id as BM25 primary field; this corpus needs the symbol path there). User has flagged a follow-up to actually use Ranker''s streaming/updateable index APIs — capturing as a separate task.'
  timestamp: 2026-07-17T21:30:38.733046+00:00
- actor: claude-code
  id: 01kxs06na240e0ktz2dw488bqt
  text: 'Iteration 1 complete → DONE. /test green (541 tests), checkpoint committed locally (78c9fe4), /review clean (0 findings, 14 checks) and moved task doing→review→done. Verified-good commit is 78c9fe4. Total: 1 iteration.'
  timestamp: 2026-07-17T21:37:28.898690+00:00
position_column: done
position_ordinal: b480
title: Adopt Ranker streaming corpus APIs for incremental file re-index
---
## What
Adopt FoundationModelsRanker's streaming corpus APIs (once they land) to make file re-index incremental, replacing today's generation-invalidated wholesale reload.

Today: any store write bumps `generation`, and `SearchCorpus.snapshot()` responds by reloading the entire corpus from GRDB — every `ts_chunks` row re-fetched, every `RankedDocument` re-tokenized, the full embedding matrix repacked — even when a single file changed.

After adoption: a file re-index becomes `remove(group: filePath)` + `add(reparsedChunks)` on the Ranker's mutable streaming corpus — O(changed file), not O(corpus):
- The lexical corpus (RankedDocument precompute + BM25 corpus globals) mutates additively via the Ranker API; no per-save whole-corpus re-tokenize.
- The group key is the chunk's `filePath` (the Ranker API's group key is generic — FoundationModelsAgents uses session ids for the same mechanism).
- The packed vDSP cosine matrix stays CCK-side and is repacked wholesale on mutation — cheap memcpy of already-persisted vectors, no re-embedding. (Additive matrix mutation is the separate, reserved `CosineScoring` phase-2 seam in the Ranker plan; not this task.)
- GRDB remains the durable store exactly as-is: rows and embedding blobs unchanged; only the in-memory corpus lifecycle changes.

**Prerequisite (cross-repo):** FoundationModelsRanker tasks on its board — `xqrbq19` (streaming corpus: additive add/remove with incremental BM25 globals), plus its dependents (actor confinement, incremental embed on add). Do not start until `xqrbq19` is done and published on the Ranker `main` branch.

## Acceptance Criteria
- [ ] Re-indexing one file no longer triggers a whole-corpus reload: only that file's chunks are removed/re-added in the in-memory corpus
- [ ] Search results after an incremental file update are identical to results after a from-scratch snapshot load of the same store state (equivalence)
- [ ] BM25 globals (idf/avgdl) correct after incremental updates — asserted against a from-scratch rebuild
- [ ] Cosine still works: matrix repacked from persisted vectors on mutation; no embed calls during re-index of unchanged chunks
- [ ] Generation-based full reload remains as the cold-start path (first load) and as a fallback

## Tests
- [ ] Incremental-vs-wholesale equivalence: edit one file, compare search results and BM25 globals against a fresh `snapshot()` load
- [ ] Counting fake embedder: file re-index with unchanged embeddings performs zero embed calls
- [ ] Perf guard: re-index of one file in a many-file corpus does not re-tokenize untouched files' chunks (observable via instrumentation or a counting seam)

## Workflow
- Use /tdd — write failing tests first, then implement to make them pass.
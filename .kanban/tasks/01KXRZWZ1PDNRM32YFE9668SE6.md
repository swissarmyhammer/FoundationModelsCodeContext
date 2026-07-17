---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kxs06wjcgdbpq2xqd10agv26
  text: 'Picked up by /finish. Dependency ^cssmrg4 is done (verified-good commit 78c9fe4). Iteration 1: dispatching /implement. Goal per user: replace the hand-rolled cosine matrix in SearchCorpus with FoundationModelsRanker''s streaming/updateable index APIs, preserving all existing behavior (esp. symbolPathMatchOutranksBodyOnlyMatch) and tests.'
  timestamp: 2026-07-17T21:37:36.332079+00:00
- actor: claude-code
  id: 01kxs0cyb3wf13554x17jm6jmf
  text: |-
    BLOCKER — re-verified against the UPDATED Ranker on main (.build/checkouts/FoundationModelsRanker); the streaming/updateable index still cannot express this corpus's requirement. Marked stuck, no code changed, tree clean. Analysis:

    Inspected the updated API surface: SearchCorpus.swift (the value-type updateable index: init/init(items:)/add(items:)/remove(ids:)/remove(group:)/setEmbedding/embedding(forID:)), StreamingSearchCorpus.swift (new actor confinement + incremental embed-at-add, ^rayd7bq), Searchable/SearchItem.swift, RankedDocument.swift, HybridRanker.swift. What main ADDED since ^cssmrg4: actor-confinement (StreamingSearchCorpus) and per-row embedding storage keyed by id. What it did NOT add: any primary-field/id separation.

    Decisive gaps (both unresolvable):

    1) BM25/trigram primary field is hardcoded to the item id, no config. The ONLY RankedDocument construction site in the updateable index is `SearchCorpus.add` -> `RankedDocument(primaryText: item.id, bodyText: item.text)` (grep-confirmed: single site). The `Searchable` protocol exposes only id/text/summary/group — there is NO `primaryText` member and NO config to source the primary field from anything but the id. Our corpus REQUIRES the chunk's symbol path as the primary field (RankedDocument(primaryText: symbolPath, bodyText: text)); that is exactly what `symbolPathMatchOutranksBodyOnlyMatchInFusedOrdering` (SearchCodeTests) locks in. To get symbolPath as primary via Ranker, item.id would have to BE the symbol path.

    2) Id-uniqueness collides with symbol paths being non-unique, and id type is wrong. `SearchCorpus.add` drops any item whose id is already live (`guard rows[item.id] == nil else { continue }`, first-occurrence-wins). Symbol paths are legitimately non-unique across chunks (overloads, module-level/.other chunks, repeated members), so id=symbolPath would silently DROP real chunks (data loss / wrong corpus). Separately, Ranker's id is String while the consumer (SearchCode.fuseRankings) needs the Int64 ts_chunks.id for identity AND the lower-id tie-break (`snapshot.chunkIds`).

    Corroborating (not independently decisive):
    3) No carrier for per-chunk result metadata. SearchCode reads kind/startLine/endLine/filePath and a symbolPath distinct from id per result; Ranker's Row carries only text/summary/group/embedding — no seam for kind/lines, and none for a symbolPath distinct from id.
    4) Packed cosine matrix vs per-row loop. Our snapshot scores cosine as one vDSP_mmul over a contiguous chunkCount×dim matrix (SearchCorpusSnapshot.cosineScores, task says preserve); Ranker stores embeddings per-row and loops CosineScoring.cosineSimilarity. Numerically equivalent for normalized vectors but the packed matrix the task asks to keep is not exposed.

    No coherent partial adoption exists: wrapping Ranker's SearchCorpus while keeping our symbolPath/id/metadata/matrix on the side would mean TWO indexes, and Ranker's would carry the WRONG primary field (id-as-primary), breaking the symbol-path-outranks test. The current code already adopts the correct primitive (RankedDocument with primaryText: symbolPath) and the additive/streaming *pattern*; it cannot adopt the *container*.

    Specific Ranker API change that would unblock this (feature request for FoundationModelsRanker): add a primary-field seam decoupled from id — e.g. `var primaryText: String { get }` on `Searchable` (defaulting to `id` for source compat) with `SearchCorpus.add` using `RankedDocument(primaryText: item.primaryText, bodyText: item.text)` — together with keeping the id as a separate opaque identity (so non-unique symbol paths don't collide and the Int64 id survives), plus a way to carry arbitrary per-row payload metadata and/or a packed embedding matrix. Until Ranker exposes that, this task cannot be implemented without a broken result. Per the user directive, not forcing it.
  timestamp: 2026-07-17T21:40:54.755183+00:00
- actor: claude-code
  id: 01kxs0eher3jnhvef5h2xgxsav
  text: |-
    Iteration 1 → STUCK (genuine upstream API gap, no code changed, tree unchanged). Implementer inspected updated FoundationModelsRanker main (SearchCorpus.swift, new StreamingSearchCorpus.swift, Searchable/RankedDocument/HybridRanker) and found the two decisive blockers:

    1. Primary BM25/trigram field is hardcoded to item.id — the sole RankedDocument site is `add` → RankedDocument(primaryText: item.id, bodyText: item.text). Searchable exposes only id/text/summary/group; no primaryText seam or config. This corpus needs SYMBOL PATH as the primary field (the outranks test locks that in).
    2. id uniqueness/type collision — add() drops items whose id is already live (first-wins), but symbol paths are legitimately non-unique across chunks (overloads/module-level), so id=symbolPath would silently drop real chunks. Ranker id is String, but SearchCode.fuseRankings needs the Int64 ts_chunks.id for identity + lower-id tie-break. Ranker also stores per-row embeddings rather than the packed vDSP_mmul matrix the task requires.

    No coherent partial adoption exists. UNBLOCK requires an upstream change to FoundationModelsRanker: add a primaryText seam on Searchable decoupled from id (e.g. `var primaryText: String { get }` defaulting to id) with add() using item.primaryText, keep id as separate opaque identity, plus per-row payload metadata / packed-matrix access. Escalating to the user for a decision — this cannot be resolved inside this repo.
  timestamp: 2026-07-17T21:41:47.096201+00:00
- actor: claude-code
  id: 01kxs1wkped666ak6nyk7wh7sy
  text: |-
    UNBLOCKED upstream (user chose "You make the Ranker change"). Made the seam in FoundationModelsRanker and pushed to main (commit 18f8a80):
    - Added `primaryText` to the `Searchable` protocol (default extension returns `id`), plus a stored `primaryText` on `SearchItem` with an optional init param.
    - `SearchCorpus.add` now builds `RankedDocument(primaryText: item.primaryText, ...)` instead of `item.id`.
    - Added 4 tests (primaryText outranks body-only match; default==id preserves prior behavior; two items may share a primaryText with distinct ids; SearchItem default). Full Ranker suite green (235 tests). Backward compatible via the id default; only 3 files touched.
    NOTE: do NOT run `swift format`/`swiftformat` repo-wide on FoundationModelsRanker — it has no format config and Apple's swift-format reformats all 48 files spuriously. Match surrounding style by hand.
    Next: bump the Ranker dependency in this repo and adopt primaryText in Sources/.../Search/SearchCorpus.swift (id = unique Int64 chunk id as String; primaryText = symbol path), preserving symbolPathMatchOutranksBodyOnlyMatch and all incremental tests.
  timestamp: 2026-07-17T22:06:56.718688+00:00
- actor: claude-code
  id: 01kxs28hvf2cxz6nr4rxb0zwhb
  text: 'Picked up. Verified the Ranker checkout has the primaryText seam (SearchItem.init(...,primaryText:), Searchable.primaryText default=id, SearchCorpus.add builds RankedDocument(primaryText: item.primaryText,...)). Plan: adopt FMR.SearchCorpus (value type) as the retrieval-state container inside our actor SearchCorpus — id=String(chunkId), primaryText=symbolPath, body=text, group=filePath. Incremental splice = remove(group: filePath)+add(items:) on changed files, remove(group:) on deleted files; embeddings via setEmbedding/embedding(forID:). Keep SearchCorpusSnapshot''s exact public shape + instrumentation counters so SearchCode needs no change. Documented residuals (kept by necessity): (a) a per-file metadata/signature side-cache — FMR.Row carries no filePath/symbolPath-string/kind/line payload and no change-signature; (b) the packed vDSP cosine matrix, repacked from FMR''s per-row embeddings — the incremental tests assert directly on snapshot.embeddingMatrix and SearchCorpusMatvecTests exercises CosineScoring.matvecScores, so cosine stays on the packed-matrix path rather than HybridRanker. Establishing green baseline first.'
  timestamp: 2026-07-17T22:13:28.047935+00:00
- actor: claude-code
  id: 01kxs39t43chtc6wmj3h519bsw
  text: |-
    DONE (green, left in doing for review). Single file changed: Sources/FoundationModelsCodeContext/Search/SearchCorpus.swift.

    What changed: the actor SearchCorpus now uses FoundationModelsRanker.SearchCorpus (value-type updateable index, aliased RankerIndex) as its retrieval-state container instead of the hand-rolled per-file cache of RankedDocuments + decoded vectors. Mapping via the new primaryText seam: id=String(ts_chunks.id), primaryText=symbolPath, body=text, group=filePath. Incremental re-index is now index.remove(group: filePath)+index.add(items:) on changed files and remove(group:) on deleted files (the group-keyed additive streaming shape); embeddings flow through index.setEmbedding(_:forID:ifTextMatches:)/embedding(forID:). RankedDocument construction and per-row vector storage are the Ranker's now, not ours.

    Adopted vs kept: the Ranker index owns all retrieval state (ids + RankedDocuments + per-row embeddings) and the add/remove(group) mechanics. Two things stay local as documented residuals, both because the Ranker's Row genuinely can't carry them: (a) a per-file FileEntry holding the change signature (id+embeddingByteCount, for the cheap diff) plus each chunk's result metadata (filePath, symbolPath-as-plain-string, kind, line range) — none of which round-trips through Ranker's text/summary/group/embedding row; (b) the packed vDSP cosine matrix, repacked at assembly from the index's per-row vectors — the incremental tests assert directly on snapshot.embeddingMatrix and SearchCorpusMatvecTests exercises CosineScoring.matvecScores, so cosine stays on the packed-matrix path rather than HybridRanker. SearchCorpusSnapshot's public shape and the lastBuildReTokenized/ReDecoded counters are unchanged, so SearchCode needed no change.

    Tests: full suite green — 541 tests, 47 suites, 0 failures. All hard-constraint tests pass unchanged (symbolPathMatchOutranksBodyOnlyMatchInFusedOrdering; all of SearchCorpusIncrementalTests: incremental equivalence, chunkId/matrix equality, per-file re-tokenize/re-decode perf guards, no-op generation bump, deletion, in-place dimension-change regression; all SearchCode tests). Adversarial double-check: PASS (verified signature completeness against TreeSitterWorker's writers, id ordering, no dedup collision / no assemble force-unwrap desync, dimension detection, actor-reentrancy discipline).

    FORMAT NOTE / discovered constraint: did NOT run `swift format -i -r Sources Tests`. Neither locally-installed formatter reproduces this repo's committed style — the `swift format` subcommand (a "main" dev build) and homebrew swift-format 602.0.0 each rewrite ~120 previously-clean committed files (e.g. WireTests churns 1368 lines, SearchCode.swift 686), and there is no .swift-format config or CI format gate in the repo. This is the same swift-format version-mismatch churn already documented for the FoundationModelsRanker checkout, here hitting this repo with the available toolchains. Running it would have produced a massive spurious cross-repo diff, so I reverted that churn and kept only my one file, hand-matched to the surrounding style (4-space indent, same doc-comment conventions/wrapping as the original). Working tree contains exactly one modified source file.
  timestamp: 2026-07-17T22:31:37.859723+00:00
- actor: claude-code
  id: 01kxs3av3f96wa13dj3945gtqf
  text: 'Iteration 1 — /implement landed green in `doing`. SearchCorpus.swift now uses FoundationModelsRanker.SearchCorpus (aliased RankerIndex) as its retrieval-state container via the new primaryText seam: id=String(ts_chunks.id), primaryText=symbol path, body=text, group=file path. Incremental re-index = index.remove(group: filePath)+add(items:) on changed files, remove(group:) on deleted; embeddings via setEmbedding/embedding(forID:). Ranker owns ids+RankedDocuments+per-row vectors+add/remove-by-group. Two documented residuals kept local because Ranker''s Row can''t carry them: (1) per-file FileEntry with change signature + chunk result metadata (filePath/symbolPath/kind/lines); (2) packed vDSP cosine matrix repacked at assembly — the incremental tests + SearchCorpusMatvecTests assert on snapshot.embeddingMatrix/CosineScoring.matvecScores, so cosine stays on the packed-matrix path. SearchCorpusSnapshot public shape + counters unchanged, so SearchCode untouched. Full suite green (541 tests). NOTE: implementer did NOT run swift format — same version-mismatch churn as the Ranker repo (both local formatters rewrite ~120 committed files; no .swift-format config, no CI format gate). Kept one modified source file, hand-matched to style.'
  timestamp: 2026-07-17T22:32:11.631247+00:00
- actor: claude-code
  id: 01kxs4316p6qnvs41mgams3ka6
  text: 'Iteration 1 review: 5 confirmed findings (all clarity/idiom in Sources/.../Search/SearchCorpus.swift) — chunkIds→chunkIDs acronym casing; two manual grouping loops → Dictionary(grouping:by:); a force-unwrap → guard let/preconditionFailure; a manual parallel-sequence dict build → Dictionary(uniqueKeysWithValues: zip(...)). Task back doing→ /implement to fix at root. Iteration 2 dispatching.'
  timestamp: 2026-07-17T22:45:24.310075+00:00
- actor: claude-code
  id: 01kxs59z1tjh8y2kfaxs33rs1q
  text: |-
    Iteration 2 — /implement worked all 5 review findings at the root, one file of real changes: Sources/.../Search/SearchCorpus.swift (plus mechanical reference updates in SearchCode.swift, FindDuplicates.swift, and two test files).

    1. Acronym casing: renamed public property SearchCorpusSnapshot.chunkIds → chunkIDs, and updated every reference across the module (SearchCorpus.swift decl+doc backticks+init label, SearchCode.swift x3, FindDuplicates.swift x1) and the two test assertion sites (SearchCodeTests, SearchCorpusIncrementalTests). Grep-verified no `.chunkIds`/`chunkIds:` property references remain anywhere in Sources/Tests; the only surviving lowercase `chunkIds` is an unrelated DB-fetch local var in SearchCorpusIncrementalTests.swift:254, correctly left alone. Checked the rest of the file for other lowercased acronyms — none (forID/documentByID already correct).
    2+3. Both manual per-file grouping loops → Dictionary(grouping:by:): loadSignatures returns `Dictionary(grouping: rows, by: \.filePath).mapValues { $0.map(\.entry) }`; loadAllRows returns `Dictionary(grouping: rows, by: \.filePath)`. Per-file id order preserved (SQL still ORDER BY filePath,id), which the signature-diff and chunkID equality depend on.
    4. Force-unwrap in assemble()'s rankedDocuments: init arg → guard let ... else { preconditionFailure(...) } with a desync message. Only force-unwrap in the file; no others recur.
    5. Manual parallel-sequence dict build (documentByID) → Dictionary(uniqueKeysWithValues: zip(index.ids, index.documents)). index.ids are unique by the Ranker's first-wins add() invariant, so no trap risk vs the old last-write-wins loop.

    Tests: full suite green — 541 tests, 47 suites, 0 failures. Hard-constraint suites confirmed green in a fresh run: symbolPathMatchOutranksBodyOnlyMatchInFusedOrdering, all SearchCorpusIncrementalTests (incl. incrementalSnapshotChunkIds, deletion, inPlaceEmbeddingDimensionChange), SearchCorpusMatvecTests, SearchCodeTests. swift build clean, no warnings. Adversarial double-check: PASS, no findings (verified duplicate-key/ordering/preconditionFailure equivalence and rename completeness).

    Did NOT run swift format (documented repo-wide formatter version-mismatch churn). Working tree limited to the 5 changed source/test files. Left in doing for /review.
  timestamp: 2026-07-17T23:06:40.058694+00:00
depends_on:
- 01KXQZC78NAQ36J80QTCSSMRG4
position_column: doing
position_ordinal: '80'
title: Use FoundationModelsRanker streaming/updateable index directly instead of the hand-rolled cosine matrix
---
Follow-up to ^cssmrg4. That task adopted the Ranker *additive streaming pattern* plus the `RankedDocument` primitive, but deliberately did NOT wrap `FoundationModelsRanker.SearchCorpus` directly — it kept a hand-rolled per-file cache + packed cosine matrix in `Sources/FoundationModelsCodeContext/Search/SearchCorpus.swift`. The stated reason: Ranker's `add()` hardcodes the item id as the BM25/trigram primary field, whereas this corpus needs the chunk's symbol path as the primary field (the `symbolPathMatchOutranksBodyOnlyMatch` test depends on it) alongside a separate int64 id and packed cosine matrix.

Goal (per user directive 2026-07-17): actually use Ranker's streaming / updateable index APIs for the incremental re-index path, rather than maintaining a parallel hand-rolled index.

Scope to investigate:
- Review the updated FoundationModelsRanker (main, streaming corpus / updateable index APIs) at .build/checkouts/FoundationModelsRanker.
- Determine whether Ranker's updateable index now supports a distinct primary-field/id separation (or a config) that satisfies the symbol-path-outranks-body requirement. If yes, replace the hand-rolled matrix with Ranker's updateable index.
- Preserve all existing SearchCorpus behavior and tests (symbolPathMatchOutranksBodyOnlyMatch, cosine equivalence, incremental equivalence, deletion, dimension-change regression).
- If Ranker genuinely cannot express the primary-field requirement, document that as a blocker with the specific API gap and stop.

Verify: `swift build`, `swift test` fully green; format with `swift format -i -r Sources Tests`.

## Review Findings (2026-07-17 17:37)

- [x] `Sources/FoundationModelsCodeContext/Search/SearchCorpus.swift:25` — Property name `chunkIds` violates uniform acronym casing: interior acronyms in lowerCamelCase should be uniformly up-cased. Rename property `chunkIds` → `chunkIDs`. Update all references: line 74 (`chunkIds.count`), initializer parameter label at line 324, and documentation backtick references.
- [x] `Sources/FoundationModelsCodeContext/Search/SearchCorpus.swift:234` — Manually groups rows by key using a loop and default dictionary access, reimplementing Dictionary(grouping:by:) from the standard library. Replace lines 234-238 with `let signatures = Dictionary(grouping: rows, by: \.filePath).mapValues { $0.map(\.entry) }`.
- [x] `Sources/FoundationModelsCodeContext/Search/SearchCorpus.swift:253` — Manually groups rows by key using a loop and default dictionary access, reimplementing Dictionary(grouping:by:) from the standard library. Replace lines 253-257 with `let rowsByFile = Dictionary(grouping: rows, by: \.filePath)`.
- [x] `Sources/FoundationModelsCodeContext/Search/SearchCorpus.swift:346` — Force unwrap `!` appears in non-test production code. Replace force unwrap: use `guard let` + error handling, or replace `!` with `?? fatalError()` / `?? preconditionFailure()` if asserting a programmer-error invariant.
- [x] `Sources/FoundationModelsCodeContext/Search/SearchCorpus.swift:374` — Manually initializes a dictionary from parallel sequences using a loop and reserveCapacity, reimplementing Dictionary(uniqueKeysWithValues:) from the standard library. Replace lines 374-378 with `let documentByID = Dictionary(uniqueKeysWithValues: zip(index.ids, index.documents))`.
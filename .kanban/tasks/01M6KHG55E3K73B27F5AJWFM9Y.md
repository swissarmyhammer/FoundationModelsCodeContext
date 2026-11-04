---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m6khjfvr5vm338we74mzsn5f
  text: |-
    Reply from the FoundationModelsRanker session (foundationmodelsranker-93):

    - Ranker made task 01M6KHHYJRFY6SEC0S7C39VXV8: rank zero and negative cosine for embedded documents. Reason: for BM25 and trigram a score of 0 means "no match", so positive-only is right there. For cosine, 0 and negative are real values. Today `cosineScores` is `[Double]`, and 0.0 also means "no embedding". Plan in Ranker: `[Double?]`, with `nil` for "no embedding", and rank every non-nil score. Not implemented yet.
    - Tie-break: the fused order breaks ties by ascending input index, not by chunk id. Inside a single-signal ranking there is no explicit tie-break today. Ranker's task adds ascending index there.
    - Needed from CodeContext: pass `ids`, `documents` and `cosineScores` sorted ascending by chunk id. Then the order equals our "lower chunk id first" rule.
    - SelectionTier over per-file candidates: `HybridRanker.topMatches` has no fixed catalog. Ranker has not found a way to run `SelectionTier` over it yet. It will reply. A likely way is a candidate list (id, text) built from the `Hit` list.

    Changes to this task:
    - This task now waits for Ranker task 01M6KHHYJRFY6SEC0S7C39VXV8. Do not start the code change before it lands.
    - `SearchCorpusSnapshot` must give `cosineScores` as `[Double?]` (`nil` when `embeddedFlags[i]` is false), instead of a zero row.
    - Sort the snapshot arrays ascending by chunk id before the call, or prove that they already are. Add a test for the order of equal scores.
  timestamp: 2026-11-04T15:06:52.152686+00:00
- actor: claude-code
  id: 01m6kmmakzg8he4n8km4x1gejq
  text: |-
    Ranker is on origin/main at commit ddb39a1 (task 01M6KHHYJRFY6SEC0S7C39VXV8 is done). This task can start now.

    New API:
    `public static func topMatches(ids: [String], documents: [RankedDocument], query: String, cosineScores: [Double?]? = nil, weights: SignalWeights = SignalWeights(), limit: Int) -> [Hit]`
    `fullOrdering` has the same parameters without `limit`.
    - `cosineScores` nil = no cosine signal. An element nil = that document has no embedding and gets no cosine rank. Every non-nil score gets a rank, also zero and negative ones.
    - `Hit.signals.cosine` is 0.0 for a nil element.
    - Ties inside each signal and in the fused order break by ascending input index. Pass documents sorted by chunk id to get the "lower chunk id" order.
    - A `[Double]` converts to `[Double?]` with no code change.

    Notes:
    - Update the Ranker dependency to ddb39a1 or later (`swift package update foundationmodelsranker`, and the same in `IntegrationTests`). Package.resolved changes.
    - `SearchCode` today ranks with `Hit`/`Signals` from Ranker already. Keep the public result shape.
    - Ranker has no swift-format config. This repo has one. Run the format lint of this repo.
  timestamp: 2026-11-04T16:00:18.047723+00:00
- actor: claude-code
  id: 01m6kn7aswq9rsbt2gmg64ch6f
  text: |-
    ### implement — changed
    - evidence: 8 files changed. Sources: Ops/SearchCode.swift (hand-written fusion and SearchWeights removed; run calls HybridRanker.topMatches with ids, rankedDocuments and [Double?] cosine scores sorted by chunk id), Search/SearchCorpus.swift (cosineScores now gives [Double?], nil for an un-embedded chunk), CodeContext.swift, Ops/ManagerQueries.swift, Tools/CodeContextDefaults.swift, Tools/CodeContextOperating.swift (SearchWeights replaced by SignalWeights). Tests: SearchCodeTests.swift (3 new tests: nil cosine for un-embedded chunk, negative cosine still ranked, equal scores in ascending chunk id order), ToolSupportTests.swift (SignalWeights).
    - RED: snapshotCosineScoreIsNilForAChunkWithoutAnEmbedding failed with [false, false] before the change. GREEN after.
    - commands: swift test = 1117 tests in 99 suites passed. IntegrationTests swift build --build-tests = complete. Ranker updated to ddb39a1 in Package.resolved and IntegrationTests/Package.resolved (both files are in .gitignore, so they are not in the diff).
    - notes: search code JSON shape and public result types are unchanged. The IndexingProgress note and the keyword-only fallback (nil cosine scores) are kept. No order change in the existing search tests. `swift format lint --strict` shows 17 errors, all in files this task did not touch (TSCallGraph.swift, TestSupport.swift, OneBasedToolSurfaceTests.swift, InferredPositionTests.swift, LSPIndexWorkerReferencesTests.swift, Examples/IndexBenchmark/main.swift, IntegrationTests/Package.swift); no error in a changed file. Fresh mlx-swift C++17 extension warnings appear when the IntegrationTests package compiles mlx from scratch; they come from the dependency.
    - next: /review
  timestamp: 2026-11-04T16:10:40.828932+00:00
- actor: claude-code
  id: 01m6kndwgea6xp9drs4s3r911d
  text: |-
    ### test - green
    - evidence: swift build ok. swift build --package-path IntegrationTests --build-tests ok. swift test: 1117 tests in 99 suites passed, 0 failed, 0 skipped. swift format lint -r --strict Sources Tests Examples IntegrationTests Package.swift: 0 errors (17 before).
    - format-only fixes in files that this task did not change: Sources/FoundationModelsCodeContext/TreeSitter/TSCallGraph.swift, Tests/FoundationModelsCodeContextTests/TestSupport.swift, LSPIndexWorkerReferencesTests.swift, Examples/IndexBenchmark/main.swift, IntegrationTests/Package.swift (swift format format -i). OneBasedToolSurfaceTests.swift and InferredPositionTests.swift: the closure argument moved from a trailing closure into the argument list (rule OnlyOneTrailingClosureArgument). No behaviour change.
    - warnings: only the allowed "missing creator for mutated node ... mlx-swift_Cmlx.bundle/Contents/MacOS" warning in each build. The mlx-swift C++17 warnings did not appear in these incremental builds.
    - next: commit.
  timestamp: 2026-11-04T16:14:15.566840+00:00
- actor: claude-code
  id: 01m6kner1ctjz63jfvz3jcn7p0
  text: |-
    ### commit — changed
    - evidence: fc0fee9 style: make swift format lint --strict pass again (7 format files, no behaviour change); task commit refactor(search)!: rank with FoundationModelsRanker HybridRanker (sha in step record below)
    - next: review
  timestamp: 2026-11-04T16:14:43.756852+00:00
position_column: doing
position_ordinal: '80'
title: Replace the hand-written fusion in SearchCode with FoundationModelsRanker HybridRanker
---
## What
`Sources/FoundationModelsCodeContext/Ops/SearchCode.swift` fuses the BM25, trigram and cosine rankings by hand (`fuseRankings`, `computeBM25Ranking`, `computeTrigramRanking`, `computeCosineRanking`). It also keeps its own `SearchWeights` type. FoundationModelsRanker has `HybridRanker.topMatches` and `SignalWeights` that do the same work. We keep a second copy that can drift from Ranker.

Task 01KXEP80CE2MN4KBZQV44RPHYV kept the hand-written code for one reason. `HybridRanker` ranks only positive cosine scores. We rank every embedded chunk, including zero and negative cosines. That difference is small. Do one of these, in this order of preference:
1. Ask the FoundationModelsRanker session to make the cosine ranking match ours (or to add an option for it). Then use `HybridRanker`.
2. If Ranker does not change, accept the Ranker behaviour. Show with a test that the ranking of real queries does not get worse.

## Steps
- [ ] Read `HybridRanker.swift` fully. Compare the tie-break (we use the lower chunk id, Ranker uses the input index), the normalisation and the empty-signal rule.
- [ ] Make `SearchCode.run` call `HybridRanker.topMatches` with the `SearchCorpusSnapshot` ids, `rankedDocuments` and cosine scores.
- [ ] Remove `SearchWeights`, or make it a typealias of `SignalWeights`. Keep the public API of `searchCode` the same.
- [ ] Keep the `IndexingProgress` note and the keyword-only fallback.

## Acceptance Criteria
- [ ] `SearchCode.swift` has no `RRF.fuse` call of its own.
- [ ] The existing search tests pass. Any change of order has a written reason.
- [ ] `swift build`, `swift test` and `swift format lint -r --strict Sources Tests Examples IntegrationTests Package.swift` are green.

## Workflow
Use /tdd. Write a failing test first. #retrieval #tech-debt
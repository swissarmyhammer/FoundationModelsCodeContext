---
assignees:
- claude-code
depends_on:
- 01M2JFKFQ1DS4B95ACWJPQWGMW
position_column: todo
position_ordinal: '8380'
title: Use FoundationModelsRanker.TextEmbedding as the one embedding-model type
---
## What
The user said: "we need to pass ranker an LLM and an Embedder". Ranker's `Searcher` takes `embedder: (any TextEmbedding)?` and `session: any AgentSession` (a FoundationModels `LanguageModelSession` conforms). Ranker's `StreamingSearchCorpus(embedder:)` takes the same `FoundationModelsRanker.TextEmbedding`. This repo's `TextEmbedding` protocol (`Sources/FoundationModelsCodeContext/Embedding/TextEmbedding.swift`) is a byte-identical copy of Ranker's. Two copies mean that a caller's model must conform two times, and a file that imports both modules gets an ambiguous name.

Make the embedding-model type one protocol: Ranker's. Then a caller conforms one time, and the same value works for CodeContext indexing, `searchCode`, and every Ranker API. Ranker `origin/main` (`0015ff2`) still has `Sources/FoundationModelsRanker/TextEmbedding.swift`.

CodeContext does not use Ranker's selection tier (`Searcher`, `SelectionTier`, `AgentSession`). Thus CodeContext takes no LLM input. Do not add one.

- [ ] Replace the protocol in `Sources/FoundationModelsCodeContext/Embedding/TextEmbedding.swift` with `import FoundationModelsRanker` and `public typealias TextEmbedding = FoundationModelsRanker.TextEmbedding`. Use the same pattern as `Hit`/`Signals` in `Sources/FoundationModelsCodeContext/Search/RankingTypes.swift`. The doc comment gives the contract: one vector per input, in input order, each `dimension` long and L2-normalized. The host supplies the model. There is no Router in this package.
- [ ] Make sure that all current uses compile with no change: `CodeContext.swift` (lines 40, 139, 641), `CodeContextManager.swift` (lines 38, 94, 375), `Index/TreeSitterWorker.swift` (lines 53, 212, 227, 256), `Ops/SearchCode.swift` (lines 193, 286, 306), and `Tests/FoundationModelsCodeContextTests/Support/FakeEmbedder.swift`. If a file that imports both modules gets an "ambiguous type" error, qualify the name in that file.
- [ ] Add `Tests/FoundationModelsCodeContextTests/SharedEmbedderTests.swift` (a new file, so that `CallerEmbedderPublicAPITests.swift` stays free of a Ranker import). In it, one caller-side value that conforms to `FoundationModelsRanker.TextEmbedding` goes to `CodeContext(rootDirectory:embedder:autoInstall: LspAutoInstall(isEnabled: false))` and also to `FoundationModelsRanker.StreamingSearchCorpus(embedder:)` (other parameters at their defaults).

## Acceptance Criteria
- [ ] `rg -n "protocol TextEmbedding" Sources` gives no output.
- [ ] `FoundationModelsCodeContext.TextEmbedding` and `FoundationModelsRanker.TextEmbedding` are the same type (the new test compiles and passes).
- [ ] No public call site changes: `CodeContext(rootDirectory:embedder:)` and `CodeContextManager(embedder:)` keep their signatures.

## Tests
- [ ] New test `oneEmbedderValueServesCodeContextAndRankerCorpus` in `Tests/FoundationModelsCodeContextTests/SharedEmbedderTests.swift`. Red step: it does not compile before the typealias, because the value conforms to Ranker's protocol and not to CodeContext's.
- [ ] `Tests/FoundationModelsCodeContextTests/EmbeddingSeamTests.swift` stays green.
- [ ] `swift build` exits 0.
- [ ] `swift build --package-path IntegrationTests --build-tests` exits 0.
- [ ] `swift format lint -r --strict Sources Tests Examples IntegrationTests Package.swift` exits 0.
- [ ] `swift test` exits 0.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #router #tech-debt
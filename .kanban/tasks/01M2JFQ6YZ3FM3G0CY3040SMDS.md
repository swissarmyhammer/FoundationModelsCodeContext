---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m2jt042h10k40qrc2wxz0cxr
  text: |-
    Research and discoveries:
    - Ranker checkout in .build/checkouts is 545cb06. `FoundationModelsRanker.TextEmbedding` has the same signature as the local copy (`dimension`, `embed(_:)`, `Sendable`). `StreamingSearchCorpus.init(embedder:onDiagnostic:)` has defaults for both parameters.
    - In this module, a local `public typealias TextEmbedding` shadows the imported protocol. Thus the source files that import both modules (`SearchCode.swift`, `CodeContextManager.swift`, `SearchCorpus.swift`) need no qualification. Test files that import both modules also compile with no change.
    - The new test file qualifies `FoundationModelsRanker.TextEmbedding`, `StreamingSearchCorpus` and `SearchItem`. This module has its own `SearchCorpus` actor, so the qualified names prevent confusion.
    - `CodeContext.stop()` returns at once when `start()` did not run. Thus the new test does not call it.
    - RED: `swift build --build-tests` failed on `SharedEmbedderTests.swift` with "argument type 'SharedEmbedderTests.RankerConformingEmbedder' does not conform to expected type 'TextEmbedding'". This is the expected reason.
    - GREEN: after the typealias replaced the protocol, all builds, the lint and `swift test` pass.
  timestamp: 2026-09-15T15:12:05.713761+00:00
- actor: claude-code
  id: 01m2jt0r08mmf8vrwy2cha0ezp
  text: |-
    ### implement — changed
    - evidence: 2 files. Sources/FoundationModelsCodeContext/Embedding/TextEmbedding.swift (the protocol is replaced by `public typealias TextEmbedding = FoundationModelsRanker.TextEmbedding`). Tests/FoundationModelsCodeContextTests/SharedEmbedderTests.swift (new, test `oneEmbedderValueServesCodeContextAndRankerCorpus`). RED: `swift build --build-tests` failed, "does not conform to expected type 'TextEmbedding'". GREEN: `swift build` exit 0. `swift build --build-tests` exit 0. `swift build --package-path IntegrationTests --build-tests` exit 0. `swift format lint -r --strict Sources Tests Examples IntegrationTests Package.swift` exit 0. `rg -n "protocol TextEmbedding" Sources` gave no output. `swift test` exit 0: 563 tests in 49 suites passed, 0 skipped, 0 warnings. SharedEmbedderTests and EmbeddingSeamTests passed. No other file changed. CallerEmbedderPublicAPITests.swift does not import FoundationModelsRanker.
    - next: /review
  timestamp: 2026-09-15T15:12:26.120978+00:00
depends_on:
- 01M2JFKFQ1DS4B95ACWJPQWGMW
position_column: doing
position_ordinal: '80'
title: Use FoundationModelsRanker.TextEmbedding as the one embedding-model type
---
## What
The user said: "we need to pass ranker an LLM and an Embedder". Ranker's `Searcher` takes `embedder: (any TextEmbedding)?` and `session: any AgentSession` (a FoundationModels `LanguageModelSession` conforms). Ranker's `StreamingSearchCorpus(embedder:)` takes the same `FoundationModelsRanker.TextEmbedding`. This repo's `TextEmbedding` protocol (`Sources/FoundationModelsCodeContext/Embedding/TextEmbedding.swift`) is a byte-identical copy of Ranker's. Two copies mean that a caller's model must conform two times, and a file that imports both modules gets an ambiguous name.

Make the embedding-model type one protocol: Ranker's. Then a caller conforms one time, and the same value works for CodeContext indexing, `searchCode`, and every Ranker API. Ranker `origin/main` (`0015ff2`) still has `Sources/FoundationModelsRanker/TextEmbedding.swift`.

CodeContext does not use Ranker's selection tier (`Searcher`, `SelectionTier`, `AgentSession`). Thus CodeContext takes no LLM input. Do not add one.

- [x] Replace the protocol in `Sources/FoundationModelsCodeContext/Embedding/TextEmbedding.swift` with `import FoundationModelsRanker` and `public typealias TextEmbedding = FoundationModelsRanker.TextEmbedding`. Use the same pattern as `Hit`/`Signals` in `Sources/FoundationModelsCodeContext/Search/RankingTypes.swift`. The doc comment gives the contract: one vector per input, in input order, each `dimension` long and L2-normalized. The host supplies the model. There is no Router in this package.
- [x] Make sure that all current uses compile with no change: `CodeContext.swift` (lines 40, 139, 641), `CodeContextManager.swift` (lines 38, 94, 375), `Index/TreeSitterWorker.swift` (lines 53, 212, 227, 256), `Ops/SearchCode.swift` (lines 193, 286, 306), and `Tests/FoundationModelsCodeContextTests/Support/FakeEmbedder.swift`. If a file that imports both modules gets an "ambiguous type" error, qualify the name in that file.
- [x] Add `Tests/FoundationModelsCodeContextTests/SharedEmbedderTests.swift` (a new file, so that `CallerEmbedderPublicAPITests.swift` stays free of a Ranker import). In it, one caller-side value that conforms to `FoundationModelsRanker.TextEmbedding` goes to `CodeContext(rootDirectory:embedder:autoInstall: LspAutoInstall(isEnabled: false))` and also to `FoundationModelsRanker.StreamingSearchCorpus(embedder:)` (other parameters at their defaults).

## Acceptance Criteria
- [x] `rg -n "protocol TextEmbedding" Sources` gives no output.
- [x] `FoundationModelsCodeContext.TextEmbedding` and `FoundationModelsRanker.TextEmbedding` are the same type (the new test compiles and passes).
- [x] No public call site changes: `CodeContext(rootDirectory:embedder:)` and `CodeContextManager(embedder:)` keep their signatures.

## Tests
- [x] New test `oneEmbedderValueServesCodeContextAndRankerCorpus` in `Tests/FoundationModelsCodeContextTests/SharedEmbedderTests.swift`. Red step: it does not compile before the typealias, because the value conforms to Ranker's protocol and not to CodeContext's.
- [x] `Tests/FoundationModelsCodeContextTests/EmbeddingSeamTests.swift` stays green.
- [x] `swift build` exits 0.
- [x] `swift build --package-path IntegrationTests --build-tests` exits 0.
- [x] `swift format lint -r --strict Sources Tests Examples IntegrationTests Package.swift` exits 0.
- [x] `swift test` exits 0.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #router #tech-debt
---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m2jr4c7ytzh929wk1w0wtzxe
  text: |-
    Research before the update:
    - Ranker origin/main is now 545cb06, not 0015ff2. `git show origin/main:Package.swift | rg -c Router` gives no output (exit 1). The precondition holds.
    - Root Package.resolved pins Ranker 18f8a804. `rg -c Router .build/checkouts/FoundationModelsRanker/Package.swift` gives 19. This is the red step.
    - IntegrationTests/Package.resolved pins Ranker 5ab7b1ad. Its checkout Package.swift has no Router text already. The two packages resolved different Ranker revisions.
    - Root Package.swift comments on the Router dependency say that Ranker also depends on Router. That text becomes false after this update. This task must not change the Router dependency, so the later task ^kgmwgmw must correct that comment.
  timestamp: 2026-09-15T14:39:27.998950+00:00
- actor: claude-code
  id: 01m2jrbx63br98t8n53pywy3jc
  text: |-
    ### implement — changed
    - evidence: The Ranker pin moved from 18f8a804 (root) and 5ab7b1ad (IntegrationTests) to 545cb06 in both gitignored Package.resolved files. No tracked file changed, and no compile break occurred, so no Swift source edit was necessary.
      - red: `rg -c Router .build/checkouts/FoundationModelsRanker/Package.swift` gave 19 before the update.
      - `swift package update foundationmodelsranker` exit 0, "resolved at main (545cb06)".
      - `swift package --package-path IntegrationTests update foundationmodelsranker` exit 0, "resolved at main (545cb06)". Note: `--package-path` must come before `update`. After `update` it gives "Unknown option".
      - green: `rg -c Router` on the root and IntegrationTests Ranker checkouts gives no output (exit 1).
      - `swift build` exit 0. The only warnings come from the third-party mlx-swift checkout (C++17 extension, missing creator node).
      - `swift build --package-path IntegrationTests --build-tests` exit 0.
      - `swift format lint -r --strict Sources Tests Examples IntegrationTests Package.swift` exit 0.
      - `swift test` exit 0: 561 tests in 47 suites passed, 0 failed.
    - next: /review. A commit step will find no tracked change, because git ignores Package.resolved.
  timestamp: 2026-09-15T14:43:34.723288+00:00
position_column: doing
position_ordinal: '80'
title: Move this repo to the Router-free FoundationModelsRanker main
---
## What
Ranker `origin/main` (`0015ff2`, 2026-09-14) has no FoundationModelsRouter in `Package.swift` or `Sources`. Its `Searcher` takes `embedder: (any TextEmbedding)?` and `session: any AgentSession` (a FoundationModels `LanguageModelSession` conforms). This repo's local `Package.resolved` pins Ranker `18f8a804`, an older revision that still depends on Router. `Package.resolved` is in `.gitignore` (line 7). Thus CI resolves Ranker `main` again on each run, and only local checkouts use the old revision.

Another agent owns the sibling repo `../FoundationModelsRanker`. Do not edit that repo from this task. If this repo needs a Ranker change, send a request to that agent.

- [x] Precondition: `git -C ../FoundationModelsRanker fetch` then `git -C ../FoundationModelsRanker show origin/main:Package.swift | rg -c Router` gives no output. If Router is present, stop and report.
- [x] Run `swift package update foundationmodelsranker`, and the same command with `--package-path IntegrationTests`.
- [x] Fix each compile break in this repo that the new Ranker causes. This repo uses only Ranker's retrieval API: `SearchCorpus`, `CosineScoring`, `BM25`, `RankedDocument`, `Tokenizer`, `Trigram`, `Hit` and `Signals`. These are used in `Sources/FoundationModelsCodeContext/Search/SearchCorpus.swift`, `Search/RankingTypes.swift`, `Ops/SearchCode.swift`, `Ops/FindDuplicates.swift`, and the tests.
- [x] Do not commit `Package.resolved`, because git ignores it.

## Acceptance Criteria
- [x] `rg -c Router .build/checkouts/FoundationModelsRanker/Package.swift` gives no output (the resolved Ranker has no Router).
- [x] `swift build` and `swift test` pass with the new Ranker.

## Tests
- [x] Red step: before the update, `rg -c Router .build/checkouts/FoundationModelsRanker/Package.swift` gives a count. After the update, it gives no output.
- [x] `swift build` exits 0.
- [x] `swift build --package-path IntegrationTests --build-tests` exits 0.
- [x] `swift format lint -r --strict Sources Tests Examples IntegrationTests Package.swift` exits 0.
- [x] `swift test` exits 0.

## Workflow
- Use `/tdd`. The red step is the `rg` check above: it must fail before the update and pass after it. #router #tech-debt
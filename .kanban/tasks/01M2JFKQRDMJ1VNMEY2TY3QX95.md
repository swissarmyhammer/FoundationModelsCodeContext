---
assignees:
- claude-code
depends_on:
- 01M2JFQ6YZ3FM3G0CY3040SMDS
position_column: todo
position_ordinal: '8280'
title: 'Docs: embedding model is caller-supplied, no Router'
---
## What
Update the documents so they agree with the code after these changes: `RoutedEmbedderAdapter` is removed, the Router dependency is removed, this repo moves to the Router-free Ranker `main`, and `TextEmbedding` becomes a typealias to `FoundationModelsRanker.TextEmbedding`. After this work, no part of the build graph contains FoundationModelsRouter.

- [ ] `README.md` lines 18–19: the code comment must say that `embedder` is any value that conforms to `TextEmbedding`, which is FoundationModelsRanker's embedding protocol (the caller's own embedding model). Remove the reference to `RoutedEmbedderAdapter`.
- [ ] `README.md` lines 58–61: remove "embeddings come from FoundationModelsRouter". Tell the reader that the host supplies the embedding model through `TextEmbedding`, and that the same value works with FoundationModelsRanker's `Searcher`, which also takes a FoundationModels `LanguageModelSession` for its selection tier. CodeContext itself takes no LLM.
- [ ] `plan.md`: update each location that names Router or the adapter:
  - the Rust-removals table row (line 47)
  - "floor inherited from FoundationModelsRouter" (lines 71–72)
  - the module layout line (line 85)
  - "Dependencies" (lines 92–94)
  - the `os.Logger` reason (line 105)
  - "Embeddings" (lines 285–290)
  - the `ResolutionProgress` pattern note (line 466)
  - port order step 1 (line 544) and step 5 (line 556)
  - the testing note (line 588)
  
  The design is now: a caller-supplied `TextEmbedding` (Ranker's protocol), no Router in the build graph, and no Router adapter.
- [ ] `docs/multiple-repos.md` and `docs/language-servers.md` already say `TextEmbedding` and have no Router text. Change them only if a statement is now incorrect.

## Acceptance Criteria
- [ ] `rg -n "RoutedEmbedderAdapter|RoutedEmbedder" README.md docs plan.md` gives no output.
- [ ] `rg -n "FoundationModelsRouter" README.md docs plan.md` gives no output.

## Tests
- [ ] Red step: before the change, both `rg` commands above find matches. After the change, both give no output.
- [ ] `swift build` exits 0 (the examples that the README links to still compile).

## Workflow
- Use `/tdd`. There is no code to test, so the red step is the `rg` checks above: they must fail before the change and pass after it. #router #chore
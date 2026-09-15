---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m2jtdh2sr6442x1x9wb3fhdz
  text: 'Research: The red step is confirmed. Both rg checks find matches in README.md (comment in the code example, the ranking/embedding paragraph) and plan.md (the Rust-removals row, the Package shape floor comment, the Embedding/ layout line, Dependencies, the os.Logger floor reason, the Embeddings section, the ResolutionProgress note, port order steps 1 and 5, the testing note). The docs/ files have no Router text. Their TextEmbedding statements are correct. Package.swift gives the macOS 27 floor to "FoundationModels v2 and FoundationModelsRanker". Ranker Searcher inits take `embedder: (any TextEmbedding)?` and `session:` (a factory or `any AgentSession`, for example a LanguageModelSession). The IntegrationTests use only FakeEmbedder. No real-model embedding test exists. Review has 0 validator rules for .md files.'
  timestamp: 2026-09-15T15:19:25.017282+00:00
- actor: claude-code
  id: 01m2jtg3m67faazvq9qp097tqa
  text: |-
    ### implement — changed
    - evidence: 2 files — README.md, plan.md. Red step: before the change, `rg -n "RoutedEmbedderAdapter|RoutedEmbedder" README.md docs plan.md` found 6 matches and `rg -n "FoundationModelsRouter" README.md docs plan.md` found 10 matches. After the change, both commands give no output (rg exit 1). A wider search for `Router.resolve|ProfileDefinition|LiveModelLoader|ResolutionProgress` also gives no output. `swift build` exits 0 ("Build complete!"). No change to docs/multiple-repos.md or docs/language-servers.md, because their statements are correct.
    - note: The first pass wrote "the build graph does not contain FoundationModelsRouter" into plan.md Dependencies. That text failed the second check, so it now says "has no Router package". Do not name the package in new text.
    - note: The plan.md macOS 27 floor reason now agrees with the Package.swift comment: "FoundationModels v2 and FoundationModelsRanker need this floor".
    - next: /review
  timestamp: 2026-09-15T15:20:49.542837+00:00
- actor: claude-code
  id: 01m2jtgfd2rc94ee0xsz2pa19f
  text: 'Correction to the step record: the counts are for matching lines in the red-step output. The first check matched 5 lines, not 6 (README.md:18; plan.md:94, 285, 286, 556). The second check matched 11 lines, not 10 (README.md:19, 61; plan.md:47, 72, 85, 92, 105, 285, 466, 544, 588). The outcome does not change: after the change, both checks give no output.'
  timestamp: 2026-09-15T15:21:01.602166+00:00
depends_on:
- 01M2JFQ6YZ3FM3G0CY3040SMDS
position_column: doing
position_ordinal: '80'
title: 'Docs: embedding model is caller-supplied, no Router'
---
## What
Update the documents so they agree with the code after these changes: `RoutedEmbedderAdapter` is removed, the Router dependency is removed, this repo moves to the Router-free Ranker `main`, and `TextEmbedding` becomes a typealias to `FoundationModelsRanker.TextEmbedding`. After this work, no part of the build graph contains FoundationModelsRouter.

- [x] `README.md` lines 18–19: the code comment must say that `embedder` is any value that conforms to `TextEmbedding`, which is FoundationModelsRanker's embedding protocol (the caller's own embedding model). Remove the reference to `RoutedEmbedderAdapter`.
- [x] `README.md` lines 58–61: remove "embeddings come from FoundationModelsRouter". Tell the reader that the host supplies the embedding model through `TextEmbedding`, and that the same value works with FoundationModelsRanker's `Searcher`, which also takes a FoundationModels `LanguageModelSession` for its selection tier. CodeContext itself takes no LLM.
- [x] `plan.md`: update each location that names Router or the adapter:
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
- [x] `docs/multiple-repos.md` and `docs/language-servers.md` already say `TextEmbedding` and have no Router text. Change them only if a statement is now incorrect.

## Acceptance Criteria
- [x] `rg -n "RoutedEmbedderAdapter|RoutedEmbedder" README.md docs plan.md` gives no output.
- [x] `rg -n "FoundationModelsRouter" README.md docs plan.md` gives no output.

## Tests
- [x] Red step: before the change, both `rg` commands above find matches. After the change, both give no output.
- [x] `swift build` exits 0 (the examples that the README links to still compile).

## Workflow
- Use `/tdd`. There is no code to test, so the red step is the `rg` checks above: they must fail before the change and pass after it. #router #chore
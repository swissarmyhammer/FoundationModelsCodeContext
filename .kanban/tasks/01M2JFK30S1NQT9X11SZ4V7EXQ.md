---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: 'Examples: pass a caller-defined TextEmbedding, not a Router profile'
---
## What
Remove all `FoundationModelsRouter` use from the two example targets. The examples must show that a caller gives any `TextEmbedding` value directly to `CodeContext` and `CodeContextManager`. The user decided: the input is "any `TextEmbedding`", and no Router is permitted in this repo. Do not add an MLX adapter to the library.

- [ ] `Examples/CodeContextExample/main.swift`: remove `import FoundationModelsRouter` and the "Resolve a RoutedEmbedder" block (lines 61–81: `ProfileDefinition`, `Router(...)`, `router.resolve(...)`, `RoutedEmbedderAdapter(...)`). Add a file-local `struct HashingEmbedder: TextEmbedding` with these rules:
  - Tokens: split the text on each character that is not a letter, a digit or `_`. Make each token lowercase.
  - Bucket: FNV-1a 64-bit hash of the token's UTF-8 bytes, modulo `dimension`. This is the same stable hash as `Tests/FoundationModelsCodeContextTests/Support/FakeEmbedder.swift`. Do NOT use `Hasher` or `hashValue`: their seed changes in each process, and the index stays on disk in `<root>/.code-context`, so vectors from two runs would not match.
  - Add 1 to the bucket of each token, then L2-normalize. If the magnitude is 0 (empty text, or text with no tokens), return the zero vector unchanged, as `FakeEmbedder` does. Do not divide by 0. (The corpus requires unit-length vectors, see `Sources/FoundationModelsCodeContext/Search/SearchCorpus.swift:84`.)
  - Give `HashingEmbedder(dimension: 256)` to `CodeContext(rootDirectory:embedder:)`.
- [ ] Rewrite the header doc comment of `Examples/CodeContextExample/main.swift` (lines 5–54). Remove the Router rationale and the `LiveModelLoader` notes. Tell the reader: the caller supplies the embedding model through `TextEmbedding`; a production host wraps its real model (for example an MLX embedder) in a small conformance with `dimension` and `embed(_:)`.
- [ ] `Examples/ManagerExample/main.swift`: make the same change (header lines 1–33, block lines 40–58, and the ARC note at lines 122–124). Use the same `HashingEmbedder` and give it to `CodeContextManager(embedder:)`.
- [ ] Keep one copy of `HashingEmbedder` in each example. An executable target cannot share source with another executable target, and a shared target for approximately 20 lines costs more than it gives. Write this reason in one comment above each copy.
- [ ] `Package.swift`: remove `.product(name: "FoundationModelsRouter", package: "FoundationModelsRouter")` from the `CodeContextExample` and `ManagerExample` targets (lines 195 and 207). Rewrite their comments (lines 184–190 and 199–202) so they do not say the examples need Router.

Do not change the library target or the top-level `.package(url: ...FoundationModelsRouter.git...)` entry in this task. A dependent task removes them.

## Acceptance Criteria
- [ ] `rg -n "FoundationModelsRouter|RoutedEmbedder|Router\(" Examples` gives no output.
- [ ] The two example targets in `Package.swift` depend only on `.target(name: packageName)`.
- [ ] Both examples compile.

## Tests
- [ ] Red step: before the change, `rg -n "FoundationModelsRouter|RoutedEmbedder|Router\(" Examples` finds matches. After the change, it gives no output.
- [ ] `swift build --target CodeContextExample` exits 0.
- [ ] `swift build --target ManagerExample` exits 0.
- [ ] `swift format lint -r --strict Sources Tests Examples IntegrationTests Package.swift` exits 0 (the CI format gate).
- [ ] `swift test` exits 0 with no new failures.

## Workflow
- Use `/tdd`. The examples have no unit tests, so the red step is the `rg` check above: it must fail before the change and pass after it. #router #tech-debt
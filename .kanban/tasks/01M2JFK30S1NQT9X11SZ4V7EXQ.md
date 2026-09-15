---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m2jrq0rwk8sq2m61x1vs0de5
  text: |-
    Research:
    - Red step done before any edit: `rg -n "FoundationModelsRouter|RoutedEmbedder|Router\(" Examples` finds 22 matches (exit 0), in both example files.
    - The library declares its own `public protocol TextEmbedding` in `Sources/FoundationModelsCodeContext/Embedding/TextEmbedding.swift`. The examples import only `FoundationModelsCodeContext`, so `HashingEmbedder` conforms to that protocol. The shape is the same as the Ranker protocol (`dimension`, `embed(_:) async throws -> [[Float]]`, `Sendable`).
    - `FakeEmbedder` (tests) has the FNV-1a 64-bit constants: offset basis 0xCBF2_9CE4_8422_2325 and prime 0x0000_0100_0000_01B3. `HashingEmbedder` uses the same constants.
    - Rules to obey (from dump validators): swiftlint `no_magic_numbers` (the dimension 256 gets a name), no top-level `func` for new helpers (use `static func` on the struct), doc comments on each member, `precondition` is correct for an API-contract violation (dimension must be positive, because modulo by 0 traps).
    - The duplication rule can flag the two copies of `HashingEmbedder`. The card decides one copy per example and requires a comment with the reason above each copy.
  timestamp: 2026-09-15T14:49:38.844695+00:00
- actor: claude-code
  id: 01m2jrxj7nqjse23fb5rgs5dfc
  text: |-
    ### implement — changed
    - evidence: 3 files — Examples/CodeContextExample/main.swift, Examples/ManagerExample/main.swift, Package.swift. Red: `rg -n "FoundationModelsRouter|RoutedEmbedder|Router\(" Examples` found 22 matches (exit 0) before the change; after the change it finds none (exit 1). `swift build --target CodeContextExample` exit 0. `swift build --target ManagerExample` exit 0. `swift format lint -r --strict Sources Tests Examples IntegrationTests Package.swift` exit 0. `swift test` exit 0: 561 tests in 47 suites passed, 0 warnings, 0 errors.
    - note: the first build failed with "constant must be declared private or fileprivate because its type 'HashingEmbedder' uses a private type". A top-level `let` in main.swift is a module global, so it cannot hold a `private` type. Fix: `private let embedder`. This keeps `HashingEmbedder` file-local, as the card says.
    - note: the library target and the top-level FoundationModelsRouter `.package(url:)` entry did not change (task ^jpqwgmw removes them). The comment on `platforms` in Package.swift still names FoundationModelsRouter; it is on the library side, so that task owns it.
    - next: /review
  timestamp: 2026-09-15T14:53:13.333117+00:00
- actor: claude-code
  id: 01m2js6s2h4w290eqpnz8baqzj
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (commit a88142f). 0 findings, 0 confirmed, 0 refuted. 7 validator runs attempted, 0 failed. The engine reviewed 3 files. The .reviewignore rule excluded 2 .kanban files.
    - next: The task is in done. Task ^jpqwgmw can start.
  timestamp: 2026-09-15T14:58:15.249329+00:00
- actor: claude-code
  id: 01m2js75748t41ypt3mh45xrn5
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — Examples/CodeContextExample/main.swift, Examples/ManagerExample/main.swift, Package.swift; rg red step 22 matches, then 0
    - test: green — swift build, both example targets, IntegrationTests build-tests, swift format lint --strict, swift test 561 passed in 47 suites, 0 failed, 0 skipped
    - commit: a88142f
    - review: clean — 0 findings (3 files, 7 validator runs)
  timestamp: 2026-09-15T14:58:27.684129+00:00
position_column: done
position_ordinal: bd80
title: 'Examples: pass a caller-defined TextEmbedding, not a Router profile'
---
## What
Remove all `FoundationModelsRouter` use from the two example targets. The examples must show that a caller gives any `TextEmbedding` value directly to `CodeContext` and `CodeContextManager`. The user decided: the input is "any `TextEmbedding`", and no Router is permitted in this repo. Do not add an MLX adapter to the library.

- [x] `Examples/CodeContextExample/main.swift`: remove `import FoundationModelsRouter` and the "Resolve a RoutedEmbedder" block (lines 61–81: `ProfileDefinition`, `Router(...)`, `router.resolve(...)`, `RoutedEmbedderAdapter(...)`). Add a file-local `struct HashingEmbedder: TextEmbedding` with these rules:
  - Tokens: split the text on each character that is not a letter, a digit or `_`. Make each token lowercase.
  - Bucket: FNV-1a 64-bit hash of the token's UTF-8 bytes, modulo `dimension`. This is the same stable hash as `Tests/FoundationModelsCodeContextTests/Support/FakeEmbedder.swift`. Do NOT use `Hasher` or `hashValue`: their seed changes in each process, and the index stays on disk in `<root>/.code-context`, so vectors from two runs would not match.
  - Add 1 to the bucket of each token, then L2-normalize. If the magnitude is 0 (empty text, or text with no tokens), return the zero vector unchanged, as `FakeEmbedder` does. Do not divide by 0. (The corpus requires unit-length vectors, see `Sources/FoundationModelsCodeContext/Search/SearchCorpus.swift:84`.)
  - Give `HashingEmbedder(dimension: 256)` to `CodeContext(rootDirectory:embedder:)`.
- [x] Rewrite the header doc comment of `Examples/CodeContextExample/main.swift` (lines 5–54). Remove the Router rationale and the `LiveModelLoader` notes. Tell the reader: the caller supplies the embedding model through `TextEmbedding`; a production host wraps its real model (for example an MLX embedder) in a small conformance with `dimension` and `embed(_:)`.
- [x] `Examples/ManagerExample/main.swift`: make the same change (header lines 1–33, block lines 40–58, and the ARC note at lines 122–124). Use the same `HashingEmbedder` and give it to `CodeContextManager(embedder:)`.
- [x] Keep one copy of `HashingEmbedder` in each example. An executable target cannot share source with another executable target, and a shared target for approximately 20 lines costs more than it gives. Write this reason in one comment above each copy.
- [x] `Package.swift`: remove `.product(name: "FoundationModelsRouter", package: "FoundationModelsRouter")` from the `CodeContextExample` and `ManagerExample` targets (lines 195 and 207). Rewrite their comments (lines 184–190 and 199–202) so they do not say the examples need Router.

Do not change the library target or the top-level `.package(url: ...FoundationModelsRouter.git...)` entry in this task. A dependent task removes them.

## Acceptance Criteria
- [x] `rg -n "FoundationModelsRouter|RoutedEmbedder|Router\(" Examples` gives no output.
- [x] The two example targets in `Package.swift` depend only on `.target(name: packageName)`.
- [x] Both examples compile.

## Tests
- [x] Red step: before the change, `rg -n "FoundationModelsRouter|RoutedEmbedder|Router\(" Examples` finds matches. After the change, it gives no output.
- [x] `swift build --target CodeContextExample` exits 0.
- [x] `swift build --target ManagerExample` exits 0.
- [x] `swift format lint -r --strict Sources Tests Examples IntegrationTests Package.swift` exits 0 (the CI format gate).
- [x] `swift test` exits 0 with no new failures.

## Workflow
- Use `/tdd`. The examples have no unit tests, so the red step is the `rg` check above: it must fail before the change and pass after it. #router #tech-debt
---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m2jsa3a5w38ypxrrv40dywcb
  text: |-
    Research and red step.
    - Red step before the change: `rg -n "FoundationModelsRouter|RoutedEmbedder" Sources Examples Package.swift` finds Package.swift (comments above `platforms` and above the Router and Ranker `.package` entries, the Router `.package` entry, the Router `.product` in the library target), Log.swift, TextEmbedding.swift and RoutedEmbedderAdapter.swift. `swift package dump-package | rg -c FoundationModelsRouter` gives 3. `swift package show-dependencies --format json | rg -c -i foundationmodelsrouter` gives 4.
    - No file in Tests or IntegrationTests uses RoutedEmbedderAdapter or FoundationModelsRouter.
    - The public `CodeContextManager.init(embedder:autoInstall:)` is in an extension where `Connection == ProcessLanguageServerConnection`. It opens no root. `shutdown()` closes the open roots.
    - README.md and plan.md also name Router. Task ^kqrdmj1 ("Docs: embedding model is caller-supplied, no Router") owns those files, so this task does not change them.
  timestamp: 2026-09-15T15:00:04.037260+00:00
- actor: claude-code
  id: 01m2jsb6w2f9cwkj313t8ynjmq
  text: 'Correction to the research comment: the docs task that owns README.md and plan.md is ^ty3qx95, not "^kqrdmj1".'
  timestamp: 2026-09-15T15:00:40.450991+00:00
- actor: claude-code
  id: 01m2jse4hakm22ncmbxjwx7fvp
  text: |-
    ### implement — changed
    - evidence: 4 files. Deleted Sources/FoundationModelsCodeContext/Embedding/RoutedEmbedderAdapter.swift (git rm). Package.swift: removed the Router `.package` entry and the Router `.product` in the library target; rewrote the comment at the top of the file, the comment above `platforms` (the floor is now for FoundationModels v2 and FoundationModelsRanker) and the Ranker `.package` comment (no Router text). Log.swift: the macOS 27 floor comment names FoundationModels v2 and FoundationModelsRanker. Added Tests/FoundationModelsCodeContextTests/CallerEmbedderPublicAPITests.swift (plain import; a private caller-defined `TextEmbedding` struct; opens a temporary root through the public `CodeContextManager(embedder:autoInstall:)` and `context(for:)`, examines `rootDirectory`, then `shutdown()`).
    - Red step, before: rg found Router in Package.swift, Log.swift, TextEmbedding.swift and RoutedEmbedderAdapter.swift; dump-package count 3; show-dependencies count 4. After `swift package resolve` and `swift package --package-path IntegrationTests resolve`: rg finds only the two stale doc lines in TextEmbedding.swift (the card allows these, and ^040smds replaces them); dump-package gives no output; show-dependencies gives no output for the root package and for IntegrationTests.
    - swift build exit 0. swift build --package-path IntegrationTests --build-tests exit 0. swift format lint -r --strict Sources Tests Examples IntegrationTests Package.swift exit 0. swift test exit 0: 562 tests in 48 suites passed; publicManagerInitAcceptsCallerDefinedEmbedder passed; EmbeddingSeamTests passed; no warnings.
    - TextEmbedding.swift was not changed. README.md and plan.md still name Router; ^ty3qx95 owns them.
    - next: /review
  timestamp: 2026-09-15T15:02:16.362984+00:00
depends_on:
- 01M2JFK30S1NQT9X11SZ4V7EXQ
- 01M2JG4HJDKVAX6FRH81QCV5A6
position_column: doing
position_ordinal: '80'
title: Remove RoutedEmbedderAdapter and the direct FoundationModelsRouter dependency
---
## What
Remove this package's direct dependency on FoundationModelsRouter. The user said: "i don't want to be using Router in here". After this task, a caller passes any `TextEmbedding` conformance as the embedding model, and no part of the resolved build graph contains Router. The dependency task `1qcv5a6` moves this repo to the Router-free Ranker `main`, so after this task Router does not come in through Ranker either.

This is a public API break: the public type `RoutedEmbedderAdapter` goes away. A host that uses Router writes the small conformance itself.

- [x] Delete `Sources/FoundationModelsCodeContext/Embedding/RoutedEmbedderAdapter.swift`.
- [x] `Package.swift`: remove `.product(name: "FoundationModelsRouter", package: "FoundationModelsRouter")` from the library target (line 161). Remove `.package(url: "git@github.com:swissarmyhammer/FoundationModelsRouter.git", branch: "main")` (line 108). Rewrite the comments at lines 6–8, 86–87, 98–107 and 109–115 so no comment says this package depends on Router. Keep `.macOS("27.0")`; its comment now gives FoundationModels v2 / FoundationModelsRanker as the reason.
- [x] `Sources/FoundationModelsCodeContext/Logging/Log.swift` lines 12–14: the macOS 27 floor is no longer "inherited from FoundationModelsRouter".
- [x] Add `Tests/FoundationModelsCodeContextTests/CallerEmbedderPublicAPITests.swift`. Use a plain `import FoundationModelsCodeContext` (NOT `@testable`), and do not import FoundationModelsRanker. Define a caller-side `struct` that conforms to `TextEmbedding`. In a temporary workspace (`withTemporaryWorkspace` from `TestSupport.swift`), open `CodeContextManager(embedder:autoInstall: LspAutoInstall(isEnabled: false))` with it. Do not add a `CodeContext` init test: `CodeContextRootDirectoryPublicVisibilityTests.swift:26` and `DiagnosticsReportPublicVisibilityTests.swift:32` already cover the public `CodeContext` init with a plain import.

Do not change `Sources/FoundationModelsCodeContext/Embedding/TextEmbedding.swift` here. The dependent task `040smds` replaces it with a typealias to `FoundationModelsRanker.TextEmbedding`.

## Acceptance Criteria
- [x] `rg -n "FoundationModelsRouter|RoutedEmbedder" Sources Examples Package.swift` gives no output, except the stale doc line in `TextEmbedding.swift` that the dependent task replaces.
- [x] `swift package dump-package | rg -c FoundationModelsRouter` gives no output.
- [x] `swift package show-dependencies --format json | rg -c -i foundationmodelsrouter` gives no output (the full resolved graph has no Router).
- [x] A type outside the module that conforms to `TextEmbedding` can be given to the public `CodeContextManager` initializer.

## Tests
- [x] Red step: before the change, the `rg`, `dump-package` and `show-dependencies` checks above find Router. After the change, all three give no output. (The new test passes on the current code, so it is not the red step.)
- [x] New `publicManagerInitAcceptsCallerDefinedEmbedder` in `Tests/FoundationModelsCodeContextTests/CallerEmbedderPublicAPITests.swift`.
- [x] Existing `Tests/FoundationModelsCodeContextTests/EmbeddingSeamTests.swift` stays green.
- [x] `swift build` exits 0.
- [x] `swift build --package-path IntegrationTests --build-tests` exits 0 (that package depends on this manifest).
- [x] `swift format lint -r --strict Sources Tests Examples IntegrationTests Package.swift` exits 0.
- [x] `swift test` exits 0.

## Workflow
- Use `/tdd`. The red step is the three dependency checks above: they must fail before the change and pass after it. #router #tech-debt
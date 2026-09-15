---
assignees:
- claude-code
depends_on:
- 01M2JFK30S1NQT9X11SZ4V7EXQ
- 01M2JG4HJDKVAX6FRH81QCV5A6
position_column: todo
position_ordinal: '8180'
title: Remove RoutedEmbedderAdapter and the direct FoundationModelsRouter dependency
---
## What
Remove this package's direct dependency on FoundationModelsRouter. The user said: "i don't want to be using Router in here". After this task, a caller passes any `TextEmbedding` conformance as the embedding model, and no part of the resolved build graph contains Router. The dependency task `1qcv5a6` moves this repo to the Router-free Ranker `main`, so after this task Router does not come in through Ranker either.

This is a public API break: the public type `RoutedEmbedderAdapter` goes away. A host that uses Router writes the small conformance itself.

- [ ] Delete `Sources/FoundationModelsCodeContext/Embedding/RoutedEmbedderAdapter.swift`.
- [ ] `Package.swift`: remove `.product(name: "FoundationModelsRouter", package: "FoundationModelsRouter")` from the library target (line 161). Remove `.package(url: "git@github.com:swissarmyhammer/FoundationModelsRouter.git", branch: "main")` (line 108). Rewrite the comments at lines 6–8, 86–87, 98–107 and 109–115 so no comment says this package depends on Router. Keep `.macOS("27.0")`; its comment now gives FoundationModels v2 / FoundationModelsRanker as the reason.
- [ ] `Sources/FoundationModelsCodeContext/Logging/Log.swift` lines 12–14: the macOS 27 floor is no longer "inherited from FoundationModelsRouter".
- [ ] Add `Tests/FoundationModelsCodeContextTests/CallerEmbedderPublicAPITests.swift`. Use a plain `import FoundationModelsCodeContext` (NOT `@testable`), and do not import FoundationModelsRanker. Define a caller-side `struct` that conforms to `TextEmbedding`. In a temporary workspace (`withTemporaryWorkspace` from `TestSupport.swift`), open `CodeContextManager(embedder:autoInstall: LspAutoInstall(isEnabled: false))` with it. Do not add a `CodeContext` init test: `CodeContextRootDirectoryPublicVisibilityTests.swift:26` and `DiagnosticsReportPublicVisibilityTests.swift:32` already cover the public `CodeContext` init with a plain import.

Do not change `Sources/FoundationModelsCodeContext/Embedding/TextEmbedding.swift` here. The dependent task `040smds` replaces it with a typealias to `FoundationModelsRanker.TextEmbedding`.

## Acceptance Criteria
- [ ] `rg -n "FoundationModelsRouter|RoutedEmbedder" Sources Examples Package.swift` gives no output, except the stale doc line in `TextEmbedding.swift` that the dependent task replaces.
- [ ] `swift package dump-package | rg -c FoundationModelsRouter` gives no output.
- [ ] `swift package show-dependencies --format json | rg -c -i foundationmodelsrouter` gives no output (the full resolved graph has no Router).
- [ ] A type outside the module that conforms to `TextEmbedding` can be given to the public `CodeContextManager` initializer.

## Tests
- [ ] Red step: before the change, the `rg`, `dump-package` and `show-dependencies` checks above find Router. After the change, all three give no output. (The new test passes on the current code, so it is not the red step.)
- [ ] New `publicManagerInitAcceptsCallerDefinedEmbedder` in `Tests/FoundationModelsCodeContextTests/CallerEmbedderPublicAPITests.swift`.
- [ ] Existing `Tests/FoundationModelsCodeContextTests/EmbeddingSeamTests.swift` stays green.
- [ ] `swift build` exits 0.
- [ ] `swift build --package-path IntegrationTests --build-tests` exits 0 (that package depends on this manifest).
- [ ] `swift format lint -r --strict Sources Tests Examples IntegrationTests Package.swift` exits 0.
- [ ] `swift test` exits 0.

## Workflow
- Use `/tdd`. The red step is the three dependency checks above: they must fail before the change and pass after it. #router #tech-debt
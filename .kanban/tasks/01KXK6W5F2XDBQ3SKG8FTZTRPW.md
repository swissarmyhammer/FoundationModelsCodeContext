---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kxkjyypvdwckmvjq8w3bg9th
  text: |-
    Implemented: added `.executableTarget(name: "CodeContextExample", ...)` to Package.swift (depends only on the library target + FoundationModelsRouter product, per the task's literal spec) and Examples/CodeContextExample/main.swift.

    main.swift: parses root dir from argv[1] (default cwd) and query from argv[2] (default "TODO"); builds a ProfileDefinition (standard/flash/embedding candidate refs — ProfileDefinition has no embedding-only shape), resolves it via `Router(recordingsDir:).resolve(profile:reporting:)` (the only public resolution entry point FoundationModelsRouter exposes), wraps `profile.embedding` in `RoutedEmbedderAdapter`, then `CodeContext(rootDirectory:embedder:)` -> `start()` -> `detectProjects()` + `indexStatus()` -> `searchSymbol`/`searchCode` -> `stop()` -> `profile.release()`.

    Deliberately does not link MLXHuggingFace/HuggingFace/Tokenizers (per task spec), so a real `swift run` needs a host-configured LiveModelLoader to actually download/load models — documented at length in the file's header doc comment as a local smoke step, not a CI gate. Mirrors FoundationModelsRouter's own Examples/MultiModelGeneration call pattern for the resolve step.

    Verified fresh: `swift build` exits 0 (target + whole package, no warnings from the new code — only a pre-existing unrelated SwiftPM warning about mlx-swift's Cmlx.bundle). `swift test` — 478/478 tests pass, 40 suites. Sent for adversarial double-check via really-done before handoff.
  timestamp: 2026-07-15T19:09:52.731984+00:00
- actor: claude-code
  id: 01kxkk5yp7frh5b5ptnq7g6fd5
  text: |-
    Adversarial double-check (via really-done) returned PASS with no findings: verified the Package.swift executableTarget block matches the task's literal dependency/path/name spec, verified every API call in main.swift against the real FoundationModelsCodeContext/FoundationModelsRouter source (CodeContext's public init, detectProjects/indexStatus/searchSymbol/searchCode/start/stop, RoutedEmbedderAdapter.init, Router/ProfileDefinition/ResolutionProgress/LanguageModelProfile.release), confirmed no unused-variable warnings, and independently re-ran `swift build` (target + whole package) and `swift test` fresh — both green, 478/478 tests passing.

    Leaving task in doing, green and ready for /review. All acceptance criteria and subtask checkboxes satisfied:
    - swift build builds CodeContextExample with no warnings (only a pre-existing, unrelated mlx-swift_Cmlx.bundle SwiftPM warning present regardless of this change)
    - example uses only public API of both packages, no @testable
    - source demonstrates full lifecycle: embedder resolution -> init -> start -> queries -> stop
    - swift test still passes (478/478, no library changes)
  timestamp: 2026-07-15T19:13:42.087406+00:00
- actor: claude-code
  id: 01kxkk7yx4a3bjpzrsb3nxbsne
  text: Checked off all Acceptance Criteria / Tests checkboxes in the task description (all verified true — see prior comments) after a redundant background double-check run flagged them as still unchecked bookkeeping. First attempt at the update accidentally stored literal "\n" escape sequences instead of real newlines; caught and corrected in a follow-up update. Task stays in doing per implement's contract — /review will pull it forward.
  timestamp: 2026-07-15T19:14:47.844474+00:00
position_column: doing
position_ordinal: '80'
title: 'Add example program: standalone single-root CodeContext'
---
## What
Add the first of the two "ways in" examples: a small executable demonstrating standalone `CodeContext` on one repo (this entry point stays public and first-class).

- `Package.swift`: add `.executableTarget(name: "CodeContextExample", dependencies: [.target(name: packageName), .product(name: "FoundationModelsRouter", package: "FoundationModelsRouter")], path: "Examples/CodeContextExample")` following the manifest's named-constant conventions. The Router product is required: this package deliberately ships no embedder factory — `RoutedEmbedderAdapter`'s public init takes an already-resolved `RoutedEmbedder`, and plan.md records that the host app resolves the Router profile and injects the embedder. Do NOT add the example to the library product.
- `Examples/CodeContextExample/main.swift`: take a root directory as `CommandLine.arguments[1]` (default: current directory) and an optional query argument. Resolve a `RoutedEmbedder` via FoundationModelsRouter's public resolution API and wrap it in `RoutedEmbedderAdapter`, then:
  1. `let context = try await CodeContext(rootDirectory:embedder:)` + `try await context.start()`
  2. print detected projects and `indexStatus()`
  3. run `searchSymbol` and `searchCode` with the query and print results
  4. `await context.stop()`

Keep `main.swift` a thin script over the public API of the two packages (`import FoundationModelsCodeContext`, `import FoundationModelsRouter`; no `@testable`) — it exists to compile-verify and document the public surface, not to hold logic.

## Acceptance Criteria
- [x] `swift build` builds the `CodeContextExample` target with no warnings
- [x] The example uses only public API of FoundationModelsCodeContext and FoundationModelsRouter (no `@testable`)
- [x] The source demonstrates the full lifecycle: embedder resolution → init → start → queries → stop

## Tests
- [x] `swift build` exits 0 with the new target included — this build is the automated verification (running the example needs Apple Intelligence + real LSP daemons, so a live run is a documented local smoke step in the example's header comment, NOT an acceptance gate)
- [x] `swift test` still passes (no library changes expected)

## Workflow
- Use `/tdd` where applicable; for this example the build itself is the failing-then-passing check.
---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m6khz9jka39mng6nr7yjksry
  text: |-
    Open promise to the ACPAgent session (foundationmodelsacpagent-1e):
    - ACPAgent made card 01M6KHYYRA21327AWHEFHG4RNV (^hfhg4rnv) on its board: "Pass a selection model to CodeContext". It is blocked until we act. ACPAgent makes no change to its CodeContext calls before then.
    - When the final signature of `CodeContext(...)` is fixed, SEND it to foundationmodelsacpagent-1e.
    - When this task is pushed to main, TELL foundationmodelsacpagent-1e. ACPAgent resolves CodeContext from main, and its build breaks before the push.
    - Also tell the session if the signature changes after it was sent.
  timestamp: 2026-11-04T15:13:51.699234+00:00
- actor: claude-code
  id: 01m6kmmfsmxynhkjv5m12xw4kc
  text: |-
    Answer from the Ranker session about SelectionTier (Ranker is on main at ddb39a1). It works today. No Ranker code is needed.

    `SelectionTier` takes any `SelectionCatalog`. Build a small catalog from the `Hit` list for each search:
    ```
    public protocol SelectionCatalog: Sendable { var ids: [String] { get }; func summaryBlock(forID id: String) -> String?; func block(forID id: String) -> String? }
    public actor SelectionTier { public init(catalog: any SelectionCatalog, config: SelectionConfig, onDiagnostic: @escaping @Sendable (RankDiagnostic) -> Void); public func search(intent: String, limit: Int) async throws -> [SelectionMatch] }
    public struct SelectionConfig: Sendable { public init(model: any LanguageModel, preamble: String = .selectionDefault, capacityCharacterLimit: Int = SelectionConfig.defaultCapacityCharacterLimit) }
    public struct SelectionMatch: Sendable, Equatable { id: String; block: String; score: Double; signals: Signals? }
    ```
    Call:
    ```
    let hits = HybridRanker.topMatches(...)
    let catalog = YourCandidateCatalog(hits)   // ids = hits.map(\.id); summaryBlock = short text; block = verbatim chunk
    let tier = SelectionTier(catalog: catalog, config: SelectionConfig(model: model), onDiagnostic: { _ in })
    let matches = try await tier.search(intent: query, limit: limit)
    ```
    - The tier is cheap and keeps no state across searches. Create one for each search.
    - Catalog order = prompt order. Keep the hit order.
    - Returned ids are the model's picks, in the model's order. `score` is 1/rank and `signals` is nil. Take the retrieval score from the `Hit` with the same id.
    - Errors: `SelectionTier` has no error type. `search` throws whatever `LanguageModelSession.respond(to:generating:)` throws. An empty catalog or `limit <= 0` returns `[]` with no prompt. An id that is not in the catalog is dropped and reported as `RankDiagnostic.unknownSelectedId(id:)` through `onDiagnostic`. Route that diagnostic to the Log of this package.

    Design decision of the user: `selection` is required and not `nil`. It takes a `SelectionFactory` like Multitool: `(ids) throws -> SelectionConfig`. A selection error is the error of `search code`. No silent fallback.

    Also: after the push, tell foundationmodelsacpagent-1e (see the earlier comment).
  timestamp: 2026-11-04T16:00:23.348513+00:00
- actor: claude-code
  id: 01m6knm3tqv3tgjxvt8vvwp4pz
  text: |-
    ### implement - research and design decisions (before code)

    Research:
    - Ranker answer (comment above) is confirmed in .build/checkouts/FoundationModelsRanker: SelectionTier takes any SelectionCatalog, keeps no state, one tier for each search. No Ranker change is needed.
    - Multitool defines `SelectionFactory` as a typealias NESTED in `SearchToolsTool`. It is not reachable from Ranker or MetadataRegistry as a top-level type. So this package defines a top-level public `SelectionFactory = @Sendable (_ ids: [String]) throws -> SelectionConfig`. Same shape as Multitool. No new dependency (SelectionConfig comes from FoundationModelsRanker).
    - Multitool test fake: `ScriptedLanguageModel` (Tests/.../Fixtures/LanguageModelFixtures.swift). It is a `LanguageModel` with a `LanguageModelExecutor`. It reads the transcript, answers from a script, can throw. I will write the same kind of fake in Tests/FoundationModelsCodeContextTests/Support/FakeLanguageModel.swift.
    - Tool layer: `CodeContextTools.make(context:)` takes a built `CodeContext`. So the selection input flows through the context. No default model is possible there. No change to the tool signature.
    - `embedder` stays as it is (`PooledEmbedding?`, no default). `selection` goes right after it.

    Design decision: manager fan-out.
    - Problem: `CodeContextManager.searchCode` calls `context.searchCode` for each root. If each context ran selection, the model would run once for each root.
    - Decision: the model runs once for each user search, in the manager, over the merged candidates.
      1. `SearchCode.retrieve(...)` is the retrieval step (HybridRanker, no model). It stays internal, and keeps the old search span.
      2. `SearchCode.run(corpus:embedder:selection:query:topK:weights:tracer:)` is retrieve + select. It is what `CodeContext.searchCode` calls (one root = one selection).
      3. The manager asks each root for retrieval only (internal `CodeContext.retrieveCode`), merges the roots by the existing rank-major interleave (cap topK), builds ONE catalog over the merged list with ids qualified by root (hit ids are chunk row ids and collide across roots), applies the factory once with those ids, and runs one SelectionTier.
      4. Each selected match keeps its own Hit (retrieval score and signals) and its root.
    - Consequence: `CodeContextManager.searchCode` becomes `async throws` (a selection error is the error of the call, no fallback). Per-root retrieval failures stay in `failures`.
    - The manager also gives the factory to each context it makes (required init), but its own search does not call the contexts' selection.
    - No user choice is needed. Public signatures are fixed by the user decision; this only decides where the model runs.
  timestamp: 2026-11-04T16:17:39.671220+00:00
- actor: claude-code
  id: 01m6kp7b2qes9f3mk7cz40pcd7
  text: |-
    ### implement - changed
    - evidence:
      - Source: Search/CodeSelection.swift (new: public `SelectionFactory`, catalog, `CodeSelection.select`, `SelectionDiagnostics`), Ops/SearchCode.swift (`retrieve` = old run, new `run` = retrieve + select), CodeContext.swift, CodeContextManager.swift, Ops/ManagerQueries.swift, Package.swift (Ranker product for the two examples).
      - Tests: Support/FakeLanguageModel.swift (new), SearchCodeSelectionTests.swift (new, 12 tests), ManagerQueriesTests (+4), CodeContextE2ETests (+2), 15 other test files take `selection:`; `SearchCode.run` retrieval tests now call `SearchCode.retrieve`.
      - Examples (3), IntegrationTests (2 files), README.md, plan.md (new "Selection model" section), docs/language-servers.md, docs/multiple-repos.md. ARCHITECTURE.md untouched (task ^w6z300d).
      - Final signatures:
        `CodeContext(rootDirectory: URL, embedder: PooledEmbedding?, selection: @escaping SelectionFactory, autoInstall: LspAutoInstall = .., eventSource: (any FileEventSource)? = .., indexDirectory: URL? = nil) async throws`
        `CodeContextManager(embedder: PooledEmbedding?, selection: @escaping SelectionFactory, autoInstall: LspAutoInstall = .., eventSource: (any FileEventSource)? = .., indexDirectory: (@Sendable (URL) -> URL)? = nil) async`
        `public typealias SelectionFactory = @Sendable (_ ids: [String]) throws -> SelectionConfig`
        `CodeContextManager.searchCode(query:topK:weights:)` is now `async throws`.
      - Commands: `swift build` (only the allowed mlx warning), `swift build --package-path IntegrationTests --build-tests` (ok, allowed warning only), `swift test` (1135 tests, 100 suites, passed), `swift format lint -r --strict Sources Tests Examples IntegrationTests Package.swift` (clean).
    - Notes for the next agent:
      - Manager: model runs once for each search over the merged candidates; candidate ids there are positions in the merged list (hit ids repeat across roots).
      - `unknownSelectedId` goes to Log.search with a fixed message, no id (the id is model output).
      - The search span now holds the retrieval hit count; selection has no span of its own.
      - FakeLanguageModel `.selectingEveryCandidate` reads `id: ` lines of the Ranker prefix. If Ranker changes that format, tests that use it fail loudly.
      - ACPAgent session (foundationmodelsacpagent-1e): the signature above is final for this change. The orchestrator must send it, and tell the session when this is pushed (open promise in the first comment).
    - next: /review
  timestamp: 2026-11-04T16:28:09.687312+00:00
- actor: claude-code
  id: 01m6kpd47acpnqthfk8a6wxahj
  text: |-
    ### test - green
    - evidence: I touched each changed Swift file first, so the build was fresh. `swift build` (library and the 3 Examples): complete. `swift build --package-path IntegrationTests --build-tests`: complete. `swift test`: 1135 tests in 100 suites passed, 0 failed, 0 skipped. `swift format lint -r --strict Sources Tests Examples IntegrationTests Package.swift`: 0 findings.
    - warnings: only the allowed "missing creator for mutated node ... mlx-swift_Cmlx.bundle/Contents/MacOS" warning.
    - reading checks: every `CodeContext(` and `CodeContext<...>(` call passes `selection:` (Sources, Tests, Examples, IntegrationTests, README.md, plan.md, docs). No test uses a real model: the unit tests use FakeLanguageModel, and the integration tests use `unusedSelection`. The new tests have no sleep and no timer wait. The only waits are `waitForFirstIndexPass()` with a fake embedder, and each one ends by itself.
    - flaky check: 5 runs of `swift test --filter 'SearchCodeSelectionTests|ManagerQueriesTests|CodeContextE2ETests'`: 33 tests passed in each run. No flaky result.
    - files changed by me: none.
    - next: review.
  timestamp: 2026-11-04T16:31:19.274692+00:00
- actor: claude-code
  id: 01m6kpdkyhf3sr8qm8r6v29ebz
  text: |-
    ### commit — changed
    - evidence: 40 files committed locally. Not pushed.
    - next: review
  timestamp: 2026-11-04T16:31:35.377323+00:00
- actor: claude-code
  id: 01m6kpnynpp8pfqn655a4b4dnt
  text: |-
    ### review - findings
    - evidence: review sha HEAD~1..HEAD. Engine: 2 findings (ManagerExample/main.swift:113, dead-code-swift). Acceptance review by hand: 3 more (SearchCode.swift:290, CodeSelection.swift:107, CodeSearchToolTests.swift:120). Total 5 open.
    - note on the two engine findings: `searchResults` and `searchFailures` are used in the loops at lines 115-121 of the same file. They look like false positives of the dead-code rule for a top-level tuple pattern. The review skill gives no written rule to drop them, so they stay on the list. A person can decide if this is a rule conflict.
    - checked and OK: `selection` has no default and no nil in CodeContext (both inits), CodeContextManager (both inits) and the one internal CodeContext build. All callers in Sources, Tests, Examples, IntegrationTests, README.md, plan.md and docs pass `selection:`. Selection error is thrown (context, manager, engine tests). Tool path rethrows it (ToolSupport.outcome only turns a CodeContextError into corrective text). Model runs one time per manager search over merged candidates. Hit score and signals are kept, model order is kept. unknownSelectedId goes to Log.search with a fixed message, no id, no query, no chunk text, and one test checks it. The content-safety test runs `searchCode` through the selection path with the marker as query. SelectionFactory is @Sendable, tier is made for each search, no shared mutable state. The new tests have no sleep and no timer wait.
    - next: fix the open findings, then /review again.
  timestamp: 2026-11-04T16:36:08.502990+00:00
- actor: claude-code
  id: 01m6kqb19mj8633h2465c37z6j
  text: |-
    ### implement — changed
    - evidence: 13 files changed (Examples/ManagerExample/main.swift; Sources: CodeContextManager.swift, Ops/ManagerQueries.swift, Ops/SearchCode.swift, Search/CodeSelection.swift, Tracing/CodeContextSpans.swift, Tracing/CodeContextTracing.swift; Tests: CodeContextTracingTests, CodeSearchToolTests, ManagerQueriesTests, TelemetryContentSafetyTests, ToolTestSupport, TracingSpanTests).
    - Findings 1 and 2 (dead-code-swift, `searchResults` and `searchFailures`): the cause was top-level state in main.swift. The rule runs the compiler on the file, and it also flagged the used global `query`. Fix: all example state now lives in one `@MainActor func runExample() async throws` that the file calls at top level. The file has no state global left. No validator was edited. `review file Examples/ManagerExample/main.swift` (code-hygiene) no longer reports any dead-code finding. CodeContextExample and IndexBenchmark have no dead-code finding. The same review still reports older findings outside the five (print calls, magic number, HashingEmbedder duplication, firstRegularFile); they are not part of this list.
    - Finding 3: the search span now covers retrieval and selection. `SearchCode.run` and `CodeContextManager.searchCode` own it. `search.result_count` is the number of hits that the call returns after selection. `SearchCode.retrieve` opens no span. Test: `theSearchSpanHoldsTheNumberOfSelectedHitsNotOfRetrievedCandidates` (2 candidates, model selects 1, count is 1).
    - Finding 4: new `SpanName.select` (child of search), `AttributeKey.selectionCandidateCount` and `selectionResultCount`. `CodeSelection.select` opens the span through `CodeContextSpans.withSelectionSpan`. It holds counts only. No span for a search with no candidate (no model call). The manager path has one search span and one select span (`aManagerSearchCodeGivesOneSearchSpanAndOneSelectSpanAsItsChild`). New internal `tracer:` parameter of the manager init (test seam, passed to each context). Tests: select span child and counts, failed selection records only the error type and no result count, no select span for no candidate. Vocabulary lists in CodeContextTracingTests have the new names. TelemetryContentSafetyTests now also runs a manager search with the marker as query, expects the select span name, and expects exactly 2 select spans (context and manager). Its span, log and metric check covers them.
    - Finding 5: `CodeSearchToolTests.aSelectionErrorIsTheErrorOfTheSearchCodeToolCall`. The tool call throws `OperationError.executionFailed` with the selection error as cause: no corrective text, no retrieval result. This test passed at once because the behavior already existed; it guards it. `ToolTest.withIndexedTool` and `withStartedContext` take an optional `selection:` (default selects every candidate).
    - Note: the tool layer wraps the engine error in `OperationError.executionFailed(cause:)`. The card text said "the tool throws the error"; the cause is the selection error.
    - Commands: `swift build` ok, `swift build --package-path IntegrationTests --build-tests` ok (only the allowed mlx warning), `swift test` 1141 tests in 100 suites passed, `swift format lint -r --strict Sources Tests Examples IntegrationTests Package.swift` 0 findings.
    - next: /review
  timestamp: 2026-11-04T16:47:39.316167+00:00
- actor: claude-code
  id: 01m6kqg3dgvdhat1ck3vngz4vc
  text: |-
    ### test — green
    - swift build: pass. The three Examples build alone: pass. Only the allowed "missing creator" warning.
    - swift build --package-path IntegrationTests --build-tests: pass. No other warning.
    - swift test: 1141 tests in 100 suites passed. 0 failures, 0 skipped.
    - swift format lint -r --strict Sources Tests Examples IntegrationTests Package.swift: 0 findings.
    - Five runs of TelemetryContentSafetyTests, TracingSpanTests, CodeContextTracingTests, CodeSearchToolTests, ManagerQueriesTests and SearchCodeSelectionTests: 72 tests each run, all pass. No flaky result.
    - Content-safety check by reading: the test uses one marker as the query and as the chunk text. The selection runs in the context path and in the manager path, and the test checks that 2 select spans exist. TelemetryContentCheck.places reads each attribute, event, error and status of each span, and fails if any holds the marker. So a query or chunk text in a select span attribute fails the test.
    - Integration run not done: three tests (DetectProjectsScaleTests, two in GrepCodeScaleTests) have no .timeLimit, and the live tests need sourcekit-lsp and pylsp, which are not installed here (they would skip). This change touches no IntegrationTests file. Left for CI.
    - Files changed by this step: none.
    - next: commit
  timestamp: 2026-11-04T16:50:25.328780+00:00
- actor: claude-code
  id: 01m6kqgjds9qqv4b1dv9r1960b
  text: |-
    ### commit — changed
    - evidence: local commit made with 15 files (Sources, Tests, Examples, .kanban)
    - next: review
  timestamp: 2026-11-04T16:50:40.697399+00:00
- actor: claude-code
  id: 01m6kqtztr733mqese2y8g4486
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD gave 15 findings. review file Examples/**/main.swift gave 20 findings, 7 not in the first list. Prior items 1 to 5 are fixed in code: no dead-code finding remains in ManagerExample; search.result_count holds the returned hit count in both paths; the select span holds counts only and a search with no candidate opens no select span (matches the vocabulary doc); the tool-path test aSelectionErrorIsTheErrorOfTheSearchCodeToolCall exists. The manager init `tracer:` is internal, has default nil that reads the bootstrapped tracer, and does not widen the public API.
    - next: fix the new open items in the 10:50 Review Findings section.
  timestamp: 2026-11-04T16:56:22.104697+00:00
- actor: claude-code
  id: 01m6kxg682zb42ndz3p4q5fe7w
  text: |-
    ### implement — changed
    - evidence: 22 findings of the 10:50 section fixed and checked.
      - Files changed: Package.swift; Examples/CodeContextExample/main.swift, Examples/ManagerExample/main.swift, Examples/IndexBenchmark/main.swift; new target Examples/ExampleSupport (HashingEmbedder.swift, ExampleArguments.swift, ExampleOutput.swift, ExampleSelection.swift); Sources: Tracing/CodeContextSpans.swift, Search/CodeSelection.swift, Ops/SearchCode.swift, Ops/ManagerQueries.swift; Tests: Support/SearchSpanTreeCheck.swift (new), Support/FakeEmbedder.swift (doc), ManagerQueriesTests.swift, TracingSpanTests.swift.
      - Magic numbers (3 example files): argument positions moved to ExampleArguments (private named constants); IndexBenchmark has named `attosecondsPerSecond` and `percentFactor`.
      - print directives (10 + 4 invariant-propagation): one function `ExampleOutput.report(_:)` holds the one directive. Every print of the three examples calls it.
      - `swift/optionals`: ManagerExample uses `guard let containingContext` in a nested `demonstrateRouting()`.
      - Duplicated HashingEmbedder: new library target `ExampleSupport` (no product), public `HashingEmbedder`, used by CodeContextExample and ManagerExample. The graph stays small: the target depends on the library, Extras and Ranker. Ranker is no longer a direct dependency of the two examples.
      - Span duplication: private `CodeContextSpans.withCountedSpan`; `withSearchSpan` and `withSelectionSpan` call it. New `CodeSelection.search(...)` owns the search span, the retrieval and the selection for both `SearchCode.run` and `CodeContextManager.searchCode`. Each caller passes only its retrieval and its result build.
      - Test reuse: `SearchSpanTreeCheck.expectOneSearchSpanWithOneSelectChild` is used by TracingSpanTests and ManagerQueriesTests; the `spans(named:in:)` helper exists once.
    - Extra fixes from repeated whole-file reviews of the examples (the engine found new items in old code each run, all fixed): `firstRegularFile` throws instead of hiding errors; IndexBenchmark `timed` helper, one `EmbedStats.Snapshot`, one `quotient` helper, `Duration.inSeconds`/`formattedSeconds`.
    - Note: the engine reports `HashingEmbedder` as a copy of the test `FakeEmbedder`. It is not a copy: the test double seeds a random generator with the text hash (no two texts near), the example counts hashed tokens. Both docs now say this and name the other.
    - Note: a `static func` in an enum namespace in ManagerExample/main.swift gave `dead-code-swift` findings (false: called from the top level), while a top-level func gave `swift/immutability`. Global `runExample`, `report`, `firstRegularFile` plus a nested local `demonstrateRouting` satisfy both rules.
    - Commands: `swift build` ok; each example built with `swift build --product`; `swift build --package-path IntegrationTests --build-tests` ok; `swift test` 1141 tests in 100 suites passed; `swift format lint -r --strict Sources Tests Examples IntegrationTests Package.swift` 0 findings. Only the allowed mlx "missing creator" warning.
    - Review engine: `review file Examples/**/*.swift` 0 findings (final run, after 6 rounds); `review working` 0 findings (16 files); `review file Examples/ExampleSupport/HashingEmbedder.swift` reports only the FakeEmbedder-copy claim above (documented, not a copy).
    - next: /review
  timestamp: 2026-11-04T18:35:19.682070+00:00
- actor: claude-code
  id: 01m6kxt3hvj1bmg0jr5e769naf
  text: |-
    ### test - green
    - evidence: swift build, build of 3 examples, swift build --package-path IntegrationTests --build-tests, swift format lint -r --strict, and swift test all exit 0. The only warning is the allowed "missing creator for mutated node" mlx-swift_Cmlx.bundle warning.
    - next: review
  timestamp: 2026-11-04T18:40:44.603429+00:00
depends_on:
- 01M6KHG55E3K73B27F5AJWFM9Y
position_column: doing
position_ordinal: '80'
title: Add a required selection model to CodeContext and run SelectionTier after retrieval in search code
---
## What
The user said: "we need to pass ranker an LLM and an Embedder". Only the embedder was done. Task 01M2JFQ6YZ3FM3G0CY3040SMDS wrote "Do not add one". That line is wrong.

Make the selection model a required input of `CodeContext`. Follow FoundationModelsMultitool: the host picks the model, and this package ships no model. In Multitool, `SearchToolsTool.init(registry:selection:embedder:...)` takes a `SelectionFactory` (`(ids) throws -> SelectionConfig`), and `SelectionConfig` holds an `any LanguageModel`. The user does not want the model to be optional here. There is no `nil` and no silent fallback to retrieval only.

New signature (name to check against Multitool): `CodeContext(rootDirectory:embedder:selection:autoInstall:indexDirectory:)`, with `selection` required and not `nil`.

## Steps
- [ ] Read `FoundationModelsRanker` `Searcher.swift`, `Selection/SelectionTier.swift`, `Selection/SelectionConfig.swift` and `FoundationModelsMetadataRegistry` `MetadataSearcher`. `Searcher` has a fixed catalog, so it may not fit an index that changes per file. Find how to run `SelectionTier` over the candidates of `HybridRanker` for a changing index. Write what you find in a task comment before you code.
- [ ] Add the required `selection` input to `CodeContext` and `CodeContextManager`. Keep `embedder` required.
- [ ] `search code`: retrieve, then run the selection tier over the candidates. An error of the selection session is the error of the call. The model reads it. Do not hide it.
- [ ] Add a fake `LanguageModel` to `Tests/FoundationModelsCodeContextTests/Support/`, like `FakeEmbedder`.
- [ ] Update every caller: tests, `Examples`, `IntegrationTests`.
- [ ] Keep the 10-minute budget of the integration run. Bound every selection call.

## Acceptance Criteria
- [ ] `CodeContext(...)` does not compile without `selection`.
- [ ] A test shows that selection reorders or filters the retrieval candidates.
- [ ] A test shows that a selection error is the error of `search code`.
- [ ] `swift build`, `swift build --package-path IntegrationTests --build-tests`, `swift test` and the format lint are green.

## Notes
- Breaking API change. FoundationModelsACPAgent builds `CodeContext` in `CodeContextLease.makeUnsharedLease`. It must pass the model in the same change window. The ACPAgent session owns that task.
- This task depends on the HybridRanker task (01M6KHG55E3K73B27F5AJWFM9Y), so the selection tier sits on the Ranker path and not on the hand-written fusion.

## Workflow
Use /tdd. Write a failing test first. #retrieval #breaking-change

## Review Findings (2026-11-04 10:35)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 32 file(s) reviewed, 8 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

> 4 file(s) not reviewed — no validator matched:
> - `README.md` — no validator matches this file
> - `docs/language-servers.md` — no validator matches this file
> - `docs/multiple-repos.md` — no validator matches this file
> - `plan.md` — no validator matches this file

- [x] `Examples/ManagerExample/main.swift:113` `code-hygiene/dead-code-swift` — var.global `searchResults` is unused.
- [x] `Examples/ManagerExample/main.swift:113` `code-hygiene/dead-code-swift` — var.global `searchFailures` is unused.
- [x] `Sources/FoundationModelsCodeContext/Ops/SearchCode.swift:290` `task/acceptance-criteria (tracing)` — `CodeContextTracing.AttributeKey.searchResultCount` is documented as "The number of results that one search gives". `retrieve` sets it with `resultCount: \.hits.count`, so it now holds the number of retrieval candidates. The call returns the selected hits, and selection filters. The span value and the returned hit count differ. Record the number of selected hits that the call returns on the search span (or change the vocabulary text of `searchResultCount` and add a second attribute for the selected count), and add a test in `TracingSpanTests` for it.
- [x] `Sources/FoundationModelsCodeContext/Search/CodeSelection.swift:107` `task/acceptance-criteria (tracing)` — The selection step (the model call, the slowest part of a search) runs outside every span. `CodeContextTracing.SpanName.search` is documented as "One `searchCode` call", but the span in `SearchCode.retrieve` ends before selection starts, and the manager path (`Ops/ManagerQueries.swift:111`) has no span for its one call that runs the selection. Add a selection span name to `CodeContextTracing.SpanName` (child of the search span, no query and no chunk text in it), open it in `CodeSelection.select`, make the one `searchCode` call of `SearchCode.run` and of the manager fan-out the owner of the search span, and add the span to `TracingSpanTests` and to the span, log and metric checks of `TelemetryContentSafetyTests`.
- [x] `Tests/FoundationModelsCodeContextTests/CodeSearchToolTests.swift:120` `task/acceptance-criteria (tests)` — No test shows that a selection error is the error of the `code_search` tool path. `SearchCodeSelectionTests`, `ManagerQueriesTests` and `CodeContextE2ETests` cover the engine, the context and the manager. Add a test that gives the tool a `CodeContext` with a selection factory or model that throws, runs the `search code` operation, and expects the error to be thrown by the tool (no `.corrective` text and no retrieval-only result).

## Review Findings (2026-11-04 10:50)

> Scope: `review sha HEAD~1..HEAD` (c7b0bc4) — reviewed the diffs only — lines this change added or modified. 13 file(s) reviewed, 2 not reviewed. Prior items 1 to 5 of the 10:35 section are checked against the code and are fixed. This section holds the new findings of the engine, plus the findings of `review file Examples/**/main.swift`.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Examples/ManagerExample/main.swift:51` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `Examples/ManagerExample/main.swift:70` `code-hygiene/disallowed-constructs-swift` — no_direct_standard_out_logs: Do not commit print(…), debugPrint(…), dump(…) or _printChanges(), which write to standard out in release. Log to a dedicated logging system, or silence one debug-only line with // swiftlint:disable:next no_direct_standard_out_logs and the reason after it.
- [x] `Examples/ManagerExample/main.swift:72` `code-hygiene/disallowed-constructs-swift` — no_direct_standard_out_logs: Do not commit print(…), debugPrint(…), dump(…) or _printChanges(), which write to standard out in release. Log to a dedicated logging system, or silence one debug-only line with // swiftlint:disable:next no_direct_standard_out_logs and the reason after it.
- [x] `Examples/ManagerExample/main.swift:92` `code-hygiene/disallowed-constructs-swift` — no_direct_standard_out_logs: Do not commit print(…), debugPrint(…), dump(…) or _printChanges(), which write to standard out in release. Log to a dedicated logging system, or silence one debug-only line with // swiftlint:disable:next no_direct_standard_out_logs and the reason after it.
- [x] `Examples/ManagerExample/main.swift:107` `code-hygiene/disallowed-constructs-swift` — no_direct_standard_out_logs: Do not commit print(…), debugPrint(…), dump(…) or _printChanges(), which write to standard out in release. Log to a dedicated logging system, or silence one debug-only line with // swiftlint:disable:next no_direct_standard_out_logs and the reason after it.
- [x] `Examples/ManagerExample/main.swift:109` `code-hygiene/disallowed-constructs-swift` — no_direct_standard_out_logs: Do not commit print(…), debugPrint(…), dump(…) or _printChanges(), which write to standard out in release. Log to a dedicated logging system, or silence one debug-only line with // swiftlint:disable:next no_direct_standard_out_logs and the reason after it.
- [x] `Examples/ManagerExample/main.swift:112` `code-hygiene/disallowed-constructs-swift` — no_direct_standard_out_logs: Do not commit print(…), debugPrint(…), dump(…) or _printChanges(), which write to standard out in release. Log to a dedicated logging system, or silence one debug-only line with // swiftlint:disable:next no_direct_standard_out_logs and the reason after it.
- [x] `Examples/ManagerExample/main.swift:120` `code-hygiene/disallowed-constructs-swift` — no_direct_standard_out_logs: Do not commit print(…), debugPrint(…), dump(…) or _printChanges(), which write to standard out in release. Log to a dedicated logging system, or silence one debug-only line with // swiftlint:disable:next no_direct_standard_out_logs and the reason after it.
- [x] `Examples/ManagerExample/main.swift:122` `code-hygiene/disallowed-constructs-swift` — no_direct_standard_out_logs: Do not commit print(…), debugPrint(…), dump(…) or _printChanges(), which write to standard out in release. Log to a dedicated logging system, or silence one debug-only line with // swiftlint:disable:next no_direct_standard_out_logs and the reason after it.
- [x] `Examples/ManagerExample/main.swift:125` `code-hygiene/disallowed-constructs-swift` — no_direct_standard_out_logs: Do not commit print(…), debugPrint(…), dump(…) or _printChanges(), which write to standard out in release. Log to a dedicated logging system, or silence one debug-only line with // swiftlint:disable:next no_direct_standard_out_logs and the reason after it.
- [x] `Sources/FoundationModelsCodeContext/Ops/ManagerQueries.swift:108` `duplication/duplication` — The manager searchCode opens its search span with the same call as SearchCode.run. Both call CodeContextSpans.withSearchSpan with CodeContextTracing.SpanName.search, the tracer, limit: topK, and a result-count key path. Only the key path differs (\.results.count here, \.hits.count there). The two copies can drift apart, for example if the span name, the limit attribute, or the result-count rule changes in only one place. Move the span wrapping into one shared helper that takes the retrieval-and-selection body and the result-count closure as arguments, for example a search-span helper on CodeContextSpans. Call it from both searchCode and SearchCode.run, so each site passes only its own body and its own result count.
- [x] `Sources/FoundationModelsCodeContext/Ops/ManagerQueries.swift:122` `duplication/duplication` — The manager searchCode repeats the selection tail of SearchCode.run. Both build SelectionCandidate values from the retrieved hits, call CodeSelection.select with the same arguments (query, limit: topK, factory: selection, tracer: tracer), and return the selected payloads. Only the candidate source differs: the manager interleaves several roots, and SearchCode.run reads one corpus. A later change to the selection call would have to be made in both places. Extract a shared internal helper, for example CodeSelection.selectAndSummarize(candidates:query:limit:factory:tracer:), or move the candidate-to-select step into CodeSelection. Call it from both searchCode and SearchCode.run. Keep the per-source candidate construction at each call site, since that part really differs.
- [x] `Sources/FoundationModelsCodeContext/Tracing/CodeContextSpans.swift:140` `duplication/duplication` — The new withSelectionSpan repeats the body of withSearchSpan. Both wrap withSpan, set a start attribute in the attributes closure, run body, and then set one result-count attribute from resultCount(output). Only the span name, the attribute keys, and the optional limit differ. The two copies can drift apart, for example in how an error or a result count is recorded. Extract one generic helper, for example withCountedSpan(name, tracer:, attributes:, resultKey:, resultCount:, body). Make withSelectionSpan and withSearchSpan call it with their own name, keys, and count closure. Changing withSearchSpan is a separate change from this one, so it can be done as a follow-up task if the review scope must stay on the new code.
- [x] `Sources/FoundationModelsCodeContext/Tracing/CodeContextSpans.swift:140` `reuse/reuse` — The new withSelectionSpan repeats the body of withSearchSpan (lines 107-124). Both call withSpan with a count attribute set before the body, run the body, and then write a result count after it. The only differences are the span name, the attribute key, and the closure that gives the count. This is a near-match that was not extended. Each new span helper adds another copy of the same error-handling and attribute-writing logic that must stay in step. Generalize withSearchSpan into one private helper. It takes the span name, the count attribute key, the count value, the result attribute key, and the result count closure. Then withSearchSpan and withSelectionSpan become one-line calls to that helper.
- [x] `Tests/FoundationModelsCodeContextTests/ManagerQueriesTests.swift:333` `reuse/reuse` — The new test aManagerSearchCodeGivesOneSearchSpanAndOneSelectSpanAsItsChild rebuilds the span-tree check that TracingSpanTests already has. It filters finishedSpans by operation name, asserts one search span and one select span, checks the parent link, and checks the count attributes. The near-copy is a parallel check for the same behavior, so the two copies can drift apart. Move the span-tree assertions into one shared test helper that takes the tracer and the expected counts. Use it from both TracingSpanTests and ManagerQueriesTests. Or extend the existing TracingSpanTests test to cover the manager path, so only one copy remains.

Findings of `review file Examples/**/main.swift` (whole files, code-hygiene validator) that the diff scope did not report:

- [x] `Examples/ManagerExample/main.swift:70` `completeness/invariant-propagation` — This print has no swiftlint directive for no_direct_standard_out_logs. The sibling examples put the directive on each print, so this one breaks that convention. Add `// swiftlint:disable:next no_direct_standard_out_logs` on the line above this print. The same applies to lines 92, 107 and 120 of this file.
- [x] `Examples/ManagerExample/main.swift:102` `swift/optionals` — The `if let containingContext` binding nests its success branch, and it has a trailing `else` that prints the failure message. Write `guard let containingContext = try await manager.context(containing: sampleFile) else { print("...found no covering root"); return }`, then read `containingContext.state.rootDirectory` at the top level of the scope.
- [x] `Examples/ManagerExample/main.swift:183` `duplication/duplication` — The whole `HashingEmbedder` type (lines 183-251) is a verbatim copy of the `HashingEmbedder` in Examples/CodeContextExample/main.swift. Both copies use the same FNV-1a hash, token split, and normalization. If one copy changes and the other does not, the two examples produce different vectors for the same text, and the index written by one example does not match the other. Move `HashingEmbedder` into one shared support target in Package.swift (a small library target that both example executables depend on). Make the type public, then delete both copies from the two example files. If the team keeps the copies on purpose, record that decision in one place and accept the drift risk. This validator does not decide that trade-off.
- [x] `Examples/CodeContextExample/main.swift:58` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `Examples/CodeContextExample/main.swift:136` `duplication/duplication` — The `HashingEmbedder` type (lines 136-204) is a verbatim copy of the `HashingEmbedder` in Examples/ManagerExample/main.swift. Move it into one shared support target and delete both copies (same fix as the ManagerExample finding above).
- [x] `Examples/IndexBenchmark/main.swift:56` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `Examples/IndexBenchmark/main.swift:251` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.

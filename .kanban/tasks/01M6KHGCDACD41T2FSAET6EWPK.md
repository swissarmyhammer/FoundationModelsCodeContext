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

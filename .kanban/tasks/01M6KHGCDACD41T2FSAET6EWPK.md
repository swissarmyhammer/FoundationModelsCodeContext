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
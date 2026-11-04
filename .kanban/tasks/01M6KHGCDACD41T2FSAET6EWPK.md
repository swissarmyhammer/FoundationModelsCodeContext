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
depends_on:
- 01M6KHG55E3K73B27F5AJWFM9Y
position_column: todo
position_ordinal: '8180'
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
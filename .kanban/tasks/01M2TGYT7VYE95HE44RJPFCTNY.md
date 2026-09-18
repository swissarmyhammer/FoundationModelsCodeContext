---
comments:
- actor: claude-code
  id: 01m2thaavjmztc3eqrjf5qnfeq
  text: |-
    Research is complete.

    HOW IT WORKS: `CodeContext.start()` does the reconcile, the project detection and the supervisor start, then it calls `runOneIndexPass()` before it makes the watcher and the index loop task. `runOneIndexPass()` calls `TreeSitterWorker.run`, which parses each dirty file and then calls `embedDirtyChunks`. `embedChunks(forFilePath:)` sends all chunks of one file in one `embed` call. The worker has no cancellation check. `TreeSitterWorker.run` is a static function, thus the `CodeContext` actor is free while a pass runs, and the symbol operations can answer during the pass.

    KEY CODE: `Sources/FoundationModelsCodeContext/CodeContext.swift` (start, stop, runIndexLoop, runOneIndexPass, searchCode, findDuplicates, indexStatus), `Index/TreeSitterWorker.swift`, `CodeContextState.swift` (`IndexProgress`), `CodeContextError.swift`, `Tools/ToolSupport.swift` (`correctiveMessage`), `CodeContextManager.swift` (it passes the embedder to each context).

    BLAST RADIUS: Each test that reads the index immediately after `start()` (E2E tests, tool tests through `ToolTest.withStartedContext`, manager tests), the two examples, README and plan.md. These callers need a method that waits for the first pass.

    DESIGN:
    - `embedder` becomes `TextEmbedding?` on `CodeContext` and `CodeContextManager`. `nil` turns the embedding layer off.
    - `CodeContextError.embeddingDisabled` is the clear error of `searchCode` (and of `findDuplicates`, which has the same fault).
    - `IndexProgress.isEmbeddingEnabled` shows the state of the layer, and `isDrained` ignores the embedding count when the layer is off.
    - `start()` publishes the index status after the reconcile, thus `state.isReady` is `false` while the first pass is not complete. The index loop task runs the first pass. `waitForFirstIndexPass()` is new public API for a caller that needs the complete index.
    - The worker sends batches of a bounded size and calls `Task.checkCancellation()` between files and between batches. One file stays one write transaction.

    NOTE: The validator dump is 12,098 lines, because it holds the tool rules of each language. I read the general rules and all Swift rules. I did not read the rule bodies for Dart, Go, Python, Rust and TypeScript.
  timestamp: 2026-09-18T15:14:18.610086+00:00
- actor: claude-code
  id: 01m2tjedmw0xvwnvwmy3k7w6az
  text: |-
    Implementation notes.

    - Requirement 1: `CodeContext.start()` does the reconcile, the project detection and the supervisor start, publishes the index status, and returns. The index loop task runs the first pass (`runFirstIndexPass`). New public `waitForFirstIndexPass()` is for a caller that needs the complete index. `indexStatus()` now reads the counts from the store, thus it shows the progress of a pass that runs.
    - Requirement 2: `embedder` is `TextEmbedding?` on `CodeContext` and `CodeContextManager`. With `nil`, `searchCode` and `findDuplicates` throw the new `CodeContextError.embeddingDisabled`, and `IndexProgress.isEmbeddingEnabled` is `false` (`isDrained` then ignores `filesEmbedded`). The tools give `.embeddingDisabled` as a corrective message that names `grep code` and `search symbol`.
    - Requirement 3: `TreeSitterWorker.run(store:rootDirectory:embedder:embeddingBatchSize:)` sends batches of `defaultEmbeddingBatchSize` (32) texts at most and calls `Task.checkCancellation()` before each file and each batch. One file stays one write transaction.
    - Requirement 4: `stop()` cancels the loop task. `CodeContextStartTests.stopDuringTheFirstPassCancelsThePass` proves it with a gated embedder.

    Additions that the card does not list: `waitForFirstIndexPass()` (the callers that read the index after `start()` need it), the `findDuplicates` error (same fault as `searchCode`), and the JSON key `isEmbeddingEnabled` (two pinned test strings changed).

    TDD record: the worker, state and tool-support tests failed at run time before the production code. The `CodeContextStartTests` were red as a compile failure only (the API did not exist), because a stub stage of `CodeContext.swift` was too costly.

    Corrections to the research comment: I read the Swift prompt rules fully, but only the first part of each Swift tool rule (function length 250, magic numbers, missing docs, periphery, disallowed constructs, idioms). One test file line was changed with `sed` before I went back to the file tool.

    A helper agent did the mechanical part (manager, callers, README, plan.md, examples). I examined its diff and ran the suite again.

    New card: ^q6q0ygb (two index passes can run at the same time and embed the same files twice).

    The ACP agent can now remove its background `start()` task and its `ZeroTextEmbedding` (pass `embedder: nil`).

    ### implement — changed
    - evidence: `swift test`: 631 tests in 59 suites passed, 0 warnings from package files; `swift build --build-tests --package-path IntegrationTests` builds. 22 files — Sources: CodeContext.swift, CodeContextError.swift, CodeContextManager.swift, CodeContextState.swift, Index/TreeSitterWorker.swift, Tools/ToolSupport.swift; Tests: CodeContextStartTests.swift (new), EmbeddingBatchTests.swift (new), Support/GatedEmbedder.swift (new), CodeContextE2ETests.swift, CodeContextManagerTests.swift, CodeContextStateTests.swift, DiagnosticsReportPublicVisibilityTests.swift, ManagerQueriesTests.swift, ResultEncodingTests.swift, ToolSupportTests.swift, ToolTestSupport.swift; IntegrationTests LiveSourceKitTests.swift; Examples/CodeContextExample/main.swift, Examples/ManagerExample/main.swift; README.md; plan.md
    - next: /review
  timestamp: 2026-09-18T15:34:01.116240+00:00
- actor: claude-code
  id: 01m2tjh631dn0zah9f30vak3rw
  text: |-
    ### test — green
    - evidence: swift test — 631 tests, 59 suites, 0 failed, 0 skipped. swift format lint -s -r Sources Tests — clean, 0 findings.
    - next: send the task to review.
  timestamp: 2026-09-18T15:35:31.681842+00:00
- actor: claude-code
  id: 01m2tjj419aqd756ttzefcyew7
  text: |-
    ### commit — changed
    - evidence: staged all source, tests, and .kanban files; one local commit follows this comment
    - next: none
  timestamp: 2026-09-18T15:36:02.345828+00:00
- actor: claude-code
  id: 01m2tk0yfx55w94e070sve8d1c
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit 3c4605a). Counts: 0 findings, 0 confirmed, 2 refuted, 14 attempted, 0 failed. 20 files reviewed. 10 files not reviewed: 8 files in `.kanban/` (excluded by `.reviewignore`), and `README.md` and `plan.md` (no validator matches these files).
    - next: none. The task has no prior `## Review Findings` section, thus the task moved to `done`.
  timestamp: 2026-09-18T15:44:08.189364+00:00
- actor: claude-code
  id: 01m2tk19tp12yjn9xvddkr0y9y
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 22 files
    - test: green — swift test, 631 tests in 59 suites passed, 0 failed, 0 skipped
    - commit: 3c4605a
    - review: clean — 0 findings, 20 files reviewed
  timestamp: 2026-09-18T15:44:19.798091+00:00
position_column: done
position_ordinal: ca80
title: start() does not return until the full embedding pass is complete, and a host cannot turn the embedding off
---
## What

`CodeContext.start()` calls `runOneIndexPass()` before it returns (`CodeContext.swift:220`). That pass runs `TreeSitterWorker.run`, which embeds each dirty chunk with the embedder of the host (`TreeSitterWorker.embedDirtyChunks`, `embedChunks(forFilePath:)`).

On 2026-09-18 `FoundationModelsACPAgent` called `start()` in `session/new`, for a clone of django: 2,849 files and 44,532 chunks. The embedder was the MLX embedding model of the Router profile. After 8 minutes, 273 chunks had an embedding, and the count did not move for the last 3 minutes. The ACP client stopped at its 600 second limit, and the SWE-bench run failed. A sample of the process showed the stack `start()` -> `runOneIndexPass()` -> `embedDirtyChunks` -> `embedChunks(forFilePath:)` -> the embedder.

With a zero-vector embedder, the same repository parses 33,070 chunks in 181 seconds (debug build), thus the tree-sitter work is not the problem.

## Three faults

1. **`start()` has no bound.** A host cannot get a started context for a large repository in a bounded time. The README example shows `try await context.start()` with no warning. The symbol and language server operations do not need the embedding layer, but they wait for it.
2. **There is no switch for the embedding layer.** A host that wants symbols, the call graph and the language servers, and no semantic search, must give an embedder that makes zero vectors. `searchCode` then gives a useless order and no diagnostic.
3. **One file is one embed batch.** `embedChunks(forFilePath:)` sends all chunks of a file in one `embed` call. A large file is one very large batch, and the count of embedded chunks stopped for minutes in one call.

## The work

1. `start()` returns after the reconcile, the project detection and the start of the language servers. The first index pass runs in the index loop task, not in `start()`.
2. An option turns the embedding layer off (for example an optional embedder, or an `IndexLayers` option). `searchCode` then gives a clear error, and `getStatus` shows that the layer is off.
3. The embedding step sends batches of a bounded size, and it looks for task cancellation between batches.
4. `stop()` during the first pass cancels the pass and returns promptly.

## Where it was found

`FoundationModelsACPAgent`, card `^bt2wyyz`. The agent works around it: it calls `start()` in a background task, and its `tools.codeContext.semanticSearch: false` option gives a `ZeroTextEmbedding`. When this card is done, the agent can remove both. #index #cross-repo
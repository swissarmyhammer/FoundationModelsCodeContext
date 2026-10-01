---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3wqv6ydv8kyv865wf8yzxac
  text: |-
    Research:
    - `ProjectDetection.detectProjects` is the one source for both `LspSupervisor.performStart()` (which daemons start) and `CodeContext.start()` (which LSP index tasks run, `coveredLspExtensions`). A rule in `detectProjects` keeps the two in step.
    - Decided rule: a marker gives a project of a module only when the subtree of the marker directory holds at least one non-ignored file with an extension of that module (`LanguageModule.fileExtensions`). The same `Walker.walkEntries` pass gives the extensions, so no second walk. Real C/C++ and Node projects have such files, thus they keep their server. For real Django, `docs/Makefile` gives no C/C++ project (no `.c`/`.h`/`.cpp` file). The root `package.json` still gives a JavaScript project, because Django has `.js` files (admin static files, `js_tests`), thus typescript-language-server still starts there. That is correct: the tree has files of that server.
    - Existing tests that use a marker with no source file (ProjectDetectionTests, LspSupervisorTests, the composer.json auto-install tests in CodeContextE2ETests and CodeContextManagerTests) must get one source file each.
    - Cancellation: `Store.withDbAccess` wraps each non-`CodeContextError` error in `CodeContextError.storage(String)`, thus the type `CancellationError` is lost. GRDB 7 calls `Task.checkCancellation()` in its async accesses. The worker can only see the cancellation with `error is CancellationError || Task.isCancelled`. Store-error log sites: `processFile` write, `markIndexedIgnoringErrors`, `isChangedSinceLastPass`. Request-failure log sites (warning, through `LspSession.logFailure`): syncOpen, documentSymbols, didClose, prepareCallHierarchy, outgoingCalls, references, definition.
    - A `CodeContext`-level unit test cannot start the pylsp spec, because `LSPDaemon.start()` needs the binary on `$PATH`. The unit test drives `LSPIndexWorker.run` in a task and cancels it, which is what `stop()` does to each LSP index task. clangd, typescript-language-server and pylsp are installed on this machine, thus the stop() time is measured with a temporary IntegrationTests file (removed after).
  timestamp: 2026-10-01T22:02:33.805464+00:00
- actor: claude-code
  id: 01m3ws3f9xjks83532x393eh2t
  text: |-
    Implementation and measurements:

    - Rule (in `ProjectDetection.detectProjects`): a marker that more than one module declares (`SharedProjectMarkers`: `package.json`, `CMakeLists.txt`, `Makefile`) gives a project only when a non-ignored file with an extension of the module is in the subtree of the marker directory. The set of shared markers is computed one time from `Languages.all`. The subtree extensions come from the same `Walker.walkEntries` pass.
    - What did not work: the first try applied the source-file rule to ALL markers. That broke the two gated composer.json auto-install tests (`CodeContextE2ETests.isReadyIsFalseWhileAnAutoInstallIsPendingAndTrueOnceItResolves`, `CodeContextManagerTests.injectedInstallRunnerReachesEachPerRootContextSupervisor`): a `.php` file is needed for detection, but then the file stays LSP-dirty for ever while intelephense is `.notFound`, thus `isReady` never becomes true. The rule is now scoped to shared markers only, which is the real cause on Django. That latent `isReady` defect is recorded as a new task.
    - Cancellation: new `LSPIndexWorker+FailureLog.swift` with `isStop(_:)` (`error is CancellationError || Task.isCancelled`), `logRequestFailure(of:filePath:error:session:)` and `logStoreFailure(_:filePath:error:)`. Each of the 7 request-failure sites and the 3 store-error sites of `LSPIndexWorker` and `LSPIndexWorker+References` goes through them. A stop writes one debug record, no warning and no error. The file stays dirty.
    - Tests: `ProjectDetectionTests` (4 new), `LspSupervisorTests.startOnAPythonTreeWithANodeMarkerAndADocsMakefileStartsOnlyPylsp`, `LSPIndexWorkerReferencesTests.stoppingTheIndexTaskDuringAReferencesRequestWritesNoErrorRecord` and `...LogsNoRequestFailure` (the fake gets a `referencesCallHook` that keeps the request in flight until the task is cancelled, as `stop()` does). Existing fixtures with only a `package.json` got one `.ts`/`.js` file.
    - stop() time, measured with real clangd, typescript-language-server and pylsp on a tree with `pyproject.toml`, 200 `.py` files, `package.json` and `docs/Makefile` (temporary IntegrationTests file, removed after):
      - Before: servers = clangd, pylsp, typescript-language-server. stop() = 0.22 s (stop 300 ms after start), 0.52 s and 0.51 s (stop after the first pass). Close log: pylsp `references`/`definition`/`documentSymbols` failed with `Swift.CancellationError` (warning); "the content hashes of a file could not be read" and "the LSP index of a file could not be written to the store" (error, `CodeContextError`); "typescript-language-server did not exit in the shutdown grace period" and "clangd did not exit in the shutdown grace period" (warning).
      - After: servers = pylsp only. stop() = 0.22 s, 0.54 s, 0.53 s. Close log: no warning and no error.
      - Shutdown grace: the servers that the index does not use no longer start on such a tree, thus no grace kill. The remaining stop() time is the pylsp shutdown. On real Django, typescript-language-server still starts, because Django has `.js` files (admin static files, `js_tests`); that server has files to index.
  timestamp: 2026-10-01T22:24:33.085993+00:00
- actor: claude-code
  id: 01m3ws3s6c7wq1sgev811zjhdw
  text: |-
    ### implement — changed
    - evidence: 11 files. Sources: Projects/ProjectDetection.swift, Languages/SharedProjectMarkers.swift, Index/LSPIndexWorker.swift, Index/LSPIndexWorker+References.swift, Index/LSPIndexWorker+FailureLog.swift (new); plan.md. Tests: ProjectDetectionTests.swift, LspSupervisorTests.swift, LSPIndexWorkerReferencesTests.swift, Support/FakeLanguageServerConnection.swift, TestSupport.swift. `swift test`: 748 tests in 68 suites passed, 0 failed. `swift format lint --strict` on the changed Swift files: clean. The one build-system line "missing creator for mutated node ... mlx-swift_Cmlx.bundle" comes from the SwiftPM build of the mlx-swift dependency, not from these files.
    - next: review. New task ^7vtt6nt records the latent `isReady` defect for a `.notFound` server.
  timestamp: 2026-10-01T22:24:43.212803+00:00
- actor: claude-code
  id: 01m3ws9thne1k78d6azvgprqwe
  text: |-
    ### test — green
    - evidence: swift test (root) passed, 748 tests in 68 suites, 0 failed, 0 skipped. swift test --package-path IntegrationTests passed, 11 tests in 8 suites, 0 failed, 0 skipped. swift format lint -s -r Sources Tests gave 0 findings.
    - note: the build tool printed one warning in each package: "missing creator for mutated node" for the mlx-swift_Cmlx.bundle dependency product. It does not come from code in this repo.
    - next: review. No source file was changed in this step. Nothing was committed.
  timestamp: 2026-10-01T22:28:01.205527+00:00
- actor: claude-code
  id: 01m3wsafab1yesevtkpsbw8p6w
  text: |-
    ### commit — changed
    - evidence: 988459e fix(lsp): start a language server only for a project with a file of its language
    - next: none. The commit is local. No push.
  timestamp: 2026-10-01T22:28:22.475490+00:00
- actor: claude-code
  id: 01m3wswc48arehbpv8g2wm6fwy
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (5c9b3da). 0 findings, 0 confirmed, 1 refuted, 14 attempted, 0 failed. 10 files were reviewed. 5 files were not reviewed: the .kanban/ files (ignore rule) and plan.md (no validator).
    - next: none. The task moved to done.
  timestamp: 2026-10-01T22:38:09.032975+00:00
- actor: claude-code
  id: 01m3wswkmytx5wmy4m366s1y4y
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 11 files (5 Sources, 1 new; plan.md; 5 Tests)
    - test: green — swift test 748 passed; IntegrationTests 11 passed; swift format lint 0 findings
    - commit: 5c9b3da
    - review: clean — 0 findings, 1 refuted
  timestamp: 2026-10-01T22:38:16.734212+00:00
position_column: done
position_ordinal: d680
title: A mostly-Python tree starts clangd and typescript-language-server, and stop() logs cancellation as LSP index errors
---
## Problem

Found during ^w08na27 (question 3 of that card). The SWE-bench run of 2026-10-01 (FoundationModelsACPAgent, `bench/run.code-context.log`) shows these lines at each session close, on each instance:

- A pylsp `references` request fails with `Swift.CancellationError`.
- Then "the content hashes of a file could not be read; the call sites of the file are not checked" (`LSPIndexWorker+References.swift`) and "the LSP index of a file could not be written to the store" (`LSPIndexWorker.swift`), with a `CodeContextError`.
- Then clangd and typescript-language-server (one time also pylsp) "did not exit in the shutdown grace period; the daemon kills it" (`LSPDaemon.shutdown()`, grace 5 s).
- clangd starts for a Python repository.

## Findings from the code (not yet measured)

1. Why clangd and typescript-language-server start for Django:
   - `ProjectDetection` starts one server for each detected project. Detection uses marker files only.
   - C and C++ use `SharedProjectMarkers.cmakeOrMakefile` (`CMakeLists.txt`, `Makefile`). Django has a `Makefile` (for example `docs/Makefile`), thus clangd starts. Django has few or no C files.
   - TypeScript, TSX and JavaScript use `SharedProjectMarkers.nodeJs` (`package.json`). Django has a `package.json` at the root (JavaScript tests of the admin), thus typescript-language-server starts.
   - Each extra server uses CPU and memory during the first index pass, and each one adds up to 5 s to the close path.
2. The close path order:
   - `CodeContext.stop()` cancels the index loop and each LSP index task and waits for them. Then it stops the watcher, then it calls `supervisor.shutdown()`. `stop()` does not close the store. Thus the store is open while the workers stop.
   - The error lines come from the cancellation itself: the LSP index task is cancelled while a request is in flight. The worker then calls the store from a cancelled task. GRDB throws `CancellationError` for a cancelled task, and `Store.withDbAccess` wraps it in `CodeContextError.storage`. The worker logs that as an error.
   - Thus the order is already correct (cancel the indexer, then shut down the servers, store stays open). The defect is that a cancellation is logged as a store failure.

## Work

- [x] Measure: open a `CodeContext` on a tree with `package.json`, `docs/Makefile` and only Python sources; record which servers start. Record the close log.
- [x] Decide and implement a rule so that a server starts only when the tree has files of its language (for example a marker plus at least one file with an extension of the module, or a lazy start on the first file of that language). Keep the existing marker behavior for real C/C++ and Node projects.
- [x] In `LSPIndexWorker` and `LSPIndexWorker+References`, treat `CancellationError` (also when `CodeContextError.storage` wraps it, or when the task is cancelled) as a normal stop: no error log.
- [x] Look at the shutdown grace: a server that the index does not use should stop fast. Record how long `stop()` takes before and after.

## Decided rule

A marker that more than one module declares (`package.json` for TypeScript, TSX and JavaScript; `CMakeLists.txt` and `Makefile` for C and C++) gives a project only when its directory, or a directory below it, holds a non-ignored file with an extension of that module. A marker of one module only (`Cargo.toml`, `go.mod`, `composer.json`, ...) gives a project as before. `ProjectDetection.detectProjects(rootDirectory:)` applies the rule, thus `LspSupervisor` (which servers start) and `CodeContext.start()` (which LSP index tasks run) stay in step.

## Acceptance criteria

- [x] A test shows that a tree with only Python sources plus `package.json` and `docs/Makefile` does not start clangd and typescript-language-server (or the card records the decided rule and its test).
- [x] A test shows that `stop()` during an LSP index pass writes no error log record for the cancellation.
- [x] The time of `stop()` on such a tree is recorded before and after.
#bug #index #lsp
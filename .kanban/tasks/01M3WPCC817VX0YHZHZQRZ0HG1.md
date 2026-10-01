---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
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

- [ ] Measure: open a `CodeContext` on a tree with `package.json`, `docs/Makefile` and only Python sources; record which servers start. Record the close log.
- [ ] Decide and implement a rule so that a server starts only when the tree has files of its language (for example a marker plus at least one file with an extension of the module, or a lazy start on the first file of that language). Keep the existing marker behavior for real C/C++ and Node projects.
- [ ] In `LSPIndexWorker` and `LSPIndexWorker+References`, treat `CancellationError` (also when `CodeContextError.storage` wraps it, or when the task is cancelled) as a normal stop: no error log.
- [ ] Look at the shutdown grace: a server that the index does not use should stop fast. Record how long `stop()` takes before and after.

## Acceptance criteria

- [ ] A test shows that a tree with only Python sources plus `package.json` and `docs/Makefile` does not start clangd and typescript-language-server (or the card records the decided rule and its test).
- [ ] A test shows that `stop()` during an LSP index pass writes no error log record for the cancellation.
- [ ] The time of `stop()` on such a tree is recorded before and after.
#bug #index #lsp
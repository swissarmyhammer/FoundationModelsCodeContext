---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m57dv363cf59cv47nze9c9v0
  text: |-
    Research and supervisor fix.
    - LspSupervisor now has `StopState` (notStopped / stopping(task) / stopped). shutdown() sets stopping, runs performShutdown in one task (a second shutdown waits for it), performShutdown cancels and awaits inFlightStart before it reads managedDaemons, then sets stopped. start() and startForTesting() call clearStopState(): wait for a shutdown that runs, then set notStopped. spawnAndRegister checks `acceptsNewDaemons` on the actor just before registration and shuts the new daemon down when stopped (the Rust port idea: check the stop flag at registration, no suspension between check and register).
    - inFlightStart is now cleared by the round itself (defer in performStart). Reason: with the old caller defer, a start() that waited for a shutdown could find the old cancelled round still in inFlightStart and return with no spawn.
    - New tests in Tests/FoundationModelsCodeContextTests/LspSupervisorShutdownDuringStartTests.swift. Both failed before the fix (running daemon, live process, 1 clock waiter = health loop) and pass after.
    - A cancelled spawn round still waits for a connection factory or handshake that ignores cancellation (AsyncGate in the test). This is the reason the test opens the gate after it calls shutdown().
    - ManualClock gets `waiterCount`; the private `hasAtLeastWaitersSynchronously` helper is replaced by it (no duplicate lock read).
  timestamp: 2026-10-18T11:55:04.771148+00:00
- actor: claude-code
  id: 01m57epxxyb741zc1ab4rsy6j5
  text: |-
    CodeContext fix and test results.
    - Choice for the CodeContext.stop() item: "block start() until stop() completes". start(), stop(), stopLanguageServers() and startLanguageServers() now go through `runAfterPriorLifecycleCalls(_:)`: one chain of tasks (`lastLifecycleCall`), thus the calls run one at a time in the order they came. A cancel of the caller cancels its operation. The bodies moved to performStart / performStop / performStopLanguageServers / performStartLanguageServers with no change. Reason for serializing all four: a start lsp that passed its isStarted guard could otherwise reach the supervisor after the shutdown of a CodeContext.stop().
    - Test that shows the stop/start race: CodeContextStartTests.aStartDuringAStopWaitsForTheStopAndLeavesTheContextWatchingWithItsServerRunning. Stop is held at the LSP index task by an AsyncGate in the didOpen hook of the fake connection (a cancel does not stop it); waitForFirstIndexPass() returning is the signal that the stop is past the index loop. Before the fix it failed: the stop stopped the watcher of the start that came during the stop (isWatching false). After the fix it passes.
    - Test for "stop lsp then start lsp immediately": CodeContextStartTests.startLanguageServersDuringAStopLeavesOneRunningServerForEachProject (stop held on the shutdown grace of a ManualClock with a fake process that does not exit). This test passed already with only the supervisor fix in place; it guards that the new stop state is cleared by start and does not refuse a start that comes during a stop.
    - LSPDaemonLimits changed from private to internal so the test reads the default shutdown grace.
    - CodeContext.swift had one no_magic_numbers finding (index loop idle sleep 300 ms); now a named constant in a private `CodeContextTiming` enum. swiftlint no_magic_numbers on all changed files: clean.
    - Affected suites: 148 tests in 9 suites passed. Full `swift test`: 991 tests in 88 suites passed. Only warning: the pre-existing build-system "missing creator for mutated node ... mlx-swift_Cmlx.bundle".
  timestamp: 2026-10-18T12:10:16.894796+00:00
- actor: claude-code
  id: 01m57eq0drzesr407z3g6wgec4
  text: |-
    ### implement — changed
    - evidence: Sources/FoundationModelsCodeContext/LSP/LspSupervisor.swift, Sources/FoundationModelsCodeContext/CodeContext.swift, Sources/FoundationModelsCodeContext/LSP/LSPDaemon.swift, Tests/FoundationModelsCodeContextTests/LspSupervisorShutdownDuringStartTests.swift (new), Tests/FoundationModelsCodeContextTests/CodeContextStartTests.swift, Tests/FoundationModelsCodeContextTests/Support/ManualClock.swift; `swift test` 991 tests in 88 suites passed; swiftlint no_magic_numbers clean on changed files
    - next: /review
  timestamp: 2026-10-18T12:10:19.448661+00:00
- actor: claude-code
  id: 01m57f3e2sx488jj1crfmb22z9
  text: |-
    ### test — green
    - evidence: swift test — 991 tests in 88 suites passed, 0 failed, 0 skipped; swift build --package-path IntegrationTests --build-tests — Build complete. Only warning: SwiftPM "missing creator for mutated node" for the mlx-swift_Cmlx.bundle dependency (not from this package).
    - next: commit
  timestamp: 2026-10-18T12:17:06.649734+00:00
- actor: claude-code
  id: 01m57fc7mcred5dt38acj4vsre
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (1d65f09). 0 findings, 0 confirmed, 0 refuted. 6 files reviewed. 4 .kanban files are not reviewed because of .reviewignore. The two acceptance criteria are checked. The change adds the tests that the task specifies (shutdown during a start, stop lsp then start lsp).
    - next: none. The task is in done.
  timestamp: 2026-10-18T12:21:54.956873+00:00
- actor: claude-code
  id: 01m57fchq5zwbyqwt9yaaty80e
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 6 files
    - test: green — swift test, 991 passed
    - commit: 1d65f09
    - review: clean — 0 findings
  timestamp: 2026-10-18T12:22:05.285125+00:00
position_column: done
position_ordinal: ed80
title: LspSupervisor.shutdown must wait for or cancel a start that is in progress
---
## Problem
`LspSupervisor.shutdown()` (`Sources/FoundationModelsCodeContext/LSP/LspSupervisor.swift:396-418`) does not wait for `inFlightStart` (`:167-176`). Both are reentrant actor calls. Thus a spawn round that runs can register live daemons and health loops after `shutdown()` returns. The same race occurs for `CodeContext.stop()` against `start()`, and for the operations `stop lsp` and `start lsp` (`CodeContext.swift:515-520`). The result is a language server that runs with no owner.

- `CodeContext.stop()` sets `isStarted = false` (`CodeContext.swift:397`) before its awaits. A `start()` that runs during these awaits can put new tasks in `lspIndexTasks`. Then `removeAll()` at `:411` drops them and does not cancel them. This is possible from the code; a test must show if it occurs.

## Change
- In `CodeContext.stop()`, cancel and remove the tasks that existed when `stop()` started. Do not remove tasks that a later `start()` added. Or block `start()` until `stop()` completes.
- Add a "stopping" state to the supervisor. `shutdown()` sets it, then cancels `inFlightStart` and waits for it.
- `spawnAndRegister` checks this state before it registers a daemon. If the state is "stopping", it shuts down the new daemon.
- A later `start()` clears the state.

## Tests
- Call `start()`, then call `shutdown()` before the spawn completes (use a fake connection that waits). After `shutdown()` returns, no daemon is running and no health loop is active.
- `stop lsp` then `start lsp` immediately still gives one running daemon for each server.

## Acceptance criteria
- [x] No daemon runs after `shutdown()` returns.
- [x] The tests above pass.

#lsp-fix
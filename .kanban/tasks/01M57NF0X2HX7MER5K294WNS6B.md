---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m57pkjh49ky87hsh0ewpchwg
  text: |-
    Research:
    - `LspSupervisor.performShutdown()` cancels each install task, then awaits it, then shuts the daemons down. The install task calls `forceRestart(reason: .install)` only when it is not cancelled.
    - `FakeInstallRunner.run` records the invocation and sets the gate continuation in one actor turn. Thus `invocations.count == 1` tells that the install waits at the gate.
    - `onRun` of `FakeInstallRunner` runs after the gate opens, before the install returns. A flag that `onRun` sets, read by the shutdown task after `shutdown()` returns, proves the order "install ended, then shutdown returned" with state.
    - `LSPDaemon.forceRestart(reason:)` adds 1 to the restart counter with the reason `install`. A `TestMetrics` factory shows if the install restart occurred (`MetricsTests.restartDimensions` gives the dimensions).
    - No observable state tells that `shutdown()` has started its wait. A named head-start wait before the gate opens stays. It cannot make a correct run fail; it only gives a defective `shutdown()` time to return early.
    Plan: replace `elapsed < .seconds(5)` and the 20 ms / 100 ms sleeps with these state checks, add `.timeLimit(.minutes(testTimeLimitMinutes))`, rename the test.
  timestamp: 2026-10-18T14:28:15.524622+00:00
- actor: claude-code
  id: 01m57prec911ps4r8b6h2g792g
  text: |-
    Implementation landed:
    - `LspSupervisorTests.shutdownDuringInFlightInstallCancelsCleanlyAndPromptly` is now `shutdownDuringAGatedInstallReturnsOnlyAfterTheInstallAndLeavesTheDaemonNotStartedWithNoInstallRestart`, with `.timeLimit(.minutes(testTimeLimitMinutes))`.
    - Removed: `elapsed < .seconds(5)`, the 20 ms sleep, and the 100 ms settle window.
    - New proof with state: (1) `waitUntil { runner.invocations.count == 1 }` before the shutdown, thus the install waits at the gate; (2) `onRun` sets a `Box<Bool>` flag, and the shutdown task returns that flag after `shutdown()` returns: it must be `true`; (3) the daemon state after the shutdown is `.notStarted`; (4) a `TestMetrics` factory has no restart counter with the reason `install`.
    - One named lower-bound wait stays: `shutdownHeadStart` (100 ms) before the gate opens. It is not a time limit; a slow scheduler cannot make a correct run fail.
    - `MetricsTests.restartDimensions(server:reason:)` is now `internal` (was `private`), for reuse.
    RED proof (production code temporarily changed, then restored to HEAD, `git diff -- Sources` empty):
    - Removed the `await installTask.value` loop of `performShutdown()`: the test failed on `installEndedBeforeTheShutdownReturned`.
    - Removed the `installTask?.cancel()` of `performShutdown()`: the test failed on `installRestarts == nil` (counter total 1).
    GREEN: the new test passed. Full `swift test`: 1012 tests in 90 suites passed. One build warning stays, `missing creator for mutated node ... mlx-swift_Cmlx.bundle`, from the SwiftPM build of the mlx-swift dependency, not from this change. New task ^kw00hcn records it.
  timestamp: 2026-10-18T14:30:55.113463+00:00
- actor: claude-code
  id: 01m57prhw2j2606rf4kggxmv8e
  text: |-
    ### implement — changed
    - evidence: 2 files — Tests/FoundationModelsCodeContextTests/LspSupervisorTests.swift, Tests/FoundationModelsCodeContextTests/MetricsTests.swift; `swift test --filter LspSupervisorTests/shutdownDuringAGatedInstall` RED x2 (production temporarily changed), then GREEN 1/1; full `swift test` 1012 tests in 90 suites passed, 0 failures; 1 build warning from the mlx-swift dependency (task ^kw00hcn)
    - next: /review
  timestamp: 2026-10-18T14:30:58.690511+00:00
- actor: claude-code
  id: 01m57pt0fky9kvsksa7hdbjdwb
  text: |-
    ### test — green
    - evidence: swift test (root package) — 1012 tests in 90 suites passed, 0 failed, 0 skipped. One warning only: SwiftPM "missing creator for mutated node ... mlx-swift_Cmlx.bundle". It comes from a dependency. Task ^kw00hcn tracks it.
    - next: review
  timestamp: 2026-10-18T14:31:46.419698+00:00
position_column: doing
position_ordinal: '80'
title: 'LspSupervisorTests: replace the 5-second real-time limit of the shutdown-during-install test'
---
## Problem
In `Tests/FoundationModelsCodeContextTests/LspSupervisorTests.swift`, the test that races `shutdown()` against a gated install (`FakeInstallRunner` with a closed gate) asserts `elapsed < .seconds(5)` in real time from the start of `shutdown()` to `shutdownTask.value`. This is the same kind of real-time assertion that ^vqpcb1t removed from `ProcessInstallRunnerTests`. Under full-suite load the scheduler delay can be more than 6 seconds, thus the test can fail when the machine is busy. The test also uses fixed real-time sleeps (20 ms before the gate opens, 100 ms settle window).

Found during ^vqpcb1t.

## Change
- Make the assertion independent of the scheduler. Prove the behavior (shutdown resolves after the gate opens, no state change after the shutdown) with state, not with a tight real-time limit. If a time limit stays, use a named constant far above the scheduler delay.

## Acceptance criteria
- [x] The test proves the shutdown behavior, not that the scheduler is fast.
- [x] The full unit suite passes.

#test-flake
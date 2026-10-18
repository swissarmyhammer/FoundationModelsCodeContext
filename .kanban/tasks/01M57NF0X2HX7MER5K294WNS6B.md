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
- actor: claude-code
  id: 01m57pthne30aanjz79ff5xbqb
  text: |-
    ### commit — changed
    - evidence: 6f6f949 test: check state, not time, in the install stop test ^94wns6b (10 files)
    - next: review
  timestamp: 2026-10-18T14:32:04.014293+00:00
- actor: claude-code
  id: 01m57pxhxy3td7m6m8708rs2hr
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (6f6f949) — 2 findings, 2 confirmed, 0 refuted — Tests/FoundationModelsCodeContextTests/LspSupervisorTests.swift:830 (swift/optionals), Tests/FoundationModelsCodeContextTests/LspSupervisorTests.swift:830 (test-integrity/no-test-cheating)
    - next: Remove the `try?` on `metrics.expectCounter(...)`. Make the absence assertion fail on a broken counter lookup. The task stays in review.
  timestamp: 2026-10-18T14:33:42.590806+00:00
- actor: claude-code
  id: 01m57pxszhy024rmypttbx00wc
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 2 files
    - test: green — swift test, 1012 passed
    - commit: 6f6f949
    - review: findings — Tests/FoundationModelsCodeContextTests/LspSupervisorTests.swift:830 (swift/optionals), Tests/FoundationModelsCodeContextTests/LspSupervisorTests.swift:830 (test-integrity/no-test-cheating)
  timestamp: 2026-10-18T14:33:50.833578+00:00
- actor: claude-code
  id: 01m57q103tcjtj1hvk17dc0a7t
  text: |-
    Research for the 2 review findings:
    - `TestMetrics.expectCounter(_:_:)` (MetricsTestKit) throws `TestMetricsError.missingMetric(label:dimensions:)` when no counter has the label and the dimensions. The only other case is `illegalMetricType`.
    - A wrong label or a wrong dimension also gives `missingMetric`. Thus an assertion on the error case alone cannot find a wrong lookup key. A positive control is necessary: record an install restart with `CodeContextMetrics(factory:).addServerRestart(server:reason: .install)` into a second `TestMetrics`, and find it with the same lookup.
    - Plan: one helper does the lookup for the control and for the real factory. The control must find a counter with total 1. The real factory must throw `missingMetric` (`#expect(throws: TestMetricsError.self)` plus a case check).
    - Other `try?` in the file: (1) `try? await Task.sleep` before the assertion of `shutdownRacingAnInFlightRestartHandshakeAlwaysWinsAndLeavesTheDaemonNotStarted`: a cancel skips the settle window silently; change it to `try await`. (2) `try? Self.materializeFakeBinary` in the `onRun` closure of `autoInstallSuccessTransitionsNotFoundToInstallingToRunning`: a failure becomes a later, unclear wait timeout; change it to `#expect(throws: Never.self)`. (3) The `defer { try? FileManager.default.removeItem(...) }` lines are cleanup of a folder that can be absent, not assertions; they stay.
  timestamp: 2026-10-18T14:35:35.418128+00:00
- actor: claude-code
  id: 01m57q4nwbs73xpgtya1hjc0pr
  text: |-
    Implementation landed for the 2 review findings (LspSupervisorTests.swift only):
    - Removed `try? metrics.expectCounter(...)` and `#expect(installRestarts == nil)`. New private helper `installRestarts(of:in:)` does the one lookup (label `lspServerRestarts`, dimensions from `MetricsTests.restartDimensions` with `CodeContextMetrics.RestartReason.install.rawValue`).
    - Positive control: a second `TestMetrics` gets one `CodeContextMetrics(factory:).addServerRestart(server:reason: .install)`; the helper must find it with `totalValue == 1` (no `try?`, a throw fails the test).
    - Absence: `#expect(throws: TestMetricsError.self)` on the helper with the supervisor factory, then `isMissingMetric(_:)` must be true. `illegalMetricType` or no throw fails the test.
    - RED proof: with the reason `instal` in the helper (a broken lookup), the test failed with `missingMetric ... ("lsp.restart_reason", "instal")`. The old `try?` form passes in that case. Then the reason was restored.
    - Same cause, other places in the file: `try? await Task.sleep(for: .milliseconds(200))` is now `try await Task.sleep(for: Self.restartRaceSettleWindow)` (named constant); `try? Self.materializeFakeBinary(...)` in `onRun` is now `#expect(throws: Never.self) { ... }`. The `defer { try? FileManager.default.removeItem(...) }` cleanup lines stay: they are not assertions, and the folder can be absent.
  timestamp: 2026-10-18T14:37:36.011592+00:00
- actor: claude-code
  id: 01m57q4rbeext3es5ga64vymgp
  text: |-
    ### implement — changed
    - evidence: 1 file — Tests/FoundationModelsCodeContextTests/LspSupervisorTests.swift; `swift test --filter LspSupervisorTests/shutdownDuringAGatedInstall` RED 1/1 failed (lookup key broken on purpose), then `swift test --filter` on the 3 changed tests GREEN 3/3; full `swift test` 1012 tests in 90 suites passed, 0 failures; 1 build warning from the mlx-swift dependency (task ^kw00hcn). Both review findings are `- [x]`.
    - next: /review
  timestamp: 2026-10-18T14:37:38.542466+00:00
- actor: claude-code
  id: 01m57q65wgswwpq996d3yw6r66
  text: |-
    ### test — green
    - evidence: swift test (root package) — 1012 tests in 90 suites passed, 0 failed, 0 skipped. The only warning is the mlx-swift_Cmlx.bundle warning from a dependency (task ^kw00hcn).
    - next: review
  timestamp: 2026-10-18T14:38:25.168598+00:00
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

## Review Findings (2026-10-18 09:32)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 2 file(s) reviewed, 8 not reviewed.

> 8 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 8 file(s)

- [x] `Tests/FoundationModelsCodeContextTests/LspSupervisorTests.swift:830` `swift/optionals` — The test turns any error from `metrics.expectCounter` into `nil` with `try?`. The later assertion `installRestarts == nil` then passes for every failure, including a wrong metric name or a broken lookup, not only for the absence of an install restart. A test that cannot run must fail, not pass silently. Assert the absence in a way that keeps the error visible. For example, read the counter without `try?` and state the expected absence explicitly, or assert on the thrown error type, so a failed lookup cannot count as a pass.
- [x] `Tests/FoundationModelsCodeContextTests/LspSupervisorTests.swift:830` `test-integrity/no-test-cheating` — The `try?` on `metrics.expectCounter(...)` turns any thrown error into `nil`. The assertion at line 839 then checks `installRestarts == nil`, so it passes whenever the lookup fails for any reason, including a wrong metric name or dimension key. The test cannot tell 'no install restart' apart from 'the counter lookup is broken'. The swallowed error makes the negative assertion pass without proving anything. Do not swallow the error. Assert the absence of the counter in a form that fails on a broken lookup, for example with a positive control that runs the same lookup after a known restart, or by asserting the thrown error is the specific 'not found' case. Then the nil check proves the restart did not happen.

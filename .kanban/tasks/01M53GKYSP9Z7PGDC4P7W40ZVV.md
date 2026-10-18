---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m56wtrbjkywpns5tktgfs8a9
  text: |-
    Research:
    - LSPDaemon.start() sets consecutiveFailures = 0 on each good handshake. recordFailure() adds 1. Thus a crash after init gives attempts 1 for ever, and the backoff stays at 2 s.
    - The daemon sees a crash only at a health check. ServerSpec.healthCheckInterval is 60 s by default. If the daemon measures the uptime at the time of the crash detection, an immediate crash shows an uptime of about one interval. Thus the reset must not use the detection time.
    - Decision: record the time of `.running` (as an offset on the injected clock). healthCheck() resets the counter only when it finds the process alive AND the uptime is at least minimumHealthyUptime. A crash found later does not reset the counter. This does not depend on the health check interval.
    - Default minimumHealthyUptime: 5 minutes, the same as MIN_HEALTHY_UPTIME of the Rust port. Reason: each restart starts a full index again, and 5 minutes is five health check intervals by default, much longer than the 60 s backoff cap.
    - `any Clock<Duration>` cannot name its Instant. A generic helper opens the clock one time in init and gives a closure that returns the elapsed time.
    - Supervisor health loop: when the daemon has no restart budget, the loop wrote the warning at each interval. New: LSPDaemon.hasExhaustedRestarts(); the loop writes a "giving up" warning one time, and writes it again only after the daemon got a budget again (forceRestart).
  timestamp: 2026-10-18T06:57:47.890235+00:00
- actor: claude-code
  id: 01m56xm4ns4c246nzgqaey8exr
  text: |-
    Implementation:
    - LSPDaemon: `start()` does not set `consecutiveFailures` to zero. It records `runningSince` (elapsed time on the injected clock). `healthCheck()` sets the count to zero only when it finds the process alive and the uptime is at least `minimumHealthyUptime`. New init parameter `minimumHealthyUptime` (default `defaultMinimumHealthyUptime` = 300 s, the same as MIN_HEALTHY_UPTIME of the Rust port). New `hasExhaustedRestarts()`; `restartWithBackoff()` uses it. Backoff and the limit of 5 did not change.
    - `any Clock<Duration>` cannot name its Instant: a private generic `stopwatch(on:)` opens the clock one time in init and returns a closure that gives the elapsed time.
    - The named constants of the daemon are in a private file-level enum `LSPDaemonLimits` (a generic actor cannot hold static stored properties). This also removed the old no_magic_numbers findings in LSPDaemon.swift (5, 5 s, 62). The threshold stays private, thus the comment in CodeContextState stays true.
    - LspSupervisor health loop: split into `needsRestart(_:)` and `restart(_:command:hasWarnedGivingUp:)`. When the budget is used, the loop writes "the language server daemon gives up the restarts after too many consecutive failures" one time; the flag clears when the daemon has a budget again (forceRestart).
    - plan.md: the reset rule is updated.

    Tests (TDD): RED showed the crash loop test failing at attempts == 2 (the count went back to 1) and the warning test failing (no "gives up" warning). The budget test passed in RED as expected: it guards that the fix does not remove the reset. GREEN after the change.
    - New files: Tests/.../LSPDaemonCrashLoopTests.swift (extension of LSPDaemonTests) and Tests/.../LspSupervisorGivingUpTests.swift (extension of LspSupervisorTests). They are separate files because LspSupervisorTests.swift went over the swiftlint 1000-line error limit. `serverSpec`, `workspaceRoot` and `stateWaitTimeout` of the two suites are now internal, thus the extensions use them and copy nothing.

    Discovery: swiftlint no_magic_numbers flags `.seconds(5)` in a `static let` of a source file and of a test extension, but not a plain integer `static let`. Name the seconds as an integer constant and pass the name.

    Lint: `swiftlint lint --quiet --only-rule no_magic_numbers` on all 6 changed files gives no findings. Pre-existing swiftlint errors (type_body_length of LSPDaemonTests and LspSupervisorTests) are not new.
  timestamp: 2026-10-18T07:11:39.705064+00:00
- actor: claude-code
  id: 01m56xm8svz9n9x0wgmh10z7be
  text: |-
    ### implement — changed
    - evidence: 7 files — Sources/FoundationModelsCodeContext/LSP/LSPDaemon.swift, Sources/FoundationModelsCodeContext/LSP/LspSupervisor.swift, Tests/FoundationModelsCodeContextTests/LSPDaemonTests.swift, Tests/FoundationModelsCodeContextTests/LspSupervisorTests.swift, Tests/FoundationModelsCodeContextTests/LSPDaemonCrashLoopTests.swift (new), Tests/FoundationModelsCodeContextTests/LspSupervisorGivingUpTests.swift (new), plan.md. `swift test --filter 'LSPDaemonTests|LspSupervisorTests|MetricsTests|CodeContextStateTests'`: 82 passed. Full `swift test`: 937 tests in 84 suites passed, 0 failed. `swiftlint lint --quiet --only-rule no_magic_numbers` on the changed Swift files: 0 findings.
    - next: /review (task stays in doing)
  timestamp: 2026-10-18T07:11:43.931586+00:00
- actor: claude-code
  id: 01m56xvqbme9hq0fr386rbs36t
  text: |-
    ### test — green
    - evidence: swift test — 937 tests in 84 suites passed, 0 failed, 0 skipped; swift build --package-path IntegrationTests --build-tests — Build complete, 0 compiler warnings from this package (only the SwiftPM "missing creator for mutated node" notice for the mlx-swift_Cmlx.bundle dependency)
    - next: commit
  timestamp: 2026-10-18T07:15:48.212219+00:00
- actor: claude-code
  id: 01m56y35epp1xv0xvry89x8z7t
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (9c23997). 3 findings (3 confirmed, 0 refuted): Sources/FoundationModelsCodeContext/LSP/LspSupervisor.swift:377, Sources/FoundationModelsCodeContext/LSP/LspSupervisor.swift:400, Tests/FoundationModelsCodeContextTests/LspSupervisorGivingUpTests.swift:68. The acceptance criteria are both checked.
    - next: Correct the 3 open items in "Review Findings (2026-10-18 02:16)". The task stays in review.
  timestamp: 2026-10-18T07:19:52.022686+00:00
- actor: claude-code
  id: 01m56y3g162dgc1005emqq6sxt
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 7 files
    - test: green — swift test, 937 passed
    - commit: 9c23997
    - review: findings — Sources/FoundationModelsCodeContext/LSP/LspSupervisor.swift:377, Sources/FoundationModelsCodeContext/LSP/LspSupervisor.swift:400, Tests/FoundationModelsCodeContextTests/LspSupervisorGivingUpTests.swift:68
  timestamp: 2026-10-18T07:20:02.854717+00:00
- actor: claude-code
  id: 01m56yja52fkzwkt4tpjcv9s8t
  text: |-
    Review findings (2026-10-18 02:16) fixed:
    - swift/fluent-usage: the helper `needsRestart(_:)` is removed. The health loop now calls `daemon.healthCheck()` itself, then calls the new `isFailed(_:)`, which only reads `daemon.state()`. No other function in LspSupervisor.swift has a query name and a side effect.
    - reuse/reuse (metadata): new `Log.serverMetadata(server:)` in Logging/Log.swift. `Log.serverFailureMetadata` now starts from it. `LSPDaemon.serverMetadata` and the "gives up" warning of LspSupervisor use it. A search of the Sources tree found no other server-only metadata: the other `lspServer` sites (LspSession, ServerInstaller, ProcessLanguageServerConnection) hold more keys.
    - reuse/reuse (test fixture): `LSPDaemonTests.crashLoopDaemon` is not private now and has a `configureConnection` parameter (default: no change). `daemonThatFailsEachRestart` in LspSupervisorGivingUpTests.swift uses it to make the handshakes fail. The giving-up daemon now has the 10 s minimum healthy uptime of the crash loop tests; this has no effect, because the daemon never runs again after the first crash.
    - New tests in ScaffoldTests: `theServerMetadataHoldsOnlyTheServerName` (RED: compile failure, no `Log.serverMetadata`) and `theServerFailureMetadataHoldsTheServerNameAndTheErrorType`.
  timestamp: 2026-10-18T07:28:08.354371+00:00
- actor: claude-code
  id: 01m56yjdc731b3f5jhr02b2sxj
  text: |-
    ### implement — changed
    - evidence: 6 files — Sources/FoundationModelsCodeContext/Logging/Log.swift, Sources/FoundationModelsCodeContext/LSP/LSPDaemon.swift, Sources/FoundationModelsCodeContext/LSP/LspSupervisor.swift, Tests/FoundationModelsCodeContextTests/ScaffoldTests.swift, Tests/FoundationModelsCodeContextTests/LSPDaemonCrashLoopTests.swift, Tests/FoundationModelsCodeContextTests/LspSupervisorGivingUpTests.swift. `swift test --filter 'ScaffoldTests|LSPDaemonTests|LspSupervisorTests|LoggingContentTests|TelemetryContentSafetyTests'`: 57 tests in 6 suites passed. Full `swift test`: 939 tests in 84 suites passed, 0 failed. `swiftlint lint --quiet --only-rule no_magic_numbers` on the 6 files: 0 findings. 3 of 3 review findings checked.
    - next: /review (task stays in doing)
  timestamp: 2026-10-18T07:28:11.655828+00:00
- actor: claude-code
  id: 01m56ysj2d71b9b4sss4ec17bh
  text: |-
    ### test — green
    - evidence: swift test — 939 tests in 84 suites passed, 0 failed, 0 skipped; swift build --package-path IntegrationTests --build-tests — Build complete, exit 0. Only warning is a SwiftPM bundle message about mlx-swift_Cmlx.bundle (dependency, not this package).
    - next: commit
  timestamp: 2026-10-18T07:32:05.837302+00:00
- actor: claude-code
  id: 01m56z0qa1ka6hkgd2j7hmes27
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (c37e921). 0 findings, 0 confirmed, 0 refuted. 7 pairs attempted, 0 failed. All 3 items in the prior Review Findings section are checked, and the code shows each fix: `needsRestart` is gone; `Log.serverMetadata(server:)` is the shared helper for `LSPDaemon.serverMetadata` and the LspSupervisor warning; `daemonThatFailsEachRestart` calls the shared `LSPDaemonTests.crashLoopDaemon`.
    - next: none. The task is in done.
  timestamp: 2026-10-18T07:36:00.577644+00:00
- actor: claude-code
  id: 01m56z12pazw3cjds1h0hbvg38
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 6 files (isFailed, shared Log.serverMetadata, shared crashLoopDaemon fixture)
    - test: green — swift test, 939 passed
    - commit: c37e921
    - review: clean — 0 findings; 3 of 3 prior items checked
  timestamp: 2026-10-18T07:36:12.234561+00:00
position_column: done
position_ordinal: e880
title: 'Limit LSP crash restarts: reset the failure count only after a healthy uptime'
---
## Problem
A server that crashes after `initialize` restarts with no limit.

- A good `start()` sets `consecutiveFailures = 0` (`Sources/FoundationModelsCodeContext/LSP/LSPDaemon.swift:329`).
- A crash after the init calls `recordFailure`, which sets the count to 1 (`:350`, `:528-537`). `restartWithBackoff` waits 2 s and starts again, and the count goes back to 0 (`:366-376`).
- Thus the limit `maxConsecutiveFailures` (5, `:129`) is never hit, and the backoff stays at 2 s. Each restart starts a full index again.
- `healthCheck()` (`:343`) only checks that the process is alive.
- When the daemon stops trying, the health loop writes a "giving up" warning at each interval with no end (`LspSupervisor.swift:355-372`).

## Change
- Record the time when the daemon goes to `.running`. Reset `consecutiveFailures` only after a minimum healthy uptime (for example 60 s). Make this value injectable for tests.
- Keep the exponential backoff and the hard limit.
- Write the "giving up" warning one time only.

## Tests
- A fake server that crashes immediately after `initialize` stops after `maxConsecutiveFailures` restarts, and the backoff becomes longer each time.
- A server that runs longer than the minimum uptime and then crashes gets its full restart budget again.
- The "giving up" warning is written one time.

## Acceptance criteria
- [x] A crash loop after init stops at the limit.
- [x] The tests above pass.

#lsp-fix

## Review Findings (2026-10-18 02:16)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 6 file(s) reviewed, 5 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

> 1 file(s) not reviewed — no validator matched:
> - `plan.md` — no validator matches this file

- [x] `Sources/FoundationModelsCodeContext/LSP/LspSupervisor.swift:377` `swift/fluent-usage` — The name `needsRestart` reads as a pure Boolean query, but the function calls `daemon.healthCheck()`. That call can tear down the connection, clear the session documents, and record a failure. A side-effecting operation must be named as an imperative verb phrase. Rename the function to a verb phrase that states the effect, for example `checkHealthAndRequestRestart(_:)`, or split the function so that the health check runs in the loop and the function only reads the daemon state.
- [x] `Sources/FoundationModelsCodeContext/LSP/LspSupervisor.swift:400` `reuse/reuse` — The new `restart` helper builds the server-only log metadata inline as `[CodeContextTracing.MetadataKey.lspServer: .string(command)]`. That is the same construction as the existing private `serverMetadata` property of `LSPDaemon`, which builds `[CodeContextTracing.MetadataKey.lspServer: .string(spec.command)]`. The inline copy will drift if the metadata key or its shape changes, because the two sites are not linked. The same function already uses the shared `Log.serverFailureMetadata(server:error:)` helper for its sibling warning at line 412. Add a shared helper beside `Log.serverFailureMetadata`, for example `Log.serverMetadata(server: String) -> Logger.Metadata`, and use it from both `LSPDaemon.serverMetadata` and the inline warning at LspSupervisor.swift:400.
- [x] `Tests/FoundationModelsCodeContextTests/LspSupervisorGivingUpTests.swift:68` `reuse/reuse` — The new `daemonThatFailsEachRestart` helper builds an `LSPDaemon<FakeLanguageServerConnection>` with `serverSpec()`, `workspaceRoot`, a `ManualClock`, and a `fakeConnectionFactory`. The new `crashLoopDaemon` helper in the crash loop tests builds the same daemon shape. Only the minimum healthy uptime and the factory's handshake behavior differ. Two parallel builders for the same type will drift apart. Give one shared fixture a parameter for the connection factory, or for the handshake hook, and call it from both places. `crashLoopDaemon` is `private` in its own file, so its visibility must change, for example to `static` without `private` as the other fixtures in `LSPDaemonTests` already are, before `LspSupervisorGivingUpTests.swift` can call it.

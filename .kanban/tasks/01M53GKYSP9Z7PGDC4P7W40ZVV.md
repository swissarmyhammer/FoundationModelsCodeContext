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
position_column: doing
position_ordinal: '80'
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
---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5ad8s2b37ftrhkjy72d6hr7
  text: |-
    Research (implement):
    - Callers of ProcessGroupChild: ProcessLanguageServerConnection (close -> terminateGroup; deinit -> signalGroup(SIGKILL); closeOutOfStepConnection on the reader thread -> signalGroup(SIGKILL); isRunning; waitUntilExit) and ProcessInstallRunner.stop (terminateGroup, then terminationStatus). closeOutOfStepConnection is a third post-reap signal site the card does not name: the reader loop ends at EOF, which can come after the reap.
    - Checked on this Darwin with a scratch program: waitid(P_PID, pid, &info, WEXITED | WNOWAIT) returns at the exit and keeps the zombie (kill(pid, 0) == 0 after it). si_code CLD_EXITED (1) gives si_status = exit code (3 for `exit 3`); CLD_KILLED (2) gives si_status = signal (9, 15). A later waitpid(pid, 0) reaps, and kill(pid, 0) is ESRCH after that. So the status can come from the WNOWAIT observation, and the reap can happen later.
    - Plan: a seam protocol for the three process calls (wait for exit without reap, reap, signal group) so a unit-test fake records the order. The leader state becomes one enum behind the existing CancellableWaiters lock: running(isReapAllowed:), exited(status) (zombie kept, pid reserved), reaped(status). Each group signal is sent under the lock and is skipped once reaped. The reap happens only when allowed: after terminateGroup sent SIGKILL, or at deinit of ProcessGroupChild (no caller can signal after that). isRunning/waitUntilExit now track the exit observation; terminateGroup still returns after the reap.
  timestamp: 2026-10-19T15:42:47.883321+00:00
- actor: claude-code
  id: 01m5adnqfecjmng7nadk583fej
  text: |-
    Implementation landed (TDD):
    - Seam first, with no behavior change: new `ProcessGroupCalls` protocol (waitForExit(of:) via waitid WEXITED|WNOWAIT, reap(_:) via waitpid, send(_:toGroup:) via kill(-pid)) and `SystemProcessGroupCalls`; `ProcessGroupChild.init(pid:calls:)` is internal so a test can give a fake. The old waitpid status decode (WTERMSIG/WEXITSTATUS masks) is gone: si_status of the WNOWAIT siginfo already gives the same value.
    - RED: 6 new unit tests in ProcessGroupChildTests with the RecordingProcessGroupCalls fake. 4 failed on the old ordering: terminateGroup recorded [SIGTERM, reap, SIGKILL]; terminateGroup then signalGroup recorded [SIGTERM, reap, SIGKILL, SIGKILL]; the deinit path recorded [reap, SIGKILL]; an exited child was reaped at once. 2 passed (status reported, a child released before its exit is still reaped): they guard behavior that must stay.
    - GREEN: LeaderState enum (running(isReapAllowed:), exited, reaped) behind the CancellableWaiters lock. signalGroup sends under the lock and sends nothing once reaped. allowReap() runs after SIGKILL in terminateGroup and in deinit of ProcessGroupChild; an exited zombie is reaped there, a running child is reaped by the reaper thread at its exit. isRunning/waitUntilExit now follow the exit, terminationStatus the WNOWAIT status; terminateGroup still returns after the reap.
    - Behavior change one test saw: while a ProcessGroupChild is held, a child that exited by itself stays a zombie, so kill(pid, 0) still finds it. IntegrationTests ScriptedLSPServerHangTests polled `!processExists(pid)` with the child held; it now polls `!child.isRunning` (doc updated). No other test checks a leader pid while its child is held: ConnectionTests, ServerInstallerTests and LanguageServerProcessGroupTests check after close()/run/release, which reap.
    - The closeOutOfStepConnection signal on the reader thread is covered by the same lock rule.
  timestamp: 2026-10-19T15:49:52.238622+00:00
- actor: claude-code
  id: 01m5adp034eg1bfqde6qcqh8ep
  text: |-
    ### implement — changed
    - evidence: 7 files — Sources/FoundationModelsCodeContext/LSP/ProcessGroupCalls.swift (new), Sources/FoundationModelsCodeContext/LSP/ProcessGroupChild.swift, Sources/FoundationModelsCodeContext/LSP/ProcessLanguageServerConnection.swift (docs), Tests/FoundationModelsCodeContextTests/ProcessGroupChildTests.swift (new), Tests/FoundationModelsCodeContextTests/Support/RecordingProcessGroupCalls.swift (new), IntegrationTests/Tests/FoundationModelsCodeContextIntegrationTests/ScriptedLSPServerHangTests.swift. RED: `swift test --filter ProcessGroupChildTests` 4 of 6 failed before the fix; GREEN 6 of 6 passed. `swift test`: 1058 tests in 94 suites passed. `swift test --package-path IntegrationTests`: 22 tests in 16 suites passed. Only warning: the known mlx-swift "missing creator for mutated node" (^3a92r6p).
    - next: /review
  timestamp: 2026-10-19T15:50:01.060267+00:00
- actor: claude-code
  id: 01m5advt1z9y2htk1xe5r1r2cb
  text: |-
    ### test — green
    - evidence: swift build ok; swift test — 1058 passed, 0 failed, 0 skipped; swift test --package-path IntegrationTests — 22 passed, 0 failed, 0 skipped; swift format lint --strict clean. Only warning is the known upstream mlx-swift_Cmlx one (^3a92r6p). Fixed one lint failure (AddLines/Indentation) in IntegrationTests/Tests/FoundationModelsCodeContextIntegrationTests/HardKilledHostTests.swift via swift format (whitespace only), then re-ran lint and integration tests.
    - next: review
  timestamp: 2026-10-19T15:53:11.487200+00:00
- actor: claude-code
  id: 01m5ae08vdyvc5xj57sxgesxhd
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (5aa59c0) — 0 findings, 0 confirmed, 0 refuted; 7 files attempted, 0 failed; 6 .kanban/ files excluded by .reviewignore
    - next: none — task moved to done
  timestamp: 2026-10-19T15:55:37.709340+00:00
- actor: claude-code
  id: 01m5ae0j7970d4kw3cx24wn7e0
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 6 files (leader kept as a zombie via waitid WNOWAIT until every group signal is sent; ProcessGroupCalls seam; 6 new tests, 4 RED before the fix)
    - test: green — swift test 1058 passed; IntegrationTests 22 passed; swift format lint --strict clean
    - commit: 5aa59c0
    - review: clean — 0 findings; task moved to done
  timestamp: 2026-10-19T15:55:47.305770+00:00
position_column: done
position_ordinal: ff8180
title: ProcessGroupChild signals -pid after the reap of the leader; a reused pid can be another group
---
## What
`ProcessGroupChild.terminateGroup(grace:)` sends `SIGTERM` to `-pid`, waits for the reap, and then always sends `SIGKILL` to `-pid`. `LSPDaemon.shutdown()` waits for the exit (the reaper reaps the server) before `releaseConnection()` calls `close()`, so after a clean exit both signals go to `-pid` after the reap. When no process of the group is left, the kernel may give that pid to a new process, and when that process leads its own group (each language server does, via `POSIX_SPAWN_SETPGROUP`; SwiftPM also starts test binaries in new groups), `kill(-pid, ...)` hits an unrelated group. `deinit` (`signalGroup(SIGKILL)`) has the same risk.

## Evidence (^t71wvkm, 2026-10-19)
During 6 concurrent `swift test --package-path IntegrationTests` runs with 40 CPU hogs, one run exited 143 (SIGTERM) about 1.3 s into its tests, log cut mid-line; pids were near 99999 and wrapping. No other cause found. Not proven; the mechanism above is the likely one.

## Direction
Keep the leader pid reserved until the group is signalled: observe the exit with `waitid(P_PID, pid, &info, WEXITED | WNOWAIT)` (the zombie keeps its pid, so the pgid cannot be reused), send the group signals, then reap. Or skip the group signal when the group has no member (`killpg` probe with signal 0 is racy, so prefer the zombie approach). Write a test that fails without the fix (e.g. a fake that observes the order "reap" vs "signal").
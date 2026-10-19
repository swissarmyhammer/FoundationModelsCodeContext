---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5a64vkjwnxar0aqhm5c60n0
  text: |-
    Research:
    - `ProcessInstallRunner.run` (LSP/ServerInstaller.swift) spawns via Foundation `Process`; timeout and cancel call `kill(pid, SIGKILL)` on the pid only. On cancel the terminationHandler then awaits `drainTask.value` unbounded, so a grandchild holding the output pipe blocks a cancelled run until the grandchild exits (timeout path resumes before the drain, so it returns but leaks the grandchild).
    - `ProcessGroupChild` (LSP/ProcessGroupChild.swift) has spawn/signalGroup/terminateGroup/waitUntilExit, but does not keep the wait status. The runner needs the exit code (existing test asserts `exitCode == SIGKILL` on cancel, mirroring `Process.terminationStatus`), so ProcessGroupChild must record the status from `waitpid`.
    - `terminateGroup(grace:)` inside a cancelled task skips the grace and the reap (sleep throws, wait returns at cancel), so the cancel path must run it in an unstructured task to still reap the child.
    - `clock.waitForCompletion(atMost:)` + cancellable `waitUntilExit()` gives the exit-vs-timeout-vs-cancel race without a ResumeOnce.
    - Host can already lower the timeout: `LspAutoInstall(timeout:)` is public and threaded through `CodeContext`/`CodeContextManager`; docs/language-servers.md shows a 120 s example. Will add a note for short-lived hosts and the process-group stop.
    - Existing ProcessInstallRunnerTests live in the unit target (Tests/.../ServerInstallerTests.swift) using `sh`/`sleep`; the new grandchild tests follow them there.
  timestamp: 2026-10-19T13:38:19.378017+00:00
- actor: claude-code
  id: 01m5a6t4vvej9b3mpvqp0j01rw
  text: |-
    Implementation landed (TDD).

    RED (old Foundation `Process` runner, `swift test --filter ProcessInstallRunnerTests`):
    - timeoutKillsADescendantOfTheInstaller: failed, descendant alive 30 s after the timeout.
    - cancellationKillsADescendantOfTheInstaller: failed, descendant alive after the cancel. First version passed for the wrong reason: the script's foreground `sleep` held the pipe, so the old cancel path blocked on the drain for the full 60 s and the descendant ended on its own. Fixed by `exec sleep` in the script; then it failed correctly.
    - cancellationReturnsWhileADescendantOutsideTheGroupHoldsTheOutputPipe: failed, run waited 60 s after cancel (old terminationHandler awaited the drain unbounded).
    - cancellationKillsAndReapsTheChildBeforeItsSleepEnds: expectation changed SIGKILL -> SIGTERM (graceful group stop); failed with 9 vs 15.
    - timeoutReturnsWhileADescendantOutsideTheGroupHoldsTheOutputPipe and exitCodeIsTheExitStatusOfTheInstaller passed on the old code: the old timeout path never waited for the drain, and Process already decoded exit codes. They stay as guards: the new code does wait for the output (bounded), and the exit code now comes from our own waitpid decode.

    GREEN design:
    - ProcessGroupChild keeps the reaper task's value: `terminationStatus` (async, Process.terminationStatus semantics, decoded from the waitpid status with named WTERMSIG/WEXITSTATUS masks). ProcessUtilities.runOnDedicatedThread is now generic over its result.
    - ProcessInstallRunner: spawn via ProcessGroupChild (stdin = null device, one pipe for stdout+stderr); race `clock.waitForCompletion(atMost: timeout) { child.waitUntilExit() }`; timed out = !exited && !Task.isCancelled; every end runs `stop`: an awaited unstructured Task (so a cancel does not skip the grace or the reap) that does terminateGroup(grace: 2 s), waits at most outputGrace (500 ms) for the drain, then returns terminationStatus. The drain thread keeps the Pipe alive with withExtendedLifetime, so a run that returns before EOF never closes an fd under a blocked read.
    - Bound: timeout + terminationGrace + outputGrace + reap. A descendant that leaves the group (setsid/setpgid) cannot be signalled. It can only delay the run by outputGrace.
    - Removed awaitCompletion/scheduleTimeout/installTerminationHandler. ResumeOnce keeps its PendingRequestTable caller; stale doc references in ResumeOnce and ProcessLanguageServerConnection were updated.
    - Docs: docs/language-servers.md says that a short-lived host can lower `LspAutoInstall(timeout:)` (already public and passed through CodeContext/CodeContextManager), and describes the group stop. The plan.md auto-install bullet is updated.
  timestamp: 2026-10-19T13:49:56.987734+00:00
- actor: claude-code
  id: 01m5a6t8ecetb39y8fppqaspaj
  text: |-
    ### implement — changed
    - evidence: 8 files — Sources/FoundationModelsCodeContext/LSP/ServerInstaller.swift, LSP/ProcessGroupChild.swift, LSP/ProcessUtilities.swift, LSP/ResumeOnce.swift (doc), LSP/ProcessLanguageServerConnection.swift (doc), Tests/FoundationModelsCodeContextTests/ServerInstallerTests.swift (+5 tests, 1 expectation SIGKILL->SIGTERM), docs/language-servers.md, plan.md. `swift test --filter ProcessInstallRunnerTests`: 9/9 passed. `swift test`: exit 0, 0 failures. `swift test --package-path IntegrationTests`: 22 tests in 16 suites passed. Only warning: the known upstream mlx-swift Cmlx `missing creator` build warning (^kw00hcn), present before this change.
    - next: /review
  timestamp: 2026-10-19T13:50:00.652053+00:00
- actor: claude-code
  id: 01m5a6y9133zh7xnjp3xaak3pr
  text: |-
    ### test — green
    - evidence: swift test — 1027 tests in 90 suites passed, 0 failures, 0 skipped; swift test --package-path IntegrationTests — 22 tests in 16 suites passed, 0 failures. Only warning: pre-existing mlx-swift_Cmlx "missing creator for mutated node" (both packages, not chased). LanguageServerGrandchildTests did not flake (^t71wvkm). ProcessInstallRunnerTests passed in 3.4s and LspSupervisorTests in 1.6s under full-suite load.
    - next: review/commit
  timestamp: 2026-10-19T13:52:12.323080+00:00
- actor: claude-code
  id: 01m5a72f3h1x9e0xxxz0xenfw5
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (9592bb1); 0 findings, 0 confirmed, 0 refuted; 7 validator runs attempted, 0 failed. The validators did not cover docs/language-servers.md or plan.md, because no validator matches them. The .reviewignore rules excluded the .kanban/ files.
    - next: none — moved to done
  timestamp: 2026-10-19T13:54:29.617644+00:00
- actor: claude-code
  id: 01m5a72qyse4jsjraqy7mn748n
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 8 files (ServerInstaller, ProcessGroupChild, ProcessUtilities, 2 doc-only, ServerInstallerTests +5, docs/language-servers.md, plan.md)
    - test: green — swift test 1027 passed, IntegrationTests 22 passed, 0 skipped
    - commit: 9592bb1
    - review: clean — 0 findings; task in done
  timestamp: 2026-10-19T13:54:38.681728+00:00
position_column: done
position_ordinal: fc80
title: Installer timeout and cancel must kill the full process group of the installer, not only its pid
---
## What
Peer item 1(c): "a hung installer must have a time limit and cannot delay the work".

Already true:
- `LspAutoInstall.timeout` defaults to 300 s (`ServerInstaller.swift` ~line 131).
- The install runs on a background task (`LspSupervisor.startInstallTask`, ~line 336), so `start()` does not wait for it; `shutdown()` cancels and awaits it.

The gap found:
- `ProcessInstallRunner.run` (`ServerInstaller.swift` ~line 190) starts the installer with Foundation `Process` via `/usr/bin/env npm ...`, in the host's process group. On timeout or cancel it calls `kill(pid, SIGKILL)` (~lines 281 and 312) on the pid only. npm starts child processes (node workers, `sh -c` lifecycle scripts, git). Those survive the kill, can keep the output pipe open (the drain thread then blocks until they exit), and can hold the npm cache lock for the next session.
- The language servers already use `ProcessGroupChild` (`LSP/ProcessGroupChild.swift`, `POSIX_SPAWN_SETPGROUP` + `terminateGroup(grace:)`). The installer should use the same.

Also consider: 300 s is long for a host like the SWE-bench agent. Check that the host can set a lower `LspAutoInstall.timeout`, and document it.

## TDD
1. Failing test in `ProcessInstallRunnerTests`: the "installer" is a shell script that starts a grandchild (`sleep 1000 & echo $! > <tmp>/gc.pid; sleep 1000`). Run with a short timeout (e.g. 1 s). After the runner throws `CodeContextError.timeout`, assert the grandchild pid is gone within a short wait (`kill(pid, 0)` fails with ESRCH).
2. Same for task cancellation.
3. Test that `run` returns promptly after the timeout even when the grandchild holds the output pipe open.
4. Implement with `ProcessGroupChild.spawn` + `terminateGroup(grace:)`; keep stdin = null device.

## Acceptance
- No installer descendant outlives a timeout or a cancel.
- The runner never blocks past timeout + grace. #lsp #bug
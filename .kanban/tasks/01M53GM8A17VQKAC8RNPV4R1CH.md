---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m57fqn7gdrtmgf9476d77y1b
  text: 'Research: Foundation Process has no public API to set a process group, and a setpgid from the parent after run() races the exec and the first fork of the child. Thus the language server starts with posix_spawn and POSIX_SPAWN_SETPGROUP in a new type ProcessGroupChild (LSP/ProcessGroupChild.swift). It also sets POSIX_SPAWN_CLOEXEC_DEFAULT (only stdin/stdout/stderr go to the child, the same as Process), resets the signal mask and the signal dispositions, and takes all three streams (pipe or null device), the same rule as ProcessUtilities.makeChildProcess. makeChildProcess stays for the installer and GitShell, which do not need a group. A dedicated thread reaps the leader with waitpid; isRunning reads that state, thus a zombie is not "alive". The daemon tests: the old clean-shutdown test asserted terminateCount == 0; the card now requires the clean shutdown to close the connection, thus that assertion moved into a new test that expects 1. RED seen: 4 LSPDaemonTests and 2 integration tests (LanguageServerProcessGroupTests) fail on the old code.'
  timestamp: 2026-10-18T12:28:09.328214+00:00
- actor: claude-code
  id: 01m57gcz98x3n2sthmfdvz6fpb
  text: |-
    ### implement — changed
    - evidence: new Sources/FoundationModelsCodeContext/LSP/ProcessGroupChild.swift (posix_spawn + POSIX_SPAWN_SETPGROUP, waitpid reaper thread, cancel-aware exit wait, terminateGroup = SIGTERM to the group, 500 ms grace, SIGKILL to the group, wait for the reap); ProcessLanguageServerConnection.swift (spawns through ProcessGroupChild, close() is async and kills and reaps the group, deinit sends SIGKILL to the group when close() did not run, out-of-step path signals the group, waitUntilExit reads the reap and a cancel stops it); LSPDaemon.swift (start() returns when a handle runs or a start is in progress; releaseConnection() is the one drop path for a failed health check and each shutdown, clean or after the grace); CodeContext.swift deinit comment; README.md stop()/shutdown() note; ProcessUtilities.swift and ServerInstaller.swift doc text; tests: LSPDaemonTests (+4: health check terminates, clean shutdown terminates once, second start spawns nothing, start during a start spawns nothing; old terminateCount == 0 assertion moved, because the card requires a clean shutdown to close the connection), ConnectionTests doc comments, IntegrationTests LanguageServerProcessGroupTests (+2) and IntegrationSupport.processExists.
    - RED seen for all 6 new tests on the old code. GREEN: swift test --filter LSPDaemonTests|ConnectionTests|LspSupervisorTests|ChildStandardInputTests → 81 passed; swift test --package-path IntegrationTests --filter (6 LSP suites) → 9 passed; full root swift test → 995 tests in 88 suites passed. swiftlint no_magic_numbers: no finding in changed lines (two findings in ServerInstaller.swift are on old lines 131 and 211).
    - Discovery: the old waitUntilExit awaited readerTask.value, which a cancel cannot stop, thus the shutdown grace race of LSPDaemon could not end early for a real server that hangs. The new wait stops at a cancel.
    - Note: makeChildProcess stays for the installer and GitShell; ProcessGroupChild.spawn is the one helper for the language server and keeps the same three-stream rule.
    - next: /review
  timestamp: 2026-10-18T12:39:47.752065+00:00
- actor: claude-code
  id: 01m57gh4jcd6ex92x00tnxax5m
  text: |-
    ### test — green
    - evidence: swift test (root) 995 tests in 88 suites passed, 0 failures, 0 skipped; swift build --build-tests after touching all package sources: 0 warnings from this package (only the mlx-swift dependency bundle warning "missing creator for mutated node"); swift build --package-path IntegrationTests --build-tests complete; swift test --package-path IntegrationTests --filter LanguageServerProcessGroupTests 2 tests in 1 suite passed
    - next: commit
  timestamp: 2026-10-18T12:42:04.236533+00:00
- actor: claude-code
  id: 01m57h20fgb2cz81xzm63rhmzm
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (fc2d112). 3 findings, 3 confirmed, 0 refuted. Sources/FoundationModelsCodeContext/LSP/ProcessGroupChild.swift:132, Sources/FoundationModelsCodeContext/LSP/ProcessGroupChild.swift:288, Sources/FoundationModelsCodeContext/LSP/ProcessGroupChild.swift:363
    - acceptance criteria: both items are checked on the task. The change adds LanguageServerProcessGroupTests, a process group start with posix_spawn, a group kill on close and on deinit, and one release path in LSPDaemon.
    - next: implement the three findings. The task stays in review.
  timestamp: 2026-10-18T12:51:17.104688+00:00
- actor: claude-code
  id: 01m57h2cx230fffn1qj95jakd0
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 12 files
    - test: green — swift test, 995 passed; integration LanguageServerProcessGroupTests 2 passed
    - commit: fc2d112
    - review: findings — Sources/FoundationModelsCodeContext/LSP/ProcessGroupChild.swift:132, :288, :363
  timestamp: 2026-10-18T12:51:29.826104+00:00
- actor: claude-code
  id: 01m57hjgrhmzn440xv11xxfhwy
  text: |-
    Review fix pass. Two shared helpers replace the copies.
    - New `Clock.waitForCompletion(atMost:_:)` (LSP/Clock+WaitForCompletion.swift): races an operation against a sleep on the given clock, cancels the loser, and returns `true` when the operation finished first. ProcessGroupChild.terminateGroup(grace:) uses it with ContinuousClock(). LSPDaemon.shutdown() also uses it with the injected clock. That was a one-line, safe change, thus no separate task for the LSPDaemon copy.
    - New `CancellableWaiters<State>` (LSP/CancellableWaiters.swift): a Mutex-guarded state plus cancellable waits for a condition on that state. ExitSignal is removed. ProcessGroupChild keeps a `CancellableWaiters<Bool>` for the reap.
    - Discovery: the old ExitSignal and UpdateMailbox keep a cancelled token in a set when the cancel comes after the resume, and that token never leaves the set. CancellableWaiters keeps one entry per token (pending, suspended, cancelled) and removes it at the resume, thus a late cancel finds nothing and adds nothing.
    - update(_:) resumes the suspended waits only when the condition is true after the change. A pending wait (not registered yet) reads the condition at its registration.
    - UpdateMailbox is not changed (the finding says so). New task ^6ava5jt (tag lsp-fix) moves it onto CancellableWaiters.
    - The other race in LSPDaemon (performHandshake, a throwing timeout race) has a different shape and is outside these findings.
  timestamp: 2026-10-18T13:00:18.065542+00:00
- actor: claude-code
  id: 01m57hjn7cs2mxt71nn6s74ysv
  text: |-
    ### implement — changed
    - evidence: new Sources/FoundationModelsCodeContext/LSP/CancellableWaiters.swift, new Sources/FoundationModelsCodeContext/LSP/Clock+WaitForCompletion.swift, changed Sources/FoundationModelsCodeContext/LSP/ProcessGroupChild.swift (ExitSignal removed), changed Sources/FoundationModelsCodeContext/LSP/LSPDaemon.swift (shutdown uses the shared race); new Tests/FoundationModelsCodeContextTests/CancellableWaitersTests.swift (6 tests) and Tests/FoundationModelsCodeContextTests/ClockWaitForCompletionTests.swift (3 tests). RED seen (types did not exist). New task ^6ava5jt. swift test --filter of the 2 new suites: 9 passed; affected root suites (LSPDaemon, ConnectionTests, LspSupervisor*, ChildStandardInput, new suites): 92 tests in 7 suites passed; swift test --package-path IntegrationTests --filter LanguageServerProcessGroupTests: 2 passed; full root swift test: 1004 tests in 90 suites passed. swift build --build-tests: 0 warnings from this package. swiftlint no_magic_numbers on the 6 changed files: no finding.
    - findings: 3 of 3 checked.
    - next: /review
  timestamp: 2026-10-18T13:00:22.636171+00:00
- actor: claude-code
  id: 01m57hp5vmy3ck747t2eknrs5y
  text: |-
    ### test — green
    - evidence: swift test — 1004 tests in 90 suites passed, 0 failed, 0 skipped; IntegrationTests build-tests complete; LanguageServerProcessGroupTests 2 tests passed. Only warning: "missing creator for mutated node" for mlx-swift_Cmlx.bundle (dependency, not this package).
    - next: commit
  timestamp: 2026-10-18T13:02:17.972192+00:00
- actor: claude-code
  id: 01m57j0898p1hpb7cqy8rzk96x
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (2625a0b). 1 finding (confirmed 1, refuted 2). Tests/FoundationModelsCodeContextTests/ClockWaitForCompletionTests.swift:21 (reuse/reuse). The 3 items of the 07:42 section are checked and fixed: Clock.waitForCompletion(atMost:_:) is the one timed wait for ProcessGroupChild and LSPDaemon.shutdown; CancellableWaiters replaces ExitSignal; task ^6ava5jt moves UpdateMailbox onto CancellableWaiters.
    - next: Fix the open item in the 08:02 section. Then run the review again.
  timestamp: 2026-10-18T13:07:48.136231+00:00
- actor: claude-code
  id: 01m57j0j945cb44j9jwm7jzn9g
  text: |-
    ### finish iteration 2 — findings
    - implement: changed — 6 files (Clock.waitForCompletion, CancellableWaiters; new task ^6ava5jt)
    - test: green — swift test, 1004 passed; integration LanguageServerProcessGroupTests 2 passed
    - commit: 2625a0b
    - review: findings — Tests/FoundationModelsCodeContextTests/ClockWaitForCompletionTests.swift:21
  timestamp: 2026-10-18T13:07:58.372672+00:00
- actor: claude-code
  id: 01m57ja8k6cqtpezg1dbcbwyyn
  text: |-
    Review fix pass for the 08:02 finding (ClockWaitForCompletionTests.swift:21 reuse/reuse).
    - New `CancellableWaiters.flag(isSet:)` in Tests/FoundationModelsCodeContextTests/Support/CancellableWaiters+Flag.swift. CancellableWaitersTests and ClockWaitForCompletionTests both use it. The private `makeFlagWaiters` and `makeNeverSatisfiedWaiters` are removed.
    - Same cause, second copy: `processExists(_:)` in IntegrationSupport.swift said in its doc that it was a copy of the private `ConnectionTests.pidExists(_:)`. A test target cannot import the test target of a different package, thus the one shared body is now public `processExists(_:)` in Tests/ScriptedLSPServerSupport/ProcessExistence.swift (the test-support library that both packages already use). ConnectionTests and LanguageServerProcessGroupTests call it. Both copies are removed. ConnectionTests no longer needs `import Darwin`. The manifest comments of Package.swift and IntegrationTests/Package.swift tell about the new function.
    - Not changed: ProcessGroupChild keeps its one-line `CancellableWaiters(false) { isReaped in isReaped }`. Production code must not call a test-support helper.
    - Discovery: the `files` tool `replace_all` edit changed only one match per call in this session. Check the result of each such edit.
  timestamp: 2026-10-18T13:13:16.134889+00:00
- actor: claude-code
  id: 01m57jac4p0e797x3ahyc9y90e
  text: |-
    ### implement — changed
    - evidence: new Tests/FoundationModelsCodeContextTests/Support/CancellableWaiters+Flag.swift, new Tests/ScriptedLSPServerSupport/ProcessExistence.swift; changed CancellableWaitersTests.swift, ClockWaitForCompletionTests.swift, ConnectionTests.swift, IntegrationTests/.../IntegrationSupport.swift, IntegrationTests/.../LanguageServerProcessGroupTests.swift, Package.swift, IntegrationTests/Package.swift. swift test --filter 'CancellableWaitersTests|ClockWaitForCompletionTests': 9 tests in 2 suites passed; swift test --package-path IntegrationTests --filter LanguageServerProcessGroupTests: 2 passed; full root swift test: 1004 tests in 90 suites passed, 0 failed. Only warning: mlx-swift_Cmlx.bundle "missing creator for mutated node" (dependency). swiftlint on the changed test files: no no_magic_numbers finding (two old findings in IntegrationSupport.swift on lines this pass did not change).
    - findings: 08:02 section 1 of 1 checked.
    - next: /review
  timestamp: 2026-10-18T13:13:19.766138+00:00
- actor: claude-code
  id: 01m57jfq9r7ka0hxqs726xdckt
  text: |-
    ### test — green
    - evidence: swift test (root) 1004 tests in 90 suites passed, 0 failed, 0 skipped; swift build --package-path IntegrationTests --build-tests complete; swift test --package-path IntegrationTests --filter "LanguageServerProcessGroupTests|LSPCancelRequestTests" 3 tests in 2 suites passed. Only warning: SwiftPM "missing creator for mutated node" for the mlx-swift_Cmlx bundle (dependency, not this package).
    - next: commit
  timestamp: 2026-10-18T13:16:15.032179+00:00
position_column: doing
position_ordinal: '80'
title: Start each language server in its own process group and kill the group on close and on deinit
---
## Problem
- The server starts with Foundation `Process` and has no process group (`Sources/FoundationModelsCodeContext/LSP/ProcessLanguageServerConnection.swift:195-210`). `close()` sends SIGKILL to the single pid only (`:280-282`). Child processes of the server (for example tsserver, or the rust-analyzer proc-macro server) continue to run.
- `ProcessLanguageServerConnection` has no `deinit` that kills its child.
- `CodeContext.deinit` (`CodeContext.swift:259-265`) only cancels tasks. Its comment says that it stops each LSP daemon, but it does not.
- `LSPDaemon.start()` (`LSP/LSPDaemon.swift:287`) has no guard for a daemon that runs. At `:322` it writes over `handle` and never closes the old process. Two `start()` calls at the same time can each start a process (reentrancy at the awaits at `:306` and `:314`).
- `healthCheck` (`:348`) and the clean-exit branch of `shutdown` (`:432-437`) do not call `close()`. The pipes and file descriptors stay open, and the notification stream does not finish.
- `close()` (`ProcessLanguageServerConnection.swift:280-281`) sends SIGKILL and does not wait for the process to exit.
- There is no exit hook. The host must call `CodeContext.stop()` or `CodeContextManager.shutdown()`.

## Change
- Start the server with `posix_spawn` and `POSIX_SPAWN_SETPGROUP` (or an equal method), and keep the pgid.
- In `close()`, send the signal to the group: `kill(-pgid, SIGTERM)`, then SIGKILL after a short time.
- Add a `deinit` to the connection that kills the group if the process is alive.
- Make one kill-and-wait function. Use it on each path that drops a connection: shutdown timeout, clean shutdown, failed health check, restart and a second `start()`.
- `start()` must close the old handle first, or return when a start is in progress or the daemon runs.
- In tests that start a server script (`ConnectionTests.swift:43-45`, `withConnection` at `:81` and `:84`), kill the process and wait for its exit. `swift <script>` can start a child process. Kill the process group, so that no child keeps stdout open.
- Correct the comment on `CodeContext.deinit`.
- In the README, tell hosts to call `shutdown()` at exit.

## Tests
- A fake server script that starts a child process: after `close()`, the child process is not alive.
- When the connection is released with no `close()`, the server process is not alive.

## Acceptance criteria
- [x] No server process or child process stays after close or deinit.
- [x] The tests above pass.

#lsp-fix

## Review Findings (2026-10-18 07:42)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 10 file(s) reviewed, 5 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

> 1 file(s) not reviewed — no validator matched:
> - `README.md` — no validator matches this file

- [x] `Sources/FoundationModelsCodeContext/LSP/ProcessGroupChild.swift:132` `duplication/duplication` — The race in waitUntilExit(atMost:) repeats the task-group race in LSPDaemon.shutdown(): one task waits for the exit, one task sleeps, the first to finish wins, and the group cancels the other. Two copies of this race can drift apart, for example if one gets a cancel fix and the other does not. Extract one shared helper that races an exit wait against a clock sleep and takes the clock as a parameter. Call it from waitUntilExit(atMost:) in the changed code. Report the LSPDaemon.shutdown() copy as a separate task, because that code is outside this change.
- [x] `Sources/FoundationModelsCodeContext/LSP/ProcessGroupChild.swift:288` `reuse/reuse` — `ExitSignal` rebuilds a cancellable async waiter with a lock, a token per wait, a continuation map, and a set of early-cancelled tokens. `UpdateMailbox` already has the same shape: a waiter token, `registerWaiter`, and `cancelWaiter`. Writing a second copy means two places to fix the cancel-before-register race. Check whether `UpdateMailbox`'s waiter machinery, or a small shared one-shot waiter type, can serve `ExitSignal`. If the contracts differ too much (an update stream versus a fire-once signal), extract the shared token-and-cancel registration into one helper that both types call, and note in the `ExitSignal` doc comment why the reuse stops there.
- [x] `Sources/FoundationModelsCodeContext/LSP/ProcessGroupChild.swift:363` `duplication/duplication` — ExitSignal.cancelWait(token:) and its register/wait pattern copy the cancellable-waiter logic of UpdateMailbox. Each has a token counter, a dictionary of continuations, a set of cancelled tokens recorded before registration, and a cancel handler that resumes the waiter. Two copies of this subtle logic can drift apart. Extract one generic cancellable-waiter helper, parameterized by the state that each caller guards, and use it from ExitSignal in the changed code. Do not edit UpdateMailbox in this change. Report the UpdateMailbox adoption as a separate task.

## Review Findings (2026-10-18 08:02)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 6 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Tests/FoundationModelsCodeContextTests/ClockWaitForCompletionTests.swift:21` `reuse/reuse` — makeNeverSatisfiedWaiters builds the same object as makeFlagWaiters(isSet: false) in CancellableWaitersTests. The helper is a copy in a sibling test struct, so the two can diverge. Use the one-line constructor CancellableWaiters(false) { isSet in isSet } directly, or move the helper to Support/ so both suites share it. makeFlagWaiters is private, so it cannot be called from this file as it stands.

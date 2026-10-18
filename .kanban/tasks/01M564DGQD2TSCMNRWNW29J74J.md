---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m566sa6kbbx51jnc0j9nw417
  text: |-
    Research:
    - Three Process() sites in Sources/: ProcessInstallRunner.run (LSP/ServerInstaller.swift), GitShell.runBlocking (Diagnostics/DiagnosticsScope.swift), ProcessLanguageServerConnection.init (LSP/ProcessLanguageServerConnection.swift). No other spawn (no posix_spawn, no system) in Sources/ or Tests/. Test helpers (GitFixture) go through GitShell.
    - Plan: one helper ProcessUtilities.makeChildProcess(executableURL:arguments:standardInput:standardOutput:standardError:). standardInput is an enum (nullDevice or pipe), thus each site must state stdin. All three sites use it.
    - Test seam for stdin: the test swaps fd 0 of the test process to a pipe with known bytes (dup/dup2), runs the runner, restores fd 0, and reads the bytes back. The two tests that swap fd 0 are in one serialized suite. git test uses `git hash-object --stdin` (it reads stdin to EOF).
    - Failed-install test: CodeContext has a serverSpecs seam. The test adds one synthetic spec (command not on PATH, installer tool "true") beside the real Rust spec with a fake binary, and a FakeInstallRunner that exits 1. The existing E2E test for this case is gated on npm present and intelephense absent, thus it can skip.
    - PATH diagnostics: BinaryLookup gets a pathDiagnostics function (entry count and non-absolute entries) that uses the same split as isOnPath. LSPDaemon adds its metadata to the "not on the PATH" warning. Two new MetadataKey constants.
  timestamp: 2026-10-18T00:32:31.955595+00:00
- actor: claude-code
  id: 01m5686dpbdzvn7cm6ww1j24zv
  text: |-
    Implementation landed (not committed).
    - New helper `ProcessUtilities.makeChildProcess(executableURL:arguments:standardInput:standardOutput:standardError:)` with enum `ProcessUtilities.StandardInput { nullDevice, pipe(Pipe) }`. All three parameters for the streams are required, thus no stream defaults to the stream of the host. It is now the only `Process()` in Sources/.
    - `ProcessInstallRunner.run` and `GitShell.runBlocking` use `.nullDevice`. `ProcessLanguageServerConnection.init` uses `.pipe(stdinPipe)`. Each site has a comment that tells why (the host can use its stdin for ACP or MCP stdio).
    - PATH diagnostics: `BinaryLookup.pathDiagnostics(pathVariable:)` gives `PathDiagnostics(entryCount:nonAbsoluteEntries:)` with the same split as `isOnPath` (shared private `searchDirectories(of:)`; lookup rules unchanged). The "not on the PATH" warning of `LSPDaemon.start()` now has metadata `process.path.entry_count` and `process.path.non_absolute_entries` (new `CodeContextTracing.MetadataKey.pathEntryCount` / `.pathNonAbsoluteEntries`).
    - Tests: new `ChildStandardInputTests` (serialized suite): a pipe with known bytes is fd 0 of the test process (dup/dup2) while the child runs. Installer case: `sh -c "wc -c"` with the write end open; RED before the fix = runner timeout after 5 s (the child read the parent stdin); GREEN = output "0", every byte remains. git case: `git hash-object --stdin`; RED = bytes gone and wrong object id; GREEN = empty-blob id, every byte remains. `BinaryLookupTests` +3 tests for pathDiagnostics, `LSPDaemonTests.theNotOnThePathWarningCarriesTheDiagnosticsOfThePath` (RED was a compile error: missing keys). `CodeContextStartTests.aFailedInstallLeavesItsServerNotFoundAndTheOtherServerAndTheIndexRunning` (ungated; synthetic spec with installer tool `true` + fake runner exit 1 beside the Rust server with a fake binary); it passed at once because the behavior already exists; it is the regression guard that the card asks for. The older E2E test for this case is gated on npm/intelephense.
    - Discovery: in one full run, `ProcessInstallRunnerTests.cancellationTerminatesTheChildPromptly` failed with elapsed 6.17 s (limit 5 s) while the whole test process stalled about 40 s; alone it passes in 0.11 s. Filed as ^vqpcb1t.
    - Discovery: `git hash-object --stdin` in a temporary directory takes about 5 s on this machine each time (also alone). Not a fault of this change.
  timestamp: 2026-10-18T00:57:10.091981+00:00
- actor: claude-code
  id: 01m5686hjgh8bwd25age333d76
  text: |-
    ### implement — changed
    - evidence: 11 files — Sources/FoundationModelsCodeContext/LSP/ProcessUtilities.swift, LSP/ServerInstaller.swift, LSP/ProcessLanguageServerConnection.swift, LSP/LSPDaemon.swift, Diagnostics/DiagnosticsScope.swift, Tracing/CodeContextTracing.swift; Tests/FoundationModelsCodeContextTests/ChildStandardInputTests.swift (new), ServerInstallerTests.swift, LSPDaemonTests.swift, CodeContextStartTests.swift, CodeContextTracingTests.swift. `swift test` full: 911 tests, 910 pass, 1 fail (cancellationTerminatesTheChildPromptly, 6.17 s > 5 s under load; passes alone in 0.11 s; filed ^vqpcb1t). Targeted runs green: ChildStandardInputTests 2/2, BinaryLookupTests|LSPDaemonTests|CodeContextTracingTests 40/40, the failed-install test 1/1, ProcessInstallRunnerTests|ChildStandardInputTests 6/6. `swift build --package-path IntegrationTests --build-tests` exit 0. No compiler warnings.
    - next: /test then /review
  timestamp: 2026-10-18T00:57:14.064674+00:00
- actor: claude-code
  id: 01m56bz6dz5jv2906vqhgmz9f2
  text: |-
    ### test — green
    - evidence: swift test full suite: 914 tests in 81 suites, 0 failed, 0 skipped, 3 runs in a row passed (runs 125, 126, 129). swift build --package-path IntegrationTests --build-tests: Build complete. Only warning: "missing creator for mutated node ... mlx-swift_Cmlx.bundle" from the third-party mlx-swift build, not from this package.
    - cause found: the old ChildStandardInputTests swapped file descriptor 0 of the whole test process (dup2) while other tests ran, and the pipe write end leaked into other child spawns. The first full run failed shutdownDuringInFlightInstallCancelsCleanlyAndPromptly (elapsed < 5 s). Fix: ChildStandardInputTests now checks the standard input of the child itself (null device test, wc -c test, pipe test, ProcessInstallRunner test, GitShell test). No test changes fd 0 and the suite is no longer serialized. No time limit was raised.
    - remaining environment fact: a run with ChildStandardInputTests skipped still stalled the whole process about 43 s and failed two LspSupervisorTests timing tests. A sample of the process shows threads blocked in lstat, rmdir and realpath in the kernel. The user TMPDIR directory ($TMPDIR, /var/folders/l7/.../T/) holds about 1 million entries (directory size 81 MB, link count 65535), and ls -f on it does not finish in 15 minutes. Other swift test and cargo runs also ran on the machine. This stall is outside the package code. A person should clean $TMPDIR.
    - next: commit
  timestamp: 2026-10-18T02:03:07.583913+00:00
- actor: claude-code
  id: 01m56c88cvfbs2qg0h5k7vqfg2
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (6b183de): 1 finding (1 confirmed, 1 refuted) — Tests/FoundationModelsCodeContextTests/CodeContextStartTests.swift:502 reuse/reuse. Acceptance criteria are correct: the only Process() in Sources/ is in ProcessUtilities.makeChildProcess, which sets stdin, stdout and stderr. The installer and the git runner use the null device as stdin. The LSP connection uses its own stdin pipe. CodeContextStartTests has a test for a failed install.
    - next: implement the open finding (a shared poll wait in CodeContextStartTests), then review again.
  timestamp: 2026-10-18T02:08:04.507040+00:00
- actor: claude-code
  id: 01m56c8hvp5brc36n1n3x9wb33
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 11 files
    - test: green — swift test x3, 914 passed
    - commit: 6b183de
    - review: findings — Tests/FoundationModelsCodeContextTests/CodeContextStartTests.swift:502
  timestamp: 2026-10-18T02:08:14.198540+00:00
- actor: claude-code
  id: 01m56cen29zxze88j11zpsxhph
  text: |-
    Review finding fixed. CodeContextStartTests has a new private `waitUntil(_ isDone: () async throws -> Bool)`. It checks `isDone` and sleeps for `statusPollInterval` between two checks. `waitForIndexStatus` and `waitForTheFailedInstall` now call `waitUntil`. The file had only these two poll loops (a search for `Task.sleep` gives only the line in `waitUntil` now). The doc of `statusPollInterval` now names `waitUntil(_:)`.

    ### implement — changed
    - evidence: 1 file — Tests/FoundationModelsCodeContextTests/CodeContextStartTests.swift. `swift test --filter CodeContextStartTests`: 15 tests in 1 suite passed, 0 failed. Only warning: "missing creator for mutated node ... mlx-swift_Cmlx.bundle" from the third-party mlx-swift build.
    - next: /review
  timestamp: 2026-10-18T02:11:34.089799+00:00
- actor: claude-code
  id: 01m56cwcjws1bf25cg9h5zz845
  text: |-
    ### test — green
    - evidence: swift test full run: 914 tests in 81 suites, 4 timing-only failures (LspSupervisorTests autoInstallSuccess, autoInstallFailure, shutdownDuringInFlightInstall; ProcessInstallRunnerTests cancellationTerminatesTheChildPromptly) while the machine was starved (each ran about 30 s). The 4 tests alone: 4 passed in 2.7 s, no code change. The environment caused it. swift build --package-path IntegrationTests --build-tests: Build complete. Zero warnings from this package. Zero skipped tests.
    - next: commit
  timestamp: 2026-10-18T02:19:04.156427+00:00
- actor: claude-code
  id: 01m56hxkyscvtqfymv7dsgta4e
  text: |-
    Root cause of the slow timing tests (about 55 s each, only in the full suite) is found and removed. No time limit was changed.

    Baseline: at e850544 (before ^w29j74j) in a separate worktree, the full suite had the same stall. Run 1 passed, but the 6 auto-install and cancel tests each took about 42 s and 564 tests took more than 30 s. Run 2 failed shutdownDuringInFlightInstallCancelsCleanlyAndPromptly (elapsed < 5 s, 58 s). Thus the ^w29j74j change did not cause the stall and did not make it worse.

    Cause: each test workspace was in $TMPDIR (/var/folders/.../T/). On this machine $TMPDIR holds about one million entries and other processes write in it all the time. A change of $TMPDIR is slow and locks it, and each path lookup through $TMPDIR waits. `sample` of the test process during the stall showed 20 or more threads blocked in mkdirat and rmdir (withTemporaryWorkspace), getattrlist (realpath in WorkspaceRoot.realURL) and lstat (SQLite open of the store). These calls block the threads of the cooperative pool, thus the whole process stops for about a minute, and each test that measures wall-clock time fails. Measurements: 200 mkdir+rmdir in $TMPDIR took 20.6 s (worst call 5.9 s); in a subdirectory of $TMPDIR 0.04 s. But 1000 realpath+lstat on a path below $TMPDIR still took 62 s (worst 6.8 s), and on a path below /tmp 0.03 s. Thus a subdirectory of $TMPDIR is not sufficient (a first try with $TMPDIR/FoundationModelsCodeContextTests/ still stalled the suite for 150 s); the items must be out of $TMPDIR.

    Fix (tests only, no change in Sources/):
    - TestSupport.swift: new `TemporaryItem` with `root` = /tmp/FoundationModelsCodeContextTests-<uid> and `makeURL(prefix:)`. withTemporaryWorkspace and withSymlinkedWorkspace use it. The root is not in the package directory, because a workspace in the git work tree of the package breaks the tests that expect no git repository (for example aGitFailureGivesTheCorrectiveOutput).
    - The direct $TMPDIR sites now use TemporaryItem.makeURL: LspSupervisorTests (5), LSPDaemonTests (2), ServerInstallerTests (2), MetricsTests (1).
    - IntegrationSupport.swift: withTemporaryWorkspace uses /tmp/FoundationModelsCodeContextIntegrationTests-<uid>.
    - New TemporaryItemTests (4 tests). RED: the root was below $TMPDIR.
    - RootDiscoveryTests (4 lines) and CodeContextManagerTests (1 line) now build the expected directory URL with isDirectory: true. These tests passed before only because of a quirk of the URL that FileManager.temporaryDirectory gives: standardizedFileURL of a URL derived from it reads the file system and adds the trailing slash of a directory. A plain /tmp URL does not do that.

    Result: full swift test 918 tests passed two times (33.4 s and 36.0 s; before the fix 105 s to 150 s). Slowest test 5.4 s. The 6 tests of the card take 1.2 s to 1.5 s.

    Discovery: LayeredOpsTests, TreeSitterWorkerTests and LSPIndexWorkerTests write "../secret.swift" into the parent of the workspace. Before this fix that file went directly into $TMPDIR; now it stays in the shared root. It is never removed. Filed as a new task.
  timestamp: 2026-10-18T03:47:07.353016+00:00
- actor: claude-code
  id: 01m56hy882j8pqae65rkzpyytd
  text: |-
    ### implement — changed
    - evidence: root cause = test temporary items in a $TMPDIR with about 1 million entries; mkdir/rmdir/realpath/lstat through $TMPDIR blocked all cooperative-pool threads (seen with `sample`), so the process stalled for about a minute. The same stall is in the baseline e850544, so ^w29j74j did not cause it. Files: Tests/FoundationModelsCodeContextTests/TestSupport.swift (TemporaryItem, root /tmp/FoundationModelsCodeContextTests-<uid>), TemporaryItemTests.swift (new, 4 tests), LspSupervisorTests.swift, LSPDaemonTests.swift, ServerInstallerTests.swift, MetricsTests.swift, RootDiscoveryTests.swift, CodeContextManagerTests.swift, IntegrationTests/.../IntegrationSupport.swift. `swift test` full: 918 tests in 82 suites passed two times (33.4 s, 36.0 s), 0 failed, 0 skipped. `swift build --package-path IntegrationTests --build-tests`: Build complete. Only warning: the third-party "missing creator for mutated node ... mlx-swift_Cmlx.bundle". No time limit changed.
    - next: /review
  timestamp: 2026-10-18T03:47:28.130595+00:00
- actor: claude-code
  id: 01m56j8eyjfd1tzf71vdtc8bme
  text: |-
    ### test — green
    - evidence: swift test — 918 tests in 82 suites passed, 0 failed, 0 skipped, 0 warnings from this package (only a SwiftPM warning about the mlx-swift_Cmlx bundle); swift build --package-path IntegrationTests --build-tests — build complete, same single third-party warning
    - next: commit
  timestamp: 2026-10-18T03:53:02.674602+00:00
position_column: doing
position_ordinal: '80'
title: Child processes must not read the stdin of the host process
---
## Problem
SWE-bench run with code-context on 2026-10-17: 16 instances, `bench/code-context.config.yaml` with `autoInstall: true`. All 16 failed: the agent process stopped and made no patch. Each failure occurred in the same second as this log line:
`error FoundationModelsCodeContext.lsp: lsp.installer=npm lsp.server=typescript-language-server process.exit_code=1 the installer of the language server failed`

The transcripts had 0 lines and the model made 0 generations. During one instance, `lsof` showed that fd 0 of the `npm install` child and fd 0 of `acp-agent` were on the same pipe. The host speaks ACP on its stdin, so npm read from the ACP channel. The agent waited at 0 % CPU until npm stopped.

Cause (confirmed in the code): Foundation `Process` gives the child the stdin of the parent when `standardInput` is not set.
- `ProcessInstallRunner.run` (`Sources/FoundationModelsCodeContext/LSP/ServerInstaller.swift:155-161`) sets only `standardOutput` and `standardError`.
- `DiagnosticsScope.runBlocking` (`Sources/FoundationModelsCodeContext/Diagnostics/DiagnosticsScope.swift:257-265`), which runs `git`, has the same fault.
- `ProcessLanguageServerConnection` (`LSP/ProcessLanguageServerConnection.swift:202`) gives the server its own stdin pipe. This is correct.

The fault is not only for a failed install. npm holds the stdin while it runs, so a good install can also take ACP bytes and stop the session.

## Change
- In `ProcessInstallRunner.run`, set `process.standardInput = FileHandle.nullDevice` before `process.run()`.
- Do the same in `DiagnosticsScope.runBlocking`.
- Look at all other `Process()` sites in `Sources/` (also new ones from other open tasks) and make sure that each one sets `standardInput` to a pipe that it owns or to the null device. Add a comment that tells why: the host can use its stdin for a protocol (ACP, MCP stdio).
- If possible, make one helper that makes a `Process` with stdin set to the null device, and use it in all places that do not need a stdin pipe.
- Stdout and stderr have the same risk: a child that gets the stdout of the host can write bytes into the protocol output (ACP or MCP). Today, all three `Process()` sites set `standardOutput` and `standardError` to pipes. The helper must set all three streams, and each site must set all three streams. Do not let a stream default to the stream of the parent.
- Make sure that a failed install does not stop the session: `CodeContext` continues with no server for that language, and other servers and the index continue. Add a test for this if no test exists.

## Diagnostics for the open problem with pylsp
In the same run, the log had `the binary of the language server is not on the PATH` for `pylsp`, but `~/.local/bin/pylsp` exists and `~/.local/bin` is on the PATH that the harness gives the agent. `BinaryLookup.isOnPath` (`ServerInstaller.swift:29-39`) splits `PATH` and does not expand `~` or `$HOME`. One possible cause: the PATH entry is the literal text `~/.local/bin`. The cause is not confirmed.
- In the "not on the PATH" warning, add the number of PATH entries and each entry that is not an absolute path, so that the next run shows the cause.
- Do not change the lookup rules in this task unless a test shows the cause.

## Not in this task
- npm `UNABLE_TO_GET_ISSUER_CERT_LOCALLY`: an environment problem (certificate authority); check it outside the harness.

## Tests
- An installer script that reads its stdin until end of file must end at once (it gets the null device). The test process's own stdin must not lose bytes. For example: run the runner in a child test process whose stdin is a pipe that holds known bytes, then read those bytes after the install and make sure they are all there.
- The same test for the `git` runner in `DiagnosticsScope`, if a seam makes it possible.
- A failed install (exit code 1) gives a `.notFound` or a failed state for that server, and `CodeContext.start()` still completes.

## Acceptance criteria
- [x] No child process in `Sources/` gets the stdin of the host.
- [x] A failed install does not stop the session.
- [x] The tests above pass.

#lsp-fix

## Review Findings (2026-10-17 21:03)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 11 file(s) reviewed, 8 not reviewed.

> 8 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 8 file(s)

- [x] `Tests/FoundationModelsCodeContextTests/CodeContextStartTests.swift:502` `reuse/reuse` — waitForTheFailedInstall repeats the poll-until-condition loop of waitForIndexStatus (line 64-71): sleep for statusPollInterval, check a condition on the context, and throw on cancellation. The loop was written again instead of parameterizing the existing wait. Add a generic predicate-based wait in CodeContextStartTests (for example waitUntil(_ predicate: () async throws -> Bool)) that polls with statusPollInterval. Rebuild waitForIndexStatus and waitForTheFailedInstall on top of it. The private waitUntil in LspSupervisorTests.swift:50 has a deadline and is in another file, so it does not fit as is.

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
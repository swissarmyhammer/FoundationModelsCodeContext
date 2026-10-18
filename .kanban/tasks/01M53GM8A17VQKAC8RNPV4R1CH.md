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
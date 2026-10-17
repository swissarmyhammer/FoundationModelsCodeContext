---
assignees:
- claude-code
position_column: todo
position_ordinal: '8480'
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
- [ ] No server process or child process stays after close or deinit.
- [ ] The tests above pass.

#lsp-fix
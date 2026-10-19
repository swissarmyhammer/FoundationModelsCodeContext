---
assignees:
- claude-code
position_column: todo
position_ordinal: '8280'
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
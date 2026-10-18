---
assignees:
- claude-code
position_column: todo
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
- [ ] No child process in `Sources/` gets the stdin of the host.
- [ ] A failed install does not stop the session.
- [ ] The tests above pass.

#lsp-fix
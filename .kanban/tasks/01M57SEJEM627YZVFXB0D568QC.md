---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: An orphan scripted-lsp-server process of the negative Content-Length test stays alive after a test run
---
## Problem
During ^kw00hcn, `pgrep` showed one `swift-frontend -frontend -interpret .../Tests/FoundationModelsCodeContextTests/Support/scripted-lsp-server.swift` process with PPID 1. Its age was 9 h 44 min. Its script argument was `[{"action":"read"},{"text":"Content-Length: -5\r\n\r\n","action":"writeRaw"},{"action":"hang"}]`. This is the script of `ConnectionTests.aNegativeContentLengthFailsThePendingRequestAndStopsTheServer`.

The test expects `isRunning()` to become `false`. But the `swift-frontend` child of `/usr/bin/env swift` stayed alive after the test run, with no parent.

The cause is not known. Possible causes: the test run was stopped before the cleanup; or the stop of the connection kills the `swift` driver process and not the `swift-frontend` child.

## Change
- Find if a full `swift test` run can leave this process alive. Count the `scripted-lsp-server.swift` processes before and after one run.
- If the run leaves the process, make the stop of the connection kill the full process tree or process group of the server.

## Acceptance criteria
- [ ] After one full `swift test` run, no `scripted-lsp-server.swift` process stays alive, or the task records that the process came from a stopped run. #bug
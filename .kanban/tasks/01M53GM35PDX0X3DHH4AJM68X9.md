---
assignees:
- claude-code
position_column: todo
position_ordinal: '8380'
title: LspSupervisor.shutdown must wait for or cancel a start that is in progress
---
## Problem
`LspSupervisor.shutdown()` (`Sources/FoundationModelsCodeContext/LSP/LspSupervisor.swift:396-418`) does not wait for `inFlightStart` (`:167-176`). Both are reentrant actor calls. Thus a spawn round that runs can register live daemons and health loops after `shutdown()` returns. The same race occurs for `CodeContext.stop()` against `start()`, and for the operations `stop lsp` and `start lsp` (`CodeContext.swift:515-520`). The result is a language server that runs with no owner.

- `CodeContext.stop()` sets `isStarted = false` (`CodeContext.swift:397`) before its awaits. A `start()` that runs during these awaits can put new tasks in `lspIndexTasks`. Then `removeAll()` at `:411` drops them and does not cancel them. This is possible from the code; a test must show if it occurs.

## Change
- In `CodeContext.stop()`, cancel and remove the tasks that existed when `stop()` started. Do not remove tasks that a later `start()` added. Or block `start()` until `stop()` completes.
- Add a "stopping" state to the supervisor. `shutdown()` sets it, then cancels `inFlightStart` and waits for it.
- `spawnAndRegister` checks this state before it registers a daemon. If the state is "stopping", it shuts down the new daemon.
- A later `start()` clears the state.

## Tests
- Call `start()`, then call `shutdown()` before the spawn completes (use a fake connection that waits). After `shutdown()` returns, no daemon is running and no health loop is active.
- `stop lsp` then `start lsp` immediately still gives one running daemon for each server.

## Acceptance criteria
- [ ] No daemon runs after `shutdown()` returns.
- [ ] The tests above pass.

#lsp-fix
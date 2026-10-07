---
assignees:
- claude-code
position_column: done
position_ordinal: d980
title: 'Watcher: a burst of file events must not lose dirty marks'
---
## Problem

Two SWE-bench runs of the ACP agent (2026-10-05, 2026-10-06) logged "the watcher could not mark a changed file dirty" (error.type=FoundationModelsCodeContext.CodeContextError) 24,812 and 11,789 times. Peer tracking task: FoundationModelsACPAgent ^9qw2mac.

Each failure drops the change. Then code_context can give old results for a file that the agent edited. The log keeps only the error type, thus the cause is not in the log.

## Cause (found)

`Watcher.restartDebounceTimer()` cancels `debounceTask`. The same task runs `flushPendingEvents()` after the sleep. When a new event comes while a flush runs (the actor is reentrant at each `await`), the event cancels the flush task. GRDB 7 `DatabasePool.write` calls `Task.checkCancellation()`, thus each remaining `store.markDirty` / `store.deleteFile` of the batch throws. `Store.withDbAccess` wraps the `CancellationError` in `CodeContextError.storage`. The batch was already removed from `pendingEvents`, thus all these changes are lost. A burst (checkout, venv build) gives this many times.

## Fix

1. Run each flush in its own task, which a new event does not cancel. Run the flushes one after the other.
2. When a write fails, put the change back in the pending batch for the next flush (a limit of attempts). A change that fails all attempts stays for the next reconcile.
3. Log a safe detail of the error in the two warnings: the `CodeContextError` case and the SQLite extended result code (no description, no file content). `CodeContextError.storage` gets an optional SQLite result code.

## Acceptance criteria

- [ ] The two warnings hold the error case and the SQLite result code.
- [ ] A test with a burst of many changes, with new events during the flush, gives no lost dirty mark and no warning.
- [ ] A write failure puts the change back for the next flush.
- [ ] The build and all tests pass with no warnings.

## Tests

- `WatcherTests`: burst of 2000 files, and new events during the flush.
- `WatcherTests`: a failed write logs the case and the SQLite code, and a later flush retries the change. #bug
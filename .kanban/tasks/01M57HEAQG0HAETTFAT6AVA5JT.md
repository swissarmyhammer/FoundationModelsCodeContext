---
assignees:
- claude-code
position_column: todo
position_ordinal: '9080'
title: Move the waiter logic of UpdateMailbox onto CancellableWaiters
---
## Problem
- `UpdateMailbox` (`Sources/FoundationModelsCodeContext/Diagnostics/UpdateMailbox.swift`) has its own cancellable waiter: an `NSLock`, a token counter (`nextWaiterToken`, `allocateWaiterToken()`), a continuation map (`waiters`), a set of tokens that were cancelled before they registered (`cancelledTokensAwaitingRegistration`), `registerWaiter(token:continuation:)` and `cancelWaiter(token:)`.
- `CancellableWaiters<State>` (`Sources/FoundationModelsCodeContext/LSP/CancellableWaiters.swift`) has the same logic in one generic type. `ProcessGroupChild` uses it. Two copies of this logic can drift apart, for example when one copy gets a fix for the cancel-before-register race and the other copy does not.
- The copy in `UpdateMailbox` also keeps a token in `cancelledTokensAwaitingRegistration` when a cancel comes after the wait resumed. That token never leaves the set. `CancellableWaiters` does not keep such a token.
- This came from the review of ^pv4r1ch (finding `ProcessGroupChild.swift:363 duplication/duplication`). That finding said: do not edit `UpdateMailbox` in that change, and report the adoption as a separate task.

## Change
- Keep the state of `UpdateMailbox` (`queued`, `isClosed`) in a `CancellableWaiters<State>` whose condition is "`queued` is not empty, or `isClosed`".
- `record(_:)` and `markClosed()` call `update(_:)`. `next()` calls `wait()`, and then drains `queued` with one `update(_:)` (or a new drain method on `CancellableWaiters` if a read and a change in one lock step is necessary).
- Remove the token counter, the continuation map, the cancelled-token set, `registerWaiter(token:continuation:)` and `cancelWaiter(token:)` from `UpdateMailbox`.
- Update `UpdateMailboxTests`: the tests that call `registerWaiter(token:continuation:)` directly must test the same race through `CancellableWaiters` or through `next()`.
- Remove the sentence about `UpdateMailbox` from the doc comment of `CancellableWaiters`.

## Tests
- The `UpdateMailboxTests` and `DiagnosticsTests` suites pass.
- A record that comes before the wait registers still ends the wait (the race that `recordBeforeRegisterStillDeliversTheUpdateOnceRegistered` guards).

## Acceptance criteria
- [ ] `UpdateMailbox` has no token, continuation map or cancelled-token logic of its own.
- [ ] The tests above pass. #lsp-fix
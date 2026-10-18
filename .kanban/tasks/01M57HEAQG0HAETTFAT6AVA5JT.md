---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m57rcyzt3t6k1455wg3scn87
  text: |-
    Research:
    - `CancellableWaiters.update(_:)` returns `Void`. Callers: `ProcessGroupChild.startReaper` and the tests (`CancellableWaitersTests`, `CancellableWaiters+Flag`). All callers give a closure that returns `Void`.
    - `next()` must read `queued` and clear it in one lock step. If not, a `record(_:)` between the read and the clear is lost. Thus a read-and-change step is necessary.
    - Plan: make `update(_:)` generic. It gives the value of the change: `update<Value>(_ change: (inout State) -> Value) -> Value`. The existing callers stay the same (`Value == Void`). This keeps one method, not a second copy of the resume logic.
    - After the change, `next()` has no fast path. It always goes through `wait()`, and the registration in `CancellableWaiters` reads the condition under the lock. Thus "record before the wait registers" is the same as "record before `next()`", and a test through `next()` covers that race.
    - The doc comment of `Settle` says that `UpdateMailbox` copies the bookkeeping of `ManualClock`. That sentence becomes false; update it.
  timestamp: 2026-10-18T14:59:36.058164+00:00
- actor: claude-code
  id: 01m57rzhn1t2n3wrxa0t1rzgmc
  text: |-
    Implementation:
    - `CancellableWaiters.update(_:)` is now generic: `update<Value>(_ change: (inout State) -> Value) -> Value`. It gives the value of the change, thus a read and a change occur in one lock step. I did not add a second method, thus the resume logic has one copy. New test: `CancellableWaitersTests.updateGivesTheValueThatItsChangeReturns` (RED was a compile failure, then GREEN).
    - `UpdateMailbox` keeps a private `State` (`queued`, `isClosed`) in a `CancellableWaiters`. `record(_:)` and `markClosed()` call `update(_:)`. `next()` calls `wait()`, then takes `queued` with one `update(_:)`. The `NSLock`, the token counter, the continuation map, the cancelled-token set, `registerWaiter(token:continuation:)` and `cancelWaiter(token:)` are removed. The class is now plain `Sendable` (no `@unchecked`), and it does not import Foundation.
    - `UpdateMailboxTests` now test through `next()`: record or close while `next()` waits, record or close before the wait registers, the queue empties after `next()`, queued updates come before the close, and a cancelled `next()` gives `.updates([])`.
    - Doc comments: removed the `UpdateMailbox` sentence from `CancellableWaiters`. Updated the `Settle` doc comment, which said that `UpdateMailbox` copies the bookkeeping of `ManualClock`.
    - I did not change `ManualClock` (test support). It has the same token pattern with deadlines, but the card does not name it.
  timestamp: 2026-10-18T15:09:44.993001+00:00
- actor: claude-code
  id: 01m57rzmk6qhm8k6ad6dtt73e9
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsCodeContext/Diagnostics/UpdateMailbox.swift, Sources/FoundationModelsCodeContext/LSP/CancellableWaiters.swift, Sources/FoundationModelsCodeContext/Diagnostics/Settle.swift (doc comment), Tests/FoundationModelsCodeContextTests/UpdateMailboxTests.swift, Tests/FoundationModelsCodeContextTests/CancellableWaitersTests.swift. `swift test --filter "UpdateMailboxTests|CancellableWaitersTests|DiagnosticsTests|ProcessGroupChild|ClockWaitForCompletionTests"`: 38 tests in 4 suites passed. Full `swift test`: 1015 tests in 90 suites passed, no warnings in Sources or Tests.
    - next: review
  timestamp: 2026-10-18T15:09:48.006299+00:00
- actor: claude-code
  id: 01m57s17x73z36kd32n7z9et2k
  text: |-
    ### test - green
    - evidence: swift test (root package) - 1015 tests in 90 suites passed, 0 failed, 0 skipped. Build output has one warning: the SwiftPM warning "missing creator for mutated node ... mlx-swift_Cmlx.bundle". It comes from a dependency and has its own task ^kw00hcn. No warning comes from this repo.
    - next: none. The IntegrationTests package was not run.
  timestamp: 2026-10-18T15:10:40.551758+00:00
position_column: doing
position_ordinal: '80'
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
- [x] `UpdateMailbox` has no token, continuation map or cancelled-token logic of its own.
- [x] The tests above pass. #lsp-fix
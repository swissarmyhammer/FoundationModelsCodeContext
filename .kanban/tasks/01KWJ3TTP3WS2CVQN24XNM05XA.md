---
comments:
- actor: wballard
  id: 01kwkyvhr4x9k94g5rdcewv2dg
  text: |-
    Implemented Sources/CodeContextKit/Index/Watcher.swift (new file, distinct from Walker.swift): FileChangeKind enum, RawFileEvent, FileEventSubscription/FileEventSource protocols, the Watcher actor (reset-on-each-event debounce, per-path pending batch keyed by relative path so a burst on one path coalesces to one dirty-mark, one nudgeWorkers() call per flush), and FSEventsFileEventSource (real Core Services FSEvents backend, recursive watch, kFSEventStreamCreateFlagFileEvents for per-file granularity, disk-existence check as ground truth for created/modified/removed classification since ItemRenamed is ambiguous, detached-queue teardown to avoid blocking on FSEvents' ~seconds-long stream invalidation).

    Added Store.deleteFile(filePath:) (parameterized DELETE, cascades via existing FKs) — the delete-time counterpart to markDirty, reused by Watcher instead of duplicating raw SQL.

    Debounce semantics design decision: reset-on-each-event quiet-window (standard debounce), documented in the Watcher doc comment — the Rust reference's async-watcher dependency (crates/swissarmyhammer-code-context/src/watcher.rs and swissarmyhammer-tools/src/mcp/tools/code_context/watcher.rs in the sibling monorepo) batches internally without exposing its own coalescing algorithm, so there was no exact behavior to port; this is a deliberate, spelled-out choice.

    Tests (TDD, watched RED before implementing): Tests/CodeContextKitTests/WatcherTests.swift (10 tests) + Tests/CodeContextKitTests/Support/FakeFileEventSource.swift. FakeFileEventSource.emit(_:) is async and awaits the handler directly (handler type is `@Sendable (RawFileEvent) async -> Void`), which eliminates the classic fake-event-source race against ManualClock — no Task-based fire-and-forget dispatch needed for the fake path. Added a test-only (internal, not public) Watcher.waitForQuiescence() synchronization hook so ManualClock-driven tests can await the debounce Task's completion after clock.advance(by:), matching the existing waitForWaiter()/advance(by:) pattern from ConnectionTests.

    All acceptance criteria covered: burst-of-5-events-on-one-file -> exactly one dirty mark + nudgeCount==1; delete event removes indexed_files row + cascades to ts_chunks; gitignored paths and .code-context/ paths never enter the pending batch (verified via a test that asserts no debounce timer was ever started, i.e. filtering happens synchronously before any clock interaction).

    Ran mcp__sah__review twice; fixed all applicable findings (inlined two single-call-site helpers back into applyChange, inlined containsHiddenComponent, added missing @unchecked Sendable invariant docs on FSEventsFileEventSource/FSEventsSubscription/FakeFileEventSource/FakeFileEventHandlerBox). Declined findings to rename pre-existing Store.drainTsDirty/drainLspDirty (acronym casing) — those functions predate this task, are used across ~6 other files, and renaming them is an unrelated refactor outside this task's scope.

    Verification: swift build clean (zero warnings beyond a pre-existing unrelated mlx-swift_Cmlx.bundle warning). Full `swift test`: 278/278 pass. `swift test --filter WatcherTests` stress-tested 10 consecutive runs (all green, ~0.96-1.26s each, including the real FSEvents integration test which reliably detects a real file write in under 1s using a 200ms debounce). No flakes observed.

    Left in `doing` per /implement workflow — ready for /review.
  timestamp: 2026-07-03T12:22:02.244295+00:00
- actor: wballard
  id: 01kwkzndhetshvx3gmn8f1k9k4
  text: |-
    Adversarial double-check (via really-done's advisory gate) found a genuine bug in the first implementation: `applyChange`'s guard was `kind != .removed, FileManager.fileExists(...)` — an AND that deletes if EITHER the kind was `.removed` OR the file was missing, which contradicted its own doc comment ("disk existence is ground truth") and could incorrectly delete a live, readable file's indexed_files row (cascading away all its chunks/symbols/edges) whenever a coalesced batch's *last* recorded event happened to be `.removed` even though the file existed at flush time.

    Root cause: I'd added "disk existence at flush time" as extra defensive robustness beyond the task's literal spec, then only half-wired it in, producing a contradiction between two different sources of truth.

    Fix: reverted to pure kind-driven dispatch, matching the task's literal acceptance criteria ("created/modified → mark dirty, deleted → DELETE") and the Rust reference's FanoutWatcher.notify (which maps FileEvent directly to an action, no disk check). `.removed` now always deletes (including a no-op DELETE for an untracked path); `.created`/`.modified` reads the file to compute its content hash — if that read fails (file raced away again before the debounced flush ran), the change is skipped and logged rather than guessed at, leaving the file dirty for a future pass. Updated the Watcher/classifyFSEvent doc comments to match.

    Also fixed a low-severity leak the double-check found: `FSEventsFileEventSource.start` retains `FSEventsHandlerBox` via `Unmanaged.passRetained` before calling `FSEventStreamCreate`; if stream creation fails, the release callback (wired into the stream) never runs. Fixed by keeping the `Unmanaged` reference (`retainedBox`) and calling `.release()` explicitly in the failure branch — implemented without a force-unwrap (kept the non-optional `Unmanaged<FSEventsHandlerBox>` handle directly rather than round-tripping through `context.info!`).

    Added two regression tests pinning the corrected last-kind-wins semantics: `lastRecordedRemovedKindInABurstDeletesEvenWhenFileStillExistsOnDisk` and `lastRecordedModifiedKindInABurstMarksDirtyEvenAfterAnEarlierRemovedEvent` — both drive a two-event burst (.modified then .removed, and vice versa) against a file that stays on disk throughout, asserting the outcome tracks the last recorded kind, not disk state.

    Re-verified after fixes: swift build clean (zero warnings), full swift test 280/280 pass, swift test --filter WatcherTests stress-tested 3+ additional consecutive runs (all green, ~0.95-1s each including the real FSEvents integration test). Ran mcp__sah__review again after the fix — one more finding (missing @unchecked Sendable invariant doc on FSEventsHandlerBox), fixed.

    Still left in `doing` — ready for /review.
  timestamp: 2026-07-03T12:36:09.902055+00:00
depends_on:
- 01KWJ3QTH53M16194BCTX6MKVP
- 01KWJ3S2AJFZPWWXRTKSQC3TW7
position_column: doing
position_ordinal: '80'
title: 'FSEvents watcher: debounced change pipeline'
---
## What
Create `Sources/CodeContextKit/Index/Watcher.swift` — replaces Rust's notify/async-watcher with FSEvents (recursive on rootDirectory), ~1s debounce window, filtered to extensions in `Languages.all` and excluding gitignored paths and `.code-context/`. Coalesced events map to created/modified → mark dirty (all layers), deleted → DELETE row (cascades), then nudge the indexing workers. Debounce clock injectable; the FSEvents source wrapped behind a small `FileEventSource` protocol so tests can drive synthetic event streams without the real FS API.

## Acceptance Criteria
- [ ] A burst of N events on one file within the debounce window produces exactly one dirty-mark and one worker nudge
- [ ] Delete events remove the `indexed_files` row and cascaded children
- [ ] Events under gitignored paths and `.code-context/` are ignored

## Tests
- [ ] `Tests/CodeContextKitTests/WatcherTests.swift` driving a fake `FileEventSource` + manual clock: debounce coalescing, dirty/delete flows, filtering; one real-FSEvents integration test (temp dir, write a file, await dirty flag with generous timeout)
- [ ] Run `swift test --filter WatcherTests` → all pass

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
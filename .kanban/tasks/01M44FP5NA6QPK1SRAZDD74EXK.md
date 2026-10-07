---
comments:
- actor: claude-code
  id: 01m4b8vxp0ch3dqzhknfhzrzfw
  text: |-
    Research done.
    - `Watcher.start()` (actor method) calls `eventSource.start(rootDirectory:handler:)` directly. The `FileEventSource` protocol method is synchronous, so `FSEventsFileEventSource.start` runs `FSEventStreamStart` on the cooperative thread of the actor.
    - Plan: `Watcher.start()` calls `eventSource.start` on a private serial dispatch queue (one queue for each watcher) and awaits a checked continuation. Thus each source (real or injected) starts off the cooperative pool. The `FileEventSource` protocol does not change.
    - `Watcher.start()` now has a suspension point. Thus the actor can re-enter. The subscription state becomes an enum (idle, starting, running), so that a second `start()` during a start is a no-op, and a `stop()` during a start stops the late subscription.
    - Public seam: the internal initializers of `CodeContext` and `CodeContextManager` already take `eventSource`, but the public initializers do not. Add `eventSource: (any FileEventSource)? = FSEventsFileEventSource()` to both public initializers. `nil` turns the watcher off (the same pattern as `embedder: nil`).
    - No ARCHITECTURE.md in this repo.
  timestamp: 2026-10-07T13:29:24.928616+00:00
- actor: claude-code
  id: 01m4bbfxw5jb1jbgjjvx43eyyn
  text: |-
    Implementation landed (not committed, by the instruction of the caller).
    - `Watcher.start()` is now `async`. It calls `FileEventSource.start` on a private serial queue (label `FoundationModelsCodeContext.watcher.start`, `Watcher.eventSourceStartQueueLabel`) and waits with a checked continuation. The `FileEventSource` protocol does not change.
    - The subscription state is an enum (`idle`, `starting(call:)`, `running`). A second `start()` during a start is a no-op. A `stop()` during a start makes the late `start()` stop the subscription that the source returns.
    - Public seam: `CodeContext(rootDirectory:embedder:autoInstall:eventSource:)` and `CodeContextManager(embedder:autoInstall:eventSource:)`. `eventSource` defaults to `FSEventsFileEventSource()`. `nil` turns the watcher off. Internal `CodeContext.isWatching` shows if a watcher exists.
    - Tests: `WatcherTests` (3 new: start queue label, stop during start, start during start), `FileEventSourcePublicAPITests` (2 new, plain import), `CodeContextStartTests` (2 new: watcher off with nil, on with a source). Test double: `Tests/.../Support/RecordingFileEventSource.swift`.
    - Each new test was seen to fail first. The RED of the start queue test showed the label `com.apple.root.default-qos.cooperative`, which proves the defect.
    - Dead end: a first version of the "start during start" test awaited the second `start()` in line. With the broken guard, that call waits for ever behind the gated first call on the serial queue, and `.timeLimit` did not end the run (the shell timed out after 30 min). The test now runs the second call in a task, waits 100 ms, and opens the gate two times. Thus a regression fails fast with `startRecords.count == 2`.
    - plan.md "File watching" now tells about the off-pool start and the seam.
    - Subtask 4 (push to main and tell the FoundationModelsACPAgent session the commit id) is open. It belongs to the commit step, because the caller said do not commit.
  timestamp: 2026-10-07T14:15:17.637015+00:00
- actor: claude-code
  id: 01m4bbg1mnn5kc7gq215nxb3ph
  text: |-
    ### implement — changed
    - evidence: 7 files — Sources/FoundationModelsCodeContext/Index/Watcher.swift, Sources/FoundationModelsCodeContext/CodeContext.swift, Sources/FoundationModelsCodeContext/CodeContextManager.swift, Tests/FoundationModelsCodeContextTests/WatcherTests.swift, Tests/FoundationModelsCodeContextTests/CodeContextStartTests.swift, Tests/FoundationModelsCodeContextTests/FileEventSourcePublicAPITests.swift (new), Tests/FoundationModelsCodeContextTests/Support/RecordingFileEventSource.swift (new), plus plan.md. `swift test`: 765 tests in 69 suites passed, 0 failed. `swift test --package-path IntegrationTests --filter RealFSEventsWatcherTests`: 1 passed. `swift format lint` on the changed Swift files: clean. The only build warnings come from SwiftPM and the mlx-swift checkout, not from this package.
    - next: /review. Subtask 4 (push to main, tell FoundationModelsACPAgent the commit id) is for the commit step.
  timestamp: 2026-10-07T14:15:21.493424+00:00
position_column: doing
position_ordinal: '80'
title: Watcher.start() calls FSEventStreamStart on a Swift cooperative thread, and fseventsd serializes the starts
---
## Why

Reported by FoundationModelsACPAgent (^bdzygnn), found during its ^vjaka1g.

`CodeContext.start()` awaits `Watcher.start()`. `Watcher.start()` calls `FSEventsFileEventSource.start(rootDirectory:handler:)`, and that method calls `FSEventStreamStart` synchronously on the calling thread. The calling thread is a thread of the Swift cooperative pool (`Sources/FoundationModelsCodeContext/Index/Watcher.swift`, at e9f60bd).

`FSEventStreamStart` is a synchronous mach RPC to fseventsd (`f2d_register_rpc`). fseventsd registers the streams of the whole machine one at a time.

Measured on 2026-10-04, on a 32-core machine at load average 30:
- One start takes 0.1 s to 0.3 s.
- Ten starts at the same time take 9.5 s (5.5 s each on average).
- Forty starts at the same time take 13 s.

While a start waits, it holds one cooperative thread. A `sample` of the agent test process showed many cooperative threads blocked in `FSEventStreamStart`. The cooperative pool has one thread for each core, so other async work in the process also waited.

The teardown (`FSEventStreamStop`, `Invalidate`, `Release`) already runs on a global dispatch queue, so `stop()` does not block.

## What to do

- [x] Call `FSEventStreamStart` off the cooperative pool. For example, call it on the watcher dispatch queue, and resume a continuation when the start returns. Then a slow fseventsd does not block a cooperative thread.
- [x] Add a public seam to inject a `FileEventSource`, or a configuration that turns the watcher off. A host or a test that does not need live file events can then use the index with no FSEvents stream.
- [x] Add a test that proves `start()` does not call `FSEventStreamStart` on a cooperative thread. For example, use an injected source that records `Thread.isMainThread` and the dispatch queue label.
- [ ] Push to main, and tell the FoundationModelsACPAgent session the commit id.
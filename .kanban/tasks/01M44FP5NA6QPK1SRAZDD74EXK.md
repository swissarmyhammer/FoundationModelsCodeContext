---
position_column: todo
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

- [ ] Call `FSEventStreamStart` off the cooperative pool. For example, call it on the watcher dispatch queue, and resume a continuation when the start returns. Then a slow fseventsd does not block a cooperative thread.
- [ ] Add a public seam to inject a `FileEventSource`, or a configuration that turns the watcher off. A host or a test that does not need live file events can then use the index with no FSEvents stream.
- [ ] Add a test that proves `start()` does not call `FSEventStreamStart` on a cooperative thread. For example, use an injected source that records `Thread.isMainThread` and the dispatch queue label.
- [ ] Push to main, and tell the FoundationModelsACPAgent session the commit id.
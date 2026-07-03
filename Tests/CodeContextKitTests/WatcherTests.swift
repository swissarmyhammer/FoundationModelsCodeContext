import Foundation
import Testing

@testable import CodeContextKit

/// Tests for `Watcher`: debounce coalescing of a burst of events into one
/// flush, the created/modified→dirty and deleted→delete-cascade flows, and
/// gitignore/`.code-context/`/extension filtering — driven entirely against
/// `FakeFileEventSource` and a `ManualClock` so no test waits on real
/// wall-clock time or the real FSEvents API. One real-FSEvents integration
/// test lives at the bottom of this file.
struct WatcherTests {
    /// Counts `nudgeWorkers` invocations, so tests can assert "exactly one
    /// nudge per flush" without a real indexing worker to observe.
    private actor NudgeCounter {
        private(set) var count = 0
        func increment() { count += 1 }
    }

    /// Builds a `Watcher` wired to a fresh `FakeFileEventSource` and the
    /// given `ManualClock`, started and ready to receive `emit(_:)` calls.
    /// Shared setup for every fake-driven test below.
    private static func makeStartedWatcher(
        store: Store,
        rootDirectory: URL,
        clock: ManualClock,
        debounceInterval: Duration = .seconds(1),
        nudgeWorkers: @escaping @Sendable () async -> Void = {}
    ) async -> (watcher: Watcher, eventSource: FakeFileEventSource) {
        let eventSource = FakeFileEventSource()
        let watcher = Watcher(
            store: store,
            rootDirectory: rootDirectory,
            eventSource: eventSource,
            clock: clock,
            debounceInterval: debounceInterval,
            nudgeWorkers: nudgeWorkers
        )
        await watcher.start()
        return (watcher, eventSource)
    }

    @Test
    func burstOfEventsOnOneFileWithinDebounceWindowProducesOneDirtyMarkAndOneNudge() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("fn a() {}", to: "a.rs", in: root)

            let clock = ManualClock()
            let nudges = NudgeCounter()
            let (watcher, eventSource) = await Self.makeStartedWatcher(
                store: store,
                rootDirectory: root,
                clock: clock,
                nudgeWorkers: { await nudges.increment() }
            )

            let fileURL = root.appendingPathComponent("a.rs")
            for _ in 0..<5 {
                await eventSource.emit(RawFileEvent(url: fileURL, kind: .modified))
            }

            await clock.waitForWaiter()
            clock.advance(by: .seconds(1))
            await watcher.waitForQuiescence()

            #expect(try await store.drainTsDirty() == ["a.rs"])
            let nudgeCount = await nudges.count
            #expect(nudgeCount == 1)
        }
    }

    @Test
    func createdEventMarksNewFileDirtyAcrossAllLayers() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("fn a() {}", to: "a.rs", in: root)

            let clock = ManualClock()
            let (watcher, eventSource) = await Self.makeStartedWatcher(store: store, rootDirectory: root, clock: clock)

            await eventSource.emit(RawFileEvent(url: root.appendingPathComponent("a.rs"), kind: .created))
            await clock.waitForWaiter()
            clock.advance(by: .seconds(1))
            await watcher.waitForQuiescence()

            #expect(try await store.drainTsDirty() == ["a.rs"])
            #expect(try await store.drainLspDirty() == ["a.rs"])
            #expect(try await store.drainEmbeddingDirty() == ["a.rs"])
        }
    }

    @Test
    func modifiedEventReDirtiesAPreviouslyFullyIndexedFile() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("fn a() {}", to: "a.rs", in: root)
            try await store.markDirty(filePath: "a.rs", contentHash: Data([1]), fileSize: 1)
            try await store.markIndexed(filePath: "a.rs", layer: .treeSitter)
            try await store.markIndexed(filePath: "a.rs", layer: .lsp)
            try await store.markIndexed(filePath: "a.rs", layer: .embedding)
            #expect(try await store.drainTsDirty().isEmpty)

            try write("fn a_modified() {}", to: "a.rs", in: root)

            let clock = ManualClock()
            let (watcher, eventSource) = await Self.makeStartedWatcher(store: store, rootDirectory: root, clock: clock)

            await eventSource.emit(RawFileEvent(url: root.appendingPathComponent("a.rs"), kind: .modified))
            await clock.waitForWaiter()
            clock.advance(by: .seconds(1))
            await watcher.waitForQuiescence()

            #expect(try await store.drainTsDirty() == ["a.rs"])
            #expect(try await store.drainLspDirty() == ["a.rs"])
            #expect(try await store.drainEmbeddingDirty() == ["a.rs"])
        }
    }

    @Test
    func deletedEventRemovesIndexedFileRowAndCascades() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("fn a() {}", to: "a.rs", in: root)
            try await store.markDirty(filePath: "a.rs", contentHash: Data([1]), fileSize: 1)
            try await store.write { db in
                try db.execute(sql: """
                INSERT INTO ts_chunks (file_path, start_byte, end_byte, start_line, end_line, text, symbol_path, kind)
                VALUES ('a.rs', 0, 10, 1, 1, 'fn a() {}', 'a', 'function')
                """)
            }

            try FileManager.default.removeItem(at: root.appendingPathComponent("a.rs"))

            let clock = ManualClock()
            let (watcher, eventSource) = await Self.makeStartedWatcher(store: store, rootDirectory: root, clock: clock)

            await eventSource.emit(RawFileEvent(url: root.appendingPathComponent("a.rs"), kind: .removed))
            await clock.waitForWaiter()
            clock.advance(by: .seconds(1))
            await watcher.waitForQuiescence()

            let remainingFiles = try await store.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM indexed_files") ?? 0
            }
            #expect(remainingFiles == 0)

            let remainingChunks = try await store.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ts_chunks") ?? 0
            }
            #expect(remainingChunks == 0)
        }
    }

    @Test
    func deletedEventForAFileNeverIndexedIsANoOp() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)

            let clock = ManualClock()
            let (watcher, eventSource) = await Self.makeStartedWatcher(store: store, rootDirectory: root, clock: clock)

            await eventSource.emit(RawFileEvent(url: root.appendingPathComponent("ghost.rs"), kind: .removed))
            await clock.waitForWaiter()
            clock.advance(by: .seconds(1))
            await watcher.waitForQuiescence()

            let remainingFiles = try await store.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM indexed_files") ?? 0
            }
            #expect(remainingFiles == 0)
        }
    }

    @Test
    func lastRecordedRemovedKindInABurstDeletesEvenWhenFileStillExistsOnDisk() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("fn a() {}", to: "a.rs", in: root)
            try await store.markDirty(filePath: "a.rs", contentHash: Data([1]), fileSize: 1)

            let clock = ManualClock()
            let (watcher, eventSource) = await Self.makeStartedWatcher(store: store, rootDirectory: root, clock: clock)

            // The file is never actually deleted from disk, but the last
            // event recorded for it within the debounce window is
            // `.removed` — that must still drive the outcome (matching the
            // Rust FanoutWatcher reference), not a disk-existence check.
            let fileURL = root.appendingPathComponent("a.rs")
            await eventSource.emit(RawFileEvent(url: fileURL, kind: .modified))
            await eventSource.emit(RawFileEvent(url: fileURL, kind: .removed))

            await clock.waitForWaiter()
            clock.advance(by: .seconds(1))
            await watcher.waitForQuiescence()

            let remainingFiles = try await store.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM indexed_files") ?? 0
            }
            #expect(remainingFiles == 0)
            #expect(FileManager.default.fileExists(atPath: fileURL.path))
        }
    }

    @Test
    func lastRecordedModifiedKindInABurstMarksDirtyEvenAfterAnEarlierRemovedEvent() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("fn a() {}", to: "a.rs", in: root)

            let clock = ManualClock()
            let (watcher, eventSource) = await Self.makeStartedWatcher(store: store, rootDirectory: root, clock: clock)

            let fileURL = root.appendingPathComponent("a.rs")
            await eventSource.emit(RawFileEvent(url: fileURL, kind: .removed))
            await eventSource.emit(RawFileEvent(url: fileURL, kind: .modified))

            await clock.waitForWaiter()
            clock.advance(by: .seconds(1))
            await watcher.waitForQuiescence()

            #expect(try await store.drainTsDirty() == ["a.rs"])
        }
    }

    @Test
    func eventsUnderGitignoredPathAreIgnored() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("ignored.rs\n", to: ".gitignore", in: root)
            try write("fn ignored() {}", to: "ignored.rs", in: root)
            try write("fn kept() {}", to: "kept.rs", in: root)

            let clock = ManualClock()
            let (watcher, eventSource) = await Self.makeStartedWatcher(store: store, rootDirectory: root, clock: clock)

            await eventSource.emit(RawFileEvent(url: root.appendingPathComponent("ignored.rs"), kind: .created))
            await eventSource.emit(RawFileEvent(url: root.appendingPathComponent("kept.rs"), kind: .created))

            await clock.waitForWaiter()
            clock.advance(by: .seconds(1))
            await watcher.waitForQuiescence()

            #expect(try await store.drainTsDirty() == ["kept.rs"])
        }
    }

    @Test
    func eventsUnderCodeContextDirectoryAreIgnored() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("fn leaked() {}", to: ".code-context/leaked.rs", in: root)

            let clock = ManualClock()
            let (_, eventSource) = await Self.makeStartedWatcher(store: store, rootDirectory: root, clock: clock)

            await eventSource.emit(RawFileEvent(url: root.appendingPathComponent(".code-context/leaked.rs"), kind: .created))

            // The event was filtered synchronously inside `handleRawEvent`
            // (never entered the pending batch), so no debounce timer was
            // ever started — nothing to advance, the assertion is immediate.
            #expect(try await store.drainTsDirty().isEmpty)
        }
    }

    @Test
    func eventsForUnknownExtensionsAreIgnored() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("not code", to: "notes.txt", in: root)

            let clock = ManualClock()
            let (_, eventSource) = await Self.makeStartedWatcher(store: store, rootDirectory: root, clock: clock)

            await eventSource.emit(RawFileEvent(url: root.appendingPathComponent("notes.txt"), kind: .created))

            #expect(try await store.drainTsDirty().isEmpty)
        }
    }

    @Test
    func multipleDistinctFilesInOneWindowAllDirtyWithOneNudge() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("fn a() {}", to: "a.rs", in: root)
            try write("struct B {}", to: "b.swift", in: root)

            let clock = ManualClock()
            let nudges = NudgeCounter()
            let (watcher, eventSource) = await Self.makeStartedWatcher(
                store: store,
                rootDirectory: root,
                clock: clock,
                nudgeWorkers: { await nudges.increment() }
            )

            await eventSource.emit(RawFileEvent(url: root.appendingPathComponent("a.rs"), kind: .created))
            await eventSource.emit(RawFileEvent(url: root.appendingPathComponent("b.swift"), kind: .created))

            await clock.waitForWaiter()
            clock.advance(by: .seconds(1))
            await watcher.waitForQuiescence()

            #expect(Set(try await store.drainTsDirty()) == ["a.rs", "b.swift"])
            let nudgeCount = await nudges.count
            #expect(nudgeCount == 1)
        }
    }

    // MARK: - Real FSEvents integration

    @Test
    func realFSEventsDetectsFileWriteAndMarksItDirty() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            let watcher = Watcher(
                store: store,
                rootDirectory: root,
                debounceInterval: .milliseconds(200),
                nudgeWorkers: {}
            )
            await watcher.start()
            defer { Task { await watcher.stop() } }

            // Give the FSEvents stream a moment to finish registering
            // before writing, mirroring production's real startup order.
            try await Task.sleep(for: .milliseconds(500))

            try write("fn a() {}", to: "a.rs", in: root)

            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            var dirty: [String] = []
            while ContinuousClock.now < deadline {
                dirty = try await store.drainTsDirty()
                if !dirty.isEmpty {
                    break
                }
                try await Task.sleep(for: .milliseconds(200))
            }

            #expect(dirty == ["a.rs"])
        }
    }
}

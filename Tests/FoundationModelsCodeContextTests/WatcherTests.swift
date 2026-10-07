import Foundation
import InMemoryLogging
import Logging
import Testing

@testable import FoundationModelsCodeContext

/// Tests for `Watcher`: debounce coalescing of a burst of events into one
/// flush, the created/modified→dirty and deleted→delete-cascade flows, and
/// gitignore/`.code-context/`/extension filtering — driven entirely against
/// `FakeFileEventSource` and a `ManualClock` so no test waits on real
/// wall-clock time or the real FSEvents API. The test against the real
/// FSEvents API lives in `RealFSEventsWatcherTests` in the `IntegrationTests`
/// nested package.
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

    /// The time that a second `start()` call gets to run while the first call
    /// waits at the gate of the source. The result of a correct watcher does
    /// not depend on this time. A watcher that starts the source again needs
    /// the time to show the second start.
    private static let secondStartRunTime = Duration.milliseconds(100)

    /// Builds a `Watcher` wired to `eventSource` and a fresh `ManualClock`,
    /// not yet started.
    private static func makeWatcher(store: Store, rootDirectory: URL, eventSource: any FileEventSource) -> Watcher {
        Watcher(store: store, rootDirectory: rootDirectory, eventSource: eventSource, clock: ManualClock(), nudgeWorkers: {})
    }

    @Test
    func startCallsTheEventSourceOnTheStartQueueAndNotOnTheCooperativePool() async throws {
        try await withTemporaryWorkspace { root in
            let source = RecordingFileEventSource()
            let watcher = Self.makeWatcher(store: try Store(rootDirectory: root), rootDirectory: root, eventSource: source)

            await watcher.start()

            let expected = FileEventSourceStartRecord(isMainThread: false, queueLabel: Watcher.eventSourceStartQueueLabel)
            #expect(source.startRecords == [expected])
        }
    }

    @Test
    func stopWhileTheSourceStartsStopsTheSubscriptionThatTheSourceReturns() async throws {
        try await withTemporaryWorkspace { root in
            let source = RecordingFileEventSource(isGated: true)
            let watcher = Self.makeWatcher(store: try Store(rootDirectory: root), rootDirectory: root, eventSource: source)
            var startCalls = source.startCalls.makeAsyncIterator()

            let startTask = Task { await watcher.start() }
            await startCalls.next()
            await watcher.stop()
            source.openGate()
            await startTask.value

            #expect(source.stoppedSubscriptionCount == 1)
        }
    }

    @Test
    func startWhileTheSourceStartsDoesNotStartTheSourceAgain() async throws {
        try await withTemporaryWorkspace { root in
            let source = RecordingFileEventSource(isGated: true)
            let watcher = Self.makeWatcher(store: try Store(rootDirectory: root), rootDirectory: root, eventSource: source)
            var startCalls = source.startCalls.makeAsyncIterator()

            let firstStartTask = Task { await watcher.start() }
            await startCalls.next()
            let secondStartTask = Task { await watcher.start() }
            // The second call runs while the first call waits at the gate. Then the gate opens
            // for two calls, thus a second start of the source cannot wait for ever.
            try await Task.sleep(for: Self.secondStartRunTime)
            source.openGate()
            source.openGate()
            await firstStartTask.value
            await secondStartTask.value

            #expect(source.startRecords.count == 1)
            #expect(source.stoppedSubscriptionCount == 0)
        }
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
    func modifiedEventRedirtiesAPreviouslyFullyIndexedFile() async throws {
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
                try db.execute(
                    sql: """
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
    func eventsForUppercaseExtensionsAreAccepted() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("fn a() {}", to: "Sample.RS", in: root)

            let clock = ManualClock()
            let (watcher, eventSource) = await Self.makeStartedWatcher(store: store, rootDirectory: root, clock: clock)

            await eventSource.emit(RawFileEvent(url: root.appendingPathComponent("Sample.RS"), kind: .created))
            await clock.waitForWaiter()
            clock.advance(by: .seconds(1))
            await watcher.waitForQuiescence()

            #expect(try await store.drainTsDirty() == ["Sample.RS"])
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

    // MARK: - Bursts and failed writes

    /// The number of files in the burst test. A checkout or a venv build
    /// changes thousands of files, thus the flush of the burst is long
    /// enough to get new events while it runs.
    private static let burstFileCount = 2000

    /// The watcher warnings about the files under `directory`.
    ///
    /// The log records of all the tests of the process go into one store.
    /// Each test that calls this function uses a directory name that no other
    /// test uses.
    private static func watcherWarnings(under directory: String) -> [InMemoryLogHandler.Entry] {
        CapturedLogRecords.entries.filter { entry in
            entry.level == .warning
                && entry.metadata[CodeContextTracing.MetadataKey.filePath]?.description.hasPrefix(directory + "/") == true
        }
    }

    /// Advances `clock` past one debounce window and waits until the flush
    /// that it starts is complete.
    private static func flushOneWindow(watcher: Watcher, clock: ManualClock) async {
        await clock.waitForWaiter()
        clock.advance(by: .seconds(1))
        await watcher.waitForQuiescence()
    }

    /// Makes each write of the `indexed_files` table fail with
    /// `SQLITE_CONSTRAINT_TRIGGER` (1811), until `allowIndexedFileWrites(in:)`.
    private static func failIndexedFileWrites(in store: Store) async throws {
        try await store.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_insert BEFORE INSERT ON indexed_files BEGIN SELECT RAISE(ABORT, 'test'); END")
            try db.execute(sql: "CREATE TRIGGER fail_update BEFORE UPDATE ON indexed_files BEGIN SELECT RAISE(ABORT, 'test'); END")
            try db.execute(sql: "CREATE TRIGGER fail_delete BEFORE DELETE ON indexed_files BEGIN SELECT RAISE(ABORT, 'test'); END")
        }
    }

    /// Removes the triggers of `failIndexedFileWrites(in:)`.
    private static func allowIndexedFileWrites(in store: Store) async throws {
        try await store.write { db in
            try db.execute(sql: "DROP TRIGGER fail_insert")
            try db.execute(sql: "DROP TRIGGER fail_update")
            try db.execute(sql: "DROP TRIGGER fail_delete")
        }
    }

    @Test
    func newEventsDuringTheFlushOfABurstLoseNoDirtyMarkAndLogNoWarning() async throws {
        _ = CapturedLogRecords.handler
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            let directory = "burst-\(UUID().uuidString)"
            let paths = (0..<Self.burstFileCount).map { "\(directory)/file\($0).py" }
            for path in paths {
                try write("x = 1\n", to: path, in: root)
            }
            let latePath = "\(directory)/late.py"
            try write("y = 2\n", to: latePath, in: root)

            let clock = ManualClock()
            let (watcher, eventSource) = await Self.makeStartedWatcher(store: store, rootDirectory: root, clock: clock)
            for path in paths {
                await eventSource.emit(RawFileEvent(url: root.appendingPathComponent(path), kind: .created))
            }
            await clock.waitForWaiter()
            clock.advance(by: .seconds(1))

            // Wait until the flush of the burst writes, then give a new event
            // while that flush runs.
            while try await store.drainTsDirty().isEmpty {
                try await Task.sleep(for: .milliseconds(1))
            }
            await eventSource.emit(RawFileEvent(url: root.appendingPathComponent(latePath), kind: .created))
            await Self.flushOneWindow(watcher: watcher, clock: clock)

            #expect(Set(try await store.drainTsDirty()) == Set(paths + [latePath]))
            #expect(Self.watcherWarnings(under: directory).isEmpty)
        }
    }

    @Test
    func aFailedDirtyMarkLogsTheErrorCaseAndTheSQLiteCodeAndTheNextFlushWritesIt() async throws {
        _ = CapturedLogRecords.handler
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            let directory = "failed-mark-\(UUID().uuidString)"
            let path = "\(directory)/a.py"
            try write("x = 1\n", to: path, in: root)
            try await Self.failIndexedFileWrites(in: store)

            let clock = ManualClock()
            let (watcher, eventSource) = await Self.makeStartedWatcher(store: store, rootDirectory: root, clock: clock)
            await eventSource.emit(RawFileEvent(url: root.appendingPathComponent(path), kind: .modified))
            await Self.flushOneWindow(watcher: watcher, clock: clock)

            let warnings = Self.watcherWarnings(under: directory)
            #expect(warnings.count == 1)
            #expect(warnings.first?.message.description == "the watcher could not mark a changed file dirty")
            #expect(warnings.first?.metadata[CodeContextTracing.MetadataKey.errorCase]?.description == "storage")
            #expect(warnings.first?.metadata[CodeContextTracing.MetadataKey.databaseStatusCode]?.description == "1811")
            #expect(try await store.drainTsDirty().isEmpty)

            try await Self.allowIndexedFileWrites(in: store)
            await Self.flushOneWindow(watcher: watcher, clock: clock)

            #expect(try await store.drainTsDirty() == [path])
        }
    }

    @Test
    func aFailedDeleteLogsTheErrorCaseAndTheSQLiteCodeAndTheNextFlushDeletesTheFile() async throws {
        _ = CapturedLogRecords.handler
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            let directory = "failed-delete-\(UUID().uuidString)"
            let path = "\(directory)/a.py"
            try await store.markDirty(filePath: path, contentHash: Data([1]), fileSize: 1)
            try await Self.failIndexedFileWrites(in: store)

            let clock = ManualClock()
            let (watcher, eventSource) = await Self.makeStartedWatcher(store: store, rootDirectory: root, clock: clock)
            await eventSource.emit(RawFileEvent(url: root.appendingPathComponent(path), kind: .removed))
            await Self.flushOneWindow(watcher: watcher, clock: clock)

            let warnings = Self.watcherWarnings(under: directory)
            #expect(warnings.count == 1)
            #expect(warnings.first?.message.description == "the watcher could not delete a removed file from the index")
            #expect(warnings.first?.metadata[CodeContextTracing.MetadataKey.errorCase]?.description == "storage")
            #expect(warnings.first?.metadata[CodeContextTracing.MetadataKey.databaseStatusCode]?.description == "1811")
            #expect(try await store.drainTsDirty() == [path])

            try await Self.allowIndexedFileWrites(in: store)
            await Self.flushOneWindow(watcher: watcher, clock: clock)

            #expect(try await store.drainTsDirty().isEmpty)
        }
    }

    @Test
    func aWriteThatFailsEachAttemptStopsAfterTheLastAttempt() async throws {
        _ = CapturedLogRecords.handler
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            let directory = "failed-always-\(UUID().uuidString)"
            let path = "\(directory)/a.py"
            try write("x = 1\n", to: path, in: root)
            try await Self.failIndexedFileWrites(in: store)

            let clock = ManualClock()
            let (watcher, eventSource) = await Self.makeStartedWatcher(store: store, rootDirectory: root, clock: clock)
            await eventSource.emit(RawFileEvent(url: root.appendingPathComponent(path), kind: .modified))
            for _ in 0..<Watcher.maximumWriteAttempts {
                await Self.flushOneWindow(watcher: watcher, clock: clock)
            }

            #expect(Self.watcherWarnings(under: directory).count == Watcher.maximumWriteAttempts)
            #expect(await watcher.pendingEventCount == 0)
        }
    }
}

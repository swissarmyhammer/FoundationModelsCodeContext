import Foundation
import Testing

@testable import FoundationModelsCodeContext

/// The test of `Watcher` against the real FSEvents API of the operating system.
///
/// The unit target drives `Watcher` with `FakeFileEventSource` and `ManualClock`, thus it never
/// starts a real event stream. This suite lives in the `IntegrationTests` nested package, so a
/// root `swift test` never runs it. It depends on the delivery of events by `fseventsd`. That
/// delivery is slow and intermittent when many tests run at the same time in one process.
/// Run it with `swift test --package-path IntegrationTests`.
struct RealFSEventsWatcherTests {
    /// The time after which the test gives up when no event comes.
    private static let deliveryBudget: Duration = .seconds(30)

    /// The time between two writes of the same file. It is longer than the debounce interval, thus
    /// a new write cannot restart the quiet-window timer of the watcher without end.
    private static let rewriteInterval: Duration = .seconds(2)

    /// The time between two checks of the dirty files.
    private static let pollInterval: Duration = .milliseconds(200)

    /// The time that the stream needs to finish its registration before the first write.
    private static let registrationDelay: Duration = .milliseconds(500)

    /// The quiet time that the watcher waits before it flushes a batch of events.
    private static let debounceInterval: Duration = .milliseconds(200)

    /// The content of the file that the test writes.
    private static let fileContent = "fn a() {}"

    @Test func realFSEventsDetectsFileWriteAndMarksItDirty() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            let watcher = Watcher(
                store: store,
                rootDirectory: root,
                debounceInterval: Self.debounceInterval,
                nudgeWorkers: {}
            )
            await watcher.start()
            defer { Task { await watcher.stop() } }

            // The stream needs a moment to register. This is the same order as the start of the
            // production code.
            try await Task.sleep(for: Self.registrationDelay)

            try write(Self.fileContent, to: "a.rs", in: root)

            // A single write can race the registration of the stream and be lost. Thus the test
            // writes the same content again when the last write gets no answer.
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: Self.deliveryBudget)
            var lastWrite = clock.now
            var dirty: [String] = []
            while clock.now < deadline {
                dirty = try await store.drainTsDirty()
                if !dirty.isEmpty {
                    break
                }
                if lastWrite.duration(to: clock.now) > Self.rewriteInterval {
                    try write(Self.fileContent, to: "a.rs", in: root)
                    lastWrite = clock.now
                }
                try await Task.sleep(for: Self.pollInterval)
            }

            #expect(dirty == ["a.rs"])
        }
    }
}

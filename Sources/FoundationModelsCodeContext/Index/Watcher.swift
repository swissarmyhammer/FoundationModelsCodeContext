import CoreServices
import Foundation
import Logging
import Tracing

// MARK: - Raw event model

/// The kind of change a `FileEventSource` observed for one path.
public enum FileChangeKind: Sendable, Hashable {
    /// A new file appeared.
    case created

    /// An existing file's content changed.
    case modified

    /// A file was removed.
    case removed
}

/// One raw filesystem change reported by a `FileEventSource`, before
/// `Watcher` debounces and coalesces it.
public struct RawFileEvent: Sendable, Hashable {
    /// The changed file's full filesystem URL.
    public let url: URL

    /// The kind of change observed.
    public let kind: FileChangeKind

    /// Creates a raw filesystem change event.
    ///
    /// - Parameters:
    ///   - url: The changed file's full filesystem URL.
    ///   - kind: The kind of change observed.
    public init(url: URL, kind: FileChangeKind) {
        self.url = url
        self.kind = kind
    }
}

// MARK: - FileEventSource

/// A handle to a live subscription started by
/// `FileEventSource.start(rootDirectory:handler:)`.
public protocol FileEventSubscription: Sendable {
    /// Stops delivering events and releases any underlying resources.
    func stop()
}

/// Abstraction over a live filesystem-change notification stream.
///
/// `Watcher` is generic over this protocol so tests can drive a synthetic
/// event stream (`FakeFileEventSource` in the test target) without touching
/// the real FSEvents API; `FSEventsFileEventSource` is the production
/// implementation.
public protocol FileEventSource: Sendable {
    /// Begins delivering raw filesystem-change events under `rootDirectory`
    /// to `handler`, until the returned subscription's `stop()` is called.
    ///
    /// - Parameters:
    ///   - rootDirectory: The directory to watch, recursively.
    ///   - handler: Called once per raw event. Declared `async` so a fake
    ///     test source can await full delivery before returning from its
    ///     own synthetic `emit(_:)` call, instead of racing a
    ///     fire-and-forget dispatch.
    /// - Returns: A subscription whose `stop()` ends the watch.
    func start(rootDirectory: URL, handler: @escaping @Sendable (RawFileEvent) async -> Void) -> any FileEventSubscription
}

// MARK: - Watcher

/// Debounced, gitignore-aware bridge from live filesystem change events to
/// `Store`'s dirty-flag bookkeeping.
///
/// Port of the Rust `swissarmyhammer-code-context::watcher::FanoutWatcher`
/// plus the debounced-watch loop in `swissarmyhammer-tools`'s
/// `file_watcher.rs`/`code_context/watcher.rs`, replacing
/// `notify`/`async-watcher` with FSEvents (see `FSEventsFileEventSource`
/// below): every raw event that survives filtering (known `Languages.all`
/// extension, and accepted by `PathFilter`, the same filter as the walk) is
/// accumulated into a per-path pending batch. Each new event restarts a
/// `debounceInterval`
/// quiet-window timer — reset-on-each-event, standard debounce semantics.
/// This is a deliberate, spelled-out design choice rather than an inherited
/// one: the Rust reference's `async-watcher` dependency batches events
/// internally without documenting its own coalescing algorithm, so there is
/// no exact behavior to port here.
///
/// When the timer finally elapses with no new events, the whole batch is
/// flushed in one pass, one path at a time, using each path's
/// last-recorded event kind in the batch (matching the Rust reference's
/// `FanoutWatcher::notify`, which maps `FileEvent` directly to an action
/// with no separate disk check): `.created`/`.modified` marks the path
/// dirty across all three index layers (`Store.markDirty`), reading its
/// current content from disk to compute the hash `markDirty` records. When
/// no file is at the path (the file was removed again before this debounced
/// flush ran), the watcher deletes the path like a `.removed` change and logs
/// it at the debug level. When the read fails for another reason, the path is
/// skipped with a warning, so it keeps its row for a later event or a future
/// reconcile. `.removed` deletes the path (`Store.deleteFile`, cascading
/// to its chunks/symbols/edges) unconditionally — including when nothing
/// is indexed for it yet, which is a harmless no-op `DELETE`. The flush
/// ends with exactly one call to `nudgeWorkers`, regardless of how many
/// distinct paths were in the batch.
///
/// Each flush runs in its own task, not in the debounce timer task. A new
/// event cancels the timer task, and GRDB stops each write of a cancelled
/// task. Thus a new event during a long flush (for example the flush of a
/// checkout) does not stop that flush. The flushes run one after the other.
///
/// When a write of a path fails, the watcher logs a warning and puts the
/// change back in the pending batch for the next flush, if no newer event
/// for that path is pending. After `maximumWriteAttempts` failed writes the
/// watcher drops the change. The next reconcile finds that change, because
/// the index still holds the old content hash of the file.
///
/// The watcher loads the ignore rules one time, in `start()`, off this actor
/// (see `SharedPathFilter`). It does not read the rule files for each event.
/// It loads the rules again when an event is for a `.gitignore` or `.ignore`
/// file, or for `.git/info/exclude`. The watcher examines each event for these
/// files BEFORE the filter, because the filter ignores `.git/info/exclude`
/// (`.git` is hidden and a hard skip). The event after the load uses the new
/// rules. An event that is already in the pending batch keeps its place; the
/// next reconcile removes the row of a path that the new rules ignore.
public actor Watcher {
    /// The label of the dispatch queue that calls `FileEventSource.start(rootDirectory:handler:)`.
    /// It starts with the label of the watcher logger, thus it starts with the module prefix.
    static let eventSourceStartQueueLabel = CodeContextTracing.LoggerLabel.watcher + ".start"

    private let store: Store
    private let rootDirectory: URL
    private let eventSource: any FileEventSource
    private let clock: any Clock<Duration>
    private let debounceInterval: Duration
    private let nudgeWorkers: @Sendable () async -> Void
    private let allowedExtensions: Set<String>

    /// The path filter of the workspace. `start()` loads its rules, and an
    /// event for a rule file loads them again.
    private let pathFilter: SharedPathFilter

    /// The tracer of the span of each flush. `nil` reads the bootstrapped tracer at the time of
    /// each flush.
    private let tracer: (any Tracer)?

    /// The serial queue that calls `FileEventSource.start(rootDirectory:handler:)`.
    ///
    /// The call can block. `FSEventsFileEventSource` calls `FSEventStreamStart`, which is a
    /// synchronous request to fseventsd, and fseventsd registers the streams of the whole machine
    /// one at a time. On this queue a slow start blocks a dispatch thread, not a thread of the
    /// Swift cooperative pool.
    private let eventSourceStartQueue = DispatchQueue(label: Watcher.eventSourceStartQueueLabel)

    /// The state of the subscription to `eventSource`.
    private enum SubscriptionState {
        /// No subscription: before `start()`, and after `stop()`.
        case idle

        /// A `start()` call waits for `eventSource` to start. The payload is the number of that
        /// call, from `startCallCount`.
        case starting(call: Int)

        /// The subscription delivers events.
        case running(any FileEventSubscription)

        /// The subscription of the `.running` state, or `nil` in each other state.
        var runningSubscription: (any FileEventSubscription)? {
            guard case .running(let subscription) = self else {
                return nil
            }
            return subscription
        }
    }

    /// The state of the subscription to `eventSource`.
    private var subscriptionState = SubscriptionState.idle

    /// The number of `start()` calls that started `eventSource` up to now. A `start()` call
    /// compares its number with `subscriptionState` when the source returns, thus it knows if
    /// `stop()` ran during the start.
    private var startCallCount = 0

    /// The maximum number of writes of one change. After this number of
    /// failed writes, the watcher drops the change.
    static let maximumWriteAttempts = 3

    private var pendingEvents: [String: FileChangeKind] = [:]

    /// The number of failed writes of each pending change that a failed
    /// write put back in `pendingEvents`. A new event for a path removes its
    /// count.
    private var failedWriteCounts: [String: Int] = [:]

    private var debounceTask: Task<Void, Never>?

    /// The task of the last flush. A new event does not cancel it.
    private var flushTask: Task<Void, Never>?

    /// Creates a watcher for `rootDirectory`, not yet started.
    ///
    /// - Parameters:
    ///   - store: The workspace's index store to mark dirty or delete into.
    ///   - rootDirectory: The workspace root to watch, recursively.
    ///   - eventSource: The raw event source to watch with. Defaults to
    ///     `FSEventsFileEventSource()`; tests inject a fake.
    ///   - clock: The clock used to schedule the debounce window. Defaults
    ///     to `ContinuousClock()`; tests inject a `ManualClock`.
    ///   - debounceInterval: How long a path must go quiet before its batch
    ///     is flushed. Defaults to one second.
    ///   - tracer: The tracer of the span of each flush. Defaults to `nil`,
    ///     which reads the bootstrapped tracer at the time of each flush.
    ///   - nudgeWorkers: Called once after each non-empty flush, so the
    ///     caller can wake its indexing workers to drain the newly dirtied
    ///     files.
    public init(
        store: Store,
        rootDirectory: URL,
        eventSource: any FileEventSource = FSEventsFileEventSource(),
        clock: any Clock<Duration> = ContinuousClock(),
        debounceInterval: Duration = .seconds(1),
        tracer: (any Tracer)? = nil,
        nudgeWorkers: @escaping @Sendable () async -> Void
    ) {
        self.init(
            store: store,
            rootDirectory: rootDirectory,
            pathFilter: SharedPathFilter(rootDirectory: rootDirectory),
            eventSource: eventSource,
            clock: clock,
            debounceInterval: debounceInterval,
            tracer: tracer,
            nudgeWorkers: nudgeWorkers
        )
    }

    /// Creates a watcher for `rootDirectory` that uses the path filter
    /// instance of the workspace, not yet started.
    ///
    /// `CodeContext` calls this form, thus the watcher and the other users of
    /// the filter share one instance, and a rule change reaches each of them.
    ///
    /// - Parameters:
    ///   - store: The workspace's index store to mark dirty or delete into.
    ///   - rootDirectory: The workspace root to watch, recursively.
    ///   - pathFilter: The path filter instance of the workspace.
    ///   - eventSource: The raw event source to watch with.
    ///   - clock: The clock used to schedule the debounce window.
    ///   - debounceInterval: How long a path must go quiet before its batch
    ///     is flushed.
    ///   - tracer: The tracer of the span of each flush, or `nil` for the
    ///     bootstrapped tracer at the time of each flush.
    ///   - nudgeWorkers: Called once after each non-empty flush.
    init(
        store: Store,
        rootDirectory: URL,
        pathFilter: SharedPathFilter,
        eventSource: any FileEventSource,
        clock: any Clock<Duration>,
        debounceInterval: Duration,
        tracer: (any Tracer)?,
        nudgeWorkers: @escaping @Sendable () async -> Void
    ) {
        self.store = store
        self.rootDirectory = rootDirectory
        self.pathFilter = pathFilter
        self.eventSource = eventSource
        self.clock = clock
        self.debounceInterval = debounceInterval
        self.nudgeWorkers = nudgeWorkers
        self.tracer = tracer
        allowedExtensions = Set(Languages.all.flatMap { languageModule in languageModule.fileExtensions.map { $0.lowercased() } })
    }

    /// Starts watching, if not already started.
    ///
    /// The method first loads the ignore rules off this actor (see
    /// `SharedPathFilter.reload()`). When the load fails, the watcher still
    /// starts, with only the hidden-path and hard-skip rules.
    ///
    /// The method calls `FileEventSource.start(rootDirectory:handler:)` on
    /// `eventSourceStartQueue` and waits for it. Thus a slow start does not
    /// block a thread of the Swift cooperative pool.
    ///
    /// Safe to call more than once; a call while the watcher starts or
    /// watches is a no-op. When `stop()` runs before the source returns, this
    /// method stops the subscription that the source returns.
    public func start() async {
        guard case .idle = subscriptionState else {
            return
        }
        startCallCount += 1
        let call = startCallCount
        subscriptionState = .starting(call: call)

        await pathFilter.reload()
        let subscription = await startEventSource()

        guard case .starting(call: call) = subscriptionState else {
            subscription.stop()
            return
        }
        subscriptionState = .running(subscription)
    }

    /// Calls `FileEventSource.start(rootDirectory:handler:)` on
    /// `eventSourceStartQueue`, and waits for the subscription.
    ///
    /// - Returns: The subscription that the source returns.
    private func startEventSource() async -> any FileEventSubscription {
        let source = eventSource
        let directory = rootDirectory
        let handler: @Sendable (RawFileEvent) async -> Void = { [weak self] event in
            await self?.handleRawEvent(event)
        }
        return await withCheckedContinuation { continuation in
            eventSourceStartQueue.async {
                continuation.resume(returning: source.start(rootDirectory: directory, handler: handler))
            }
        }
    }

    /// Stops watching and discards any not-yet-flushed pending batch.
    ///
    /// A flush that runs continues to the end of its batch, but it puts no
    /// failed change back.
    ///
    /// Safe to call more than once, and safe to call without a prior
    /// `start()`. A call while `start()` waits for the source makes that
    /// `start()` stop the subscription that the source returns.
    public func stop() {
        subscriptionState.runningSubscription?.stop()
        subscriptionState = .idle
        debounceTask?.cancel()
        debounceTask = nil
        pendingEvents.removeAll()
        failedWriteCounts.removeAll()
    }

    deinit {
        subscriptionState.runningSubscription?.stop()
        debounceTask?.cancel()
    }

    // MARK: - Event handling

    /// Adds one raw event to the pending batch when the filter accepts it.
    ///
    /// The method first examines the raw path for a rule file change, and
    /// loads the rules again for that change. Then it filters the event with
    /// the current rules.
    /// - Parameter event: The raw event.
    private func handleRawEvent(_ event: RawFileEvent) async {
        var filter = await pathFilter.filter
        if filter.isRuleFileChange(event.url) {
            await pathFilter.reload()
            filter = await pathFilter.filter
        }
        guard let relativePath = acceptedRelativePath(for: event.url, filter: filter) else {
            return
        }
        pendingEvents[relativePath] = event.kind
        failedWriteCounts[relativePath] = nil
        restartDebounceTimer()
    }

    /// Cancels any in-flight debounce timer and starts a fresh one, so a
    /// path that keeps changing never flushes until it goes quiet for a
    /// full `debounceInterval`.
    private func restartDebounceTimer() {
        debounceTask?.cancel()
        let interval = debounceInterval
        let debounceClock = clock
        debounceTask = Task { [weak self] in
            do {
                try await debounceClock.sleep(for: interval)
            } catch {
                // Cancelled by a newer event restarting the timer, or by
                // `stop()` — either way, this cycle never flushes.
                return
            }
            await self?.startFlush()
        }
    }

    /// Starts a flush of the pending batch in a new task, which runs after
    /// the flush before it is complete.
    ///
    /// The flush does not run in `debounceTask`: a new event cancels
    /// `debounceTask`, and GRDB stops each write of a cancelled task. A new
    /// unstructured task does not get the cancellation of the task that
    /// makes it.
    private func startFlush() {
        let previousFlush = flushTask
        flushTask = Task { [weak self] in
            await previousFlush?.value
            await self?.flushPendingEvents()
        }
    }

    /// Applies every path in the current pending batch, then nudges the
    /// indexing workers exactly once.
    ///
    /// The flush runs in one `CodeContextTracing.SpanName.watcherBatch`
    /// span, which holds the count of paths in the batch. It never holds a
    /// path. The flush is short, thus it writes no "enter" log record.
    ///
    /// A change whose write fails goes back in the pending batch (see
    /// `retryLater(relativePath:kind:)`), and the flush then starts the
    /// debounce timer one time.
    private func flushPendingEvents() async {
        guard !pendingEvents.isEmpty else {
            return
        }
        let batch = pendingEvents
        pendingEvents.removeAll()

        await CodeContextTracing.tracer(explicit: tracer).withSpan(CodeContextTracing.SpanName.watcherBatch) { span in
            span.attributes[CodeContextTracing.AttributeKey.watcherBatchSize] = batch.count
            var putBackCount = 0
            for (relativePath, kind) in batch {
                if await applyChange(relativePath: relativePath, kind: kind) {
                    failedWriteCounts[relativePath] = nil
                } else if retryLater(relativePath: relativePath, kind: kind) {
                    putBackCount += 1
                }
            }
            if putBackCount > 0 {
                restartDebounceTimer()
            }
            await nudgeWorkers()
        }
    }

    /// Puts a change whose write failed back in the pending batch, for the
    /// next flush.
    ///
    /// The method does not put the change back when the watcher is stopped,
    /// when a newer event for the path is pending, or when the change has
    /// had `maximumWriteAttempts` failed writes.
    ///
    /// - Parameters:
    ///   - relativePath: The path of the file, relative to the root directory.
    ///   - kind: The change whose write failed.
    /// - Returns: `true` when the change is back in the pending batch.
    private func retryLater(relativePath: String, kind: FileChangeKind) -> Bool {
        guard subscriptionState.runningSubscription != nil, pendingEvents[relativePath] == nil else {
            return false
        }
        let failedWrites = (failedWriteCounts[relativePath] ?? 0) + 1
        guard failedWrites < Self.maximumWriteAttempts else {
            failedWriteCounts[relativePath] = nil
            return false
        }
        failedWriteCounts[relativePath] = failedWrites
        pendingEvents[relativePath] = kind
        return true
    }

    /// Applies one path's coalesced change, per its last-recorded `kind` in
    /// the batch: `.removed` deletes its `indexed_files` row; `.created`/
    /// `.modified` marks it dirty across all layers.
    ///
    /// - Returns: `false` when the write to the store failed, else `true`. A
    ///   file that the watcher cannot read is not a failed write.
    private func applyChange(relativePath: String, kind: FileChangeKind) async -> Bool {
        guard kind != .removed else {
            return await deleteFile(relativePath: relativePath)
        }

        let fileURL = rootDirectory.appendingPathComponent(relativePath)
        let hashed: HashedFile
        do {
            hashed = try Walker.hashFile(at: fileURL, relativePath: relativePath)
        } catch {
            return await skipUnreadFile(relativePath: relativePath, error: error)
        }
        do {
            try await store.markDirty(filePath: hashed.relativePath, contentHash: hashed.contentHash, fileSize: hashed.fileSize)
            return true
        } catch {
            Log.watcher.warning(
                "the watcher could not mark a changed file dirty",
                metadata: Self.failureMetadata(relativePath: relativePath, error: error)
            )
            return false
        }
    }

    /// Deletes the `indexed_files` row of one path, with its chunks, symbols
    /// and edges.
    /// - Parameter relativePath: The path of the file, relative to the root
    ///   directory.
    /// - Returns: `false` when the delete failed, else `true`.
    private func deleteFile(relativePath: String) async -> Bool {
        do {
            try await store.deleteFile(filePath: relativePath)
            return true
        } catch {
            Log.watcher.warning(
                "the watcher could not delete a removed file from the index",
                metadata: Self.failureMetadata(relativePath: relativePath, error: error)
            )
            return false
        }
    }

    /// Handles a created or modified path whose read failed, with the log
    /// level of the reason (see `SourceText.isMissingFile(_:)`).
    ///
    /// No file at the path is not an error: an agent often writes a scratch
    /// file and deletes it again inside the debounce window. The watcher logs
    /// it at the debug level and deletes the row of the path, as for a
    /// `.removed` change. Each other read failure is a warning with the type
    /// name of the error, and the path keeps its row for a later event or
    /// reconcile.
    /// - Parameters:
    ///   - relativePath: The path of the file, relative to the root directory.
    ///   - error: The error of the read.
    /// - Returns: `false` when the delete of a gone file failed, else `true`.
    private func skipUnreadFile(relativePath: String, error: any Error) async -> Bool {
        guard SourceText.isMissingFile(error) else {
            Log.watcher.warning(
                "the watcher cannot read a changed file and skips it in this flush",
                metadata: Self.failureMetadata(relativePath: relativePath, error: error)
            )
            return true
        }
        Log.watcher.debug(
            "the watcher finds no file at a changed path and removes the file from the index",
            metadata: [CodeContextTracing.MetadataKey.filePath: .string(relativePath)]
        )
        return await deleteFile(relativePath: relativePath)
    }

    /// Gives the log metadata of a watcher record about a failure for one file.
    /// - Parameters:
    ///   - relativePath: The path of the file, relative to the root directory.
    ///   - error: The error of the failure. The metadata holds only the names
    ///     and the code of `Log.errorDetail(of:)`, never the description.
    /// - Returns: The file path, the error type name, and the error case name
    ///   and the SQLite result code when the error has them.
    private static func failureMetadata(relativePath: String, error: any Error) -> Logger.Metadata {
        var metadata = Log.errorDetail(of: error)
        metadata[CodeContextTracing.MetadataKey.filePath] = .string(relativePath)
        return metadata
    }

    // MARK: - Filtering

    /// Returns `url`'s workspace-relative path if it should be tracked, or
    /// `nil` otherwise.
    ///
    /// Requires a known `Languages.all` extension and a path that `filter`
    /// accepts: below the root or the canonical root, and not ignored by the
    /// hidden-path, hard-skip or rule-file rules for any ancestor directory or
    /// for the file. The key is `WorkspaceRoot.relativePath(of:)`, the same key
    /// as the walk gives.
    /// - Parameters:
    ///   - url: The URL of the raw event.
    ///   - filter: The current path filter.
    /// - Returns: The row key of the file, or `nil` when the watcher ignores it.
    private func acceptedRelativePath(for url: URL, filter: PathFilter) -> String? {
        guard allowedExtensions.contains(Languages.normalizedFileExtension(of: url)) else {
            return nil
        }
        return filter.acceptedRelativePath(of: url, isDirectory: false)
    }

    // MARK: - Testing

    /// Test-only synchronization hook: awaits completion of the currently
    /// in-flight debounce timer, and then of the flush that it started, if
    /// any.
    ///
    /// A `ManualClock`-driven test calls this right after
    /// `clock.advance(by:)` so it observes the flush's fully-applied state
    /// instead of racing its async work.
    func waitForQuiescence() async {
        await debounceTask?.value
        await flushTask?.value
    }

    /// Test-only: the number of paths in the pending batch.
    var pendingEventCount: Int {
        pendingEvents.count
    }
}

// MARK: - FSEventsFileEventSource

/// Production `FileEventSource`, backed by the Core Services FSEvents API.
///
/// FSEvents is used instead of `DispatchSource`'s per-file-descriptor
/// monitoring because it is the only macOS API that can watch an entire
/// directory tree recursively from a single root path —
/// `DispatchSource.makeFileSystemObjectSource` requires one open file
/// descriptor per watched path with no built-in recursion, which doesn't
/// fit "FSEvents (recursive on rootDirectory)".
///
/// `@unchecked Sendable`: this class holds no stored state at all — every
/// `start(rootDirectory:handler:)` call builds its own `FSEventStreamContext`
/// box and stream locally — so there is nothing for concurrent callers to
/// race on.
public final class FSEventsFileEventSource: FileEventSource, @unchecked Sendable {
    /// The label of the dispatch queue that gets the FSEvents callbacks. It
    /// is the label of the watcher logger, so each name of the watcher starts
    /// with the module prefix.
    private static let eventQueueLabel = CodeContextTracing.LoggerLabel.watcher

    /// Creates an FSEvents-backed event source.
    public init() {}

    /// Starts an FSEvents stream watching `rootDirectory` recursively.
    ///
    /// - Parameters:
    ///   - rootDirectory: The directory to watch, recursively.
    ///   - handler: Called once per raw file-level event (directory-level
    ///     events are filtered out before `handler` is ever called).
    /// - Returns: A subscription whose `stop()` tears the stream down on a
    ///   detached background queue — FSEvents stream teardown can block for
    ///   seconds on macOS, so it must never run on the caller's queue.
    public func start(
        rootDirectory: URL,
        handler: @escaping @Sendable (RawFileEvent) async -> Void
    ) -> any FileEventSubscription {
        let box = FSEventsHandlerBox(handler: handler)
        let retainedBox = Unmanaged.passRetained(box)
        var context = FSEventStreamContext(
            version: 0,
            info: retainedBox.toOpaque(),
            retain: nil,
            release: { info in
                guard let info else {
                    return
                }
                Unmanaged<FSEventsHandlerBox>.fromOpaque(info).release()
            },
            copyDescription: nil
        )

        let pathsToWatch = [rootDirectory.path] as CFArray
        let flags =
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
            | FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
            | FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)

        guard
            let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                fsEventsTrampoline,
                &context,
                pathsToWatch,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.05,
                flags
            )
        else {
            // `retainedBox` was retained above for the stream to release
            // when it's torn down; with no stream ever created, that
            // release callback will never run, so release it here instead
            // to avoid leaking `box`.
            retainedBox.release()
            Log.watcher.error("FSEventStreamCreate could not make an event stream for the root directory")
            return FSEventsSubscription(stream: nil)
        }

        let queue = DispatchQueue(label: Self.eventQueueLabel)
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)

        return FSEventsSubscription(stream: stream)
    }
}

/// Boxes an `FSEventsFileEventSource` handler across the C callback
/// boundary; retained by `FSEventStreamContext.info` for the stream's
/// lifetime and released when the stream itself is released.
///
/// `@unchecked Sendable`: `handler` is a `let` set once at `init` and never
/// mutated afterward, so every access — from `fsEventsTrampoline`'s
/// `Task`, potentially on any thread FSEvents' dispatch queue runs on — is
/// a read of an already-immutable value, never a race.
private final class FSEventsHandlerBox: @unchecked Sendable {
    let handler: @Sendable (RawFileEvent) async -> Void

    init(handler: @escaping @Sendable (RawFileEvent) async -> Void) {
        self.handler = handler
    }
}

/// `FSEventsFileEventSource`'s subscription handle.
///
/// `@unchecked Sendable`: its only stored state is an immutable
/// `FSEventStreamRef` (an `OpaquePointer`, not itself `Sendable`), and
/// `stop()` only ever reads it to hand off to FSEvents' own teardown
/// functions, which are safe to call from any thread once the stream is no
/// longer in use — exactly the detached-teardown use below.
private final class FSEventsSubscription: FileEventSubscription, @unchecked Sendable {
    private let stream: FSEventStreamRef?

    init(stream: FSEventStreamRef?) {
        self.stream = stream
    }

    func stop() {
        guard let stream else {
            return
        }
        // Boxed rather than captured directly: `FSEventStreamRef` still
        // isn't `Sendable` even though this class asserts it, since the
        // closure below crosses onto a different queue.
        let box = UnsafeFSEventStreamBox(stream: stream)
        // Detached, not the caller's queue: FSEvents stream teardown
        // (`Invalidate`/`Release`) can block for seconds on macOS.
        DispatchQueue.global(qos: .utility).async {
            FSEventStreamStop(box.stream)
            FSEventStreamInvalidate(box.stream)
            FSEventStreamRelease(box.stream)
        }
    }
}

/// Boxes an `FSEventStreamRef` so it can cross into a `@Sendable` closure:
/// `OpaquePointer` itself isn't `Sendable`, but FSEvents' teardown
/// functions are safe to call from any thread once the stream is no longer
/// in use, which is exactly the detached-teardown use `FSEventsSubscription.stop()` needs.
private struct UnsafeFSEventStreamBox: @unchecked Sendable {
    let stream: FSEventStreamRef
}

/// The `FSEventStreamCallback` C function pointer FSEvents invokes with a
/// batch of raw events. Translates each file-level event (directory-level
/// events are dropped) into a `RawFileEvent` and delivers the batch, in
/// order, to the registered handler on a new `Task`.
private func fsEventsTrampoline(
    streamRef: ConstFSEventStreamRef,
    clientCallbackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let clientCallbackInfo else {
        return
    }
    let box = Unmanaged<FSEventsHandlerBox>.fromOpaque(clientCallbackInfo).takeUnretainedValue()
    guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else {
        return
    }

    var events: [RawFileEvent] = []
    events.reserveCapacity(numEvents)
    for index in 0..<numEvents {
        let flags = eventFlags[index]
        let isDirectory = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
        guard !isDirectory else {
            continue
        }
        let path = paths[index]
        events.append(RawFileEvent(url: URL(fileURLWithPath: path), kind: classifyFSEvent(flags: flags, path: path)))
    }

    guard !events.isEmpty else {
        return
    }
    Task {
        for event in events {
            await box.handler(event)
        }
    }
}

/// Classifies one FSEvents flag set into a `FileChangeKind`.
///
/// Disk existence at classification time — not the `ItemRenamed` flag,
/// which is ambiguous between a move-in and a move-away — is the ground
/// truth for removal. `Watcher.applyChange(relativePath:kind:)` then acts on
/// this classification directly (the last one recorded for a path within
/// its debounce window), rather than re-checking disk state itself.
private func classifyFSEvent(flags: FSEventStreamEventFlags, path: String) -> FileChangeKind {
    guard FileManager.default.fileExists(atPath: path) else {
        return .removed
    }
    if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated) != 0 {
        return .created
    }
    return .modified
}

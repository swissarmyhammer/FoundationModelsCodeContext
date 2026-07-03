import CoreServices
import CryptoKit
import Foundation

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
/// extension, not a hidden path segment — which also covers
/// `.code-context/` without a special case — and not matched by the
/// accumulated `.gitignore` rules along its path) is accumulated into a
/// per-path pending batch. Each new event restarts a `debounceInterval`
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
/// current content from disk to compute the hash `markDirty` records — if
/// that read fails (e.g. the file was removed again before this debounced
/// flush ran), the path is skipped and logged rather than treated as a
/// delete, so it stays dirty for a future indexing pass rather than losing
/// its history. `.removed` deletes the path (`Store.deleteFile`, cascading
/// to its chunks/symbols/edges) unconditionally — including when nothing
/// is indexed for it yet, which is a harmless no-op `DELETE`. The flush
/// ends with exactly one call to `nudgeWorkers`, regardless of how many
/// distinct paths were in the batch.
public actor Watcher {
    private let store: Store
    private let rootDirectory: URL
    private let eventSource: any FileEventSource
    private let clock: any Clock<Duration>
    private let debounceInterval: Duration
    private let nudgeWorkers: @Sendable () async -> Void
    private let allowedExtensions: Set<String>

    private var subscription: (any FileEventSubscription)?
    private var pendingEvents: [String: FileChangeKind] = [:]
    private var debounceTask: Task<Void, Never>?

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
    ///   - nudgeWorkers: Called once after each non-empty flush, so the
    ///     caller can wake its indexing workers to drain the newly dirtied
    ///     files.
    public init(
        store: Store,
        rootDirectory: URL,
        eventSource: any FileEventSource = FSEventsFileEventSource(),
        clock: any Clock<Duration> = ContinuousClock(),
        debounceInterval: Duration = .seconds(1),
        nudgeWorkers: @escaping @Sendable () async -> Void
    ) {
        self.store = store
        self.rootDirectory = rootDirectory
        self.eventSource = eventSource
        self.clock = clock
        self.debounceInterval = debounceInterval
        self.nudgeWorkers = nudgeWorkers
        allowedExtensions = Set(Languages.all.flatMap { languageModule in languageModule.fileExtensions.map { $0.lowercased() } })
    }

    /// Starts watching, if not already started.
    ///
    /// Safe to call more than once; a second call while already watching is
    /// a no-op.
    public func start() {
        guard subscription == nil else {
            return
        }
        subscription = eventSource.start(rootDirectory: rootDirectory) { [weak self] event in
            await self?.handleRawEvent(event)
        }
    }

    /// Stops watching and discards any not-yet-flushed pending batch.
    ///
    /// Safe to call more than once, and safe to call without a prior
    /// `start()`.
    public func stop() {
        subscription?.stop()
        subscription = nil
        debounceTask?.cancel()
        debounceTask = nil
        pendingEvents.removeAll()
    }

    deinit {
        subscription?.stop()
        debounceTask?.cancel()
    }

    // MARK: - Event handling

    private func handleRawEvent(_ event: RawFileEvent) async {
        guard let relativePath = acceptedRelativePath(for: event.url) else {
            return
        }
        pendingEvents[relativePath] = event.kind
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
            await self?.flushPendingEvents()
        }
    }

    /// Applies every path in the current pending batch, then nudges the
    /// indexing workers exactly once.
    private func flushPendingEvents() async {
        guard !pendingEvents.isEmpty else {
            return
        }
        let batch = pendingEvents
        pendingEvents.removeAll()

        for (relativePath, kind) in batch {
            await applyChange(relativePath: relativePath, kind: kind)
        }

        await nudgeWorkers()
    }

    /// Applies one path's coalesced change, per its last-recorded `kind` in
    /// the batch: `.removed` deletes its `indexed_files` row; `.created`/
    /// `.modified` marks it dirty across all layers.
    private func applyChange(relativePath: String, kind: FileChangeKind) async {
        guard kind != .removed else {
            do {
                try await store.deleteFile(filePath: relativePath)
            } catch {
                Log.watcher.warning(
                    "failed to delete \(relativePath, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
            return
        }

        let fileURL = rootDirectory.appendingPathComponent(relativePath)
        guard let hashed = Self.hashFile(at: fileURL, relativePath: relativePath) else {
            // The file was removed again (or replaced by something
            // unreadable) between the triggering event and this debounced
            // flush; leave it as-is rather than guessing — a later event
            // (or a future reconcile pass) will resolve it.
            Log.watcher.warning("failed to read \(relativePath, privacy: .public); skipping this flush")
            return
        }
        do {
            try await store.markDirty(filePath: hashed.relativePath, contentHash: hashed.contentHash, fileSize: hashed.fileSize)
        } catch {
            Log.watcher.warning(
                "failed to mark \(relativePath, privacy: .public) dirty: \(String(describing: error), privacy: .public)"
            )
        }
    }

    // MARK: - Filtering

    /// Returns `url`'s workspace-relative path if it should be tracked, or
    /// `nil` otherwise.
    ///
    /// Requires all of: under `rootDirectory`, a known `Languages.all`
    /// extension, no hidden path segment (which also covers
    /// `.code-context/` without a special case, matching `Walker`'s own
    /// hidden-entry skip), and no match against the accumulated
    /// `.gitignore` rules along the path.
    private func acceptedRelativePath(for url: URL) -> String? {
        guard let relativePath = RelativePath.of(url, relativeTo: rootDirectory) else {
            return nil
        }
        guard allowedExtensions.contains(url.pathExtension.lowercased()) else {
            return nil
        }
        guard !relativePath.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else {
            return nil
        }
        guard !isIgnored(url) else {
            return nil
        }
        return relativePath
    }

    /// Whether `url` is excluded by the `.gitignore` rules accumulated from
    /// `rootDirectory` down to `url`'s containing directory.
    ///
    /// Rebuilt fresh on every call rather than cached: watcher events are
    /// infrequent relative to the cost of re-reading a handful of
    /// `.gitignore` files, and rebuilding avoids having to invalidate a
    /// cache when a `.gitignore` file itself changes.
    private func isIgnored(_ url: URL) -> Bool {
        guard let directories = intermediateDirectories(to: url) else {
            return false
        }
        var stack = GitignoreStack()
        for directory in directories {
            stack = stack.appending(gitignoreAt: directory)
        }
        return stack.isIgnored(url, isDirectory: false)
    }

    /// `rootDirectory`, then each directory on the path down to (but not
    /// including) `url` itself, for `isIgnored(_:)` to accumulate
    /// `.gitignore` rules through.
    private func intermediateDirectories(to url: URL) -> [URL]? {
        guard let relativePath = RelativePath.of(url, relativeTo: rootDirectory) else {
            return nil
        }
        var directories = [rootDirectory]
        var current = rootDirectory
        let parentComponents = relativePath.split(separator: "/").dropLast()
        for component in parentComponents {
            current = current.appendingPathComponent(String(component))
            directories.append(current)
        }
        return directories
    }

    /// Reads `fileURL` and computes its `HashedFile` the same way `Walker`
    /// does (SHA-256, truncated to 16 bytes), so `Store.markDirty`'s
    /// `content_hash` argument matches what a full reconcile pass would
    /// compute for the same content. `Walker`'s own hashing helper is
    /// `private`, so this is a small, deliberate re-implementation rather
    /// than a shared call.
    ///
    /// - Returns: `nil` if `fileURL` can no longer be read (e.g. deleted or
    ///   replaced between the triggering event and this debounced flush).
    private static func hashFile(at fileURL: URL, relativePath: String) -> HashedFile? {
        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        let digest = SHA256.hash(data: data)
        return HashedFile(relativePath: relativePath, contentHash: Data(digest.prefix(16)), fileSize: Int64(data.count))
    }

    // MARK: - Testing

    /// Test-only synchronization hook: awaits completion of the currently
    /// in-flight debounce timer/flush cycle, if any.
    ///
    /// A `ManualClock`-driven test calls this right after
    /// `clock.advance(by:)` so it observes the flush's fully-applied state
    /// instead of racing its async work.
    func waitForQuiescence() async {
        await debounceTask?.value
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
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
            | FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
            | FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            fsEventsTrampoline,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.05,
            flags
        ) else {
            // `retainedBox` was retained above for the stream to release
            // when it's torn down; with no stream ever created, that
            // release callback will never run, so release it here instead
            // to avoid leaking `box`.
            retainedBox.release()
            Log.watcher.error("FSEventStreamCreate failed for \(rootDirectory.path, privacy: .public)")
            return FSEventsSubscription(stream: nil)
        }

        let queue = DispatchQueue(label: "\(Log.subsystem).watcher")
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
    clientCallBackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let clientCallBackInfo else {
        return
    }
    let box = Unmanaged<FSEventsHandlerBox>.fromOpaque(clientCallBackInfo).takeUnretainedValue()
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

import CodeContextKit
import Foundation

/// A `FileEventSource` test double that lets a test synchronously drive
/// synthetic filesystem events into a `Watcher` without touching the real
/// FSEvents API.
///
/// `emit(_:)` awaits the registered handler directly, so by the time it
/// returns, `Watcher` has fully processed the event (its pending batch
/// updated and its debounce timer (re)started) — no race between emitting
/// an event and later driving a `ManualClock` forward.
///
/// `@unchecked Sendable`: its only mutable state lives in `box.handler`,
/// which is set once by `start(rootDirectory:handler:)` during test setup
/// and only read afterward by `emit(_:)` — a test never calls `start`
/// concurrently with `emit`, so there is no concurrent mutation to guard.
final class FakeFileEventSource: FileEventSource, @unchecked Sendable {
    private let box = FakeFileEventHandlerBox()

    /// Creates a fake event source with no handler registered yet.
    init() {}

    /// Stores `handler` for later delivery via `emit(_:)`.
    ///
    /// Unlike `FSEventsFileEventSource`, this test double never starts a
    /// real filesystem event stream — `rootDirectory` is accepted only to
    /// satisfy the `FileEventSource` protocol and is otherwise unused.
    func start(
        rootDirectory: URL,
        handler: @escaping @Sendable (RawFileEvent) async -> Void
    ) -> any FileEventSubscription {
        box.handler = handler
        return FakeFileEventSubscription(box: box)
    }

    /// Delivers `event` to the currently registered handler and awaits its
    /// completion.
    ///
    /// - Parameter event: The synthetic filesystem event to deliver.
    func emit(_ event: RawFileEvent) async {
        await box.handler?(event)
    }
}

/// Boxes `FakeFileEventSource`'s registered handler so a
/// `FakeFileEventSubscription`'s `stop()` can clear it without needing a
/// back-reference to the (non-final-until-`stop`) source itself.
///
/// `@unchecked Sendable`: `handler` is mutated only by `start(rootDirectory:
/// handler:)` (assignment) and `stop()` (clearing to `nil`), and read only by
/// `emit(_:)` — a test drives these strictly sequentially (set up, emit
/// zero or more events, tear down), never from concurrent tasks.
private final class FakeFileEventHandlerBox: @unchecked Sendable {
    var handler: (@Sendable (RawFileEvent) async -> Void)?
}

/// `FakeFileEventSource`'s subscription handle: `stop()` clears the boxed
/// handler so no further `emit(_:)` calls are delivered.
private struct FakeFileEventSubscription: FileEventSubscription {
    let box: FakeFileEventHandlerBox

    func stop() {
        box.handler = nil
    }
}

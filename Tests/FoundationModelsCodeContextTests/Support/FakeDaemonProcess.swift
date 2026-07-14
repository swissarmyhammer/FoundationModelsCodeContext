import Foundation

@testable import FoundationModelsCodeContext

/// A single mutable value shared between a test and a `@Sendable` closure (e.g. a `ConnectionFactory`
/// or a test-only hook). Plain captured `var`s can't be mutated or read from inside `@Sendable`
/// closures that cross an actor boundary; this actor-isolates the box instead. Shared by
/// `LSPDaemonTests` and `LspSupervisorTests`.
actor Box<Value: Sendable> {
    /// The boxed value.
    var value: Value

    /// Creates a box holding `value`.
    /// - Parameter value: The initial boxed value.
    init(_ value: Value) { self.value = value }

    /// Replaces the boxed value.
    /// - Parameter newValue: The value to store.
    func set(_ newValue: Value) { value = newValue }
}

/// An actor-isolated counter for tests to verify how many times an operation ran, without racing
/// on a plain `var` from concurrent `@Sendable` closures. Shared by `LSPDaemonTests` and
/// `LspSupervisorTests`.
actor Counter {
    /// The current count.
    private(set) var value = 0

    /// Increments the count and returns the new value.
    /// - Returns: The count after incrementing.
    @discardableResult
    func increment() -> Int {
        value += 1
        return value
    }
}

/// Tracks the liveness of one fake "process" for a `ConnectionFactory` to read/drive: whether
/// it's alive, how many times it has been force-terminated, and whether `waitForExit()` should
/// resolve immediately (a cooperative process) or hang until cancelled (an unresponsive one the
/// daemon/supervisor must kill after a grace period). Shared by `LSPDaemonTests` and
/// `LspSupervisorTests` so both drive `LSPDaemon`'s process-level hooks
/// (`isAlive`/`waitForExit`/`terminate`) through one fixture instead of two near-identical copies.
actor ProcessState {
    /// Whether the fake process currently reports itself alive.
    private(set) var isAlive = true

    /// How many times `markTerminated()` has been called.
    private(set) var terminateCount = 0

    /// Whether `waitForExit()` hangs until cancelled instead of resolving immediately.
    private var hangsOnWaitForExit = false

    /// Configures whether `waitForExit()` hangs until cancelled instead of resolving immediately.
    /// - Parameter hangs: `true` to simulate an unresponsive process; `false` (the default at
    ///   construction) to simulate a cooperative one.
    func setHangsOnWaitForExit(_ hangs: Bool) {
        hangsOnWaitForExit = hangs
    }

    /// Sets whether the fake process is currently alive.
    /// - Parameter alive: `true` if the process should report itself alive; `false` to simulate a
    ///   crash or exit.
    func setAlive(_ alive: Bool) {
        isAlive = alive
    }

    /// Records a forced termination, as `LSPDaemon` would trigger after an unresponsive shutdown or
    /// a handshake timeout.
    func markTerminated() {
        terminateCount += 1
        isAlive = false
    }

    /// Simulates waiting for the process to exit on its own: resolves immediately unless
    /// `setHangsOnWaitForExit(true)` was called, in which case it only resolves via cancellation.
    func waitForExit() async {
        guard hangsOnWaitForExit else {
            isAlive = false
            return
        }
        // Simulate an unresponsive process: this only ever returns via cancellation, which
        // `LSPDaemon.shutdown()` triggers once the grace-period sleep wins the race. Real
        // wall-clock duration is irrelevant here since it is always cancelled almost immediately
        // in a passing test — only the manually-driven clock controls timing.
        try? await Task.sleep(for: .seconds(3600))
    }
}

/// Builds a `ConnectionFactory` that hands back a fresh `FakeLanguageServerConnection` on every
/// call, wired to `processState` for its `isAlive`/`waitForExit`/`terminate` hooks. Shared by
/// `LSPDaemonTests` and `LspSupervisorTests`.
/// - Parameters:
///   - pid: The pid to report via the returned handle.
///   - processState: The shared liveness tracker the daemon's health/shutdown hooks read.
///   - configureConnection: Called with each freshly created connection before it's handed back,
///     so a test can script a failure result on it. Defaults to no configuration.
func fakeConnectionFactory(
    pid: Int32,
    processState: ProcessState,
    configureConnection: @escaping @Sendable (FakeLanguageServerConnection) async -> Void = { _ in }
) -> ConnectionFactory<FakeLanguageServerConnection> {
    { _, _ in
        let connection = FakeLanguageServerConnection()
        await configureConnection(connection)
        return ConnectionHandle(
            connection: connection,
            pid: pid,
            isAlive: { await processState.isAlive },
            waitForExit: { await processState.waitForExit() },
            terminate: { await processState.markTerminated() }
        )
    }
}

/// A gate that suspends each async caller of `waitUntilOpen()` while the gate
/// is closed, until a test calls `open()`.
///
/// The gate keeps each waiter, thus two or more callers can wait at the same
/// time, and `open()` resumes them all. A caller that comes while the gate is
/// open does not wait. `close()` closes the gate again for the next callers.
///
/// A waiter suspends on a bare `CheckedContinuation` with no cancellation
/// handler: unlike `ManualClock.sleep`, a cancel of the waiting task does not
/// stop `waitUntilOpen()`. Thus a test can model an in-flight call that a
/// cancel alone cannot stop. A test uses the gate in a hook or a method of a
/// fake connection, to keep a request in flight while a second operation
/// starts.
actor AsyncGate {
    /// Whether `waitUntilOpen()` returns at once.
    private var isOpen: Bool

    /// The suspended callers of `waitUntilOpen()`.
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Makes a gate.
    /// - Parameter isOpen: Whether the gate starts open. Defaults to `false`.
    init(isOpen: Bool = false) {
        self.isOpen = isOpen
    }

    /// Suspends until the gate is open, and returns at once when it is open.
    func waitUntilOpen() async {
        guard !isOpen else {
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Closes the gate, thus the next calls of `waitUntilOpen()` suspend until
    /// `open()`.
    func close() {
        isOpen = false
    }

    /// Opens the gate and resumes each suspended caller.
    func open() {
        isOpen = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }
}

/// A gate that suspends each async caller of `waitUntilOpen()` until a test
/// calls `open()`.
///
/// The gate starts closed. It keeps each waiter, thus two or more callers can
/// wait at the same time, and `open()` resumes them all. A caller that comes
/// after `open()` does not wait. A test uses the gate in a hook of a fake
/// connection, to keep a request in flight while a second operation starts.
actor AsyncGate {
    /// Whether `waitUntilOpen()` returns at once.
    private var isOpen = false

    /// The suspended callers of `waitUntilOpen()`.
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Suspends until the gate is open, and returns at once when it is open.
    func waitUntilOpen() async {
        guard !isOpen else {
            return
        }
        await withCheckedContinuation { waiters.append($0) }
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

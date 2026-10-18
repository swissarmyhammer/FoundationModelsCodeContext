extension Clock where Duration == Swift.Duration {
    /// Runs `operation`, and returns when `operation` finishes or when `limit` elapses on this
    /// clock. The first to finish wins, and the other is cancelled.
    ///
    /// The function returns only after the cancelled side also ends. Thus `operation` must stop
    /// at a cancel (see `CancellableWaiters`), or the function waits for it to finish.
    /// - Parameters:
    ///   - limit: The longest time to wait for `operation`.
    ///   - operation: The work to wait for.
    /// - Returns: `true` when `operation` finished before `limit` elapsed, `false` when the limit
    ///   elapsed first.
    @discardableResult
    func waitForCompletion(
        atMost limit: Swift.Duration,
        _ operation: @escaping @Sendable () async -> Void
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await operation()
                return true
            }
            group.addTask {
                try? await self.sleep(for: limit)
                return false
            }
            let operationFinishedFirst = await group.next() ?? false
            group.cancelAll()
            return operationFinishedFirst
        }
    }
}

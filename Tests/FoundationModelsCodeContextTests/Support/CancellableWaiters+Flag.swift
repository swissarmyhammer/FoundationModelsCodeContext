@testable import FoundationModelsCodeContext

/// The `Bool` waiters of the tests. `CancellableWaitersTests` and `ClockWaitForCompletionTests`
/// both use this one helper.
extension CancellableWaiters where State == Bool {
    /// Makes waiters whose state satisfies a wait when the state is `true`.
    /// - Parameter isSet: The initial state.
    /// - Returns: The waiters.
    static func flag(isSet: Bool) -> CancellableWaiters<Bool> {
        CancellableWaiters(isSet) { isSet in isSet }
    }
}

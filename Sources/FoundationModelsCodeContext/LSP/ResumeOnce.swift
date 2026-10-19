import Foundation

/// Guards a single `CheckedContinuation` so it is resumed at most once, even when multiple
/// independent completion paths race to resolve it concurrently.
///
/// `PendingRequestTable` wraps every registered continuation in one of these, keyed by JSON-RPC
/// request id, because a request's real response (`resolveOrBuffer(id:response:)`) and its
/// timeout (`timeOut(id:with:)`) can both fire for the same id.
///
/// `@unchecked Sendable` is safe because every access goes through `lock`.
final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var hasResumed = false
    private let continuation: CheckedContinuation<Value, Error>

    /// Creates a guard wrapping `continuation`.
    /// - Parameter continuation: The continuation to resume at most once.
    init(continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    /// Resumes the wrapped continuation with `result`, unless it has already been resumed.
    /// - Parameter result: The result to resume with.
    /// - Returns: `true` if this call actually performed the resume; `false` if the continuation
    ///   had already been resumed by an earlier call, in which case `result` is discarded.
    @discardableResult
    func resume(with result: Result<Value, Error>) -> Bool {
        lock.lock()
        guard !hasResumed else {
            lock.unlock()
            return false
        }
        hasResumed = true
        lock.unlock()
        continuation.resume(with: result)
        return true
    }

    /// Resumes the wrapped continuation with `value`, unless it has already been resumed.
    /// - Parameter value: The value to resume with.
    func resume(returning value: Value) {
        resume(with: .success(value))
    }

    /// Resumes the wrapped continuation by throwing `error`, unless it has already been resumed.
    /// - Parameter error: The error to resume with.
    func resume(throwing error: Error) {
        resume(with: .failure(error))
    }
}

import Foundation

/// Errors surfaced by CodeContextKit's language-server lifecycle, storage,
/// and embedding subsystems.
///
/// Associated data is limited to `Sendable` primitives (`String`,
/// `Duration`) rather than wrapping arbitrary underlying `Error` values —
/// callers that need the original error should capture its
/// `localizedDescription` into the associated `String` at the call site.
/// This keeps `CodeContextError` unconditionally `Sendable`, so it can cross
/// actor boundaries (e.g. out of the `CodeContext` actor or an LSP session
/// actor) without extra ceremony.
public enum CodeContextError: Error, Sendable {
    /// The language-server binary was not found on `$PATH`.
    case binaryNotFound(command: String, installHint: String)

    /// Spawning the language-server process failed.
    case spawnFailed(String)

    /// The LSP `initialize` handshake did not complete successfully.
    case handshakeFailed(String)

    /// An operation exceeded its allotted time budget.
    case timeout(Duration)

    /// An operation was attempted on a server or session that is not running.
    case notRunning

    /// A storage-layer (SQLite/GRDB) operation failed.
    case storage(String)

    /// An embedding-layer operation failed.
    case embedding(String)
}

extension CodeContextError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .binaryNotFound(command, installHint):
            "binary not found: \(command) (\(installHint))"
        case let .spawnFailed(reason):
            "failed to spawn language server: \(reason)"
        case let .handshakeFailed(reason):
            "initialize handshake failed: \(reason)"
        case let .timeout(duration):
            "operation timed out after \(duration)"
        case .notRunning:
            "server not running"
        case let .storage(reason):
            "storage error: \(reason)"
        case let .embedding(reason):
            "embedding error: \(reason)"
        }
    }
}

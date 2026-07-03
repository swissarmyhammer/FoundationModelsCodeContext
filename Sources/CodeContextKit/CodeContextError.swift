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

    /// A tree-sitter AST query operation failed.
    ///
    /// Covers an unregistered language, a language with no tree-sitter
    /// grammar, and a query that failed to compile.
    case query(String)

    /// A `grepCode` regular-expression pattern failed to compile.
    case pattern(String)

    /// A requested symbol, file, or other named resource could not be
    /// resolved.
    ///
    /// Covers `CallGraphOps.callGraph(store:of:direction:maxDepth:)`'s
    /// unresolvable start symbol and
    /// `BlastRadiusOps.blastRadius(store:file:symbol:maxHops:)`'s
    /// named-symbol-not-in-file miss.
    case notFound(String)
}

extension CodeContextError: LocalizedError {
    /// A human-readable description of the error, suitable for logging or surfacing to a caller.
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
        case let .query(reason):
            "query error: \(reason)"
        case let .pattern(reason):
            "pattern error: \(reason)"
        case let .notFound(reason):
            "not found: \(reason)"
        }
    }
}

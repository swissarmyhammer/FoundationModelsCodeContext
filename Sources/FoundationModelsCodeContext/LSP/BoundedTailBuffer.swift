import Foundation

/// Thread-safe bounded tail of a stream of text chunks.
///
/// Shared by two call sites that each drain a child process's output outside actor isolation and
/// need to retain only the most recent chunks, bounding memory while still giving their
/// respective failure-reporting paths enough context to diagnose what happened:
/// - `ProcessLanguageServerConnection`'s `stderrTailBuffer` (a language server's stderr, capped at
///   20 chunks) feeds `recentStderrTail()`, which enriches a handshake-failure error with whatever
///   the server printed before it died.
/// - `ProcessInstallRunner`'s tail buffer (`ServerInstaller.swift`; an installer's combined
///   stdout+stderr, capped at 40 chunks) feeds `ServerInstaller`'s failure log.
///
/// A plain `NSLock`-guarded class rather than actor state: both call sites append from a background
/// drain loop that runs outside actor isolation by design (see `ProcessLanguageServerConnection
/// .runStderrDrainLoop`'s doc comment), and must be readable synchronously — without an actor hop
/// — from code that often can't `await` (e.g. from inside a `catch` that's already off the actor).
/// `@unchecked Sendable` is safe because every access goes through `lock`.
final class BoundedTailBuffer: @unchecked Sendable {
    private let maxChunks: Int

    private let lock = NSLock()
    private var chunks: [String] = []

    /// Creates a bounded tail buffer.
    /// - Parameter maxChunks: The number of most-recent chunks retained; older chunks are dropped.
    init(maxChunks: Int) {
        self.maxChunks = maxChunks
    }

    /// Appends one output chunk, evicting the oldest chunk(s) if the buffer is now over capacity.
    /// - Parameter chunk: The raw text read from the process's stdout/stderr pipe.
    func append(chunk: String) {
        lock.lock()
        defer { lock.unlock() }
        chunks.append(chunk)
        if chunks.count > maxChunks {
            chunks.removeFirst(chunks.count - maxChunks)
        }
    }

    /// A snapshot of every retained chunk, oldest first.
    /// - Returns: The retained output chunks joined together, or an empty string if none have been
    ///   captured yet.
    func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return chunks.joined()
    }
}

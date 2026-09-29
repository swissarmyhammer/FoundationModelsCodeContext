import Darwin
import Foundation

/// Shared low-level POSIX process-I/O helpers used by both `ProcessLanguageServerConnection` and
/// `ProcessInstallRunner` (`ServerInstaller.swift`) to read from a child process's pipe file
/// descriptors.
enum ProcessUtilities {
    /// The `env(1)` path both `ProcessLanguageServerConnection` and `ProcessInstallRunner` spawn
    /// through to resolve a bare executable name (e.g. `"rust-analyzer"`, `"npm"`) against
    /// `$PATH`, exactly as a shell would, without either caller pre-resolving a full path itself.
    static let envExecutablePath = "/usr/bin/env"

    /// The chunk size both background drain loops (`ProcessLanguageServerConnection`'s reader and
    /// stderr loops, `ProcessInstallRunner`'s combined-output loop) request by default from
    /// `readChunk(from:bufferSize:)` / `drainChunks(from:bufferSize:onChunk:)` — large enough that
    /// a single framed JSON-RPC message or one line of installer output almost always arrives in
    /// one read, without requesting an unboundedly large buffer from the OS.
    static let defaultChunkSize = 65536

    /// Runs `body` on a new dedicated thread, and gives a task that completes when `body` returns.
    ///
    /// Use this, not `Task.detached`, for a loop that blocks in `read(2)` until a child process
    /// closes its pipe. A blocked `read(2)` holds its thread. A thread of the Swift cooperative
    /// pool is one of a small number of threads (one for each processor core). When the blocked
    /// loops hold all of these threads, no task of the process can run: a request timeout, a
    /// `close()` that kills the child and a test all stop, and the process hangs with no output.
    /// Each `ProcessLanguageServerConnection` has two such loops, so a small number of open
    /// connections is sufficient to fill the pool on a machine with few cores. A dedicated thread
    /// is not in the pool, and the returned task only suspends, so it holds no pool thread.
    /// - Parameters:
    ///   - name: The name of the thread, for a debugger or a crash report.
    ///   - body: The blocking work. It runs one time.
    /// - Returns: A task that completes when `body` returns. Cancelling the task does not stop
    ///   `body`; close the pipe or stop the child process to stop it.
    internal static func runOnDedicatedThread(name: String, _ body: @escaping @Sendable () -> Void) -> Task<Void, Never> {
        Task {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let thread = Thread {
                    body()
                    continuation.resume()
                }
                thread.name = name
                thread.start()
            }
        }
    }

    /// Reads whatever is currently available from `fileDescriptor`, up to `bufferSize` bytes.
    ///
    /// Issues a single raw POSIX `read(2)` call on the raw file descriptor rather than going
    /// through any `FileHandle` method, for two reasons neither of which alone is sufficient:
    /// `FileHandle.availableData` raises an Objective-C exception (uncatchable in Swift, crashing
    /// the process) when the handle is closed concurrently with a blocked read, and even
    /// `FileHandle`'s own `.fileDescriptor` property getter raises the same kind of exception once
    /// the handle has been closed — both exactly what happens when a caller's `close()` closes a
    /// pipe while a background drain loop is mid-read. The newer throwing
    /// `FileHandle.read(upToCount:)` avoids the exception but loops internally trying to fill the
    /// full requested count (or reach EOF) rather than returning as soon as any data is available,
    /// so it can block indefinitely against a live process that has written less than `bufferSize`
    /// bytes and has nothing further to send yet. Working from a raw file descriptor captured once
    /// up front (by both callers, before any background loop starts) sidesteps both problems: a
    /// single `read(2)` call returns as soon as any data is ready, matching `availableData`'s
    /// responsiveness, and reports failure as a plain `-1`/`errno` rather than an exception, even
    /// once the underlying descriptor has been closed out from under it.
    ///
    /// A `read(2)` interrupted by a signal (`EINTR`) before transferring any data is not EOF and
    /// not a real failure — POSIX requires the caller to retry. Under load this is not just a
    /// theoretical nicety: with several background loops each blocked in `read(2)`, plus the many
    /// child processes those loops' owners spawn and reap, `SIGCHLD` delivery becomes frequent
    /// enough to interrupt an in-flight read. Treating that the same as EOF (as a bare
    /// `bytesRead > 0` check does) would end the caller's loop against a process that is still
    /// very much alive.
    /// - Parameters:
    ///   - fileDescriptor: The pipe read end's raw file descriptor.
    ///   - bufferSize: The maximum number of bytes to read in one call.
    /// - Returns: The bytes read, or `nil` at EOF (`read` returns `0`) or on a genuine error
    ///   (`read` returns `-1` with `errno != EINTR`, e.g. because the descriptor was closed
    ///   concurrently) — both end the caller's loop.
    static func readChunk(from fileDescriptor: Int32, bufferSize: Int) -> Data? {
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while true {
            errno = 0
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                return read(fileDescriptor, baseAddress, bufferSize)
            }
            if bytesRead > 0 {
                return Data(buffer[0..<bytesRead])
            }
            if bytesRead < 0, errno == EINTR {
                continue
            }
            return nil
        }
    }

    /// Reads `fileDescriptor` until EOF, decoding each raw chunk from `readChunk(from:bufferSize:)`
    /// as UTF-8 and invoking `onChunk` for every successfully decoded, non-empty chunk, in order.
    ///
    /// Factors out the read-decode-append *loop* shared by `ProcessLanguageServerConnection`'s
    /// `runStderrDrainLoop` and `ProcessInstallRunner`'s `drainOutput`: both looped on `readChunk`
    /// until EOF, decoded each chunk as UTF-8, and forwarded it somewhere (a log plus a tail
    /// buffer, vs. a tail buffer alone) — this is that shared loop, parameterized over what a
    /// caller does with each decoded chunk, so the loop itself exists in exactly one place instead
    /// of once per caller. A chunk that fails to decode as UTF-8, or decodes empty, is silently
    /// skipped rather than passed to `onChunk` — both callers already treated that as a no-op.
    /// - Parameters:
    ///   - fileDescriptor: The pipe read end's raw file descriptor.
    ///   - bufferSize: The maximum number of bytes to read in one `read(2)` call. Defaults to
    ///     `defaultChunkSize`.
    ///   - onChunk: Invoked, in order, with each decoded non-empty chunk read before EOF.
    static func drainChunks(from fileDescriptor: Int32, bufferSize: Int = defaultChunkSize, onChunk: (String) -> Void) {
        while let chunk = readChunk(from: fileDescriptor, bufferSize: bufferSize) {
            if let text = String(data: chunk, encoding: .utf8), !text.isEmpty {
                onChunk(text)
            }
        }
    }
}

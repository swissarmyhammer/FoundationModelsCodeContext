import Darwin
import Foundation

/// Shared low-level POSIX process-I/O helpers used by both `ProcessLanguageServerConnection` and
/// `ProcessInstallRunner` (`ServerInstaller.swift`) to read from a child process's pipe file
/// descriptors.
enum ProcessUtilities {
    /// Reads whatever is currently available from `fileDescriptor`, up to `bufferSize` bytes.
    ///
    /// Issues a single raw POSIX `read(2)` call on the raw file descriptor rather than going
    /// through any `FileHandle` method, for two reasons neither of which alone is sufficient:
    /// `FileHandle.availableData` raises an Objective-C exception (uncatchable in Swift, crashing
    /// the process) when the handle is closed concurrently with a blocked read, and even
    /// `FileHandle`'s own `.fileDescriptor` property getter raises the same kind of exception once
    /// the handle has been closed — both exactly what happens when a caller's `close()` closes a
    /// pipe while a detached drain loop is mid-read. The newer throwing
    /// `FileHandle.read(upToCount:)` avoids the exception but loops internally trying to fill the
    /// full requested count (or reach EOF) rather than returning as soon as any data is available,
    /// so it can block indefinitely against a live process that has written less than `bufferSize`
    /// bytes and has nothing further to send yet. Working from a raw file descriptor captured once
    /// up front (by both callers, before any detached loop starts) sidesteps both problems: a
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
}

import Darwin
import Foundation

/// Shared low-level POSIX process helpers. `GitShell` (`DiagnosticsScope.swift`) makes each
/// child process with `makeChildProcess`. `ProcessLanguageServerConnection` starts each language
/// server, and `ProcessInstallRunner` (`ServerInstaller.swift`) starts each installer, with
/// `ProcessGroupChild.spawn`, which puts the child in its own process group and keeps the same
/// standard-stream rule. The connection and the install runner read the pipe file descriptors
/// of the child with the read helpers.
enum ProcessUtilities {
    /// The `env(1)` path both `ProcessLanguageServerConnection` and `ProcessInstallRunner` spawn
    /// through to resolve a bare executable name (e.g. `"rust-analyzer"`, `"npm"`) against
    /// `$PATH`, exactly as a shell would, without either caller pre-resolving a full path itself.
    static let envExecutablePath = "/usr/bin/env"

    /// The standard input that a child process gets from `makeChildProcess` or from
    /// `ProcessGroupChild.spawn`.
    enum StandardInput {
        /// The null device. A child that reads it gets the end of the file at once. Use it for
        /// each child that does not need input from this process.
        case nullDevice

        /// A pipe that the caller owns and writes to, for example the JSON-RPC channel to a
        /// language server.
        case pipe(Pipe)
    }

    /// Makes a child process that shares no standard stream with this process.
    ///
    /// Foundation `Process` gives the child the stream of this process for each stream that the
    /// caller does not set. The host of this library can use its own standard input and standard
    /// output for a protocol (ACP, or MCP over stdio). A child that reads the standard input of
    /// the host takes bytes of that protocol, and the session of the host stops. A child that
    /// writes to the standard output of the host puts bytes into that protocol. Thus this
    /// function sets all three streams, and each caller must give each of them.
    /// - Parameters:
    ///   - executableURL: The executable that the process runs.
    ///   - arguments: The arguments of the executable.
    ///   - standardInput: The standard input of the child: the null device, or a pipe that the
    ///     caller owns.
    ///   - standardOutput: The pipe that gets the standard output of the child.
    ///   - standardError: The pipe that gets the standard error of the child. It can be the same
    ///     pipe as `standardOutput`.
    /// - Returns: The process, not yet started. The caller sets other properties and calls
    ///   `run()`.
    static func makeChildProcess(
        executableURL: URL,
        arguments: [String],
        standardInput: StandardInput,
        standardOutput: Pipe,
        standardError: Pipe
    ) -> Process {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        switch standardInput {
        case .nullDevice:
            process.standardInput = FileHandle.nullDevice
        case .pipe(let pipe):
            process.standardInput = pipe
        }
        process.standardOutput = standardOutput
        process.standardError = standardError
        return process
    }

    /// The chunk size both background drain loops (`ProcessLanguageServerConnection`'s reader and
    /// stderr loops, `ProcessInstallRunner`'s combined-output loop) request by default from
    /// `readChunk(from:bufferSize:)` / `drainChunks(from:bufferSize:onChunk:)` — large enough that
    /// a single framed JSON-RPC message or one line of installer output almost always arrives in
    /// one read, without requesting an unboundedly large buffer from the OS.
    static let defaultChunkSize = 65536

    /// Runs `body` on a new dedicated thread, and gives a task that completes with the value of
    /// `body` when `body` returns.
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
    /// - Returns: A task that completes with the value of `body` when `body` returns. Cancelling
    ///   the task does not stop `body`; close the pipe or stop the child process to stop it.
    internal static func runOnDedicatedThread<Value: Sendable>(
        name: String,
        _ body: @escaping @Sendable () -> Value
    ) -> Task<Value, Never> {
        Task {
            await withCheckedContinuation { (continuation: CheckedContinuation<Value, Never>) in
                let thread = Thread {
                    continuation.resume(returning: body())
                }
                thread.name = name
                thread.start()
            }
        }
    }

    /// Runs `body` on a new dedicated thread (see `runOnDedicatedThread(name:_:)`) with the file
    /// descriptor of `readEnd`, and closes `readEnd` after `body` returns.
    ///
    /// Use this for each loop that reads a pipe of a child process. The loop is the one owner of
    /// the read end, and no other code may close it. A closed descriptor frees its number, and
    /// the next pipe that this process opens gets the lowest free number, thus most often that
    /// same number. A loop whose read end other code closed, and that then calls `read(2)` one
    /// more time, reads the pipe of another child: it takes the bytes of that child, and the
    /// owner of that pipe never gets them. The loop can be between two reads at the time of the
    /// close, and on a busy machine its thread can even start after the close. So the read end
    /// stays open until `body` returns, and the loop then closes it. `body` ends at the end of
    /// the file, when each process that holds the write end exited.
    /// - Parameters:
    ///   - name: The name of the thread, for a debugger or a crash report.
    ///   - readEnd: The read end of the pipe. The loop owns it from this call on.
    ///   - body: The read loop. It gets the descriptor of `readEnd`, and it runs one time.
    /// - Returns: A task that completes with the value of `body` after `body` returns and the
    ///   loop closed `readEnd`.
    internal static func runReadLoop<Value: Sendable>(
        name: String,
        readEnd: FileHandle,
        _ body: @escaping @Sendable (Int32) -> Value
    ) -> Task<Value, Never> {
        let fileDescriptor = readEnd.fileDescriptor
        return runOnDedicatedThread(name: name) {
            let value = body(fileDescriptor)
            try? readEnd.close()
            return value
        }
    }

    /// Reads whatever is currently available from `fileDescriptor`, up to `bufferSize` bytes.
    ///
    /// Issues a single raw POSIX `read(2)` call on the raw file descriptor rather than going
    /// through any `FileHandle` method, for two reasons neither of which alone is sufficient:
    /// `FileHandle.availableData` raises an Objective-C exception (uncatchable in Swift, crashing
    /// the process) when the read fails, and the newer throwing `FileHandle.read(upToCount:)`
    /// loops internally trying to fill the full requested count (or reach EOF) rather than
    /// returning as soon as any data is available, so it can block indefinitely against a live
    /// process that has written less than `bufferSize` bytes and has nothing further to send yet.
    /// A single `read(2)` call returns as soon as any data is ready, matching `availableData`'s
    /// responsiveness, and reports failure as a plain `-1`/`errno` rather than an exception.
    ///
    /// The caller reads the descriptor inside `runReadLoop(name:readEnd:_:)`, which keeps the
    /// read end open for each call and closes it only after the loop ends. No other code closes
    /// it, because a closed number can name the next pipe that this process opens.
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
    ///   (`read` returns `-1` with `errno != EINTR`) — both end the caller's loop.
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

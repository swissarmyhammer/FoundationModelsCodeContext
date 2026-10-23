import Darwin
import Foundation
import Logging
import Tracing

/// Thread-safe table of in-flight JSON-RPC requests, keyed by request id.
///
/// A plain lock-guarded class rather than `ProcessLanguageServerConnection`
/// actor state: a request's `CheckedContinuation` must be registered
/// synchronously inside the `withCheckedThrowingContinuation` closure that
/// creates it (that closure does not run with actor isolation), and the
/// reader loop and timeout race both resolve continuations from outside the
/// actor too. `@unchecked Sendable` is safe because every access goes
/// through `lock`.
///
/// Every registered continuation is wrapped in a `ResumeOnce` (see its doc comment) rather than
/// stored raw: the table's own dictionary removal already hands each continuation to exactly one
/// of `timeOut(id:with:)` / `resolveOrBuffer(id:response:)` / `failAll(with:)`, but routing every
/// resume through one primitive keeps the "resume at most once" guarantee in one place instead
/// of each call site re-deriving it from dictionary-removal semantics on its own.
///
/// Not `private`: unit-tested directly (`PendingRequestTableTests`) since the
/// register/resolve ordering it guarantees is only reliably exercisable this
/// way — reproducing the real race below via an actual child process would
/// require winning a microsecond-scale scheduling race on demand.
///
/// The table keeps a response only for a request that waits for it. A response for a request that
/// timed out, for an id that the client never sent, or a second response for one id is dropped.
/// Thus no response stays in the table for ever.
final class PendingRequestTable: @unchecked Sendable {
    /// What `resolveOrBuffer(id:response:)` did with one response.
    enum ResponseDisposition: Equatable {
        /// A registered continuation got the response.
        case delivered

        /// The request is sent, but its continuation is not registered yet. The table keeps the
        /// response until `register(id:continuation:)` takes it.
        case buffered

        /// The response answers a request that timed out. The table dropped it.
        case droppedLate

        /// The response answers no request that waits: an id that the client never sent, or a
        /// second response for one id. The table dropped it.
        case droppedUnknown
    }

    /// The maximum count of timed-out ids that the table keeps. A server that never answers a
    /// timed-out request must not make the set grow without a limit. When the set is full, the
    /// oldest id goes first. A late response for that id is then `droppedUnknown`, and the table
    /// also drops it.
    static let timedOutIDLimit = 1024

    private let lock = NSLock()
    private var continuations: [Int: ResumeOnce<Data>] = [:]
    private var earlyResponses: [Int: Data] = [:]

    /// The ids of the sent requests that no response answered yet. Only a response for one of
    /// these ids goes into `earlyResponses`, thus a registration always takes each buffered
    /// response.
    private var awaitedIDs: Set<Int> = []

    /// The ids of the requests that timed out and that no late response answered yet. The set
    /// holds at most `timedOutIDLimit` ids.
    private var timedOutIDs: Set<Int> = []

    /// The ids of the sent requests that `cancel(id:)` cancelled before their continuation was
    /// registered. The registration that always follows takes the id out and fails at once.
    private var cancelledIDs: Set<Int> = []

    /// The error of the first `failAll(with:)` call, or `nil` before it. After that call no
    /// response comes, thus a registration with no buffered response gets this error at once.
    private var failure: (any Error)?

    /// Records that the request `id` is sent and waits for its response.
    ///
    /// Call this before the request is written: the response can arrive before the write
    /// returns.
    /// - Parameter id: The JSON-RPC id of the request.
    func expectResponse(id: Int) {
        lock.withLock { _ = awaitedIDs.insert(id) }
    }

    /// Removes the request `id` from the sent requests, because its write failed. No response
    /// can come for it.
    /// - Parameter id: The JSON-RPC id of the request.
    func abandon(id: Int) {
        lock.withLock { _ = awaitedIDs.remove(id) }
    }

    /// Registers `continuation` as awaiting the response to request `id`.
    ///
    /// If a response for `id` already arrived via `resolveOrBuffer(id:response:)` before this
    /// call ever ran, `continuation` is resumed immediately with the buffered response instead of
    /// being stored — see `resolveOrBuffer(id:response:)`'s doc comment for why that race is
    /// always possible and why silently losing it used to hang the caller forever.
    ///
    /// After `failAll(with:)`, a registration with no buffered response is resumed at once with
    /// the error of `failAll(with:)`: no response comes after that call, thus the registration
    /// would otherwise wait until its timeout.
    /// - Parameters:
    ///   - id: The JSON-RPC id of the outstanding request.
    ///   - continuation: The continuation to resume when a response or timeout resolves `id`.
    func register(id: Int, continuation: CheckedContinuation<Data, Error>) {
        let outcome: Result<Data, any Error>? = lock.withLock {
            if let buffered = earlyResponses.removeValue(forKey: id) {
                return .success(buffered)
            }
            if cancelledIDs.remove(id) != nil {
                return .failure(CancellationError())
            }
            if let failure {
                return .failure(failure)
            }
            continuations[id] = ResumeOnce(continuation: continuation)
            return nil
        }
        if let outcome {
            continuation.resume(with: outcome)
        }
    }

    /// Fails the pending request `id` with `error` when its timeout fires, and records `id` as
    /// timed out. The table then drops a late response for `id` (see
    /// `resolveOrBuffer(id:response:)`).
    ///
    /// Used by the request-timeout race in `awaitResponse(id:)`: unlike
    /// `resolveOrBuffer(id:response:)`, a miss here always means the request was already resolved
    /// by some other path (the real response, or — impossible in practice, since only one timeout
    /// task exists per id — another timeout), never that its continuation hasn't registered yet,
    /// so there is nothing to buffer.
    /// - Parameters:
    ///   - id: The JSON-RPC id of the request that timed out.
    ///   - error: The error to fail the request with.
    /// - Returns: `true` if a pending continuation for `id` was found and failed; `false` if
    ///   `id` was already resolved, in which case `error` is discarded and `id` is not recorded —
    ///   this is what lets a timeout and a real response race safely.
    @discardableResult
    func timeOut(id: Int, with error: Error) -> Bool {
        let resumer: ResumeOnce<Data>? = lock.withLock {
            guard let resumer = continuations.removeValue(forKey: id) else {
                return nil
            }
            awaitedIDs.remove(id)
            recordTimedOut(id: id)
            return resumer
        }
        guard let resumer else {
            return false
        }
        return resumer.resume(with: .failure(error))
    }

    /// Fails the pending request `id` with `CancellationError`, because the task that waits for
    /// it is cancelled, and records `id` like a timed-out id: the table then drops a late response
    /// for `id` (see `resolveOrBuffer(id:response:)`).
    ///
    /// Unlike `timeOut(id:with:)`, the cancel can come before the continuation of `id` is
    /// registered: `withTaskCancellationHandler` runs its handler at once in a task that is
    /// already cancelled. The table then records `id` in `cancelledIDs`, and the registration
    /// that follows fails at once. A request that a response already resolved, or whose response
    /// is buffered, is not changed.
    /// - Parameter id: The JSON-RPC id of the cancelled request.
    func cancel(id: Int) {
        let resumer: ResumeOnce<Data>? = lock.withLock {
            if let resumer = continuations.removeValue(forKey: id) {
                awaitedIDs.remove(id)
                recordTimedOut(id: id)
                return resumer
            }
            if awaitedIDs.remove(id) != nil {
                recordTimedOut(id: id)
                cancelledIDs.insert(id)
            }
            return nil
        }
        resumer?.resume(throwing: CancellationError())
    }

    /// Adds `id` to `timedOutIDs`, and removes the oldest id when the set holds more than
    /// `timedOutIDLimit` ids. The ids of one connection increase monotonically, thus the smallest
    /// id is the oldest. The caller holds `lock`.
    /// - Parameter id: The JSON-RPC id of the request that timed out.
    private func recordTimedOut(id: Int) {
        timedOutIDs.insert(id)
        guard timedOutIDs.count > Self.timedOutIDLimit, let oldestID = timedOutIDs.min() else {
            return
        }
        timedOutIDs.remove(oldestID)
    }

    /// Resolves the pending request `id` with `response` if it is already registered; otherwise
    /// buffers `response` so the next `register(id:continuation:)` call for the same `id`
    /// delivers it immediately instead of leaving that registration to wait forever.
    ///
    /// Used exclusively by the reader loop's `route(message:serverName:sinks:)`
    /// — the one caller whose response can legitimately arrive before the matching request has
    /// finished registering its continuation. `sendRequest` writes a request to the child
    /// process's stdin, then separately spawns the task that registers a continuation to await
    /// its reply; nothing enforces that the second step wins the race against a real round trip,
    /// especially once the cooperative thread pool is busy running hundreds of other concurrent
    /// tasks (exactly the condition a full `swift test` run creates). Before this buffering
    /// existed, a response arriving in that window found no continuation to resolve, was silently
    /// discarded (`route` never checked `resolve`'s `Bool` result), and the registration that
    /// followed was orphaned: nothing but its own sibling timeout task would ever resolve it, and
    /// that task's wakeup could itself be starved by the same load that lost the race in the first
    /// place — manifesting as exactly the "genuinely un-resumed continuation" hang this fixes.
    ///
    /// Only a response for a sent request that waits (see `expectResponse(id:)`) is buffered. A
    /// late response for a timed-out request removes its id from the timed-out ids and is
    /// dropped. A response for an id that no request waits for is dropped too. Thus no response
    /// stays in `earlyResponses` for ever.
    /// - Parameters:
    ///   - id: The JSON-RPC id the response answers.
    ///   - response: The raw response message bytes.
    /// - Returns: What the table did with the response.
    @discardableResult
    func resolveOrBuffer(id: Int, response: Data) -> ResponseDisposition {
        let (disposition, resumer) = lock.withLock {
            dispose(ofResponse: response, id: id)
        }
        resumer?.resume(returning: response)
        return disposition
    }

    /// Decides what happens to one response, and updates the state of the table. The caller
    /// holds `lock`, and resumes the continuation that this function gives outside the lock.
    /// - Parameters:
    ///   - response: The raw response message bytes.
    ///   - id: The JSON-RPC id the response answers.
    /// - Returns: What the table did with the response, and the continuation that gets it when
    ///   the disposition is `.delivered`.
    private func dispose(ofResponse response: Data, id: Int) -> (ResponseDisposition, ResumeOnce<Data>?) {
        if timedOutIDs.remove(id) != nil {
            return (.droppedLate, nil)
        }
        let isAwaited = awaitedIDs.remove(id) != nil
        if let resumer = continuations.removeValue(forKey: id) {
            return (.delivered, resumer)
        }
        guard isAwaited else {
            return (.droppedUnknown, nil)
        }
        earlyResponses[id] = response
        return (.buffered, nil)
    }

    /// Fails every still-pending request with `error`, used when the connection closes or the
    /// child process exits unexpectedly. Also forgets the sent and the timed-out ids, because no
    /// response comes after this point. A later registration with no buffered response gets the
    /// error of the first call at once (see `register(id:continuation:)`).
    ///
    /// Keeps each buffered early response. It is the true answer of a sent request whose
    /// registration did not run yet, and that registration always runs and takes it. A server
    /// that answers and exits at once, before a loaded cooperative pool starts the registering
    /// task, makes exactly this order: the reader loop buffers the response, reads the end of
    /// the file and calls this function, and only then does the request register. A drop of the
    /// buffered response here made that request wait until its timeout.
    /// - Parameter error: The error to fail every pending request with.
    func failAll(with error: Error) {
        let pending: [ResumeOnce<Data>] = lock.withLock {
            if failure == nil {
                failure = error
            }
            let pending = Array(continuations.values)
            continuations.removeAll()
            awaitedIDs.removeAll()
            timedOutIDs.removeAll()
            return pending
        }
        for resumer in pending {
            resumer.resume(throwing: error)
        }
    }
}

/// A `LanguageServerConnection` backed by a real language-server child
/// process, talking `Content-Length`-framed JSON-RPC over its stdio.
///
/// Owns the process's three pipes: writes typed requests/notifications to
/// stdin, decodes stdout through `JSONRPCMessageDecoder` on a background
/// reader loop that routes each message to a pending request (by id), to a
/// reply (a request from the server, see `ServerRequestReply`) or to
/// `serverNotifications`, and drains stderr into an in-memory tail buffer. The stderr
/// text stays only in that buffer: the log gets only the server name and the byte count of
/// each chunk, at `.debug` in `Log.lsp`. The wire messages go to `Log.lspWire` at `.trace`
/// with only their method name, request id, direction and byte size, never the payload.
/// Every request races against an injectable `Clock`-driven timeout
/// (30 seconds by default), so a server that never answers fails the caller
/// rather than hanging it forever. A timeout writes one `.warning` record to `Log.lspWire` with
/// the state of the server and of the reader loop (see `ReaderLoopProgress`), and no payload. Each request records its duration in the
/// injected `CodeContextMetrics`, with the method name, the server name and the
/// outcome as dimensions.
///
/// The server process leads its own process group (see `ProcessGroupChild`). `close()` stops
/// the full group and waits for the exit of the server. A connection that is released with no
/// `close()` kills the group in `deinit`. Thus no process that the server started stays after
/// the connection.
///
/// When the host process is killed with `SIGKILL`, or crashes, neither `close()` nor `deinit`
/// runs, and nothing in the host can kill the group. The kernel then closes the pipes of the
/// host: the server reads the end of its standard input and exits, as each language server does.
/// A process that the server started stops when it reads the end of a pipe from the server, as
/// the Jedi subprocess of `pylsp` does. The `HardKilledHostTests` of the `IntegrationTests`
/// package measure this for the scripted server and for a real `pylsp`: no process of the group
/// stays. A process that the server started and that reads no pipe from the server does not see
/// the death of the host, and it stays with the parent process id 1 until something kills it.
public actor ProcessLanguageServerConnection: LanguageServerConnection {
    /// The server process, the leader of its own process group.
    private nonisolated let child: ProcessGroupChild
    private let stdinHandle: FileHandle
    private nonisolated let pendingRequests = PendingRequestTable()

    /// The count of the most recent stderr chunks that `recentStderrTail()` keeps.
    private static let stderrTailChunkLimit = 20

    /// The time in seconds that a request waits for its response when the caller gives no
    /// timeout.
    static let defaultRequestTimeoutSeconds = 30

    /// The time that a request waits for its response when the caller gives no timeout.
    static let defaultRequestTimeout: Duration = .seconds(defaultRequestTimeoutSeconds)

    /// The time in milliseconds that `close()` gives the server to exit after `SIGTERM`, before
    /// it sends `SIGKILL` to the process group.
    static let terminationGraceMilliseconds = 500

    /// The time that `close()` gives the server to exit after `SIGTERM`, before it sends
    /// `SIGKILL` to the process group.
    static let terminationGrace: Duration = .milliseconds(terminationGraceMilliseconds)

    private nonisolated let stderrTailBuffer = BoundedTailBuffer(maxChunks: stderrTailChunkLimit)

    /// What the stdout reader loop did so far. A request that times out logs it.
    private nonisolated let readerProgress = ReaderLoopProgress()
    private let requestTimeout: Duration
    private let clock: any Clock<Duration>

    /// The server-specific options that `initialize(rootURI:)` sends, or `nil` to send no
    /// `initializationOptions` field.
    private let initializationOptions: JSONValue?

    /// Gets the duration of each request, with the method name, the server name and the outcome.
    private let metrics: CodeContextMetrics

    /// The tracer of the span of each request. `nil` reads the bootstrapped tracer at the time
    /// of each request.
    private let tracer: (any Tracer)?
    private var nextRequestID = 0
    private var readerTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?

    /// Writes the reply to each server request to the server, in the order of the requests. See
    /// `writeReply(_:)`.
    ///
    /// `nonisolated(unsafe)`, the same as `LspSession.notificationConsumerTask`: `init` creates
    /// the task that captures `self`, and after that point `init` can write only nonisolated
    /// members of `self`. `init` assigns it one time, and only `close()` reads it after that, thus
    /// no two accesses occur at the same time. The task body does not touch it.
    private nonisolated(unsafe) var replyTask: Task<Void, Never>?
    private var isClosed = false

    /// The id of the server process, and also the id of its process group. The id does not
    /// change after the start, thus it needs no actor hop.
    nonisolated let pid: Int32

    /// The command of the language server, as the caller gave it. The wire and standard error
    /// log records name the server with it.
    private nonisolated let serverName: String

    private let notificationContinuation: AsyncStream<ServerNotification>.Continuation

    /// Gets the reply to each server request from the reader loop. `replyTask` reads the stream.
    private let replyContinuation: AsyncStream<ServerReply>.Continuation

    /// Server-initiated notifications (currently just `publishDiagnostics`), fanned out as they arrive.
    public nonisolated let serverNotifications: AsyncStream<ServerNotification>

    /// Spawns `command` as a child process in a new process group and opens a JSON-RPC
    /// connection to it over its stdio.
    ///
    /// `command` is looked up on `$PATH` via `/usr/bin/env`, matching how `ServerSpec.command`
    /// names language servers (e.g. `"rust-analyzer"`) without requiring a pre-resolved path.
    /// - Parameters:
    ///   - command: The executable to spawn, looked up on `$PATH`.
    ///   - arguments: Arguments passed to `command` on launch. Defaults to none.
    ///   - initializationOptions: The server-specific options that `initialize(rootURI:)`
    ///     sends. Defaults to `nil`: the request has no `initializationOptions` field.
    ///   - requestTimeout: How long a request waits for a response before failing with
    ///     `CodeContextError.timeout`. Defaults to 30 seconds.
    ///   - clock: The clock used to schedule the request timeout. Defaults to `ContinuousClock()`;
    ///     tests inject a `ManualClock` to exercise the timeout without waiting in real time.
    ///   - metrics: Gets the duration of each request. Defaults to `CodeContextMetrics()`, which
    ///     records into the bootstrapped `MetricsSystem` factory; tests give a `TestMetrics` factory.
    ///   - tracer: The tracer of the span of each request. Defaults to `nil`, which reads the
    ///     bootstrapped tracer at the time of each request; tests give an `InMemoryTracer`.
    /// - Throws: `CodeContextError.spawnFailed` if the process could not be launched.
    init(
        command: String,
        arguments: [String] = [],
        initializationOptions: JSONValue? = nil,
        requestTimeout: Duration = defaultRequestTimeout,
        clock: any Clock<Duration> = ContinuousClock(),
        metrics: CodeContextMetrics = CodeContextMetrics(),
        tracer: (any Tracer)? = nil
    ) throws {
        // The server gets its own three pipes. It never gets a standard stream of the host,
        // because the host can use its standard streams for a protocol (ACP, MCP over stdio).
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let child: ProcessGroupChild
        do {
            child = try ProcessGroupChild.spawn(
                executableURL: URL(fileURLWithPath: ProcessUtilities.envExecutablePath),
                arguments: [command] + arguments,
                standardInput: .pipe(stdinPipe),
                standardOutput: stdoutPipe,
                standardError: stderrPipe
            )
        } catch {
            throw CodeContextError.spawnFailed("\(command): \(error.localizedDescription)")
        }

        self.child = child
        self.serverName = command
        self.pid = child.pid
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.initializationOptions = initializationOptions
        self.requestTimeout = requestTimeout
        self.clock = clock
        self.metrics = metrics
        self.tracer = tracer

        let (notificationStream, continuation) = AsyncStream.makeStream(of: ServerNotification.self)
        self.serverNotifications = notificationStream
        self.notificationContinuation = continuation
        let (replyStream, replyContinuation) = AsyncStream.makeStream(of: ServerReply.self)
        self.replyContinuation = replyContinuation

        // Each loop owns the read end of its pipe, and closes it after its last `read(2)`: no
        // other code of this connection closes the stdout or the stderr read end, also not
        // `close()` or `deinit`. A read end that other code closes frees its descriptor number,
        // and the loop can then read the pipe of the next server that this process starts. See
        // `ProcessUtilities.runReadLoop(name:readEnd:_:)`.
        //
        // Each loop blocks in `read(2)` until the child process closes its pipe, thus each loop
        // runs on a dedicated thread, not on a thread of the cooperative pool. Two blocked loops
        // for each open connection can fill the pool on a machine with few cores, and then no
        // request timeout and no `close()` can run. See
        // `ProcessUtilities.runOnDedicatedThread(name:_:)`.
        let sinks = MessageSinks(
            pendingRequests: self.pendingRequests,
            notifications: continuation,
            replies: replyContinuation,
            progress: self.readerProgress
        )
        self.readerTask = ProcessUtilities.runReadLoop(name: "lsp-reader \(command)", readEnd: stdoutPipe.fileHandleForReading) {
            stdoutFileDescriptor in
            let isOutOfStep = Self.runReaderLoop(serverName: command, stdoutFileDescriptor: stdoutFileDescriptor, sinks: sinks)
            guard isOutOfStep else { return }
            Self.closeOutOfStepConnection(child: child, notificationContinuation: continuation)
        }

        let stderrTailBuffer = self.stderrTailBuffer
        self.stderrTask = ProcessUtilities.runReadLoop(name: "lsp-stderr \(command)", readEnd: stderrPipe.fileHandleForReading) {
            stderrFileDescriptor in
            Self.runStderrDrainLoop(serverName: command, stderrFileDescriptor: stderrFileDescriptor, tailBuffer: stderrTailBuffer)
        }

        // The reader loop runs on its own thread and must not write to stdin: a write blocks
        // while the stdin pipe of the server is full, and the server can block at the same time
        // on its full stdout pipe, which only the reader loop empties. Thus the reader loop only
        // puts each reply in `replyStream`, and this task writes it through the actor, in the
        // same serial order as each other write. The task holds `self` only for each write, thus
        // it does not keep the connection alive. The loop stops when the stream finishes: when
        // the reader loop stops or when `close()` runs.
        self.replyTask = Task { [weak self] in
            for await reply in replyStream {
                await self?.writeReply(reply)
            }
        }
    }

    /// Stops the process group of the server, waits for the exit of the server, and releases
    /// each resource that this connection owns.
    ///
    /// Sends `SIGTERM` to the full process group, gives the server `terminationGrace` to exit,
    /// and then sends `SIGKILL` to the group (see `ProcessGroupChild.terminateGroup(grace:)`).
    /// Thus each process that the server started also stops, and none of them keeps the pipes of
    /// the server open. A server that ignores `SIGTERM` does not survive `close()`. The JSON-RPC
    /// `shutdown`/`exit` exchange and its grace period are the work of the caller
    /// (`LSPDaemon.shutdown()`), before this call. `close()` returns after the reap of the
    /// server process, or at once when the task of the caller is cancelled after `SIGKILL`.
    ///
    /// The exit of the group closes the write ends of the stdout and stderr pipes, and that
    /// stops the reader and stderr-drain loops: they block in a raw `read(2)` call outside actor
    /// isolation, thus `Task.cancel()` alone cannot stop them, and the end of the file is the
    /// exit condition of `ProcessUtilities.readChunk(from:bufferSize:)`. Each loop then closes
    /// its own read end; this method closes only the stdin write end, because a read end that
    /// it closed could get a new pipe under a loop that still reads (see
    /// `ProcessUtilities.runReadLoop(name:readEnd:_:)`). `readerTask` and `stderrTask` are also
    /// cancelled here. Fails every still-pending request with `CodeContextError.notRunning` and
    /// finishes `serverNotifications`. Drops each reply to a server request that is not written
    /// yet. Safe to call more than once.
    func close() async {
        guard !isClosed else { return }
        isClosed = true

        readerTask?.cancel()
        stderrTask?.cancel()
        replyContinuation.finish()
        replyTask?.cancel()

        await child.terminateGroup(grace: Self.terminationGrace)

        try? stdinHandle.close()

        pendingRequests.failAll(with: CodeContextError.notRunning)
        notificationContinuation.finish()
    }

    /// Kills the process group of the server when the connection is released with no `close()`.
    ///
    /// A `deinit` cannot `await`, thus it sends `SIGKILL` to the group and does not wait.
    /// `ProcessGroupChild` reaps the server after the kill: at the release of the child, or at
    /// the exit of the server when the exit comes later. The signal goes to the group also when
    /// the server already exited, because a process that the server started can still run; the
    /// exited server stays unreaped until the signal went out, thus its pid cannot name another
    /// group. After `close()`, the group already got `SIGKILL`, thus `deinit` does nothing. Also
    /// finishes `serverNotifications`, thus no consumer of the stream waits for ever.
    deinit {
        guard !isClosed else { return }
        child.signalGroup(SIGKILL)
        notificationContinuation.finish()
    }

    // MARK: - Process-level hooks for LSPDaemon

    /// Reports whether the server process is still running.
    ///
    /// Backs the `isAlive` hook `LSPDaemon.processConnectionFactory()` bundles into a
    /// `ConnectionHandle`, so the daemon's `healthCheck()` can detect an unexpected exit.
    /// - Returns: `true` if the server process did not exit yet; `false` after its exit.
    func isRunning() -> Bool {
        child.isRunning
    }

    /// Suspends until the server process exits, or until the task of the caller is cancelled.
    /// Returns at once when the server process already exited.
    ///
    /// A cancel stops the wait, thus `LSPDaemon.shutdown()` can race this wait against its grace
    /// period.
    func waitUntilExit() async {
        await child.waitUntilExit()
    }

    /// A best-effort tail of the child process's recent stderr output.
    ///
    /// Backs the `stderrTail` hook `LSPDaemon.processConnectionFactory()` bundles into a
    /// `ConnectionHandle`, so a handshake-failure error can be enriched with whatever the server
    /// printed before it died.
    /// - Returns: The most recently captured stderr chunks, oldest first, or an empty string if
    ///   none have been captured yet.
    nonisolated func recentStderrTail() -> String {
        stderrTailBuffer.snapshot()
    }

    /// What the stdout reader loop did so far: its phase, and the counts of the bytes and the
    /// frames that it read from the server.
    ///
    /// A request that times out writes the same values to its log record (see
    /// `logTimeout(id:method:)`). Tests read it to find where a lost response went.
    /// - Returns: The state of the reader loop now.
    nonisolated func readerLoopProgress() -> ReaderLoopProgress.Snapshot {
        readerProgress.snapshot
    }

    // MARK: - LanguageServerConnection

    /// Sends the LSP `initialize` request that starts the handshake.
    ///
    /// The request holds the client capabilities (see `ClientCapabilities`), the root as the
    /// one workspace folder, and the `initializationOptions` of this connection.
    /// - Parameter rootURI: The workspace root to advertise to the server, if any.
    /// - Returns: The gated capabilities that the server advertises.
    /// - Throws: If the server rejects the handshake or the connection is unusable.
    public func initialize(rootURI: DocumentURI?) async throws -> ServerCapabilities {
        let params = InitializeParams(
            processID: Int(ProcessInfo.processInfo.processIdentifier),
            rootURI: rootURI,
            initializationOptions: initializationOptions
        )
        return try await request(method: "initialize", params: params, resultType: InitializeResult.self).capabilities
    }

    /// Sends the `initialized` notification that completes the handshake.
    public func initialized() async throws {
        try await notifyEmpty(method: "initialized")
    }

    /// Sends the `shutdown` request that begins graceful server termination.
    public func shutdown() async throws {
        _ = try await request(method: "shutdown", params: EmptyPayload(), resultType: EmptyPayload?.self)
    }

    /// Sends the `exit` notification that tells the server to terminate.
    public func exit() async throws {
        try await notifyEmpty(method: "exit")
    }

    /// Notifies the server that a document was opened, sending its full content.
    public func didOpen(uri: DocumentURI, languageID: String, version: Int, text: String) async throws {
        let item = TextDocumentItem(uri: uri, languageID: languageID, version: version, text: text)
        try await notify(method: "textDocument/didOpen", params: DidOpenTextDocumentParams(textDocument: item))
    }

    /// Notifies the server of a full-document content replacement.
    public func didChange(uri: DocumentURI, version: Int, text: String) async throws {
        let params = DidChangeTextDocumentParams(
            textDocument: VersionedTextDocumentIdentifier(uri: uri, version: version),
            contentChanges: [TextDocumentContentChangeEvent(text: text)]
        )
        try await notify(method: "textDocument/didChange", params: params)
    }

    /// Notifies the server that a document was saved.
    public func didSave(uri: DocumentURI) async throws {
        try await notifyTextDocument(method: "textDocument/didSave", uri: uri, makeParams: DidSaveTextDocumentParams.init)
    }

    /// Notifies the server that a document was closed.
    public func didClose(uri: DocumentURI) async throws {
        try await notifyTextDocument(method: "textDocument/didClose", uri: uri, makeParams: DidCloseTextDocumentParams.init)
    }

    /// Requests the symbols declared in a document.
    public func documentSymbols(in uri: DocumentURI) async throws -> [DocumentSymbol] {
        let params = DocumentSymbolParams(textDocument: TextDocumentIdentifier(uri: uri))
        let result = try await request(method: "textDocument/documentSymbol", params: params, resultType: DocumentSymbolResult.self)
        return result.symbols
    }

    /// Requests the definition site of the symbol at a position.
    public func definition(in uri: DocumentURI, at position: Position) async throws -> [Location] {
        try await positionRequest(method: "textDocument/definition", uri: uri, position: position)
    }

    /// Requests the type-definition site of the symbol at a position.
    public func typeDefinition(in uri: DocumentURI, at position: Position) async throws -> [Location] {
        try await positionRequest(method: "textDocument/typeDefinition", uri: uri, position: position)
    }

    /// Requests hover information for the symbol at a position.
    public func hover(in uri: DocumentURI, at position: Position) async throws -> Hover? {
        try await requestAtPosition(method: "textDocument/hover", uri: uri, position: position, resultType: Hover?.self)
    }

    /// Requests every reference to the symbol at a position.
    public func references(in uri: DocumentURI, at position: Position, includeDeclaration: Bool) async throws -> [Location] {
        let params = ReferenceParams(
            textDocument: TextDocumentIdentifier(uri: uri),
            position: position,
            context: ReferenceContext(includeDeclaration: includeDeclaration)
        )
        return try await locationsRequest(method: "textDocument/references", params: params)
    }

    /// Requests every implementation of the symbol at a position.
    public func implementations(in uri: DocumentURI, at position: Position) async throws -> [Location] {
        try await positionRequest(method: "textDocument/implementation", uri: uri, position: position)
    }

    /// Requests the call-hierarchy item(s) rooted at a position.
    public func prepareCallHierarchy(in uri: DocumentURI, at position: Position) async throws -> [CallHierarchyItem] {
        try await arrayRequest(method: "textDocument/prepareCallHierarchy", params: positionParams(uri: uri, position: position), resultType: CallHierarchyItem.self)
    }

    /// Requests every call made from a call-hierarchy item.
    public func outgoingCalls(of item: CallHierarchyItem) async throws -> [CallHierarchyOutgoingCall] {
        try await arrayRequest(method: "callHierarchy/outgoingCalls", params: CallHierarchyCallsParams(item: item), resultType: CallHierarchyOutgoingCall.self)
    }

    /// Requests every call made into a call-hierarchy item.
    public func incomingCalls(of item: CallHierarchyItem) async throws -> [CallHierarchyIncomingCall] {
        try await arrayRequest(method: "callHierarchy/incomingCalls", params: CallHierarchyCallsParams(item: item), resultType: CallHierarchyIncomingCall.self)
    }

    /// Checks whether the symbol at a position can be renamed.
    public func prepareRename(in uri: DocumentURI, at position: Position) async throws -> PrepareRenameResult {
        try await requestAtPosition(method: "textDocument/prepareRename", uri: uri, position: position, resultType: PrepareRenameResult.self)
    }

    /// Requests the workspace edit that renames the symbol at a position.
    public func rename(in uri: DocumentURI, at position: Position, newName: String) async throws -> WorkspaceEdit {
        let params = RenameParams(textDocument: TextDocumentIdentifier(uri: uri), position: position, newName: newName)
        return try await request(method: "textDocument/rename", params: params, resultType: WorkspaceEdit.self)
    }

    /// Requests the code actions available for a range.
    public func codeActions(in uri: DocumentURI, range: LSPRange, diagnostics: [Diagnostic], only: [String]?) async throws -> [CodeActionItem] {
        let params = CodeActionParams(
            textDocument: TextDocumentIdentifier(uri: uri),
            range: range,
            context: CodeActionContext(diagnostics: diagnostics, only: only)
        )
        return try await arrayRequest(method: "textDocument/codeAction", params: params, resultType: CodeActionItem.self)
    }

    /// Resolves a code action's deferred fields.
    public func resolveCodeAction(item: CodeActionItem) async throws -> CodeActionItem {
        try await request(method: "codeAction/resolve", params: item, resultType: CodeActionItem.self)
    }

    /// Searches the workspace for symbols matching a query string.
    public func workspaceSymbols(query: String) async throws -> [SymbolInformation] {
        try await arrayRequest(method: "workspace/symbol", params: WorkspaceSymbolParams(query: query), resultType: SymbolInformation.self)
    }

    /// Pulls the current diagnostics for a document via `textDocument/diagnostic`.
    public func pullDiagnostics(for uri: DocumentURI) async throws -> [Diagnostic] {
        let params = DocumentDiagnosticParams(textDocument: TextDocumentIdentifier(uri: uri))
        let resultData = try await performRequest(method: "textDocument/diagnostic", params: params) { data, id in
            try Self.rawResultData(from: data, expectedID: id)
        }
        return DiagnosticsParsing.parseDiagnosticsFromResult(from: resultData)
    }

    // MARK: - Shared request/notify helpers

    /// Sends a fire-and-forget notification carrying no payload — the shape shared by
    /// `initialized` and `exit`.
    private func notifyEmpty(method: String) async throws {
        try await notify(method: method, params: EmptyPayload())
    }

    /// Sends a fire-and-forget `textDocument/*` notification whose params wrap a bare
    /// `TextDocumentIdentifier` — the shape shared by `didSave` and `didClose`, which only
    /// differ in method name and which wrapper type the wire protocol expects.
    /// - Parameters:
    ///   - method: The JSON-RPC method name.
    ///   - uri: The document the notification is about.
    ///   - makeParams: Wraps the built `TextDocumentIdentifier` in the method's params type.
    private func notifyTextDocument<Params: Encodable>(
        method: String,
        uri: DocumentURI,
        makeParams: (TextDocumentIdentifier) -> Params
    ) async throws {
        try await notify(method: method, params: makeParams(TextDocumentIdentifier(uri: uri)))
    }

    /// Builds the `{ textDocument, position }` params shared by every request keyed on a
    /// cursor position.
    private func positionParams(uri: DocumentURI, position: Position) -> TextDocumentPositionParams {
        TextDocumentPositionParams(textDocument: TextDocumentIdentifier(uri: uri), position: position)
    }

    /// Sends a position-keyed request and returns its typed result directly — the shape shared
    /// by `hover` and `prepareRename`, which only differ in method name and result type.
    private func requestAtPosition<Result: Decodable>(
        method: String,
        uri: DocumentURI,
        position: Position,
        resultType: Result.Type
    ) async throws -> Result {
        try await request(method: method, params: positionParams(uri: uri, position: position), resultType: resultType)
    }

    /// Sends a request expecting an optional array result, normalizing an absent (`null`)
    /// result to an empty array — the shape shared by `prepareCallHierarchy`,
    /// `outgoingCalls`/`incomingCalls`, `codeActions`, and `workspaceSymbols`.
    private func arrayRequest<Params: Encodable, Element: Decodable>(
        method: String,
        params: Params,
        resultType: Element.Type
    ) async throws -> [Element] {
        let result = try await request(method: method, params: params, resultType: [Element]?.self)
        return result ?? []
    }

    /// The `textDocument/definition`-shaped request/response pattern shared by
    /// `definition`, `typeDefinition`, and `implementations`.
    private func positionRequest(method: String, uri: DocumentURI, position: Position) async throws -> [Location] {
        try await locationsRequest(method: method, params: positionParams(uri: uri, position: position))
    }

    /// Sends a request whose result is a `LocationsResult` wrapper and unwraps it — shared by
    /// `positionRequest` (definition/typeDefinition/implementations) and `references`, whose
    /// params additionally carry reference context.
    private func locationsRequest<Params: Encodable>(method: String, params: Params) async throws -> [Location] {
        let result = try await request(method: method, params: params, resultType: LocationsResult.self)
        return result.locations
    }

    /// Sends a request and decodes its typed result.
    /// - Parameters:
    ///   - method: The JSON-RPC method name.
    ///   - params: The request's parameters.
    ///   - resultType: The type to decode the response's `result` field as.
    /// - Returns: The decoded result.
    /// - Throws: `WireError` if the server replied with an error or a mismatched id;
    ///   `CodeContextError.timeout` if no response arrived in time; a `DecodingError` if
    ///   `result` doesn't match `resultType`.
    private func request<Params: Encodable, Result: Decodable>(method: String, params: Params, resultType: Result.Type) async throws -> Result {
        try await performRequest(method: method, params: params) { data, id in
            try JSONRPCFraming.decodeResult(as: resultType, from: data, expectedID: id)
        }
    }

    /// Sends a request, waits for its response and decodes the response with `decode`, in one
    /// `CodeContextTracing.SpanName.lspRequest` span of kind `.client`.
    ///
    /// The one path of each request. `request(method:params:resultType:)` gives a typed decode;
    /// `pullDiagnostics(for:)` gives the raw `result` bytes, because
    /// `DiagnosticsParsing.parseDiagnosticsFromResult` parses them leniently.
    ///
    /// A request can wait for a long time, thus it also writes one "enter" log record before it
    /// is sent. The span and the record hold the server name, the method name and the request
    /// id. The span also holds the request and response sizes and the outcome. They never hold
    /// the payload. A failed request records only the type name of its error on the span, never
    /// the error message of the server. The trace context does not go into the wire message.
    /// - Parameters:
    ///   - method: The JSON-RPC method name.
    ///   - params: The request's parameters.
    ///   - decode: Makes the result from the raw response message bytes and the request id.
    /// - Returns: The result that `decode` makes.
    /// - Throws: `CodeContextError.notRunning` if the connection can't write to the process;
    ///   `CodeContextError.timeout` if no response arrived in time; whatever `decode` throws.
    private func performRequest<Params: Encodable, Output>(
        method: String,
        params: Params,
        decode: (_ data: Data, _ id: Int) throws -> Output
    ) async throws -> Output {
        let id = allocateRequestID()
        let server = CodeContextMetrics.serverName(ofCommand: serverName)
        return try await CodeContextSpans.withEnterRecord(
            CodeContextTracing.SpanName.lspRequest,
            ofKind: .client,
            tracer: tracer,
            logger: Log.lspWire,
            attributes: { attributes in
                attributes[CodeContextTracing.AttributeKey.lspServer] = server
                attributes[CodeContextTracing.AttributeKey.lspMethod] = method
                attributes[CodeContextTracing.AttributeKey.lspRequestId] = id
            },
            metadata: [
                CodeContextTracing.MetadataKey.lspServer: .string(server),
                CodeContextTracing.MetadataKey.lspMethod: .string(method),
                CodeContextTracing.MetadataKey.lspRequestId: .stringConvertible(id),
            ],
            { span in
                try await timedRequest(id: id, method: method, params: params, span: span, decode: decode)
            }
        )
    }

    /// Sends one request, waits for its response and decodes it, and records the duration of the
    /// whole request in `metrics` and its outcome on `span`.
    ///
    /// The timer includes the decode, so a server error response, which the decode throws, has
    /// the outcome `error`.
    /// - Parameters:
    ///   - id: The JSON-RPC id of the request.
    ///   - method: The JSON-RPC method name.
    ///   - params: The request's parameters.
    ///   - span: The span of the request. It gets the sizes and the outcome.
    ///   - decode: Makes the result from the raw response message bytes and the request id.
    /// - Returns: The result that `decode` makes.
    /// - Throws: The errors of `sendRequest(id:method:params:span:)` and of `decode`.
    private func timedRequest<Params: Encodable, Output>(
        id: Int,
        method: String,
        params: Params,
        span: any Span,
        decode: (_ data: Data, _ id: Int) throws -> Output
    ) async throws -> Output {
        let started = ContinuousClock.now
        do {
            let data = try await sendRequest(id: id, method: method, params: params, span: span)
            span.attributes[CodeContextTracing.AttributeKey.lspResponseBytes] = data.count
            let output = try decode(data, id)
            recordRequest(method: method, since: started, outcome: .ok, span: span)
            return output
        } catch {
            recordRequest(method: method, since: started, outcome: CodeContextMetrics.LSPRequestOutcome(classifying: error), span: span)
            throw error
        }
    }

    /// Records the duration of one request in `metrics`, and its outcome on its span.
    /// - Parameters:
    ///   - method: The JSON-RPC method name of the request.
    ///   - started: The time at which the request started.
    ///   - outcome: How the request ended.
    ///   - span: The span of the request.
    private func recordRequest(
        method: String,
        since started: ContinuousClock.Instant,
        outcome: CodeContextMetrics.LSPRequestOutcome,
        span: any Span
    ) {
        metrics.recordLSPRequest(duration: started.duration(to: .now), method: method, server: serverName, outcome: outcome)
        span.attributes[CodeContextTracing.AttributeKey.lspOutcome] = outcome.rawValue
    }

    /// Sends a request and returns its raw response payload, unresolved to a typed result.
    /// - Parameters:
    ///   - id: The JSON-RPC id of the request, from `allocateRequestID()`.
    ///   - method: The JSON-RPC method name.
    ///   - params: The request's parameters.
    ///   - span: The span of the request. It gets the size of the encoded request.
    /// - Returns: The raw response message bytes.
    /// - Throws: `CodeContextError.notRunning` if the connection can't write to the process;
    ///   `CodeContextError.timeout` if no response arrived in time. A timeout also writes one
    ///   `.warning` record (see `logTimeout(id:method:)`) and sends `$/cancelRequest` for `id` to
    ///   the server (see `cancelOnServer(id:)`). `CancellationError` if the calling task is
    ///   cancelled: before the write, the request is not written; after it, the request ends at
    ///   once, with no wait for the response, and `$/cancelRequest` goes to the server.
    private func sendRequest<Params: Encodable>(id: Int, method: String, params: Params, span: any Span) async throws -> Data {
        try Task.checkCancellation()
        let envelope = JSONRPCRequestEnvelope(id: id, method: method, params: params)
        let payload = try JSONEncoder().encode(envelope)
        span.attributes[CodeContextTracing.AttributeKey.lspRequestBytes] = payload.count
        try writeRequest(id: id, payload: payload)
        Self.logWireMessage(.toServer, serverName: serverName, method: method, id: .number(id), byteCount: payload.count)
        do {
            return try await awaitResponse(id: id)
        } catch CodeContextError.timeout(let timeout) {
            logTimeout(id: id, method: method)
            await cancelOnServer(id: id)
            throw CodeContextError.timeout(timeout)
        } catch is CancellationError where Task.isCancelled {
            await cancelOnServer(id: id)
            throw CancellationError()
        }
    }

    /// Writes one `.warning` record to `Log.lspWire` for a request that timed out, with the state
    /// of the server and of the reader loop at that time.
    ///
    /// The record tells where a lost response went: a server that does not run, a reader loop
    /// that stopped or never started, or a loop that read no frame since the request. It holds
    /// the server name, the pid, the method name, the request id, whether the server runs, and
    /// the phase and the byte and frame counts of the reader loop. It never holds a payload or
    /// the standard error text of the server.
    /// - Parameters:
    ///   - id: The JSON-RPC id of the request that timed out.
    ///   - method: The JSON-RPC method name of the request.
    private func logTimeout(id: Int, method: String) {
        let progress = readerProgress.snapshot
        Log.lspWire.warning(
            "a request to the language server timed out",
            metadata: [
                CodeContextTracing.MetadataKey.lspServer: .string(serverName),
                CodeContextTracing.MetadataKey.processID: .stringConvertible(pid),
                CodeContextTracing.MetadataKey.lspMethod: .string(method),
                CodeContextTracing.MetadataKey.lspRequestId: .stringConvertible(id),
                CodeContextTracing.MetadataKey.lspServerRunning: .stringConvertible(child.isRunning),
                CodeContextTracing.MetadataKey.lspReaderPhase: .string(progress.phase.rawValue),
                CodeContextTracing.MetadataKey.lspReaderBytes: .stringConvertible(progress.byteCount),
                CodeContextTracing.MetadataKey.lspReaderFrames: .stringConvertible(progress.frameCount),
            ]
        )
    }

    /// Writes one encoded request to the server, and tells `pendingRequests` that the request
    /// waits for its response.
    ///
    /// `pendingRequests` gets the id before the write, because the response can arrive before
    /// the write returns. When the write fails, `pendingRequests` removes the id again.
    /// - Parameters:
    ///   - id: The JSON-RPC id of the request.
    ///   - payload: The encoded request, not framed.
    /// - Throws: `CodeContextError.notRunning` if the connection can't write to the process.
    private func writeRequest(id: Int, payload: Data) throws {
        pendingRequests.expectResponse(id: id)
        do {
            try writeToStdin(JSONRPCFraming.frame(payload: payload))
        } catch {
            pendingRequests.abandon(id: id)
            throw error
        }
    }

    /// Sends a fire-and-forget notification (no response expected).
    /// - Parameters:
    ///   - method: The JSON-RPC method name.
    ///   - params: The notification's parameters.
    /// - Throws: `CodeContextError.notRunning` if the connection can't write to the process.
    private func notify<Params: Encodable>(method: String, params: Params) async throws {
        let envelope = JSONRPCNotificationEnvelope(method: method, params: params)
        let payload = try JSONEncoder().encode(envelope)
        try writeToStdin(JSONRPCFraming.frame(payload: payload))
        Self.logWireMessage(.toServer, serverName: serverName, method: method, id: nil, byteCount: payload.count)
    }

    /// Writes one reply to a server request to the server.
    ///
    /// A reply that cannot be written is dropped with one `.debug` record: the write fails only
    /// when the connection closes or the server exits, and then no server waits for the reply.
    /// - Parameter reply: The reply to write.
    private func writeReply(_ reply: ServerReply) {
        guard !isClosed else { return }
        do {
            try writeToStdin(JSONRPCFraming.frame(payload: reply.payload))
            Self.logWireMessage(.toServer, serverName: serverName, method: nil, id: reply.id, byteCount: reply.payload.count)
        } catch {
            Self.logRequestEvent(
                "a reply to a server request was not written; the language server is not running",
                serverName: serverName,
                id: reply.id
            )
        }
    }

    /// Tells the server with the notification `$/cancelRequest` that the client does not wait
    /// for the request `id` any more, after its timeout. The server can then stop the work. A
    /// late response that the server still sends is dropped (see
    /// `PendingRequestTable.resolveOrBuffer(id:response:)`).
    ///
    /// The write goes through the actor, the same as each other write to stdin, thus it does not
    /// interleave with the replies that `replyTask` writes. A notification that cannot be written
    /// is dropped with one `.debug` record: the write fails only when the connection closes or the
    /// server exits, and then the server does no more work.
    /// - Parameter id: The JSON-RPC id of the request that timed out.
    private func cancelOnServer(id: Int) async {
        guard !isClosed else { return }
        do {
            try await notify(method: "$/cancelRequest", params: CancelParams(id: .number(id)))
        } catch {
            Self.logRequestEvent(
                "a $/cancelRequest notification was not written; the language server is not running",
                serverName: serverName,
                id: .number(id)
            )
        }
    }

    /// Allocates the next monotonically increasing JSON-RPC request id.
    private func allocateRequestID() -> Int {
        defer { nextRequestID += 1 }
        return nextRequestID
    }

    /// Writes framed bytes to the child process's stdin.
    /// - Parameter framedMessage: A `Content-Length`-framed JSON-RPC message.
    /// - Throws: `CodeContextError.notRunning` if the process has exited or the write fails.
    private func writeToStdin(_ framedMessage: Data) throws {
        guard child.isRunning else {
            throw CodeContextError.notRunning
        }
        do {
            try stdinHandle.write(contentsOf: framedMessage)
        } catch {
            throw CodeContextError.notRunning
        }
    }

    /// Waits for the response to request `id`, racing it against the injectable-clock timeout.
    ///
    /// Both branches run outside actor isolation (they only touch the `Sendable`
    /// `pendingRequests` table and `clock`), so registering the continuation and racing the
    /// timeout never need to hop back onto this actor. Extracted into `awaitRegisteredResponse`
    /// and `failAfterTimeout`, so each `group.addTask` closure here is a single call rather than
    /// an inline `withCheckedThrowingContinuation` or sleep-then-resolve body.
    /// - Parameter id: The JSON-RPC id to wait for.
    /// - Returns: The raw response message bytes.
    /// - Throws: `CodeContextError.timeout` if `requestTimeout` elapses first.
    private func awaitResponse(id: Int) async throws -> Data {
        let timeout = requestTimeout
        let clock = self.clock
        let pendingRequests = self.pendingRequests

        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await Self.awaitRegisteredResponse(id: id, pendingRequests: pendingRequests)
            }
            group.addTask {
                try await Self.failAfterTimeout(id: id, timeout: timeout, clock: clock, pendingRequests: pendingRequests)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw CodeContextError.notRunning
            }
            return result
        }
    }

    /// Registers a continuation for `id` and suspends until `pendingRequests` resolves it — the
    /// "wait for the real response" side of `awaitResponse(id:)`'s race.
    /// - Parameters:
    ///   - id: The JSON-RPC id to await.
    ///   - pendingRequests: The table to register the continuation with.
    /// - Returns: The raw response message bytes once resolved.
    /// - Throws: Whatever error `pendingRequests` resolves `id` with (e.g. the timeout race's
    ///   `CodeContextError.timeout`, or `CodeContextError.notRunning` if the connection closes);
    ///   `CancellationError` at once when the task is cancelled (see `PendingRequestTable.cancel(id:)`).
    ///   A server that is busy can answer a request many seconds late; a cancelled caller (for
    ///   example the LSP index task in `CodeContext.stop()`) must not wait for that answer.
    private static func awaitRegisteredResponse(id: Int, pendingRequests: PendingRequestTable) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                pendingRequests.register(id: id, continuation: continuation)
            }
        } onCancel: {
            pendingRequests.cancel(id: id)
        }
    }

    /// Sleeps for `timeout`, then resolves `id` with a timeout failure and throws — the "give up
    /// waiting" side of `awaitResponse(id:)`'s race. Never actually returns a value: if the real
    /// response already resolved `id` through `awaitRegisteredResponse` by the time this fires,
    /// `pendingRequests.timeOut(id:with:)` returns `false` and this throws `CancellationError()`
    /// instead, so `awaitResponse(id:)`'s `group.next()` sees the real response's task win rather
    /// than mistaking this branch's own wakeup for a timeout that didn't happen.
    /// - Parameters:
    ///   - id: The JSON-RPC id to fail if it is still pending once `timeout` elapses.
    ///   - timeout: How long to wait before firing.
    ///   - clock: The clock to sleep against.
    ///   - pendingRequests: The table to resolve `id` against.
    /// - Throws: `CodeContextError.timeout(timeout)` if `id` was still pending; `CancellationError`
    ///   if the real response already resolved it first.
    private static func failAfterTimeout(
        id: Int, timeout: Duration, clock: any Clock<Duration>, pendingRequests: PendingRequestTable
    ) async throws -> Data {
        try await clock.sleep(for: timeout)
        if pendingRequests.timeOut(id: id, with: CodeContextError.timeout(timeout)) {
            throw CodeContextError.timeout(timeout)
        }
        throw CancellationError()
    }

    /// Extracts a request's raw `result` field as re-encoded JSON, for callers that need the
    /// untyped bytes (only `pullDiagnostics(for:)`, for `DiagnosticsParsing`'s lenient parsing).
    /// - Parameters:
    ///   - data: The raw response message bytes.
    ///   - expectedID: The id the response must carry.
    /// - Returns: The `result` field's bytes, or `"null"` if the field was absent.
    /// - Throws: `WireError.idMismatch` or `WireError.serverError`, matching
    ///   `JSONRPCFraming.decodeResult(as:from:expectedID:)`.
    private static func rawResultData(from data: Data, expectedID: Int) throws -> Data {
        let envelope = try JSONDecoder().decode(JSONRPCResponseEnvelope<JSONValue>.self, from: data)
        guard envelope.id == expectedID else {
            throw WireError.idMismatch(expected: expectedID, actual: envelope.id)
        }
        if let error = envelope.error {
            throw WireError.serverError(code: error.code, message: error.message)
        }
        guard let result = envelope.result else {
            return Data("null".utf8)
        }
        return try JSONEncoder().encode(result)
    }

    // MARK: - Background loops

    /// Reads framed messages from the child process's stdout until EOF, routing each one to a
    /// pending request (by id), to the reply stream (server request) or to the notification
    /// stream (server-initiated notification). See `route(message:serverName:sinks:)`.
    ///
    /// Runs on a dedicated thread, outside actor isolation: every value it touches (`sinks`) is
    /// `Sendable`, so no actor hop is needed per received message. On EOF (the process exited),
    /// fails every still-pending request with `CodeContextError.notRunning` and finishes the reply
    /// stream.
    ///
    /// A frame header that tells no correct body length (see `JSONRPCFrameError`) puts the stream
    /// out of step. The loop then writes one `.error` record to `Log.lspWire`, fails every
    /// still-pending request with `CodeContextError.notRunning`, finishes the reply stream, and
    /// stops. It does not read the next bytes as a header. The caller must then close the
    /// connection.
    ///
    /// The loop records its phase, each read and each decoded frame in `sinks.progress`, thus a
    /// request that times out can log what the loop read.
    /// - Parameters:
    ///   - serverName: The command name of the language server, for the wire log records.
    ///   - stdoutFileDescriptor: The child process's stdout read end's raw file descriptor.
    ///   - sinks: The places that get the messages.
    /// - Returns: `true` when the loop stopped at a bad frame header; `false` when it stopped at
    ///   EOF.
    private static func runReaderLoop(serverName: String, stdoutFileDescriptor: Int32, sinks: MessageSinks) -> Bool {
        sinks.progress.recordStart()
        defer {
            sinks.progress.recordStop()
            sinks.pendingRequests.failAll(with: CodeContextError.notRunning)
            sinks.replies.finish()
        }
        var decoder = JSONRPCMessageDecoder()
        while let chunk = ProcessUtilities.readChunk(from: stdoutFileDescriptor, bufferSize: ProcessUtilities.defaultChunkSize) {
            sinks.progress.recordRead(byteCount: chunk.count)
            let messages: [Data]
            do {
                messages = try decoder.append(bytes: chunk)
            } catch {
                logFrameError(error, serverName: serverName)
                return true
            }
            sinks.progress.recordFrames(messages.count)
            for message in messages {
                route(message: message, serverName: serverName, sinks: sinks)
            }
        }
        return false
    }

    /// Closes the connection after the reader loop stopped at a bad frame header.
    ///
    /// After a bad frame header no later byte can be read as a message. This kills the process
    /// group of the server and finishes `serverNotifications`, the same as `close()` does. The
    /// reader loop already failed every pending request. The health check of the daemon then
    /// finds a dead process and starts the server again through its normal restart path.
    /// The reader loop closes the stdout read end after this returns, and `close()` later
    /// closes the stdin write end.
    ///
    /// Runs on the thread of the reader loop, thus it does not wait for the actor.
    /// - Parameters:
    ///   - child: The server process, the leader of its process group.
    ///   - notificationContinuation: The stream of the server notifications.
    private static func closeOutOfStepConnection(
        child: ProcessGroupChild,
        notificationContinuation: AsyncStream<ServerNotification>.Continuation
    ) {
        child.signalGroup(SIGKILL)
        notificationContinuation.finish()
    }

    /// Writes the one `.error` record to `Log.lspWire` for a bad frame header.
    ///
    /// The record holds the server name, the direction, the error type and the error case. It
    /// never holds a byte of the header or of the payload.
    /// - Parameters:
    ///   - error: The framing error of the decoder.
    ///   - serverName: The command name of the language server.
    private static func logFrameError(_ error: JSONRPCFrameError, serverName: String) {
        Log.lspWire.error(
            "a frame header from the language server is not valid; the connection closes",
            metadata: [
                CodeContextTracing.MetadataKey.lspServer: .string(serverName),
                CodeContextTracing.MetadataKey.lspDirection: .string(WireDirection.fromServer.rawValue),
                CodeContextTracing.MetadataKey.errorType: Log.errorType(of: error),
                CodeContextTracing.MetadataKey.errorCase: .string(String(describing: error)),
            ]
        )
    }

    /// Routes one decoded JSON-RPC message to a pending request, to the reply stream or to the
    /// notification stream, as `JSONRPCEnvelopePeek.route` tells.
    ///
    /// A message with an `id` and a `method` is a server request: it gets a reply (see
    /// `ServerRequestReply`) and never resolves a pending request, also when its id is the id of a
    /// pending request. A message with an `id` and no `method` is a response.
    ///
    /// Each message writes one `.trace` record to `Log.lspWire` with its method name, request
    /// id, direction and byte size. A message that is not valid JSON-RPC writes one `.error`
    /// record with its byte size only. A response that the pending-request table drops also
    /// writes one `.debug` record (see `logDroppedResponse(_:id:serverName:)`). No record holds
    /// the payload.
    /// - Parameters:
    ///   - message: The raw message bytes.
    ///   - serverName: The command name of the language server, for the wire log records.
    ///   - sinks: The places that get the messages.
    private static func route(message: Data, serverName: String, sinks: MessageSinks) {
        guard let peek = try? JSONRPCFraming.peek(message: message) else {
            Log.lspWire.error(
                "a JSON-RPC message from the language server is not valid",
                metadata: [
                    CodeContextTracing.MetadataKey.lspServer: .string(serverName),
                    CodeContextTracing.MetadataKey.lspDirection: .string(WireDirection.fromServer.rawValue),
                    CodeContextTracing.MetadataKey.bytes: .stringConvertible(message.count),
                ]
            )
            return
        }
        logWireMessage(.fromServer, serverName: serverName, method: peek.method, id: peek.id, byteCount: message.count)

        switch peek.route {
        case .response(let id):
            let disposition = sinks.pendingRequests.resolveOrBuffer(id: id, response: message)
            logDroppedResponse(disposition, id: id, serverName: serverName)
        case .serverRequest(let id, let method):
            replyToServerRequest(message, id: id, method: method, serverName: serverName, replies: sinks.replies)
        case .notification(let method):
            publishNotification(message, method: method, notifications: sinks.notifications)
        case .unroutable:
            // A response whose id is not a number of a client request, or a message with no id
            // and no method: no part of the client waits for it.
            break
        }
    }

    /// Writes one `.debug` record to `Log.lspWire` for a response that the pending-request table
    /// dropped, and writes nothing for a response that the table kept.
    ///
    /// A late response to a timed-out request is normal after `$/cancelRequest`. A response that
    /// answers no waiting request shows a fault of the server.
    /// - Parameters:
    ///   - disposition: What the table did with the response.
    ///   - id: The JSON-RPC id that the response holds.
    ///   - serverName: The command name of the language server.
    private static func logDroppedResponse(_ disposition: PendingRequestTable.ResponseDisposition, id: Int, serverName: String) {
        let message: Logger.Message
        switch disposition {
        case .delivered, .buffered:
            return
        case .droppedLate:
            message = "a late response to a timed-out request was dropped"
        case .droppedUnknown:
            message = "a response that answers no waiting request was dropped"
        }
        logRequestEvent(message, serverName: serverName, id: .number(id))
    }

    /// Writes one `.debug` record to `Log.lspWire` about one request. The record holds only the
    /// server name and the request id, never a payload.
    /// - Parameters:
    ///   - message: What occurred.
    ///   - serverName: The command name of the language server.
    ///   - id: The JSON-RPC id of the request.
    private static func logRequestEvent(_ message: Logger.Message, serverName: String, id: JSONRPCID) {
        Log.lspWire.debug(
            message,
            metadata: [
                CodeContextTracing.MetadataKey.lspServer: .string(serverName),
                CodeContextTracing.MetadataKey.lspRequestId: .stringConvertible(id),
            ]
        )
    }

    /// Makes the reply to one server request and puts it in the reply stream.
    /// - Parameters:
    ///   - message: The raw bytes of the server request.
    ///   - id: The id of the server request.
    ///   - method: The method of the server request.
    ///   - serverName: The command name of the language server, for the log record.
    ///   - replies: The stream that gets the reply.
    private static func replyToServerRequest(
        _ message: Data,
        id: JSONRPCID,
        method: String,
        serverName: String,
        replies: AsyncStream<ServerReply>.Continuation
    ) {
        do {
            let payload = try ServerRequestReply.payload(answering: message, id: id, method: method)
            replies.yield(ServerReply(id: id, payload: payload))
        } catch {
            Log.lspWire.error(
                "the reply to a server request could not be encoded",
                metadata: [
                    CodeContextTracing.MetadataKey.lspServer: .string(serverName),
                    CodeContextTracing.MetadataKey.lspMethod: .string(method),
                    CodeContextTracing.MetadataKey.errorType: Log.errorType(of: error),
                ]
            )
        }
    }

    /// Puts one server notification in the notification stream, when the package uses it.
    /// - Parameters:
    ///   - message: The raw bytes of the notification.
    ///   - method: The method of the notification.
    ///   - notifications: The stream that gets the notification.
    private static func publishNotification(
        _ message: Data,
        method: String,
        notifications: AsyncStream<ServerNotification>.Continuation
    ) {
        guard method == "textDocument/publishDiagnostics" else {
            // Every other server-initiated notification (window/logMessage, $/progress, ...) is
            // out of this package's v1 scope and dropped.
            return
        }
        guard let notification = decodePublishDiagnostics(from: message) else {
            return
        }
        notifications.yield(notification)
    }

    /// Decodes a `textDocument/publishDiagnostics` notification's `{ uri, diagnostics }` params.
    private static func decodePublishDiagnostics(from message: Data) -> ServerNotification? {
        struct NotificationEnvelope: Decodable {
            let params: JSONValue
        }
        struct URIOnly: Decodable {
            let uri: DocumentURI
        }

        guard let envelope = try? JSONDecoder().decode(NotificationEnvelope.self, from: message),
            let paramsData = try? JSONEncoder().encode(envelope.params),
            let uriOnly = try? JSONDecoder().decode(URIOnly.self, from: paramsData)
        else {
            return nil
        }

        let diagnostics = DiagnosticsParsing.parsePublishDiagnostics(from: paramsData)
        return .publishDiagnostics(uri: uriOnly.uri, diagnostics: diagnostics)
    }

    /// Drains the child process's stderr until EOF, and keeps every chunk in `tailBuffer`.
    ///
    /// The stderr text of a language server can hold source code or file content, so the text
    /// stays only in the in-memory `tailBuffer`. Each chunk writes one `.debug` record to
    /// `Log.lsp` that holds only the server name and the byte count of the chunk.
    ///
    /// Delegates the read-decode-append loop itself to the shared
    /// `ProcessUtilities.drainChunks(from:bufferSize:onChunk:)` — the same helper
    /// `ProcessInstallRunner.drainOutput` calls — passing only what differs between the two call
    /// sites: what to do with each decoded chunk (log then append here, vs. append alone there).
    /// - Parameters:
    ///   - serverName: The command name of the language server, for the log records.
    ///   - stderrFileDescriptor: The child process's stderr read end's raw file descriptor.
    ///   - tailBuffer: The bounded tail buffer `recentStderrTail()` reads from.
    private static func runStderrDrainLoop(serverName: String, stderrFileDescriptor: Int32, tailBuffer: BoundedTailBuffer) {
        ProcessUtilities.drainChunks(from: stderrFileDescriptor) { text in
            Log.lsp.debug(
                "a language server wrote to standard error",
                metadata: [
                    CodeContextTracing.MetadataKey.lspServer: .string(serverName),
                    CodeContextTracing.MetadataKey.bytes: .stringConvertible(text.utf8.count),
                ]
            )
            tailBuffer.append(chunk: text)
        }
    }

    // MARK: - Reader loop sinks

    /// The reply to one server request, ready to write to the server.
    private struct ServerReply: Sendable {
        /// The id of the server request. The reply holds the same id.
        let id: JSONRPCID

        /// The JSON payload of the reply, not framed.
        let payload: Data
    }

    /// The places where the reader loop sends the messages from the server.
    private struct MessageSinks: Sendable {
        /// The table that gets each response.
        let pendingRequests: PendingRequestTable

        /// The stream that gets each server notification that the package uses.
        let notifications: AsyncStream<ServerNotification>.Continuation

        /// The stream that gets the reply to each server request.
        let replies: AsyncStream<ServerReply>.Continuation

        /// Gets the phase of the loop and the count of each read and each decoded frame.
        let progress: ReaderLoopProgress
    }

    // MARK: - Wire log

    /// The direction of one JSON-RPC wire message, for the `Log.lspWire` records.
    private enum WireDirection: String {
        /// A message that the package writes to the language server.
        case toServer = "to-server"

        /// A message that the package reads from the language server.
        case fromServer = "from-server"
    }

    /// Writes one `.trace` record to `Log.lspWire` for one wire message.
    ///
    /// The record holds only the server name, the direction, the byte size and, when the
    /// message has them, the method name and the request id. It never holds the payload.
    /// - Parameters:
    ///   - direction: Whether the message goes to the server or comes from it.
    ///   - serverName: The command name of the language server.
    ///   - method: The JSON-RPC method name, or `nil` for a response.
    ///   - id: The JSON-RPC request id, or `nil` for a notification.
    ///   - byteCount: The size of the message payload, in bytes.
    private static func logWireMessage(_ direction: WireDirection, serverName: String, method: String?, id: JSONRPCID?, byteCount: Int) {
        var metadata: Logger.Metadata = [
            CodeContextTracing.MetadataKey.lspServer: .string(serverName),
            CodeContextTracing.MetadataKey.lspDirection: .string(direction.rawValue),
            CodeContextTracing.MetadataKey.bytes: .stringConvertible(byteCount),
        ]
        if let method {
            metadata[CodeContextTracing.MetadataKey.lspMethod] = .string(method)
        }
        if let id {
            metadata[CodeContextTracing.MetadataKey.lspRequestId] = .stringConvertible(id)
        }
        Log.lspWire.trace("a JSON-RPC message went over the wire", metadata: metadata)
    }
}

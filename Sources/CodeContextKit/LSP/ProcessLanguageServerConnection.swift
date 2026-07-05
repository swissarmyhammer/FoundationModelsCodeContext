import Darwin
import Foundation

/// Thread-safe table of in-flight JSON-RPC requests, keyed by request id.
///
/// A plain lock-guarded class rather than `ProcessLanguageServerConnection`
/// actor state: a request's `CheckedContinuation` must be registered
/// synchronously inside the `withCheckedThrowingContinuation` closure that
/// creates it (that closure does not run with actor isolation), and the
/// reader loop and timeout race both resolve continuations from outside the
/// actor too. `@unchecked Sendable` is safe because every access goes
/// through `lock`.
private final class PendingRequestTable: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [Int: CheckedContinuation<Data, Error>] = [:]

    /// Registers `continuation` as awaiting the response to request `id`.
    /// - Parameters:
    ///   - id: The JSON-RPC id of the outstanding request.
    ///   - continuation: The continuation to resume when a response or timeout resolves `id`.
    func register(id: Int, continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        defer { lock.unlock() }
        continuations[id] = continuation
    }

    /// Resolves the pending request `id` with `result`, if it is still pending.
    /// - Parameters:
    ///   - id: The JSON-RPC id to resolve.
    ///   - result: The response payload to resume with, or an error (e.g. a timeout).
    /// - Returns: `true` if a pending continuation for `id` was found and resumed; `false` if
    ///   `id` was already resolved (or never registered), in which case `result` is discarded —
    ///   this is what lets a timeout and a late-arriving response race safely.
    @discardableResult
    func resolve(id: Int, with result: Result<Data, Error>) -> Bool {
        lock.lock()
        guard let continuation = continuations.removeValue(forKey: id) else {
            lock.unlock()
            return false
        }
        lock.unlock()
        continuation.resume(with: result)
        return true
    }

    /// Fails every still-pending request with `error`, used when the connection closes or the
    /// child process exits unexpectedly.
    /// - Parameter error: The error to fail every pending request with.
    func failAll(with error: Error) {
        lock.lock()
        let pending = continuations
        continuations.removeAll()
        lock.unlock()
        for continuation in pending.values {
            continuation.resume(throwing: error)
        }
    }
}

/// Thread-safe bounded tail of a child process's stderr output.
///
/// Fed from `runStderrDrainLoop`, which already reads stderr chunks outside actor isolation to
/// log them at `.debug`; this buffer captures the same chunks so `LSPDaemon` can enrich a
/// handshake-failure error with whatever the server printed before it died. A plain
/// `NSLock`-guarded class rather than actor state, matching `PendingRequestTable` above: it must
/// be readable from `recentStderrTail()` without an actor hop, since callers building an error
/// message often can't `await` (e.g. from inside a `catch` that's already off the actor).
/// `@unchecked Sendable` is safe because every access goes through `lock`.
private final class StderrTailBuffer: @unchecked Sendable {
    /// The number of most-recent chunks retained; older chunks are dropped.
    private static let maxChunks = 20

    private let lock = NSLock()
    private var chunks: [String] = []

    /// Appends one stderr chunk, evicting the oldest chunk if the buffer is now over capacity.
    /// - Parameter chunk: The raw text read from the child process's stderr.
    func append(chunk: String) {
        lock.lock()
        defer { lock.unlock() }
        chunks.append(chunk)
        if chunks.count > Self.maxChunks {
            chunks.removeFirst(chunks.count - Self.maxChunks)
        }
    }

    /// A snapshot of every retained chunk, oldest first.
    /// - Returns: The retained stderr chunks joined together, or an empty string if none have
    ///   been captured yet.
    func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return chunks.joined()
    }
}

/// A `LanguageServerConnection` backed by a real language-server child
/// process, talking `Content-Length`-framed JSON-RPC over its stdio.
///
/// Owns the process's three pipes: writes typed requests/notifications to
/// stdin, decodes stdout through `JSONRPCMessageDecoder` on a background
/// reader loop that routes each message to either a pending request (by id)
/// or `serverNotifications`, and drains stderr to `Log.lsp` at `.debug`.
/// Every request races against an injectable `Clock`-driven timeout
/// (30 seconds by default), so a server that never answers fails the caller
/// rather than hanging it forever.
public actor ProcessLanguageServerConnection: LanguageServerConnection {
    private let process: Process
    private let stdinHandle: FileHandle
    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle
    private nonisolated let pendingRequests = PendingRequestTable()
    private nonisolated let stderrTailBuffer = StderrTailBuffer()
    private let requestTimeout: Duration
    private let clock: any Clock<Duration>
    private var nextRequestID = 0
    private var readerTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private var isClosed = false

    /// The spawned child process's id, captured once at launch (a process's id never changes
    /// after `run()` succeeds, so this is safe to expose without an actor hop).
    nonisolated let pid: Int32

    private let notificationContinuation: AsyncStream<ServerNotification>.Continuation

    /// Server-initiated notifications (currently just `publishDiagnostics`), fanned out as they arrive.
    public nonisolated let serverNotifications: AsyncStream<ServerNotification>

    /// Spawns `command` as a child process and opens a JSON-RPC connection to it over its stdio.
    ///
    /// `command` is looked up on `$PATH` via `/usr/bin/env`, matching how `ServerSpec.command`
    /// names language servers (e.g. `"rust-analyzer"`) without requiring a pre-resolved path.
    /// - Parameters:
    ///   - command: The executable to spawn, looked up on `$PATH`.
    ///   - arguments: Arguments passed to `command` on launch. Defaults to none.
    ///   - requestTimeout: How long a request waits for a response before failing with
    ///     `CodeContextError.timeout`. Defaults to 30 seconds.
    ///   - clock: The clock used to schedule the request timeout. Defaults to `ContinuousClock()`;
    ///     tests inject a `ManualClock` to exercise the timeout without waiting in real time.
    /// - Throws: `CodeContextError.spawnFailed` if the process could not be launched.
    init(
        command: String,
        arguments: [String] = [],
        requestTimeout: Duration = .seconds(30),
        clock: any Clock<Duration> = ContinuousClock()
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + arguments

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw CodeContextError.spawnFailed("\(command): \(error.localizedDescription)")
        }

        self.process = process
        self.pid = process.processIdentifier
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutHandle = stdoutPipe.fileHandleForReading
        self.stderrHandle = stderrPipe.fileHandleForReading
        self.requestTimeout = requestTimeout
        self.clock = clock

        let (notificationStream, continuation) = AsyncStream.makeStream(of: ServerNotification.self)
        self.serverNotifications = notificationStream
        self.notificationContinuation = continuation

        // Captured once, here, while the handles are definitely still open: `readChunk(from:)`
        // operates on these raw descriptors rather than the `FileHandle` objects themselves, so
        // the detached loops below never touch a `FileHandle` concurrently with `close()` (see
        // `readChunk(from:)`'s doc comment for why that matters).
        let pendingRequests = self.pendingRequests
        let stdoutFileDescriptor = self.stdoutHandle.fileDescriptor
        self.readerTask = Task.detached {
            Self.runReaderLoop(stdoutFileDescriptor: stdoutFileDescriptor, pendingRequests: pendingRequests, notificationContinuation: continuation)
        }

        let stderrFileDescriptor = self.stderrHandle.fileDescriptor
        let stderrTailBuffer = self.stderrTailBuffer
        self.stderrTask = Task.detached {
            Self.runStderrDrainLoop(stderrFileDescriptor: stderrFileDescriptor, tailBuffer: stderrTailBuffer)
        }
    }

    /// Terminates the child process and releases every resource this connection owns.
    ///
    /// Unconditionally `SIGKILL`s a still-running process rather than sending `SIGTERM` via
    /// `Process.terminate()`: this mirrors `swissarmyhammer-lsp`'s `kill_on_drop(true)`/
    /// `child.kill()` guarantee that a process this connection owns is reaped, not merely asked
    /// to leave — a server that traps or ignores `SIGTERM` would otherwise survive `close()`
    /// indefinitely. Any "ask nicely first" grace period is the caller's responsibility (the
    /// JSON-RPC `shutdown`/`exit` dance plus the grace-period wait `LSPDaemon.shutdown()`
    /// performs before ever reaching this call), not this method's. Once the process actually
    /// exits, its write end of the stdout/stderr pipes closes, which is what stops the reader and
    /// stderr-drain loops: they read via a blocking raw `read(2)` call outside actor isolation,
    /// so `Task.cancel()` alone can't interrupt them, and that `read(2)` call returning `0`
    /// (EOF) is `readChunk(from:)`'s own loop-exit condition. `readerTask`/`stderrTask` are still
    /// cancelled here too, so an already-finished loop doesn't linger as a live (if inert) task.
    /// Fails every still-pending request with `CodeContextError.notRunning` and finishes
    /// `serverNotifications`. Safe to call more than once.
    func close() {
        guard !isClosed else { return }
        isClosed = true

        readerTask?.cancel()
        stderrTask?.cancel()

        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }

        try? stdinHandle.close()
        try? stdoutHandle.close()
        try? stderrHandle.close()

        pendingRequests.failAll(with: CodeContextError.notRunning)
        notificationContinuation.finish()
    }

    // MARK: - Process-level hooks for LSPDaemon

    /// Reports whether the child process is still running.
    ///
    /// Backs the `isAlive` hook `LSPDaemon.processConnectionFactory()` bundles into a
    /// `ConnectionHandle`, so the daemon's `healthCheck()` can detect an unexpected exit.
    /// - Returns: `true` if the process has not exited; `false` once it has.
    func isRunning() -> Bool {
        process.isRunning
    }

    /// Suspends until the child process exits, returning immediately if it already has.
    ///
    /// Waits on `readerTask` rather than polling `process.isRunning`: the reader loop's own exit
    /// condition is stdout EOF, which is exactly the child process's exit signal, so this reuses
    /// the exit-detection `ProcessLanguageServerConnection` already performs to fail pending
    /// requests on process death instead of introducing a second detection path.
    func waitUntilExit() async {
        await readerTask?.value
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

    // MARK: - LanguageServerConnection

    public func initialize(rootURI: DocumentURI?) async throws {
        let params = InitializeParams(processID: Int(ProcessInfo.processInfo.processIdentifier), rootURI: rootURI)
        _ = try await request(method: "initialize", params: params, resultType: InitializeResult.self)
    }

    public func initialized() async throws {
        try await notifyEmpty(method: "initialized")
    }

    public func shutdown() async throws {
        _ = try await request(method: "shutdown", params: EmptyPayload(), resultType: EmptyPayload?.self)
    }

    public func exit() async throws {
        try await notifyEmpty(method: "exit")
    }

    public func didOpen(uri: DocumentURI, languageID: String, version: Int, text: String) async throws {
        let item = TextDocumentItem(uri: uri, languageID: languageID, version: version, text: text)
        try await notify(method: "textDocument/didOpen", params: DidOpenTextDocumentParams(textDocument: item))
    }

    public func didChange(uri: DocumentURI, version: Int, text: String) async throws {
        let params = DidChangeTextDocumentParams(
            textDocument: VersionedTextDocumentIdentifier(uri: uri, version: version),
            contentChanges: [TextDocumentContentChangeEvent(text: text)]
        )
        try await notify(method: "textDocument/didChange", params: params)
    }

    public func didSave(uri: DocumentURI) async throws {
        try await notifyTextDocument(method: "textDocument/didSave", uri: uri, makeParams: DidSaveTextDocumentParams.init)
    }

    public func didClose(uri: DocumentURI) async throws {
        try await notifyTextDocument(method: "textDocument/didClose", uri: uri, makeParams: DidCloseTextDocumentParams.init)
    }

    public func documentSymbols(in uri: DocumentURI) async throws -> [DocumentSymbol] {
        let params = DocumentSymbolParams(textDocument: TextDocumentIdentifier(uri: uri))
        let result = try await request(method: "textDocument/documentSymbol", params: params, resultType: DocumentSymbolResult.self)
        return result.symbols
    }

    public func definition(in uri: DocumentURI, at position: Position) async throws -> [Location] {
        try await positionRequest(method: "textDocument/definition", uri: uri, position: position)
    }

    public func typeDefinition(in uri: DocumentURI, at position: Position) async throws -> [Location] {
        try await positionRequest(method: "textDocument/typeDefinition", uri: uri, position: position)
    }

    public func hover(in uri: DocumentURI, at position: Position) async throws -> Hover? {
        try await requestAtPosition(method: "textDocument/hover", uri: uri, position: position, resultType: Hover?.self)
    }

    public func references(in uri: DocumentURI, at position: Position, includeDeclaration: Bool) async throws -> [Location] {
        let params = ReferenceParams(
            textDocument: TextDocumentIdentifier(uri: uri),
            position: position,
            context: ReferenceContext(includeDeclaration: includeDeclaration)
        )
        return try await locationsRequest(method: "textDocument/references", params: params)
    }

    public func implementations(in uri: DocumentURI, at position: Position) async throws -> [Location] {
        try await positionRequest(method: "textDocument/implementation", uri: uri, position: position)
    }

    public func prepareCallHierarchy(in uri: DocumentURI, at position: Position) async throws -> [CallHierarchyItem] {
        try await arrayRequest(method: "textDocument/prepareCallHierarchy", params: positionParams(uri: uri, position: position), resultType: CallHierarchyItem.self)
    }

    public func outgoingCalls(of item: CallHierarchyItem) async throws -> [CallHierarchyOutgoingCall] {
        try await arrayRequest(method: "callHierarchy/outgoingCalls", params: CallHierarchyCallsParams(item: item), resultType: CallHierarchyOutgoingCall.self)
    }

    public func incomingCalls(of item: CallHierarchyItem) async throws -> [CallHierarchyIncomingCall] {
        try await arrayRequest(method: "callHierarchy/incomingCalls", params: CallHierarchyCallsParams(item: item), resultType: CallHierarchyIncomingCall.self)
    }

    public func prepareRename(in uri: DocumentURI, at position: Position) async throws -> PrepareRenameResult {
        try await requestAtPosition(method: "textDocument/prepareRename", uri: uri, position: position, resultType: PrepareRenameResult.self)
    }

    public func rename(in uri: DocumentURI, at position: Position, newName: String) async throws -> WorkspaceEdit {
        let params = RenameParams(textDocument: TextDocumentIdentifier(uri: uri), position: position, newName: newName)
        return try await request(method: "textDocument/rename", params: params, resultType: WorkspaceEdit.self)
    }

    public func codeActions(in uri: DocumentURI, range: LSPRange, diagnostics: [Diagnostic], only: [String]?) async throws -> [CodeActionItem] {
        let params = CodeActionParams(
            textDocument: TextDocumentIdentifier(uri: uri),
            range: range,
            context: CodeActionContext(diagnostics: diagnostics, only: only)
        )
        return try await arrayRequest(method: "textDocument/codeAction", params: params, resultType: CodeActionItem.self)
    }

    public func resolveCodeAction(item: CodeActionItem) async throws -> CodeActionItem {
        try await request(method: "codeAction/resolve", params: item, resultType: CodeActionItem.self)
    }

    public func workspaceSymbols(query: String) async throws -> [SymbolInformation] {
        try await arrayRequest(method: "workspace/symbol", params: WorkspaceSymbolParams(query: query), resultType: SymbolInformation.self)
    }

    public func pullDiagnostics(for uri: DocumentURI) async throws -> [Diagnostic] {
        let params = DocumentDiagnosticParams(textDocument: TextDocumentIdentifier(uri: uri))
        let (id, data) = try await performRequest(method: "textDocument/diagnostic", params: params)
        let resultData = try Self.rawResultData(from: data, expectedID: id)
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
        let (id, data) = try await performRequest(method: method, params: params)
        return try JSONRPCFraming.decodeResult(as: resultType, from: data, expectedID: id)
    }

    /// Sends a request and returns its raw response payload, unresolved to a typed result.
    ///
    /// Only `pullDiagnostics(for:)` needs this: `textDocument/diagnostic`'s lenient parsing
    /// (`DiagnosticsParsing.parseDiagnosticsFromResult`) operates on the raw `result` bytes, not
    /// a fully-typed decode.
    /// - Parameters:
    ///   - method: The JSON-RPC method name.
    ///   - params: The request's parameters.
    /// - Returns: The request's id and the raw response message bytes.
    /// - Throws: `CodeContextError.notRunning` if the connection can't write to the process;
    ///   `CodeContextError.timeout` if no response arrived in time.
    private func performRequest<Params: Encodable>(method: String, params: Params) async throws -> (id: Int, data: Data) {
        let id = allocateRequestID()
        let envelope = JSONRPCRequestEnvelope(id: id, method: method, params: params)
        let payload = try JSONEncoder().encode(envelope)
        try writeToStdin(JSONRPCFraming.frame(payload: payload))
        let responseData = try await awaitResponse(id: id)
        return (id, responseData)
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
        guard process.isRunning else {
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
    /// timeout never need to hop back onto this actor.
    /// - Parameter id: The JSON-RPC id to wait for.
    /// - Returns: The raw response message bytes.
    /// - Throws: `CodeContextError.timeout` if `requestTimeout` elapses first.
    private func awaitResponse(id: Int) async throws -> Data {
        let timeout = requestTimeout
        let clock = self.clock
        let pendingRequests = self.pendingRequests

        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                    pendingRequests.register(id: id, continuation: continuation)
                }
            }
            group.addTask {
                try await clock.sleep(for: timeout)
                if pendingRequests.resolve(id: id, with: .failure(CodeContextError.timeout(timeout))) {
                    throw CodeContextError.timeout(timeout)
                }
                throw CancellationError()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw CodeContextError.notRunning
            }
            return result
        }
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
    /// pending request (by id) or to `notificationContinuation` (server-initiated notification).
    ///
    /// Runs detached, outside actor isolation: every value it touches
    /// (`pendingRequests`, `notificationContinuation`) is `Sendable`, so no actor hop is needed
    /// per received message. On EOF (the process exited), fails every still-pending request with
    /// `CodeContextError.notRunning`.
    private static func runReaderLoop(
        stdoutFileDescriptor: Int32,
        pendingRequests: PendingRequestTable,
        notificationContinuation: AsyncStream<ServerNotification>.Continuation
    ) {
        var decoder = JSONRPCMessageDecoder()
        while let chunk = Self.readChunk(from: stdoutFileDescriptor) {
            for message in decoder.append(bytes: chunk) {
                route(message: message, pendingRequests: pendingRequests, notificationContinuation: notificationContinuation)
            }
        }
        pendingRequests.failAll(with: CodeContextError.notRunning)
    }

    /// The read chunk size used by both background loops — large enough that a single framed
    /// JSON-RPC message almost always arrives in one read, without requesting an unboundedly
    /// large buffer from the OS.
    private static let readChunkSize = 65536

    /// Reads whatever is currently available from `fileDescriptor`, up to `readChunkSize` bytes.
    ///
    /// Issues a single raw POSIX `read(2)` call on the raw file descriptor rather than going
    /// through any `FileHandle` method, for two reasons neither of which alone is sufficient:
    /// `FileHandle.availableData` raises an Objective-C exception (uncatchable in Swift, crashing
    /// the process) when the handle is closed concurrently with a blocked read, and even
    /// `FileHandle`'s own `.fileDescriptor` property getter raises the same kind of exception once
    /// the handle has been closed — both exactly what happens when `close()` closes a pipe while
    /// this loop, running detached on another thread, is mid-read. The newer throwing
    /// `FileHandle.read(upToCount:)` avoids the exception but loops internally trying to fill the
    /// full requested count (or reach EOF) rather than returning as soon as any data is available,
    /// so it can block indefinitely against a live process that has written less than
    /// `readChunkSize` bytes and has nothing further to send yet. Working from a raw file
    /// descriptor captured once up front (see `readerTask`'s and `stderrTask`'s creation in
    /// `init`) sidesteps both problems: a single `read(2)` call returns as soon as any data is
    /// ready, matching `availableData`'s responsiveness, and reports failure as a plain
    /// `-1`/`errno` rather than an exception, even once the underlying descriptor has been closed
    /// out from under it.
    /// A `read(2)` interrupted by a signal (`EINTR`) before transferring any data is not EOF and
    /// not a real failure — POSIX requires the caller to retry. Under load this is not just a
    /// theoretical nicety: with several `ProcessLanguageServerConnection`s each running two
    /// detached loops blocked in `read(2)`, plus the many child processes those tests spawn and
    /// reap, `SIGCHLD` delivery becomes frequent enough to interrupt an in-flight read. Treating
    /// that the same as EOF (as a bare `bytesRead > 0` check does) fails every pending request
    /// with `.notRunning` on a connection whose process is still very much alive.
    /// - Parameter fileDescriptor: The pipe read end's raw file descriptor.
    /// - Returns: The bytes read, or `nil` at EOF (`read` returns `0`) or on a genuine error
    ///   (`read` returns `-1` with `errno != EINTR`, e.g. because the descriptor was closed
    ///   concurrently) — both end the loop.
    private static func readChunk(from fileDescriptor: Int32) -> Data? {
        var buffer = [UInt8](repeating: 0, count: Self.readChunkSize)
        while true {
            errno = 0
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                return read(fileDescriptor, baseAddress, Self.readChunkSize)
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

    /// Routes one decoded JSON-RPC message to a pending request or a server notification.
    private static func route(
        message: Data,
        pendingRequests: PendingRequestTable,
        notificationContinuation: AsyncStream<ServerNotification>.Continuation
    ) {
        guard let peek = try? JSONRPCFraming.peek(message: message) else {
            Log.lspWire.error("failed to peek malformed JSON-RPC message")
            return
        }

        if let id = peek.id {
            pendingRequests.resolve(id: id, with: .success(message))
            return
        }

        guard let method = peek.method else {
            return
        }
        guard method == "textDocument/publishDiagnostics" else {
            // Every other server-initiated notification (window/logMessage, $/progress, ...) is
            // out of this package's v1 scope and dropped.
            return
        }
        guard let notification = decodePublishDiagnostics(from: message) else {
            return
        }
        notificationContinuation.yield(notification)
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

    /// Drains the child process's stderr to `Log.lsp` at `.debug` until EOF, capturing every
    /// chunk into `tailBuffer` along the way.
    /// - Parameters:
    ///   - stderrFileDescriptor: The child process's stderr read end's raw file descriptor.
    ///   - tailBuffer: The bounded tail buffer `recentStderrTail()` reads from.
    private static func runStderrDrainLoop(stderrFileDescriptor: Int32, tailBuffer: StderrTailBuffer) {
        while let chunk = Self.readChunk(from: stderrFileDescriptor) {
            if let text = String(data: chunk, encoding: .utf8), !text.isEmpty {
                Log.lsp.debug("\(text, privacy: .public)")
                tailBuffer.append(chunk: text)
            }
        }
    }
}

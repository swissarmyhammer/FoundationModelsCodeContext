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
actor ProcessLanguageServerConnection: LanguageServerConnection {
    private let process: Process
    private let stdinHandle: FileHandle
    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle
    private nonisolated let pendingRequests = PendingRequestTable()
    private let requestTimeout: Duration
    private let clock: any Clock<Duration>
    private var nextRequestID = 0
    private var readerTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private var isClosed = false

    private let notificationContinuation: AsyncStream<ServerNotification>.Continuation

    /// Server-initiated notifications (currently just `publishDiagnostics`), fanned out as they arrive.
    nonisolated let serverNotifications: AsyncStream<ServerNotification>

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
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutHandle = stdoutPipe.fileHandleForReading
        self.stderrHandle = stderrPipe.fileHandleForReading
        self.requestTimeout = requestTimeout
        self.clock = clock

        let (notificationStream, continuation) = AsyncStream.makeStream(of: ServerNotification.self)
        self.serverNotifications = notificationStream
        self.notificationContinuation = continuation

        let pendingRequests = self.pendingRequests
        let stdoutHandle = self.stdoutHandle
        self.readerTask = Task.detached {
            Self.runReaderLoop(stdoutHandle: stdoutHandle, pendingRequests: pendingRequests, notificationContinuation: continuation)
        }

        let stderrHandle = self.stderrHandle
        self.stderrTask = Task.detached {
            Self.runStderrDrainLoop(stderrHandle: stderrHandle)
        }
    }

    /// Terminates the child process and releases every resource this connection owns.
    ///
    /// Closes all three pipes — which is what actually stops the reader/stderr loops: they read
    /// via blocking `FileHandle.availableData` outside actor isolation, so `Task.cancel()` alone
    /// can't interrupt them; closing the handles makes `availableData` return empty (EOF), which
    /// is the loops' own exit condition. `readerTask`/`stderrTask` are still cancelled first, so
    /// any already-EOF'd loop doesn't linger as a live (if inert) task. Fails every still-pending
    /// request with `CodeContextError.notRunning` and finishes `serverNotifications`. Safe to call
    /// more than once.
    func close() {
        guard !isClosed else { return }
        isClosed = true

        readerTask?.cancel()
        stderrTask?.cancel()

        if process.isRunning {
            process.terminate()
        }

        try? stdinHandle.close()
        try? stdoutHandle.close()
        try? stderrHandle.close()

        pendingRequests.failAll(with: CodeContextError.notRunning)
        notificationContinuation.finish()
    }

    // MARK: - LanguageServerConnection

    func initialize(rootURI: DocumentURI?) async throws {
        let params = InitializeParams(processID: Int(ProcessInfo.processInfo.processIdentifier), rootURI: rootURI)
        _ = try await request(method: "initialize", params: params, resultType: InitializeResult.self)
    }

    func initialized() async throws {
        try await notifyEmpty(method: "initialized")
    }

    func shutdown() async throws {
        _ = try await request(method: "shutdown", params: EmptyPayload(), resultType: EmptyPayload?.self)
    }

    func exit() async throws {
        try await notifyEmpty(method: "exit")
    }

    func didOpen(uri: DocumentURI, languageID: String, version: Int, text: String) async throws {
        let item = TextDocumentItem(uri: uri, languageID: languageID, version: version, text: text)
        try await notify(method: "textDocument/didOpen", params: DidOpenTextDocumentParams(textDocument: item))
    }

    func didChange(uri: DocumentURI, version: Int, text: String) async throws {
        let params = DidChangeTextDocumentParams(
            textDocument: VersionedTextDocumentIdentifier(uri: uri, version: version),
            contentChanges: [TextDocumentContentChangeEvent(text: text)]
        )
        try await notify(method: "textDocument/didChange", params: params)
    }

    func didSave(uri: DocumentURI) async throws {
        try await notifyTextDocument(method: "textDocument/didSave", uri: uri, makeParams: DidSaveTextDocumentParams.init)
    }

    func didClose(uri: DocumentURI) async throws {
        try await notifyTextDocument(method: "textDocument/didClose", uri: uri, makeParams: DidCloseTextDocumentParams.init)
    }

    func documentSymbols(in uri: DocumentURI) async throws -> [DocumentSymbol] {
        let params = DocumentSymbolParams(textDocument: TextDocumentIdentifier(uri: uri))
        let result = try await request(method: "textDocument/documentSymbol", params: params, resultType: DocumentSymbolResult.self)
        return result.symbols
    }

    func definition(in uri: DocumentURI, at position: Position) async throws -> [Location] {
        try await positionRequest(method: "textDocument/definition", uri: uri, position: position)
    }

    func typeDefinition(in uri: DocumentURI, at position: Position) async throws -> [Location] {
        try await positionRequest(method: "textDocument/typeDefinition", uri: uri, position: position)
    }

    func hover(in uri: DocumentURI, at position: Position) async throws -> Hover? {
        try await requestAtPosition(method: "textDocument/hover", uri: uri, position: position, resultType: Hover?.self)
    }

    func references(in uri: DocumentURI, at position: Position, includeDeclaration: Bool) async throws -> [Location] {
        let params = ReferenceParams(
            textDocument: TextDocumentIdentifier(uri: uri),
            position: position,
            context: ReferenceContext(includeDeclaration: includeDeclaration)
        )
        return try await locationsRequest(method: "textDocument/references", params: params)
    }

    func implementations(in uri: DocumentURI, at position: Position) async throws -> [Location] {
        try await positionRequest(method: "textDocument/implementation", uri: uri, position: position)
    }

    func prepareCallHierarchy(in uri: DocumentURI, at position: Position) async throws -> [CallHierarchyItem] {
        try await arrayRequest(method: "textDocument/prepareCallHierarchy", params: positionParams(uri: uri, position: position), resultType: CallHierarchyItem.self)
    }

    func outgoingCalls(of item: CallHierarchyItem) async throws -> [CallHierarchyOutgoingCall] {
        try await arrayRequest(method: "callHierarchy/outgoingCalls", params: CallHierarchyCallsParams(item: item), resultType: CallHierarchyOutgoingCall.self)
    }

    func incomingCalls(of item: CallHierarchyItem) async throws -> [CallHierarchyIncomingCall] {
        try await arrayRequest(method: "callHierarchy/incomingCalls", params: CallHierarchyCallsParams(item: item), resultType: CallHierarchyIncomingCall.self)
    }

    func prepareRename(in uri: DocumentURI, at position: Position) async throws -> PrepareRenameResult {
        try await requestAtPosition(method: "textDocument/prepareRename", uri: uri, position: position, resultType: PrepareRenameResult.self)
    }

    func rename(in uri: DocumentURI, at position: Position, newName: String) async throws -> WorkspaceEdit {
        let params = RenameParams(textDocument: TextDocumentIdentifier(uri: uri), position: position, newName: newName)
        return try await request(method: "textDocument/rename", params: params, resultType: WorkspaceEdit.self)
    }

    func codeActions(in uri: DocumentURI, range: LSPRange, diagnostics: [Diagnostic], only: [String]?) async throws -> [CodeActionItem] {
        let params = CodeActionParams(
            textDocument: TextDocumentIdentifier(uri: uri),
            range: range,
            context: CodeActionContext(diagnostics: diagnostics, only: only)
        )
        return try await arrayRequest(method: "textDocument/codeAction", params: params, resultType: CodeActionItem.self)
    }

    func resolveCodeAction(item: CodeActionItem) async throws -> CodeActionItem {
        try await request(method: "codeAction/resolve", params: item, resultType: CodeActionItem.self)
    }

    func workspaceSymbols(query: String) async throws -> [SymbolInformation] {
        try await arrayRequest(method: "workspace/symbol", params: WorkspaceSymbolParams(query: query), resultType: SymbolInformation.self)
    }

    func pullDiagnostics(for uri: DocumentURI) async throws -> [Diagnostic] {
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
        stdoutHandle: FileHandle,
        pendingRequests: PendingRequestTable,
        notificationContinuation: AsyncStream<ServerNotification>.Continuation
    ) {
        var decoder = JSONRPCMessageDecoder()
        while true {
            let chunk = stdoutHandle.availableData
            if chunk.isEmpty {
                break
            }
            for message in decoder.append(bytes: chunk) {
                route(message: message, pendingRequests: pendingRequests, notificationContinuation: notificationContinuation)
            }
        }
        pendingRequests.failAll(with: CodeContextError.notRunning)
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

    /// Drains the child process's stderr to `Log.lsp` at `.debug` until EOF.
    private static func runStderrDrainLoop(stderrHandle: FileHandle) {
        while true {
            let chunk = stderrHandle.availableData
            if chunk.isEmpty {
                break
            }
            if let text = String(data: chunk, encoding: .utf8), !text.isEmpty {
                Log.lsp.debug("\(text, privacy: .public)")
            }
        }
    }
}

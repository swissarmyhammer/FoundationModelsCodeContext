import Foundation
import Logging

/// One per-uri diagnostics update, broadcast to in-process subscribers.
///
/// Carries the *latest* full set of diagnostics for `uri` — diagnostics are
/// published as a complete replacement for a document, not as a delta, so
/// each update fully describes the current state of `uri`. Ports
/// `swissarmyhammer-lsp`'s `diagnostics::DiagnosticUpdate`.
struct DiagnosticUpdate: Sendable, Equatable {
    /// The document the diagnostics apply to.
    let uri: DocumentURI

    /// The latest complete set of diagnostics for `uri`.
    let diagnostics: [Diagnostic]
}

/// What the session believes the server knows about one open document.
///
/// `version` is the LSP document version, starting at 1 on `didOpen` and
/// incremented on every text-changing `didChange`. `textHash` is a cheap
/// hash of the text last sent to the server, used so a no-op `syncOpen`
/// (identical text) does not bump the version or emit a notification. Ports
/// `swissarmyhammer-lsp`'s `session::DocState`.
struct DocState: Sendable, Equatable {
    /// The document's LSP version, as last sent to the server.
    let version: Int

    /// A hash of the text last sent to the server for this document.
    let textHash: Int
}

/// One kind of request that `LspSession` sends.
///
/// The session uses it to gate a request on the server capabilities
/// (`LspSessionError.notAdvertised`) and to log a request failure one time
/// for each server (`LspSession.logFailure(of:filePath:error:)`). The raw
/// value is the name that a log record shows.
enum SessionRequest: String, Sendable, Hashable {
    /// Opens a document or sends its new text (`didOpen` or `didChange`).
    case syncOpen

    /// `textDocument/documentSymbol`.
    case documentSymbols

    /// `textDocument/prepareCallHierarchy`, gated on call hierarchy.
    case prepareCallHierarchy

    /// `callHierarchy/outgoingCalls`, gated on call hierarchy.
    case outgoingCalls

    /// `callHierarchy/incomingCalls`, gated on call hierarchy.
    case incomingCalls

    /// `textDocument/references`.
    case references

    /// `textDocument/definition`.
    case definition

    /// `textDocument/implementation`, gated on implementations.
    case implementations

    /// `workspace/symbol`, gated on workspace symbols.
    case workspaceSymbols

    /// `textDocument/didClose`.
    case didClose
}

/// Errors that `LspSession` throws itself, without a request to the server.
enum LspSessionError: Error, Equatable {
    /// The server does not advertise the method of this request in its
    /// `initialize` capabilities, so the session did not send it.
    case notAdvertised(SessionRequest)

    /// The session has the most open documents that it keeps, and an op uses
    /// each one of them now, thus no document can close to make space for a
    /// new one. The associated value is the limit.
    case openDocumentLimit(Int)
}

/// Gives each `LspSessionError` a description for log lines and tool output.
extension LspSessionError: LocalizedError {
    /// The text that `localizedDescription` gives for this error.
    var errorDescription: String? {
        switch self {
        case .notAdvertised(let request):
            return "the server does not advertise \(request.rawValue)"
        case .openDocumentLimit(let limit):
            return "each of the \(limit) open documents is in use, thus no document can open"
        }
    }
}

/// Makes the text that tells a caller that a language server does not have
/// the method of a request.
///
/// `LspSessionError.notAdvertised` tells a log line the same fact. An op
/// result must tell its caller too, because an empty result list alone does
/// not show the difference between "no results" and "the server does not have
/// this method". The ops put this text in the `notSupportedReason` field of
/// their result (`ImplementationsResult`, `WorkspaceSymbolsResult`), and the
/// tools give that field to the model.
///
/// The text names the request with the raw value of `SessionRequest`, the
/// same name that a log line shows.
enum NotSupportedText {
    /// The text for one server that does not have the method.
    /// - Parameters:
    ///   - serverName: The name of the server, for example `pylsp`.
    ///   - request: The request that the server does not have.
    /// - Returns: One sentence for the result of an op.
    static func server(_ serverName: String, doesNotHave request: SessionRequest) -> String {
        "The language server \(serverName) does not have \(request.rawValue)."
    }

    /// The text for a group of servers when no one of them has the method.
    /// - Parameters:
    ///   - request: The request that no server has.
    ///   - serverNames: The names of the servers that run.
    /// - Returns: One sentence for the result of an op.
    static func noRunningServerHas(_ request: SessionRequest, serverNames: [String]) -> String {
        "No language server that runs has \(request.rawValue). These servers run: \(serverNames.joined(separator: ", "))."
    }
}

/// The `error.code` values that a pull-diagnostics response carries when the
/// server answers "still loading, retrigger later" rather than a real report
/// (LSP 3.17+). A generic type cannot hold a stored static property, thus the
/// values are in this non-generic namespace.
private enum NotReadyErrorCode {
    /// `ServerCancelled`.
    static let serverCancelled = -32802

    /// `ContentModified`, the server's other "still loading" signal.
    static let contentModified = -32801
}

/// A single owned LSP session over one `LanguageServerConnection`: the
/// open-document set, the diagnostics cache and its multi-subscriber
/// fan-out, and the server's observed readiness.
///
/// Ports `swissarmyhammer-lsp`'s `session::LspSession` as a Swift actor: the
/// document-set/client mutex pair and the `tokio::sync::broadcast` channel
/// from the Rust original collapse into plain actor-isolated state plus an
/// actor-managed set of `AsyncStream` continuations (Swift's `AsyncStream`
/// only supports a single iterator per stream, so fan-out to N subscribers
/// means handing each subscriber its own stream backed by its own
/// continuation, all fed from the same `recordDiagnostics(uri:diagnostics:)`
/// write path).
///
/// The open-document set has a limit and an owner for each document (see
/// `OpenDocuments`). At the limit, the session closes the least recently used
/// document that no op uses now before it opens one more. The index worker
/// closes only the documents that it owns (`closeIfOwned(uri:by:)`).
///
/// On creation, the session starts consuming `connection.serverNotifications`
/// in the background so `textDocument/publishDiagnostics` pushes land in the
/// cache and fan-out without any caller having to drive a read loop.
actor LspSession<Connection: LanguageServerConnection> {
    /// The one connection this session drives.
    private let connection: Connection

    /// The LSP `languageId` sent on every `didOpen` (e.g. `"swift"`). One
    /// session serves one server, which serves one language family.
    private let languageID: String

    /// What the server is believed to have open, with the owner, the last
    /// use and the use count of each document.
    private var documents: OpenDocuments

    /// The documents that an open or a close works on now.
    ///
    /// `LspSession` is an actor, and an actor is reentrant at each `await`.
    /// One sync reads the open-document set, waits for the send, and then
    /// writes the set. A second sync of the same URI in that wait could send
    /// a second `didOpen`, and a close in that wait could make the sync skip
    /// a reopen. Thus one open or close of a URI runs at a time: a URI in
    /// this set is held, and the next caller for it waits in
    /// `documentWaiters`.
    private var busyDocuments: Set<DocumentURI> = []

    /// The callers that wait for a URI of `busyDocuments`, in FIFO order.
    private var documentWaiters: [DocumentURI: [CheckedContinuation<Void, Never>]] = [:]

    /// Latest-per-uri diagnostics cache: `uri -> latest full diagnostic set.
    ///
    /// Derived state — a live mirror of what the server most recently
    /// published (push) or returned (pull) for each document. Never
    /// persisted; rebuilt from server output and discarded on
    /// `resetDocuments()` or when the session is deallocated.
    private var diagnosticsCache: [DocumentURI: [Diagnostic]] = [:]

    /// Live diagnostics subscribers, keyed by an internal id so a
    /// terminated subscriber's continuation can be removed individually.
    private var diagnosticsSubscribers: [Int: AsyncStream<DiagnosticUpdate>.Continuation] = [:]

    /// The id the next `diagnosticUpdates()` subscriber will be registered
    /// under.
    private var nextSubscriberID = 0

    /// Whether the server is believed ready to report diagnostics for the
    /// workspace. See `isReady`.
    private(set) var isReady = true

    /// The background task draining `connection.serverNotifications` into
    /// the diagnostics cache and fan-out.
    ///
    /// `nonisolated(unsafe)`: assigned once from `init` (before the closure
    /// capturing `self` can run) and only ever read/cancelled from `deinit`
    /// afterward, so it is never accessed concurrently despite living
    /// outside actor isolation. It must be nonisolated because `init`
    /// creating the `Task` that captures `self` makes `self` "escape" the
    /// initializer from the compiler's point of view — after that point,
    /// only nonisolated members of `self` may be written from within `init`.
    private nonisolated(unsafe) var notificationConsumerTask: Task<Void, Never>?

    /// The name of the server that this session talks to (its command, for
    /// example `"pylsp"`). Log lines name the server with it.
    nonisolated let serverName: String

    /// The gated capabilities that the server advertised in its `initialize`
    /// result. A gated request that the server does not advertise is not
    /// sent; the request method throws `LspSessionError.notAdvertised`.
    nonisolated let capabilities: ServerCapabilities

    /// The logger that gets the failure records (see `logFailure(of:filePath:error:)`).
    private let logger: Logger

    /// The requests whose failure this session already logged. The log has
    /// a maximum of one record for each (server, request) pair.
    private var loggedFailures: Set<SessionRequest> = []

    /// Creates a session over `connection`, immediately starting to consume
    /// its `serverNotifications` in the background.
    /// - Parameters:
    ///   - connection: The connection this session drives every document-sync and
    ///     diagnostics operation through.
    ///   - languageID: The LSP `languageId` to send on every `didOpen` (e.g. `"swift"`).
    ///   - serverName: The name of the server, used in log lines.
    ///   - capabilities: The gated capabilities that the server advertised.
    ///   - maximumOpenDocuments: The most documents that the session keeps
    ///     open on the server. Defaults to `OpenDocuments.defaultLimit`; tests
    ///     give a small limit.
    ///   - logger: The logger that gets the failure records. Defaults to
    ///     `Log.lsp`; tests give a logger that keeps the records instead.
    init(
        connection: Connection,
        languageID: String,
        serverName: String,
        capabilities: ServerCapabilities,
        maximumOpenDocuments: Int = OpenDocuments.defaultLimit,
        logger: Logger = Log.lsp
    ) {
        self.connection = connection
        self.languageID = languageID
        self.serverName = serverName
        self.capabilities = capabilities
        self.documents = OpenDocuments(limit: maximumOpenDocuments)
        self.logger = logger
        notificationConsumerTask = Task { [weak self] in
            await self?.consumeServerNotifications()
        }
    }

    deinit {
        notificationConsumerTask?.cancel()
        for continuation in diagnosticsSubscribers.values {
            continuation.finish()
        }
    }

    /// Snapshots the current open-document set (`uri -> DocState`).
    /// - Returns: A copy of the open-document set; not a live view.
    func openDocuments() -> [DocumentURI: DocState] {
        documents.states
    }

    /// The number of live diagnostics subscribers, for tests to observe
    /// that a terminated subscriber's continuation is actually removed
    /// from the fan-out set rather than leaking.
    /// - Returns: How many `diagnosticUpdates()` streams are currently registered.
    func diagnosticsSubscriberCount() -> Int {
        diagnosticsSubscribers.count
    }

    /// Makes the server's buffer for `uri` match `text`, opening the
    /// document if the session has never seen it.
    ///
    /// The first sync for a uri sends `textDocument/didOpen` at version 1.
    /// A later sync for an already-open uri refreshes the buffer via
    /// `textDocument/didChange`, but only when `text` actually differs from
    /// what was last sent — an unchanged re-sync costs nothing on the wire.
    /// Because the session keeps documents open across requests, callers
    /// that depend on a document's current text (a query op, a diagnostics
    /// pull) should call this before issuing that request.
    ///
    /// Each sync marks the document as the most recently used. A sync by a
    /// tool op makes the tool ops the owner of the document. When the set is
    /// full, a new document first closes the least recently used document
    /// that no op uses now. Two syncs of one URI run one after the other, thus
    /// they send one `didOpen` only.
    ///
    /// A sync does not keep the document open for the request that follows
    /// it: an op that must keep the document open uses
    /// `beginUse(uri:text:owner:)` and `endUse(uri:)`.
    /// - Parameters:
    ///   - uri: The document to open or refresh.
    ///   - text: The document's full current content.
    ///   - owner: Who syncs the document. Defaults to `DocumentOwner.tool`.
    /// - Throws: `LspSessionError.openDocumentLimit` when the set is full and
    ///   an op uses each open document; whatever `connection.didClose` throws
    ///   for the document that must close first; whatever
    ///   `connection.didOpen`/`didChange` throws (e.g. a transport failure).
    func syncOpen(uri: DocumentURI, text: String, owner: DocumentOwner = .tool) async throws {
        await acquireDocumentGate(for: uri)
        defer { releaseDocumentGate(for: uri) }
        let newHash = Self.hashText(text)
        guard let state = documents.state(of: uri) else {
            try await sendOpen(of: uri, text: text, textHash: newHash, owner: owner)
            return
        }
        documents.touch(uri, by: owner)
        try await sendChange(of: uri, from: state, text: text, textHash: newHash)
    }

    /// Syncs `uri` like `syncOpen(uri:text:owner:)` and adds one use of the
    /// document, so that the limit does not close it and its owner does not
    /// close it until the op calls `endUse(uri:)`.
    ///
    /// The use begins before the sync, thus no close runs between the sync
    /// and the request that the op sends next. When the sync throws, the use
    /// ends before the error goes to the caller, thus the caller calls
    /// `endUse(uri:)` only after a sync that did not throw.
    /// - Parameters:
    ///   - uri: The document to open or refresh.
    ///   - text: The document's full current content.
    ///   - owner: Who uses the document.
    /// - Throws: Whatever `syncOpen(uri:text:owner:)` throws.
    func beginUse(uri: DocumentURI, text: String, owner: DocumentOwner) async throws {
        documents.beginUse(of: uri)
        do {
            try await syncOpen(uri: uri, text: text, owner: owner)
        } catch {
            documents.endUse(of: uri)
            throw error
        }
    }

    /// Ends one use that `beginUse(uri:text:owner:)` began. The document
    /// stays open; the limit or its owner closes it later.
    /// - Parameter uri: The document that the op does not use any more.
    func endUse(uri: DocumentURI) {
        documents.endUse(of: uri)
    }

    /// Sends `didClose` for `uri` when `owner` owns the open document and no
    /// op uses it now, then forgets the document.
    ///
    /// The index worker calls this with `DocumentOwner.indexer` after it
    /// indexes a file, on each path. A document that a tool op synced
    /// belongs to the tool ops, thus the worker does not close it; the limit
    /// closes it later. If the notification fails, the document stays in the
    /// set: the server may still believe that the document is open, so a
    /// later sync continues with `didChange`.
    /// - Parameters:
    ///   - uri: The document to close.
    ///   - owner: The owner that closes the document.
    /// - Throws: Whatever `connection.didClose(uri:)` throws.
    func closeIfOwned(uri: DocumentURI, by owner: DocumentOwner) async throws {
        await acquireDocumentGate(for: uri)
        defer { releaseDocumentGate(for: uri) }
        guard documents.owner(of: uri) == owner, !documents.isInUse(uri) else {
            return
        }
        try await sendClose(of: uri)
    }

    /// Forgets every open document and every cached diagnostic, without
    /// sending any `didClose`.
    ///
    /// Called when the underlying server process is gone (shutdown, health
    /// check failure, or just before a restart): the new process knows
    /// nothing about what the old one had open, so the open set must be
    /// cleared to match. Sending `didClose` here would be wrong — the
    /// server the old documents were opened against no longer exists. After
    /// a reset, the next `syncOpen` for any uri emits a fresh `didOpen`
    /// instead of being suppressed as a stale duplicate. The diagnostics
    /// cache is cleared too: it is derived state describing the gone
    /// process's analysis, so it must not outlive that process. The use
    /// counts stay, because each op that uses a document now ends its use
    /// later.
    func resetDocuments() {
        documents.removeAllEntries()
        diagnosticsCache.removeAll()
    }

    /// Sends `didChange` with the next version when `textHash` differs from
    /// the hash of the text that the server has, then records the new state.
    /// The caller holds the gate of `uri`.
    /// - Parameters:
    ///   - uri: The open document.
    ///   - state: What the server has now.
    ///   - text: The new full text.
    ///   - textHash: The hash of `text`.
    /// - Throws: Whatever `connection.didChange` throws.
    private func sendChange(of uri: DocumentURI, from state: DocState, text: String, textHash: Int) async throws {
        guard state.textHash != textHash else {
            // No textual change since the last sync — nothing to send.
            return
        }
        let next = DocState(version: state.version + 1, textHash: textHash)
        try await connection.didChange(uri: uri, version: next.version, text: text)
        documents.setState(next, of: uri)
    }

    /// Makes space for one more document, records `uri` in the set, and then
    /// sends `didOpen` at version 1. The caller holds the gate of `uri`.
    ///
    /// The entry goes into the set before the `await` of the send, with no
    /// `await` between the space check and the insert. Thus two opens of two
    /// URIs at the same time cannot both use the last free place, and the
    /// set never holds more than its limit. When the send fails, the entry
    /// goes out of the set again.
    /// - Parameters:
    ///   - uri: The document to open.
    ///   - text: The full text.
    ///   - textHash: The hash of `text`.
    ///   - owner: Who opens the document.
    /// - Throws: Whatever `makeSpaceForOneDocument()` or `connection.didOpen` throws.
    private func sendOpen(of uri: DocumentURI, text: String, textHash: Int, owner: DocumentOwner) async throws {
        try await makeSpaceForOneDocument()
        let state = DocState(version: 1, textHash: textHash)
        documents.insert(uri, state: state, owner: owner)
        do {
            try await connection.didOpen(uri: uri, languageID: languageID, version: state.version, text: text)
        } catch {
            documents.remove(uri)
            throw error
        }
    }

    /// Closes the least recently used documents that no op uses now, until
    /// the set has space for one more document.
    ///
    /// A document that an open or a close works on now is not a candidate.
    /// When a `didClose` fails, the open that needs the space fails too, thus
    /// the set never holds more than its limit.
    /// - Throws: `LspSessionError.openDocumentLimit` when no document can
    ///   close; whatever `connection.didClose` throws.
    private func makeSpaceForOneDocument() async throws {
        while documents.isFull {
            guard let leastRecentlyUsed = documents.leastRecentlyUsed(excluding: busyDocuments) else {
                throw LspSessionError.openDocumentLimit(documents.limit)
            }
            // The candidate is not in `busyDocuments`, thus the gate is free
            // and the insert holds it with no wait.
            busyDocuments.insert(leastRecentlyUsed)
            defer { releaseDocumentGate(for: leastRecentlyUsed) }
            try await sendClose(of: leastRecentlyUsed)
        }
    }

    /// Sends `didClose` for `uri`, then forgets the document. When the send
    /// fails, the document stays in the set. The caller holds the gate of
    /// `uri`.
    /// - Parameter uri: The document to close.
    /// - Throws: Whatever `connection.didClose(uri:)` throws.
    private func sendClose(of uri: DocumentURI) async throws {
        try await connection.didClose(uri: uri)
        documents.remove(uri)
    }

    /// Waits until no other open or close works on `uri`, then holds the
    /// gate of `uri`. Paired with `releaseDocumentGate(for:)`.
    /// - Parameter uri: The document to hold.
    private func acquireDocumentGate(for uri: DocumentURI) async {
        guard busyDocuments.contains(uri) else {
            busyDocuments.insert(uri)
            return
        }
        await withCheckedContinuation { continuation in
            documentWaiters[uri, default: []].append(continuation)
        }
    }

    /// Releases the gate that `acquireDocumentGate(for:)` holds: gives it to
    /// the next FIFO waiter for `uri` when one waits, or frees it.
    /// - Parameter uri: The document to release.
    private func releaseDocumentGate(for uri: DocumentURI) {
        guard var waiters = documentWaiters[uri], !waiters.isEmpty else {
            busyDocuments.remove(uri)
            return
        }
        let next = waiters.removeFirst()
        documentWaiters[uri] = waiters.isEmpty ? nil : waiters
        next.resume()
    }

    /// Requests the symbols declared in a document, delegating directly to
    /// `connection.documentSymbols(in:)`.
    ///
    /// - Parameter uri: The document to query; should already be synced via
    ///   `syncOpen(uri:text:owner:)` so the server sees its current content.
    /// - Returns: The document's symbols.
    /// - Throws: Whatever `connection.documentSymbols(in:)` throws.
    func documentSymbols(uri: DocumentURI) async throws -> [DocumentSymbol] {
        try await connection.documentSymbols(in: uri)
    }

    /// Requests the call-hierarchy item(s) rooted at a position, delegating
    /// to `connection.prepareCallHierarchy(in:at:)` when the server
    /// advertises call hierarchy.
    ///
    /// - Parameters:
    ///   - uri: The document containing the cursor position; should already
    ///     be synced via `syncOpen(uri:text:owner:)` so the server sees its
    ///     current content.
    ///   - position: The cursor position to query.
    /// - Returns: Zero or more call-hierarchy items.
    /// - Throws: `LspSessionError.notAdvertised` without a request when the
    ///   server does not advertise call hierarchy; otherwise whatever
    ///   `connection.prepareCallHierarchy(in:at:)` throws.
    func prepareCallHierarchy(uri: DocumentURI, position: Position) async throws -> [CallHierarchyItem] {
        try requireAdvertised(.prepareCallHierarchy, isAdvertised: capabilities.callHierarchy)
        return try await connection.prepareCallHierarchy(in: uri, at: position)
    }

    /// Requests every call made *from* a call-hierarchy item, delegating
    /// to `connection.outgoingCalls(of:)` when the server advertises call
    /// hierarchy.
    ///
    /// - Parameter item: The item previously returned by
    ///   `prepareCallHierarchy(uri:position:)`.
    /// - Returns: Zero or more outgoing calls.
    /// - Throws: `LspSessionError.notAdvertised` without a request when the
    ///   server does not advertise call hierarchy; otherwise whatever
    ///   `connection.outgoingCalls(of:)` throws.
    func outgoingCalls(item: CallHierarchyItem) async throws -> [CallHierarchyOutgoingCall] {
        try requireAdvertised(.outgoingCalls, isAdvertised: capabilities.callHierarchy)
        return try await connection.outgoingCalls(of: item)
    }

    /// Requests every call made *into* a call-hierarchy item, delegating
    /// to `connection.incomingCalls(of:)` when the server advertises call
    /// hierarchy.
    ///
    /// - Parameter item: The item previously returned by
    ///   `prepareCallHierarchy(uri:position:)`.
    /// - Returns: Zero or more incoming calls.
    /// - Throws: `LspSessionError.notAdvertised` without a request when the
    ///   server does not advertise call hierarchy; otherwise whatever
    ///   `connection.incomingCalls(of:)` throws.
    func incomingCalls(item: CallHierarchyItem) async throws -> [CallHierarchyIncomingCall] {
        try requireAdvertised(.incomingCalls, isAdvertised: capabilities.callHierarchy)
        return try await connection.incomingCalls(of: item)
    }

    /// Requests the definition site of the symbol at a position, delegating
    /// directly to `connection.definition(in:at:)`.
    ///
    /// - Parameters:
    ///   - uri: The document containing the cursor position; should already
    ///     be synced via `syncOpen(uri:text:owner:)` so the server sees its
    ///     current content.
    ///   - position: The cursor position to query.
    /// - Returns: Zero or more definition locations.
    /// - Throws: Whatever `connection.definition(in:at:)` throws.
    func definition(uri: DocumentURI, at position: Position) async throws -> [Location] {
        try await connection.definition(in: uri, at: position)
    }

    /// Requests the type-definition site of the symbol at a position,
    /// delegating directly to `connection.typeDefinition(in:at:)`.
    ///
    /// - Parameters:
    ///   - uri: The document containing the cursor position; should already
    ///     be synced via `syncOpen(uri:text:owner:)` so the server sees its
    ///     current content.
    ///   - position: The cursor position to query.
    /// - Returns: Zero or more type-definition locations.
    /// - Throws: Whatever `connection.typeDefinition(in:at:)` throws.
    func typeDefinition(uri: DocumentURI, at position: Position) async throws -> [Location] {
        try await connection.typeDefinition(in: uri, at: position)
    }

    /// Requests hover information for the symbol at a position, delegating
    /// directly to `connection.hover(in:at:)`.
    ///
    /// - Parameters:
    ///   - uri: The document containing the cursor position; should already
    ///     be synced via `syncOpen(uri:text:owner:)` so the server sees its
    ///     current content.
    ///   - position: The cursor position to query.
    /// - Returns: The hover contents, or `nil` if the server has nothing to
    ///   show.
    /// - Throws: Whatever `connection.hover(in:at:)` throws.
    func hover(uri: DocumentURI, at position: Position) async throws -> Hover? {
        try await connection.hover(in: uri, at: position)
    }

    /// Requests every reference to the symbol at a position, delegating
    /// directly to `connection.references(in:at:includeDeclaration:)`.
    ///
    /// - Parameters:
    ///   - uri: The document containing the cursor position; should already
    ///     be synced via `syncOpen(uri:text:owner:)` so the server sees its
    ///     current content.
    ///   - position: The cursor position to query.
    ///   - includeDeclaration: Whether the declaration site itself should be
    ///     included.
    /// - Returns: Zero or more reference locations.
    /// - Throws: Whatever `connection.references(in:at:includeDeclaration:)` throws.
    func references(uri: DocumentURI, at position: Position, includeDeclaration: Bool) async throws -> [Location] {
        try await connection.references(in: uri, at: position, includeDeclaration: includeDeclaration)
    }

    /// Requests every implementation of the symbol at a position, delegating
    /// to `connection.implementations(in:at:)` when the server advertises
    /// implementations.
    ///
    /// - Parameters:
    ///   - uri: The document containing the cursor position; should already
    ///     be synced via `syncOpen(uri:text:owner:)` so the server sees its
    ///     current content.
    ///   - position: The cursor position to query.
    /// - Returns: Zero or more implementation locations.
    /// - Throws: `LspSessionError.notAdvertised` without a request when the
    ///   server does not advertise implementations; otherwise whatever
    ///   `connection.implementations(in:at:)` throws.
    func implementations(uri: DocumentURI, at position: Position) async throws -> [Location] {
        try requireAdvertised(.implementations, isAdvertised: capabilities.implementation)
        return try await connection.implementations(in: uri, at: position)
    }

    /// Requests the code actions available for a range, delegating directly
    /// to `connection.codeActions(in:range:diagnostics:only:)`.
    ///
    /// - Parameters:
    ///   - uri: The document containing the range; should already be synced
    ///     via `syncOpen(uri:text:owner:)` so the server sees its current content.
    ///   - range: The span to request actions for.
    ///   - diagnostics: The diagnostics currently in scope for `range`.
    ///   - only: If non-`nil`, restricts the server to these code-action kinds.
    /// - Returns: Zero or more code actions.
    /// - Throws: Whatever `connection.codeActions(in:range:diagnostics:only:)` throws.
    func codeActions(uri: DocumentURI, range: LSPRange, diagnostics: [Diagnostic], only: [String]?) async throws -> [CodeActionItem] {
        try await connection.codeActions(in: uri, range: range, diagnostics: diagnostics, only: only)
    }

    /// Resolves a code action's deferred fields, delegating directly to
    /// `connection.resolveCodeAction(item:)`.
    ///
    /// - Parameter item: The code action previously returned by `codeActions(uri:range:diagnostics:only:)`.
    /// - Returns: The same action with its deferred fields filled in.
    /// - Throws: Whatever `connection.resolveCodeAction(item:)` throws.
    func resolveCodeAction(item: CodeActionItem) async throws -> CodeActionItem {
        try await connection.resolveCodeAction(item: item)
    }

    /// Searches the workspace for symbols matching a query string,
    /// delegating directly to `connection.workspaceSymbols(query:)`.
    ///
    /// Unlike every other request wrapper above, this one is document-less:
    /// it needs no prior `syncOpen(uri:text:owner:)` call, since `workspace/symbol`
    /// is not scoped to any single open document.
    /// - Parameter query: The search string, interpreted by the server (typically fuzzy).
    /// - Returns: Zero or more matching symbols.
    /// - Throws: `LspSessionError.notAdvertised` without a request when the
    ///   server does not advertise workspace symbols; otherwise whatever
    ///   `connection.workspaceSymbols(query:)` throws.
    func workspaceSymbols(query: String) async throws -> [SymbolInformation] {
        try requireAdvertised(.workspaceSymbols, isAdvertised: capabilities.workspaceSymbol)
        return try await connection.workspaceSymbols(query: query)
    }

    /// Throws when the server does not advertise the method of `request`,
    /// so that the caller sends no request.
    /// - Parameters:
    ///   - request: The gated request the caller is about to send.
    ///   - isAdvertised: Whether the server advertises the method of `request`.
    /// - Throws: `LspSessionError.notAdvertised(request)` when `isAdvertised` is `false`.
    private func requireAdvertised(_ request: SessionRequest, isAdvertised: Bool) throws {
        guard isAdvertised else {
            throw LspSessionError.notAdvertised(request)
        }
    }

    /// Logs a request failure, one time for each (server, request) pair.
    ///
    /// The index worker sends some requests for each symbol of each file.
    /// When a server refuses a request, each symbol fails in the same way,
    /// and one record for each symbol hides the other log records. Thus only
    /// the first failure of each request is logged. The record has a fixed
    /// message. Its metadata holds the name of the server, the request, the
    /// file path, the type name of `error` and, for a server error, the
    /// JSON-RPC error code. It never holds the error message of the server or
    /// the description of `error`, because they can hold content.
    /// - Parameters:
    ///   - request: The request that failed.
    ///   - filePath: The path, relative to the root directory, of the file
    ///     that the request was about.
    ///   - error: The error the request threw.
    internal func logFailure(of request: SessionRequest, filePath: String, error: any Error) {
        guard loggedFailures.insert(request).inserted else {
            return
        }
        var metadata: Logger.Metadata = [
            CodeContextTracing.MetadataKey.lspServer: .string(serverName),
            CodeContextTracing.MetadataKey.lspRequest: .string(request.rawValue),
            CodeContextTracing.MetadataKey.errorType: Log.errorType(of: error),
            CodeContextTracing.MetadataKey.filePath: .string(filePath),
        ]
        if case WireError.serverError(let code, _) = error {
            metadata[CodeContextTracing.MetadataKey.lspErrorCode] = .string("\(code)")
        }
        logger.warning(
            "a language server request failed; the log does not show the next failures of this request for this server",
            metadata: metadata
        )
    }

    /// A first-in-first-out mutual-exclusion gate held by `prepareRenameAndRename`.
    ///
    /// `LspSession` is a Swift actor, and actors are reentrant at every
    /// `await`: while `prepareRenameAndRename` is suspended awaiting
    /// `connection.prepareRename(in:at:)`, a *different* concurrent
    /// `prepareRenameAndRename` call already queued on this same actor is
    /// free to run its own `prepareRename`/`rename` pair before the first
    /// call resumes and issues its own `rename` — splitting what should be
    /// one atomic request/response pair across two logically unrelated
    /// rename batches. This flag, together with `renameLockWaiters`, closes
    /// exactly that gap: whichever caller acquires the gate first runs its
    /// whole `prepareRename` + `rename` pair to completion before the next
    /// queued caller's pair begins. Port of `swissarmyhammer-lsp`'s
    /// `lsp_multi_request_batch` "hold the client for the whole batch"
    /// semantics — this session has no cross-process client to hold, so the
    /// gate is scoped to serializing this session's own rename batches
    /// against each other instead.
    private var renameLockHeld = false

    /// Continuations of `prepareRenameAndRename` calls queued behind
    /// `renameLockHeld`, resumed one at a time by `releaseRenameLock()` in
    /// FIFO order.
    private var renameLockWaiters: [CheckedContinuation<Void, Never>] = []

    /// Waits until no other `prepareRenameAndRename` batch holds the gate,
    /// then claims it. Paired with `releaseRenameLock()`.
    private func acquireRenameLock() async {
        guard renameLockHeld else {
            renameLockHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            renameLockWaiters.append(continuation)
        }
    }

    /// Releases the gate `acquireRenameLock()` claimed: hands it directly to
    /// the next FIFO waiter if one is queued, or marks it free otherwise.
    private func releaseRenameLock() {
        guard renameLockWaiters.isEmpty else {
            renameLockWaiters.removeFirst().resume()
            return
        }
        renameLockHeld = false
    }

    /// Runs `prepareRename` then, only if the server reports the position is
    /// renameable, `rename` — as one atomic batch (see `acquireRenameLock()`'s
    /// documentation): no other concurrent `prepareRenameAndRename` call on
    /// this session can interleave its own `prepareRename`/`rename` pair
    /// between this call's two requests.
    ///
    /// - Parameters:
    ///   - uri: The document containing the cursor position; should already
    ///     be synced via `syncOpen(uri:text:owner:)` so the server sees its
    ///     current content.
    ///   - position: The cursor position to query.
    ///   - newName: The symbol's new name.
    /// - Returns: `prepareRename`'s answer, alongside the `rename` edit —
    ///   `edit` is `nil` when `prepareRename` reports the position can't be
    ///   renamed, in which case `rename` is never called at all.
    /// - Throws: Whatever `connection.prepareRename(in:at:)`/
    ///   `connection.rename(in:at:newName:)` throw.
    func prepareRenameAndRename(
        uri: DocumentURI, at position: Position, newName: String
    ) async throws -> (prepare: PrepareRenameResult, edit: WorkspaceEdit?) {
        await acquireRenameLock()
        defer { releaseRenameLock() }
        let prepare = try await connection.prepareRename(in: uri, at: position)
        guard prepare.range != nil else {
            return (prepare, nil)
        }
        let edit = try await connection.rename(in: uri, at: position, newName: newName)
        return (prepare, edit)
    }

    /// The latest captured diagnostics for a document uri.
    /// - Parameter uri: The document to look up.
    /// - Returns: A snapshot of the cached diagnostics, or an empty array if
    ///   none have been captured for `uri`.
    func diagnostics(for uri: DocumentURI) -> [Diagnostic] {
        diagnosticsCache[uri] ?? []
    }

    /// Subscribes to the in-process diagnostics fan-out.
    ///
    /// Every diagnostics batch captured after this call — whether it
    /// arrived via a push `publishDiagnostics` notification or a pull
    /// `pullDiagnostics(uri:)` request — is yielded to the returned stream.
    /// Each call returns an independent stream backed by its own
    /// continuation, so every subscriber sees every update; a subscriber
    /// that wants the state captured *before* it subscribed should read it
    /// via `diagnostics(for:)` first.
    /// - Returns: A stream of diagnostics updates, one per captured batch.
    func diagnosticUpdates() -> AsyncStream<DiagnosticUpdate> {
        let subscriberID = nextSubscriberID
        nextSubscriberID += 1
        let (stream, continuation) = AsyncStream.makeStream(of: DiagnosticUpdate.self)
        diagnosticsSubscribers[subscriberID] = continuation
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.removeDiagnosticsSubscriber(id: subscriberID) }
        }
        return stream
    }

    /// Requests diagnostics for a document via the pull model
    /// (`textDocument/diagnostic`, LSP 3.17+) and feeds the result through
    /// the same cache and fan-out as push diagnostics.
    ///
    /// A pull issued before the server has finished loading the workspace
    /// is answered with its "still loading, retrigger later" signal
    /// (`ServerCancelled` / `ContentModified`) rather than a real report:
    /// that flips `isReady` false and returns an empty array *without*
    /// caching or broadcasting it — caching an empty body here would let a
    /// consumer misread "still loading" as "the file is clean". Any other
    /// error propagates to the caller unchanged and leaves `isReady`
    /// untouched.
    /// - Parameter uri: The document to request diagnostics for.
    /// - Returns: The document's current diagnostics, or an empty array if the
    ///   server reported it is still loading.
    /// - Throws: Whatever `connection.pullDiagnostics(for:)` throws, apart from the
    ///   "still loading" signal, which is handled rather than propagated.
    func pullDiagnostics(uri: DocumentURI) async throws -> [Diagnostic] {
        do {
            let diagnostics = try await connection.pullDiagnostics(for: uri)
            isReady = true
            recordDiagnostics(uri: uri, diagnostics: diagnostics)
            return diagnostics
        } catch let error as WireError {
            guard case .serverError(let code, _) = error, Self.isNotReadyErrorCode(code) else {
                throw error
            }
            isReady = false
            return []
        }
    }

    /// Drains `connection.serverNotifications` for the session's lifetime,
    /// feeding every `publishDiagnostics` push into the cache and fan-out.
    private func consumeServerNotifications() async {
        let notifications = await connection.serverNotifications
        for await notification in notifications {
            switch notification {
            case .publishDiagnostics(let uri, let diagnostics):
                recordDiagnostics(uri: uri, diagnostics: diagnostics)
            }
        }
    }

    /// Replaces the cached diagnostics for `uri` and broadcasts the update
    /// to every live subscriber.
    ///
    /// The single write path shared by push (`consumeServerNotifications`)
    /// and pull (`pullDiagnostics(uri:)`), so the cache and the fan-out
    /// never drift apart.
    /// - Parameters:
    ///   - uri: The document the diagnostics apply to.
    ///   - diagnostics: The latest complete set of diagnostics for `uri`.
    private func recordDiagnostics(uri: DocumentURI, diagnostics: [Diagnostic]) {
        diagnosticsCache[uri] = diagnostics
        let update = DiagnosticUpdate(uri: uri, diagnostics: diagnostics)
        for continuation in diagnosticsSubscribers.values {
            continuation.yield(update)
        }
    }

    /// Removes a terminated subscriber's continuation from the fan-out set.
    /// - Parameter id: The subscriber id assigned by `diagnosticUpdates()`.
    private func removeDiagnosticsSubscriber(id: Int) {
        diagnosticsSubscribers.removeValue(forKey: id)
    }

    /// Whether a pull-diagnostics error code is the server's "still
    /// loading, retrigger later" signal rather than a genuine failure.
    /// - Parameter code: The JSON-RPC `error.code` from a pull response.
    /// - Returns: `true` for `ServerCancelled` or `ContentModified`.
    private static func isNotReadyErrorCode(_ code: Int) -> Bool {
        code == NotReadyErrorCode.serverCancelled || code == NotReadyErrorCode.contentModified
    }

    /// Hashes a document's text for cheap no-op-change detection.
    /// - Parameter text: The document text to hash.
    /// - Returns: A process-local hash of `text`, stable only for the lifetime of the process.
    private static func hashText(_ text: String) -> Int {
        var hasher = Hasher()
        hasher.combine(text)
        return hasher.finalize()
    }
}

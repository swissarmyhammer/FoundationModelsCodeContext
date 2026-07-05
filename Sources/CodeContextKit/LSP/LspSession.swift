import Foundation

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
/// On creation, the session starts consuming `connection.serverNotifications`
/// in the background so `textDocument/publishDiagnostics` pushes land in the
/// cache and fan-out without any caller having to drive a read loop.
actor LspSession<Connection: LanguageServerConnection> {
    /// The `error.code` a pull-diagnostics response carries when the server
    /// answers "still loading, retrigger later" rather than a real report
    /// (`ServerCancelled`, LSP 3.17+).
    private static var serverCancelledErrorCode: Int { -32802 }

    /// The `error.code` a pull-diagnostics response carries for the
    /// server's other "still loading" signal (`ContentModified`).
    private static var contentModifiedErrorCode: Int { -32801 }

    /// The one connection this session drives.
    private let connection: Connection

    /// The LSP `languageId` sent on every `didOpen` (e.g. `"swift"`). One
    /// session serves one server, which serves one language family.
    private let languageID: String

    /// What the server is believed to have open: `uri -> DocState`.
    private var docs: [DocumentURI: DocState] = [:]

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

    /// Creates a session over `connection`, immediately starting to consume
    /// its `serverNotifications` in the background.
    /// - Parameters:
    ///   - connection: The connection this session drives every document-sync and
    ///     diagnostics operation through.
    ///   - languageID: The LSP `languageId` to send on every `didOpen` (e.g. `"swift"`).
    init(connection: Connection, languageID: String) {
        self.connection = connection
        self.languageID = languageID
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
        docs
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
    /// - Parameters:
    ///   - uri: The document to open or refresh.
    ///   - text: The document's full current content.
    /// - Throws: Whatever `connection.didOpen`/`didChange` throws (e.g. a
    ///   transport failure).
    func syncOpen(uri: DocumentURI, text: String) async throws {
        let newHash = Self.hashText(text)
        if let state = docs[uri] {
            guard state.textHash != newHash else {
                // No textual change since the last sync — nothing to send.
                return
            }
            let nextVersion = state.version + 1
            try await connection.didChange(uri: uri, version: nextVersion, text: text)
            docs[uri] = DocState(version: nextVersion, textHash: newHash)
        } else {
            try await connection.didOpen(uri: uri, languageID: languageID, version: 1, text: text)
            docs[uri] = DocState(version: 1, textHash: newHash)
        }
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
    /// process's analysis, so it must not outlive that process.
    func resetDocuments() {
        docs.removeAll()
        diagnosticsCache.removeAll()
    }

    /// Requests the symbols declared in a document, delegating directly to
    /// `connection.documentSymbols(in:)`.
    ///
    /// - Parameter uri: The document to query; should already be synced via
    ///   `syncOpen(uri:text:)` so the server sees its current content.
    /// - Returns: The document's symbols.
    /// - Throws: Whatever `connection.documentSymbols(in:)` throws.
    func documentSymbols(uri: DocumentURI) async throws -> [DocumentSymbol] {
        try await connection.documentSymbols(in: uri)
    }

    /// Requests the call-hierarchy item(s) rooted at a position, delegating
    /// directly to `connection.prepareCallHierarchy(in:at:)`.
    ///
    /// - Parameters:
    ///   - uri: The document containing the cursor position; should already
    ///     be synced via `syncOpen(uri:text:)` so the server sees its
    ///     current content.
    ///   - position: The cursor position to query.
    /// - Returns: Zero or more call-hierarchy items.
    /// - Throws: Whatever `connection.prepareCallHierarchy(in:at:)` throws.
    func prepareCallHierarchy(uri: DocumentURI, position: Position) async throws -> [CallHierarchyItem] {
        try await connection.prepareCallHierarchy(in: uri, at: position)
    }

    /// Requests every call made *from* a call-hierarchy item, delegating
    /// directly to `connection.outgoingCalls(of:)`.
    ///
    /// - Parameter item: The item previously returned by
    ///   `prepareCallHierarchy(uri:position:)`.
    /// - Returns: Zero or more outgoing calls.
    /// - Throws: Whatever `connection.outgoingCalls(of:)` throws.
    func outgoingCalls(item: CallHierarchyItem) async throws -> [CallHierarchyOutgoingCall] {
        try await connection.outgoingCalls(of: item)
    }

    /// Requests every call made *into* a call-hierarchy item, delegating
    /// directly to `connection.incomingCalls(of:)`.
    ///
    /// - Parameter item: The item previously returned by
    ///   `prepareCallHierarchy(uri:position:)`.
    /// - Returns: Zero or more incoming calls.
    /// - Throws: Whatever `connection.incomingCalls(of:)` throws.
    func incomingCalls(item: CallHierarchyItem) async throws -> [CallHierarchyIncomingCall] {
        try await connection.incomingCalls(of: item)
    }

    /// Requests the definition site of the symbol at a position, delegating
    /// directly to `connection.definition(in:at:)`.
    ///
    /// - Parameters:
    ///   - uri: The document containing the cursor position; should already
    ///     be synced via `syncOpen(uri:text:)` so the server sees its
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
    ///     be synced via `syncOpen(uri:text:)` so the server sees its
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
    ///     be synced via `syncOpen(uri:text:)` so the server sees its
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
    ///     be synced via `syncOpen(uri:text:)` so the server sees its
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
    /// directly to `connection.implementations(in:at:)`.
    ///
    /// - Parameters:
    ///   - uri: The document containing the cursor position; should already
    ///     be synced via `syncOpen(uri:text:)` so the server sees its
    ///     current content.
    ///   - position: The cursor position to query.
    /// - Returns: Zero or more implementation locations.
    /// - Throws: Whatever `connection.implementations(in:at:)` throws.
    func implementations(uri: DocumentURI, at position: Position) async throws -> [Location] {
        try await connection.implementations(in: uri, at: position)
    }

    /// Requests the code actions available for a range, delegating directly
    /// to `connection.codeActions(in:range:diagnostics:only:)`.
    ///
    /// - Parameters:
    ///   - uri: The document containing the range; should already be synced
    ///     via `syncOpen(uri:text:)` so the server sees its current content.
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
    /// it needs no prior `syncOpen(uri:text:)` call, since `workspace/symbol`
    /// is not scoped to any single open document.
    /// - Parameter query: The search string, interpreted by the server (typically fuzzy).
    /// - Returns: Zero or more matching symbols.
    /// - Throws: Whatever `connection.workspaceSymbols(query:)` throws.
    func workspaceSymbols(query: String) async throws -> [SymbolInformation] {
        try await connection.workspaceSymbols(query: query)
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
    ///     be synced via `syncOpen(uri:text:)` so the server sees its
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

    /// Notifies the server that a document was closed, then forgets it from
    /// the open-document set.
    ///
    /// Unlike `resetDocuments()` — which forgets every document without
    /// notifying a (presumed-gone) server — this notifies the still-live
    /// server via `connection.didClose(uri:)` first, so a later
    /// `syncOpen(uri:text:)` for the same uri is correctly treated as
    /// never-opened (a fresh `didOpen`) rather than a stale duplicate. If
    /// the notification fails, the open-document entry is left in place: the
    /// server may still believe the document is open, so a later
    /// `syncOpen(uri:text:)` correctly continues sending `didChange`.
    /// - Parameter uri: The document to close.
    /// - Throws: Whatever `connection.didClose(uri:)` throws; the
    ///   open-document entry is only forgotten once the notification
    ///   succeeds.
    func didClose(uri: DocumentURI) async throws {
        try await connection.didClose(uri: uri)
        docs.removeValue(forKey: uri)
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
            guard case let .serverError(code, _) = error, Self.isNotReadyErrorCode(code) else {
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
            case let .publishDiagnostics(uri, diagnostics):
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
        code == serverCancelledErrorCode || code == contentModifiedErrorCode
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

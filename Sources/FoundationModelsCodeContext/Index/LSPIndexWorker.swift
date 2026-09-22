import Foundation
import GRDB

/// Idle/backoff pacing knobs for `LSPIndexWorker.run(store:rootDirectory:extensions:sessionProvider:configuration:clock:)`.
///
/// Port of `swissarmyhammer-code-context`'s `LspWorkerConfig`.
struct LSPIndexWorkerConfiguration: Sendable, Equatable {
    /// Maximum dirty files drained per batch before the drain loop re-queries.
    let batchSize: Int

    /// How long the continuous loop sleeps when no dirty files remain.
    let idleSleep: Duration

    /// How long the continuous loop sleeps when dirty files exist but no
    /// session is currently available.
    let sessionUnavailableSleep: Duration

    /// Creates a worker configuration.
    /// - Parameters:
    ///   - batchSize: Maximum dirty files drained per batch. Defaults to 50,
    ///     matching `swissarmyhammer-code-context`'s `LspWorkerConfig::default`.
    ///   - idleSleep: Sleep duration when no dirty files remain. Defaults to
    ///     500 milliseconds.
    ///   - sessionUnavailableSleep: Sleep duration when the session is
    ///     unavailable. Defaults to 5 seconds.
    init(
        batchSize: Int = 50,
        idleSleep: Duration = .milliseconds(500),
        sessionUnavailableSleep: Duration = .seconds(5)
    ) {
        self.batchSize = batchSize
        self.idleSleep = idleSleep
        self.sessionUnavailableSleep = sessionUnavailableSleep
    }
}

/// Drains `lsp_indexed = 0` files matching one language server's extensions,
/// indexing each via `textDocument/documentSymbol` and call-hierarchy
/// requests over a shared `LspSession`.
///
/// Port of `swissarmyhammer-code-context`'s `lsp_worker.rs` +
/// `lsp_communication.rs` + `lsp_indexer.rs` + `invalidation.rs`, adapted to
/// this port's `lsp_symbols`/`lsp_call_edges` schema (see
/// `TSCallGraph`/`SymbolOps` for the established conventions this worker
/// follows):
///
/// - `lsp_symbols.id` is an autoincrementing integer, not the Rust
///   reference's `"lsp:{file}:{qualified_path}"` string, so this port has no
///   persisted qualified-path column. A symbol's stable on-disk identity is
///   instead `(file_path, start_line)` — the same correlation key
///   `TSCallGraph.ensureSymbolID` and `SymbolOps`'s candidate merge already
///   use — so a re-indexed file's unchanged symbols keep their row (and
///   their edges), while symbols whose start line disappears are deleted.
/// - Unlike the Rust reference — whose worker doc comment states it "never
///   sends `didClose`" because the daemon-owned session keeps every file
///   open indefinitely — this port's worker closes each file's document
///   after querying it (see `processFile(relativePath:rootDirectory:session:store:)`),
///   trading a `didClose` round trip per file for a bounded open-document
///   set on the server. This is a deliberate divergence for this Swift port,
///   not an oversight.
/// - A file whose `documentSymbol`/`didOpen` request throws is left dirty
///   (`lsp_indexed` stays `0`) so a later pass retries it once the
///   connection recovers, and nothing is written for it this pass — unlike
///   the Rust reference, which marks a failed file indexed anyway to avoid
///   an infinite retry loop. This port instead treats such a failure as
///   transient (a connection hiccup, not a permanently broken file).
/// - The call edges come from call hierarchy only when the server advertises
///   it (`LspSession.capabilities`). A server without call hierarchy (for
///   example `pylsp`) gets no `prepareCallHierarchy` request: the worker
///   finds the callers of each callable symbol with `textDocument/references`
///   instead (see `LSPIndexWorker+References.swift`). A pass of an edited
///   file of such a server also marks the files of the symbols that its new
///   calls call `lsp_indexed = 0`, so their next pass writes the new caller.
/// - A request failure is logged through `LspSession.logFailure(of:context:error:)`,
///   one time for each (server, request) pair. A server that refuses a
///   request for each symbol thus writes one log line, not one line for each
///   symbol.
///
/// Every symbol/edge write and the `lsp_indexed` flag flip for one file
/// happen inside a single `Store.write` transaction (see
/// `writeFile(db:filePath:flatSymbols:pendingEdges:callSiteTargets:)`), matching
/// `TreeSitterWorker`'s established atomicity pattern: a process
/// interrupted mid-drain never leaves a file's rows committed with its flag
/// still `0`, or vice versa.
enum LSPIndexWorker<Connection: LanguageServerConnection> {
    /// Maximum number of `?` bind parameters used in one dynamically-sized
    /// `IN (...)` clause, mirroring `swissarmyhammer-code-context::invalidation`'s
    /// `SQLITE_IN_CHUNK_SIZE` so a pathologically large symbol-deletion count
    /// never exceeds SQLite's bind-parameter limit.
    private static var sqliteInChunkSize: Int { 900 }

    /// LSP symbol kinds whose call-hierarchy is collected, mirroring the
    /// Rust reference's `SymbolKind::FUNCTION | METHOD | CONSTRUCTOR` filter.
    ///
    /// A `Set` membership check, not a `switch`: unlike `kindString(for:)`
    /// below (an exhaustive mapping from every `SymbolKind` case to a
    /// distinct value), this is a plain "is this kind in a fixed subset?"
    /// test, which a set expresses more directly than a switch with a
    /// catch-all `default:` arm. Checked inline at its call sites rather
    /// than through a wrapper function. Not `private`: the references
    /// fallback (`LSPIndexWorker+References.swift`) uses it too, to pick
    /// the callee symbols and the caller symbols.
    static var callableKinds: Set<SymbolKind> { [.function, .method, .constructor] }

    // MARK: - Continuous loop

    /// Runs the drain loop until the calling task is cancelled: repeatedly
    /// drains a batch of `lsp_indexed = 0` files matching `extensions`,
    /// sleeping `configuration.idleSleep` when none are dirty and
    /// `configuration.sessionUnavailableSleep` when `sessionProvider()`
    /// currently returns `nil`.
    ///
    /// `sessionProvider` is re-invoked at the start of every batch rather
    /// than resolved once: per `LSPDaemon.session()`'s documented caution,
    /// this port builds a fresh `LspSession` on every successful daemon
    /// restart, so a session reference captured before a restart would
    /// silently point at a torn-down connection for the rest of this loop's
    /// lifetime.
    /// - Parameters:
    ///   - store: The workspace's index store to drain and write into.
    ///   - rootDirectory: The workspace root dirty file paths are relative to.
    ///   - extensions: The file extensions (without a leading dot) this
    ///     server's session covers; only dirty files matching one of these
    ///     are drained.
    ///   - sessionProvider: Returns the current session for this server, or
    ///     `nil` if the daemon isn't running. Re-invoked before every batch.
    ///   - configuration: Batch size and idle/unavailable backoff pacing.
    ///     Defaults to `LSPIndexWorkerConfiguration()`.
    ///   - clock: The clock idle/unavailable sleeps wait against. Defaults
    ///     to `ContinuousClock()`; tests inject a `ManualClock`.
    /// - Throws: Rethrows `Store`'s storage errors, or `CancellationError`
    ///   if the calling task is cancelled while sleeping.
    static func run(
        store: Store,
        rootDirectory: URL,
        extensions: [String],
        sessionProvider: @escaping @Sendable () async -> LspSession<Connection>?,
        configuration: LSPIndexWorkerConfiguration = LSPIndexWorkerConfiguration(),
        clock: any Clock<Duration> = ContinuousClock()
    ) async throws {
        while !Task.isCancelled {
            let dirtyPaths = try await dirtyFiles(store: store, extensions: extensions, limit: configuration.batchSize)
            guard !dirtyPaths.isEmpty else {
                try await clock.sleep(for: configuration.idleSleep)
                continue
            }

            guard let session = await sessionProvider() else {
                try await clock.sleep(for: configuration.sessionUnavailableSleep)
                continue
            }

            for relativePath in dirtyPaths {
                guard !Task.isCancelled else { return }
                await processFile(relativePath: relativePath, rootDirectory: rootDirectory, session: session, store: store)
            }
        }
    }

    // MARK: - Single batch drain

    /// Drains one batch (up to `configuration.batchSize`) of `lsp_indexed = 0`
    /// files matching `extensions` through `session`, without looping or
    /// sleeping — the building block `run(store:rootDirectory:extensions:sessionProvider:configuration:clock:)`
    /// repeats, and the entry point tests drive directly.
    /// - Parameters:
    ///   - store: The workspace's index store to drain and write into.
    ///   - rootDirectory: The workspace root dirty file paths are relative to.
    ///   - extensions: The file extensions (without a leading dot) this
    ///     server's session covers; only dirty files matching one of these
    ///     are drained.
    ///   - session: The live session to index through.
    ///   - configuration: Supplies `batchSize`. Defaults to
    ///     `LSPIndexWorkerConfiguration()`.
    /// - Returns: The number of dirty files successfully indexed and marked
    ///   `lsp_indexed = 1` this pass — excludes any file left dirty after a
    ///   connection error.
    /// - Throws: Rethrows `Store`'s storage errors from the dirty-file query
    ///   itself (per-file failures are caught and logged, not rethrown).
    @discardableResult
    static func drainBatch(
        store: Store,
        rootDirectory: URL,
        extensions: [String],
        session: LspSession<Connection>,
        configuration: LSPIndexWorkerConfiguration = LSPIndexWorkerConfiguration()
    ) async throws -> Int {
        let dirtyPaths = try await dirtyFiles(store: store, extensions: extensions, limit: configuration.batchSize)

        var indexedCount = 0
        for relativePath in dirtyPaths {
            let indexed = await processFile(relativePath: relativePath, rootDirectory: rootDirectory, session: session, store: store)
            if indexed {
                indexedCount += 1
            }
        }
        return indexedCount
    }

    // MARK: - Dirty file query

    /// Queries `lsp_indexed = 0` files whose path ends in one of
    /// `extensions`, oldest-path-first, capped at `limit`.
    ///
    /// Every extension is bound as a `LIKE` pattern argument rather than
    /// interpolated into the SQL text, matching this codebase's
    /// parameterized-query convention (see `TSCallGraph.resolveCallees`).
    /// - Parameters:
    ///   - store: The workspace's index store to query.
    ///   - extensions: The file extensions (without a leading dot) to match.
    ///     An empty list matches nothing, mirroring the Rust reference's
    ///     "unknown server -> empty extensions -> no files" behavior.
    ///   - limit: The maximum number of paths to return.
    /// - Returns: Matching dirty file paths, in path order.
    /// - Throws: Rethrows `Store`'s storage errors.
    private static func dirtyFiles(store: Store, extensions: [String], limit: Int) async throws -> [String] {
        guard !extensions.isEmpty else {
            return []
        }

        let likeClauses = extensions.map { _ in "\(Schema.IndexedFiles.filePath) LIKE ?" }.joined(separator: " OR ")
        let patterns = extensions.map { fileExtension in "%.\(fileExtension)" }
        let arguments = StatementArguments(patterns) + StatementArguments([limit])

        return try await store.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT \(Schema.IndexedFiles.filePath) FROM \(Schema.IndexedFiles.table) \
                    WHERE \(Schema.IndexedFiles.lspIndexed) = 0 AND (\(likeClauses)) \
                    ORDER BY \(Schema.IndexedFiles.filePath) LIMIT ?
                    """,
                arguments: arguments
            )
        }
    }

    // MARK: - Per-file processing

    /// Indexes one dirty file end-to-end: syncs its current disk content,
    /// requests `textDocument/documentSymbol`, flattens the result, requests
    /// call-hierarchy edges for its callable symbols, closes the document,
    /// then persists everything atomically and marks the file
    /// `lsp_indexed = 1`.
    ///
    /// `relativePath` is checked with `RelativePath.isSafeRelativePath(_:)` before it is
    /// ever resolved against disk: a `..` component, or a leading `/` or
    /// `~`, is rejected and the file is marked indexed with nothing
    /// written, the same "unreadable, nothing to retry" outcome as below.
    /// The walker/reconciler that populates `indexed_files.file_path`
    /// should already only ever write workspace-relative paths, but this
    /// layer doesn't trust data flowing back out of the store any more
    /// than it trusts other store-sourced input elsewhere in this file.
    ///
    /// A file that can't be read (missing, non-UTF-8) is marked indexed with
    /// nothing written — mirroring `TreeSitterWorker`'s handling of an
    /// unreadable file, there is nothing meaningful to retry. A `syncOpen`
    /// or `documentSymbol` failure, by contrast, leaves the file dirty and
    /// writes nothing for it — see this type's doc comment for why this
    /// differs from the Rust reference. A `prepareCallHierarchy`/
    /// `outgoingCalls` failure for one symbol only skips that symbol's
    /// edges (logged, non-fatal); the file's symbols are still persisted. A
    /// `didClose` failure is logged but never blocks persistence — every
    /// piece of data needed to index the file has already been collected by
    /// that point.
    /// - Parameters:
    ///   - relativePath: The file's workspace-relative path.
    ///   - rootDirectory: The workspace root `relativePath` is relative to.
    ///   - session: The live session to index through.
    ///   - store: The workspace's index store to write into.
    /// - Returns: `true` if the file is now `lsp_indexed = 1` (whether
    ///   because it was fully indexed or because it was unreadable); `false`
    ///   if a connection error left it dirty for a later retry.
    @discardableResult
    private static func processFile(
        relativePath: String,
        rootDirectory: URL,
        session: LspSession<Connection>,
        store: Store
    ) async -> Bool {
        guard RelativePath.isSafeRelativePath(relativePath) else {
            Log.lsp.warning(
                "rejecting unsafe relative path \(relativePath, privacy: .public) for LSP indexing (possible path traversal); marking indexed"
            )
            return await markIndexedIgnoringErrors(relativePath: relativePath, store: store)
        }

        guard let contents = readFileContents(relativePath: relativePath, rootDirectory: rootDirectory) else {
            Log.lsp.warning("failed to read \(relativePath, privacy: .public) for LSP indexing; marking indexed")
            return await markIndexedIgnoringErrors(relativePath: relativePath, store: store)
        }

        let fileURL = rootDirectory.appendingPathComponent(relativePath)
        let uri = DocumentURI(fileURL.absoluteString)

        guard
            let documentSymbols = await syncAndFetchSymbols(
                relativePath: relativePath,
                uri: uri,
                contents: contents,
                session: session
            )
        else {
            return false
        }

        let flatSymbols = flattenSymbols(filePath: relativePath, symbols: documentSymbols)
        let pendingEdges = await collectCallEdges(
            filePath: relativePath,
            uri: uri,
            contents: contents,
            flatSymbols: flatSymbols,
            rootDirectory: rootDirectory,
            session: session
        )
        let callSiteTargets = await collectCallSiteTargets(
            filePath: relativePath,
            uri: uri,
            contents: contents,
            flatSymbols: flatSymbols,
            rootDirectory: rootDirectory,
            session: session,
            store: store
        )

        await closeDocument(uri: uri, relativePath: relativePath, session: session)

        do {
            try await store.write { db in
                try writeFile(
                    db: db,
                    filePath: relativePath,
                    flatSymbols: flatSymbols,
                    pendingEdges: pendingEdges,
                    callSiteTargets: callSiteTargets
                )
            }
        } catch {
            Log.lsp.error(
                "failed to persist LSP index for \(relativePath, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return false
        }

        return true
    }

    /// Syncs `contents` to the session then requests `textDocument/documentSymbol`,
    /// logging and returning `nil` if either step throws.
    ///
    /// Factored out of `processFile(relativePath:rootDirectory:session:store:)`
    /// so its two "leave dirty on failure" branches share one early-return
    /// shape at the call site instead of duplicating it. Not `private`: the
    /// references fallback uses it too, to read the symbols of a file that
    /// holds a reference. A failure is logged through
    /// `LspSession.logFailure(of:context:error:)`, one time for each
    /// (server, request) pair.
    /// - Parameters:
    ///   - relativePath: The file's workspace-relative path, used only for log messages.
    ///   - uri: The document uri to sync and query.
    ///   - contents: The file's current disk content.
    ///   - session: The live session to sync and query through.
    /// - Returns: The document's symbols, or `nil` if `syncOpen`/`documentSymbols` threw.
    static func syncAndFetchSymbols(
        relativePath: String,
        uri: DocumentURI,
        contents: String,
        session: LspSession<Connection>
    ) async -> [DocumentSymbol]? {
        do {
            try await session.syncOpen(uri: uri, text: contents)
        } catch {
            await session.logFailure(of: .syncOpen, context: relativePath, error: error)
            return nil
        }

        do {
            return try await session.documentSymbols(uri: uri)
        } catch {
            await session.logFailure(of: .documentSymbols, context: relativePath, error: error)
            return nil
        }
    }

    /// Sends `didClose` for `uri`, logging (not propagating) a failure: every
    /// piece of data the worker needs from the document is already collected
    /// when it closes the document.
    /// - Parameters:
    ///   - uri: The document to close.
    ///   - relativePath: The file's workspace-relative path, used only for log messages.
    ///   - session: The live session to close the document through.
    static func closeDocument(uri: DocumentURI, relativePath: String, session: LspSession<Connection>) async {
        do {
            try await session.didClose(uri: uri)
        } catch {
            await session.logFailure(of: .didClose, context: relativePath, error: error)
        }
    }

    /// Reads `relativePath`'s content from disk as UTF-8 text, or `nil` if
    /// it can't be read or decoded.
    /// - Parameters:
    ///   - relativePath: The file's workspace-relative path.
    ///   - rootDirectory: The workspace root `relativePath` is relative to.
    /// - Returns: The file's decoded text, or `nil` on any read/decode failure.
    static func readFileContents(relativePath: String, rootDirectory: URL) -> String? {
        let fileURL = rootDirectory.appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: fileURL), let contents = String(data: data, encoding: .utf8) else {
            return nil
        }
        return contents
    }

    /// Marks `relativePath` `lsp_indexed = 1`, logging (rather than
    /// propagating) any storage failure — used for both of `processFile`'s
    /// permanent-skip paths (an unreadable file and an unsafe/traversal
    /// relative path, per `RelativePath.isSafeRelativePath(_:)`), where there is nothing
    /// left to retry even if the mark itself fails.
    /// - Parameters:
    ///   - relativePath: The file's workspace-relative path.
    ///   - store: The workspace's index store to write into.
    /// - Returns: `true` unconditionally, matching this path's "nothing to
    ///   retry" contract even when the mark write itself fails.
    private static func markIndexedIgnoringErrors(relativePath: String, store: Store) async -> Bool {
        do {
            try await store.markIndexed(filePath: relativePath, layer: .lsp)
        } catch {
            Log.lsp.error(
                "failed to mark \(relativePath, privacy: .public) lsp-indexed after a permanent-skip decision: \(error.localizedDescription, privacy: .public)"
            )
        }
        return true
    }

    // MARK: - Flattening

    /// One `textDocument/documentSymbol` result symbol flattened out of its
    /// nested tree, carrying a fully qualified path built by joining
    /// ancestor names with `Chunker.symbolPathSeparator`.
    ///
    /// Port of `swissarmyhammer-code-context::lsp_indexer::FlatSymbol`. This
    /// port's `lsp_symbols` schema has no persisted qualified-path column
    /// (see this file's type-level doc comment), so `qualifiedPath` here is
    /// a purely in-memory value used only to name call-hierarchy log
    /// messages — a symbol's stable on-disk identity is
    /// `(filePath, startLine)`, computed separately in `writeFile(db:filePath:flatSymbols:pendingEdges:)`.
    ///
    /// Not `private`: the references fallback (`LSPIndexWorker+References.swift`)
    /// reads the symbols of the files that hold a reference in this shape too.
    struct FlatSymbol: Sendable, Hashable {
        /// The symbol's short name, e.g. `"new"`.
        let name: String

        /// The symbol's fully qualified path, e.g. `"MyStruct.new"`.
        let qualifiedPath: String

        /// The symbol's LSP kind.
        let kind: SymbolKind

        /// The file containing the symbol, relative to the workspace root.
        let filePath: String

        /// The symbol's zero-based start line.
        let startLine: Int

        /// The symbol's zero-based start column.
        let startColumn: Int

        /// The symbol's zero-based end line.
        let endLine: Int

        /// The symbol's zero-based end column.
        let endColumn: Int

        /// The start of the symbol's selection range: the name for a
        /// hierarchical `DocumentSymbol`, the same as the range start for a
        /// flat `SymbolInformation`. The search for the name starts here.
        let selectionStart: Position

        /// Extra detail about the symbol (e.g. a function signature), if any.
        let detail: String?

        /// Whether the range of this symbol holds `position`.
        /// - Parameter position: The position to test.
        /// - Returns: `true` when `position` is at or after the start and at
        ///   or before the end of the symbol.
        func contains(_ position: Position) -> Bool {
            (startLine, startColumn) <= (position.line, position.character)
                && (position.line, position.character) <= (endLine, endColumn)
        }

        /// This symbol as one end of a pending call edge.
        var endpoint: EdgeEndpoint {
            EdgeEndpoint(
                filePath: filePath,
                name: name,
                kind: kindString(for: kind),
                range: LSPRange(
                    start: Position(line: startLine, character: startColumn),
                    end: Position(line: endLine, character: endColumn)
                ),
                detail: detail
            )
        }
    }

    /// Flattens a `textDocument/documentSymbol` result tree into a flat list
    /// with qualified paths, walking every symbol's `children` recursively.
    /// - Parameters:
    ///   - filePath: The file the symbols were requested for.
    ///   - symbols: The top-level symbols returned by the server.
    /// - Returns: One `FlatSymbol` per symbol in the tree (parents and
    ///   children alike), in depth-first order.
    static func flattenSymbols(filePath: String, symbols: [DocumentSymbol]) -> [FlatSymbol] {
        var flattened: [FlatSymbol] = []
        appendFlattenedSymbols(filePath: filePath, symbols: symbols, parentPath: nil, into: &flattened)
        return flattened
    }

    /// Recursive helper behind `flattenSymbols(filePath:symbols:)`, threading
    /// the accumulated qualified path down into each symbol's children.
    private static func appendFlattenedSymbols(
        filePath: String,
        symbols: [DocumentSymbol],
        parentPath: String?,
        into flattened: inout [FlatSymbol]
    ) {
        for symbol in symbols {
            let qualifiedPath = parentPath.map { "\($0)\(Chunker.symbolPathSeparator)\(symbol.name)" } ?? symbol.name
            flattened.append(
                FlatSymbol(
                    name: symbol.name,
                    qualifiedPath: qualifiedPath,
                    kind: symbol.kind,
                    filePath: filePath,
                    startLine: symbol.range.start.line,
                    startColumn: symbol.range.start.character,
                    endLine: symbol.range.end.line,
                    endColumn: symbol.range.end.character,
                    selectionStart: symbol.selectionRange.start,
                    detail: symbol.detail
                ))
            if let children = symbol.children {
                appendFlattenedSymbols(filePath: filePath, symbols: children, parentPath: qualifiedPath, into: &flattened)
            }
        }
    }

    // MARK: - Call-edge collection

    /// One end (the caller or the callee) of a pending call edge.
    ///
    /// `writeCallEdges(db:filePath:pendingEdges:symbolIDsByStartLine:)`
    /// resolves an endpoint in the indexed file through the file's own
    /// symbol rows, and an endpoint in another file through
    /// `upsertSymbol(db:filePath:name:kind:startLine:startColumn:endLine:endColumn:detail:)`.
    struct EdgeEndpoint: Sendable {
        /// The file of the symbol, relative to the workspace root.
        let filePath: String

        /// The symbol's name.
        let name: String

        /// The symbol's kind, as a stored `lsp_symbols.kind` string.
        let kind: String

        /// The symbol's declaration span.
        let range: LSPRange

        /// Extra detail about the symbol, if the server gave one.
        let detail: String?
    }

    /// One call edge collected for a file, ready for
    /// `writeFile(db:filePath:flatSymbols:pendingEdges:)` to resolve into
    /// `lsp_symbols`/`lsp_call_edges` rows.
    ///
    /// With call hierarchy, the caller is a symbol of the indexed file and
    /// the callee can be in any file. With the references fallback, the
    /// callee is a symbol of the indexed file and the caller can be in any
    /// file. In both cases the indexed file owns the edge
    /// (`lsp_call_edges.file_path`), so the next index pass of that file
    /// replaces it.
    struct PendingCallEdge: Sendable {
        /// The calling symbol.
        let caller: EdgeEndpoint

        /// The called symbol.
        let callee: EdgeEndpoint

        /// JSON-encoded array of `[startLine,startColumn,endLine,endColumn]`
        /// call-site ranges, matching `lsp_call_edges.from_ranges`'s stored
        /// shape (see `TSCallGraph.writeEdge`).
        let fromRangesJSON: String
    }

    /// Collects the call edges of the callable (`function`/`method`/
    /// `constructor`) symbols in `flatSymbols`.
    ///
    /// When the server advertises call hierarchy, the edges are the
    /// outgoing calls of each symbol, via `prepareCallHierarchy` then
    /// `outgoingCalls`. When it does not, no call-hierarchy request is sent:
    /// the edges are the callers of each symbol, via `textDocument/references`
    /// (see `collectReferenceEdges(filePath:uri:contents:flatSymbols:rootDirectory:session:)`).
    ///
    /// A request failure for one symbol is logged and skipped rather than
    /// propagated — mirroring the Rust reference's "edge-collection failures
    /// are logged but do not fail the whole index pass". A symbol whose uri
    /// doesn't resolve to a path under `rootDirectory` (an external symbol,
    /// e.g. a standard-library definition) is skipped: this port's
    /// `lsp_symbols.file_path` is a foreign key into `indexed_files`, so
    /// there is no row to attribute an external symbol to.
    /// - Parameters:
    ///   - filePath: The file `flatSymbols` were flattened from.
    ///   - uri: `filePath`'s document uri, already synced via `syncOpen`.
    ///   - contents: The text of `filePath`, where the references fallback
    ///     finds the name of each symbol.
    ///   - flatSymbols: The file's flattened symbols.
    ///   - rootDirectory: The workspace root symbol uris are resolved against.
    ///   - session: The live session to issue the requests through.
    /// - Returns: Every collected edge, in no particular order.
    private static func collectCallEdges(
        filePath: String,
        uri: DocumentURI,
        contents: String,
        flatSymbols: [FlatSymbol],
        rootDirectory: URL,
        session: LspSession<Connection>
    ) async -> [PendingCallEdge] {
        guard session.capabilities.callHierarchy else {
            return await collectReferenceEdges(
                filePath: filePath,
                uri: uri,
                contents: contents,
                flatSymbols: flatSymbols,
                rootDirectory: rootDirectory,
                session: session
            )
        }

        var edges: [PendingCallEdge] = []

        for symbol in flatSymbols where callableKinds.contains(symbol.kind) {
            edges.append(
                contentsOf: await collectEdges(
                    forSymbol: symbol,
                    filePath: filePath,
                    uri: uri,
                    rootDirectory: rootDirectory,
                    session: session
                ))
        }

        return edges
    }

    /// Collects one callable symbol's outgoing call edges, via
    /// `prepareCallHierarchy` then `outgoingCalls` — the per-symbol body
    /// `collectCallEdges(filePath:uri:flatSymbols:rootDirectory:session:)`
    /// loops over for every callable symbol in a file.
    ///
    /// A `prepareCallHierarchy`/`outgoingCalls` failure is logged and
    /// skipped rather than propagated (see `collectCallEdges`'s doc comment
    /// for why). A callee whose uri doesn't resolve to a path under
    /// `rootDirectory` (an external symbol, e.g. a standard-library
    /// definition) is skipped: this port's `lsp_symbols.file_path` is a
    /// foreign key into `indexed_files`, so there is no row to attribute an
    /// external callee to.
    /// - Parameters:
    ///   - symbol: The callable symbol to query outgoing calls for.
    ///   - filePath: The file `symbol` was flattened from, used only for log context.
    ///   - uri: `filePath`'s document uri, already synced via `syncOpen`.
    ///   - rootDirectory: The workspace root callee uris are resolved against.
    ///   - session: The live session to issue call-hierarchy requests through.
    /// - Returns: `symbol`'s collected outgoing edges, in no particular order.
    private static func collectEdges(
        forSymbol symbol: FlatSymbol,
        filePath: String,
        uri: DocumentURI,
        rootDirectory: URL,
        session: LspSession<Connection>
    ) async -> [PendingCallEdge] {
        let position = Position(line: symbol.startLine, character: symbol.startColumn)

        let context = "\(filePath):\(symbol.qualifiedPath)"
        let items: [CallHierarchyItem]
        do {
            items = try await session.prepareCallHierarchy(uri: uri, position: position)
        } catch {
            await session.logFailure(of: .prepareCallHierarchy, context: context, error: error)
            return []
        }
        guard let item = items.first else {
            return []
        }

        let outgoing: [CallHierarchyOutgoingCall]
        do {
            outgoing = try await session.outgoingCalls(item: item)
        } catch {
            await session.logFailure(of: .outgoingCalls, context: context, error: error)
            return []
        }

        return outgoing.compactMap { call in
            guard let calleeURL = URL(string: call.to.uri.value),
                let calleeRelativePath = RelativePath.of(calleeURL, relativeTo: rootDirectory)
            else {
                return nil
            }

            let callee = EdgeEndpoint(
                filePath: calleeRelativePath,
                name: call.to.name,
                kind: kindString(for: call.to.kind),
                range: call.to.range,
                detail: nil
            )
            return PendingCallEdge(caller: symbol.endpoint, callee: callee, fromRangesJSON: encodeFromRanges(call.fromRanges))
        }
    }

    /// Encodes a call site's ranges as the JSON array-of-arrays shape
    /// `lsp_call_edges.from_ranges` stores, matching `TSCallGraph.writeEdge`'s
    /// `"[[startLine,startColumn,endLine,endColumn], ...]"` format.
    /// - Parameter ranges: The call site ranges to encode.
    /// - Returns: The encoded JSON array text.
    static func encodeFromRanges(_ ranges: [LSPRange]) -> String {
        let encodedRanges = ranges.map { range in
            "[\(range.start.line),\(range.start.character),\(range.end.line),\(range.end.character)]"
        }.joined(separator: ",")
        return "[\(encodedRanges)]"
    }

    // MARK: - Persistence (single transaction per file)

    /// Persists `flatSymbols` and `pendingEdges` for `filePath`, applies
    /// invalidation to any dependent file whose edges pointed at a symbol
    /// `flatSymbols` no longer contains, and marks `filePath` indexed — all
    /// inside the single `Store.write` transaction the caller opened, so a
    /// process interrupted mid-write never leaves partial rows committed
    /// with `lsp_indexed` still `0`, or `lsp_indexed = 1` with stale rows.
    ///
    /// Port of `swissarmyhammer-code-context::invalidation::reextract_symbols`,
    /// adapted to identify a symbol by `(file_path, start_line)` rather than
    /// a persisted string id (see this type's doc comment): symbols whose
    /// start line survives from the previous pass are updated in place
    /// (preserving their row id, and therefore any edges into or out of
    /// them); symbols whose start line disappears are deleted, cascading
    /// away their edges, after first collecting which other files had an
    /// edge into one of them — those files are the ones marked
    /// `lsp_indexed = 0` for a later pass to refresh. The files of the
    /// symbols that a call of `callSiteTargets` calls with no stored edge
    /// yet are marked `lsp_indexed = 0` too (see
    /// `calleeFilesMissingAnEdge(db:targets:symbolIDsByStartLine:)`).
    /// - Parameters:
    ///   - db: The write-transaction database connection.
    ///   - filePath: The file being indexed.
    ///   - flatSymbols: The file's freshly flattened symbols.
    ///   - pendingEdges: The file's freshly collected outgoing call edges.
    ///   - callSiteTargets: The symbols of other files that the calls of the
    ///     file refer to; empty when the pass collected none.
    /// - Throws: Rethrows any error `db`'s statements throw.
    private static func writeFile(
        db: Database,
        filePath: String,
        flatSymbols: [FlatSymbol],
        pendingEdges: [PendingCallEdge],
        callSiteTargets: Set<CallSiteTarget>
    ) throws {
        let reextraction = try reextractSymbols(db: db, filePath: filePath, flatSymbols: flatSymbols)
        try writeCallEdges(db: db, filePath: filePath, pendingEdges: pendingEdges, symbolIDsByStartLine: reextraction.symbolIDsByStartLine)
        let staleCalleeFiles = try calleeFilesMissingAnEdge(
            db: db,
            targets: callSiteTargets,
            symbolIDsByStartLine: reextraction.symbolIDsByStartLine
        )
        try applyInvalidation(db: db, affectedFiles: reextraction.affectedFiles + staleCalleeFiles)
        try recordLspContentHash(db: db, filePath: filePath)
        try setLSPIndexed(db: db, filePath: filePath, indexed: true)
    }

    /// The result of `reextractSymbols(db:filePath:flatSymbols:)`: the
    /// found-or-created row id for every symbol in `flatSymbols`, plus every
    /// other file whose edges pointed at a symbol this call deleted.
    private struct SymbolReextraction {
        /// Every freshly written symbol's start line mapped to its row id,
        /// used by `writeCallEdges(db:filePath:pendingEdges:symbolIDsByStartLine:)`
        /// to resolve each pending edge's caller.
        let symbolIDsByStartLine: [Int: Int64]

        /// Files (other than the one just re-extracted) whose outgoing
        /// edges pointed at a symbol that no longer exists, and therefore
        /// need `applyInvalidation(db:affectedFiles:)` to flag them dirty.
        let affectedFiles: [String]
    }

    /// Diffs `filePath`'s existing `lsp_symbols` rows against `flatSymbols`
    /// by `(file_path, start_line)`, deletes the rows that disappeared
    /// (cascading away their edges), and upserts every row in `flatSymbols`.
    ///
    /// Port of `swissarmyhammer-code-context::invalidation::reextract_symbols`,
    /// adapted to identify a symbol by `(file_path, start_line)` rather than
    /// a persisted string id (see this type's doc comment): symbols whose
    /// start line survives from the previous pass are updated in place
    /// (preserving their row id, and therefore any edges into or out of
    /// them); symbols whose start line disappears are deleted, cascading
    /// away their edges, after first collecting which other files had an
    /// edge into one of them.
    /// - Parameters:
    ///   - db: The write-transaction database connection.
    ///   - filePath: The file being re-extracted.
    ///   - flatSymbols: The file's freshly flattened symbols.
    /// - Returns: The new row-id map and the dependent files to invalidate.
    /// - Throws: Rethrows any error `db`'s statements throw.
    private static func reextractSymbols(
        db: Database,
        filePath: String,
        flatSymbols: [FlatSymbol]
    ) throws -> SymbolReextraction {
        let existingIDsByStartLine = try existingSymbolIDsByStartLine(db: db, filePath: filePath)
        let newStartLines = Set(flatSymbols.map(\.startLine))
        let deletedIDs =
            existingIDsByStartLine
            .filter { startLine, _ in !newStartLines.contains(startLine) }
            .map(\.value)

        let affectedFiles = try reverseEdgeFiles(db: db, symbolIDs: deletedIDs, excludingFile: filePath)
        try deleteSymbols(db: db, ids: deletedIDs)

        var symbolIDsByStartLine: [Int: Int64] = [:]
        for symbol in flatSymbols {
            symbolIDsByStartLine[symbol.startLine] = try upsertSymbol(
                db: db,
                filePath: filePath,
                name: symbol.name,
                kind: kindString(for: symbol.kind),
                startLine: symbol.startLine,
                startColumn: symbol.startColumn,
                endLine: symbol.endLine,
                endColumn: symbol.endColumn,
                detail: symbol.detail
            )
        }

        return SymbolReextraction(symbolIDsByStartLine: symbolIDsByStartLine, affectedFiles: affectedFiles)
    }

    /// Replaces `filePath`'s lsp-sourced edges with `pendingEdges`, resolving
    /// each edge's two ends via `resolveEndpoint(_:db:filePath:symbolIDsByStartLine:fileIndexedCache:)`.
    ///
    /// An edge with an end that does not resolve (a symbol in a file that
    /// isn't a known `indexed_files` row, see `isFileIndexed(db:filePath:cache:)`)
    /// is silently skipped rather than written.
    /// - Parameters:
    ///   - db: The write-transaction database connection.
    ///   - filePath: The file whose lsp-sourced edges are being replaced.
    ///   - pendingEdges: The file's freshly collected call edges.
    ///   - symbolIDsByStartLine: `filePath`'s freshly written symbol row ids, keyed by start line.
    /// - Throws: Rethrows any error `db`'s statements throw.
    private static func writeCallEdges(
        db: Database,
        filePath: String,
        pendingEdges: [PendingCallEdge],
        symbolIDsByStartLine: [Int: Int64]
    ) throws {
        try db.execute(
            sql: """
                DELETE FROM \(Schema.LspCallEdges.table) \
                WHERE \(Schema.LspCallEdges.filePath) = ? AND \(Schema.LspCallEdges.source) = 'lsp'
                """,
            arguments: [filePath]
        )

        var fileIndexedCache: [String: Bool] = [filePath: true]
        for edge in pendingEdges {
            guard
                let callerID = try resolveEndpoint(
                    edge.caller, db: db, filePath: filePath, symbolIDsByStartLine: symbolIDsByStartLine, fileIndexedCache: &fileIndexedCache
                ),
                let calleeID = try resolveEndpoint(
                    edge.callee, db: db, filePath: filePath, symbolIDsByStartLine: symbolIDsByStartLine, fileIndexedCache: &fileIndexedCache
                )
            else {
                continue
            }

            try db.execute(
                sql: """
                    INSERT INTO \(Schema.LspCallEdges.table)
                        (\(Schema.LspCallEdges.callerId), \(Schema.LspCallEdges.calleeId), \(Schema.LspCallEdges.filePath), \
                         \(Schema.LspCallEdges.fromRanges), \(Schema.LspCallEdges.source))
                    VALUES (?, ?, ?, ?, 'lsp')
                    """,
                arguments: [callerID, calleeID, filePath, edge.fromRangesJSON]
            )
        }
    }

    /// Resolves one end of a pending edge to its `lsp_symbols.id`.
    ///
    /// A symbol of `filePath` resolves through `symbolIDsByStartLine`, the
    /// rows this pass just wrote. A symbol of another file resolves through
    /// `upsertSymbol(db:filePath:name:kind:startLine:startColumn:endLine:endColumn:detail:)`,
    /// which finds or creates its row by `(file_path, start_line)`; that
    /// file's own index pass later keeps the row when the symbol still starts
    /// on the same line.
    /// - Parameters:
    ///   - endpoint: The end of the edge to resolve.
    ///   - db: The write-transaction database connection.
    ///   - filePath: The file being indexed.
    ///   - symbolIDsByStartLine: `filePath`'s freshly written symbol row ids, keyed by start line.
    ///   - fileIndexedCache: Memoized `isFileIndexed(db:filePath:cache:)` results for this pass.
    /// - Returns: The symbol's row id, or `nil` when its file has no
    ///   `indexed_files` row.
    /// - Throws: Rethrows any error `db`'s statements throw.
    private static func resolveEndpoint(
        _ endpoint: EdgeEndpoint,
        db: Database,
        filePath: String,
        symbolIDsByStartLine: [Int: Int64],
        fileIndexedCache: inout [String: Bool]
    ) throws -> Int64? {
        if endpoint.filePath == filePath, let id = symbolIDsByStartLine[endpoint.range.start.line] {
            return id
        }
        guard try isFileIndexed(db: db, filePath: endpoint.filePath, cache: &fileIndexedCache) else {
            return nil
        }
        return try upsertSymbol(
            db: db,
            filePath: endpoint.filePath,
            name: endpoint.name,
            kind: endpoint.kind,
            startLine: endpoint.range.start.line,
            startColumn: endpoint.range.start.character,
            endLine: endpoint.range.end.line,
            endColumn: endpoint.range.end.character,
            detail: endpoint.detail
        )
    }

    /// Flags every file in `affectedFiles` as `lsp_indexed = 0`, so a later
    /// drain refreshes its now-stale outgoing edges.
    /// - Parameters:
    ///   - db: The write-transaction database connection.
    ///   - affectedFiles: The dependent files to invalidate.
    /// - Throws: Rethrows any error `db`'s statements throw.
    private static func applyInvalidation(db: Database, affectedFiles: [String]) throws {
        for affectedFile in affectedFiles {
            try setLSPIndexed(db: db, filePath: affectedFile, indexed: false)
        }
    }

    /// Sets `indexed_files.lsp_indexed` for `filePath`, shared by
    /// `applyInvalidation(db:affectedFiles:)` (clearing it) and
    /// `writeFile(db:filePath:flatSymbols:pendingEdges:)` (setting it) so the
    /// two don't each carry their own copy of this single-column `UPDATE`.
    /// - Parameters:
    ///   - db: The write-transaction database connection.
    ///   - filePath: The file whose `lsp_indexed` flag to set.
    ///   - indexed: The new flag value.
    /// - Throws: Rethrows any error `db`'s statement throws.
    private static func setLSPIndexed(db: Database, filePath: String, indexed: Bool) throws {
        try db.execute(
            sql: """
                UPDATE \(Schema.IndexedFiles.table) SET \(Schema.IndexedFiles.lspIndexed) = ? \
                WHERE \(Schema.IndexedFiles.filePath) = ?
                """,
            arguments: [indexed, filePath]
        )
    }

    /// Snapshots `filePath`'s current `lsp_symbols` rows as a
    /// `(startLine -> id)` map, taken before any write this pass so
    /// `writeFile(db:filePath:flatSymbols:pendingEdges:)` can diff it
    /// against the freshly flattened symbol set.
    /// - Parameters:
    ///   - db: The database connection to query.
    ///   - filePath: The file to snapshot.
    /// - Returns: Every existing row's start line mapped to its id.
    /// - Throws: Rethrows any error the query throws.
    private static func existingSymbolIDsByStartLine(db: Database, filePath: String) throws -> [Int: Int64] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(Schema.LspSymbols.startLine), \(Schema.LspSymbols.id) FROM \(Schema.LspSymbols.table) \
                WHERE \(Schema.LspSymbols.filePath) = ?
                """,
            arguments: [filePath]
        )
        var idsByStartLine: [Int: Int64] = [:]
        for row in rows {
            let startLine: Int = row[Schema.LspSymbols.startLine]
            let id: Int64 = row[Schema.LspSymbols.id]
            idsByStartLine[startLine] = id
        }
        return idsByStartLine
    }

    /// Finds every file (other than `excludingFile`) that owns an
    /// `lsp_call_edges` row whose callee or caller is one of `symbolIDs`,
    /// before those rows are deleted.
    ///
    /// Port of `swissarmyhammer-code-context::invalidation::find_reverse_edge_files`,
    /// extended to the caller side: an edge from the references fallback is
    /// owned by its callee's file, so deleting its caller must mark that
    /// file dirty too. With call hierarchy, the caller of each edge is in
    /// the owner file itself, so the caller side adds no file there.
    /// Chunks `symbolIDs` through `sqliteInChunkSize` so the generated
    /// `IN (...)` clause never exceeds SQLite's bind-parameter limit.
    /// - Parameters:
    ///   - db: The database connection to query.
    ///   - symbolIDs: The symbol ids about to be deleted.
    ///   - excludingFile: The file to exclude from the results (the file
    ///     currently being re-indexed).
    /// - Returns: The distinct dependent file paths, in no particular order.
    /// - Throws: Rethrows any error the query throws.
    private static func reverseEdgeFiles(db: Database, symbolIDs: [Int64], excludingFile: String) throws -> [String] {
        var affectedFiles: Set<String> = []
        for side in [CallEdgeSide.callee, CallEdgeSide.caller] {
            for chunk in chunked(symbolIDs, size: sqliteInChunkSize) {
                affectedFiles.formUnion(try edgeOwnerFiles(db: db, side: side, symbolIDs: chunk, excludingFile: excludingFile))
            }
        }
        return Array(affectedFiles)
    }

    /// Finds the distinct owner files (other than `excludingFile`) of the
    /// `lsp_call_edges` rows whose `side` column is one of `symbolIDs`.
    /// - Parameters:
    ///   - db: The database connection to query.
    ///   - side: Which end of the edge to match.
    ///   - symbolIDs: At most `sqliteInChunkSize` symbol ids.
    ///   - excludingFile: The file to exclude from the results.
    /// - Returns: The owner file paths, in no particular order.
    /// - Throws: Rethrows any error the query throws.
    private static func edgeOwnerFiles(db: Database, side: CallEdgeSide, symbolIDs: [Int64], excludingFile: String) throws -> [String] {
        let placeholders = symbolIDs.map { _ in "?" }.joined(separator: ", ")
        return try String.fetchAll(
            db,
            sql: """
                SELECT DISTINCT \(Schema.LspCallEdges.filePath) FROM \(Schema.LspCallEdges.table) \
                WHERE \(side.column) IN (\(placeholders)) AND \(Schema.LspCallEdges.filePath) != ?
                """,
            arguments: StatementArguments(symbolIDs) + StatementArguments([excludingFile])
        )
    }

    /// Deletes `lsp_symbols` rows by id, cascading away any edge that
    /// referenced one of them as caller or callee.
    ///
    /// Chunks `ids` through `sqliteInChunkSize`, mirroring
    /// `reverseEdgeFiles(db:symbolIDs:excludingFile:)`.
    /// - Parameters:
    ///   - db: The database connection to write through.
    ///   - ids: The symbol ids to delete.
    /// - Throws: Rethrows any error the delete throws.
    private static func deleteSymbols(db: Database, ids: [Int64]) throws {
        guard !ids.isEmpty else {
            return
        }
        for chunk in chunked(ids, size: sqliteInChunkSize) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
            try db.execute(
                sql: "DELETE FROM \(Schema.LspSymbols.table) WHERE \(Schema.LspSymbols.id) IN (\(placeholders))",
                arguments: StatementArguments(chunk)
            )
        }
    }

    /// Finds or creates the `lsp_symbols` row identifying the symbol at
    /// `(filePath, startLine)`, updating its `name`/`kind`/columns/`detail`
    /// in place when found — mirroring `TSCallGraph.ensureSymbolID`'s
    /// find-or-update pattern, but writing real LSP-reported fields instead
    /// of a synthetic tree-sitter-derived name.
    /// - Parameters:
    ///   - db: The database connection to query and write through.
    ///   - filePath: The symbol's file path.
    ///   - name: The symbol's short name.
    ///   - kind: The symbol's kind, as a stored `lsp_symbols.kind` string.
    ///   - startLine: The symbol's zero-based start line.
    ///   - startColumn: The symbol's zero-based start column.
    ///   - endLine: The symbol's zero-based end line.
    ///   - endColumn: The symbol's zero-based end column.
    ///   - detail: Extra detail about the symbol, if any.
    /// - Returns: The `lsp_symbols.id` of the found-or-created row.
    /// - Throws: Rethrows any error the lookup or write queries throw.
    private static func upsertSymbol(
        db: Database,
        filePath: String,
        name: String,
        kind: String,
        startLine: Int,
        startColumn: Int,
        endLine: Int,
        endColumn: Int,
        detail: String?
    ) throws -> Int64 {
        if let existingID = try Int64.fetchOne(
            db,
            sql: """
                SELECT \(Schema.LspSymbols.id) FROM \(Schema.LspSymbols.table) \
                WHERE \(Schema.LspSymbols.filePath) = ? AND \(Schema.LspSymbols.startLine) = ? \
                LIMIT 1
                """,
            arguments: [filePath, startLine]
        ) {
            try db.execute(
                sql: """
                    UPDATE \(Schema.LspSymbols.table) \
                    SET \(Schema.LspSymbols.name) = ?, \(Schema.LspSymbols.kind) = ?, \
                        \(Schema.LspSymbols.startColumn) = ?, \(Schema.LspSymbols.endLine) = ?, \
                        \(Schema.LspSymbols.endColumn) = ?, \(Schema.LspSymbols.detail) = ? \
                    WHERE \(Schema.LspSymbols.id) = ?
                    """,
                arguments: [name, kind, startColumn, endLine, endColumn, detail, existingID]
            )
            return existingID
        }

        try db.execute(
            sql: """
                INSERT INTO \(Schema.LspSymbols.table)
                    (\(Schema.LspSymbols.name), \(Schema.LspSymbols.kind), \(Schema.LspSymbols.filePath), \
                     \(Schema.LspSymbols.startLine), \(Schema.LspSymbols.startColumn), \
                     \(Schema.LspSymbols.endLine), \(Schema.LspSymbols.endColumn), \(Schema.LspSymbols.detail))
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [name, kind, filePath, startLine, startColumn, endLine, endColumn, detail]
        )
        return db.lastInsertedRowID
    }

    /// Whether `filePath` has an `indexed_files` row, memoized in `cache`
    /// across calls within the same `writeFile(db:filePath:flatSymbols:pendingEdges:)`
    /// invocation.
    ///
    /// `lsp_symbols.file_path` is a foreign key into `indexed_files`, so a
    /// synthetic callee row can only be created for a file this workspace
    /// already tracks — a callee outside the workspace, or in a file not yet
    /// walked/reconciled, has no row to attribute the edge to and must be
    /// skipped rather than violating the foreign key.
    /// - Parameters:
    ///   - db: The database connection to query.
    ///   - filePath: The file path to check.
    ///   - cache: Memoized results for file paths already checked this call.
    /// - Returns: `true` if `filePath` has an `indexed_files` row.
    /// - Throws: Rethrows any error the query throws.
    private static func isFileIndexed(db: Database, filePath: String, cache: inout [String: Bool]) throws -> Bool {
        if let cached = cache[filePath] {
            return cached
        }
        let exists =
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM \(Schema.IndexedFiles.table) WHERE \(Schema.IndexedFiles.filePath) = ?)",
                arguments: [filePath]
            ) ?? false
        cache[filePath] = exists
        return exists
    }

    // MARK: - Small shared helpers

    /// Maps an LSP `SymbolKind` to the lowercase string stored in
    /// `lsp_symbols.kind`, matching the names `SymbolOps.lspKindMetaTypes`
    /// recognizes for `function`/`method`/`constructor`/`class`/`struct`/
    /// `interface`/`enum`/`namespace`/`module` — every other case falls back
    /// to `SymbolMetaType.other` there regardless of its exact stored
    /// string, so any other lowercase spelling below is unambiguous.
    /// - Parameter kind: The LSP symbol kind to map.
    /// - Returns: The lowercase string to store as `lsp_symbols.kind`.
    static func kindString(for kind: SymbolKind) -> String {
        switch kind {
        case .file: "file"
        case .module: "module"
        case .namespace: "namespace"
        case .package: "package"
        case .class: "class"
        case .method: "method"
        case .property: "property"
        case .field: "field"
        case .constructor: "constructor"
        case .enum: "enum"
        case .interface: "interface"
        case .function: "function"
        case .variable: "variable"
        case .constant: "constant"
        case .string: "string"
        case .number: "number"
        case .boolean: "boolean"
        case .array: "array"
        case .object: "object"
        case .key: "key"
        case .null: "null"
        case .enumMember: "enummember"
        case .struct: "struct"
        case .event: "event"
        case .operator: "operator"
        case .typeParameter: "typeparameter"
        }
    }

    /// Splits `elements` into consecutive chunks of at most `size` elements.
    /// - Parameters:
    ///   - elements: The elements to split.
    ///   - size: The maximum size of each chunk.
    /// - Returns: `elements` split into chunks, preserving order; empty if
    ///   `elements` is empty.
    private static func chunked<Element>(_ elements: [Element], size: Int) -> [[Element]] {
        guard !elements.isEmpty else {
            return []
        }
        return stride(from: 0, to: elements.count, by: size).map { startIndex in
            Array(elements[startIndex..<Swift.min(startIndex + size, elements.count)])
        }
    }
}

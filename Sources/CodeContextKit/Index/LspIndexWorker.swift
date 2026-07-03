import Foundation
import GRDB

/// Idle/backoff pacing knobs for `LspIndexWorker.run(store:rootDirectory:extensions:sessionProvider:configuration:clock:)`.
///
/// Port of `swissarmyhammer-code-context`'s `LspWorkerConfig`.
struct LspIndexWorkerConfiguration: Sendable, Equatable {
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
///
/// Every symbol/edge write and the `lsp_indexed` flag flip for one file
/// happen inside a single `Store.write` transaction (see
/// `writeFile(db:filePath:flatSymbols:pendingEdges:)`), matching
/// `TreeSitterWorker`'s established atomicity pattern: a process
/// interrupted mid-drain never leaves a file's rows committed with its flag
/// still `0`, or vice versa.
enum LspIndexWorker<Connection: LanguageServerConnection> {
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
    /// catch-all `default:` arm. Checked inline at its one call site in
    /// `collectCallEdges(filePath:uri:flatSymbols:rootDirectory:session:)`
    /// rather than through a wrapper function.
    private static var callableKinds: Set<SymbolKind> { [.function, .method, .constructor] }

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
    ///     Defaults to `LspIndexWorkerConfiguration()`.
    ///   - clock: The clock idle/unavailable sleeps wait against. Defaults
    ///     to `ContinuousClock()`; tests inject a `ManualClock`.
    /// - Throws: Rethrows `Store`'s storage errors, or `CancellationError`
    ///   if the calling task is cancelled while sleeping.
    static func run(
        store: Store,
        rootDirectory: URL,
        extensions: [String],
        sessionProvider: @escaping @Sendable () async -> LspSession<Connection>?,
        configuration: LspIndexWorkerConfiguration = LspIndexWorkerConfiguration(),
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
    ///     `LspIndexWorkerConfiguration()`.
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
        configuration: LspIndexWorkerConfiguration = LspIndexWorkerConfiguration()
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
        guard let contents = readFileContents(relativePath: relativePath, rootDirectory: rootDirectory) else {
            Log.lsp.warning("failed to read \(relativePath, privacy: .public) for LSP indexing; marking indexed")
            return await markIndexedIgnoringErrors(relativePath: relativePath, store: store)
        }

        let fileURL = rootDirectory.appendingPathComponent(relativePath)
        let uri = DocumentURI(fileURL.absoluteString)

        guard let documentSymbols = await syncAndFetchSymbols(
            relativePath: relativePath,
            uri: uri,
            contents: contents,
            session: session
        ) else {
            return false
        }

        let flatSymbols = flattenSymbols(filePath: relativePath, symbols: documentSymbols)
        let pendingEdges = await collectCallEdges(
            filePath: relativePath,
            uri: uri,
            flatSymbols: flatSymbols,
            rootDirectory: rootDirectory,
            session: session
        )

        do {
            try await session.didClose(uri: uri)
        } catch {
            Log.lsp.warning("didClose failed for \(relativePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        do {
            try await store.write { db in
                try writeFile(db: db, filePath: relativePath, flatSymbols: flatSymbols, pendingEdges: pendingEdges)
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
    /// shape at the call site instead of duplicating it.
    /// - Parameters:
    ///   - relativePath: The file's workspace-relative path, used only for log messages.
    ///   - uri: The document uri to sync and query.
    ///   - contents: The file's current disk content.
    ///   - session: The live session to sync and query through.
    /// - Returns: The document's symbols, or `nil` if `syncOpen`/`documentSymbols` threw.
    private static func syncAndFetchSymbols(
        relativePath: String,
        uri: DocumentURI,
        contents: String,
        session: LspSession<Connection>
    ) async -> [DocumentSymbol]? {
        do {
            try await session.syncOpen(uri: uri, text: contents)
        } catch {
            Log.lsp.warning(
                "syncOpen failed for \(relativePath, privacy: .public), leaving dirty: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }

        do {
            return try await session.documentSymbols(uri: uri)
        } catch {
            Log.lsp.warning(
                "documentSymbol failed for \(relativePath, privacy: .public), leaving dirty: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// Reads `relativePath`'s content from disk as UTF-8 text, or `nil` if
    /// it can't be read or decoded.
    /// - Parameters:
    ///   - relativePath: The file's workspace-relative path.
    ///   - rootDirectory: The workspace root `relativePath` is relative to.
    /// - Returns: The file's decoded text, or `nil` on any read/decode failure.
    private static func readFileContents(relativePath: String, rootDirectory: URL) -> String? {
        let fileURL = rootDirectory.appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: fileURL), let contents = String(data: data, encoding: .utf8) else {
            return nil
        }
        return contents
    }

    /// Marks `relativePath` `lsp_indexed = 1`, logging (rather than
    /// propagating) any storage failure — used for the unreadable-file skip
    /// path, where there is nothing left to retry even if the mark itself
    /// fails.
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
                "failed to mark \(relativePath, privacy: .public) lsp-indexed after an unreadable-file skip: \(error.localizedDescription, privacy: .public)"
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
    private struct FlatSymbol: Sendable, Equatable {
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

        /// Extra detail about the symbol (e.g. a function signature), if any.
        let detail: String?
    }

    /// Flattens a `textDocument/documentSymbol` result tree into a flat list
    /// with qualified paths, walking every symbol's `children` recursively.
    /// - Parameters:
    ///   - filePath: The file the symbols were requested for.
    ///   - symbols: The top-level symbols returned by the server.
    /// - Returns: One `FlatSymbol` per symbol in the tree (parents and
    ///   children alike), in depth-first order.
    private static func flattenSymbols(filePath: String, symbols: [DocumentSymbol]) -> [FlatSymbol] {
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
            flattened.append(FlatSymbol(
                name: symbol.name,
                qualifiedPath: qualifiedPath,
                kind: symbol.kind,
                filePath: filePath,
                startLine: symbol.range.start.line,
                startColumn: symbol.range.start.character,
                endLine: symbol.range.end.line,
                endColumn: symbol.range.end.character,
                detail: symbol.detail
            ))
            if let children = symbol.children {
                appendFlattenedSymbols(filePath: filePath, symbols: children, parentPath: qualifiedPath, into: &flattened)
            }
        }
    }

    // MARK: - Call-edge collection

    /// One outgoing call edge collected for a file, ready for
    /// `writeFile(db:filePath:flatSymbols:pendingEdges:)` to resolve into
    /// `lsp_symbols`/`lsp_call_edges` rows.
    private struct PendingCallEdge: Sendable {
        /// The caller symbol's start line, used to look up its row id from
        /// the `(startLine -> id)` map `writeFile(db:filePath:flatSymbols:pendingEdges:)`
        /// builds while writing this file's own `flatSymbols`.
        let callerStartLine: Int

        /// The callee's file, relative to the workspace root.
        let calleeFilePath: String

        /// The callee's name, as reported by `callHierarchy/outgoingCalls`.
        let calleeName: String

        /// The callee's kind, as a stored `lsp_symbols.kind` string.
        let calleeKind: String

        /// The callee's zero-based declaration start line.
        let calleeStartLine: Int

        /// The callee's zero-based declaration start column.
        let calleeStartColumn: Int

        /// The callee's zero-based declaration end line.
        let calleeEndLine: Int

        /// The callee's zero-based declaration end column.
        let calleeEndColumn: Int

        /// JSON-encoded array of `[startLine,startColumn,endLine,endColumn]`
        /// call-site ranges, matching `lsp_call_edges.from_ranges`'s stored
        /// shape (see `TSCallGraph.writeEdge`).
        let fromRangesJSON: String
    }

    /// Collects outgoing call edges for every callable (`function`/`method`/
    /// `constructor`) symbol in `flatSymbols`, via `prepareCallHierarchy`
    /// then `outgoingCalls` per symbol.
    ///
    /// A `prepareCallHierarchy`/`outgoingCalls` failure for one symbol is
    /// logged and skipped rather than propagated — mirroring the Rust
    /// reference's "edge-collection failures are logged but do not fail the
    /// whole index pass". A callee whose uri doesn't resolve to a path under
    /// `rootDirectory` (an external symbol, e.g. a standard-library
    /// definition) is skipped: this port's `lsp_symbols.file_path` is a
    /// foreign key into `indexed_files`, so there is no row to attribute an
    /// external callee to.
    /// - Parameters:
    ///   - filePath: The file `flatSymbols` were flattened from.
    ///   - uri: `filePath`'s document uri, already synced via `syncOpen`.
    ///   - flatSymbols: The file's flattened symbols.
    ///   - rootDirectory: The workspace root callee uris are resolved against.
    ///   - session: The live session to issue call-hierarchy requests through.
    /// - Returns: Every collected edge, in no particular order.
    private static func collectCallEdges(
        filePath: String,
        uri: DocumentURI,
        flatSymbols: [FlatSymbol],
        rootDirectory: URL,
        session: LspSession<Connection>
    ) async -> [PendingCallEdge] {
        var edges: [PendingCallEdge] = []

        for symbol in flatSymbols where callableKinds.contains(symbol.kind) {
            let position = Position(line: symbol.startLine, character: symbol.startColumn)

            let items: [CallHierarchyItem]
            do {
                items = try await session.prepareCallHierarchy(uri: uri, position: position)
            } catch {
                Log.lsp.warning(
                    "prepareCallHierarchy failed for \(filePath, privacy: .public):\(symbol.qualifiedPath, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                continue
            }
            guard let item = items.first else {
                continue
            }

            let outgoing: [CallHierarchyOutgoingCall]
            do {
                outgoing = try await session.outgoingCalls(item: item)
            } catch {
                Log.lsp.warning(
                    "outgoingCalls failed for \(filePath, privacy: .public):\(symbol.qualifiedPath, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                continue
            }

            for call in outgoing {
                guard let calleeURL = URL(string: call.to.uri.value),
                      let calleeRelativePath = RelativePath.of(calleeURL, relativeTo: rootDirectory)
                else {
                    continue
                }

                edges.append(PendingCallEdge(
                    callerStartLine: symbol.startLine,
                    calleeFilePath: calleeRelativePath,
                    calleeName: call.to.name,
                    calleeKind: kindString(for: call.to.kind),
                    calleeStartLine: call.to.range.start.line,
                    calleeStartColumn: call.to.range.start.character,
                    calleeEndLine: call.to.range.end.line,
                    calleeEndColumn: call.to.range.end.character,
                    fromRangesJSON: encodeFromRanges(call.fromRanges)
                ))
            }
        }

        return edges
    }

    /// Encodes a call site's ranges as the JSON array-of-arrays shape
    /// `lsp_call_edges.from_ranges` stores, matching `TSCallGraph.writeEdge`'s
    /// `"[[startLine,startColumn,endLine,endColumn], ...]"` format.
    /// - Parameter ranges: The call site ranges to encode.
    /// - Returns: The encoded JSON array text.
    private static func encodeFromRanges(_ ranges: [LSPRange]) -> String {
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
    /// `lsp_indexed = 0` for a later pass to refresh.
    /// - Parameters:
    ///   - db: The write-transaction database connection.
    ///   - filePath: The file being indexed.
    ///   - flatSymbols: The file's freshly flattened symbols.
    ///   - pendingEdges: The file's freshly collected outgoing call edges.
    /// - Throws: Rethrows any error `db`'s statements throw.
    private static func writeFile(
        db: Database,
        filePath: String,
        flatSymbols: [FlatSymbol],
        pendingEdges: [PendingCallEdge]
    ) throws {
        let reextraction = try reextractSymbols(db: db, filePath: filePath, flatSymbols: flatSymbols)
        try writeCallEdges(db: db, filePath: filePath, pendingEdges: pendingEdges, symbolIDsByStartLine: reextraction.symbolIDsByStartLine)
        try applyInvalidation(db: db, affectedFiles: reextraction.affectedFiles)
        try markIndexed(db: db, filePath: filePath)
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
        let deletedIDs = existingIDsByStartLine
            .filter { startLine, _ in !newStartLines.contains(startLine) }
            .map(\.value)

        let affectedFiles = try reverseEdgeFiles(db: db, calleeIDs: deletedIDs, excludingFile: filePath)
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

    /// Replaces `filePath`'s lsp-sourced outgoing edges with `pendingEdges`,
    /// resolving each edge's caller via `symbolIDsByStartLine` and its
    /// callee via `upsertSymbol(db:filePath:name:kind:startLine:startColumn:endLine:endColumn:detail:)`.
    ///
    /// An edge whose caller isn't in `symbolIDsByStartLine`, or whose callee
    /// file isn't a known `indexed_files` row (see `isFileIndexed(db:filePath:cache:)`),
    /// is silently skipped rather than written.
    /// - Parameters:
    ///   - db: The write-transaction database connection.
    ///   - filePath: The file whose lsp-sourced edges are being replaced.
    ///   - pendingEdges: The file's freshly collected outgoing call edges.
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

        var calleeFileIndexedCache: [String: Bool] = [filePath: true]
        for edge in pendingEdges {
            guard let callerID = symbolIDsByStartLine[edge.callerStartLine] else {
                continue
            }
            guard try isFileIndexed(db: db, filePath: edge.calleeFilePath, cache: &calleeFileIndexedCache) else {
                continue
            }

            let calleeID = try upsertSymbol(
                db: db,
                filePath: edge.calleeFilePath,
                name: edge.calleeName,
                kind: edge.calleeKind,
                startLine: edge.calleeStartLine,
                startColumn: edge.calleeStartColumn,
                endLine: edge.calleeEndLine,
                endColumn: edge.calleeEndColumn,
                detail: nil
            )

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

    /// Flags every file in `affectedFiles` as `lsp_indexed = 0`, so a later
    /// drain refreshes its now-stale outgoing edges.
    /// - Parameters:
    ///   - db: The write-transaction database connection.
    ///   - affectedFiles: The dependent files to invalidate.
    /// - Throws: Rethrows any error `db`'s statements throw.
    private static func applyInvalidation(db: Database, affectedFiles: [String]) throws {
        for affectedFile in affectedFiles {
            try setLspIndexed(db: db, filePath: affectedFile, indexed: false)
        }
    }

    /// Flags `filePath` as `lsp_indexed = 1`.
    /// - Parameters:
    ///   - db: The write-transaction database connection.
    ///   - filePath: The file to mark indexed.
    /// - Throws: Rethrows any error `db`'s statement throws.
    private static func markIndexed(db: Database, filePath: String) throws {
        try setLspIndexed(db: db, filePath: filePath, indexed: true)
    }

    /// Sets `indexed_files.lsp_indexed` for `filePath`, shared by
    /// `applyInvalidation(db:affectedFiles:)` (clearing it) and
    /// `markIndexed(db:filePath:)` (setting it) so the two don't each carry
    /// their own copy of this single-column `UPDATE`.
    /// - Parameters:
    ///   - db: The write-transaction database connection.
    ///   - filePath: The file whose `lsp_indexed` flag to set.
    ///   - indexed: The new flag value.
    /// - Throws: Rethrows any error `db`'s statement throws.
    private static func setLspIndexed(db: Database, filePath: String, indexed: Bool) throws {
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

    /// Finds every file (other than `excludingFile`) with an `lsp_call_edges`
    /// row whose callee is one of `calleeIDs`, before those rows are deleted.
    ///
    /// Port of `swissarmyhammer-code-context::invalidation::find_reverse_edge_files`.
    /// Chunks `calleeIDs` through `sqliteInChunkSize` so the generated
    /// `IN (...)` clause never exceeds SQLite's bind-parameter limit.
    /// - Parameters:
    ///   - db: The database connection to query.
    ///   - calleeIDs: The symbol ids about to be deleted.
    ///   - excludingFile: The file to exclude from the results (the file
    ///     currently being re-indexed).
    /// - Returns: The distinct dependent file paths, in no particular order.
    /// - Throws: Rethrows any error the query throws.
    private static func reverseEdgeFiles(db: Database, calleeIDs: [Int64], excludingFile: String) throws -> [String] {
        guard !calleeIDs.isEmpty else {
            return []
        }

        var affectedFiles: Set<String> = []
        for chunk in chunked(calleeIDs, size: sqliteInChunkSize) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
            let arguments = StatementArguments(chunk) + StatementArguments([excludingFile])
            let rows = try String.fetchAll(
                db,
                sql: """
                SELECT DISTINCT \(Schema.LspCallEdges.filePath) FROM \(Schema.LspCallEdges.table) \
                WHERE \(Schema.LspCallEdges.calleeId) IN (\(placeholders)) AND \(Schema.LspCallEdges.filePath) != ?
                """,
                arguments: arguments
            )
            affectedFiles.formUnion(rows)
        }
        return Array(affectedFiles)
    }

    /// Deletes `lsp_symbols` rows by id, cascading away any edge that
    /// referenced one of them as caller or callee.
    ///
    /// Chunks `ids` through `sqliteInChunkSize`, mirroring
    /// `reverseEdgeFiles(db:calleeIDs:excludingFile:)`.
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
        let exists = try Bool.fetchOne(
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
    private static func kindString(for kind: SymbolKind) -> String {
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
            Array(elements[startIndex ..< Swift.min(startIndex + size, elements.count)])
        }
    }
}

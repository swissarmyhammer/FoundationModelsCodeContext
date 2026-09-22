import Foundation
import GRDB

/// The references fallback of `LSPIndexWorker`, for a server that does not
/// advertise call hierarchy.
///
/// Such a server (for example `pylsp`) answers `prepareCallHierarchy` with
/// `-32601 Method Not Found`, so call hierarchy gives no call edge. The
/// fallback finds the callers of each callable symbol of the indexed file
/// with `textDocument/references` instead:
///
/// 1. The request goes to the name of the symbol, found in the text by
///    `SymbolNameLocator` (a `pylsp` symbol range starts at `def`, where a
///    request gives no references).
/// 2. Each reference location is attributed to the narrowest callable
///    symbol of its file that holds it. The symbols of another file come
///    from one `documentSymbol` request for each file and indexed file. A
///    reference with no callable symbol around it (for example an import at
///    module level) gives no edge.
/// 3. Each (caller, symbol) pair becomes one edge, with the reference
///    ranges as its call sites.
///
/// A reference is not always a call: a function passed as a value is a
/// reference too. The edges are thus a close approximation of the call
/// graph, not an exact copy of it.
///
/// The indexed file (the callee file) owns the edges it writes, so its next
/// index pass replaces them. Two rules mark the owner file dirty when an
/// edge into it goes out of date because of a change in another file:
///
/// - A caller that another file deletes marks the owner file dirty (see
///   `reverseEdgeFiles(db:symbolIDs:excludingFile:)`).
/// - A new or changed call in another file marks the file of the called
///   symbol dirty (see
///   `collectCallSiteTargets(filePath:uri:contents:flatSymbols:rootDirectory:session:store:)`
///   and `calleeFilesMissingAnEdge(db:targets:symbolIDsByStartLine:)`).
///   The next pass of the called file then finds the new caller among the
///   references.
extension LSPIndexWorker {
    /// The callable symbols of each file the fallback has read in one index
    /// pass, keyed by workspace-relative path.
    typealias CallableSymbolsByFile = [String: [FlatSymbol]]

    /// Collects the edges into each callable symbol of `flatSymbols` from
    /// `textDocument/references`.
    /// - Parameters:
    ///   - filePath: The file `flatSymbols` were flattened from.
    ///   - uri: `filePath`'s document uri, already synced via `syncOpen`.
    ///   - contents: The text of `filePath`, where the name of each symbol is found.
    ///   - flatSymbols: The file's flattened symbols.
    ///   - rootDirectory: The workspace root reference uris are resolved against.
    ///   - session: The live session to send the requests through.
    /// - Returns: One edge for each (caller, callee) pair, in no particular order.
    static func collectReferenceEdges(
        filePath: String,
        uri: DocumentURI,
        contents: String,
        flatSymbols: [FlatSymbol],
        rootDirectory: URL,
        session: LspSession<Connection>
    ) async -> [PendingCallEdge] {
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        let callables = flatSymbols.filter { callableKinds.contains($0.kind) }
        var callableSymbolsByFile: CallableSymbolsByFile = [filePath: callables]
        var edges: [PendingCallEdge] = []

        for callee in callables {
            guard let locations = await referenceLocations(of: callee, uri: uri, lines: lines, session: session) else {
                continue
            }
            edges += await callerEdges(
                into: callee,
                locations: locations,
                rootDirectory: rootDirectory,
                session: session,
                callableSymbolsByFile: &callableSymbolsByFile
            )
        }
        return edges
    }

    /// Asks the server for the references to `symbol`, at the position of its name.
    /// - Parameters:
    ///   - symbol: The callable symbol to find the references of.
    ///   - uri: The document of `symbol`, already synced via `syncOpen`.
    ///   - lines: The text of the document, split at each line feed.
    ///   - session: The live session to send the request through.
    /// - Returns: The reference locations, without the declaration; `nil`
    ///   when the name is not in the text or the request failed (a failure is
    ///   logged one time for each server).
    private static func referenceLocations(
        of symbol: FlatSymbol,
        uri: DocumentURI,
        lines: [Substring],
        session: LspSession<Connection>
    ) async -> [Location]? {
        guard
            let namePosition = SymbolNameLocator.position(
                ofName: symbol.name,
                from: symbol.selectionStart,
                throughLine: symbol.endLine,
                in: lines
            )
        else {
            return nil
        }
        do {
            return try await session.references(uri: uri, at: namePosition, includeDeclaration: false)
        } catch {
            await session.logFailure(of: .references, context: "\(symbol.filePath):\(symbol.qualifiedPath)", error: error)
            return nil
        }
    }

    /// Groups the reference `locations` of `callee` by the callable symbol
    /// that holds each one, and makes one edge for each group.
    /// - Parameters:
    ///   - callee: The symbol the references point at.
    ///   - locations: The reference locations of `callee`.
    ///   - rootDirectory: The workspace root the location uris are resolved against.
    ///   - session: The live session to read the symbols of other files through.
    ///   - callableSymbolsByFile: The callable symbols read so far in this pass;
    ///     a file read here is added to it.
    /// - Returns: One edge for each caller, ordered by the file and the
    ///   position of the caller.
    private static func callerEdges(
        into callee: FlatSymbol,
        locations: [Location],
        rootDirectory: URL,
        session: LspSession<Connection>,
        callableSymbolsByFile: inout CallableSymbolsByFile
    ) async -> [PendingCallEdge] {
        var callSites: [(caller: FlatSymbol, range: LSPRange)] = []
        for location in locations {
            guard let callerFile = relativePath(of: location.uri, rootDirectory: rootDirectory) else {
                continue
            }
            let candidates = await callableSymbols(
                in: callerFile,
                rootDirectory: rootDirectory,
                session: session,
                callableSymbolsByFile: &callableSymbolsByFile
            )
            if let caller = narrowestSymbol(in: candidates, containing: location.range.start) {
                callSites.append((caller, location.range))
            }
        }

        let callSitesByCaller = Dictionary(grouping: callSites, by: \.caller)
        let callers = callSitesByCaller.keys.sorted { ($0.filePath, $0.startLine, $0.startColumn) < ($1.filePath, $1.startLine, $1.startColumn) }
        return callers.map { caller in
            PendingCallEdge(
                caller: caller.endpoint,
                callee: callee.endpoint,
                fromRangesJSON: encodeFromRanges(callSitesByCaller[caller, default: []].map(\.range))
            )
        }
    }

    /// The workspace-relative path of `uri`, or `nil` when it is not a file
    /// under `rootDirectory` (for example a library outside the workspace).
    private static func relativePath(of uri: DocumentURI, rootDirectory: URL) -> String? {
        guard let url = URL(string: uri.value) else {
            return nil
        }
        return RelativePath.of(url, relativeTo: rootDirectory)
    }

    /// The callable symbols of `relativePath`, read one time for each pass.
    /// - Parameters:
    ///   - relativePath: The file to read the symbols of.
    ///   - rootDirectory: The workspace root `relativePath` is relative to.
    ///   - session: The live session to read the symbols through.
    ///   - callableSymbolsByFile: The callable symbols read so far in this pass.
    /// - Returns: The callable symbols of the file; empty when it cannot be read.
    private static func callableSymbols(
        in relativePath: String,
        rootDirectory: URL,
        session: LspSession<Connection>,
        callableSymbolsByFile: inout CallableSymbolsByFile
    ) async -> [FlatSymbol] {
        if let known = callableSymbolsByFile[relativePath] {
            return known
        }
        let symbols = await fetchCallableSymbols(of: relativePath, rootDirectory: rootDirectory, session: session)
        callableSymbolsByFile[relativePath] = symbols
        return symbols
    }

    /// Reads the callable symbols of a file that holds a reference: syncs its
    /// disk text, asks for its document symbols, then closes it.
    ///
    /// A path that is not a safe relative path (see
    /// `RelativePath.isSafeRelativePath(_:)`) or a file that cannot be read
    /// gives no symbols, the same rule `processFile` uses.
    /// - Parameters:
    ///   - relativePath: The file to read.
    ///   - rootDirectory: The workspace root `relativePath` is relative to.
    ///   - session: The live session to send the requests through.
    /// - Returns: The callable symbols of the file; empty on any failure.
    private static func fetchCallableSymbols(
        of relativePath: String,
        rootDirectory: URL,
        session: LspSession<Connection>
    ) async -> [FlatSymbol] {
        guard RelativePath.isSafeRelativePath(relativePath),
            let contents = readFileContents(relativePath: relativePath, rootDirectory: rootDirectory)
        else {
            return []
        }
        let uri = DocumentURI(rootDirectory.appendingPathComponent(relativePath).absoluteString)
        guard let symbols = await syncAndFetchSymbols(relativePath: relativePath, uri: uri, contents: contents, session: session) else {
            return []
        }
        await closeDocument(uri: uri, relativePath: relativePath, session: session)
        return flattenSymbols(filePath: relativePath, symbols: symbols).filter { callableKinds.contains($0.kind) }
    }

    /// The narrowest symbol of `symbols` whose range holds `position`.
    ///
    /// A method inside a class is narrower than the class, so a reference in
    /// a method goes to the method.
    /// - Parameters:
    ///   - symbols: The candidate symbols, all in the file of `position`.
    ///   - position: The position of a reference.
    /// - Returns: The narrowest symbol that holds `position`, or `nil` when none does.
    private static func narrowestSymbol(in symbols: [FlatSymbol], containing position: Position) -> FlatSymbol? {
        symbols.filter { $0.contains(position) }.min { first, second in
            (first.endLine - first.startLine, first.endColumn - first.startColumn)
                < (second.endLine - second.startLine, second.endColumn - second.startColumn)
        }
    }

    // MARK: - Invalidation from a new call site

    /// One call in the indexed file whose `definition` answer is a symbol of
    /// another file.
    struct CallSiteTarget: Sendable, Hashable {
        /// The start line of the callable symbol of the indexed file that
        /// holds the call.
        let callerStartLine: Int

        /// The file of the called symbol, relative to the workspace root.
        let calleeFile: String

        /// The position that the `definition` answer gave in `calleeFile`.
        let calleePosition: Position
    }

    /// Finds the symbol of another file that each call in `filePath` refers
    /// to, with one `textDocument/definition` request at the callee name of
    /// each call (see `TSCallGraph.calleeNamePositions(in:module:)`).
    ///
    /// Only a call inside a callable symbol of `filePath` counts: the
    /// references fallback gives no edge for a call outside a callable
    /// symbol either. A definition in `filePath` itself, or outside the
    /// workspace, gives no target.
    ///
    /// No request is sent, and the result is empty, in two cases:
    /// - The server advertises call hierarchy. The caller file then owns
    ///   its edges, and its own index pass writes a new call.
    /// - The content of `filePath` is the same as at its last LSP index
    ///   pass (see `Schema.IndexedFiles.lspContentHash`). Only an
    ///   invalidation from another file marked it dirty, so it has no new
    ///   call. This stops the chain of marks: two files that call each
    ///   other cannot mark each other dirty without end, also when the
    ///   `definition` and `references` answers of the server do not agree.
    /// - Parameters:
    ///   - filePath: The file `flatSymbols` were flattened from.
    ///   - uri: `filePath`'s document uri, already synced via `syncOpen`.
    ///   - contents: The text of `filePath`, where the calls are found.
    ///   - flatSymbols: The file's flattened symbols.
    ///   - rootDirectory: The workspace root the definition uris are resolved against.
    ///   - session: The live session to send the requests through.
    ///   - store: The workspace's index store, where the content hashes are.
    /// - Returns: The distinct targets of the calls of `filePath`.
    static func collectCallSiteTargets(
        filePath: String,
        uri: DocumentURI,
        contents: String,
        flatSymbols: [FlatSymbol],
        rootDirectory: URL,
        session: LspSession<Connection>,
        store: Store
    ) async -> Set<CallSiteTarget> {
        guard !session.capabilities.callHierarchy, await isChangedSinceLastPass(filePath: filePath, store: store) else {
            return []
        }
        let callables = flatSymbols.filter { callableKinds.contains($0.kind) }
        var targets: Set<CallSiteTarget> = []
        for call in calls(in: filePath, contents: contents, callables: callables) {
            let locations = await definitionLocations(at: call.position, uri: uri, filePath: filePath, session: session)
            targets.formUnion(
                locations.compactMap { location in
                    guard let calleeFile = relativePath(of: location.uri, rootDirectory: rootDirectory), calleeFile != filePath else {
                        return nil
                    }
                    return CallSiteTarget(callerStartLine: call.caller.startLine, calleeFile: calleeFile, calleePosition: location.range.start)
                })
        }
        return targets
    }

    /// The position of the callee name of each call in `contents` that a
    /// callable symbol holds, together with that symbol.
    /// - Parameters:
    ///   - filePath: The file of `contents`; its extension selects the grammar.
    ///   - contents: The text of the file.
    ///   - callables: The callable symbols of the file.
    /// - Returns: One entry for each call inside a callable symbol; empty
    ///   when no language module parses the file.
    private static func calls(in filePath: String, contents: String, callables: [FlatSymbol]) -> [(caller: FlatSymbol, position: Position)] {
        guard let module = Languages.module(forFileExtension: URL(fileURLWithPath: filePath).pathExtension) else {
            return []
        }
        let file = SourceFile(relativePath: filePath, contents: contents)
        return TSCallGraph.calleeNamePositions(in: file, module: module).compactMap { position in
            narrowestSymbol(in: callables, containing: position).map { caller in (caller, position) }
        }
    }

    /// Asks the server for the definition of the symbol at `position`.
    /// - Parameters:
    ///   - position: The position of a callee name.
    ///   - uri: The document of `position`, already synced via `syncOpen`.
    ///   - filePath: The file of `uri`, used only for the log line.
    ///   - session: The live session to send the request through.
    /// - Returns: The definition locations; empty when the request failed
    ///   (a failure is logged one time for each server).
    private static func definitionLocations(
        at position: Position,
        uri: DocumentURI,
        filePath: String,
        session: LspSession<Connection>
    ) async -> [Location] {
        do {
            return try await session.definition(uri: uri, at: position)
        } catch {
            await session.logFailure(of: .definition, context: "\(filePath):\(position.line):\(position.character)", error: error)
            return []
        }
    }

    /// Whether the content of `filePath` changed since its last LSP index
    /// pass: its `content_hash` is not the `lsp_content_hash` that
    /// `recordLspContentHash(db:filePath:)` wrote. A file with no LSP index
    /// pass yet (a `NULL` hash) counts as changed.
    /// - Parameters:
    ///   - filePath: The file to check.
    ///   - store: The workspace's index store.
    /// - Returns: `true` when the content changed; `false` when it did not,
    ///   or when the store cannot be read (the failure is logged).
    private static func isChangedSinceLastPass(filePath: String, store: Store) async -> Bool {
        do {
            return try await store.read { db in
                try Bool.fetchOne(
                    db,
                    sql: """
                        SELECT \(Schema.IndexedFiles.lspContentHash) IS NOT \(Schema.IndexedFiles.contentHash) \
                        FROM \(Schema.IndexedFiles.table) WHERE \(Schema.IndexedFiles.filePath) = ?
                        """,
                    arguments: [filePath]
                ) ?? false
            }
        } catch {
            Log.lsp.error(
                "failed to read the content hashes of \(filePath, privacy: .public); no call-site check: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    /// Records the current `content_hash` of `filePath` as its
    /// `lsp_content_hash`, the content of its last LSP index pass (see
    /// `isChangedSinceLastPass(filePath:store:)`).
    /// - Parameters:
    ///   - db: The write-transaction database connection.
    ///   - filePath: The file that the pass indexed.
    /// - Throws: Rethrows any error the statement throws.
    static func recordLspContentHash(db: Database, filePath: String) throws {
        try db.execute(
            sql: """
                UPDATE \(Schema.IndexedFiles.table) \
                SET \(Schema.IndexedFiles.lspContentHash) = \(Schema.IndexedFiles.contentHash) \
                WHERE \(Schema.IndexedFiles.filePath) = ?
                """,
            arguments: [filePath]
        )
    }

    /// The files of the symbols that `targets` call with no stored edge from
    /// the caller to the called symbol.
    ///
    /// Such a call is new or changed since the last index pass of the callee
    /// file, which owns the edges into its symbols. A target whose position
    /// is in no callable symbol of the stored index gives no file: the
    /// references fallback gives edges into callable symbols only.
    /// - Parameters:
    ///   - db: The write-transaction database connection.
    ///   - targets: The call-site targets of the indexed file.
    ///   - symbolIDsByStartLine: The indexed file's freshly written symbol row ids, keyed by start line.
    /// - Returns: The distinct callee files to mark `lsp_indexed = 0`.
    /// - Throws: Rethrows any error the queries throw.
    static func calleeFilesMissingAnEdge(db: Database, targets: Set<CallSiteTarget>, symbolIDsByStartLine: [Int: Int64]) throws -> Set<String> {
        let missing = try targets.filter { target in
            guard let callerID = symbolIDsByStartLine[target.callerStartLine],
                let calleeID = try callableSymbolID(db: db, filePath: target.calleeFile, containing: target.calleePosition)
            else {
                return false
            }
            return try !hasCallEdge(db: db, callerID: callerID, calleeID: calleeID)
        }
        return Set(missing.map(\.calleeFile))
    }

    /// The row id of the narrowest stored callable symbol of `filePath`
    /// whose range holds `position`.
    /// - Parameters:
    ///   - db: The database connection to query.
    ///   - filePath: The file of the symbol.
    ///   - position: A position inside the symbol, for example its name.
    /// - Returns: The symbol's row id, or `nil` when no callable symbol holds `position`.
    /// - Throws: Rethrows any error the query throws.
    private static func callableSymbolID(db: Database, filePath: String, containing position: Position) throws -> Int64? {
        let kinds = callableKinds.map(kindString(for:))
        let kindPlaceholders = kinds.map { _ in "?" }.joined(separator: ", ")
        let line = position.line
        let column = position.character
        return try Int64.fetchOne(
            db,
            sql: """
                SELECT \(Schema.LspSymbols.id) FROM \(Schema.LspSymbols.table) \
                WHERE \(Schema.LspSymbols.filePath) = ? AND \(Schema.LspSymbols.kind) IN (\(kindPlaceholders)) \
                AND (\(Schema.LspSymbols.startLine) < ? OR (\(Schema.LspSymbols.startLine) = ? AND \(Schema.LspSymbols.startColumn) <= ?)) \
                AND (\(Schema.LspSymbols.endLine) > ? OR (\(Schema.LspSymbols.endLine) = ? AND \(Schema.LspSymbols.endColumn) >= ?)) \
                ORDER BY (\(Schema.LspSymbols.endLine) - \(Schema.LspSymbols.startLine)), \
                         (\(Schema.LspSymbols.endColumn) - \(Schema.LspSymbols.startColumn)) \
                LIMIT 1
                """,
            arguments: StatementArguments([filePath]) + StatementArguments(kinds)
                + StatementArguments([line, line, column, line, line, column])
        )
    }

    /// Whether the index holds an LSP call edge from `callerID` to `calleeID`.
    /// - Parameters:
    ///   - db: The database connection to query.
    ///   - callerID: The row id of the calling symbol.
    ///   - calleeID: The row id of the called symbol.
    /// - Returns: `true` when such an edge exists, whichever file owns it.
    /// - Throws: Rethrows any error the query throws.
    private static func hasCallEdge(db: Database, callerID: Int64, calleeID: Int64) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS(SELECT 1 FROM \(Schema.LspCallEdges.table) \
                WHERE \(Schema.LspCallEdges.callerId) = ? AND \(Schema.LspCallEdges.calleeId) = ? \
                AND \(Schema.LspCallEdges.source) = 'lsp')
                """,
            arguments: [callerID, calleeID]
        ) ?? false
    }
}

import Foundation

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
/// index pass replaces them. An edge thus stays until the callee file is
/// indexed again: a new call in another file shows only after that. A caller
/// that another file deletes marks the owner file dirty (see
/// `reverseEdgeFiles(db:symbolIDs:excludingFile:)`).
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
}

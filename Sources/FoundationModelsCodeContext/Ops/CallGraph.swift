import Foundation
import GRDB

/// Which direction `CallGraphOps.callGraph(store:of:direction:maxDepth:)`
/// follows `lsp_call_edges` from the start symbol.
public enum CallGraphDirection: String, Codable, Sendable, Equatable, CaseIterable {
    /// Follow edges from callee to caller — "who calls this?".
    case inbound

    /// Follow edges from caller to callee — "what does this call?".
    case outbound

    /// Follow edges in both directions from every visited node.
    case both
}

/// Provenance of one `lsp_call_edges` row: which layer discovered it.
///
/// Mirrors `lsp_call_edges.source`'s `CHECK (source IN ('lsp', 'treesitter'))`
/// constraint exactly — unlike `SymbolOps.SymbolSource`, which additionally
/// has a `.merged` case for symbol lookup's ts_chunks/lsp_symbols merge, a
/// call edge always comes from exactly one of these two layers and is never
/// merged, so this is its own, narrower type rather than a reuse of
/// `SymbolSource`.
public enum CallEdgeSource: String, Codable, Sendable, Equatable {
    /// Discovered via LSP call-hierarchy data.
    case lsp

    /// Discovered via the tree-sitter call-expression heuristic
    /// (`TSCallGraph`).
    case treeSitter = "treesitter"
}

/// One symbol identified in a call graph or blast radius — an `lsp_symbols`
/// row's identity and location.
public struct CallGraphNode: Codable, Sendable, Equatable {
    /// The symbol's `lsp_symbols.id`.
    ///
    /// An integer FK into `lsp_symbols`, not the Rust reference's
    /// `"{source}:{file}:{qualified_path}"`-encoded string ID — this port's
    /// schema uses an autoincrementing primary key (see `Schema.LspSymbols`),
    /// matching `TSCallGraph.ensureSymbolID(db:filePath:symbolPath:kind:startLine:endLine:)`'s
    /// return type.
    public let symbolID: Int64

    /// The symbol's name.
    public let name: String

    /// The file containing the symbol.
    public let filePath: String

    /// Creates a call graph node.
    ///
    /// - Parameters:
    ///   - symbolID: The symbol's `lsp_symbols.id`.
    ///   - name: The symbol's name.
    ///   - filePath: The file containing the symbol.
    public init(symbolID: Int64, name: String, filePath: String) {
        self.symbolID = symbolID
        self.name = name
        self.filePath = filePath
    }
}

/// One directed `lsp_call_edges` row, resolved to its caller's and callee's
/// full node identity.
public struct CallGraphEdge: Codable, Sendable, Equatable {
    /// The calling symbol.
    public let caller: CallGraphNode

    /// The called symbol.
    public let callee: CallGraphNode

    /// Which layer discovered this edge.
    public let source: CallEdgeSource

    /// The BFS depth at which this edge was discovered, relative to the
    /// traversal's root (the root's own outgoing/incoming edges are depth 1).
    public let depth: Int

    /// Creates a call graph edge.
    ///
    /// - Parameters:
    ///   - caller: The calling symbol.
    ///   - callee: The called symbol.
    ///   - source: Which layer discovered this edge.
    ///   - depth: The BFS depth at which this edge was discovered.
    public init(caller: CallGraphNode, callee: CallGraphNode, source: CallEdgeSource, depth: Int) {
        self.caller = caller
        self.callee = callee
        self.source = source
        self.depth = depth
    }
}

/// The result of a `CallGraphOps.callGraph(store:of:direction:maxDepth:)`
/// traversal.
public struct CallGraph: Codable, Sendable, Equatable {
    /// The symbol traversal started from.
    public let root: CallGraphNode

    /// Every node reached during traversal, including `root`, each appearing
    /// exactly once in first-visited order.
    public let nodes: [CallGraphNode]

    /// Every edge discovered during traversal, in the order BFS encountered them.
    ///
    /// An edge whose endpoint had already been visited (e.g. the edge that
    /// closes a cycle) is still included here even though it did not grow
    /// `nodes`.
    public let edges: [CallGraphEdge]

    /// Creates a call graph result.
    ///
    /// - Parameters:
    ///   - root: The symbol traversal started from.
    ///   - nodes: Every node reached during traversal, including `root`.
    ///   - edges: Every edge discovered during traversal.
    public init(root: CallGraphNode, nodes: [CallGraphNode], edges: [CallGraphEdge]) {
        self.root = root
        self.nodes = nodes
        self.edges = edges
    }
}

/// Which side of an `lsp_call_edges` row `CallGraphOps.fetchCallEdges(db:symbolID:side:)`
/// filters on.
///
/// Not `private`: `BlastRadiusOps` reuses `fetchCallEdges(db:symbolID:side:)`
/// with `.callee` for its own inbound-caller expansion, so the two ops share
/// one join query instead of each maintaining their own copy — see this
/// file's and `BlastRadius.swift`'s type-level doc comments.
enum CallEdgeSide {
    /// Filter on `lsp_call_edges.caller_id` — "what does this symbol call?".
    case caller

    /// Filter on `lsp_call_edges.callee_id` — "what calls this symbol?".
    case callee

    /// The `lsp_call_edges` column this side filters on.
    ///
    /// A `switch`, not a dictionary: this is a closed, two-case mapping
    /// colocated with the type it describes, matching this codebase's
    /// established enum-to-value convention (see `IndexLayer.column`'s doc
    /// comment for the full rationale).
    var column: String {
        switch self {
        case .caller:
            return Schema.LspCallEdges.callerId
        case .callee:
            return Schema.LspCallEdges.calleeId
        }
    }
}

/// Call graph traversal from a starting symbol, over `lsp_call_edges`.
///
/// Port of the Rust `swissarmyhammer-code-context::ops::get_callgraph` module
/// (`crates/swissarmyhammer-code-context/src/ops/get_callgraph.rs`). Two
/// schema differences shape this port, both already documented at the
/// type level: `CallGraphNode.symbolID` is an integer FK rather than the
/// Rust reference's composite string ID, and `CallEdgeSource` is its own
/// two-case type rather than a reuse of `SymbolOps.SymbolSource`.
///
/// Symbol-by-name resolution goes through `SymbolOps.getSymbol(store:query:maxResults:)`
/// for its four-tier matching (exact/suffix/case-insensitive/fuzzy), then
/// correlates the winning match's `(filePath, startLine)` against
/// `lsp_symbols` to recover the `lsp_symbols.id` a call-graph traversal
/// actually needs — the same correlation key `SymbolOps`'s own ts_chunks/
/// lsp_symbols merge and `TSCallGraph.ensureSymbolID(db:filePath:symbolPath:kind:startLine:endLine:)`
/// both already use. A name that resolves to a symbol with no `lsp_symbols`
/// row at that location (a tree-sitter-only symbol that has never
/// participated in a call edge) cannot be a call-graph root and is reported
/// as `CodeContextError.notFound`, just as an unresolvable name is.
public enum CallGraphOps {
    /// The traversal depth clamp's lower bound.
    private static let minDepth = 1

    /// The traversal depth clamp's upper bound.
    private static let maxDepthLimit = 5

    /// Traverses `lsp_call_edges` starting from `symbol`, in `direction`, up
    /// to `maxDepth` hops.
    ///
    /// - Parameters:
    ///   - store: The workspace's index store to traverse.
    ///   - symbol: The start symbol — either a name (resolved via
    ///     `SymbolOps.getSymbol(store:query:maxResults:)`'s tiered matching)
    ///     or a `"<filePath>:<line>:<column>"` locator, both zero-based,
    ///     resolved to the narrowest `lsp_symbols` row enclosing that
    ///     position.
    ///   - direction: Which edges to follow. Defaults to `.outbound`.
    ///   - maxDepth: The maximum traversal depth, clamped to `1...5`.
    ///     Defaults to `2`.
    /// - Returns: The root symbol plus every node and edge BFS discovered.
    /// - Throws: `CodeContextError.notFound` if `symbol` cannot be resolved
    ///   to an `lsp_symbols` row. Rethrows `Store`'s storage errors.
    public static func callGraph(
        store: Store,
        of symbol: String,
        direction: CallGraphDirection = .outbound,
        maxDepth: Int = 2
    ) async throws -> CallGraph {
        let clampedMaxDepth = min(max(maxDepth, minDepth), maxDepthLimit)
        let locator = SymbolLocator.parse(identifier: symbol)
        let nameMatch = try await SymbolOps.getSymbol(store: store, query: symbol, maxResults: 1).symbols.first

        return try await store.read { db in
            let root = try resolveRoot(db: db, identifier: symbol, locator: locator, nameMatch: nameMatch)
            return try traverse(db: db, root: root, direction: direction, maxDepth: clampedMaxDepth)
        }
    }

    /// Resolves `identifier` to its root `CallGraphNode`, trying a
    /// `file:line:column` locator first, falling back to `nameMatch`'s
    /// resolved location.
    ///
    /// - Parameters:
    ///   - db: The database connection to query.
    ///   - identifier: The original, unparsed symbol identifier — used only
    ///     for the thrown error message when resolution fails entirely.
    ///   - locator: `identifier` parsed as a `file:line:column` locator, or
    ///     `nil` if it doesn't have that shape.
    ///   - nameMatch: `identifier`'s best `SymbolOps.getSymbol` match, or
    ///     `nil` if none matched.
    /// - Returns: The resolved root node.
    /// - Throws: `CodeContextError.notFound` if neither `locator` nor
    ///   `nameMatch` resolves to an `lsp_symbols` row. Rethrows any error the
    ///   underlying queries throw.
    private static func resolveRoot(db: Database, identifier: String, locator: SymbolLocator?, nameMatch: SymbolMatch?) throws -> CallGraphNode {
        if let locator, let node = try findNode(db: db, atLocationIn: locator.filePath, line: locator.line, column: locator.column) {
            return node
        }
        if let nameMatch, let node = try findNode(db: db, atStartLineIn: nameMatch.filePath, startLine: nameMatch.startLine) {
            return node
        }
        throw CodeContextError.notFound("symbol not found: \(identifier)")
    }

    /// Finds the narrowest `lsp_symbols` row in `filePath` whose range
    /// encloses `(line, column)`.
    ///
    /// - Parameters:
    ///   - db: The database connection to query.
    ///   - filePath: The file to search within.
    ///   - line: The zero-based line to locate.
    ///   - column: The zero-based column to locate.
    /// - Returns: The narrowest enclosing symbol's node, or `nil` if none
    ///   encloses `(line, column)`.
    /// - Throws: Rethrows any error the query throws.
    private static func findNode(db: Database, atLocationIn filePath: String, line: Int, column: Int) throws -> CallGraphNode? {
        try Row.fetchOne(
            db,
            sql: """
            SELECT \(Schema.LspSymbols.id), \(Schema.LspSymbols.name), \(Schema.LspSymbols.filePath) \
            FROM \(Schema.LspSymbols.table) \
            WHERE \(Schema.LspSymbols.filePath) = ? AND \(Schema.LspSymbols.startLine) <= ? AND \(Schema.LspSymbols.endLine) >= ? \
                AND \(Schema.LspSymbols.startColumn) <= ? \
            ORDER BY (\(Schema.LspSymbols.endLine) - \(Schema.LspSymbols.startLine)) ASC, \
                     (\(Schema.LspSymbols.endColumn) - \(Schema.LspSymbols.startColumn)) ASC \
            LIMIT 1
            """,
            arguments: [filePath, line, line, column]
        ).map(makeNode)
    }

    /// Finds the `lsp_symbols` row in `filePath` starting at `startLine` —
    /// the `(file_path, start_line)` correlation key `SymbolOps` and
    /// `TSCallGraph` both use to relate a `ts_chunks`-derived match back to
    /// its `lsp_symbols` identity.
    ///
    /// - Parameters:
    ///   - db: The database connection to query.
    ///   - filePath: The file to search within.
    ///   - startLine: The zero-based start line to match exactly.
    /// - Returns: The matching symbol's node, or `nil` if no `lsp_symbols`
    ///   row exists at that location.
    /// - Throws: Rethrows any error the query throws.
    private static func findNode(db: Database, atStartLineIn filePath: String, startLine: Int) throws -> CallGraphNode? {
        try Row.fetchOne(
            db,
            sql: """
            SELECT \(Schema.LspSymbols.id), \(Schema.LspSymbols.name), \(Schema.LspSymbols.filePath) \
            FROM \(Schema.LspSymbols.table) \
            WHERE \(Schema.LspSymbols.filePath) = ? AND \(Schema.LspSymbols.startLine) = ? \
            LIMIT 1
            """,
            arguments: [filePath, startLine]
        ).map(makeNode)
    }

    /// Builds a `CallGraphNode` from a row shaped by either `findNode`
    /// overload's `SELECT id, name, file_path` projection.
    private static func makeNode(from row: Row) -> CallGraphNode {
        CallGraphNode(
            symbolID: row[Schema.LspSymbols.id],
            name: row[Schema.LspSymbols.name],
            filePath: row[Schema.LspSymbols.filePath]
        )
    }

    /// Runs breadth-first search from `root` over `lsp_call_edges`, in
    /// `direction`, stopping once a node's depth reaches `maxDepth`.
    ///
    /// Every node is enqueued and appended to the result at most once (on
    /// first visit), so a cycle in the edge graph terminates traversal
    /// rather than looping forever; the edge that closes a cycle is still
    /// recorded in `edges` even though its target was already visited.
    ///
    /// - Parameters:
    ///   - db: The database connection to query.
    ///   - root: The already-resolved start node.
    ///   - direction: Which edges to follow.
    ///   - maxDepth: The already-clamped maximum traversal depth.
    /// - Returns: The completed call graph.
    /// - Throws: Rethrows any error the underlying edge queries throw.
    private static func traverse(db: Database, root: CallGraphNode, direction: CallGraphDirection, maxDepth: Int) throws -> CallGraph {
        var visitedIDs: Set<Int64> = [root.symbolID]
        var nodes: [CallGraphNode] = [root]
        var edges: [CallGraphEdge] = []
        var queue: [(symbolID: Int64, depth: Int)] = [(root.symbolID, 0)]
        var queueIndex = 0

        while queueIndex < queue.count {
            let (currentID, depth) = queue[queueIndex]
            queueIndex += 1
            guard depth < maxDepth else {
                continue
            }

            for edge in try fetchAdjacentEdges(db: db, symbolID: currentID, direction: direction, depth: depth + 1) {
                let nextID = nextSymbolID(edge: edge, direction: direction, visited: visitedIDs)
                if visitedIDs.insert(nextID).inserted {
                    nodes.append(nextID == edge.caller.symbolID ? edge.caller : edge.callee)
                    queue.append((nextID, depth + 1))
                }
                edges.append(edge)
            }
        }

        return CallGraph(root: root, nodes: nodes, edges: edges)
    }

    /// Fetches `symbolID`'s adjacent edges in `direction`, tagging each with
    /// `depth`.
    ///
    /// - Parameters:
    ///   - db: The database connection to query.
    ///   - symbolID: The symbol whose adjacent edges to fetch.
    ///   - direction: Which side(s) to query — outbound queries edges where
    ///     `symbolID` is the caller, inbound where it is the callee, both
    ///     queries both.
    ///   - depth: The BFS depth to stamp onto every returned edge.
    /// - Returns: The matching edges, outbound before inbound when
    ///   `direction` is `.both`.
    /// - Throws: Rethrows any error the underlying queries throw.
    private static func fetchAdjacentEdges(db: Database, symbolID: Int64, direction: CallGraphDirection, depth: Int) throws -> [CallGraphEdge] {
        var edges: [CallGraphEdge] = []
        if direction == .outbound || direction == .both {
            edges += try fetchCallEdges(db: db, symbolID: symbolID, side: .caller).map { row in
                CallGraphEdge(caller: row.caller, callee: row.callee, source: row.source, depth: depth)
            }
        }
        if direction == .inbound || direction == .both {
            edges += try fetchCallEdges(db: db, symbolID: symbolID, side: .callee).map { row in
                CallGraphEdge(caller: row.caller, callee: row.callee, source: row.source, depth: depth)
            }
        }
        return edges
    }

    /// Determines which side of `edge` BFS should visit next, per `direction`.
    ///
    /// A `switch`, not a dictionary, per this codebase's closed-enum-mapping
    /// convention (see `IndexLayer.column`'s doc comment): `.both` needs a
    /// branch of actual logic (prefer the callee, unless it was already
    /// visited), which only a switch arm can express.
    ///
    /// - Parameters:
    ///   - edge: The edge being expanded.
    ///   - direction: The traversal's direction.
    ///   - visited: The symbol IDs visited so far.
    /// - Returns: The next symbol ID to (potentially) enqueue.
    private static func nextSymbolID(edge: CallGraphEdge, direction: CallGraphDirection, visited: Set<Int64>) -> Int64 {
        switch direction {
        case .inbound:
            return edge.caller.symbolID
        case .outbound:
            return edge.callee.symbolID
        case .both:
            return visited.contains(edge.callee.symbolID) ? edge.caller.symbolID : edge.callee.symbolID
        }
    }

    // MARK: - Shared edge fetch (also used by BlastRadiusOps)

    /// One `lsp_call_edges` row joined against `lsp_symbols` on both sides,
    /// shared by `CallGraphOps.traverse(db:root:direction:maxDepth:)` and
    /// `BlastRadiusOps`'s inbound hop expansion — the one place either op
    /// needs a fully name/file-resolved edge, not just the raw
    /// `caller_id`/`callee_id` pair.
    struct CallEdgeRow: Sendable, Equatable {
        /// The calling symbol.
        let caller: CallGraphNode

        /// The called symbol.
        let callee: CallGraphNode

        /// Which layer discovered this edge.
        let source: CallEdgeSource
    }

    /// Fetches every `lsp_call_edges` row where `side`'s column equals
    /// `symbolID`, joined against `lsp_symbols` for both the caller's and
    /// callee's `name`/`file_path`.
    ///
    /// Not `private`: `BlastRadiusOps` calls this directly with `.callee` to
    /// find a symbol's inbound callers, reusing this exact join instead of
    /// duplicating it — see this type's and `BlastRadius.swift`'s
    /// doc comments.
    ///
    /// - Parameters:
    ///   - db: The database connection to query.
    ///   - symbolID: The symbol ID to filter `side`'s column on.
    ///   - side: Which `lsp_call_edges` column to filter on.
    /// - Returns: Every matching edge, resolved to full caller/callee nodes.
    /// - Throws: `CodeContextError.storage` if a row's `source` column holds
    ///   a value outside `CallEdgeSource`'s domain. Rethrows any error the
    ///   query itself throws.
    static func fetchCallEdges(db: Database, symbolID: Int64, side: CallEdgeSide) throws -> [CallEdgeRow] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT caller.\(Schema.LspSymbols.id) AS caller_id, caller.\(Schema.LspSymbols.name) AS caller_name, \
                   caller.\(Schema.LspSymbols.filePath) AS caller_file_path, \
                   callee.\(Schema.LspSymbols.id) AS callee_id, callee.\(Schema.LspSymbols.name) AS callee_name, \
                   callee.\(Schema.LspSymbols.filePath) AS callee_file_path, \
                   edges.\(Schema.LspCallEdges.source) AS edge_source \
            FROM \(Schema.LspCallEdges.table) AS edges \
            JOIN \(Schema.LspSymbols.table) AS caller ON caller.\(Schema.LspSymbols.id) = edges.\(Schema.LspCallEdges.callerId) \
            JOIN \(Schema.LspSymbols.table) AS callee ON callee.\(Schema.LspSymbols.id) = edges.\(Schema.LspCallEdges.calleeId) \
            WHERE edges.\(side.column) = ?
            """,
            arguments: [symbolID]
        )
        return try rows.map { row in
            CallEdgeRow(
                caller: CallGraphNode(symbolID: row["caller_id"], name: row["caller_name"], filePath: row["caller_file_path"]),
                callee: CallGraphNode(symbolID: row["callee_id"], name: row["callee_name"], filePath: row["callee_file_path"]),
                source: try parseCallEdgeSource(row["edge_source"])
            )
        }
    }

    /// Parses `rawValue` (an `lsp_call_edges.source` column value) into a
    /// `CallEdgeSource`.
    ///
    /// - Parameter rawValue: The raw `source` column text.
    /// - Returns: The parsed source.
    /// - Throws: `CodeContextError.storage` if `rawValue` isn't `"lsp"` or
    ///   `"treesitter"` — the table's own `CHECK` constraint should make this
    ///   unreachable in practice, but a malformed row is reported rather
    ///   than silently miscategorized.
    private static func parseCallEdgeSource(_ rawValue: String) throws -> CallEdgeSource {
        guard let source = CallEdgeSource(rawValue: rawValue) else {
            throw CodeContextError.storage("unrecognized lsp_call_edges.source value: '\(rawValue)'")
        }
        return source
    }
}

/// A parsed `"<filePath>:<line>:<column>"` symbol locator.
///
/// Not `private`: shared by `CallGraphOps` today and available to any future
/// op that needs the same locator syntax, so parsing it stays in exactly one
/// place.
struct SymbolLocator: Equatable {
    /// The locator's file path.
    let filePath: String

    /// The locator's zero-based line.
    let line: Int

    /// The locator's zero-based column.
    let column: Int

    /// Parses `identifier` as a `"<filePath>:<line>:<column>"` locator.
    ///
    /// Splits on every `:` and takes the last two segments as `line`/
    /// `column`, rejoining every segment before them (with `:`) as
    /// `filePath` — mirroring the Rust reference's `rsplitn(3, ':')`, so a
    /// file path that itself contains colons still parses correctly as long
    /// as `line`/`column` are the final two segments.
    ///
    /// - Parameter identifier: The string to parse.
    /// - Returns: The parsed locator, or `nil` if `identifier` doesn't have
    ///   at least three `:`-separated segments, or its last two segments
    ///   aren't both integers.
    static func parse(identifier: String) -> SymbolLocator? {
        let segments = identifier.split(separator: ":", omittingEmptySubsequences: false)
        guard segments.count >= 3 else {
            return nil
        }
        guard let line = Int(segments[segments.count - 2]), let column = Int(segments[segments.count - 1]) else {
            return nil
        }
        let filePath = segments[0..<(segments.count - 2)].joined(separator: ":")
        return SymbolLocator(filePath: filePath, line: line, column: column)
    }
}

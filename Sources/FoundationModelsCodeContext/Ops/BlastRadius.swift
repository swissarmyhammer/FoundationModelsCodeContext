import Foundation
import GRDB

/// One symbol discovered while expanding a `BlastRadiusOps.blastRadius(store:file:symbol:maxHops:)`
/// hop — a caller found transitively upstream of the starting file/symbol.
public struct AffectedSymbol: Codable, Sendable, Equatable {
    /// The symbol's `lsp_symbols.id`.
    public let symbolID: Int64

    /// The symbol's name.
    public let name: String

    /// The file containing the symbol.
    public let filePath: String

    /// Which layer discovered the call edge that led to this symbol.
    public let source: CallEdgeSource

    /// Creates an affected symbol.
    ///
    /// - Parameters:
    ///   - symbolID: The symbol's `lsp_symbols.id`.
    ///   - name: The symbol's name.
    ///   - filePath: The file containing the symbol.
    ///   - source: Which layer discovered the call edge that led to this
    ///     symbol.
    public init(symbolID: Int64, name: String, filePath: String, source: CallEdgeSource) {
        self.symbolID = symbolID
        self.name = name
        self.filePath = filePath
        self.source = source
    }
}

/// The symbols and files discovered at one hop distance from the starting
/// file/symbol.
public struct HopLevel: Codable, Sendable, Equatable {
    /// The hop distance from the starting symbol(s), starting at `1`.
    public let hop: Int

    /// Symbols discovered at this hop.
    public let symbols: [AffectedSymbol]

    /// The number of distinct files `symbols` span — deduplicated, so two
    /// symbols in the same file count as one affected file, not two.
    public let affectedFiles: Int

    /// Creates a hop level.
    ///
    /// - Parameters:
    ///   - hop: The hop distance from the starting symbol(s).
    ///   - symbols: Symbols discovered at this hop.
    ///   - affectedFiles: The number of distinct files `symbols` span.
    public init(hop: Int, symbols: [AffectedSymbol], affectedFiles: Int) {
        self.hop = hop
        self.symbols = symbols
        self.affectedFiles = affectedFiles
    }
}

/// The result of a `BlastRadiusOps.blastRadius(store:file:symbol:maxHops:)`
/// analysis.
public struct BlastRadius: Codable, Sendable, Equatable {
    /// The starting symbols' `lsp_symbols.id` values.
    public let roots: [Int64]

    /// Impact broken down by hop level, in ascending hop order.
    ///
    /// Empty if no caller was found at hop 1 (traversal stops as soon as a
    /// hop discovers nothing new — see `BlastRadiusOps`'s doc comment).
    public let hops: [HopLevel]

    /// The total number of distinct affected symbols, across every hop.
    public let totalAffectedSymbols: Int

    /// The total number of distinct affected files, across every hop —
    /// deduplicated globally, so a file that recurs across multiple hops
    /// (e.g. two different symbols in the same file, discovered at
    /// different hops) still counts once.
    public let totalAffectedFiles: Int

    /// Creates a blast radius result.
    ///
    /// - Parameters:
    ///   - roots: The starting symbols' `lsp_symbols.id` values.
    ///   - hops: Impact broken down by hop level.
    ///   - totalAffectedSymbols: The total number of distinct affected
    ///     symbols, across every hop.
    ///   - totalAffectedFiles: The total number of distinct affected files,
    ///     across every hop.
    public init(roots: [Int64], hops: [HopLevel], totalAffectedSymbols: Int, totalAffectedFiles: Int) {
        self.roots = roots
        self.hops = hops
        self.totalAffectedSymbols = totalAffectedSymbols
        self.totalAffectedFiles = totalAffectedFiles
    }
}

/// Blast radius analysis for a file or symbol: transitive inbound callers
/// ("who calls this?"), aggregated per hop level.
///
/// Port of the Rust `swissarmyhammer-code-context::ops::get_blastradius`
/// module (`crates/swissarmyhammer-code-context/src/ops/get_blastradius.rs`).
/// Root-symbol name filtering matches on `lsp_symbols.name` directly rather
/// than the Rust reference's qualified-path/suffix match against its
/// composite string ID: this port's `lsp_symbols.name` already holds the
/// symbol's short name (see `TSCallGraph.ensureSymbolID(db:filePath:symbolPath:kind:startLine:endLine:)`,
/// which stores `SymbolOps.leafName(ofQualifiedPath:)`'s result there), so
/// there is no qualified path on this table to match a suffix against.
///
/// Inbound hop expansion reuses `CallGraphOps.fetchCallEdges(db:symbolID:side:)`
/// with `side: .callee` — the exact query `CallGraphOps`'s own inbound
/// direction uses to find a symbol's callers — rather than this file
/// maintaining a second copy of that join.
public enum BlastRadiusOps {
    /// The hop clamp's lower bound.
    private static let minHops = 1

    /// The hop clamp's upper bound.
    private static let maxHopsLimit = 10

    /// Finds every symbol in `file` (optionally narrowed to `symbol`), then
    /// follows inbound call edges transitively up to `maxHops` levels.
    ///
    /// - Parameters:
    ///   - store: The workspace's index store to analyze.
    ///   - file: The file to find starting symbols in.
    ///   - symbol: When non-`nil`, only `file`'s symbols named `symbol`
    ///     become starting roots. Defaults to `nil` (every symbol in `file`
    ///     is a root).
    ///   - maxHops: The maximum number of hops to follow, clamped to
    ///     `1...10`. Defaults to `3`.
    /// - Returns: The starting roots, plus per-hop impact summaries and
    ///   totals. A whole-file query (`symbol == nil`) on a file with no
    ///   indexed symbols returns an empty result rather than throwing.
    /// - Throws: `CodeContextError.notFound` if `symbol` is non-`nil` and
    ///   matches no symbol in `file`. Rethrows `Store`'s storage errors.
    public static func blastRadius(
        store: Store,
        file: String,
        symbol: String? = nil,
        maxHops: Int = 3
    ) async throws -> BlastRadius {
        let clampedMaxHops = min(max(maxHops, minHops), maxHopsLimit)

        return try await store.read { db in
            let roots = try findRoots(db: db, filePath: file, symbolName: symbol)
            guard !roots.isEmpty else {
                return try emptyResultOrThrow(symbol: symbol, filePath: file)
            }
            return try traverseInbound(db: db, roots: roots, maxHops: clampedMaxHops)
        }
    }

    /// Produces the whole-file "no symbols" empty result, or throws when a
    /// named-symbol filter matched nothing.
    ///
    /// - Parameters:
    ///   - symbol: The original named-symbol filter, if any.
    ///   - filePath: The file that was searched.
    /// - Returns: An empty `BlastRadius`, only when `symbol` is `nil`.
    /// - Throws: `CodeContextError.notFound` when `symbol` is non-`nil`.
    private static func emptyResultOrThrow(symbol: String?, filePath: String) throws -> BlastRadius {
        guard let symbol else {
            return BlastRadius(roots: [], hops: [], totalAffectedSymbols: 0, totalAffectedFiles: 0)
        }
        throw CodeContextError.notFound("symbol '\(symbol)' not found in file '\(filePath)'")
    }

    /// One `lsp_symbols` row identified as a blast-radius starting root.
    private struct RootSymbol: Sendable {
        let symbolID: Int64
        let name: String
    }

    /// Finds every `lsp_symbols` row in `filePath`, optionally narrowed to
    /// those named `symbolName`.
    ///
    /// - Parameters:
    ///   - db: The database connection to query.
    ///   - filePath: The file to search within.
    ///   - symbolName: When non-`nil`, only rows with this exact `name` are
    ///     returned.
    /// - Returns: The matching rows, in no particular order.
    /// - Throws: Rethrows any error the query throws.
    private static func findRoots(db: Database, filePath: String, symbolName: String?) throws -> [RootSymbol] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT \(Schema.LspSymbols.id), \(Schema.LspSymbols.name) FROM \(Schema.LspSymbols.table) \
            WHERE \(Schema.LspSymbols.filePath) = ?
            """,
            arguments: [filePath]
        )
        let allRoots = rows.map { row in
            RootSymbol(symbolID: row[Schema.LspSymbols.id], name: row[Schema.LspSymbols.name])
        }
        guard let symbolName else {
            return allRoots
        }
        // Filtered in Swift rather than a SQL `WHERE name = ?` so this
        // shares one query with the whole-file case above instead of
        // branching the SQL text on whether a filter was supplied.
        return allRoots.filter { $0.name == symbolName }
    }

    /// Runs inbound BFS from `roots`, aggregating discoveries per hop until
    /// either `maxHops` is reached or a hop discovers nothing new.
    ///
    /// - Parameters:
    ///   - db: The database connection to query.
    ///   - roots: The already-resolved starting symbols.
    ///   - maxHops: The already-clamped maximum number of hops.
    /// - Returns: The completed blast radius.
    /// - Throws: Rethrows any error the underlying edge queries throw.
    private static func traverseInbound(db: Database, roots: [RootSymbol], maxHops: Int) throws -> BlastRadius {
        var visited = Set(roots.map(\.symbolID))
        var frontier = roots.map(\.symbolID)
        var hops: [HopLevel] = []
        var allAffectedFiles: Set<String> = []
        var totalAffectedSymbols = 0

        for hop in 1...maxHops {
            let expansion = try expandHop(db: db, frontier: frontier, visited: &visited)
            guard !expansion.symbols.isEmpty else {
                break
            }

            totalAffectedSymbols += expansion.symbols.count
            allAffectedFiles.formUnion(expansion.files)
            hops.append(HopLevel(hop: hop, symbols: expansion.symbols, affectedFiles: expansion.files.count))
            frontier = expansion.nextFrontier
        }

        return BlastRadius(
            roots: roots.map(\.symbolID),
            hops: hops,
            totalAffectedSymbols: totalAffectedSymbols,
            totalAffectedFiles: allAffectedFiles.count
        )
    }

    /// Expands one hop: finds every not-yet-visited inbound caller of every
    /// symbol in `frontier`, via `CallGraphOps.fetchCallEdges(db:symbolID:side:)`.
    ///
    /// - Parameters:
    ///   - db: The database connection to query.
    ///   - frontier: The symbol IDs to find inbound callers of.
    ///   - visited: Every symbol ID visited so far. Updated in place with
    ///     every newly discovered caller, so a caller found via two
    ///     different frontier symbols in the same hop is only recorded once.
    /// - Returns: The next hop's frontier, its newly discovered symbols, and
    ///   the distinct files those symbols span.
    /// - Throws: Rethrows any error the underlying edge queries throw.
    private static func expandHop(
        db: Database,
        frontier: [Int64],
        visited: inout Set<Int64>
    ) throws -> (nextFrontier: [Int64], symbols: [AffectedSymbol], files: Set<String>) {
        var nextFrontier: [Int64] = []
        var symbols: [AffectedSymbol] = []
        var files: Set<String> = []

        for symbolID in frontier {
            for edge in try CallGraphOps.fetchCallEdges(db: db, symbolID: symbolID, side: .callee) {
                let caller = edge.caller
                guard visited.insert(caller.symbolID).inserted else {
                    continue
                }
                files.insert(caller.filePath)
                symbols.append(AffectedSymbol(symbolID: caller.symbolID, name: caller.name, filePath: caller.filePath, source: edge.source))
                nextFrontier.append(caller.symbolID)
            }
        }

        return (nextFrontier, symbols, files)
    }
}

import Foundation
import GRDB

/// Which data layer produced a `LiveOpsCore` op's result.
///
/// Matches this codebase's LSP acronym-casing convention (`LSP` uppercase,
/// see `LSPTypes.swift`/`LSPRange`/`LSPDaemon`/`LSPIndexWorker`), so this is
/// `SourceLayer.liveLSP` rather than the Rust reference's `SourceLayer::LiveLsp`.
enum SourceLayer: String, Codable, Sendable, Equatable {
    /// The result came from a live LSP server.
    case liveLSP

    /// The result came from the persisted LSP symbol index
    /// (`lsp_symbols`/`lsp_call_edges`).
    case lspIndex

    /// The result came from the tree-sitter chunk index (`ts_chunks`).
    case treeSitter

    /// No layer had data for the request — never an error, per this port's
    /// "no data" contract (see `LiveOpsCore`'s type-level doc comment).
    case none
}

/// Symbol information surfaced by the LSP-index or tree-sitter layer, used to
/// enrich a location or report a hover/definition/reference's enclosing
/// symbol.
///
/// Port of the Rust `swissarmyhammer-code-context::layered_context::SymbolInfo`.
/// `range` reuses this port's shared `LSPRange` (start/end `Position`) rather
/// than the Rust reference's bespoke `start_line`/`start_character`/
/// `end_line`/`end_character` fields — `LSPRange` already exists in
/// `LSPTypes.swift` and every other LSP-facing type in this package uses it,
/// so duplicating an equivalent shape here would be pure waste.
struct LayeredSymbolInfo: Codable, Sendable, Equatable {
    /// The symbol's short name.
    let name: String

    /// The symbol's fully qualified path, when known.
    ///
    /// Populated only for a tree-sitter-derived symbol (from `ts_chunks.symbol_path`,
    /// via `SymbolOps.leafName(ofQualifiedPath:)`'s companion field): this
    /// port's `lsp_symbols` schema has no qualified-path column (see
    /// `SymbolOps`'s type-level doc comment for why), so an LSP-index-derived
    /// symbol always has `qualifiedPath == nil`.
    let qualifiedPath: String?

    /// The symbol's kind — an `lsp_symbols.kind` string for an LSP-index
    /// match, or a `ts_chunks.kind` (`SymbolMetaType.rawValue`) string for a
    /// tree-sitter match.
    let kind: String

    /// Extra detail about the symbol (e.g. a function signature), if known
    /// from LSP.
    let detail: String?

    /// The file containing the symbol, relative to the workspace root.
    let filePath: String

    /// The symbol's span.
    let range: LSPRange
}

/// A `ts_chunks` row located by `LayeredContext.tsChunkAt`/`tsChunksMatching`.
struct LayeredChunkInfo: Sendable, Equatable {
    /// The chunk's full source text.
    let text: String

    /// The file containing the chunk, relative to the workspace root.
    let filePath: String

    /// The chunk's zero-based start line.
    let startLine: Int

    /// The chunk's zero-based end line.
    let endLine: Int

    /// The chunk's fully qualified symbol path (`ts_chunks.symbol_path`).
    let symbolPath: String

    /// The chunk's meta-type (`ts_chunks.kind`, a `SymbolMetaType.rawValue`).
    let kind: String
}

/// Layer 2 (`lsp_symbols`/`lsp_call_edges`) and layer 3 (`ts_chunks`) query
/// helpers shared by every `LiveOpsCore` op.
///
/// Port of the persisted-layer query methods on the Rust
/// `swissarmyhammer-code-context::layered_context::LayeredContext`
/// (`crates/swissarmyhammer-code-context/src/layered_context.rs`) —
/// deliberately *not* a port of that type's live-LSP request plumbing
/// (`lsp_request*`, `LiveLspRouter`, `MultiLspRouter`, `SharedLspSession`):
/// this Swift port has no cross-process follower/leader routing to bridge
/// (both router seams are removed per this task), and the live layer's
/// requests go through `LspSession`'s already-typed methods
/// (`LspSession.definition(uri:at:)`, `LspSession.hover(uri:at:)`, ...)
/// rather than raw JSON-RPC method/params pairs, so `LiveOpsCore` calls those
/// directly instead of through a shared request seam. This type is therefore
/// scoped to exactly the two synchronous, `Database`-backed layers, queried
/// from inside a `Store.read`/`Store.write` closure.
enum LayeredContext {
    // MARK: - Layer 2: LSP index (lsp_symbols, lsp_call_edges)

    /// Looks up the narrowest `lsp_symbols` row in `filePath` whose line
    /// range encloses `range`, mirroring the Rust reference's `lsp_symbol_at`
    /// exactly: only `start_line`/`end_line` are compared (never a column),
    /// so a point range built from a cursor's `(line, character)` matches any
    /// symbol whose line span contains that line, narrowest span first.
    ///
    /// - Parameters:
    ///   - db: The database connection to query.
    ///   - filePath: The file to search within.
    ///   - range: The range to locate a symbol at (only `start.line`/`end.line` matter).
    /// - Returns: The narrowest enclosing symbol, or `nil` if none matches.
    /// - Throws: Rethrows any error the query throws.
    static func lspSymbolAt(db: Database, filePath: String, range: LSPRange) throws -> LayeredSymbolInfo? {
        try lspSymbolRow(db: db, filePath: filePath, range: range)?.info
    }

    /// As `lspSymbolAt(db:filePath:range:)`, but also returns the row's
    /// `lsp_symbols.id` for callers (`LiveOpsCore.references`) that need to
    /// correlate the match against `lsp_call_edges`.
    ///
    /// - Parameters:
    ///   - db: The database connection to query.
    ///   - filePath: The file to search within.
    ///   - range: The range to locate a symbol at (only `start.line`/`end.line` matter).
    /// - Returns: The matching row's id and symbol info, or `nil` if none matches.
    /// - Throws: Rethrows any error the query throws.
    static func lspSymbolRow(db: Database, filePath: String, range: LSPRange) throws -> (id: Int64, info: LayeredSymbolInfo)? {
        guard
            let row = try Row.fetchOne(
                db,
                sql: """
                SELECT \(Schema.LspSymbols.id), \(Schema.LspSymbols.name), \(Schema.LspSymbols.kind), \(Schema.LspSymbols.detail), \
                       \(Schema.LspSymbols.startLine), \(Schema.LspSymbols.startColumn), \(Schema.LspSymbols.endLine), \(Schema.LspSymbols.endColumn) \
                FROM \(Schema.LspSymbols.table) \
                WHERE \(Schema.LspSymbols.filePath) = ? AND \(Schema.LspSymbols.startLine) <= ? AND \(Schema.LspSymbols.endLine) >= ? \
                ORDER BY (\(Schema.LspSymbols.endLine) - \(Schema.LspSymbols.startLine)) ASC \
                LIMIT 1
                """,
                arguments: [filePath, range.start.line, range.end.line]
            )
        else {
            return nil
        }
        let info = LayeredSymbolInfo(
            name: row[Schema.LspSymbols.name],
            qualifiedPath: nil,
            kind: row[Schema.LspSymbols.kind],
            detail: row[Schema.LspSymbols.detail],
            filePath: filePath,
            range: LSPRange(
                start: Position(line: row[Schema.LspSymbols.startLine], character: row[Schema.LspSymbols.startColumn]),
                end: Position(line: row[Schema.LspSymbols.endLine], character: row[Schema.LspSymbols.endColumn])
            )
        )
        return (row[Schema.LspSymbols.id], info)
    }

    /// Finds every caller of `symbolID` via `lsp_call_edges`, each paired
    /// with the call-site ranges recorded for it.
    ///
    /// - Parameters:
    ///   - db: The database connection to query.
    ///   - symbolID: The callee's `lsp_symbols.id` to find callers of.
    /// - Returns: Every caller, with its call-site ranges (empty if
    ///   `from_ranges` was empty or malformed).
    /// - Throws: Rethrows any error the query throws.
    static func lspCallersOf(db: Database, symbolID: Int64) throws -> [(symbol: LayeredSymbolInfo, callSites: [LSPRange])] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT s.\(Schema.LspSymbols.id), s.\(Schema.LspSymbols.name), s.\(Schema.LspSymbols.kind), s.\(Schema.LspSymbols.detail), \
                   s.\(Schema.LspSymbols.filePath), s.\(Schema.LspSymbols.startLine), s.\(Schema.LspSymbols.startColumn), \
                   s.\(Schema.LspSymbols.endLine), s.\(Schema.LspSymbols.endColumn), e.\(Schema.LspCallEdges.fromRanges) \
            FROM \(Schema.LspCallEdges.table) e \
            JOIN \(Schema.LspSymbols.table) s ON e.\(Schema.LspCallEdges.callerId) = s.\(Schema.LspSymbols.id) \
            WHERE e.\(Schema.LspCallEdges.calleeId) = ?
            """,
            arguments: [symbolID]
        )
        return rows.map { row in
            let info = LayeredSymbolInfo(
                name: row[Schema.LspSymbols.name],
                qualifiedPath: nil,
                kind: row[Schema.LspSymbols.kind],
                detail: row[Schema.LspSymbols.detail],
                filePath: row[Schema.LspSymbols.filePath],
                range: LSPRange(
                    start: Position(line: row[Schema.LspSymbols.startLine], character: row[Schema.LspSymbols.startColumn]),
                    end: Position(line: row[Schema.LspSymbols.endLine], character: row[Schema.LspSymbols.endColumn])
                )
            )
            let callSites = parseFromRanges(row[Schema.LspCallEdges.fromRanges])
            return (info, callSites)
        }
    }

    // MARK: - Layer 3: Tree-sitter index (ts_chunks)

    /// Finds the narrowest `ts_chunks` row in `filePath` containing `line`.
    ///
    /// - Parameters:
    ///   - db: The database connection to query.
    ///   - filePath: The file to search within.
    ///   - line: The zero-based line to locate a chunk at.
    /// - Returns: The narrowest enclosing chunk, or `nil` if none matches.
    /// - Throws: Rethrows any error the query throws.
    static func tsChunkAt(db: Database, filePath: String, line: Int) throws -> LayeredChunkInfo? {
        guard
            let row = try Row.fetchOne(
                db,
                sql: """
                SELECT \(Schema.TsChunks.text), \(Schema.TsChunks.startLine), \(Schema.TsChunks.endLine), \
                       \(Schema.TsChunks.symbolPath), \(Schema.TsChunks.kind) \
                FROM \(Schema.TsChunks.table) \
                WHERE \(Schema.TsChunks.filePath) = ? AND \(Schema.TsChunks.startLine) <= ? AND \(Schema.TsChunks.endLine) >= ? \
                ORDER BY (\(Schema.TsChunks.endLine) - \(Schema.TsChunks.startLine)) ASC \
                LIMIT 1
                """,
                arguments: [filePath, line, line]
            )
        else {
            return nil
        }
        return LayeredChunkInfo(
            text: row[Schema.TsChunks.text],
            filePath: filePath,
            startLine: row[Schema.TsChunks.startLine],
            endLine: row[Schema.TsChunks.endLine],
            symbolPath: row[Schema.TsChunks.symbolPath],
            kind: row[Schema.TsChunks.kind]
        )
    }

    /// Finds chunks whose text contains `query` (a plain substring match),
    /// capped at `max`.
    ///
    /// - Parameters:
    ///   - db: The database connection to query.
    ///   - query: The substring to search chunk text for.
    ///   - max: The maximum number of chunks to return.
    /// - Returns: Matching chunks, in no particular order.
    /// - Throws: Rethrows any error the query throws.
    static func tsChunksMatching(db: Database, query: String, max: Int) throws -> [LayeredChunkInfo] {
        let pattern = "%\(query)%"
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT \(Schema.TsChunks.text), \(Schema.TsChunks.filePath), \(Schema.TsChunks.startLine), \(Schema.TsChunks.endLine), \
                   \(Schema.TsChunks.symbolPath), \(Schema.TsChunks.kind) \
            FROM \(Schema.TsChunks.table) WHERE \(Schema.TsChunks.text) LIKE ? LIMIT ?
            """,
            arguments: [pattern, max]
        )
        return rows.map { row in
            LayeredChunkInfo(
                text: row[Schema.TsChunks.text],
                filePath: row[Schema.TsChunks.filePath],
                startLine: row[Schema.TsChunks.startLine],
                endLine: row[Schema.TsChunks.endLine],
                symbolPath: row[Schema.TsChunks.symbolPath],
                kind: row[Schema.TsChunks.kind]
            )
        }
    }

    // MARK: - Layered convenience

    /// Enriches `range` in `filePath` with the best available symbol info:
    /// the LSP index first, then tree-sitter.
    ///
    /// Live LSP is intentionally never consulted here, matching the Rust
    /// reference's `enrich_location` ("live LSP requires async and is
    /// skipped here"): this only enriches a *location* synchronously against
    /// the two persisted layers, from inside a `Store.read` closure a
    /// `LiveOpsCore` op has already opened for its own layer-2/3 lookup.
    ///
    /// - Parameters:
    ///   - db: The database connection to query.
    ///   - filePath: The file containing `range`.
    ///   - range: The range to enrich.
    /// - Returns: The best available symbol (`nil` if neither layer has
    ///   data), and which layer produced it.
    /// - Throws: Rethrows any error the underlying queries throw.
    static func enrichLocation(db: Database, filePath: String, range: LSPRange) throws -> (symbol: LayeredSymbolInfo?, sourceLayer: SourceLayer) {
        if let symbol = try lspSymbolAt(db: db, filePath: filePath, range: range) {
            return (symbol, .lspIndex)
        }
        if let chunk = try tsChunkAt(db: db, filePath: filePath, line: range.start.line) {
            let symbol = LayeredSymbolInfo(
                name: SymbolOps.leafName(ofQualifiedPath: chunk.symbolPath),
                qualifiedPath: chunk.symbolPath,
                kind: chunk.kind,
                detail: nil,
                filePath: filePath,
                range: LSPRange(start: Position(line: chunk.startLine, character: 0), end: Position(line: chunk.endLine, character: 0))
            )
            return (symbol, .treeSitter)
        }
        return (nil, .none)
    }

    // MARK: - Helpers

    /// Parses the `[[startLine,startColumn,endLine,endColumn], ...]` JSON
    /// `lsp_call_edges.from_ranges` stores (see
    /// `LSPIndexWorker.encodeFromRanges(_:)`/`TSCallGraph.writeEdge` for the
    /// writer side of this exact shape) into `LSPRange` values.
    ///
    /// - Parameter json: The raw `from_ranges` column text.
    /// - Returns: The decoded ranges, or an empty array if `json` is missing,
    ///   malformed, or contains a malformed entry.
    private static func parseFromRanges(_ json: String) -> [LSPRange] {
        guard let data = json.data(using: .utf8), let quads = try? JSONDecoder().decode([[Int]].self, from: data) else {
            return []
        }
        return quads.compactMap { quad in
            guard quad.count == 4 else { return nil }
            return LSPRange(start: Position(line: quad[0], character: quad[1]), end: Position(line: quad[2], character: quad[3]))
        }
    }
}

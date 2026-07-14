import Foundation
import GRDB
import SwiftTreeSitter

/// A call expression found while walking a source file's AST, carrying its
/// callee name and byte/line range.
///
/// Port of the Rust `swissarmyhammer-code-context::ts_callgraph::CallSite`
/// (`crates/swissarmyhammer-code-context/src/ts_callgraph.rs`), scoped to
/// `TSCallGraph`'s own use rather than exposed publicly — nothing outside
/// this file needs a call site once it has been resolved into an
/// `lsp_call_edges` row.
struct CallSite: Sendable, Equatable {
    /// The callee's short name, e.g. `"doWork"` for a call written
    /// `Helper.doWork()`.
    let calleeName: String

    /// The call expression's start offset, in UTF-8 bytes, within the file's
    /// content.
    let startByte: Int

    /// The call expression's end offset, in UTF-8 bytes, within the file's
    /// content.
    let endByte: Int

    /// The call expression's zero-based start line.
    let startLine: Int

    /// The call expression's zero-based end line.
    let endLine: Int
}

/// A `ts_chunks` row whose `symbol_path` matched a call site's callee name.
///
/// Port of the Rust reference's `ResolvedCallee`, extended with `kind`,
/// `startLine`, and `endLine` beyond the Rust struct's bare
/// `callee_name`/`file_path`/`symbol_path` — this port's `lsp_symbols` schema
/// requires a non-`NULL` kind and line range for every row (see
/// `TSCallGraph.ensureSymbolID(db:filePath:symbolPath:kind:startLine:endLine:)`),
/// where the Rust reference's synthetic symbol IDs carry no such columns.
struct ResolvedCallee: Sendable, Equatable {
    /// The callee name that was looked up.
    let calleeName: String

    /// The file path of the `ts_chunks` row containing the matching symbol.
    let filePath: String

    /// The full `symbol_path` of the matching `ts_chunks` row.
    let symbolPath: String

    /// The meta-type of the matching `ts_chunks` row, as stored in
    /// `ts_chunks.kind`.
    let kind: String

    /// The zero-based start line of the matching `ts_chunks` row.
    let startLine: Int

    /// The zero-based end line of the matching `ts_chunks` row.
    let endLine: Int
}

/// A tree-sitter heuristic for approximate call-graph edges, used when no LSP
/// call-hierarchy data is available for a file's language.
///
/// Port of `swissarmyhammer-code-context::ts_callgraph`
/// (`crates/swissarmyhammer-code-context/src/ts_callgraph.rs`): walks a
/// parsed AST for call-expression node kinds, extracts each call's callee
/// name, resolves callee names against known `ts_chunks.symbol_path` values,
/// and writes the results into `lsp_call_edges` with `source = 'treesitter'`.
///
/// Two schema differences from the Rust reference shape this port, both
/// already documented at the type level in `SymbolOps`:
/// - `lsp_call_edges.caller_id`/`callee_id` are integer foreign keys into
///   `lsp_symbols.id` here, not the Rust reference's
///   `"{source}:{file}:{qualified_path}"`-encoded text IDs — so, like the
///   Rust reference's `ensure_ts_symbols`, this type creates synthetic
///   `lsp_symbols` rows for the caller and callee of every edge it writes,
///   but must look up or create each row's actual integer ID rather than
///   formatting one.
/// - `lsp_call_edges` has a single `file_path` column, not the Rust
///   reference's separate `caller_file`/`callee_file` — matching the
///   migration's own doc comment, it always holds the caller's file, since
///   that is the file whose deletion should cascade the edge away.
///
/// **Limitations** (ported from the Rust reference's module doc comment):
/// this is a heuristic. It will miss dynamic dispatch, get confused by name
/// collisions across modules, and cannot resolve fully qualified paths
/// precisely. It also assumes a synthetic `lsp_symbols` row can be
/// identified with the `ts_chunks` row it was derived from purely by
/// `(file_path, start_line)`, the same correlation key `SymbolOps` uses to
/// merge tree-sitter and LSP data — see `SymbolOps.lspKindMetaTypes`'s doc
/// comment for how a synthetic row's `SymbolMetaType.rawValue` kind stays
/// meaningful after that merge.
enum TSCallGraph {
    /// The `lsp_call_edges.source` value this heuristic writes, and the
    /// value its replace-on-reindex `DELETE` filters on.
    private static let source = "treesitter"

    /// Node kinds recognized as call expressions, ported verbatim from the
    /// Rust reference's `walk_tree`: `call_expression` (Rust, JS/TS/Go/C/C++),
    /// `method_call_expression` (older Rust grammars with a separate method
    /// call node), and `call` (Python).
    private static let callNodeKinds: Set<String> = ["call_expression", "method_call_expression", "call"]

    /// Node fields tried, in order, to find a call expression's callee
    /// sub-node, ported from the Rust reference's `extract_callee_name`
    /// (`"function"` field first, then `"method"`).
    private static let calleeFieldNames = ["function", "method"]

    /// The source-syntax member-access character separating a receiver from
    /// its member in call text like `self.bar` or `Helper.doWork` — the
    /// Rust reference's `after-last-dot` heuristic. Distinct from
    /// `Chunker.symbolPathSeparator`: that constant is this port's own
    /// `ts_chunks.symbol_path` schema convention, while this one is a
    /// literal character in the *source languages'* call syntax. The two
    /// happen to share the same character today, but are not the same
    /// concept and must not be merged into one constant.
    private static let memberAccessCharacter: Character = "."

    // MARK: - Public entry point

    /// Extracts call sites from `file`'s AST, resolves their callees against
    /// `ts_chunks.symbol_path`, and replaces `file`'s tree-sitter-sourced
    /// `lsp_call_edges` rows with the results.
    ///
    /// Always deletes `file`'s existing `source = 'treesitter'` edges first —
    /// including when zero call sites are found or none resolve — so a
    /// re-indexed file's edges are replaced rather than accumulated, while
    /// any `source = 'lsp'` edges for the same file are left untouched. Must
    /// be called with the same `db` connection `ts_chunks` rows were just
    /// written through, in the same transaction, so callee resolution can see
    /// this file's own just-written chunks alongside every other already
    /// indexed file's chunks.
    ///
    /// - Parameters:
    ///   - db: The write-transaction database connection to read `ts_chunks`
    ///     from and write `lsp_symbols`/`lsp_call_edges` rows through.
    ///   - file: The source file whose call sites to extract and resolve.
    ///   - module: The language module supplying the grammar to parse `file`
    ///     with.
    /// - Throws: Rethrows any error `db`'s statements throw.
    static func writeCallEdges(db: Database, file: SourceFile, module: any LanguageModule.Type) throws {
        try db.execute(
            sql: """
            DELETE FROM \(Schema.LspCallEdges.table) \
            WHERE \(Schema.LspCallEdges.filePath) = ? AND \(Schema.LspCallEdges.source) = ?
            """,
            arguments: [file.relativePath, source]
        )

        guard let (_, root) = Chunker.parseFile(contents: file.contents, module: module) else {
            return
        }

        var callSites: [CallSite] = []
        collectCallSites(node: root, file: file, into: &callSites)
        guard !callSites.isEmpty else {
            return
        }

        let calleeNames = Set(callSites.map(\.calleeName)).sorted()
        let resolved = try resolveCallees(db: db, calleeNames: calleeNames)
        guard !resolved.isEmpty else {
            return
        }

        for site in callSites {
            try writeEdge(db: db, callerFile: file.relativePath, site: site, resolved: resolved)
        }
    }

    // MARK: - AST walk

    /// Recurses `node` and its descendants, appending a `CallSite` for every
    /// node whose kind is in `callNodeKinds` and whose callee can be
    /// extracted.
    ///
    /// Mirrors `Chunker.collectChunks(node:file:module:into:)`: recurses into
    /// every child regardless of whether the current node itself produced a
    /// call site, so nested calls (an argument that is itself a call) are
    /// still found.
    private static func collectCallSites(node: Node, file: SourceFile, into sites: inout [CallSite]) {
        if let kind = node.nodeType, callNodeKinds.contains(kind),
           let calleeName = extractCalleeName(node: node, file: file),
           let (_, startByte, endByte) = Chunker.extractTextAndRange(of: node, in: file.contents)
        {
            sites.append(CallSite(
                calleeName: calleeName,
                startByte: startByte,
                endByte: endByte,
                startLine: Int(node.pointRange.lowerBound.row),
                endLine: Int(node.pointRange.upperBound.row)
            ))
        }

        for childIndex in 0..<node.childCount {
            guard let child = node.child(at: childIndex) else {
                continue
            }
            collectCallSites(node: child, file: file, into: &sites)
        }
    }

    /// Extracts a call expression node's callee name.
    ///
    /// Tries the `"function"` then `"method"` fields first (ported from the
    /// Rust reference); when neither is present, falls back to the node's
    /// first named child. The Rust reference only takes this fallback for
    /// Python's fieldless `call` node kind — this port generalizes it to any
    /// recognized call node, because Swift's `call_expression` (unlike
    /// Rust's) declares no fields at all in its grammar and needs the same
    /// positional fallback to find its callee.
    ///
    /// For a callee whose text contains `memberAccessCharacter` (a method or
    /// field access, e.g. `self.bar` or `Helper.doWork`), returns only the
    /// part after the last occurrence — `nil` if that part is empty (a
    /// malformed trailing-dot call). Otherwise returns the callee's full
    /// text unchanged, e.g. `MyStruct::new` for a Rust scoped call, which
    /// contains no `.`.
    ///
    /// - Parameters:
    ///   - node: The call-expression node to extract a callee name from.
    ///   - file: The source file `node` was parsed from, for text extraction.
    /// - Returns: The extracted callee name, or `nil` if none could be
    ///   recognized.
    private static func extractCalleeName(node: Node, file: SourceFile) -> String? {
        let callee = calleeFieldNames.lazy.compactMap { fieldName in
            node.child(byFieldName: fieldName)
        }.first ?? node.namedChild(at: 0)

        guard let callee,
              let calleeText = Chunker.extractTextAndRange(of: callee, in: file.contents)?.text
        else {
            return nil
        }

        guard let lastSeparatorIndex = calleeText.lastIndex(of: memberAccessCharacter) else {
            return calleeText
        }

        let afterSeparator = String(calleeText[calleeText.index(after: lastSeparatorIndex)...])
        return afterSeparator.isEmpty ? nil : afterSeparator
    }

    // MARK: - Callee resolution

    /// Escapes SQL `LIKE` pattern metacharacters (`%`, `_`) and the escape
    /// character itself (`\`) in `text`, so a literal occurrence of any of
    /// them in a caller-derived value — like a callee name lifted straight
    /// from parsed source code — is matched literally rather than
    /// interpreted as a wildcard when embedded in a `LIKE ? ESCAPE '\'`
    /// pattern.
    ///
    /// The escape character must be escaped first: escaping it after `%`/`_`
    /// would double-escape the backslashes those replacements just inserted,
    /// corrupting the pattern instead of protecting it.
    ///
    /// - Parameter text: The text to escape.
    /// - Returns: `text` with `\`, `%`, and `_` each prefixed by `\`.
    private static func escapeLikePattern(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    /// Looks up `ts_chunks` rows whose `symbol_path` matches any of
    /// `calleeNames`, either exactly or as a
    /// `Chunker.symbolPathSeparator`-qualified suffix.
    ///
    /// Port of the Rust reference's `resolve_callees`, adapted to this
    /// port's `.`-separated `symbol_path` convention (`Chunker
    /// .symbolPathSeparator`) in place of the Rust schema's `::`.
    ///
    /// - Parameters:
    ///   - db: The database connection to query.
    ///   - calleeNames: The distinct callee names to resolve.
    /// - Returns: One `ResolvedCallee` per matching `ts_chunks` row, in no
    ///   particular cross-name order; empty if `calleeNames` is empty or none
    ///   resolve.
    /// - Throws: Rethrows any error the query throws.
    private static func resolveCallees(db: Database, calleeNames: [String]) throws -> [ResolvedCallee] {
        guard !calleeNames.isEmpty else {
            return []
        }

        var resolved: [ResolvedCallee] = []
        for calleeName in calleeNames {
            let suffixPattern = "%\(Chunker.symbolPathSeparator)\(escapeLikePattern(calleeName))"
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT DISTINCT \(Schema.TsChunks.filePath), \(Schema.TsChunks.symbolPath), \(Schema.TsChunks.kind), \
                       \(Schema.TsChunks.startLine), \(Schema.TsChunks.endLine) \
                FROM \(Schema.TsChunks.table) \
                WHERE \(Schema.TsChunks.symbolPath) = ? OR \(Schema.TsChunks.symbolPath) LIKE ? ESCAPE '\\'
                """,
                arguments: [calleeName, suffixPattern]
            )
            resolved.append(contentsOf: rows.map { row in
                ResolvedCallee(
                    calleeName: calleeName,
                    filePath: row[Schema.TsChunks.filePath],
                    symbolPath: row[Schema.TsChunks.symbolPath],
                    kind: row[Schema.TsChunks.kind],
                    startLine: row[Schema.TsChunks.startLine],
                    endLine: row[Schema.TsChunks.endLine]
                )
            })
        }
        return resolved
    }

    // MARK: - Edge writing

    /// Resolves one call site to its enclosing caller chunk and the first
    /// matching, non-self resolved callee, then writes the edge — or does
    /// nothing if the site has no enclosing chunk or no matching callee.
    ///
    /// Port of the Rust reference's `build_edge_for_site`: iterates
    /// `resolved` filtered to `site.calleeName`, skipping a candidate whose
    /// `(filePath, symbolPath)` matches the caller's own (a recursive
    /// self-call) and taking the first remaining match, so a call site with
    /// only a self-match produces no edge at all rather than falling through
    /// to a different candidate.
    ///
    /// - Parameters:
    ///   - db: The database connection to query and write through.
    ///   - callerFile: The file `site` was found in.
    ///   - site: The call site to resolve.
    ///   - resolved: Every resolved callee for the file's call sites,
    ///     pre-filtered by `writeCallEdges(db:file:module:)` to non-empty.
    /// - Throws: Rethrows any error the lookup or write queries throw.
    private static func writeEdge(db: Database, callerFile: String, site: CallSite, resolved: [ResolvedCallee]) throws {
        guard let caller = try enclosingChunk(db: db, filePath: callerFile, startByte: site.startByte, endByte: site.endByte) else {
            return
        }

        for candidate in resolved where candidate.calleeName == site.calleeName {
            if candidate.filePath == callerFile, candidate.symbolPath == caller.symbolPath {
                continue
            }

            let callerID = try ensureSymbolID(
                db: db,
                filePath: callerFile,
                symbolPath: caller.symbolPath,
                kind: caller.kind,
                startLine: caller.startLine,
                endLine: caller.endLine
            )
            let calleeID = try ensureSymbolID(
                db: db,
                filePath: candidate.filePath,
                symbolPath: candidate.symbolPath,
                kind: candidate.kind,
                startLine: candidate.startLine,
                endLine: candidate.endLine
            )

            // "[[startLine,0,endLine,0]]": the JSON array-of-arrays shape
            // `lsp_call_edges.from_ranges` stores, ported from the Rust
            // reference's `from_ranges` formatting in `build_edge_for_site`.
            // The two `0`s are start/end columns, which tree-sitter chunks
            // don't carry (see `SymbolMatch.startColumn`).
            let fromRanges = "[[\(site.startLine),0,\(site.endLine),0]]"
            try db.execute(
                sql: """
                INSERT INTO \(Schema.LspCallEdges.table)
                    (\(Schema.LspCallEdges.callerId), \(Schema.LspCallEdges.calleeId), \(Schema.LspCallEdges.filePath), \
                     \(Schema.LspCallEdges.fromRanges), \(Schema.LspCallEdges.source))
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [callerID, calleeID, callerFile, fromRanges, source]
            )
            return
        }
    }

    /// Finds the smallest `ts_chunks` row in `filePath` whose byte range
    /// encloses `[startByte, endByte]`, or `nil` if none does.
    ///
    /// Port of the Rust reference's `caller_stmt` query in
    /// `map_call_sites_to_edges`: orders by ascending chunk width so a call
    /// site nested inside both a method and its enclosing type resolves to
    /// the method, the tighter enclosing chunk.
    ///
    /// - Parameters:
    ///   - db: The database connection to query.
    ///   - filePath: The file to search `ts_chunks` within.
    ///   - startByte: The call site's start byte offset.
    ///   - endByte: The call site's end byte offset.
    /// - Returns: The enclosing chunk's `symbol_path`, `kind`, `start_line`,
    ///   and `end_line`, or `nil` if no chunk encloses the range.
    /// - Throws: Rethrows any error the query throws.
    private static func enclosingChunk(
        db: Database,
        filePath: String,
        startByte: Int,
        endByte: Int
    ) throws -> (symbolPath: String, kind: String, startLine: Int, endLine: Int)? {
        try Row.fetchOne(
            db,
            sql: """
            SELECT \(Schema.TsChunks.symbolPath), \(Schema.TsChunks.kind), \(Schema.TsChunks.startLine), \(Schema.TsChunks.endLine) \
            FROM \(Schema.TsChunks.table) \
            WHERE \(Schema.TsChunks.filePath) = ? AND \(Schema.TsChunks.startByte) <= ? AND \(Schema.TsChunks.endByte) >= ? \
            ORDER BY (\(Schema.TsChunks.endByte) - \(Schema.TsChunks.startByte)) ASC \
            LIMIT 1
            """,
            arguments: [filePath, startByte, endByte]
        ).map { row in
            (
                symbolPath: row[Schema.TsChunks.symbolPath],
                kind: row[Schema.TsChunks.kind],
                startLine: row[Schema.TsChunks.startLine],
                endLine: row[Schema.TsChunks.endLine]
            )
        }
    }

    /// Finds or creates the `lsp_symbols` row identifying the symbol at
    /// `(filePath, startLine)`, keeping its `name`/`kind`/line range in sync
    /// with `symbolPath`/`kind`/`startLine`/`endLine` on every call.
    ///
    /// `(filePath, startLine)` is the same correlation key `SymbolOps` uses
    /// to merge a `ts_chunks` row with an `lsp_symbols` row (see
    /// `SymbolOps`'s `SymbolLocationKey`), so a synthetic row created here
    /// merges with its originating chunk exactly as a real LSP-reported
    /// symbol at that location would. `symbolPath`'s leaf segment (via
    /// `SymbolOps.leafName(ofQualifiedPath:)`) is stored as `name` rather
    /// than the full qualified path, matching what real LSP data would
    /// report and avoiding corrupting `SymbolOps`'s merged `name` field —
    /// mirrors the Rust reference's `ensure_ts_symbols`, which derives the
    /// same leaf name from `symbol_path` for its synthetic `lsp_symbols`
    /// rows.
    ///
    /// Existing rows are updated rather than left stale so a re-indexed
    /// file's renamed or re-kinded symbol doesn't leave a synthetic row
    /// pointing at its old name.
    ///
    /// - Parameters:
    ///   - db: The database connection to query and write through.
    ///   - filePath: The symbol's file path.
    ///   - symbolPath: The symbol's full qualified `ts_chunks.symbol_path`.
    ///   - kind: The symbol's meta-type, as stored in `ts_chunks.kind`.
    ///   - startLine: The symbol's zero-based start line.
    ///   - endLine: The symbol's zero-based end line.
    /// - Returns: The `lsp_symbols.id` of the found-or-created row.
    /// - Throws: Rethrows any error the lookup or write queries throw.
    private static func ensureSymbolID(
        db: Database,
        filePath: String,
        symbolPath: String,
        kind: String,
        startLine: Int,
        endLine: Int
    ) throws -> Int64 {
        let name = SymbolOps.leafName(ofQualifiedPath: symbolPath)

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
                SET \(Schema.LspSymbols.name) = ?, \(Schema.LspSymbols.kind) = ?, \(Schema.LspSymbols.endLine) = ? \
                WHERE \(Schema.LspSymbols.id) = ?
                """,
                arguments: [name, kind, endLine, existingID]
            )
            return existingID
        }

        try db.execute(
            sql: """
            INSERT INTO \(Schema.LspSymbols.table)
                (\(Schema.LspSymbols.name), \(Schema.LspSymbols.kind), \(Schema.LspSymbols.filePath), \
                 \(Schema.LspSymbols.startLine), \(Schema.LspSymbols.startColumn), \
                 \(Schema.LspSymbols.endLine), \(Schema.LspSymbols.endColumn))
            VALUES (?, ?, ?, ?, 0, ?, 0)
            """,
            arguments: [name, kind, filePath, startLine, endLine]
        )
        return db.lastInsertedRowID
    }
}

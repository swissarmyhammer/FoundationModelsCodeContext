import Foundation
import GRDB

/// Which index produced a symbol candidate — `ts_chunks` alone, `lsp_symbols`
/// alone, or both merged at the same `(file_path, start_line)` location.
public enum SymbolSource: String, Codable, Sendable, Equatable {
    /// The candidate came only from `ts_chunks`.
    case treeSitter = "treesitter"

    /// The candidate came only from `lsp_symbols`, with no `ts_chunks` row
    /// at the same location.
    case lsp

    /// A `ts_chunks` row and an `lsp_symbols` row shared the same
    /// `(file_path, start_line)` and were merged into one candidate.
    case merged
}

/// Which resolution tier produced a `getSymbol` match.
///
/// `SymbolOps.getSymbol(store:query:maxResults:)` tries these in order and
/// returns the results of the first tier that matches anything at all —
/// tiers are never blended, so every symbol in one `GetSymbolResult` shares
/// the same tier.
public enum SymbolMatchTier: String, Codable, Sendable, Equatable, CaseIterable {
    /// `symbol_path` equals the query exactly.
    case exact

    /// `symbol_path` ends with `.<query>` (or equals it outright).
    case suffix

    /// The lowercased `symbol_path` contains the lowercased query.
    case caseInsensitive

    /// `query`'s characters appear, in order, as a subsequence of
    /// `symbol_path`.
    case fuzzy
}

/// One symbol match returned by `SymbolOps.getSymbol(store:query:maxResults:)`.
public struct SymbolMatch: Codable, Sendable, Equatable {
    /// The symbol's short name — its qualified path's leaf segment.
    public let name: String

    /// The symbol's fully qualified path, e.g. `MyStruct.new`.
    public let qualifiedPath: String

    /// The file containing the symbol, relative to the workspace root.
    public let filePath: String

    /// The symbol's zero-based start line.
    public let startLine: Int

    /// The symbol's zero-based end line.
    public let endLine: Int

    /// The symbol's start column — precise when `source` includes LSP data,
    /// `0` for a tree-sitter-only match (tree-sitter chunks carry no column
    /// information).
    public let startColumn: Int

    /// The symbol's end column. See `startColumn`.
    public let endColumn: Int

    /// The full source text of the chunk containing the symbol — empty for
    /// an `lsp`-only match, which has no associated `ts_chunks` text.
    public let text: String

    /// Which tier produced this match.
    public let matchTier: SymbolMatchTier

    /// The match's score — higher is better. Comparable only within the
    /// same `matchTier`: each tier uses its own scale.
    public let score: Int

    /// The symbol's meta-type.
    public let kind: SymbolMetaType

    /// Extra detail about the symbol (e.g. a function signature), if known
    /// from LSP.
    public let detail: String?

    /// Which index produced this match.
    public let source: SymbolSource

    /// Creates a symbol match.
    ///
    /// - Parameters:
    ///   - name: The symbol's short name.
    ///   - qualifiedPath: The symbol's fully qualified path.
    ///   - filePath: The file containing the symbol.
    ///   - startLine: The symbol's zero-based start line.
    ///   - endLine: The symbol's zero-based end line.
    ///   - startColumn: The symbol's start column.
    ///   - endColumn: The symbol's end column.
    ///   - text: The full source text of the chunk containing the symbol.
    ///   - matchTier: Which tier produced this match.
    ///   - score: The match's score.
    ///   - kind: The symbol's meta-type.
    ///   - detail: Extra detail about the symbol, if known from LSP.
    ///   - source: Which index produced this match.
    public init(
        name: String,
        qualifiedPath: String,
        filePath: String,
        startLine: Int,
        endLine: Int,
        startColumn: Int,
        endColumn: Int,
        text: String,
        matchTier: SymbolMatchTier,
        score: Int,
        kind: SymbolMetaType,
        detail: String?,
        source: SymbolSource
    ) {
        self.name = name
        self.qualifiedPath = qualifiedPath
        self.filePath = filePath
        self.startLine = startLine
        self.endLine = endLine
        self.startColumn = startColumn
        self.endColumn = endColumn
        self.text = text
        self.matchTier = matchTier
        self.score = score
        self.kind = kind
        self.detail = detail
        self.source = source
    }
}

/// The result of a `SymbolOps.getSymbol(store:query:maxResults:)` call.
public struct GetSymbolResult: Codable, Sendable, Equatable {
    /// The original query string.
    public let query: String

    /// Matched symbols, all from the same `SymbolMatchTier`, ordered by
    /// descending score.
    public let symbols: [SymbolMatch]

    /// Creates a `getSymbol` result.
    ///
    /// - Parameters:
    ///   - query: The original query string.
    ///   - symbols: Matched symbols, ordered by descending score.
    public init(query: String, symbols: [SymbolMatch]) {
        self.query = query
        self.symbols = symbols
    }
}

/// One fuzzy-matched symbol returned by
/// `SymbolOps.searchSymbol(store:query:kind:maxResults:)`.
public struct SearchSymbolMatch: Codable, Sendable, Equatable {
    /// The symbol's short name.
    public let name: String

    /// The symbol's fully qualified path.
    public let qualifiedPath: String

    /// The symbol's meta-type.
    public let kind: SymbolMetaType

    /// The file containing the symbol.
    public let filePath: String

    /// The symbol's zero-based start line.
    public let startLine: Int

    /// The fuzzy match score — higher is better.
    public let score: Int

    /// Which index produced this match.
    public let source: SymbolSource

    /// Creates a search-symbol match.
    ///
    /// - Parameters:
    ///   - name: The symbol's short name.
    ///   - qualifiedPath: The symbol's fully qualified path.
    ///   - kind: The symbol's meta-type.
    ///   - filePath: The file containing the symbol.
    ///   - startLine: The symbol's zero-based start line.
    ///   - score: The fuzzy match score.
    ///   - source: Which index produced this match.
    public init(
        name: String,
        qualifiedPath: String,
        kind: SymbolMetaType,
        filePath: String,
        startLine: Int,
        score: Int,
        source: SymbolSource
    ) {
        self.name = name
        self.qualifiedPath = qualifiedPath
        self.kind = kind
        self.filePath = filePath
        self.startLine = startLine
        self.score = score
        self.source = source
    }
}

/// One symbol's definition location, as returned by
/// `SymbolOps.listSymbols(store:file:)`.
public struct SymbolLocation: Codable, Sendable, Equatable {
    /// The symbol's short name.
    public let name: String

    /// The symbol's fully qualified path.
    public let qualifiedPath: String

    /// The symbol's meta-type.
    public let kind: SymbolMetaType

    /// The file containing the symbol.
    public let filePath: String

    /// The symbol's zero-based start line.
    public let startLine: Int

    /// The symbol's start column. See `SymbolMatch.startColumn`.
    public let startColumn: Int

    /// The symbol's zero-based end line.
    public let endLine: Int

    /// The symbol's end column.
    public let endColumn: Int

    /// Extra detail about the symbol, if known from LSP.
    public let detail: String?

    /// Which index produced this location.
    public let source: SymbolSource

    /// Creates a symbol location.
    ///
    /// - Parameters:
    ///   - name: The symbol's short name.
    ///   - qualifiedPath: The symbol's fully qualified path.
    ///   - kind: The symbol's meta-type.
    ///   - filePath: The file containing the symbol.
    ///   - startLine: The symbol's zero-based start line.
    ///   - startColumn: The symbol's start column.
    ///   - endLine: The symbol's zero-based end line.
    ///   - endColumn: The symbol's end column.
    ///   - detail: Extra detail about the symbol, if known from LSP.
    ///   - source: Which index produced this location.
    public init(
        name: String,
        qualifiedPath: String,
        kind: SymbolMetaType,
        filePath: String,
        startLine: Int,
        startColumn: Int,
        endLine: Int,
        endColumn: Int,
        detail: String?,
        source: SymbolSource
    ) {
        self.name = name
        self.qualifiedPath = qualifiedPath
        self.kind = kind
        self.filePath = filePath
        self.startLine = startLine
        self.startColumn = startColumn
        self.endLine = endLine
        self.endColumn = endColumn
        self.detail = detail
        self.source = source
    }
}

/// Symbol lookup, fuzzy search, and per-file listing over a workspace's
/// index.
///
/// Port of the Rust `swissarmyhammer-code-context::ops::{get_symbol,
/// search_symbol, list_symbol}` modules
/// (`crates/swissarmyhammer-code-context/src/ops/{get_symbol,search_symbol,list_symbol}.rs`),
/// unified around one shared candidate loader (`loadCandidateRows`) since
/// all three ops merge `ts_chunks` and `lsp_symbols` by `(file_path,
/// start_line)` the same way — the Rust reference instead duplicates that
/// merge in each of its three files.
///
/// Two schema differences from the Rust reference shape this port:
/// - `ts_chunks.kind` is a Swift-only addition (`SymbolMetaType`), so a
///   tree-sitter-only candidate always has a known meta-type here, where
///   the Rust reference's TS-only rows have no kind at all.
/// - `lsp_symbols.id` here is an autoincrementing integer, not the Rust
///   reference's `"{source}:{file}:{qualified_path}"`-encoded string, so
///   there is no way to recover a qualified path from an `lsp_symbols` row
///   alone. A merged candidate therefore always keeps its qualified path
///   from `ts_chunks` (only `name`/`kind`/`detail`/columns are enriched
///   from LSP on merge); an LSP-only candidate (no `ts_chunks` row at the
///   same location) falls back to its bare `name` as its qualified path.
public enum SymbolOps {
    /// The score assigned to every `SymbolMatchTier.exact` match.
    private static let exactScore = 1000

    /// The score `SymbolMatchTier.suffix` matches start from, before
    /// `shorterPathBonus(qualifiedPath:)` is added.
    private static let suffixBaseScore = 900

    /// The score `SymbolMatchTier.caseInsensitive` matches start from,
    /// before `shorterPathBonus(qualifiedPath:)` is added.
    private static let caseInsensitiveBaseScore = 800

    /// The upper bound `shorterPathBonus(qualifiedPath:)` subtracts a
    /// qualified path's length from.
    private static let shorterPathBonusCeiling = 100

    /// LSP kind-name strings (as stored in `lsp_symbols.kind`) known to map
    /// onto a `SymbolMetaType` other than `.other`.
    ///
    /// Shared by candidate enrichment (`loadCandidateRows`) and
    /// `searchSymbol`'s meta-type filter, so there is exactly one mapping
    /// from an LSP kind name to the four-bucket `SymbolMetaType` scheme.
    ///
    /// Also covers `TSCallGraph`'s synthetic `lsp_symbols` rows: those store
    /// a `ts_chunks.kind` value (a `SymbolMetaType.rawValue` — `"function"`,
    /// `"method"`, `"type"`, or `"other"`) directly as `kind` rather than a
    /// real LSP kind name, so this table's `"type"`/`"other"` entries exist
    /// purely for that case — no real language server reports either
    /// literal string as a `SymbolKind` name, so they can't collide with a
    /// genuine LSP-sourced row.
    private static let lspKindMetaTypes: [String: SymbolMetaType] = [
        "function": .function,
        "method": .method,
        "constructor": .method,
        "class": .type,
        "struct": .type,
        "interface": .type,
        "enum": .type,
        "namespace": .type,
        "module": .type,
        "type": .type,
        "other": .other,
    ]

    // MARK: - getSymbol

    /// Looks up symbols by name using four-tier matching: exact, suffix,
    /// case-insensitive substring, then fuzzy subsequence — trying each in
    /// order and returning the first tier's results, so a query is never
    /// resolved by more than one tier at once.
    ///
    /// - Parameters:
    ///   - store: The workspace's index store to search.
    ///   - query: The symbol name or qualified path to look up.
    ///   - maxResults: The maximum number of matches to return within
    ///     whichever tier resolves the query. Defaults to 50.
    /// - Returns: The first non-empty tier's matches, capped at
    ///   `maxResults`, or an empty result if no tier matches.
    /// - Throws: Rethrows `Store`'s storage errors.
    public static func getSymbol(store: Store, query: String, maxResults: Int = 50) async throws -> GetSymbolResult {
        let candidates = try await loadCandidateRows(store: store, filePath: nil)

        if let result = matchExact(candidates: candidates, query: query, maxResults: maxResults) {
            return result
        }
        if let result = matchSuffix(candidates: candidates, query: query, maxResults: maxResults) {
            return result
        }
        if let result = matchCaseInsensitive(candidates: candidates, query: query, maxResults: maxResults) {
            return result
        }
        if let result = matchFuzzy(candidates: candidates, query: query, maxResults: maxResults) {
            return result
        }
        return GetSymbolResult(query: query, symbols: [])
    }

    /// Tier 1: exact `qualifiedPath` match.
    private static func matchExact(candidates: [SymbolCandidateRow], query: String, maxResults: Int) -> GetSymbolResult? {
        let matches = candidates.filter { $0.qualifiedPath == query }
        guard !matches.isEmpty else {
            return nil
        }
        let scoredRows = matches.map { (candidate: $0, score: exactScore) }
        return makeResult(query: query, tier: .exact, scoredRows: scoredRows, maxResults: maxResults)
    }

    /// Tier 2: suffix match — `foo` matches any `<container>.foo` (or `foo`
    /// itself).
    private static func matchSuffix(candidates: [SymbolCandidateRow], query: String, maxResults: Int) -> GetSymbolResult? {
        let suffixPattern = "\(Chunker.symbolPathSeparator)\(query)"
        let scoredRows = candidates
            .filter { $0.qualifiedPath.hasSuffix(suffixPattern) || $0.qualifiedPath == query }
            .map { (candidate: $0, score: suffixBaseScore + shorterPathBonus(qualifiedPath: $0.qualifiedPath)) }
            .sorted { $0.score > $1.score }
        guard !scoredRows.isEmpty else {
            return nil
        }
        return makeResult(query: query, tier: .suffix, scoredRows: scoredRows, maxResults: maxResults)
    }

    /// Tier 3: case-insensitive substring match.
    private static func matchCaseInsensitive(candidates: [SymbolCandidateRow], query: String, maxResults: Int) -> GetSymbolResult? {
        let queryLowercased = query.lowercased()
        let scoredRows = candidates
            .filter { $0.qualifiedPath.lowercased().contains(queryLowercased) }
            .map { (candidate: $0, score: caseInsensitiveBaseScore + shorterPathBonus(qualifiedPath: $0.qualifiedPath)) }
            .sorted { $0.score > $1.score }
        guard !scoredRows.isEmpty else {
            return nil
        }
        return makeResult(query: query, tier: .caseInsensitive, scoredRows: scoredRows, maxResults: maxResults)
    }

    /// Tier 4: subsequence fuzzy match, ranked by fuzzy score.
    private static func matchFuzzy(candidates: [SymbolCandidateRow], query: String, maxResults: Int) -> GetSymbolResult? {
        let scoredRows = candidates
            .compactMap { candidate -> (candidate: SymbolCandidateRow, score: Int)? in
                guard let score = fuzzyScore(query: query, target: candidate.qualifiedPath) else {
                    return nil
                }
                return (candidate, score)
            }
            .sorted { $0.score > $1.score }
        guard !scoredRows.isEmpty else {
            return nil
        }
        return makeResult(query: query, tier: .fuzzy, scoredRows: scoredRows, maxResults: maxResults)
    }

    /// Maps pre-scored, pre-sorted candidate rows to a `GetSymbolResult`,
    /// truncating to `maxResults`. Shared by all four tiers so scoring and
    /// sorting are each tier's own concern, while assembling the public
    /// result shape happens in exactly one place.
    private static func makeResult(
        query: String,
        tier: SymbolMatchTier,
        scoredRows: [(candidate: SymbolCandidateRow, score: Int)],
        maxResults: Int
    ) -> GetSymbolResult {
        let symbols = scoredRows.prefix(maxResults).map { candidate, score in
            SymbolMatch(
                name: candidate.name,
                qualifiedPath: candidate.qualifiedPath,
                filePath: candidate.filePath,
                startLine: candidate.startLine,
                endLine: candidate.endLine,
                startColumn: candidate.startColumn,
                endColumn: candidate.endColumn,
                text: candidate.text,
                matchTier: tier,
                score: score,
                kind: candidate.kind,
                detail: candidate.detail,
                source: candidate.source
            )
        }
        return GetSymbolResult(query: query, symbols: Array(symbols))
    }

    /// A small bonus that prefers a shorter (more specific) qualified path
    /// over a longer one at the same tier.
    private static func shorterPathBonus(qualifiedPath: String) -> Int {
        max(0, shorterPathBonusCeiling - qualifiedPath.count)
    }

    // MARK: - searchSymbol

    /// Fuzzy-searches every indexed symbol, with an optional meta-type
    /// filter.
    ///
    /// Matches `query` as a subsequence against each candidate's qualified
    /// path, falling back to its short name when the qualified path doesn't
    /// match — mirroring the Rust reference's "qualified path first, then
    /// name" fallback.
    ///
    /// - Parameters:
    ///   - store: The workspace's index store to search.
    ///   - query: The fuzzy query to match.
    ///   - kind: When non-`nil`, only candidates of this meta-type are
    ///     considered. Defaults to `nil` (no filter).
    ///   - maxResults: The maximum number of matches to return. Defaults to
    ///     50.
    /// - Returns: Matches ordered by descending fuzzy score, capped at
    ///   `maxResults`.
    /// - Throws: Rethrows `Store`'s storage errors.
    public static func searchSymbol(
        store: Store,
        query: String,
        kind: SymbolMetaType? = nil,
        maxResults: Int = 50
    ) async throws -> [SearchSymbolMatch] {
        let candidates = try await loadCandidateRows(store: store, filePath: nil)
        let filtered = kind.map { filterKind in candidates.filter { $0.kind == filterKind } } ?? candidates

        let scoredRows = filtered
            .compactMap { candidate -> (candidate: SymbolCandidateRow, score: Int)? in
                guard let score = fuzzyScore(query: query, target: candidate.qualifiedPath)
                    ?? fuzzyScore(query: query, target: candidate.name)
                else {
                    return nil
                }
                return (candidate, score)
            }
            .sorted { $0.score > $1.score }

        return scoredRows.prefix(maxResults).map { candidate, score in
            SearchSymbolMatch(
                name: candidate.name,
                qualifiedPath: candidate.qualifiedPath,
                kind: candidate.kind,
                filePath: candidate.filePath,
                startLine: candidate.startLine,
                score: score,
                source: candidate.source
            )
        }
    }

    // MARK: - listSymbols

    /// Lists every symbol defined in `file`, sorted by start line.
    ///
    /// - Parameters:
    ///   - store: The workspace's index store to search.
    ///   - file: The file's path, relative to the workspace root, exactly
    ///     as stored in `indexed_files.file_path`.
    /// - Returns: `file`'s symbols in source order, or an empty array if the
    ///   file has none (or doesn't exist in the index).
    /// - Throws: Rethrows `Store`'s storage errors.
    public static func listSymbols(store: Store, file: String) async throws -> [SymbolLocation] {
        let candidates = try await loadCandidateRows(store: store, filePath: file)
        return candidates
            .sorted { $0.startLine < $1.startLine }
            .map { candidate in
                SymbolLocation(
                    name: candidate.name,
                    qualifiedPath: candidate.qualifiedPath,
                    kind: candidate.kind,
                    filePath: candidate.filePath,
                    startLine: candidate.startLine,
                    startColumn: candidate.startColumn,
                    endLine: candidate.endLine,
                    endColumn: candidate.endColumn,
                    detail: candidate.detail,
                    source: candidate.source
                )
            }
    }

    // MARK: - Fuzzy subsequence scoring

    /// Computes a subsequence fuzzy-match score for `query` against
    /// `target`, or `nil` if `query`'s characters do not all appear in
    /// `target`, in order (case-insensitive).
    ///
    /// A lightweight, dependency-free stand-in for the Rust reference's
    /// `fuzzy_matcher::skim::SkimMatcherV2`: rewards each matched
    /// character, a bonus for contiguous runs of matched characters, and a
    /// bonus for matches landing at a "word boundary" (the start of
    /// `target`, or immediately after a non-alphanumeric separator) — the
    /// same shape of signal skim's scorer produces, without an external
    /// fuzzy-matching dependency.
    ///
    /// - Parameters:
    ///   - query: The subsequence to search for.
    ///   - target: The string to search within.
    /// - Returns: A score where higher is a better match, or `nil` if
    ///   `query` is not an in-order subsequence of `target`. An empty
    ///   `query` always scores `0`.
    private static func fuzzyScore(query: String, target: String) -> Int? {
        guard !query.isEmpty else {
            return 0
        }
        let queryCharacters = Array(query.lowercased())
        let targetCharacters = Array(target.lowercased())

        var score = 0
        var queryIndex = 0
        var previousMatchedIndex: Int?

        for targetIndex in targetCharacters.indices {
            guard queryIndex < queryCharacters.count, targetCharacters[targetIndex] == queryCharacters[queryIndex] else {
                continue
            }

            score += 10
            if let previousMatchedIndex, previousMatchedIndex == targetIndex - 1 {
                score += 15
            }
            let previousCharacterIsSeparator = targetIndex == 0
                || !(targetCharacters[targetIndex - 1].isLetter || targetCharacters[targetIndex - 1].isNumber)
            if previousCharacterIsSeparator {
                score += 10
            }

            previousMatchedIndex = targetIndex
            queryIndex += 1
        }

        return queryIndex == queryCharacters.count ? score : nil
    }

    // MARK: - Candidate loading (shared by getSymbol/searchSymbol/listSymbols)

    /// One row merged from `ts_chunks` and/or `lsp_symbols` at the same
    /// `(file_path, start_line)` location — the common candidate shape that
    /// `getSymbol`, `searchSymbol`, and `listSymbols` all match, filter, or
    /// list against.
    private struct SymbolCandidateRow: Sendable {
        var name: String
        var qualifiedPath: String
        var filePath: String
        var startLine: Int
        var endLine: Int
        var startColumn: Int
        var endColumn: Int
        var text: String
        var kind: SymbolMetaType
        var detail: String?
        var source: SymbolSource
    }

    /// A row loaded from `lsp_symbols`, before merging into a
    /// `SymbolCandidateRow`.
    private struct LspSymbolRow: Sendable {
        let name: String
        let kindName: String
        let filePath: String
        let startLine: Int
        let startColumn: Int
        let endLine: Int
        let endColumn: Int
        let detail: String?
    }

    /// The `(file_path, start_line)` key candidates from both tables are
    /// merged by.
    private struct SymbolLocationKey: Hashable {
        let filePath: String
        let startLine: Int
    }

    /// Loads and merges symbol candidates from `ts_chunks` and
    /// `lsp_symbols`, optionally scoped to one file.
    ///
    /// Rows from both tables are keyed by `(file_path, start_line)`: a
    /// `ts_chunks` row seeds the merged candidate (it carries source text
    /// and an already-qualified `symbol_path`); an `lsp_symbols` row at the
    /// same key then enriches it with LSP's `name`, resolved meta-type,
    /// columns, and `detail` — winning over the tree-sitter-derived values,
    /// matching the Rust reference's "LSP metadata wins on merge". An
    /// `lsp_symbols` row with no `ts_chunks` row at its key becomes its own
    /// `lsp`-sourced candidate, with empty `text` and its bare `name` as
    /// its qualified path (see this file's type-level doc comment for why).
    ///
    /// - Parameters:
    ///   - store: The workspace's index store to read from.
    ///   - filePath: When non-`nil`, only candidates in this file are
    ///     loaded.
    /// - Returns: Every merged candidate, in no particular order — callers
    ///   sort or tier-match as needed.
    private static func loadCandidateRows(store: Store, filePath: String?) async throws -> [SymbolCandidateRow] {
        try await store.read { db in
            var merged: [SymbolLocationKey: SymbolCandidateRow] = [:]

            for row in try fetchTsRows(db: db, filePath: filePath) {
                merged[SymbolLocationKey(filePath: row.filePath, startLine: row.startLine)] = row
            }

            for lspRow in try fetchLspRows(db: db, filePath: filePath) {
                let key = SymbolLocationKey(filePath: lspRow.filePath, startLine: lspRow.startLine)
                let metaType = symbolMetaType(forLspKindName: lspRow.kindName)
                if var existing = merged[key] {
                    existing.name = lspRow.name
                    existing.startColumn = lspRow.startColumn
                    existing.endColumn = lspRow.endColumn
                    existing.kind = metaType
                    existing.detail = lspRow.detail
                    existing.source = .merged
                    merged[key] = existing
                } else {
                    merged[key] = SymbolCandidateRow(
                        name: lspRow.name,
                        qualifiedPath: lspRow.name,
                        filePath: lspRow.filePath,
                        startLine: lspRow.startLine,
                        endLine: lspRow.endLine,
                        startColumn: lspRow.startColumn,
                        endColumn: lspRow.endColumn,
                        text: "",
                        kind: metaType,
                        detail: lspRow.detail,
                        source: .lsp
                    )
                }
            }

            return Array(merged.values)
        }
    }

    /// Loads `ts_chunks` rows (optionally scoped to `filePath`) as
    /// `SymbolCandidateRow`s sourced `.treeSitter`.
    private static func fetchTsRows(db: Database, filePath: String?) throws -> [SymbolCandidateRow] {
        let (whereClause, arguments) = fileFilterClause(column: Schema.TsChunks.filePath, filePath: filePath)
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT \(Schema.TsChunks.filePath), \(Schema.TsChunks.startLine), \(Schema.TsChunks.endLine), \
                   \(Schema.TsChunks.text), \(Schema.TsChunks.symbolPath), \(Schema.TsChunks.kind) \
            FROM \(Schema.TsChunks.table) \(whereClause)
            """,
            arguments: arguments
        )
        return rows.map { row in
            let qualifiedPath: String = row[Schema.TsChunks.symbolPath]
            let kindText: String = row[Schema.TsChunks.kind]
            return SymbolCandidateRow(
                name: leafName(ofQualifiedPath: qualifiedPath),
                qualifiedPath: qualifiedPath,
                filePath: row[Schema.TsChunks.filePath],
                startLine: row[Schema.TsChunks.startLine],
                endLine: row[Schema.TsChunks.endLine],
                startColumn: 0,
                endColumn: 0,
                text: row[Schema.TsChunks.text],
                kind: SymbolMetaType(rawValue: kindText) ?? .other,
                detail: nil,
                source: .treeSitter
            )
        }
    }

    /// Loads `lsp_symbols` rows (optionally scoped to `filePath`).
    private static func fetchLspRows(db: Database, filePath: String?) throws -> [LspSymbolRow] {
        let (whereClause, arguments) = fileFilterClause(column: Schema.LspSymbols.filePath, filePath: filePath)
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT \(Schema.LspSymbols.name), \(Schema.LspSymbols.kind), \(Schema.LspSymbols.filePath), \
                   \(Schema.LspSymbols.startLine), \(Schema.LspSymbols.startColumn), \
                   \(Schema.LspSymbols.endLine), \(Schema.LspSymbols.endColumn), \(Schema.LspSymbols.detail) \
            FROM \(Schema.LspSymbols.table) \(whereClause)
            """,
            arguments: arguments
        )
        return rows.map { row in
            LspSymbolRow(
                name: row[Schema.LspSymbols.name],
                kindName: row[Schema.LspSymbols.kind],
                filePath: row[Schema.LspSymbols.filePath],
                startLine: row[Schema.LspSymbols.startLine],
                startColumn: row[Schema.LspSymbols.startColumn],
                endLine: row[Schema.LspSymbols.endLine],
                endColumn: row[Schema.LspSymbols.endColumn],
                detail: row[Schema.LspSymbols.detail]
            )
        }
    }

    /// Builds an optional `WHERE <column> = ?` clause and its bound
    /// argument for `filePath`, shared by `fetchTsRows` and `fetchLspRows`
    /// so the two don't each reimplement the same conditional-filter
    /// construction.
    private static func fileFilterClause(column: String, filePath: String?) -> (whereClause: String, arguments: StatementArguments) {
        guard let filePath else {
            return ("", [])
        }
        return ("WHERE \(column) = ?", [filePath])
    }

    /// Maps an `lsp_symbols.kind` text value onto a `SymbolMetaType`,
    /// falling back to `.other` for any kind name not in
    /// `lspKindMetaTypes`.
    private static func symbolMetaType(forLspKindName kindName: String) -> SymbolMetaType {
        lspKindMetaTypes[kindName.lowercased()] ?? .other
    }

    /// Extracts the leaf segment of a qualified path (e.g. `Struct.method`
    /// -> `method`), split on `Chunker.symbolPathSeparator`.
    ///
    /// Not `private`: `TSCallGraph` reuses this same leaf-name extraction to
    /// derive the `name` column of the synthetic `lsp_symbols` rows it
    /// creates for tree-sitter-only call-graph edges, so the two don't each
    /// carry their own copy of the qualified-path-to-leaf-name logic.
    static func leafName(ofQualifiedPath qualifiedPath: String) -> String {
        qualifiedPath.components(separatedBy: Chunker.symbolPathSeparator).last ?? qualifiedPath
    }
}

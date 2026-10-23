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
/// the same tier. `near` is the one tier that is never in `symbols`: it marks
/// the `candidates` of a query that no other tier matches.
public enum SymbolMatchTier: String, Codable, Sendable, Equatable, CaseIterable {
    /// `symbol_path` equals the query exactly.
    case exact

    /// `symbol_path` ends with `.<query>` (or equals it outright).
    case suffix

    /// A `Class.member` query whose class does not define `member`: the match
    /// is the `member` of the first base class that defines it, in the method
    /// resolution order of the class. `SymbolMatch.inheritedFrom` names that
    /// base class.
    case inherited

    /// The lowercased `symbol_path` contains the lowercased query.
    case caseInsensitive

    /// `query`'s characters appear, in order, as a subsequence of
    /// `symbol_path`.
    case fuzzy

    /// Not a match: a near candidate for a query that no other tier matches,
    /// in `GetSymbolResult.candidates` only.
    case near
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

    /// For a `SymbolMatchTier.inherited` match, the qualified path of the base
    /// class that defines the symbol; `nil` for every other match.
    public let inheritedFrom: String?

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
    ///   - inheritedFrom: The base class that defines an inherited match.
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
        source: SymbolSource,
        inheritedFrom: String? = nil
    ) {
        self.inheritedFrom = inheritedFrom
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

    /// When `symbols` is empty: the near candidates, all `SymbolMatchTier.near`
    /// — the same member name in other classes, and members of the queried
    /// class with a close name. `nil` when `symbols` has a match or nothing is
    /// near. They are kept out of `symbols`, so a caller that takes
    /// `symbols.first` never gets a symbol the query did not name.
    public let candidates: [SymbolMatch]?

    /// When `symbols` is empty: a short sentence that says no symbol matches
    /// and what `candidates` holds. `nil` when `symbols` has a match.
    public let note: String?

    /// Creates a `getSymbol` result.
    ///
    /// - Parameters:
    ///   - query: The original query string.
    ///   - symbols: Matched symbols, ordered by descending score.
    ///   - candidates: The near candidates when `symbols` is empty.
    ///   - note: The sentence about an empty `symbols`.
    public init(query: String, symbols: [SymbolMatch], candidates: [SymbolMatch]? = nil, note: String? = nil) {
        self.query = query
        self.symbols = symbols
        self.candidates = candidates
        self.note = note
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

/// The result of a `SymbolOps.listSymbols(store:file:)` call.
///
/// It has the shape of `GetSymbolResult` — the asked value and a `symbols`
/// array — so a caller that reads `result.symbols` on one reads it on the
/// other too.
public struct ListSymbolsResult: Codable, Sendable, Equatable {
    /// The file whose symbols these are, as asked.
    public let file: String

    /// Each symbol of `file`, in source order.
    public let symbols: [SymbolLocation]

    /// Creates a `listSymbols` result.
    ///
    /// - Parameters:
    ///   - file: The file whose symbols these are.
    ///   - symbols: Each symbol of `file`, in source order.
    public init(file: String, symbols: [SymbolLocation]) {
        self.file = file
        self.symbols = symbols
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

    /// The score `SymbolMatchTier.inherited` matches start from, before one
    /// point per step up the method resolution order is taken off.
    private static let inheritedBaseScore = 850

    /// The score a near candidate with a close name starts from, before
    /// `nearDistancePenalty` per edit (and, for a member, one point per step
    /// up the method resolution order) is taken off.
    private static let nearClassMemberBaseScore = 700

    /// The points one edit costs a near candidate with a close name.
    private static let nearDistancePenalty = 10

    /// The score a near candidate with the queried member name, in another
    /// class, starts from, before `shorterPathBonus(qualifiedPath:)` is added.
    /// It is below every close-name candidate of the queried class.
    private static let nearSameNameBaseScore = 400

    /// The most near candidates one result holds.
    private static let nearCandidateLimit = 10

    /// How many near candidate names the note of an empty result lists.
    private static let noteCandidateNameCount = 3

    /// The fewest edits `closeNameDistance(_:_:)` always accepts.
    private static let nearMinimumEditLimit = 2

    /// `closeNameDistance(_:_:)` accepts up to the query length divided by
    /// this many edits.
    private static let nearEditLimitDivisor = 3

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

    /// Looks up symbols by name using five-tier matching: exact, suffix,
    /// inherited, case-insensitive substring, then fuzzy subsequence — trying
    /// each in order and returning the first tier's results, so a query is
    /// never resolved by more than one tier at once.
    ///
    /// When no tier matches, `symbols` is empty and the result has a `note`,
    /// plus the near `candidates` when there are any (see
    /// `nearCandidates(candidates:query:hierarchy:)`).
    ///
    /// - Parameters:
    ///   - store: The workspace's index store to search.
    ///   - query: The symbol name or qualified path to look up.
    ///   - maxResults: The maximum number of matches to return within
    ///     whichever tier resolves the query. Defaults to 50.
    /// - Returns: The first non-empty tier's matches, capped at
    ///   `maxResults`, or an empty result with a note if no tier matches.
    /// - Throws: Rethrows `Store`'s storage errors.
    public static func getSymbol(store: Store, query: String, maxResults: Int = CodeContextDefaults.maxQueryResults) async throws -> GetSymbolResult {
        let candidates = try await loadCandidateRows(store: store, filePath: nil)

        if let result = matchExact(candidates: candidates, query: query, maxResults: maxResults) {
            return result
        }
        if let result = matchSuffix(candidates: candidates, query: query, maxResults: maxResults) {
            return result
        }
        let hierarchy = ClassHierarchy(candidates: candidates)
        if let result = matchInherited(hierarchy: hierarchy, query: query, maxResults: maxResults) {
            return result
        }
        if let result = matchCaseInsensitive(candidates: candidates, query: query, maxResults: maxResults) {
            return result
        }
        if let result = matchFuzzy(candidates: candidates, query: query, maxResults: maxResults) {
            return result
        }
        return noMatchResult(candidates: candidates, query: query, hierarchy: hierarchy)
    }

    /// Tier 1: exact `qualifiedPath` match.
    private static func matchExact(candidates: [SymbolCandidateRow], query: String, maxResults: Int) -> GetSymbolResult? {
        let matches = candidates.filter { $0.qualifiedPath == query }
        guard !matches.isEmpty else {
            return nil
        }
        let scoredRows = matches.map { (candidate: $0, score: exactScore) }.sorted(by: rankedBefore)
        return makeResult(query: query, tier: .exact, scoredRows: scoredRows, maxResults: maxResults)
    }

    /// Tier 2: suffix match — `foo` matches any `<container>.foo` (or `foo`
    /// itself).
    private static func matchSuffix(candidates: [SymbolCandidateRow], query: String, maxResults: Int) -> GetSymbolResult? {
        let suffixPattern = "\(Chunker.symbolPathSeparator)\(query)"
        let scoredRows =
            candidates
            .filter { $0.qualifiedPath.hasSuffix(suffixPattern) || $0.qualifiedPath == query }
            .map { (candidate: $0, score: suffixBaseScore + shorterPathBonus(qualifiedPath: $0.qualifiedPath)) }
            .sorted(by: rankedBefore)
        guard !scoredRows.isEmpty else {
            return nil
        }
        return makeResult(query: query, tier: .suffix, scoredRows: scoredRows, maxResults: maxResults)
    }

    /// Tier 3: a `Class.member` query whose class does not define `member`
    /// resolves to the `member` of the first base class that defines it, in
    /// the method resolution order of the class.
    ///
    /// Each class the query's class part names gives at most one match. The
    /// score drops by one for each step up the method resolution order, so a
    /// nearer base ranks first.
    private static func matchInherited(hierarchy: ClassHierarchy, query: String, maxResults: Int) -> GetSymbolResult? {
        guard let memberQuery = MemberQuery(query) else {
            return nil
        }
        var resolved: [(scored: ScoredCandidateRow, definingClass: String)] = []
        var seen: Set<SymbolLocationKey> = []
        for subclass in hierarchy.classes(named: memberQuery.classPath) {
            let order = hierarchy.methodResolutionOrder(of: subclass)
            for (depth, base) in order.enumerated().dropFirst() {
                guard let member = hierarchy.member(named: memberQuery.member, of: base) else {
                    continue
                }
                if seen.insert(SymbolLocationKey(member)).inserted {
                    resolved.append(((member, inheritedBaseScore - depth), base.qualifiedPath))
                }
                break
            }
        }
        guard !resolved.isEmpty else {
            return nil
        }
        let symbols = resolved.sorted { rankedBefore($0.scored, $1.scored) }.prefix(maxResults).map {
            symbolMatch($0.scored, tier: .inherited, inheritedFrom: $0.definingClass)
        }
        return GetSymbolResult(query: query, symbols: Array(symbols))
    }

    /// Tier 4: case-insensitive substring match.
    private static func matchCaseInsensitive(candidates: [SymbolCandidateRow], query: String, maxResults: Int) -> GetSymbolResult? {
        let queryLowercased = query.lowercased()
        let scoredRows =
            candidates
            .filter { $0.qualifiedPath.lowercased().contains(queryLowercased) }
            .map { (candidate: $0, score: caseInsensitiveBaseScore + shorterPathBonus(qualifiedPath: $0.qualifiedPath)) }
            .sorted(by: rankedBefore)
        guard !scoredRows.isEmpty else {
            return nil
        }
        return makeResult(query: query, tier: .caseInsensitive, scoredRows: scoredRows, maxResults: maxResults)
    }

    /// Tier 5: subsequence fuzzy match, ranked by fuzzy score.
    private static func matchFuzzy(candidates: [SymbolCandidateRow], query: String, maxResults: Int) -> GetSymbolResult? {
        let scoredRows =
            candidates
            .compactMap { candidate -> (candidate: SymbolCandidateRow, score: Int)? in
                guard let score = fuzzyScore(query: query, target: candidate.qualifiedPath) else {
                    return nil
                }
                return (candidate, score)
            }
            .sorted(by: rankedBefore)
        guard !scoredRows.isEmpty else {
            return nil
        }
        return makeResult(query: query, tier: .fuzzy, scoredRows: scoredRows, maxResults: maxResults)
    }

    /// Maps pre-scored, pre-sorted candidate rows to a `GetSymbolResult`,
    /// truncating to `maxResults`. Shared by the tiers so scoring and
    /// sorting are each tier's own concern, while assembling the public
    /// result shape happens in one place.
    private static func makeResult(
        query: String,
        tier: SymbolMatchTier,
        scoredRows: [ScoredCandidateRow],
        maxResults: Int
    ) -> GetSymbolResult {
        let symbols = scoredRows.prefix(maxResults).map { symbolMatch($0, tier: tier) }
        return GetSymbolResult(query: query, symbols: Array(symbols))
    }

    /// Maps one scored candidate row to the public `SymbolMatch` shape.
    private static func symbolMatch(_ scored: ScoredCandidateRow, tier: SymbolMatchTier, inheritedFrom: String? = nil) -> SymbolMatch {
        let candidate = scored.candidate
        return SymbolMatch(
            name: candidate.name,
            qualifiedPath: candidate.qualifiedPath,
            filePath: candidate.filePath,
            startLine: candidate.startLine,
            endLine: candidate.endLine,
            startColumn: candidate.startColumn,
            endColumn: candidate.endColumn,
            text: candidate.text,
            matchTier: tier,
            score: scored.score,
            kind: candidate.kind,
            detail: candidate.detail,
            source: candidate.source,
            inheritedFrom: inheritedFrom
        )
    }

    // MARK: - No match: near candidates

    /// The result of a query that no tier matches: empty `symbols`, the near
    /// candidates, and a note that says what they are.
    private static func noMatchResult(candidates: [SymbolCandidateRow], query: String, hierarchy: ClassHierarchy) -> GetSymbolResult {
        let near = nearCandidates(candidates: candidates, query: query, hierarchy: hierarchy)
        var note = "No symbol matches \"\(query)\"."
        if let memberQuery = MemberQuery(query), hierarchy.classes(named: memberQuery.classPath).isEmpty {
            note += " No class named \"\(memberQuery.classPath)\" is in the index."
        }
        if near.isEmpty {
            return GetSymbolResult(query: query, symbols: [], note: note)
        }
        let names = near.prefix(noteCandidateNameCount).map(\.qualifiedPath).joined(separator: ", ")
        note += " The candidates are near names, not matches: \(names)."
        return GetSymbolResult(query: query, symbols: [], candidates: near, note: note)
    }

    /// The near candidates of a query that no tier matches, best first, at
    /// most `nearCandidateLimit`.
    ///
    /// For a `Class.member` query: first the members of the class and of its
    /// bases whose name is close to `member` (by edit distance), then the
    /// symbols named `member` in other classes. For a plain name: the symbols
    /// whose own name is close to it.
    private static func nearCandidates(candidates: [SymbolCandidateRow], query: String, hierarchy: ClassHierarchy) -> [SymbolMatch] {
        var scoredRows: [ScoredCandidateRow] = []
        var seen: Set<SymbolLocationKey> = []
        func add(_ candidate: SymbolCandidateRow, score: Int) {
            if seen.insert(SymbolLocationKey(candidate)).inserted {
                scoredRows.append((candidate, score))
            }
        }

        if let memberQuery = MemberQuery(query) {
            for subclass in hierarchy.classes(named: memberQuery.classPath) {
                for (depth, base) in hierarchy.methodResolutionOrder(of: subclass).enumerated() {
                    for member in hierarchy.members(of: base) {
                        if let distance = closeNameDistance(memberQuery.member, member.name) {
                            add(member, score: nearClassMemberBaseScore - distance * nearDistancePenalty - depth)
                        }
                    }
                }
            }
            for candidate in candidates where candidate.name == memberQuery.member && candidate.qualifiedPath != candidate.name {
                add(candidate, score: nearSameNameBaseScore + shorterPathBonus(qualifiedPath: candidate.qualifiedPath))
            }
        } else {
            for candidate in candidates {
                if let distance = closeNameDistance(query, candidate.name) {
                    add(candidate, score: nearClassMemberBaseScore - distance * nearDistancePenalty)
                }
            }
        }
        return scoredRows.sorted(by: rankedBefore).prefix(nearCandidateLimit).map { symbolMatch($0, tier: .near) }
    }

    /// The edit distance between `query` and `name` when it is small enough
    /// for `name` to be a near candidate, else `nil`. An equal name is not
    /// near: a tier would have matched it.
    ///
    /// The limit is a third of the length of `query`, at least two edits, so
    /// `_check_validity` reaches `_check_values` but a short name does not
    /// reach every other short name.
    private static func closeNameDistance(_ query: String, _ name: String) -> Int? {
        let limit = max(nearMinimumEditLimit, query.count / nearEditLimitDivisor)
        guard name != query, abs(name.count - query.count) <= limit else {
            return nil
        }
        let distance = editDistance(Array(query.lowercased()), Array(name.lowercased()))
        return distance <= limit ? distance : nil
    }

    /// The Levenshtein distance between two strings.
    private static func editDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
        guard !lhs.isEmpty else { return rhs.count }
        guard !rhs.isEmpty else { return lhs.count }
        var previous = Array(0...rhs.count)
        var current = [Int](repeating: 0, count: rhs.count + 1)
        for (lhsIndex, lhsCharacter) in lhs.enumerated() {
            current[0] = lhsIndex + 1
            for (rhsIndex, rhsCharacter) in rhs.enumerated() {
                let substitution = previous[rhsIndex] + (lhsCharacter == rhsCharacter ? 0 : 1)
                current[rhsIndex + 1] = min(substitution, previous[rhsIndex + 1] + 1, current[rhsIndex] + 1)
            }
            swap(&previous, &current)
        }
        return previous[rhs.count]
    }

    /// A small bonus that prefers a shorter (more specific) qualified path
    /// over a longer one at the same tier.
    private static func shorterPathBonus(qualifiedPath: String) -> Int {
        max(0, shorterPathBonusCeiling - qualifiedPath.count)
    }

    /// Orders two scored candidate rows: the higher score comes first, and
    /// two rows with the same score are ordered by qualified path, then file
    /// path, then start line.
    ///
    /// `loadCandidateRows` gives its rows in no particular order, so a
    /// comparison of the scores alone lets two calls with the same arguments
    /// give the matches in a different order. These tie-breaks make the order
    /// total, so each call gives the same order, and thus the same JSON.
    ///
    /// - Parameters:
    ///   - lhs: The first row to compare.
    ///   - rhs: The second row to compare.
    /// - Returns: `true` when `lhs` comes before `rhs`.
    private static func rankedBefore(_ lhs: ScoredCandidateRow, _ rhs: ScoredCandidateRow) -> Bool {
        if lhs.score != rhs.score {
            return lhs.score > rhs.score
        }
        if lhs.candidate.qualifiedPath != rhs.candidate.qualifiedPath {
            return lhs.candidate.qualifiedPath < rhs.candidate.qualifiedPath
        }
        if lhs.candidate.filePath != rhs.candidate.filePath {
            return lhs.candidate.filePath < rhs.candidate.filePath
        }
        return lhs.candidate.startLine < rhs.candidate.startLine
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
        maxResults: Int = CodeContextDefaults.maxQueryResults
    ) async throws -> [SearchSymbolMatch] {
        let candidates = try await loadCandidateRows(store: store, filePath: nil)
        let filtered = kind.map { filterKind in candidates.filter { $0.kind == filterKind } } ?? candidates

        let scoredRows =
            filtered
            .compactMap { candidate -> (candidate: SymbolCandidateRow, score: Int)? in
                guard
                    let score = fuzzyScore(query: query, target: candidate.qualifiedPath)
                        ?? fuzzyScore(query: query, target: candidate.name)
                else {
                    return nil
                }
                return (candidate, score)
            }
            .sorted(by: rankedBefore)

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
    /// - Returns: `file` and its symbols in source order; no symbols if the
    ///   file has none (or doesn't exist in the index).
    /// - Throws: Rethrows `Store`'s storage errors.
    public static func listSymbols(store: Store, file: String) async throws -> ListSymbolsResult {
        let candidates = try await loadCandidateRows(store: store, filePath: file)
        let symbols =
            candidates
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
        return ListSymbolsResult(file: file, symbols: symbols)
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
            let previousCharacterIsSeparator =
                targetIndex == 0
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

    /// One candidate row together with the score that a tier gave it.
    private typealias ScoredCandidateRow = (candidate: SymbolCandidateRow, score: Int)

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

        init(filePath: String, startLine: Int) {
            self.filePath = filePath
            self.startLine = startLine
        }

        /// The location of `candidate`.
        init(_ candidate: SymbolCandidateRow) {
            self.init(filePath: candidate.filePath, startLine: candidate.startLine)
        }
    }

    /// A query split at its last separator into a class part and a member
    /// name: `ModelChoiceField.validate` is the class `ModelChoiceField` and
    /// the member `validate`. A query with no separator is no member query.
    private struct MemberQuery {
        let classPath: String
        let member: String

        init?(_ query: String) {
            guard let separator = query.range(of: Chunker.symbolPathSeparator, options: .backwards),
                separator.lowerBound != query.startIndex, separator.upperBound != query.endIndex
            else {
                return nil
            }
            classPath = String(query[..<separator.lowerBound])
            member = String(query[separator.upperBound...])
        }
    }

    /// The classes of the index, their members and their base classes, for
    /// the inherited tier and the near candidates.
    ///
    /// A class is a `.type` candidate. Its members are the candidates in the
    /// same file whose qualified path is the class path plus one more
    /// segment. Its bases come from its header text (see
    /// `ClassInheritance.baseNames(ofClassText:filePath:)`), each resolved to
    /// an indexed class with the same leaf name: the one in the same file
    /// first, else the first by file path and line. A base the index does
    /// not hold, such as `object`, is left out.
    private struct ClassHierarchy {
        /// Each class, by its location.
        private let classes: [SymbolLocationKey: SymbolCandidateRow]

        /// The classes with each leaf name, ordered by file path and line.
        private let classesByLeafName: [String: [SymbolLocationKey]]

        /// The members of each class, by file and class path.
        private let membersByContainer: [ContainerKey: [SymbolCandidateRow]]

        /// A class by its file and qualified path.
        private struct ContainerKey: Hashable {
            let filePath: String
            let qualifiedPath: String
        }

        init(candidates: [SymbolCandidateRow]) {
            var classes: [SymbolLocationKey: SymbolCandidateRow] = [:]
            var classesByLeafName: [String: [SymbolLocationKey]] = [:]
            var membersByContainer: [ContainerKey: [SymbolCandidateRow]] = [:]
            for candidate in candidates {
                if candidate.kind == .type {
                    let key = SymbolLocationKey(candidate)
                    classes[key] = candidate
                    classesByLeafName[leafName(ofQualifiedPath: candidate.qualifiedPath), default: []].append(key)
                }
                if let separator = candidate.qualifiedPath.range(of: Chunker.symbolPathSeparator, options: .backwards) {
                    let container = String(candidate.qualifiedPath[..<separator.lowerBound])
                    membersByContainer[ContainerKey(filePath: candidate.filePath, qualifiedPath: container), default: []].append(candidate)
                }
            }
            self.classes = classes
            self.classesByLeafName = classesByLeafName.mapValues { keys in
                keys.sorted { ($0.filePath, $0.startLine) < ($1.filePath, $1.startLine) }
            }
            self.membersByContainer = membersByContainer
        }

        /// The classes whose qualified path is `path` or ends with `.path`.
        func classes(named path: String) -> [SymbolCandidateRow] {
            (classesByLeafName[leafName(ofQualifiedPath: path)] ?? []).compactMap { classes[$0] }.filter {
                $0.qualifiedPath == path || $0.qualifiedPath.hasSuffix(Chunker.symbolPathSeparator + path)
            }
        }

        /// `start` and its indexed base classes, in Python lookup order.
        func methodResolutionOrder(of start: SymbolCandidateRow) -> [SymbolCandidateRow] {
            ClassInheritance.methodResolutionOrder(of: SymbolLocationKey(start)) { baseKeys(of: $0) }.compactMap { classes[$0] }
        }

        /// The members that `owner` defines itself.
        func members(of owner: SymbolCandidateRow) -> [SymbolCandidateRow] {
            membersByContainer[ContainerKey(filePath: owner.filePath, qualifiedPath: owner.qualifiedPath)] ?? []
        }

        /// The member named `name` that `owner` defines itself, if any. A
        /// class can hold two rows of one member (a decorated method and its
        /// inner definition); the first by line wins.
        func member(named name: String, of owner: SymbolCandidateRow) -> SymbolCandidateRow? {
            members(of: owner).filter { $0.name == name }.min { $0.startLine < $1.startLine }
        }

        /// The locations of the indexed direct bases of the class at `key`.
        private func baseKeys(of key: SymbolLocationKey) -> [SymbolLocationKey] {
            guard let owner = classes[key] else {
                return []
            }
            return ClassInheritance.baseNames(ofClassText: owner.text, filePath: owner.filePath).compactMap { baseName in
                let sameLeaf = (classesByLeafName[leafName(ofQualifiedPath: baseName)] ?? []).filter { $0 != key }
                return sameLeaf.first { $0.filePath == owner.filePath } ?? sameLeaf.first
            }
        }
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

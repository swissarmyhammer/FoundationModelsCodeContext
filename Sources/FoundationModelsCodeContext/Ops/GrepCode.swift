import Darwin
import Foundation
import GRDB

/// One regex match's byte-offset span within a `GrepCodeMatch.text`.
public struct GrepMatchPosition: Codable, Sendable, Equatable {
    /// The match's start offset, in UTF-8 bytes, within `text`.
    public let start: Int

    /// The match's end offset, in UTF-8 bytes, within `text`.
    public let end: Int

    /// Creates a match position.
    ///
    /// - Parameters:
    ///   - start: The match's start offset, in UTF-8 bytes.
    ///   - end: The match's end offset, in UTF-8 bytes.
    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

/// One `ts_chunks` chunk whose text matched `GrepCode.run(store:pattern:languages:filePattern:maxResults:)`'s pattern.
public struct GrepCodeMatch: Codable, Sendable, Equatable {
    /// The path of the file containing this chunk.
    public let filePath: String

    /// The chunk's zero-based start line.
    public let startLine: Int

    /// The chunk's zero-based end line.
    public let endLine: Int

    /// The chunk's qualified symbol path.
    public let symbolPath: String

    /// The chunk's full source text.
    public let text: String

    /// Every position within `text` where the pattern matched, in the order
    /// the regex engine found them.
    public let matches: [GrepMatchPosition]

    /// Creates a grep match.
    ///
    /// - Parameters:
    ///   - filePath: The path of the file containing this chunk.
    ///   - startLine: The chunk's zero-based start line.
    ///   - endLine: The chunk's zero-based end line.
    ///   - symbolPath: The chunk's qualified symbol path.
    ///   - text: The chunk's full source text.
    ///   - matches: Every position within `text` where the pattern matched.
    public init(filePath: String, startLine: Int, endLine: Int, symbolPath: String, text: String, matches: [GrepMatchPosition]) {
        self.filePath = filePath
        self.startLine = startLine
        self.endLine = endLine
        self.symbolPath = symbolPath
        self.text = text
        self.matches = matches
    }
}

/// The result of a `GrepCode.run(store:pattern:languages:filePattern:maxResults:)` call.
public struct GrepCodeResult: Codable, Sendable, Equatable {
    /// The regex pattern that was searched for.
    public let pattern: String

    /// Chunks that matched the pattern, capped at `maxResults`.
    public let matches: [GrepCodeMatch]

    /// The total number of chunks examined, before filtering by the
    /// pattern (but after the `languages`/`filePattern` filters).
    public let totalChunksSearched: Int

    /// `true` if the full match set was larger than `maxResults`.
    public let truncated: Bool

    /// Creates a grep-code result.
    ///
    /// - Parameters:
    ///   - pattern: The regex pattern that was searched for.
    ///   - matches: Chunks that matched the pattern, capped at `maxResults`.
    ///   - totalChunksSearched: The total number of chunks examined.
    ///   - truncated: `true` if the full match set was larger than
    ///     `maxResults`.
    public init(pattern: String, matches: [GrepCodeMatch], totalChunksSearched: Int, truncated: Bool) {
        self.pattern = pattern
        self.matches = matches
        self.totalChunksSearched = totalChunksSearched
        self.truncated = truncated
    }
}

/// Regex search across every indexed `ts_chunks.text`, with language and
/// file-pattern filters.
///
/// Port of the Rust `swissarmyhammer-code-context::ops::grep_code` module
/// (`crates/swissarmyhammer-code-context/src/ops/grep_code.rs`). The Rust
/// reference parallelizes matching with `rayon::par_iter` and filters by an
/// exact `files: Vec<String>` list; this port parallelizes with a
/// `TaskGroup` (Swift's structured-concurrency equivalent) and filters by a
/// single glob `filePattern` (via POSIX `fnmatch`) instead, since a glob is
/// what the task's `grepCode(pattern:languages:filePattern:maxResults:)`
/// signature calls for.
public enum GrepCode {
    /// Searches every `ts_chunks` chunk's text for `pattern`, optionally
    /// restricted to certain languages or a file-path glob.
    ///
    /// Matching itself runs concurrently across chunks via a `TaskGroup`;
    /// the resulting matches are then sorted by `(filePath, startLine)` for
    /// deterministic output (task-group completion order is not otherwise
    /// guaranteed) before the `maxResults` cap is applied.
    ///
    /// - Parameters:
    ///   - store: The workspace's index store to search.
    ///   - pattern: The regular expression to search chunk text for.
    ///   - languages: When non-empty, only chunks from files with one of
    ///     these extensions (no leading dot, e.g. `["swift", "rs"]`) are
    ///     searched. Defaults to empty (no language filter).
    ///   - filePattern: When non-`nil`, only chunks from files whose path
    ///     matches this glob (POSIX `fnmatch`, e.g. `"Sources/*"`) are
    ///     searched. Defaults to `nil` (no file filter).
    ///   - maxResults: The maximum number of matching chunks to return.
    ///     Defaults to 50.
    /// - Returns: Matching chunks (capped at `maxResults`), how many chunks
    ///     were searched, and whether the result was truncated.
    /// - Throws: `CodeContextError.pattern` if `pattern` fails to compile.
    ///     Rethrows `Store`'s storage errors.
    public static func run(
        store: Store,
        pattern: String,
        languages: [String] = [],
        filePattern: String? = nil,
        maxResults: Int = 50
    ) async throws -> GrepCodeResult {
        // Validated once upfront so an invalid pattern throws before any
        // work starts; each concurrent task below recompiles its own
        // `Regex` from the (Sendable) pattern string rather than sharing
        // one compiled `Regex` value across tasks, since `Regex`'s
        // internal representation isn't safe to send across task
        // boundaries under strict concurrency checking.
        _ = try compile(pattern: pattern)
        let chunks = try await loadChunks(store: store, languages: languages, filePattern: filePattern)

        let allMatches = await withTaskGroup(of: GrepCodeMatch?.self) { group in
            for chunk in chunks {
                group.addTask {
                    matchChunk(chunk: chunk, pattern: pattern)
                }
            }
            var results: [GrepCodeMatch] = []
            for await match in group {
                if let match {
                    results.append(match)
                }
            }
            return results
        }

        let sortedMatches = allMatches.sorted { lhs, rhs in
            lhs.filePath != rhs.filePath ? lhs.filePath < rhs.filePath : lhs.startLine < rhs.startLine
        }
        let truncated = sortedMatches.count > maxResults

        return GrepCodeResult(
            pattern: pattern,
            matches: Array(sortedMatches.prefix(maxResults)),
            totalChunksSearched: chunks.count,
            truncated: truncated
        )
    }

    /// Compiles `pattern` with Swift's native `Regex`, translating a
    /// compile failure into `CodeContextError.pattern`.
    private static func compile(pattern: String) throws -> Regex<AnyRegexOutput> {
        do {
            return try Regex(pattern)
        } catch {
            throw CodeContextError.pattern("invalid grep pattern '\(pattern)': \(error.localizedDescription)")
        }
    }

    /// Compiles `pattern` and runs it against `chunk.text`, or returns
    /// `nil` if it doesn't match at all.
    ///
    /// Recompiles `pattern` locally (rather than accepting an
    /// already-compiled `Regex`) so this can run as the body of a
    /// `TaskGroup` child task without sharing a `Regex` value across task
    /// boundaries — see the call site's comment. `pattern` was already
    /// validated to compile by `run`'s upfront `compile(pattern:)` call, so
    /// a `nil` here (rather than a thrown error) never actually occurs in
    /// practice; a truly re-failing compile is treated as no match, not a
    /// crash.
    private static func matchChunk(chunk: ChunkRow, pattern: String) -> GrepCodeMatch? {
        guard let regex = try? Regex(pattern) else {
            return nil
        }
        let occurrences = chunk.text.matches(of: regex)
        guard !occurrences.isEmpty else {
            return nil
        }
        let utf8 = chunk.text.utf8
        let positions = occurrences.map { occurrence in
            GrepMatchPosition(
                start: utf8.distance(from: utf8.startIndex, to: occurrence.range.lowerBound),
                end: utf8.distance(from: utf8.startIndex, to: occurrence.range.upperBound)
            )
        }
        return GrepCodeMatch(
            filePath: chunk.filePath,
            startLine: chunk.startLine,
            endLine: chunk.endLine,
            symbolPath: chunk.symbolPath,
            text: chunk.text,
            matches: positions
        )
    }

    /// One `ts_chunks` row loaded for grepping, before pattern matching.
    private struct ChunkRow: Sendable {
        let filePath: String
        let startLine: Int
        let endLine: Int
        let symbolPath: String
        let text: String
    }

    /// Loads every `ts_chunks` row, filtered by `languages` and
    /// `filePattern`.
    ///
    /// Filtering happens in Swift after a full fetch, rather than by
    /// building a dynamic SQL `WHERE` clause, since the candidate set is
    /// index-sized (not disk-sized) and this avoids interpolating
    /// caller-supplied extension/glob strings into SQL text.
    private static func loadChunks(store: Store, languages: [String], filePattern: String?) async throws -> [ChunkRow] {
        try await store.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT \(Schema.TsChunks.filePath), \(Schema.TsChunks.startLine), \(Schema.TsChunks.endLine), \
                       \(Schema.TsChunks.symbolPath), \(Schema.TsChunks.text) \
                FROM \(Schema.TsChunks.table)
                """
            )
            .map { row in
                ChunkRow(
                    filePath: row[Schema.TsChunks.filePath],
                    startLine: row[Schema.TsChunks.startLine],
                    endLine: row[Schema.TsChunks.endLine],
                    symbolPath: row[Schema.TsChunks.symbolPath],
                    text: row[Schema.TsChunks.text]
                )
            }
            .filter { matchesLanguageFilter(filePath: $0.filePath, languages: languages) }
            .filter { matchesFilePatternFilter(filePath: $0.filePath, filePattern: filePattern) }
        }
    }

    /// Whether `filePath`'s extension is one of `languages` (case-insensitive), or `languages` is empty.
    private static func matchesLanguageFilter(filePath: String, languages: [String]) -> Bool {
        guard !languages.isEmpty else {
            return true
        }
        let extensions = Set(languages.map { $0.lowercased() })
        return extensions.contains(URL(fileURLWithPath: filePath).pathExtension.lowercased())
    }

    /// Whether `filePath` matches `filePattern` via POSIX `fnmatch`, or
    /// `filePattern` is `nil`.
    private static func matchesFilePatternFilter(filePath: String, filePattern: String?) -> Bool {
        guard let filePattern else {
            return true
        }
        return fnmatch(filePattern, filePath, 0) == 0
    }
}

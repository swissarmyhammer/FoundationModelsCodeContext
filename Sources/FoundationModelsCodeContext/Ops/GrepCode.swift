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
///
/// The chunk is the innermost indexed symbol whose byte range holds the start
/// of a match: a match in one method of a class gives the method chunk, not
/// the class chunk. Two sibling symbols on one line each give their own
/// chunk.
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
    /// the regex engine found them. `GrepCode.run` keeps only the positions
    /// that this chunk owns: the byte range of this chunk holds the start of
    /// the match, and no matching chunk that is more inner and holds that
    /// byte found a match that starts at the same byte of the file.
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

    /// Chunks that matched the pattern, capped at `maxResults`. Each chunk
    /// is the innermost symbol for one or more match positions, and it
    /// occurs one time only.
    public let matches: [GrepCodeMatch]

    /// The total number of chunks examined, before filtering by the
    /// pattern (but after the `languages`/`filePattern` filters).
    public let totalChunksSearched: Int

    /// `true` if the full match set was larger than `maxResults`.
    public let truncated: Bool

    /// The number of tracked files that the tree-sitter layer did not index
    /// yet when the search read the index. These files have no chunks, thus a
    /// match in them is not in `matches`. The value is zero when the index is
    /// complete, and more than zero while an index pass runs.
    public let unindexedFiles: Int

    /// `true` when the index is partial: `unindexedFiles` is more than zero,
    /// and the result can miss matches.
    public var isIndexPartial: Bool {
        unindexedFiles > 0
    }

    /// Creates a grep-code result.
    ///
    /// - Parameters:
    ///   - pattern: The regex pattern that was searched for.
    ///   - matches: Chunks that matched the pattern, capped at `maxResults`.
    ///   - totalChunksSearched: The total number of chunks examined.
    ///   - truncated: `true` if the full match set was larger than
    ///     `maxResults`.
    ///   - unindexedFiles: The number of tracked files that the tree-sitter
    ///     layer did not index yet. Defaults to zero (a complete index).
    public init(pattern: String, matches: [GrepCodeMatch], totalChunksSearched: Int, truncated: Bool, unindexedFiles: Int = 0) {
        self.pattern = pattern
        self.matches = matches
        self.totalChunksSearched = totalChunksSearched
        self.truncated = truncated
        self.unindexedFiles = unindexedFiles
    }
}

/// Regex search across every indexed `ts_chunks.text`, with language and
/// file-pattern filters.
///
/// Port of the Rust `swissarmyhammer-code-context::ops::grep_code` module
/// (`crates/swissarmyhammer-code-context/src/ops/grep_code.rs`). The Rust
/// reference parallelizes matching with `rayon::par_iter` and filters by an
/// exact `files: Vec<String>` list. This port filters by a single glob
/// `filePattern` (via POSIX `fnmatch`) instead, since a glob is what the
/// task's `grepCode(pattern:languages:filePattern:maxResults:)` signature
/// calls for.
///
/// This port matches in one sequential pass, with one `NSRegularExpression`
/// (ICU syntax) that it compiles one time for each call. A Django-size index
/// holds about 90000 chunks. An earlier version made one task for each chunk,
/// and each task compiled a Swift `Regex` again. One call then used about 46
/// seconds of CPU time on such an index, and a call took more than 90 seconds
/// when other work used the same CPUs. The sequential ICU pass uses less than
/// one second of CPU time on the same index.
public enum GrepCode {
    /// Searches every `ts_chunks` chunk's text for `pattern`, optionally
    /// restricted to certain languages or a file-path glob.
    ///
    /// The search compiles `pattern` one time, as an `NSRegularExpression`
    /// (ICU syntax). It then reads the chunks one row at a time in one read
    /// transaction of `store`, and matches each chunk that the filters keep.
    /// The read runs on a reader connection of the store, not on the threads
    /// of the Swift concurrency pool, and it does not wait for an index pass:
    /// it reads the index as it is. The result tells how many files the
    /// tree-sitter layer did not index yet (`GrepCodeResult.unindexedFiles`).
    ///
    /// The chunker writes nested chunks, so a match in a method also matches
    /// the class that holds the method. Thus each match position goes to the
    /// innermost chunk that found a match at that position. The position is
    /// the absolute start of the match in its file. Only a chunk whose byte
    /// range holds the position (`startByte <= position < endByte`) can own
    /// it. A zero-length match at the end of a chunk text starts at the
    /// `endByte` of that chunk, so that chunk cannot own it. When no chunk
    /// that found the match holds its position, the position is dropped, the
    /// same as a match in no symbol gives no result. The innermost chunk has
    /// the smallest byte range, then the largest start byte, then the deepest
    /// symbol path. Two sibling chunks on one line do not hold the same
    /// positions, so each sibling keeps its own matches. A chunk that gets no
    /// position is not in the result, and a chunk keeps only the match
    /// positions that it gets.
    ///
    /// SQLite gives the rows in no fixed order. Thus the hits are sorted by
    /// file path, start line, start byte, end byte and symbol path before the
    /// owners are chosen. The result is in that order, and it does not change
    /// between calls. The `maxResults` cap applies after this step.
    ///
    /// - Parameters:
    ///   - store: The workspace's index store to search.
    ///   - pattern: The regular expression to search chunk text for, in the
    ///     ICU syntax of `NSRegularExpression`.
    ///   - languages: When non-empty, only chunks from files with one of
    ///     these extensions (no leading dot, e.g. `["swift", "rs"]`) are
    ///     searched. Defaults to empty (no language filter).
    ///   - filePattern: When non-`nil`, only chunks from files whose path
    ///     matches this glob (POSIX `fnmatch`, e.g. `"Sources/*"`) are
    ///     searched. Defaults to `nil` (no file filter).
    ///   - maxResults: The maximum number of matching chunks to return.
    ///     Defaults to 50.
    /// - Returns: Matching chunks (capped at `maxResults`), how many chunks
    ///     were searched, whether the result was truncated, and how many
    ///     files the tree-sitter layer did not index yet.
    /// - Throws: `CodeContextError.pattern` if `pattern` fails to compile.
    ///     Rethrows `Store`'s storage errors.
    public static func run(
        store: Store,
        pattern: String,
        languages: [String] = CodeContextDefaults.grepLanguages,
        filePattern: String? = nil,
        maxResults: Int = CodeContextDefaults.maxQueryResults
    ) async throws -> GrepCodeResult {
        let regex = try compile(pattern: pattern)
        let filter = ChunkFilter(languages: languages, filePattern: filePattern)
        let scan = try await store.read { db in
            try scanChunks(db: db, regex: regex, filter: filter)
        }

        let sortedMatches = innermostMatches(of: scan.hits.sorted { orderKey(of: $0) < orderKey(of: $1) })
        let truncated = sortedMatches.count > maxResults

        return GrepCodeResult(
            pattern: pattern,
            matches: Array(sortedMatches.prefix(maxResults)),
            totalChunksSearched: scan.chunksSearched,
            truncated: truncated,
            unindexedFiles: scan.unindexedFiles
        )
    }

    /// Compiles `pattern` as an `NSRegularExpression`, translating a compile
    /// failure into `CodeContextError.pattern`.
    ///
    /// - Parameter pattern: The regular expression, in ICU syntax.
    /// - Returns: The compiled expression.
    /// - Throws: `CodeContextError.pattern` if `pattern` fails to compile.
    private static func compile(pattern: String) throws -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            throw CodeContextError.pattern("invalid grep pattern '\(pattern)': \(error.localizedDescription)")
        }
    }

    /// Reads every `ts_chunks` row one at a time, keeps the rows that
    /// `filter` accepts, and matches each kept chunk against `regex`.
    ///
    /// The count of files that the tree-sitter layer did not index yet comes
    /// from the same read transaction. Thus it agrees with the chunks that the
    /// scan reads.
    ///
    /// - Parameters:
    ///   - db: The database connection of one read transaction.
    ///   - regex: The compiled pattern.
    ///   - filter: The language and file-path filters.
    /// - Returns: The hits, the count of searched chunks and the count of
    ///   files that the tree-sitter layer did not index yet.
    /// - Throws: Rethrows any error the queries throw.
    private static func scanChunks(db: Database, regex: NSRegularExpression, filter: ChunkFilter) throws -> ChunkScan {
        let rows = try Row.fetchCursor(
            db,
            sql: """
                SELECT \(Schema.TsChunks.filePath), \(Schema.TsChunks.startByte), \(Schema.TsChunks.endByte), \
                       \(Schema.TsChunks.startLine), \(Schema.TsChunks.endLine), \
                       \(Schema.TsChunks.symbolPath), \(Schema.TsChunks.text) \
                FROM \(Schema.TsChunks.table)
                """
        )
        let initial = ChunkScan(hits: [], chunksSearched: 0, unindexedFiles: try countUnindexedFiles(db: db))
        return try rows.reduce(into: initial) { scan, row in
            let filePath: String = row[Schema.TsChunks.filePath]
            guard filter.accepts(filePath: filePath) else {
                return
            }
            scan.chunksSearched += 1
            if let hit = matchChunk(row: row, filePath: filePath, regex: regex) {
                scan.hits.append(hit)
            }
        }
    }

    /// Counts the tracked files that the tree-sitter layer did not index yet.
    ///
    /// - Parameter db: The database connection to query.
    /// - Returns: The number of files with `ts_indexed = 0`.
    /// - Throws: Rethrows any error the query throws.
    private static func countUnindexedFiles(db: Database) throws -> Int {
        try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM \(Schema.IndexedFiles.table) WHERE \(IndexLayer.treeSitter.column) = 0"
        ) ?? 0
    }

    /// Runs `regex` against the text of the chunk in `row`, or returns `nil`
    /// if it doesn't match at all. The returned hit also holds the byte range
    /// of the chunk in its file.
    ///
    /// - Parameters:
    ///   - row: One `ts_chunks` row of the scan.
    ///   - filePath: The file path of `row`, which the caller already read.
    ///   - regex: The compiled pattern.
    /// - Returns: The hit, or `nil` when the chunk text has no match.
    private static func matchChunk(row: Row, filePath: String, regex: NSRegularExpression) -> ChunkHit? {
        let text: String = row[Schema.TsChunks.text]
        let positions = matchPositions(of: regex, in: text)
        guard !positions.isEmpty else {
            return nil
        }
        let match = GrepCodeMatch(
            filePath: filePath,
            startLine: row[Schema.TsChunks.startLine],
            endLine: row[Schema.TsChunks.endLine],
            symbolPath: row[Schema.TsChunks.symbolPath],
            text: text,
            matches: positions
        )
        return ChunkHit(match: match, startByte: row[Schema.TsChunks.startByte], endByte: row[Schema.TsChunks.endByte])
    }

    /// Every match of `regex` in `text`, as UTF-8 byte offsets in `text`.
    ///
    /// `NSRegularExpression` gives UTF-16 ranges. ICU matches on code points,
    /// thus each range starts and ends on a code point boundary, and its
    /// conversion to a `String` range always succeeds.
    ///
    /// - Parameters:
    ///   - regex: The compiled pattern.
    ///   - text: The text to search.
    /// - Returns: The match positions, in the order that the engine found them.
    private static func matchPositions(of regex: NSRegularExpression, in text: String) -> [GrepMatchPosition] {
        let utf8 = text.utf8
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { result in
            Range(result.range, in: text).map { range in
                GrepMatchPosition(
                    start: utf8.distance(from: utf8.startIndex, to: range.lowerBound),
                    end: utf8.distance(from: utf8.startIndex, to: range.upperBound)
                )
            }
        }
    }

    /// The key that sets the order of the hits before `innermostMatches(of:)`
    /// chooses the owners, and thus the order of the result.
    ///
    /// The order is the file path, the start line, the start byte, the end
    /// byte and then the symbol path. SQLite gives the rows in no fixed
    /// order. This sort makes the order fixed, so a full tie in
    /// `nestingKey(of:)` has the same result in each call.
    ///
    /// - Parameter hit: The chunk that matched.
    /// - Returns: A key that is smaller for the hit that comes first.
    private static func orderKey(of hit: ChunkHit) -> (String, Int, Int, Int, String) {
        (hit.match.filePath, hit.match.startLine, hit.startByte, hit.endByte, hit.match.symbolPath)
    }

    /// Gives each match position to the innermost chunk that holds it, and
    /// keeps each chunk only for the positions it gets.
    ///
    /// A position is the absolute start of a match in its file: the start
    /// byte of the chunk plus the start of the match in the chunk text. A
    /// chunk holds a position when `startByte <= position < endByte`. The
    /// chunker writes nested chunks: a class chunk holds the text of each
    /// method chunk, so a match in one method also matches the class at the
    /// same position. From the chunks that found a match at a position and
    /// that hold it, `nestingKey(of:)` chooses the innermost one. Thus the
    /// method gets the position and the class does not. Two sibling chunks on
    /// one line do not hold the same positions, so each sibling keeps its own
    /// matches.
    ///
    /// A zero-length match at the end of a chunk text starts at the `endByte`
    /// of that chunk, so that chunk does not hold it. A chunk that holds it,
    /// for example the class around a method, can own it. When no chunk that
    /// found the match holds its position, no chunk gets the position and it
    /// is dropped, the same as a match in no symbol gives no result.
    ///
    /// A chunk that gets no position is not in the result. A chunk that gets
    /// some positions keeps only those positions. On a full tie in
    /// `nestingKey(of:)`, the first hit in the order of `hits` gets the
    /// position.
    ///
    /// - Parameter hits: Every chunk that matched, from all files, in the
    ///   order of `orderKey(of:)`.
    /// - Returns: One match for each chunk that gets one position or more, in
    ///   the order of `hits`.
    private static func innermostMatches(of hits: [ChunkHit]) -> [GrepCodeMatch] {
        let owners = Dictionary(
            hits.indices.flatMap { index in
                hits[index].filePositions.filter(hits[index].holds).map { position in (position, index) }
            },
            uniquingKeysWith: { first, second in
                nestingKey(of: hits[second]) < nestingKey(of: hits[first]) ? second : first
            }
        )
        return hits.indices.compactMap { index in
            matchKeepingOwnedPositions(of: hits[index]) { position in owners[position] == index }
        }
    }

    /// The order that puts an inner chunk before a chunk that holds it.
    ///
    /// A smaller byte range (`endByte - startByte`) comes first. On a tie,
    /// the larger start byte comes first, then the deeper symbol path. The
    /// symbol path text breaks a last tie.
    ///
    /// - Parameter hit: The chunk that matched.
    /// - Returns: A key that is smaller for the more inner chunk.
    private static func nestingKey(of hit: ChunkHit) -> (Int, Int, Int, String) {
        let depth = hit.match.symbolPath.components(separatedBy: Chunker.symbolPathSeparator).count
        return (hit.endByte - hit.startByte, -hit.startByte, -depth, hit.match.symbolPath)
    }

    /// `hit`'s match with only the positions that `isOwned` accepts, or `nil`
    /// when no position stays.
    ///
    /// - Parameters:
    ///   - hit: The chunk that matched.
    ///   - isOwned: Whether `hit` is the innermost chunk for a match position
    ///     in its file.
    /// - Returns: The match with the kept positions, or `nil`.
    private static func matchKeepingOwnedPositions(
        of hit: ChunkHit,
        isOwned: (FilePosition) -> Bool
    ) -> GrepCodeMatch? {
        let keptPositions = zip(hit.match.matches, hit.filePositions)
            .filter { _, filePosition in isOwned(filePosition) }
            .map { position, _ in position }
        guard !keptPositions.isEmpty else {
            return nil
        }
        return GrepCodeMatch(
            filePath: hit.match.filePath,
            startLine: hit.match.startLine,
            endLine: hit.match.endLine,
            symbolPath: hit.match.symbolPath,
            text: hit.match.text,
            matches: keptPositions
        )
    }

    /// The absolute start of one match in its file.
    private struct FilePosition: Hashable {
        /// The path of the file that holds the match.
        let filePath: String

        /// The start offset of the match, in UTF-8 bytes, within the file.
        let byte: Int
    }

    /// One chunk whose text matched, with the byte range of the chunk in
    /// its file.
    private struct ChunkHit: Sendable {
        /// The chunk and all its match positions.
        let match: GrepCodeMatch

        /// The chunk's start offset, in UTF-8 bytes, within its file.
        let startByte: Int

        /// The chunk's end offset, in UTF-8 bytes, within its file.
        let endByte: Int

        /// The absolute start of each entry in `match.matches`, in the same
        /// order.
        var filePositions: [FilePosition] {
            match.matches.map { position in
                FilePosition(filePath: match.filePath, byte: startByte + position.start)
            }
        }

        /// Whether the byte range of this chunk holds `position`.
        ///
        /// The range is `startByte ..< endByte`. A zero-length match at the
        /// end of the chunk text starts at `endByte`, so this chunk does not
        /// hold it.
        ///
        /// - Parameter position: The absolute start of a match in its file.
        /// - Returns: `true` when `startByte <= position.byte < endByte`.
        func holds(_ position: FilePosition) -> Bool {
            (startByte..<endByte).contains(position.byte)
        }
    }

    /// What one scan of the `ts_chunks` rows found.
    private struct ChunkScan: Sendable {
        /// Every chunk whose text matched, in the order of the scan.
        var hits: [ChunkHit]

        /// The number of chunks that the filters kept and the scan matched.
        var chunksSearched: Int

        /// The number of tracked files that the tree-sitter layer did not
        /// index yet, read in the same transaction as the chunks.
        let unindexedFiles: Int
    }

    /// The language and file-path filters of one search.
    ///
    /// Filtering happens in Swift on each row of the scan, rather than by
    /// building a dynamic SQL `WHERE` clause. This avoids interpolating
    /// caller-supplied extension/glob strings into SQL text.
    private struct ChunkFilter: Sendable {
        /// The lowercased file extensions to keep, or an empty set to keep
        /// all the languages.
        let extensions: Set<String>

        /// The POSIX `fnmatch` glob that a file path must match, or `nil` to
        /// keep all the files.
        let filePattern: String?

        /// Creates the filters of one search.
        ///
        /// - Parameters:
        ///   - languages: The file extensions to keep, with no leading dot,
        ///     in any case. An empty list keeps all the languages.
        ///   - filePattern: The glob that a file path must match, or `nil`.
        init(languages: [String], filePattern: String?) {
            extensions = Set(languages.map { $0.lowercased() })
            self.filePattern = filePattern
        }

        /// Whether the chunks of `filePath` are searched.
        ///
        /// - Parameter filePath: The path of a file, relative to the root.
        /// - Returns: `true` when the extension of `filePath` is one of
        ///   `extensions` (case-insensitive) or `extensions` is empty, and
        ///   `filePath` matches `filePattern` or `filePattern` is `nil`.
        func accepts(filePath: String) -> Bool {
            matchesLanguage(filePath: filePath) && matchesFilePattern(filePath: filePath)
        }

        /// Whether the extension of `filePath` is one of `extensions`
        /// (case-insensitive), or `extensions` is empty.
        private func matchesLanguage(filePath: String) -> Bool {
            guard !extensions.isEmpty else {
                return true
            }
            return extensions.contains(Languages.normalizedFileExtension(ofPath: filePath))
        }

        /// Whether `filePath` matches `filePattern` via POSIX `fnmatch`, or
        /// `filePattern` is `nil`.
        private func matchesFilePattern(filePath: String) -> Bool {
            guard let filePattern else {
                return true
            }
            return fnmatch(filePattern, filePath, 0) == 0
        }
    }
}

import Foundation

/// One per-context result, disambiguated by which open root produced it.
///
/// `CodeContextManager`'s fan-out queries (`searchCode(query:topK:weights:)`,
/// `searchSymbol(query:kind:maxResults:)`, `grepCode(pattern:languages:filePattern:maxResults:)`)
/// each run the same per-root `CodeContext` op across every open context. Every individual
/// result's own paths stay root-relative — exactly as that `CodeContext`'s own op reports them —
/// so `root` is what disambiguates an identically-pathed match in one open repo from the same
/// path in another.
public struct Rooted<Value: Sendable>: Sendable {
    /// The standardized root URL of the `CodeContext` that produced `value`.
    public let root: URL

    /// The per-root result, unchanged from what that root's own `CodeContext` op returned.
    public let value: Value

    /// Creates a root-qualified result.
    ///
    /// - Parameters:
    ///   - root: The standardized root URL of the `CodeContext` that produced `value`.
    ///   - value: The per-root result, unchanged from what that root's own `CodeContext` op
    ///     returned.
    public init(root: URL, value: Value) {
        self.root = root
        self.value = value
    }
}

/// One open root's query failure, captured instead of thrown so a single failing root never sinks
/// a `CodeContextManager` fan-out query's other, still-succeeding roots.
public struct FanOutFailure: Sendable {
    /// The standardized root URL of the `CodeContext` whose query failed.
    public let root: URL

    /// A human-readable description of the failure.
    ///
    /// A `String`, not the underlying `Error`, to keep this type unconditionally `Sendable` —
    /// mirrors `CodeContextError`'s own Sendable-primitives convention.
    public let message: String

    /// Creates a fan-out failure record.
    ///
    /// - Parameters:
    ///   - root: The standardized root URL of the `CodeContext` whose query failed.
    ///   - message: A human-readable description of the failure.
    public init(root: URL, message: String) {
        self.root = root
        self.message = message
    }
}

/// Workspace-wide fan-out queries over every context a `CodeContextManager` currently has open.
///
/// Each method below runs the same per-root `CodeContext` op concurrently across every open
/// context (via a `TaskGroup`, never serially), catches each root's own failure into a
/// `FanOutFailure` instead of letting it fail the whole call, and merges every succeeding root's
/// results by **rank-major interleave**: sort the union by (per-root rank ascending, root path
/// ascending as tie-break), then cap at the requested limit. A union cap smaller than the number
/// of contributing roots still samples from every one of them, rather than exhausting the
/// alphabetically-first root's full quota before a later root ever contributes — see
/// `interleave(perRoot:limit:)` below.
extension CodeContextManager {
    // MARK: - searchCode

    /// Fans `CodeContext.searchCode(query:topK:weights:)` out across every open context, merged
    /// by rank-major interleave (see this extension's documentation).
    ///
    /// **Scores are not comparable across roots.** `SearchCode.run`'s fused score is
    /// `RRF.normalize`d to `[0, 1]` **per corpus** — relative to each root's own chunk population
    /// (see `SearchCode.fuseRankings`) — so merging the union by score would systematically favor
    /// a small repo's inflated normalized scores over a large repo's genuinely stronger, but
    /// comparatively scaled-down, ones. Results are therefore merged by rank (each root's own
    /// hit order), never by score, and every hit keeps its own root-relative `SearchCodeMatch`
    /// unchanged — only `Rooted.root` reveals which corpus's normalization scale a given
    /// `hit.score` belongs to.
    ///
    /// - Parameters:
    ///   - query: The search query, passed to every open context unchanged.
    ///   - topK: The maximum number of hits to return, across the union of every root's results.
    ///     Defaults to 20, mirroring `CodeContext.searchCode(query:topK:weights:)`.
    ///   - weights: The per-signal fusion weights, passed to every open context unchanged.
    ///     Defaults to `SearchWeights.default`.
    /// - Returns: The rank-major-interleaved, root-qualified hits (capped at `topK`), plus one
    ///   `FanOutFailure` per root whose own `searchCode` call threw.
    public func searchCode(
        query: String,
        topK: Int = 20,
        weights: SearchWeights = .default
    ) async -> (results: [Rooted<SearchCodeMatch>], failures: [FanOutFailure]) {
        let (perRoot, failures) = await fanOutQuery { context in
            try await context.searchCode(query: query, topK: topK, weights: weights).hits
        }
        return (Self.interleave(perRoot: perRoot, limit: topK), failures)
    }

    // MARK: - searchSymbol

    /// Fans `CodeContext.searchSymbol(query:kind:maxResults:)` out across every open context,
    /// merged by rank-major interleave (see this extension's documentation).
    ///
    /// - Parameters:
    ///   - query: The fuzzy query, passed to every open context unchanged.
    ///   - kind: When non-`nil`, restricts every context's own search to this meta-type.
    ///     Defaults to `nil` (no filter).
    ///   - maxResults: The maximum number of matches to return, across the union of every root's
    ///     results. Defaults to `CodeContext.defaultMaxQueryResults`, mirroring
    ///     `CodeContext.searchSymbol(query:kind:maxResults:)`.
    /// - Returns: The rank-major-interleaved, root-qualified matches (capped at `maxResults`),
    ///   plus one `FanOutFailure` per root whose own `searchSymbol` call threw.
    public func searchSymbol(
        query: String,
        kind: SymbolMetaType? = nil,
        maxResults: Int = CodeContext<Connection>.defaultMaxQueryResults
    ) async -> (results: [Rooted<SearchSymbolMatch>], failures: [FanOutFailure]) {
        let (perRoot, failures) = await fanOutQuery { context in
            try await context.searchSymbol(query: query, kind: kind, maxResults: maxResults)
        }
        return (Self.interleave(perRoot: perRoot, limit: maxResults), failures)
    }

    // MARK: - grepCode

    /// Fans `CodeContext.grepCode(pattern:languages:filePattern:maxResults:)` out across every
    /// open context, merged by rank-major interleave (see this extension's documentation).
    ///
    /// - Parameters:
    ///   - pattern: The regular expression, passed to every open context unchanged.
    ///   - languages: When non-empty, restricts every context's own search to these file
    ///     extensions. Defaults to empty (no language filter).
    ///   - filePattern: When non-`nil`, restricts every context's own search to files matching
    ///     this glob. Defaults to `nil` (no file filter).
    ///   - maxResults: The maximum number of matches to return, across the union of every root's
    ///     results. Defaults to `CodeContext.defaultMaxQueryResults`, mirroring
    ///     `CodeContext.grepCode(pattern:languages:filePattern:maxResults:)`.
    /// - Returns: The rank-major-interleaved, root-qualified matches (capped at `maxResults`),
    ///   plus one `FanOutFailure` per root whose own `grepCode` call threw — including an invalid
    ///   `pattern`, which fails identically (via `CodeContextError.pattern`) on every root.
    public func grepCode(
        pattern: String,
        languages: [String] = [],
        filePattern: String? = nil,
        maxResults: Int = CodeContext<Connection>.defaultMaxQueryResults
    ) async -> (results: [Rooted<GrepCodeMatch>], failures: [FanOutFailure]) {
        let (perRoot, failures) = await fanOutQuery { context in
            try await context.grepCode(
                pattern: pattern, languages: languages, filePattern: filePattern, maxResults: maxResults
            ).matches
        }
        return (Self.interleave(perRoot: perRoot, limit: maxResults), failures)
    }

    // MARK: - Shared fan-out machinery

    /// Runs `query` concurrently (via a `TaskGroup`) against every currently open context,
    /// capturing each root's own thrown error into a `FanOutFailure` rather than letting it fail
    /// this call as a whole.
    ///
    /// - Parameter query: The per-context op to run against every open context.
    /// - Returns: Every succeeding root's own ordered result list — root-tagged, kept in that
    ///   root's own order, which is the "rank" `interleave(perRoot:limit:)` merges by — plus one
    ///   `FanOutFailure` per root whose call threw.
    private func fanOutQuery<Value: Sendable>(
        _ query: @escaping @Sendable (CodeContext<Connection>) async throws -> [Value]
    ) async -> (perRoot: [(root: URL, values: [Value])], failures: [FanOutFailure]) {
        await withTaskGroup(of: (root: URL, outcome: Result<[Value], Error>).self) { group in
            for (root, context) in openContexts {
                group.addTask {
                    do {
                        return (root, .success(try await query(context)))
                    } catch {
                        return (root, .failure(error))
                    }
                }
            }

            var perRoot: [(root: URL, values: [Value])] = []
            var failures: [FanOutFailure] = []
            for await (root, outcome) in group {
                switch outcome {
                case let .success(values):
                    perRoot.append((root: root, values: values))
                case let .failure(error):
                    failures.append(FanOutFailure(root: root, message: error.localizedDescription))
                }
            }
            return (perRoot, failures)
        }
    }

    /// Rank-major interleaves every root's own ordered result list into one root-qualified union,
    /// tie-broken by root path when two roots both still have a value at the same rank, capped at
    /// `limit`.
    ///
    /// Walks rank `0, 1, 2, ...` across every contributing root (sorted by path) in turn —
    /// appending the alphabetically-first root's value at the current rank, then the next root's,
    /// and so on, before ever advancing to the next rank — rather than exhausting one root's full
    /// list before moving to the next. This guarantees every root's rank-0 result precedes every
    /// root's rank-1 result, and means a `limit` smaller than any single root's own result count
    /// still includes results from every contributing root instead of only the first one
    /// (alphabetically) that had any.
    ///
    /// - Parameters:
    ///   - perRoot: Every succeeding root's own ordered result list, as returned by
    ///     `fanOutQuery(_:)`.
    ///   - limit: The maximum number of root-qualified results to return.
    /// - Returns: The interleaved, root-qualified union, capped at `limit`.
    private static func interleave<Value: Sendable>(
        perRoot: [(root: URL, values: [Value])], limit: Int
    ) -> [Rooted<Value>] {
        let sortedRoots = perRoot.sorted { $0.root.path < $1.root.path }

        var merged: [Rooted<Value>] = []
        var rank = 0
        while merged.count < limit {
            let countBeforeThisRank = merged.count
            for (root, values) in sortedRoots {
                guard rank < values.count else { continue }
                merged.append(Rooted(root: root, value: values[rank]))
                if merged.count == limit { break }
            }
            // No root had a value at `rank`: every root is exhausted, so further ranks would
            // never add anything either.
            guard merged.count > countBeforeThisRank else { break }
            rank += 1
        }
        return merged
    }
}

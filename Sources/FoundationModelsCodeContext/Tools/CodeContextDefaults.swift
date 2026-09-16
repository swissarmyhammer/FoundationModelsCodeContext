import Foundation

/// The default values of the `CodeContext` operations.
///
/// Each engine default has its name and its value here, one time. The public
/// `CodeContext` methods, the op engines, and the FoundationModels tool
/// operations use these names. Thus the Swift API and the tools always use the
/// same defaults.
///
/// The enum and its members are `@usableFromInline` because public default
/// arguments refer to them. A public default argument can refer only to a
/// `public` or a `@usableFromInline` declaration. They are not public API.
@usableFromInline
internal enum CodeContextDefaults {
    /// The maximum number of results of an index query: `getSymbol`,
    /// `searchSymbol` and `grepCode`.
    @usableFromInline static let maxQueryResults = 50

    /// Whether a live operation (`definition`, `typeDefinition`,
    /// `implementations`) adds the source text of each location.
    @usableFromInline static let includeSource = false

    /// The direction of a `callGraph` walk.
    @usableFromInline static let callGraphDirection = CallGraphDirection.outbound

    /// The maximum number of levels of a `callGraph` walk.
    @usableFromInline static let callGraphMaxDepth = 2

    /// The maximum number of call-edge hops of a `blastRadius` walk.
    @usableFromInline static let blastRadiusMaxHops = 3

    /// The language filter of `grepCode`. An empty list searches all languages.
    @usableFromInline static let grepLanguages: [String] = []

    /// The number of hits that `searchCode` returns.
    @usableFromInline static let searchTopK = 20

    /// The weight of each signal of the `searchCode` ranking.
    @usableFromInline static let searchWeights = SearchWeights.default

    /// The minimum cosine similarity of a `findDuplicates` pair.
    @usableFromInline static let duplicateMinSimilarity = 0.85

    /// The minimum size, in bytes, of a chunk that `findDuplicates` compares.
    @usableFromInline static let duplicateMinChunkBytes = 100

    /// The maximum number of duplicates that `findDuplicates` gives for one chunk.
    @usableFromInline static let duplicateMaxPerChunk = 5

    /// The maximum number of matches of a `queryAST` query.
    @usableFromInline static let queryASTMaxResults = 50

    /// Whether `references` includes the declaration itself.
    @usableFromInline static let referencesIncludeDeclaration = false

    /// The maximum number of results of `implementations`.
    @usableFromInline static let implementationsMaxResults = 20

    /// The lowest severity that `diagnostics` reports.
    @usableFromInline static let diagnosticsSeverity = DiagnosticSeverity.warning

    /// Whether `diagnostics` also reports the dependents that the change broke.
    @usableFromInline static let diagnosticsIncludeDependents = true

    /// The quiet time, in milliseconds, that `diagnostics` waits for before it
    /// reads a report.
    private static let diagnosticsSettleWindowMilliseconds = 300

    /// The quiet time that `diagnostics` waits for before it reads a report.
    @usableFromInline static let diagnosticsSettleWindow = Duration.milliseconds(diagnosticsSettleWindowMilliseconds)

    /// The maximum time, in seconds, that `diagnostics` waits for the reports
    /// to settle.
    private static let diagnosticsHardTimeoutSeconds = 5

    /// The maximum time that `diagnostics` waits for the reports to settle.
    @usableFromInline static let diagnosticsHardTimeout = Duration.seconds(diagnosticsHardTimeoutSeconds)

    /// The maximum number of diagnostics that `diagnostics` keeps from one report.
    @usableFromInline static let diagnosticsPerReportCap = 100

    /// Whether FoundationModels adds the schema of a tool to the prompt.
    ///
    /// This is the default of `CodeContextTools.make` and of the `make`
    /// function of each tool, so the three tools always start with the same
    /// value.
    @usableFromInline static let includesSchemaInInstructions = true
}

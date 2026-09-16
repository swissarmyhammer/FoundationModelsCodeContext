import FoundationModels
import Operations

/// The `grep code` operation of the `code_search` tool.
///
/// It finds the indexed code chunks whose text matches a regular expression.
@Generable
@Operation(
    verb: "grep",
    noun: "code",
    description: "Find the indexed code chunks whose text matches a regular expression. You can search only some languages, or only the files that match a glob."
)
internal struct GrepCodeOperation {
    /// The regular expression to search for.
    @Guide(description: "The regular expression to search for in the text of the indexed code chunks.")
    @OperationParam(aliases: ["regex", "query"])
    var pattern: String

    /// The languages to search, or `nil` for all the languages.
    @Guide(
        description:
            "The file extensions of the languages to search, with no dot, for example swift. If you give no extension, the operation searches all the languages."
    )
    @OperationParam(aliases: ["extensions", "langs"])
    var languages: [String]?

    /// The glob that a file path must match, or `nil` for all the files.
    @Guide(
        description:
            "A POSIX glob that the path of a file must match, for example `*.swift`. If you give no glob, the operation searches all the files."
    )
    @OperationParam(aliases: ["glob", "include"])
    var filePattern: String?

    /// The maximum number of results, or `nil` for the default.
    @Guide(description: "The maximum number of results to give.")
    @OperationParam(aliases: ["limit", "max"])
    var maxResults: Int?
}

extension GrepCodeOperation {
    /// Calls `grepCode(pattern:languages:filePattern:maxResults:)`.
    ///
    /// - Parameter context: The tool context.
    /// - Returns: The engine result, or a corrective message.
    /// - Throws: An error that the model cannot correct.
    func execute(in context: CodeContextToolContext) async throws -> ToolOutcome<GrepCodeResult> {
        try await ToolSupport.outcome {
            try await context.operating.grepCode(
                pattern: pattern,
                languages: languages ?? CodeContextDefaults.grepLanguages,
                filePattern: filePattern,
                maxResults: maxResults ?? CodeContextDefaults.maxQueryResults
            )
        }
    }
}

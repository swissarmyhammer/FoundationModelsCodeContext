import FoundationModels
import Operations

/// The `grep code` operation of the `code_search` tool.
///
/// It finds the indexed code chunks whose text matches a regular expression.
/// For each match, the answer is the innermost indexed symbol that holds the
/// start of the match, for example the method and not its class. Two symbols
/// on one line each give their own answer. The search does not wait for an
/// index pass. The `unindexedFiles` field of the answer tells when the index is
/// partial.
@Generable
@Operation(
    verb: "grep",
    noun: "code",
    description: "Find the indexed code chunks whose text matches a regular expression. Each match is answered with the innermost indexed symbol that holds its start, for example the method and not its class. You can limit the search by language or by file glob. The search does not wait for the index. When unindexedFiles is more than zero, the index is partial and the answer can miss matches."
)
internal struct GrepCodeOperation {
    /// The regular expression to search for, in ICU syntax.
    @Guide(description: "The regular expression, in ICU syntax, to search for in the text of the indexed code chunks.")
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

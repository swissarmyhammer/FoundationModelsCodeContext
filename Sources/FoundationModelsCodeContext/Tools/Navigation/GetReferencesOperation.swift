import FoundationModels
import Operations

/// The `get references` operation of the `code_navigation` tool.
///
/// It finds each place that uses the symbol at a position.
@Generable
@Operation(
    verb: "get",
    noun: "references",
    description: "Find each place that uses the symbol at a position in a file."
)
internal struct GetReferencesOperation {
    /// The file that holds the position.
    @Guide(
        description:
            "A file path relative to the workspace root. `get diagnostics` also accepts an absolute path or a glob."
    )
    @OperationParam(aliases: ["path", "filePath", "filename"])
    var file: String

    /// The line of the position.
    @Guide(description: "The line of the position in the file. The first line is line 0.")
    @OperationParam(aliases: ["row"])
    var line: Int

    /// The character offset of the position in its line.
    @Guide(
        description:
            "The character offset of the position in its line, in UTF-16 units. The first character is character 0."
    )
    @OperationParam(aliases: ["column", "col"])
    var character: Int

    /// Whether the result also includes the declaration, or `nil` for the
    /// default.
    @Guide(description: "Whether the result also includes the declaration of the symbol.")
    @OperationParam(aliases: ["withDeclaration", "includeDecl"])
    var includeDeclaration: Bool?

    /// The maximum number of results, or `nil` for no limit.
    @Guide(description: "The maximum number of results to give.")
    @OperationParam(aliases: ["limit", "max"])
    var maxResults: Int?
}

extension GetReferencesOperation {
    /// Calls `references(filePath:line:character:includeDeclaration:maxResults:)`.
    ///
    /// `maxResults` goes to the engine as it is: the engine reads `nil` as
    /// "give each result".
    ///
    /// - Parameter context: The tool context.
    /// - Returns: The engine result, or a corrective message.
    /// - Throws: An error that the model cannot correct.
    func execute(in context: CodeContextToolContext) async throws -> ToolOutcome<ReferencesResult> {
        try await ToolSupport.outcome {
            try await context.operating.references(
                filePath: file,
                line: line,
                character: character,
                includeDeclaration: includeDeclaration ?? CodeContextDefaults.referencesIncludeDeclaration,
                maxResults: maxResults
            )
        }
    }
}

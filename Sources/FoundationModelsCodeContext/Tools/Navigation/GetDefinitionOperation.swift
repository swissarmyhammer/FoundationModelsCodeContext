import FoundationModels
import Operations

/// The `get definition` operation of the `code_navigation` tool.
///
/// It finds the place where the program declares the symbol at a position.
@Generable
@Operation(
    verb: "get",
    noun: "definition",
    description: "Find the place where the program declares the symbol at a position in a file."
)
internal struct GetDefinitionOperation {
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

    /// The character offset of the position in its line, or `nil` when the
    /// model does not know it.
    @Guide(description: PositionGuide.character)
    @OperationParam(aliases: ["column", "col"])
    var character: Int?

    /// The name of the symbol at the position, or `nil`.
    @Guide(description: PositionGuide.symbol)
    @OperationParam(aliases: ["name", "identifier"])
    var symbol: String?

    /// Whether each location also gives its source text, or `nil` for the
    /// default.
    @Guide(description: "Whether each location also gives its source text.")
    @OperationParam(aliases: ["withSource", "source"])
    var includeSource: Bool?
}

extension GetDefinitionOperation {
    /// Calls `definition(filePath:line:character:includeSource:)`.
    ///
    /// - Parameter context: The tool context.
    /// - Returns: The engine result, or a corrective message.
    /// - Throws: An error that the model cannot correct.
    func execute(in context: CodeContextToolContext) async throws -> ToolOutcome<PositionedResult<DefinitionResult>> {
        try await ToolSupport.outcome(in: context, file: file, line: line, character: character, symbol: symbol) { position in
            try await context.operating.definition(
                filePath: file,
                line: position.line,
                character: position.character,
                includeSource: includeSource ?? CodeContextDefaults.includeSource
            )
        }
    }
}

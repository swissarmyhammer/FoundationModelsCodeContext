import FoundationModels
import Operations

/// The `get hover` operation of the `code_navigation` tool.
///
/// It gives the type, the signature or the documentation of the symbol at a
/// position.
@Generable
@Operation(
    verb: "get",
    noun: "hover",
    description: "Give the type, the signature or the documentation of the symbol at a position in a file."
)
internal struct GetHoverOperation {
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
}

extension GetHoverOperation {
    /// Calls `hover(filePath:line:character:)`.
    ///
    /// - Parameter context: The tool context.
    /// - Returns: The engine result, or a corrective message.
    /// - Throws: An error that the model cannot correct.
    func execute(in context: CodeContextToolContext) async throws -> ToolOutcome<PositionedResult<HoverResult>> {
        try await ToolSupport.outcome(in: context, file: file, line: line, character: character, symbol: symbol) { position in
            try await context.operating.hover(filePath: file, line: position.line, character: position.character)
        }
    }
}

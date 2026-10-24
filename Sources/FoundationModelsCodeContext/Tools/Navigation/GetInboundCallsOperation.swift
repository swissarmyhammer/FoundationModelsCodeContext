import FoundationModels
import Operations

/// The `get inbound_calls` operation of the `code_navigation` tool.
///
/// It finds each function that calls the symbol at a position.
@Generable
@Operation(
    verb: "get",
    noun: "inbound_calls",
    description: "Find each function that calls the symbol at a position in a file."
)
internal struct GetInboundCallsOperation {
    /// The file that holds the position.
    @Guide(
        description:
            "A file path relative to the workspace root. `get diagnostics` also accepts an absolute path or a glob."
    )
    @OperationParam(aliases: ["path", "filePath", "filename"])
    var file: String

    /// The line of the position.
    @Guide(description: PositionGuide.line)
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

extension GetInboundCallsOperation {
    /// Calls `inboundCalls(filePath:line:character:)`.
    ///
    /// - Parameter context: The tool context.
    /// - Returns: The engine result, or a corrective message.
    /// - Throws: An error that the model cannot correct.
    func execute(in context: CodeContextToolContext) async throws -> ToolOutcome<PositionedResult<InboundCallsResult>> {
        try await ToolSupport.outcome(in: context, file: file, line: line, character: character, symbol: symbol) { position in
            try await context.operating.inboundCalls(
                filePath: file,
                line: position.line,
                character: position.character
            )
        }
    }
}

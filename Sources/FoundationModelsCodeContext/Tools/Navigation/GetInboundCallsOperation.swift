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
}

extension GetInboundCallsOperation {
    /// Calls `inboundCalls(filePath:line:character:)`.
    ///
    /// - Parameter context: The tool context.
    /// - Returns: The engine result, or a corrective message.
    /// - Throws: An error that the model cannot correct.
    func execute(in context: CodeContextToolContext) async throws -> ToolOutcome<InboundCallsResult> {
        try await ToolSupport.outcome {
            try await context.operating.inboundCalls(
                filePath: file,
                line: line,
                character: character
            )
        }
    }
}

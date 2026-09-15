import FoundationModels
import Operations

/// The `list symbol` operation of the `code_search` tool.
///
/// It gives each symbol of one file, in the order of the file.
@Generable
@Operation(
    verb: "list",
    noun: "symbol",
    description: "Give each symbol of one file, with its location, in the order of the file."
)
internal struct ListSymbolOperation {
    /// The file whose symbols to give.
    @Guide(description: "A file path relative to the workspace root.")
    @OperationParam(aliases: ["path", "filePath", "filename"])
    var file: String
}

extension ListSymbolOperation {
    /// Calls `listSymbols(file:)`.
    ///
    /// - Parameter context: The tool context.
    /// - Returns: The engine result, or a corrective message.
    /// - Throws: An error that the model cannot correct.
    func execute(in context: CodeContextToolContext) async throws -> ToolOutcome<[SymbolLocation]> {
        try await ToolSupport.outcome {
            try await context.operating.listSymbols(file: file)
        }
    }
}

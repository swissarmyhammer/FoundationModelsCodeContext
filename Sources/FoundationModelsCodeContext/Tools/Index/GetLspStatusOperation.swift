import FoundationModels
import Operations

/// The `get lsp_status` operation of the `code_index` tool.
///
/// It gives the state of each language server that the workspace manages.
@Generable
@Operation(
    verb: "get",
    noun: "lsp_status",
    description: "Give the state of each language server that the workspace manages."
)
internal struct GetLspStatusOperation {}

extension GetLspStatusOperation {
    /// Calls `lspStatus()`.
    ///
    /// The operation has no parameters, because the engine call has none.
    ///
    /// - Parameter context: The tool context.
    /// - Returns: The engine result.
    /// - Throws: An error that the model cannot correct.
    func execute(in context: CodeContextToolContext) async throws -> ToolOutcome<[ServerStatus]> {
        try await ToolSupport.outcome {
            await context.operating.lspStatus()
        }
    }
}

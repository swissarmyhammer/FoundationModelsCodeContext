import FoundationModels
import Operations

/// The `stop lsp` operation of the `code_index` tool.
///
/// It stops each language server of the workspace, so that the server
/// releases its file locks. The index continues to answer.
@Generable
@Operation(
    verb: "stop",
    noun: "lsp",
    description: "Stop each language server of the workspace, so that it releases its file locks, for example before a build cleanup. The index continues to answer. Use `start lsp` to start the servers again."
)
internal struct StopLspOperation {}

extension StopLspOperation {
    /// Calls `stopLanguageServers()`.
    ///
    /// The operation has no parameters, because the engine call has none.
    ///
    /// - Parameter context: The tool context.
    /// - Returns: The engine result.
    /// - Throws: An error that the model cannot correct.
    func execute(in context: CodeContextToolContext) async throws -> ToolOutcome<[ServerStatus]> {
        try await ToolSupport.outcome {
            await context.operating.stopLanguageServers()
        }
    }
}

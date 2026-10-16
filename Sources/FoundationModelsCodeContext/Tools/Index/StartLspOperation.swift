import FoundationModels
import Operations

/// The `start lsp` operation of the `code_index` tool.
///
/// It starts the language servers of the workspace again after `stop lsp`.
@Generable
@Operation(
    verb: "start",
    noun: "lsp",
    description: "Start the language servers of the workspace again after `stop lsp`. The workspace detects its projects again and installs a missing server when the auto install is on."
)
internal struct StartLspOperation {}

extension StartLspOperation {
    /// Calls `startLanguageServers()`.
    ///
    /// The operation has no parameters, because the engine call has none.
    ///
    /// - Parameter context: The tool context.
    /// - Returns: The engine result.
    /// - Throws: An error that the model cannot correct.
    func execute(in context: CodeContextToolContext) async throws -> ToolOutcome<[ServerStatus]> {
        try await ToolSupport.outcome {
            try await context.operating.startLanguageServers()
        }
    }
}

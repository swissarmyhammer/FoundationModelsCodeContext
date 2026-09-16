import FoundationModels
import Operations

/// The `get status` operation of the `code_index` tool.
///
/// It gives the progress of the index of the workspace: the number of files
/// that the walk found, and the number of files that each layer indexed.
@Generable
@Operation(
    verb: "get",
    noun: "status",
    description: "Give the progress of the index of the workspace: the number of files that the walk found, and the number of files that each layer indexed."
)
internal struct GetStatusOperation {}

extension GetStatusOperation {
    /// Calls `indexStatus()`.
    ///
    /// The operation has no parameters, because the engine call has none.
    ///
    /// - Parameter context: The tool context.
    /// - Returns: The engine result.
    /// - Throws: An error that the model cannot correct.
    func execute(in context: CodeContextToolContext) async throws -> ToolOutcome<IndexProgress> {
        try await ToolSupport.outcome {
            await context.operating.indexStatus()
        }
    }
}

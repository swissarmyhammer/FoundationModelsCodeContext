import FoundationModels
import Operations

/// The `detect projects` operation of the `code_index` tool.
///
/// It finds the marker file of each language in the workspace, for example
/// `Package.swift`, and gives one project for each language that it finds.
@Generable
@Operation(
    verb: "detect",
    noun: "projects",
    description: "Find the marker file of each language in the workspace, for example Package.swift, and give one project for each language."
)
internal struct DetectProjectsOperation {}

extension DetectProjectsOperation {
    /// Calls `detectProjects()`.
    ///
    /// The operation has no parameters, because the engine call has none.
    ///
    /// - Parameter context: The tool context.
    /// - Returns: The engine result.
    /// - Throws: An error that the model cannot correct.
    func execute(in context: CodeContextToolContext) async throws -> ToolOutcome<[DetectedProject]> {
        try await ToolSupport.outcome {
            try await context.operating.detectProjects()
        }
    }
}

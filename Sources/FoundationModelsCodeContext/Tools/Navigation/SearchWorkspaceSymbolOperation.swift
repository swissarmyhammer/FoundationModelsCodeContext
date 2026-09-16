import FoundationModels
import Operations

/// The `search workspace_symbol` operation of the `code_navigation` tool.
///
/// It finds the symbols of the workspace whose name matches a query. The
/// language server answers the query, so the list is empty when no language
/// server runs.
@Generable
@Operation(
    verb: "search",
    noun: "workspace_symbol",
    description: "Find the symbols of the workspace whose name matches the query."
)
internal struct SearchWorkspaceSymbolOperation {
    /// The text to search for.
    @Guide(description: "The name, or a part of the name, of the symbols to find in the workspace.")
    @OperationParam(aliases: ["name", "symbol"])
    var query: String
}

extension SearchWorkspaceSymbolOperation {
    /// Calls `workspaceSymbols(query:)`.
    ///
    /// - Parameter context: The tool context.
    /// - Returns: The engine result, or a corrective message.
    /// - Throws: An error that the model cannot correct.
    func execute(in context: CodeContextToolContext) async throws -> ToolOutcome<WorkspaceSymbolsResult> {
        try await ToolSupport.outcome {
            try await context.operating.workspaceSymbols(query: query)
        }
    }
}

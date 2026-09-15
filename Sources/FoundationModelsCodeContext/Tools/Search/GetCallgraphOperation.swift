import FoundationModels
import Operations

/// The `get callgraph` operation of the `code_search` tool.
///
/// It walks the call graph from one symbol: to its callers, to its callees, or
/// in the two directions.
@Generable
@Operation(
    verb: "get",
    noun: "callgraph",
    description: "Walk the call graph from one symbol: to the callers, to the callees, or in the two directions."
)
internal struct GetCallgraphOperation {
    /// The symbol where the walk starts.
    @Guide(
        description:
            "For `get callgraph`: a symbol name, or a `<file>:<line>:<column>` locator with 0-based numbers. For `get blastradius`: the name of a symbol inside `file`."
    )
    @OperationParam(aliases: ["name", "locator"])
    var symbol: String

    /// The direction of the walk, or `nil` for the default.
    @Guide(
        description: "The direction of the walk: inbound (to the callers), outbound (to the callees) or both.",
        .anyOf(["inbound", "outbound", "both"])
    )
    @OperationParam(aliases: ["dir"])
    var direction: String?

    /// The maximum number of levels of the walk, or `nil` for the default.
    @Guide(description: "The maximum number of call levels to walk.")
    @OperationParam(aliases: ["depth"])
    var maxDepth: Int?
}

extension GetCallgraphOperation {
    /// The allowed names of `direction`, and the walk direction of each name.
    static let directionChoices = ToolSupport.choiceTable(for: CallGraphDirection.self)

    /// Calls `callGraph(of:direction:maxDepth:)`.
    ///
    /// - Parameter context: The tool context.
    /// - Returns: The engine result, or a corrective message.
    /// - Throws: An error that the model cannot correct.
    func execute(in context: CodeContextToolContext) async throws -> ToolOutcome<CallGraph> {
        let parse = ToolSupport.parseOptionalChoice(direction, choices: Self.directionChoices, parameter: "direction")
        return try await ToolSupport.outcome(after: parse) { walkDirection in
            try await context.operating.callGraph(
                of: symbol,
                direction: walkDirection ?? CodeContextDefaults.callGraphDirection,
                maxDepth: maxDepth ?? CodeContextDefaults.callGraphMaxDepth
            )
        }
    }
}

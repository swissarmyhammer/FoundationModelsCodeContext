import FoundationModels
import Operations

/// The `code_search` tool: it finds symbols and walks the call graph of the
/// workspace.
///
/// The tool fuses its operations into one `OperationTool`. The model selects
/// an operation with the `op` parameter, for example `get symbol`.
internal enum CodeSearchTool {
    /// The model-facing name of the tool.
    static let name = "code_search"

    /// The model-facing description of the tool.
    static let description =
        "Search the code of the workspace. Find symbols by name, list the symbols of a file, "
        + "walk the call graph of a symbol, and find the blast radius of a change."

    /// The verb aliases of the tool, from the alias to the real verb.
    ///
    /// No key is a real verb of the tool: the resolver applies an alias before
    /// it compares, so such a key would send a real operation to a different
    /// operation.
    static let verbAliases: [String: String] = [
        "lookup": "get",
        "locate": "get",
        "ls": "list",
        "enumerate": "list",
        "match": "grep",
    ]

    /// The noun aliases of the tool, from the alias to the real noun.
    ///
    /// No key is a real noun of the tool, for the same reason as
    /// `verbAliases`.
    static let nounAliases: [String: String] = [
        "symbols": "symbol",
        "graph": "callgraph",
        "calls": "callgraph",
        "impact": "blastradius",
        "source": "code",
        "duplicate": "duplicates",
        "dupes": "duplicates",
    ]

    /// Gives the operations of the tool, in the order of the fused schema.
    ///
    /// The fused schema keeps the first description of a shared parameter
    /// name. Each shared name has the same description in each operation.
    ///
    /// - Returns: The type-erased operations.
    static func operations() -> [AnyOperation<CodeContextToolContext>] {
        [
            AnyOperation(GetSymbolOperation.self),
            AnyOperation(SearchSymbolOperation.self),
            AnyOperation(ListSymbolOperation.self),
            AnyOperation(GetCallgraphOperation.self),
            AnyOperation(GetBlastradiusOperation.self),
        ]
    }

    /// Makes the `code_search` tool for one `CodeContext`.
    ///
    /// - Parameter context: The tool context that each operation receives.
    /// - Returns: The fused tool, with the alias tables of the tool in its
    ///   resolver.
    /// - Throws: `SchemaFusionError` or `GenerationSchema.SchemaError` when the
    ///   schema fusion fails.
    static func make(context: CodeContextToolContext) throws -> OperationTool<CodeContextToolContext> {
        try OperationTool(
            name: name,
            description: description,
            context: context,
            operations: operations(),
            resolver: OperationResolver(verbAliases: verbAliases, nounAliases: nounAliases)
        )
    }
}

import FoundationModels
import Operations

/// The `code_search` tool: it finds symbols, walks the call graph, and
/// searches the text and the syntax tree of the workspace.
///
/// The tool fuses its operations into one `OperationTool`. The model selects
/// an operation with the `op` parameter, for example `get symbol`.
internal enum CodeSearchTool {
    /// The model-facing name of the tool.
    static let name = "code_search"

    /// The model-facing description of the tool.
    static let description =
        "Search the code of the workspace. Find symbols by name, list the symbols of a file, "
        + "walk the call graph of a symbol, find the blast radius of a change, match a regular "
        + "expression, search with free text, find near-duplicate code, and run a tree-sitter query."

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
            AnyOperation(GrepCodeOperation.self),
            AnyOperation(SearchCodeOperation.self),
            AnyOperation(FindDuplicatesOperation.self),
            AnyOperation(QueryAstOperation.self),
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
        try ToolSupport.makeOperationTool(
            name: name,
            description: description,
            verbAliases: verbAliases,
            nounAliases: nounAliases,
            operations: operations(),
            context: context
        )
    }
}

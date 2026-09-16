import FoundationModels
import Operations

/// The `code_navigation` tool: it moves through the code from a position in a
/// file.
///
/// The tool fuses its operations into one `OperationTool`. The model selects
/// an operation with the `op` parameter, for example `get definition`.
///
/// Each position gives a file, a line and a character. Without a running
/// language server the operations use the LSP index, and then tree-sitter. The
/// `sourceLayer` of each result tells which layer gave the data.
internal enum CodeNavigationTool {
    /// The model-facing name of the tool.
    static let name = "code_navigation"

    /// The model-facing description of the tool.
    static let description =
        "Move through the code from a position in a file: `get definition` finds the declaration of the symbol, "
        + "`get type_definition` finds the declaration of its type, `get hover` gives its type, signature or "
        + "documentation, `get references` finds each place that uses it, and `get implementations` finds each "
        + "implementation of it. Each result tells which layer gave the data."

    /// The verb aliases of the tool, from the alias to the real verb.
    ///
    /// No key is a real verb of the tool: the resolver applies an alias before
    /// it compares, so such a key would send a real operation to a different
    /// operation.
    static let verbAliases: [String: String] = [
        "find": "get",
        "lookup": "get",
        "goto": "get",
        "list": "get",
        "check": "get",
        "query": "search",
    ]

    /// The noun aliases of the tool, from the alias to the real noun.
    ///
    /// No key is a real noun of the tool, for the same reason as
    /// `verbAliases`.
    static let nounAliases: [String: String] = [
        "def": "definition",
        "typedef": "type_definition",
        "type": "type_definition",
        "info": "hover",
        "docs": "hover",
        "reference": "references",
        "refs": "references",
        "usages": "references",
        "implementation": "implementations",
        "impls": "implementations",
        "code_action": "code_actions",
        "actions": "code_actions",
        "fixes": "code_actions",
        "rename": "rename_edits",
        "inbound_call": "inbound_calls",
        "incoming_calls": "inbound_calls",
        "callers": "inbound_calls",
        "workspace_symbols": "workspace_symbol",
        "symbol": "workspace_symbol",
        "symbols": "workspace_symbol",
        "diagnostic": "diagnostics",
        "errors": "diagnostics",
        "problems": "diagnostics",
    ]

    /// Gives the operations of the tool, in the order of the fused schema.
    ///
    /// The fused schema keeps the first description of a shared parameter
    /// name. Each shared name has the same description in each operation.
    ///
    /// - Returns: The type-erased operations.
    static func operations() -> [AnyOperation<CodeContextToolContext>] {
        [
            AnyOperation(GetDefinitionOperation.self),
            AnyOperation(GetTypeDefinitionOperation.self),
            AnyOperation(GetHoverOperation.self),
            AnyOperation(GetReferencesOperation.self),
            AnyOperation(GetImplementationsOperation.self),
        ]
    }

    /// Makes the `code_navigation` tool for one `CodeContext`.
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

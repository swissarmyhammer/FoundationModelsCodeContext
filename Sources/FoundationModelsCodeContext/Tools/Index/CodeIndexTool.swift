import FoundationModels
import Operations

/// The `code_index` tool: it reports the state of the index and of the
/// language servers, and it rebuilds the index.
///
/// The tool fuses its operations into one `OperationTool`. The model selects
/// an operation with the `op` parameter, for example `get status`.
internal enum CodeIndexTool {
    /// The model-facing name of the tool.
    static let name = "code_index"

    /// The model-facing description of the tool.
    static let description =
        "Report and control the index of the workspace: `get status` gives the progress of the index, "
        + "`get lsp_status` gives the state of each language server, `rebuild index` marks the files of one "
        + "layer dirty so that the workspace indexes them again, and `detect projects` finds the language of "
        + "each project of the workspace."

    /// The verb aliases of the tool, from the alias to the real verb.
    ///
    /// No key is a real verb of the tool: the resolver applies an alias before
    /// it compares, so such a key would send a real operation to a different
    /// operation.
    static let verbAliases: [String: String] = [
        "check": "get",
        "refresh": "rebuild",
        "scan": "detect",
        "discover": "detect",
        "find": "detect",
        "list": "detect",
    ]

    /// The noun aliases of the tool, from the alias to the real noun.
    ///
    /// No key is a real noun of the tool, for the same reason as
    /// `verbAliases`. `index` is not a key, because it is the real noun of
    /// `rebuild index`.
    static let nounAliases: [String: String] = [
        "state": "status",
        "progress": "status",
        "index_status": "status",
        "lsp": "lsp_status",
        "servers": "lsp_status",
        "server_status": "lsp_status",
        "language_servers": "lsp_status",
        "project": "projects",
        "languages": "projects",
    ]

    /// Gives the operations of the tool, in the order of the fused schema.
    ///
    /// The fused schema keeps the first description of a shared parameter
    /// name. No two operations of this tool share a parameter name.
    ///
    /// - Returns: The type-erased operations.
    static func operations() -> [AnyOperation<CodeContextToolContext>] {
        [
            AnyOperation(GetStatusOperation.self),
            AnyOperation(GetLspStatusOperation.self),
            AnyOperation(RebuildIndexOperation.self),
            AnyOperation(DetectProjectsOperation.self),
        ]
    }

    /// Makes the `code_index` tool for one `CodeContext`.
    ///
    /// - Parameters:
    ///   - context: The tool context that each operation receives.
    ///   - includesSchemaInInstructions: Whether FoundationModels adds the
    ///     schema of the tool to the prompt.
    /// - Returns: The fused tool, with the alias tables of the tool in its
    ///   resolver.
    /// - Throws: `SchemaFusionError` or `GenerationSchema.SchemaError` when the
    ///   schema fusion fails.
    static func make(
        context: CodeContextToolContext,
        includesSchemaInInstructions: Bool = CodeContextDefaults.includesSchemaInInstructions
    ) throws -> OperationTool<CodeContextToolContext> {
        try ToolSupport.makeOperationTool(
            name: name,
            description: description,
            verbAliases: verbAliases,
            nounAliases: nounAliases,
            operations: operations(),
            context: context,
            includesSchemaInInstructions: includesSchemaInInstructions
        )
    }
}

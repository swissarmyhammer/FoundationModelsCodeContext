import FoundationModels
import Operations

/// The FoundationModels tools of this package.
///
/// This is the one way in for a host: `make(context:includesSchemaInInstructions:)`
/// gives the three tools of one `CodeContext`, and the host gives them to a
/// `LanguageModelSession`. The tool types and the operation types stay
/// internal, so the host needs no `import Operations`.
///
/// ```swift
/// let tools = try CodeContextTools.make(context: codeContext)
/// let session = LanguageModelSession(tools: tools, instructions: instructions)
/// ```
public enum CodeContextTools {
    /// The names of the three tools, in the order of
    /// `make(context:includesSchemaInInstructions:)`.
    public static let toolNames: [String] = [
        CodeSearchTool.name,
        CodeNavigationTool.name,
        CodeIndexTool.name,
    ]

    /// The op strings of each tool, with the name of the tool as the key.
    ///
    /// Each list has the op strings of one tool, in the order of the fused
    /// schema of that tool. The lists come from the operations of each tool,
    /// so they cannot move away from them. Code outside this module can thus
    /// list the operations without an `import Operations`.
    public static let operationNames: [String: [String]] = [
        CodeSearchTool.name: CodeSearchTool.operations().map(\.opString),
        CodeNavigationTool.name: CodeNavigationTool.operations().map(\.opString),
        CodeIndexTool.name: CodeIndexTool.operations().map(\.opString),
    ]

    /// Makes the three tools of one `CodeContext`.
    ///
    /// The three tools share one tool context, thus they all operate on the
    /// same workspace.
    ///
    /// - Parameters:
    ///   - context: The `CodeContext` that each operation calls.
    ///   - includesSchemaInInstructions: Whether FoundationModels adds the
    ///     schema of each tool to the prompt. The schema of a fused tool is
    ///     large, so a host that gives the operations to the model in its own
    ///     instructions can make this `false`.
    /// - Returns: The `code_search`, `code_navigation` and `code_index` tools,
    ///   in the order of `toolNames`.
    /// - Throws: `SchemaFusionError` or `GenerationSchema.SchemaError` when the
    ///   schema fusion of a tool fails.
    public static func make<Connection: LanguageServerConnection>(
        context: CodeContext<Connection>,
        includesSchemaInInstructions: Bool = CodeContextDefaults.includesSchemaInInstructions
    ) throws -> [any Tool] {
        let toolContext = CodeContextToolContext(operating: context)
        return [
            try CodeSearchTool.make(context: toolContext, includesSchemaInInstructions: includesSchemaInInstructions),
            try CodeNavigationTool.make(context: toolContext, includesSchemaInInstructions: includesSchemaInInstructions),
            try CodeIndexTool.make(context: toolContext, includesSchemaInInstructions: includesSchemaInInstructions),
        ]
    }
}

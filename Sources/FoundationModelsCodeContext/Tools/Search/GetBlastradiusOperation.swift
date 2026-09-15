import FoundationModels
import Operations

/// The `get blastradius` operation of the `code_search` tool.
///
/// It finds the symbols and the files that a change to one file, or to one
/// symbol of that file, can affect.
@Generable
@Operation(
    verb: "get",
    noun: "blastradius",
    description: "Find the symbols and the files that a change to one file, or to one symbol of that file, can affect."
)
internal struct GetBlastradiusOperation {
    /// The file that changes.
    @Guide(description: "A file path relative to the workspace root.")
    @OperationParam(aliases: ["path", "filePath", "filename"])
    var file: String

    /// The symbol inside `file` that changes, or `nil` for all the symbols of
    /// the file.
    @Guide(
        description:
            "For `get callgraph`: a symbol name, or a `<file>:<line>:<column>` locator with 0-based numbers. For `get blastradius`: the name of a symbol inside `file`."
    )
    @OperationParam(aliases: ["name"])
    var symbol: String?

    /// The maximum number of call-edge hops, or `nil` for the default.
    @Guide(description: "The maximum number of call-edge hops to walk from the changed symbols.")
    @OperationParam(aliases: ["hops", "depth"])
    var maxHops: Int?
}

extension GetBlastradiusOperation {
    /// Calls `blastRadius(file:symbol:maxHops:)`.
    ///
    /// - Parameter context: The tool context.
    /// - Returns: The engine result, or a corrective message.
    /// - Throws: An error that the model cannot correct.
    func execute(in context: CodeContextToolContext) async throws -> ToolOutcome<BlastRadius> {
        try await ToolSupport.outcome {
            try await context.operating.blastRadius(
                file: file,
                symbol: symbol,
                maxHops: maxHops ?? CodeContextDefaults.blastRadiusMaxHops
            )
        }
    }
}

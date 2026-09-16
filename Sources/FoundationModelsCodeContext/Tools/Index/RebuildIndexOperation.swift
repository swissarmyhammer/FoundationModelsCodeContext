import FoundationModels
import Operations

/// The `rebuild index` operation of the `code_index` tool.
///
/// It marks the files of one layer dirty. The workspace then indexes those
/// files again.
@Generable
@Operation(
    verb: "rebuild",
    noun: "index",
    description: "Mark the files of one index layer dirty, so that the workspace indexes them again."
)
internal struct RebuildIndexOperation {
    /// The name of the layer to rebuild.
    @Guide(
        description: "The layer to rebuild: treesitter (the tree-sitter layer), lsp (the language-server layer), embedding (the embedding layer), or all (each layer).",
        .anyOf(["treesitter", "lsp", "embedding", "all"])
    )
    @OperationParam(aliases: ["target"])
    var layer: String
}

extension RebuildIndexOperation {
    /// The allowed names of `layer`, and the layer of each name.
    ///
    /// The raw value of each `RebuildLayer` case is the name of that case, so
    /// the table comes from the enum itself and cannot move away from it. The
    /// match ignores `_`, thus `tree_sitter` also finds `treesitter`.
    private static let layerChoices = ToolSupport.choiceTable(for: RebuildLayer.self)

    /// Calls `rebuildIndex(layer:)`.
    ///
    /// The operation parses `layer`. A name that the table does not hold gives
    /// a corrective message, and the engine call does not run.
    ///
    /// - Parameter context: The tool context.
    /// - Returns: The engine result, or a corrective message.
    /// - Throws: An error that the model cannot correct.
    func execute(in context: CodeContextToolContext) async throws -> ToolOutcome<RebuildIndexResult> {
        let parse = ToolSupport.parseChoice(layer, choices: Self.layerChoices, parameter: "layer")
        return try await ToolSupport.outcome(after: parse) { rebuildLayer in
            try await context.operating.rebuildIndex(layer: rebuildLayer)
        }
    }
}

import FoundationModels
import Operations

/// The `get rename_edits` operation of the `code_navigation` tool.
///
/// It gives the edits of a rename of the symbol at a position. It returns the
/// edits only, and it changes no file.
@Generable
@Operation(
    verb: "get",
    noun: "rename_edits",
    description: "Give the edits of a rename of the symbol at a position in a file. The operation changes no file."
)
internal struct GetRenameEditsOperation {
    /// The file that holds the position.
    @Guide(
        description:
            "A file path relative to the workspace root. `get diagnostics` also accepts an absolute path or a glob."
    )
    @OperationParam(aliases: ["path", "filePath", "filename"])
    var file: String

    /// The line of the position.
    @Guide(description: "The line of the position in the file. The first line is line 0.")
    @OperationParam(aliases: ["row"])
    var line: Int

    /// The character offset of the position in its line.
    @Guide(
        description:
            "The character offset of the position in its line, in UTF-16 units. The first character is character 0."
    )
    @OperationParam(aliases: ["column", "col"])
    var character: Int

    /// The new name of the symbol.
    @Guide(description: "The new name of the symbol at the position.")
    @OperationParam(aliases: ["name", "to", "newSymbol"])
    var newName: String
}

extension GetRenameEditsOperation {
    /// Calls `renameEdits(filePath:line:character:newName:)`.
    ///
    /// The result gives the edits of the rename. The operation writes no file,
    /// so the model applies the edits itself.
    ///
    /// - Parameter context: The tool context.
    /// - Returns: The engine result, or a corrective message.
    /// - Throws: An error that the model cannot correct.
    func execute(in context: CodeContextToolContext) async throws -> ToolOutcome<RenameEditsResult> {
        try await ToolSupport.outcome {
            try await context.operating.renameEdits(
                filePath: file,
                line: line,
                character: character,
                newName: newName
            )
        }
    }
}

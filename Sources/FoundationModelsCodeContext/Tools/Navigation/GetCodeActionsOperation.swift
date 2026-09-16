import FoundationModels
import Operations

/// The `get code_actions` operation of the `code_navigation` tool.
///
/// It finds the code actions of a range in a file, for example a quick fix or
/// a refactor.
///
/// The operation does not take diagnostics, because a `Diagnostic` is not a
/// supported parameter type. It gives an empty list of diagnostics to the
/// engine.
@Generable
@Operation(
    verb: "get",
    noun: "code_actions",
    description: "Find the code actions of a range in a file, for example a quick fix or a refactor."
)
internal struct GetCodeActionsOperation {
    /// The file that holds the range.
    @Guide(
        description:
            "A file path relative to the workspace root. `get diagnostics` also accepts an absolute path or a glob."
    )
    @OperationParam(aliases: ["path", "filePath", "filename"])
    var file: String

    /// The line where the range starts.
    @Guide(description: "The line where the range starts in the file. The first line is line 0.")
    @OperationParam(aliases: ["fromLine", "startRow"])
    var startLine: Int

    /// The character offset where the range starts in its line.
    @Guide(
        description:
            "The character offset where the range starts in its line, in UTF-16 units. The first character is character 0."
    )
    @OperationParam(aliases: ["startColumn", "fromColumn"])
    var startCharacter: Int

    /// The line where the range ends.
    @Guide(description: "The line where the range ends in the file. The first line is line 0.")
    @OperationParam(aliases: ["toLine", "endRow"])
    var endLine: Int

    /// The character offset where the range ends in its line.
    @Guide(
        description:
            "The character offset where the range ends in its line, in UTF-16 units. The first character is character 0."
    )
    @OperationParam(aliases: ["endColumn", "toColumn"])
    var endCharacter: Int

    /// The kinds of code action to keep, or `nil` for all the kinds.
    @Guide(
        description:
            "The kinds of code action to keep, for example quickfix or refactor. If you give no kind, the operation gives all the kinds."
    )
    @OperationParam(aliases: ["kinds", "actionKinds"])
    var only: [String]?
}

extension GetCodeActionsOperation {
    /// Calls `codeActions(filePath:startLine:startCharacter:endLine:endCharacter:diagnostics:only:)`.
    ///
    /// The call gives an empty list of diagnostics, because the operation has
    /// no diagnostics parameter: a `Diagnostic` is not a supported parameter
    /// type.
    ///
    /// - Parameter context: The tool context.
    /// - Returns: The engine result, or a corrective message.
    /// - Throws: An error that the model cannot correct.
    func execute(in context: CodeContextToolContext) async throws -> ToolOutcome<CodeActionsResult> {
        try await ToolSupport.outcome {
            try await context.operating.codeActions(
                filePath: file,
                startLine: startLine,
                startCharacter: startCharacter,
                endLine: endLine,
                endCharacter: endCharacter,
                diagnostics: [],
                only: only
            )
        }
    }
}

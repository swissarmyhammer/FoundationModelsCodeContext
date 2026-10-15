/// The kind of scope that the `scope` parameter of a tool operation selects.
///
/// The `get diagnostics` operation of `code_navigation` and the
/// `get blastradius` operation of `code_search` use the same scope names.
/// Thus this one type holds the names, the choice table and the corrective
/// message that the two operations share.
internal enum ToolScopeKind: String, CaseIterable {
    /// Each file that the working tree changes.
    case working

    /// The file, or the glob, of the `file` parameter.
    case file

    /// The files that the commit of the `sha` parameter changes.
    case sha

    /// The allowed names of `scope`, and the scope kind of each name, in the
    /// order of the cases.
    static let choices = ToolSupport.choiceTable(for: ToolScopeKind.self)

    /// The corrective message for the scope `sha` with no `sha` parameter.
    static let missingShaMessage =
        "Give the parameter `sha` for the scope `sha`. It accepts a commit name or a `<from>..<to>` range."

    /// Makes the scope `sha` of an engine call from the `sha` parameter.
    ///
    /// - Parameter sha: The `sha` parameter that the model gave, or `nil`
    ///   when the model gave no commit.
    /// - Returns: `.value(_:)` with the scope, or `.corrective(_:)` when
    ///   `sha` is `nil`.
    static func shaScope(_ sha: String?) -> ChoiceParse<DiagnosticsScope> {
        guard let sha else {
            return .corrective(missingShaMessage)
        }
        return .value(.sha(sha))
    }
}

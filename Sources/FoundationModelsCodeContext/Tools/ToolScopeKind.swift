/// The kind of scope that the `scope` parameter of a tool operation selects.
///
/// The `get diagnostics` operation of `code_navigation` and the
/// `get blastradius` operation of `code_search` use the same scope names.
/// Thus this one type holds the names, the choice table, the corrective
/// messages and the scope of each kind that the two operations share.
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

    /// The corrective message for the scope `file` with no `file` parameter.
    ///
    /// The text names only the forms of `file` that each operation accepts:
    /// a path relative to the workspace root, and a glob.
    static let missingFileMessage =
        "Give the parameter `file` for the scope `file`. It accepts a path relative to the workspace root or a glob. "
        + "For a different set of files, give the scope `working` or `sha`."

    /// The corrective message for the scope `sha` with no `sha` parameter.
    static let missingShaMessage =
        "Give the parameter `sha` for the scope `sha`. It accepts a commit name or a `<from>..<to>` range."

    /// Makes the scope of an engine call for this kind, when the kind does not
    /// read the `file` parameter.
    ///
    /// Each operation reads `file` in its own way. Thus the kind `file` has no
    /// shared scope, and the operation makes that scope itself. When `file`
    /// is `nil`, each operation gives `missingFileMessage`.
    ///
    /// - Parameter sha: The `sha` parameter that the model gave, or `nil`
    ///   when the model gave no commit.
    /// - Returns: `nil` for the kind `file`. For each other kind, `.value(_:)`
    ///   with the scope, or `.corrective(_:)` for the kind `sha` when `sha` is
    ///   `nil`.
    func scope(sha: String?) -> ChoiceParse<DiagnosticsScope>? {
        switch self {
        case .working:
            return .value(.workingTree)
        case .file:
            return nil
        case .sha:
            guard let sha else {
                return .corrective(Self.missingShaMessage)
            }
            return .value(.sha(sha))
        }
    }
}

import FoundationModels
import Operations

/// The `get diagnostics` operation of the `code_navigation` tool.
///
/// It gives the errors and the warnings of a scope: the working tree, one file
/// or a glob, or the files that a commit changed.
@Generable
@Operation(
    verb: "get",
    noun: "diagnostics",
    description: "Give the errors and the warnings of a scope: the working tree, one file or a glob, or the files that a commit changed."
)
internal struct GetDiagnosticsOperation {
    /// The name of the scope to diagnose.
    @Guide(
        description:
            "The scope to diagnose: working (each file that the working tree changes), file (the file or the glob of `file`), or sha (the files that the commit of `sha` changes).",
        .anyOf(["working", "file", "sha"])
    )
    @OperationParam(aliases: ["mode"])
    var scope: String

    /// The file of the scope `file`, or `nil` for each other scope.
    @Guide(
        description:
            "A file path relative to the workspace root. `get diagnostics` also accepts an absolute path or a glob."
    )
    @OperationParam(aliases: ["path", "filePath", "filename"])
    var file: String?

    /// The commit of the scope `sha`, or `nil` for each other scope.
    @Guide(
        description:
            "The commit of the scope sha: a commit name, or a `<from>..<to>` range."
    )
    @OperationParam(aliases: ["ref", "commit", "revision", "range"])
    var sha: String?

    /// The lowest severity to report, or `nil` for the default.
    @Guide(
        description: "The lowest severity to report: error, warning, information or hint.",
        .anyOf(["error", "warning", "information", "hint"])
    )
    @OperationParam(aliases: ["level", "minSeverity"])
    var severity: String?
}

extension GetDiagnosticsOperation {
    /// The kind of scope that a name of `scope` selects.
    private enum ScopeKind {
        /// Each file that the working tree changes.
        case working

        /// The file, the absolute path or the glob of `file`.
        case file

        /// The files that the commit of `sha` changes.
        case sha
    }

    /// The allowed names of `scope`, and the scope kind of each name.
    private static let scopeChoices: [(name: String, value: ScopeKind)] = [
        (name: "working", value: .working),
        (name: "file", value: .file),
        (name: "sha", value: .sha),
    ]

    /// The allowed names of `severity`, and the severity of each name.
    private static let severityChoices: [(name: String, value: DiagnosticSeverity)] = [
        (name: "error", value: .error),
        (name: "warning", value: .warning),
        (name: "information", value: .information),
        (name: "hint", value: .hint),
    ]

    /// Calls `diagnostics(scope:severity:includeDependents:settleWindow:hardTimeout:perReportCap:)`.
    ///
    /// The operation parses `scope` and `severity`. A name that no table holds,
    /// and a scope with no `file` or no `sha`, give a corrective message, and
    /// the engine call does not run.
    ///
    /// - Parameter context: The tool context.
    /// - Returns: The engine result, or a corrective message.
    /// - Throws: An error that the model cannot correct.
    func execute(in context: CodeContextToolContext) async throws -> ToolOutcome<DiagnosticsReport> {
        switch parsedScope() {
        case .corrective(let message):
            return .corrective(message)
        case .value(let reportScope):
            let parse = ToolSupport.parseOptionalChoice(severity, choices: Self.severityChoices, parameter: "severity")
            return try await ToolSupport.outcome(after: parse) { lowestSeverity in
                try await context.operating.diagnostics(
                    scope: reportScope,
                    severity: lowestSeverity ?? CodeContextDefaults.diagnosticsSeverity,
                    includeDependents: CodeContextDefaults.diagnosticsIncludeDependents,
                    settleWindow: CodeContextDefaults.diagnosticsSettleWindow,
                    hardTimeout: CodeContextDefaults.diagnosticsHardTimeout,
                    perReportCap: CodeContextDefaults.diagnosticsPerReportCap
                )
            }
        }
    }

    /// Parses `scope` and makes the scope of the engine call.
    ///
    /// - Returns: `.value(_:)` with the scope, or `.corrective(_:)` when the
    ///   name of the scope is not valid, or when the scope has no file and no
    ///   commit.
    private func parsedScope() -> ChoiceParse<DiagnosticsScope> {
        switch ToolSupport.parseChoice(scope, choices: Self.scopeChoices, parameter: "scope") {
        case .corrective(let message):
            return .corrective(message)
        case .value(let kind):
            return reportScope(of: kind)
        }
    }

    /// Makes the scope of the engine call from a scope kind.
    ///
    /// - Parameter kind: The scope kind that `scope` selects.
    /// - Returns: `.value(_:)` with the scope, or `.corrective(_:)` when the
    ///   scope kind needs a parameter that the model did not give.
    private func reportScope(of kind: ScopeKind) -> ChoiceParse<DiagnosticsScope> {
        switch kind {
        case .working:
            return .value(.workingTree)
        case .file:
            guard let file else {
                return .corrective(
                    "Give the parameter `file` for the scope `file`. It accepts a path relative to the workspace root, an absolute path or a glob."
                )
            }
            return .value(.file(file))
        case .sha:
            guard let sha else {
                return .corrective(
                    "Give the parameter `sha` for the scope `sha`. It accepts a commit name or a `<from>..<to>` range."
                )
            }
            return .value(.sha(sha))
        }
    }
}

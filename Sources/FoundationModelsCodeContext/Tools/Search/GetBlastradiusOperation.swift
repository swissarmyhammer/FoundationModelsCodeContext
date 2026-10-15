import FoundationModels
import Operations

/// The `get blastradius` operation of the `code_search` tool.
///
/// It finds the symbols and the files that a change can affect. The change is
/// one file or one symbol of that file, the files of a glob, each file that
/// the working tree changes, or the files that a commit changes.
@Generable
@Operation(
    verb: "get",
    noun: "blastradius",
    description:
        "Find the symbols and the files that a change can affect. The scope is file (one file, or one symbol of that file, or the files of a glob), working (each file that the working tree changes), or sha (the files that a commit changes)."
)
internal struct GetBlastradiusOperation {
    /// The name of the scope, or `nil` for the scope `file`.
    @Guide(
        description:
            "The scope of the change: working (each file that the working tree changes), file (the file or the glob of `file`), or sha (the files that the commit of `sha` changes).",
        .anyOf(["working", "file", "sha"])
    )
    @OperationParam(aliases: ["mode"])
    var scope: String?

    /// The file that changes, or the glob of the files that change. Only for
    /// the scope `file`.
    @Guide(description: "A file path relative to the workspace root.")
    @OperationParam(aliases: ["path", "filePath", "filename"])
    var file: String?

    /// The symbol inside `file` that changes, or `nil` for all the symbols of
    /// the file. Only for a `file` that is one path.
    @Guide(
        description:
            "For `get callgraph`: a symbol name, or a `<file>:<line>:<column>` locator with 0-based numbers. For `get blastradius`: the name of a symbol inside `file`."
    )
    @OperationParam(aliases: ["name"])
    var symbol: String?

    /// The commit of the scope `sha`, or `nil` for each other scope.
    @Guide(
        description:
            "The commit of the scope sha: a commit name, or a `<from>..<to>` range."
    )
    @OperationParam(aliases: ["ref", "commit", "revision", "range"])
    var sha: String?

    /// The maximum number of call-edge hops, or `nil` for the default.
    @Guide(description: "The maximum number of call-edge hops to walk from the changed symbols.")
    @OperationParam(aliases: ["hops", "depth"])
    var maxHops: Int?
}

extension GetBlastradiusOperation {
    /// The files that one call starts from, and thus the engine method that
    /// the call runs.
    private enum Target {
        /// One file that is a path, and an optional symbol of that file. The
        /// call runs `blastRadius(file:symbol:maxHops:)`.
        case file(String, symbol: String?)

        /// A set of files. The call runs `blastRadius(scope:maxHops:)`.
        case scope(DiagnosticsScope)
    }

    /// The corrective message for the scope `file` with no `file` parameter.
    private static let missingFileMessage =
        "Give the parameter `file` for the scope `file`, or give the scope `working` or `sha`. "
        + "`file` accepts a path relative to the workspace root or a glob."

    /// The name of a glob in the corrective message for a `symbol` that the
    /// call cannot use.
    private static let globOwner = "a glob"

    /// Calls `blastRadius(file:symbol:maxHops:)` for one file, or
    /// `blastRadius(scope:maxHops:)` for a set of files.
    ///
    /// No scope is the same as the scope `file`. A `file` that is one path
    /// keeps the call of `blastRadius(file:symbol:maxHops:)`. A glob, the
    /// scope `working` and the scope `sha` call `blastRadius(scope:maxHops:)`.
    /// A name that is not a scope, a missing `file` or `sha`, and a `symbol`
    /// for a set of files give a corrective message, and the engine call does
    /// not run.
    ///
    /// - Parameter context: The tool context.
    /// - Returns: The engine result, or a corrective message.
    /// - Throws: An error that the model cannot correct.
    func execute(in context: CodeContextToolContext) async throws -> ToolOutcome<BlastRadius> {
        let hops = maxHops ?? CodeContextDefaults.blastRadiusMaxHops
        return try await ToolSupport.outcome(after: parsedTarget()) { target in
            switch target {
            case .file(let path, let symbol):
                return try await context.operating.blastRadius(file: path, symbol: symbol, maxHops: hops)
            case .scope(let scope):
                return try await context.operating.blastRadius(scope: scope, maxHops: hops)
            }
        }
    }

    /// Parses `scope` and makes the target of the engine call.
    ///
    /// - Returns: `.value(_:)` with the target, or `.corrective(_:)` when the
    ///   name of the scope is not valid, or when the parameters do not fit
    ///   the scope.
    private func parsedTarget() -> ChoiceParse<Target> {
        switch ToolSupport.parseOptionalChoice(scope, choices: ToolScopeKind.choices, parameter: "scope") {
        case .corrective(let message):
            return .corrective(message)
        case .value(let kind):
            return target(of: kind ?? .file)
        }
    }

    /// Makes the target of the engine call from a scope kind.
    ///
    /// - Parameter kind: The scope kind that `scope` selects.
    /// - Returns: `.value(_:)` with the target, or `.corrective(_:)` when the
    ///   parameters do not fit the scope.
    private func target(of kind: ToolScopeKind) -> ChoiceParse<Target> {
        switch kind {
        case .working:
            return scopeTarget(.value(.workingTree), owner: Self.scopeOwner(of: kind))
        case .file:
            return fileTarget()
        case .sha:
            return scopeTarget(ToolScopeKind.shaScope(sha), owner: Self.scopeOwner(of: kind))
        }
    }

    /// Makes the target of the scope `file`.
    ///
    /// - Returns: `.value(_:)` with one file for a path, or with the scope
    ///   `file` for a glob. `.corrective(_:)` when `file` is `nil`, or when a
    ///   glob has a `symbol`.
    private func fileTarget() -> ChoiceParse<Target> {
        guard let file else {
            return .corrective(Self.missingFileMessage)
        }
        guard GlobExpansion.isGlob(file) else {
            return .value(.file(file, symbol: symbol))
        }
        return scopeTarget(.value(.file(file)), owner: Self.globOwner)
    }

    /// Makes the target of a set of files.
    ///
    /// The engine call for a set of files has no symbol. Thus a `symbol`
    /// gives a corrective message, and the operation does not drop it
    /// silently.
    ///
    /// - Parameters:
    ///   - parse: The scope of the set of files, or the corrective message of
    ///     its parse.
    ///   - owner: The name of the scope or of the glob, for the corrective
    ///     message, for example "the scope `working`".
    /// - Returns: `.value(_:)` with the scope, or `.corrective(_:)` when the
    ///   parse failed or when the call has a `symbol`.
    private func scopeTarget(_ parse: ChoiceParse<DiagnosticsScope>, owner: String) -> ChoiceParse<Target> {
        switch parse {
        case .corrective(let message):
            return .corrective(message)
        case .value(let scope):
            guard symbol == nil else {
                return .corrective(
                    "The parameter `symbol` is only for a `file` that is one path. Remove `symbol` for \(owner)."
                )
            }
            return .value(.scope(scope))
        }
    }

    /// Gives the name of a scope for a corrective message.
    ///
    /// - Parameter kind: The scope kind.
    /// - Returns: The name of the scope, for example "the scope `working`".
    private static func scopeOwner(of kind: ToolScopeKind) -> String {
        "the scope `\(kind.rawValue)`"
    }
}

import Foundation

/// The outcome of one tool operation: a success value, or a corrective
/// message for the model.
///
/// A recoverable failure, for example a symbol that is not in the index, does
/// not throw. `OperationTool` rethrows a thrown error, and that stops the turn
/// of the model. The operation returns `.corrective(_:)` instead, so that the
/// model can correct the call and try again.
internal enum ToolOutcome<Success: Encodable & Sendable>: Encodable, Sendable {
    /// A success. It encodes as the value.
    case success(Success)

    /// A recoverable failure. It encodes as a bare JSON string that tells the
    /// model what to correct.
    case corrective(String)

    /// Encodes the outcome.
    ///
    /// `.success(_:)` encodes the value itself. `.corrective(_:)` encodes the
    /// message as one JSON string.
    ///
    /// - Parameter encoder: The encoder that receives the outcome.
    /// - Throws: The error that `encoder` throws.
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .success(let value):
            try value.encode(to: encoder)
        case .corrective(let message):
            var container = encoder.singleValueContainer()
            try container.encode(message)
        }
    }
}

/// The result of `ToolSupport.parseChoice(_:choices:parameter:)`.
internal enum ChoiceParse<T> {
    /// The name matched a choice. The payload is the value of that choice.
    case value(T)

    /// The name matched no choice. The payload is a corrective message that
    /// lists the allowed names.
    case corrective(String)
}

/// Two parse results are equal when they have the same case and the same payload.
extension ChoiceParse: Equatable where T: Equatable {}

/// The shared helpers of the FoundationModels tool operations of this package.
internal enum ToolSupport {
    /// Gives the corrective message for a recoverable `CodeContextError`.
    ///
    /// The model can correct a recoverable error itself: it can change a name,
    /// a path, a pattern, a query or a commit, and try again. For these errors
    /// the operation returns the message as `ToolOutcome.corrective(_:)`. For
    /// each other error this function returns `nil`, and the operation throws
    /// the error.
    ///
    /// `.spawnFailed` is recoverable because a git command gives it, for
    /// example in a directory that is not a git repository, or for a commit
    /// that does not exist.
    ///
    /// - Parameter error: The error that a `CodeContext` operation threw.
    /// - Returns: The corrective message, or `nil` when the model cannot
    ///   correct the error.
    static func correctiveMessage(for error: CodeContextError) -> String? {
        switch error {
        case .notFound(let reason):
            "Not found: \(reason). Make sure that the name or the path is correct, then try again."
        case .pattern(let reason):
            "The pattern is not a valid regular expression: \(reason). Correct the pattern, then try again."
        case .query(let reason):
            "The AST query failed: \(reason). Correct the language or the query, then try again."
        case .spawnFailed(let reason):
            "A git command failed: \(reason). Make sure that the directory is a git repository and that the commit exists, then try again."
        case .binaryNotFound, .handshakeFailed, .timeout, .notRunning, .storage, .embedding, .overlappingRoot:
            nil
        }
    }

    /// Finds the choice whose name matches `raw`.
    ///
    /// The match ignores the letter case, `_` and `-`. Thus `type_definition`,
    /// `typeDefinition`, `TYPE-DEFINITION` and `typedefinition` all match the
    /// name `type_definition`. A table of names is necessary because some
    /// choice types have no usable raw names: `DiagnosticSeverity` has `Int`
    /// raw values.
    ///
    /// - Parameters:
    ///   - raw: The name that the model gave, or `nil` when the model gave no
    ///     name.
    ///   - choices: The allowed names and the value of each name.
    ///   - parameter: The name of the tool parameter, for the corrective
    ///     message.
    /// - Returns: `.value(_:)` with the value of the matching choice, or
    ///   `.corrective(_:)` with a message that lists the allowed names.
    static func parseChoice<T>(_ raw: String?, choices: [(name: String, value: T)], parameter: String) -> ChoiceParse<T> {
        guard let raw else {
            return .corrective("Give the parameter `\(parameter)`. Use one of: \(allowedNames(in: choices)).")
        }
        let key = normalizedChoiceName(raw)
        guard let match = choices.first(where: { normalizedChoiceName($0.name) == key }) else {
            return .corrective("`\(raw)` is not a valid value for `\(parameter)`. Use one of: \(allowedNames(in: choices)).")
        }
        return .value(match.value)
    }

    /// Gives the names of `choices`, in table order, with a comma between
    /// each two names.
    ///
    /// - Parameter choices: The choice table.
    /// - Returns: The list of names, for a corrective message.
    private static func allowedNames<T>(in choices: [(name: String, value: T)]) -> String {
        choices.map(\.name).joined(separator: ", ")
    }

    /// Makes a choice name comparable: all lowercase, with no `_` and no `-`.
    ///
    /// - Parameter name: A choice name, or the name that the model gave.
    /// - Returns: The comparable form of `name`.
    private static func normalizedChoiceName(_ name: String) -> String {
        String(name.lowercased().filter { $0 != "_" && $0 != "-" })
    }
}

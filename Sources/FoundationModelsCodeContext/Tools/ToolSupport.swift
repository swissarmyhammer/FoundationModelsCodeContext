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

    /// Finds the choice whose name matches `raw`, for an optional parameter.
    ///
    /// When the model gave no name, the result is `.value(nil)`. The operation
    /// then uses the default of the parameter. When the model gave a name, the
    /// match is the same as `parseChoice(_:choices:parameter:)`.
    ///
    /// - Parameters:
    ///   - raw: The name that the model gave, or `nil` when the model gave no
    ///     name.
    ///   - choices: The allowed names and the value of each name.
    ///   - parameter: The name of the tool parameter, for the corrective
    ///     message.
    /// - Returns: `.value(nil)` when `raw` is `nil`, `.value(_:)` with the
    ///   value of the matching choice, or `.corrective(_:)` with a message
    ///   that lists the allowed names.
    static func parseOptionalChoice<T>(
        _ raw: String?,
        choices: [(name: String, value: T)],
        parameter: String
    ) -> ChoiceParse<T?> {
        guard let raw else {
            return .value(nil)
        }
        switch parseChoice(raw, choices: choices, parameter: parameter) {
        case .value(let value):
            return .value(value)
        case .corrective(let message):
            return .corrective(message)
        }
    }

    /// Makes the choice table of an enum whose raw values are the names.
    ///
    /// Each case gives one row: the raw value is the name, and the case is the
    /// value. The rows are in the order of `allCases`.
    ///
    /// - Parameter type: The enum type.
    /// - Returns: The choice table, for `parseChoice(_:choices:parameter:)`.
    static func choiceTable<T: CaseIterable & RawRepresentable>(for type: T.Type) -> [(name: String, value: T)]
    where T.RawValue == String {
        type.allCases.map { (name: $0.rawValue, value: $0) }
    }

    /// Runs one `CodeContext` call and gives its outcome.
    ///
    /// A recoverable `CodeContextError` becomes `.corrective(_:)` with the
    /// message of `correctiveMessage(for:)`. Each other error is thrown again.
    ///
    /// - Parameter call: The `CodeContext` call.
    /// - Returns: `.success(_:)` with the result of `call`, or
    ///   `.corrective(_:)` when `call` threw a recoverable error.
    /// - Throws: The error that `call` threw, when the model cannot correct it.
    static func outcome<Success: Encodable & Sendable>(
        of call: () async throws -> Success
    ) async throws -> ToolOutcome<Success> {
        do {
            return .success(try await call())
        } catch let error as CodeContextError {
            guard let message = correctiveMessage(for: error) else {
                throw error
            }
            return .corrective(message)
        }
    }

    /// Runs one `CodeContext` call with a parsed choice and gives its outcome.
    ///
    /// When `parse` is `.corrective(_:)`, the call does not run, and the
    /// outcome is the same corrective message. When `parse` is `.value(_:)`,
    /// the call runs with the value, as in `outcome(of:)`.
    ///
    /// - Parameters:
    ///   - parse: The result of the parse of a choice parameter.
    ///   - call: The `CodeContext` call. It receives the parsed value.
    /// - Returns: `.success(_:)` with the result of `call`, or
    ///   `.corrective(_:)` when the parse failed or `call` threw a recoverable
    ///   error.
    /// - Throws: The error that `call` threw, when the model cannot correct it.
    static func outcome<Choice, Success: Encodable & Sendable>(
        after parse: ChoiceParse<Choice>,
        of call: (Choice) async throws -> Success
    ) async throws -> ToolOutcome<Success> {
        switch parse {
        case .corrective(let message):
            return .corrective(message)
        case .value(let choice):
            return try await outcome { try await call(choice) }
        }
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

import Foundation
import Testing

@testable import FoundationModelsCodeContext

/// Tests the shared helpers of the tool operations: `ToolOutcome`,
/// `ToolSupport.correctiveMessage(for:)`,
/// `ToolSupport.parseChoice(_:choices:parameter:)` and `CodeContextDefaults`.
struct ToolSupportTests {
    /// The values of the test choice table.
    private enum Kind: Equatable {
        case workingTree
        case typeDefinition
        case file
    }

    /// A choice table with two multi-word names and one single-word name.
    private static let kindChoices: [(name: String, value: Kind)] = [
        (name: "working_tree", value: .workingTree),
        (name: "type_definition", value: .typeDefinition),
        (name: "file", value: .file),
    ]

    /// The severity table, because `DiagnosticSeverity` has `Int` raw values.
    private static let severityChoices: [(name: String, value: DiagnosticSeverity)] = [
        (name: "error", value: .error),
        (name: "warning", value: .warning),
        (name: "information", value: .information),
        (name: "hint", value: .hint),
    ]

    /// Encodes `value` with `.sortedKeys` and returns the JSON text.
    ///
    /// - Parameter value: The value to encode.
    /// - Returns: The JSON text.
    /// - Throws: An `EncodingError` when `value` cannot be encoded.
    private static func encodedText<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try #require(String(data: try encoder.encode(value), encoding: .utf8))
    }

    // MARK: - ToolOutcome

    @Test
    func successOutcomeEncodesTheValue() throws {
        let progress = IndexProgress(filesWalked: 4, filesParsed: 3, filesEmbedded: 2, filesLspIndexed: 1)

        let text = try Self.encodedText(ToolOutcome.success(progress))

        #expect(text == (try Self.encodedText(progress)))
        #expect(text == #"{"filesEmbedded":2,"filesLspIndexed":1,"filesParsed":3,"filesWalked":4,"isEmbeddingEnabled":true}"#)
    }

    @Test
    func correctiveOutcomeEncodesABareString() throws {
        let outcome = ToolOutcome<IndexProgress>.corrective("Correct the path, then try again.")

        #expect(try Self.encodedText(outcome) == #""Correct the path, then try again.""#)
    }

    // MARK: - parseChoice

    @Test
    func parseChoiceAcceptsEachNameInAnyCaseAndSeparator() {
        let spellings: [(raw: String, expected: Kind)] = [
            (raw: "working_tree", expected: .workingTree),
            (raw: "WORKING_TREE", expected: .workingTree),
            (raw: "workingtree", expected: .workingTree),
            (raw: "workingTree", expected: .workingTree),
            (raw: "Working-Tree", expected: .workingTree),
            (raw: "type_definition", expected: .typeDefinition),
            (raw: "TypeDefinition", expected: .typeDefinition),
            (raw: "type-definition", expected: .typeDefinition),
            (raw: "file", expected: .file),
            (raw: "FILE", expected: .file),
        ]

        for spelling in spellings {
            let parse = ToolSupport.parseChoice(spelling.raw, choices: Self.kindChoices, parameter: "scope")
            #expect(parse == .value(spelling.expected), "raw name: \(spelling.raw)")
        }
        #expect(ToolSupport.parseChoice("Warning", choices: Self.severityChoices, parameter: "severity") == .value(.warning))
        #expect(ToolSupport.parseChoice("HINT", choices: Self.severityChoices, parameter: "severity") == .value(.hint))
    }

    @Test
    func parseChoiceRejectsAnUnknownNameWithTheAllowedList() {
        let parse = ToolSupport.parseChoice("bogus", choices: Self.kindChoices, parameter: "scope")

        #expect(parse == .corrective("`bogus` is not a valid value for `scope`. Use one of: working_tree, type_definition, file."))
        #expect(
            ToolSupport.parseChoice("loud", choices: Self.severityChoices, parameter: "severity")
                == .corrective("`loud` is not a valid value for `severity`. Use one of: error, warning, information, hint.")
        )
    }

    @Test
    func parseChoiceRejectsAMissingNameWithTheAllowedList() {
        let parse = ToolSupport.parseChoice(nil, choices: Self.kindChoices, parameter: "scope")

        #expect(parse == .corrective("Give the parameter `scope`. Use one of: working_tree, type_definition, file."))
    }

    // MARK: - correctiveMessage

    @Test
    func recoverableErrorsGiveACorrectiveMessage() throws {
        let cases: [(error: CodeContextError, reason: String)] = [
            (error: .notFound("symbol 'A.run'"), reason: "symbol 'A.run'"),
            (error: .pattern("unbalanced '('"), reason: "unbalanced '('"),
            (error: .query("no grammar for 'sql'"), reason: "no grammar for 'sql'"),
            (error: .spawnFailed("not a git repository"), reason: "not a git repository"),
        ]

        for recoverable in cases {
            let message = try #require(ToolSupport.correctiveMessage(for: recoverable.error))
            #expect(message.contains(recoverable.reason), "message: \(message)")
            #expect(message.hasSuffix("then try again."), "message: \(message)")
        }
    }

    @Test
    func theEmbeddingDisabledErrorGivesACorrectiveMessageThatNamesOtherOperations() throws {
        let message = try #require(ToolSupport.correctiveMessage(for: .embeddingDisabled))

        #expect(message.contains("embedding layer is off"), "message: \(message)")
        #expect(message.contains("`grep code`"), "message: \(message)")
        #expect(message.contains("`search symbol`"), "message: \(message)")
    }

    @Test
    func otherErrorsGiveNoCorrectiveMessage() {
        let errors: [CodeContextError] = [
            .binaryNotFound(command: "sourcekit-lsp", installHint: "install Xcode"),
            .handshakeFailed("no reply"),
            .timeout(.seconds(1)),
            .notRunning,
            .storage("disk full"),
            .embedding("model not loaded"),
            .overlappingRoot("/tmp/a"),
        ]

        for error in errors {
            #expect(ToolSupport.correctiveMessage(for: error) == nil, "error: \(error)")
        }
    }

    // MARK: - CodeContextDefaults

    @Test
    func codeContextDefaultsMatchThePublicDefaults() {
        #expect(CodeContext<FakeLanguageServerConnection>.defaultMaxQueryResults == CodeContextDefaults.maxQueryResults)
        #expect(CodeContext<FakeLanguageServerConnection>.defaultIncludeSource == CodeContextDefaults.includeSource)
        #expect(QueryASTOptions().maxResults == CodeContextDefaults.queryASTMaxResults)
        #expect(SearchWeights.default == CodeContextDefaults.searchWeights)

        // The public default values are the same as before the tools.
        #expect(CodeContextDefaults.maxQueryResults == 50)
        #expect(CodeContextDefaults.includeSource == false)
        #expect(CodeContextDefaults.callGraphDirection == .outbound)
        #expect(CodeContextDefaults.callGraphMaxDepth == 2)
        #expect(CodeContextDefaults.blastRadiusMaxHops == 3)
        #expect(CodeContextDefaults.grepLanguages.isEmpty)
        #expect(CodeContextDefaults.searchTopK == 20)
        #expect(CodeContextDefaults.searchWeights == SearchWeights(bm25: 1.0, trigram: 1.0, cosine: 1.0))
        #expect(CodeContextDefaults.duplicateMinSimilarity == 0.85)
        #expect(CodeContextDefaults.duplicateMinChunkBytes == 100)
        #expect(CodeContextDefaults.duplicateMaxPerChunk == 5)
        #expect(CodeContextDefaults.queryASTMaxResults == 50)
        #expect(CodeContextDefaults.referencesIncludeDeclaration == false)
        #expect(CodeContextDefaults.implementationsMaxResults == 20)
        #expect(CodeContextDefaults.diagnosticsSeverity == .warning)
        #expect(CodeContextDefaults.diagnosticsIncludeDependents == true)
        #expect(CodeContextDefaults.diagnosticsSettleWindow == .milliseconds(300))
        #expect(CodeContextDefaults.diagnosticsHardTimeout == .seconds(5))
        #expect(CodeContextDefaults.diagnosticsPerReportCap == 100)
    }
}

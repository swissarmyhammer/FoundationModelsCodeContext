import Testing

@testable import FoundationModelsCodeContext

/// Smoke tests proving the package scaffold itself is wired correctly:
/// the target compiles, each logger of `Log` has its label from the
/// vocabulary, the error metadata of `Log` names an error without its text,
/// and every `CodeContextError` case constructs.
struct ScaffoldTests {
    /// Each logger of `Log`, with the label that the vocabulary gives it.
    private static let loggersAndLabels = [
        (Log.lsp, CodeContextTracing.LoggerLabel.lsp),
        (Log.lspWire, CodeContextTracing.LoggerLabel.lspWire),
        (Log.index, CodeContextTracing.LoggerLabel.index),
        (Log.watcher, CodeContextTracing.LoggerLabel.watcher),
        (Log.embedding, CodeContextTracing.LoggerLabel.embedding),
        (Log.search, CodeContextTracing.LoggerLabel.search),
        (Log.diagnostics, CodeContextTracing.LoggerLabel.diagnostics),
    ]

    @Test
    func eachLoggerHasTheLabelOfTheVocabulary() {
        for (logger, label) in Self.loggersAndLabels {
            #expect(logger.label == label)
        }
    }

    /// The server name of the metadata tests.
    private static let metadataServerName = "rust-analyzer"

    @Test
    func theServerMetadataHoldsOnlyTheServerName() {
        let metadata = Log.serverMetadata(server: Self.metadataServerName)
        #expect(metadata.mapValues(\.description) == [CodeContextTracing.MetadataKey.lspServer: Self.metadataServerName])
    }

    @Test
    func theServerFailureMetadataHoldsTheServerNameAndTheErrorDetail() {
        let error = CodeContextError.notRunning
        let metadata = Log.serverFailureMetadata(server: Self.metadataServerName, error: error)
        #expect(
            metadata.mapValues(\.description) == [
                CodeContextTracing.MetadataKey.lspServer: Self.metadataServerName,
                CodeContextTracing.MetadataKey.errorType: Log.errorType(of: error).description,
                CodeContextTracing.MetadataKey.errorCase: "notRunning",
            ]
        )
    }

    /// The JSON-RPC code of the server error in the error detail tests.
    private static let serverErrorCode = -32603

    /// The server message of the error detail tests. The detail must not hold it.
    private static let serverErrorMessage = "Could not find a valid TypeScript installation"

    @Test
    func theErrorDetailOfAServerErrorHoldsItsCaseAndItsCodeButNotItsMessage() {
        let error = WireError.serverError(code: Self.serverErrorCode, message: Self.serverErrorMessage)
        let metadata = Log.errorDetail(of: error)
        #expect(
            metadata.mapValues(\.description) == [
                CodeContextTracing.MetadataKey.errorType: Log.errorType(of: error).description,
                CodeContextTracing.MetadataKey.errorCase: "serverError",
                CodeContextTracing.MetadataKey.lspErrorCode: "\(Self.serverErrorCode)",
            ]
        )
    }

    @Test
    func theErrorDetailOfAnIdMismatchHoldsItsCase() {
        let error = WireError.idMismatch(expected: 1, actual: 2)
        let metadata = Log.errorDetail(of: error)
        #expect(
            metadata.mapValues(\.description) == [
                CodeContextTracing.MetadataKey.errorType: Log.errorType(of: error).description,
                CodeContextTracing.MetadataKey.errorCase: "idMismatch",
            ]
        )
    }

    @Test
    func theErrorDetailOfAMissingResultHoldsItsCase() {
        let error = WireError.missingResult
        let metadata = Log.errorDetail(of: error)
        #expect(
            metadata.mapValues(\.description) == [
                CodeContextTracing.MetadataKey.errorType: Log.errorType(of: error).description,
                CodeContextTracing.MetadataKey.errorCase: "missingResult",
            ]
        )
    }

    @Test
    func codeContextErrorCasesConstruct() {
        let errors: [CodeContextError] = [
            .binaryNotFound(command: "rust-analyzer", installHint: "brew install rust-analyzer"),
            .spawnFailed("posix_spawn failed"),
            .handshakeFailed("no response to initialize"),
            .timeout(.seconds(30)),
            .notRunning,
            .storage("failed to open kit.db"),
            .embedding("router unavailable"),
        ]

        #expect(errors.count == 7)
    }
}

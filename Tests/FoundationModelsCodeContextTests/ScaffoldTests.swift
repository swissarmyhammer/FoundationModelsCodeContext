import Testing

@testable import FoundationModelsCodeContext

/// Smoke tests proving the package scaffold itself is wired correctly:
/// the target compiles, each logger of `Log` has its label from the
/// vocabulary, and every `CodeContextError` case constructs.
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

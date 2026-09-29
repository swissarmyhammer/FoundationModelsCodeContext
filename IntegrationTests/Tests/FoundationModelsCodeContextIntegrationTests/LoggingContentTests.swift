import Foundation
import InMemoryLogging
import Logging
import Testing

@testable import FoundationModelsCodeContext

/// The log records that the package writes in this test process.
///
/// This is a local copy of `CapturedLogRecords` in the unit target
/// (`Tests/FoundationModelsCodeContextTests/LoggingContentTests.swift`). A
/// SwiftPM test target cannot import the test target of an other package, so
/// the helper is restated here. Keep this copy in step with its original.
///
/// `LoggingSystem.bootstrap(_:)` can run one time for each process. The first
/// read of `handler` runs it, with a factory that gives each logger a copy of
/// one `InMemoryLogHandler`. The copies share one store, so `entries` holds
/// the records of each logger. The factory writes the label of the logger in
/// the metadata of its copy, because an entry does not keep the label.
internal enum CapturedLogRecords {
    /// The metadata key that holds the label of the logger that wrote a record.
    internal static let loggerLabelKey = "test.logger_label"

    /// The handler that the bootstrapped factory copies.
    internal static let handler: InMemoryLogHandler = {
        let handler = InMemoryLogHandler()
        LoggingSystem.bootstrap { label in
            var copy = handler
            copy.logLevel = .trace
            copy[metadataKey: CapturedLogRecords.loggerLabelKey] = .string(label)
            return copy
        }
        return handler
    }()

    /// Every record written since the bootstrap, oldest first.
    internal static var entries: [InMemoryLogHandler.Entry] {
        handler.entries
    }

    /// The records whose message, metadata or error holds `text`.
    /// - Parameter text: The text to look for.
    /// - Returns: The records that hold `text`.
    internal static func entries(holding text: String) -> [InMemoryLogHandler.Entry] {
        entries.filter { entry in
            entry.message.description.contains(text)
                || entry.metadata.values.contains { $0.description.contains(text) }
                || entry.error.map { String(reflecting: $0).contains(text) } == true
        }
    }

    /// The records whose metadata holds each key and value of `metadata`.
    /// - Parameter metadata: The keys and values to look for.
    /// - Returns: The records that hold all of `metadata`.
    internal static func entries(matching metadata: [String: String]) -> [InMemoryLogHandler.Entry] {
        entries.filter { entry in
            metadata.allSatisfy { key, value in entry.metadata[key]?.description == value }
        }
    }
}

/// Proves that a real language server subprocess puts no content in a log
/// record (rule 4 of the OpenTelemetry design): no standard error text of the
/// server and no LSP wire payload.
///
/// The test starts a real `swift <script>` child process that runs the
/// scripted language server of the unit target. Thus it is an integration
/// test, and it lives in this nested package. The tests of the same rule that
/// use only fakes stay in the unit target.
///
/// The test makes a new marker text, puts it in the content that the server
/// writes, and then looks for the marker in all the captured records. The
/// test also finds its own records through values that are not content, so
/// it cannot pass when the code writes no record at all.
internal struct LoggingContentTests {
    /// Makes a marker text that no other test makes.
    /// - Returns: The marker text.
    private static func makeMarker() -> String {
        "cck-log-marker-\(UUID().uuidString)"
    }

    @Test(.timeLimit(.minutes(1)))
    internal func aLanguageServerWritesNoStandardErrorTextAndNoPayloadToTheLog() async throws {
        _ = CapturedLogRecords.handler
        let marker = Self.makeMarker()
        let steps: [[String: Any]] = [
            ["action": "stderr", "text": marker],
            ["action": "read"],
            ["action": "notify", "method": "window/logMessage", "params": ["type": 3, "message": marker]],
            ["action": "respond", "which": 0, "result": ["contents": ["kind": "markdown", "value": marker]]],
            ["action": "hang"],
        ]

        let (hover, sawStderr) = try await ScriptedLSPServer.withConnection(steps: steps) { connection in
            let hover = try? await connection.hover(in: DocumentURI("file:///\(marker).swift"), at: Position(line: 0, character: 0))
            return (hover, try await ScriptedLSPServer.waitForStderr(holding: marker, of: connection))
        }

        #expect(hover?.contents == marker)
        #expect(sawStderr == true)
        #expect(CapturedLogRecords.entries(holding: marker).isEmpty)
        let stderrRecords = CapturedLogRecords.entries(matching: [
            CapturedLogRecords.loggerLabelKey: CodeContextTracing.LoggerLabel.lsp,
            CodeContextTracing.MetadataKey.bytes: "\(marker.utf8.count)",
        ])
        #expect(!stderrRecords.isEmpty)
        let wireRecords = CapturedLogRecords.entries(matching: [
            CapturedLogRecords.loggerLabelKey: CodeContextTracing.LoggerLabel.lspWire,
            CodeContextTracing.MetadataKey.lspMethod: "textDocument/hover",
        ])
        #expect(!wireRecords.isEmpty)
    }
}

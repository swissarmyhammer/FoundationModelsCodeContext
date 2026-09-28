import Foundation
import InMemoryLogging
import Logging
import Testing

@testable import FoundationModelsCodeContext

/// The log records that the package writes in this test process.
///
/// `LoggingSystem.bootstrap(_:)` can run one time for each process. The first
/// read of `handler` runs it, with a factory that gives each logger a copy of
/// one `InMemoryLogHandler`. The copies share one store, so `entries` holds
/// the records of each logger. The factory writes the label of the logger in
/// the metadata of its copy, because an entry does not keep the label.
///
/// The records of all the tests of this process go into the store. A test
/// that looks for its own records looks for a value that only that test
/// makes.
enum CapturedLogRecords {
    /// The metadata key that holds the label of the logger that wrote a record.
    static let loggerLabelKey = "test.logger_label"

    /// The handler that the bootstrapped factory copies.
    static let handler: InMemoryLogHandler = {
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
    static var entries: [InMemoryLogHandler.Entry] {
        handler.entries
    }

    /// The records whose message, metadata or error holds `text`.
    /// - Parameter text: The text to look for.
    /// - Returns: The records that hold `text`.
    static func entries(holding text: String) -> [InMemoryLogHandler.Entry] {
        entries.filter { entry in
            entry.message.description.contains(text)
                || entry.metadata.values.contains { $0.description.contains(text) }
                || entry.error.map { String(reflecting: $0).contains(text) } == true
        }
    }

    /// The records whose metadata holds each key and value of `metadata`.
    /// - Parameter metadata: The keys and values to look for.
    /// - Returns: The records that hold all of `metadata`.
    static func entries(matching metadata: [String: String]) -> [InMemoryLogHandler.Entry] {
        entries.filter { entry in
            metadata.allSatisfy { key, value in entry.metadata[key]?.description == value }
        }
    }
}

/// An error whose description holds a marker text, to prove that a log
/// record does not hold the description of an error.
private struct MarkedError: Error, LocalizedError, CustomStringConvertible {
    /// The marker text.
    let marker: String

    /// The text that `String(describing:)` gives: the marker.
    var description: String { marker }

    /// The text that `localizedDescription` gives: the marker.
    var errorDescription: String? { marker }
}

/// Proves that the package writes no content to a log record (rule 4 of the
/// OpenTelemetry design): no standard error text of a language server, no
/// LSP wire payload, no installer output and no description of an error.
///
/// Each test makes a new marker text, puts it in the content that the code
/// under test reads, and then looks for the marker in all the captured
/// records. Each test also finds its own record through a value that is not
/// content, so a test cannot pass when the code writes no record at all.
///
/// `.serialized`: the first test spawns a real `swift <script>` child process,
/// the same as `ConnectionTests`.
@Suite(.serialized)
struct LoggingContentTests {
    /// The number of polls of the standard error tail before the test stops.
    ///
    /// With `pollInterval`, this gives 60 seconds, the same budget as
    /// `ConnectionTests.recentStderrTailCapturesWhatTheServerPrinted()`.
    private static let pollLimit = 6000

    /// The time between two polls of the standard error tail.
    private static let pollInterval = Duration.milliseconds(10)

    /// A workspace root for the daemon test. The daemon only puts it in the
    /// `initialize` request, so no directory must exist.
    private static let workspaceRoot = URL(fileURLWithPath: "/tmp/logging-content-tests")

    /// Makes a marker text that no other test makes.
    /// - Returns: The marker text.
    private static func makeMarker() -> String {
        "cck-log-marker-\(UUID().uuidString)"
    }

    /// Waits until the standard error tail of `connection` holds `text`.
    /// - Parameters:
    ///   - text: The text to wait for.
    ///   - connection: The connection whose tail to read.
    /// - Returns: `true` when the tail holds `text` before the poll budget ends.
    private static func waitForStderr(holding text: String, on connection: ProcessLanguageServerConnection) async throws -> Bool {
        for _ in 0..<pollLimit {
            if connection.recentStderrTail().contains(text) {
                return true
            }
            try await Task.sleep(for: pollInterval)
        }
        return false
    }

    @Test
    func aLanguageServerWritesNoStandardErrorTextAndNoPayloadToTheLog() async throws {
        _ = CapturedLogRecords.handler
        let marker = Self.makeMarker()
        let steps: [[String: Any]] = [
            ["action": "stderr", "text": marker],
            ["action": "read"],
            ["action": "notify", "method": "window/logMessage", "params": ["type": 3, "message": marker]],
            ["action": "respond", "which": 0, "result": ["contents": ["kind": "markdown", "value": marker]]],
            ["action": "hang"],
        ]
        let script = String(decoding: try JSONSerialization.data(withJSONObject: steps), as: UTF8.self)
        let connection = try ProcessLanguageServerConnection(command: "swift", arguments: [PackagePaths.scriptedLSPServer, script])

        let hover = try? await connection.hover(in: DocumentURI("file:///\(marker).swift"), at: Position(line: 0, character: 0))
        let sawStderr = try? await Self.waitForStderr(holding: marker, on: connection)
        await connection.close()

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

    @Test
    func aHandshakeFailureWritesNoStandardErrorTextAndNoErrorDescriptionToTheLog() async throws {
        _ = CapturedLogRecords.handler
        let marker = Self.makeMarker()
        let connection = FakeLanguageServerConnection()
        await connection.setInitializeResult(to: .failure(MarkedError(marker: marker)))
        let daemon = LSPDaemon<FakeLanguageServerConnection>(
            spec: ServerSpec(command: "true", languageIDs: ["fake"], installHint: "none"),
            workspaceRoot: Self.workspaceRoot,
            clock: ManualClock(),
            connectionFactory: { _, _ in
                ConnectionHandle(
                    connection: connection,
                    pid: 1,
                    isAlive: { false },
                    waitForExit: {},
                    terminate: {},
                    stderrTail: { marker }
                )
            }
        )

        await #expect(throws: CodeContextError.self) {
            try await daemon.start()
        }

        let state = await daemon.state()
        let reason: String? = if case .failed(let reason, _) = state { reason } else { nil }
        #expect(reason?.contains(marker) == true, "the failure state keeps the full reason for the caller")
        #expect(CapturedLogRecords.entries(holding: marker).isEmpty)
        let failureRecords = CapturedLogRecords.entries(matching: [
            CodeContextTracing.MetadataKey.errorType: String(reflecting: MarkedError.self),
            CodeContextTracing.MetadataKey.lspAttempt: "1",
        ])
        #expect(!failureRecords.isEmpty)
    }

    @Test
    func aFailedInstallWritesNoInstallerOutputToTheLog() async {
        _ = CapturedLogRecords.handler
        let marker = Self.makeMarker()
        let runner = FakeInstallRunner()
        await runner.updateResult(.success(InstallRunResult(exitCode: 1, output: marker)))
        let command = "logging-content-failed-install"
        let spec = ServerSpec(
            command: command,
            languageIDs: ["fake"],
            installHint: "none",
            installer: ServerSpec.InstallSpec(tool: "true", arguments: [])
        )

        let succeeded = await ServerInstaller(runner: runner).install(spec: spec)

        #expect(!succeeded)
        #expect(CapturedLogRecords.entries(holding: marker).isEmpty)
        let failureRecords = CapturedLogRecords.entries(matching: [
            CodeContextTracing.MetadataKey.lspServer: command,
            CodeContextTracing.MetadataKey.exitCode: "1",
        ])
        #expect(!failureRecords.isEmpty)
    }

    @Test
    func anInstallerThatThrowsWritesNoErrorDescriptionToTheLog() async {
        _ = CapturedLogRecords.handler
        let marker = Self.makeMarker()
        let runner = FakeInstallRunner()
        await runner.updateResult(.failure(MarkedError(marker: marker)))
        let spec = ServerSpec(
            command: "logging-content-throwing-installer",
            languageIDs: ["fake"],
            installHint: "none",
            installer: ServerSpec.InstallSpec(tool: "true", arguments: [])
        )

        let succeeded = await ServerInstaller(runner: runner).install(spec: spec)

        #expect(!succeeded)
        #expect(CapturedLogRecords.entries(holding: marker).isEmpty)
        let failureRecords = CapturedLogRecords.entries(matching: [
            CodeContextTracing.MetadataKey.errorType: String(reflecting: MarkedError.self)
        ])
        #expect(!failureRecords.isEmpty)
    }
}

/// Proves that no library source file uses the unified logging system of the
/// operating system. The package logs through swift-log only.
struct UnifiedLoggingSourceScanTests {
    /// The texts that show a use of the unified logging system. A line that
    /// holds one of these texts fails the scan.
    private static let forbiddenTexts = ["os.Logger", "OSSignposter", "privacy:", "import OSLog"]

    /// The import of the `os` module, which a line can hold alone or with a
    /// submodule.
    private static let osImport = "import os"

    /// Tells whether `line` uses the unified logging system.
    /// - Parameter line: One line of a source file.
    /// - Returns: `true` when the line holds a forbidden text or imports `os`.
    private static func usesUnifiedLogging(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed == osImport || trimmed.hasPrefix("\(osImport).") {
            return true
        }
        return forbiddenTexts.contains { line.contains($0) }
    }

    @Test
    func noLibrarySourceFileUsesTheUnifiedLoggingSystem() throws {
        let enumerator = try #require(FileManager.default.enumerator(at: PackagePaths.librarySources, includingPropertiesForKeys: nil))
        let sourceFiles = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        let offenders = try sourceFiles.flatMap { file in
            try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .filter { Self.usesUnifiedLogging($0.element) }
                .map { "\(file.lastPathComponent):\($0.offset + 1): \($0.element)" }
        }

        #expect(!sourceFiles.isEmpty)
        #expect(offenders.isEmpty, "\(offenders.joined(separator: "\n"))")
    }
}

import Foundation
import MetricsTestKit
import Testing

@testable import FoundationModelsCodeContext

/// Tests for the metrics of the package (rules 1, 3 and 4 of the OpenTelemetry design): the
/// duration of an index pass, the count of indexed files, the duration of an LSP request and
/// the count of language server restarts.
///
/// Each test gives its own `TestMetrics` factory to the code under test through
/// `CodeContextMetrics`. No test bootstraps the global `MetricsSystem`, thus the tests can run in
/// parallel. Each test uses fakes only. The test that sends a request to a real scripted language
/// server is in the `IntegrationTests` package.
internal struct MetricsTests {
    /// The number of fixture files of the index pass test.
    private static let fixtureFileCount = 3

    /// The time limit of each test that starts background work, in minutes.
    private static let timeLimitMinutes = 1

    /// The JSON-RPC method name of the recorded request.
    private static let requestMethod = "textDocument/definition"

    /// The duration of the recorded request.
    private static let requestDuration: Duration = .milliseconds(5)

    /// The duration of the recorded request, in nanoseconds.
    private static let requestDurationNanoseconds: Int64 = 5_000_000

    /// A server command that is an absolute path, as `LSPDaemon` gives it for a binary in an
    /// installer directory.
    private static let serverCommandPath = "/opt/tools/bin/rust-analyzer"

    /// The name that the metrics use for `serverCommandPath`.
    private static let serverName = "rust-analyzer"

    /// The command of the fake language server. `true` is on the `PATH` of each machine, so the
    /// binary lookup of `LSPDaemon` finds it. The fake connection factory never starts it.
    private static let fakeServerCommand = "true"

    /// The backoff delay of the first restart after one failure: `LSPDaemon.backoffDuration`
    /// for one failure.
    private static let firstBackoffDelay: Duration = .seconds(2)

    /// The time between two reads of a counter that background work increments.
    private static let pollInterval: Duration = .milliseconds(1)

    /// The workspace root of the daemon tests. The daemon only puts it in the `initialize`
    /// request, so no folder must exist.
    private static let workspaceRoot = URL(fileURLWithPath: "/tmp/metrics-tests")

    /// Makes a daemon for the fake language server that records into `metrics`.
    /// - Parameters:
    ///   - metrics: The factory that the daemon records into.
    ///   - clock: The clock of the backoff sleep.
    ///   - processState: The liveness of the fake server process.
    /// - Returns: The daemon. It is not started.
    private static func makeDaemon(
        metrics: TestMetrics,
        clock: ManualClock,
        processState: ProcessState
    ) -> LSPDaemon<FakeLanguageServerConnection> {
        LSPDaemon<FakeLanguageServerConnection>(
            spec: ServerSpec(command: fakeServerCommand, languageIDs: ["fake"], installHint: "install the fake server"),
            workspaceRoot: workspaceRoot,
            clock: clock,
            metrics: CodeContextMetrics(factory: metrics),
            connectionFactory: fakeConnectionFactory(pid: 1, processState: processState)
        )
    }

    /// Gives the dimensions of a restart of `server` for `reason`.
    /// - Parameters:
    ///   - server: The name of the server.
    ///   - reason: The value of the restart reason dimension.
    /// - Returns: The dimensions, in the order that the package writes them.
    private static func restartDimensions(server: String, reason: String) -> [(String, String)] {
        [
            (CodeContextTracing.AttributeKey.lspServer, server),
            (CodeContextTracing.AttributeKey.restartReason, reason),
        ]
    }

    /// Gives the dimensions of the files that `layer` indexed.
    /// - Parameter layer: The value of the index layer dimension.
    /// - Returns: The dimensions.
    private static func layerDimensions(_ layer: String) -> [(String, String)] {
        [(CodeContextTracing.AttributeKey.indexLayer, layer)]
    }

    // MARK: - Index pass

    @Test(.timeLimit(.minutes(MetricsTests.timeLimitMinutes)))
    internal func anIndexPassRecordsOneDurationAndAddsTheCountOfIndexedFiles() async throws {
        try await withTemporaryWorkspace { root in
            for index in 0..<Self.fixtureFileCount {
                try write("func greet\(index)() -> String {\n    \"hello\"\n}\n", to: "Greeter\(index).swift", in: root)
            }
            let metrics = TestMetrics()
            let context = try await CodeContext<FakeLanguageServerConnection>(
                rootDirectory: root,
                embedder: nil,
                clock: ManualClock(),
                eventSource: FakeFileEventSource(),
                autoInstall: LspAutoInstall(isEnabled: false),
                metrics: CodeContextMetrics(factory: metrics),
                connectionFactory: fakeConnectionFactory(pid: 1, processState: ProcessState())
            )

            try await context.start()
            await context.waitForFirstIndexPass()
            await context.stop()

            let timer = try metrics.expectTimer(CodeContextTracing.MetricName.indexDuration)
            #expect(timer.values.count == 1)
            let filesIndexed = try metrics.expectCounter(CodeContextTracing.MetricName.filesIndexed, Self.layerDimensions("treesitter"))
            #expect(filesIndexed.totalValue == Int64(Self.fixtureFileCount))
        }
    }

    @Test
    internal func anLSPBatchAddsTheCountOfIndexedFilesUnderTheLSPLayer() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("func topLevel() {}\n", to: "Sample.swift", in: root)
            try await store.markDirty(filePath: "Sample.swift", contentHash: Data("Sample.swift".utf8), fileSize: 1)
            let connection = FakeLanguageServerConnection()
            await connection.setDocumentSymbolsResult(.success([]))
            let metrics = TestMetrics()

            try await LSPIndexWorker<FakeLanguageServerConnection>.drainBatch(
                store: store,
                rootDirectory: root,
                extensions: ["swift"],
                session: LspSession(connection: connection, languageID: "swift"),
                metrics: CodeContextMetrics(factory: metrics)
            )

            let filesIndexed = try metrics.expectCounter(CodeContextTracing.MetricName.filesIndexed, Self.layerDimensions("lsp"))
            #expect(filesIndexed.totalValue == 1)
        }
    }

    // MARK: - LSP request

    @Test
    internal func anLSPRequestRecordsOneDurationWithTheMethodTheServerNameAndTheOutcome() throws {
        let metrics = TestMetrics()

        CodeContextMetrics(factory: metrics).recordLSPRequest(
            duration: Self.requestDuration,
            method: Self.requestMethod,
            server: Self.serverCommandPath,
            outcome: .ok
        )

        let timer = try metrics.expectTimer(
            CodeContextTracing.MetricName.lspRequestDuration,
            [
                (CodeContextTracing.AttributeKey.lspMethod, Self.requestMethod),
                (CodeContextTracing.AttributeKey.lspServer, Self.serverName),
                (CodeContextTracing.AttributeKey.lspOutcome, "ok"),
            ]
        )
        #expect(timer.values == [Self.requestDurationNanoseconds])
    }

    @Test
    internal func aTimeoutErrorGivesTheOutcomeTimeout() {
        let outcome = CodeContextMetrics.LSPRequestOutcome(classifying: CodeContextError.timeout(Self.requestDuration))
        #expect(outcome == .timeout)
    }

    @Test
    internal func anErrorThatIsNotATimeoutGivesTheOutcomeError() {
        let outcome = CodeContextMetrics.LSPRequestOutcome(classifying: CodeContextError.notRunning)
        #expect(outcome == .error)
    }

    // MARK: - Server restarts

    @Test
    internal func aForcedRestartAddsOneToTheRestartCounterOfTheServer() async throws {
        let metrics = TestMetrics()
        let daemon = Self.makeDaemon(metrics: metrics, clock: ManualClock(), processState: ProcessState())

        try await daemon.start()
        try await daemon.forceRestart()

        let restarts = try metrics.expectCounter(
            CodeContextTracing.MetricName.lspServerRestarts,
            Self.restartDimensions(server: Self.fakeServerCommand, reason: "forced")
        )
        #expect(restarts.totalValue == 1)
    }

    @Test
    internal func aRestartAfterAFailedHealthCheckAddsOneToTheRestartCounterOfTheServer() async throws {
        let metrics = TestMetrics()
        let clock = ManualClock()
        let processState = ProcessState()
        let daemon = Self.makeDaemon(metrics: metrics, clock: clock, processState: processState)
        try await daemon.start()
        await processState.setAlive(false)
        await daemon.healthCheck()
        await processState.setAlive(true)

        let restartTask = Task { try await daemon.restartWithBackoff() }
        await clock.waitForWaiter()
        clock.advance(by: Self.firstBackoffDelay)
        try await restartTask.value

        let restarts = try metrics.expectCounter(
            CodeContextTracing.MetricName.lspServerRestarts,
            Self.restartDimensions(server: Self.fakeServerCommand, reason: "health")
        )
        #expect(restarts.totalValue == 1)
    }

    @Test(.timeLimit(.minutes(MetricsTests.timeLimitMinutes)))
    internal func aRestartAfterAnInstallAddsOneToTheRestartCounterOfTheServer() async throws {
        let command = "fake-metrics-install-\(UUID().uuidString)"
        let installDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let spec = ServerSpec(
            command: command,
            languageIDs: ["fake"],
            installHint: "install \(command) with true",
            installer: ServerSpec.InstallSpec(tool: Self.fakeServerCommand, extraSearchDirectories: [installDirectory.path])
        )
        let metrics = TestMetrics()
        let supervisor = LspSupervisor<FakeLanguageServerConnection>(
            workspaceRoot: Self.workspaceRoot,
            clock: ManualClock(),
            installRunner: FakeInstallRunner(),
            metrics: CodeContextMetrics(factory: metrics),
            connectionFactory: fakeConnectionFactory(pid: 1, processState: ProcessState())
        )

        await supervisor.startForTesting(specs: [spec])

        let dimensions = Self.restartDimensions(server: command, reason: "install")
        while (try? metrics.expectCounter(CodeContextTracing.MetricName.lspServerRestarts, dimensions)) == nil {
            try await Task.sleep(for: Self.pollInterval)
        }
        await supervisor.shutdown()
        let restarts = try metrics.expectCounter(CodeContextTracing.MetricName.lspServerRestarts, dimensions)
        #expect(restarts.totalValue == 1)
    }
}

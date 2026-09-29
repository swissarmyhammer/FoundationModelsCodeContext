import Foundation
import InMemoryTracing
import MetricsTestKit
import Testing
import Tracing

@testable import FoundationModelsCodeContext

/// Finds each telemetry value of a test that holds a marker text.
///
/// This is the one content check of this test target (rule 5 of the OpenTelemetry design). The
/// Extras `TelemetryTestSupport` product has no public check that works without
/// `TelemetryCapture.run(forbidding:_:)`, and that function sets up the logging system a second
/// time in this process. Thus this target has its own check.
///
/// The check reads three stores: the finished spans of an explicit `InMemoryTracer`, the metrics
/// of an explicit `TestMetrics` factory, and the log records of `CapturedLogRecords`, which this
/// test process sets up one time. The log capture holds the records of all the tasks of the
/// process, also of a detached task.
///
/// The `IntegrationTests` package has a local copy of this helper for its content-safety test.
/// Keep that copy in step with this original.
internal enum TelemetryContentCheck {
    /// Gives each telemetry place that holds `marker`.
    ///
    /// A place is a span name, a span attribute, a span event, a span status message, an error
    /// that a span recorded, a log message, a log metadata value, a metric name or a metric
    /// dimension.
    ///
    /// - Parameters:
    ///   - marker: The text that no place may hold.
    ///   - tracer: The tracer that holds the finished spans of the test.
    ///   - metrics: The factory that holds the metrics of the test.
    /// - Returns: One line of text for each place that holds `marker`. The array is empty when
    ///   no place holds it.
    internal static func places(holding marker: String, tracer: InMemoryTracer, metrics: TestMetrics) -> [String] {
        let logPlaces = CapturedLogRecords.entries(holding: marker).map { entry in
            "log \(entry.level): \(entry.message) \(entry.metadata)"
        }
        return (spanPlaces(of: tracer.finishedSpans) + metricPlaces(of: metrics)).filter { $0.contains(marker) } + logPlaces
    }

    /// Gives the places of `spans`: the name, the attributes, the events, the status message and
    /// the recorded errors of each span.
    /// - Parameter spans: The finished spans.
    /// - Returns: One line of text for each place.
    private static func spanPlaces(of spans: [FinishedInMemorySpan]) -> [String] {
        spans.flatMap { span in
            let owner = "span \(span.operationName)"
            let eventPlaces = span.events.flatMap { event in
                ["\(owner) event \(event.name)"] + attributePlaces(of: event.attributes, owner: "\(owner) event \(event.name)")
            }
            let errorPlaces = span.errors.map { "\(owner) error \(String(reflecting: $0.error))" }
            let statusPlaces = span.status.map { ["\(owner) status \($0.code) \($0.message ?? "")"] } ?? []
            return [owner] + attributePlaces(of: span.attributes, owner: owner) + eventPlaces + errorPlaces + statusPlaces
        }
    }

    /// Gives one place for each attribute of `attributes`.
    /// - Parameters:
    ///   - attributes: The attributes of a span or of a span event.
    ///   - owner: The text that names the span or the event.
    /// - Returns: One line of text for each attribute.
    private static func attributePlaces(of attributes: SpanAttributes, owner: String) -> [String] {
        // `SpanAttributes` is not a `Sequence`. `forEach` is its only walk of the attributes, thus
        // the walk collects them into an array.
        var places: [String] = []
        attributes.forEach { key, value in
            places.append("\(owner) \(key) = \(value)")
        }
        return places
    }

    /// Gives the places of the metrics of `metrics`: the name and each dimension of each metric.
    /// - Parameter metrics: The factory that holds the metrics.
    /// - Returns: One line of text for each place.
    private static func metricPlaces(of metrics: TestMetrics) -> [String] {
        let labelsAndDimensions =
            metrics.counters.map { ($0.label, $0.dimensions) }
            + metrics.meters.map { ($0.label, $0.dimensions) }
            + metrics.recorders.map { ($0.label, $0.dimensions) }
            + metrics.timers.map { ($0.label, $0.dimensions) }
        return labelsAndDimensions.flatMap { label, dimensions in
            ["metric \(label)"] + dimensions.map { "metric \(label) \($0.0) = \($0.1)" }
        }
    }
}

/// An error whose description holds a marker text, to prove that no telemetry place holds the
/// description of an error.
private struct ContentMarkedError: Error, LocalizedError, CustomStringConvertible {
    /// The marker text.
    let marker: String

    /// The text that `String(describing:)` gives: the marker.
    var description: String { marker }

    /// The text that `localizedDescription` gives: the marker.
    var errorDescription: String? { marker }
}

/// The telemetry stores of one content-safety test and the marker text of that test.
private struct ContentSafetyCapture {
    /// The text that the test puts in the content, and that no telemetry place may hold.
    let marker: String

    /// The tracer that the code under test opens its spans through.
    let tracer = InMemoryTracer()

    /// The factory that the code under test records its metrics into.
    let metrics = TestMetrics()
}

/// Proves that the package puts no content in its telemetry (rules 4 and 5 of the OpenTelemetry
/// design). Content is source code, file content, query text, embed input text and LSP wire
/// payload.
///
/// The test makes a new marker text. It puts the marker in the body of a source file, in the
/// name of a symbol, in the search query and in the text that goes to the embedder. It puts the
/// marker also in the error and the standard error text of a language server, and in the answer
/// of a language server. Then it runs each telemetry path of the package that works with fakes,
/// and it fails on each span, log or metric value that holds the marker.
///
/// The test gives an explicit `InMemoryTracer` and an explicit `TestMetrics` factory to the code
/// under test. It reads the log records from `CapturedLogRecords`, which this test process sets
/// up one time. It sets up no other global system, thus it can run in parallel with other tests.
///
/// The paths of `ProcessLanguageServerConnection` (the `lspRequest` span, the
/// `lsp.request.duration` timer, the `lsp-wire` records and the standard error records) start a
/// real subprocess. Thus their content-safety test is in the `IntegrationTests` package
/// (`IntegrationTests/Tests/FoundationModelsCodeContextIntegrationTests/TelemetryContentSafetyTests.swift`).
internal struct TelemetryContentSafetyTests {
    /// The time limit of the test, in minutes.
    private static let timeLimitMinutes = 1

    /// The length of each vector of the fake embedder.
    private static let embeddingDimension = 8

    /// The maximum number of results that each search asks for.
    private static let searchLimit = 5

    /// The debounce interval of the watcher.
    private static let debounceInterval: Duration = .seconds(1)

    /// The JSON-RPC error code of the error answer of the fake language server: an internal
    /// error of the server.
    private static let internalErrorCode = -32_603

    /// The path, relative to the root directory, of the source file that holds the marker. A
    /// relative path is a name, and a telemetry place can hold it, thus it holds no marker.
    private static let markedFilePath = "Marked.swift"

    /// The zero-based line of the end of the function in the marked source file. The range of the
    /// symbol of the fake language server ends on this line.
    private static let markedFunctionEndLine = 2

    /// The command of the fake language server of the restart. `true` is on the `PATH` of each
    /// machine, so the binary lookup of `LSPDaemon` finds it. The fake connection factory never
    /// starts it.
    private static let fakeServerCommand = "true"

    /// The workspace root of the daemon. The daemon only puts it in the `initialize` request, so
    /// no folder must exist.
    private static let daemonWorkspaceRoot = URL(fileURLWithPath: "/tmp/telemetry-content-safety-tests")

    /// The names of the spans that the test must see. The test fails when a path writes no span,
    /// because then the check proves nothing about that path.
    private static let expectedSpanNames: Set<String> = [
        CodeContextTracing.SpanName.indexPass,
        CodeContextTracing.SpanName.watcherBatch,
        CodeContextTracing.SpanName.embed,
        CodeContextTracing.SpanName.search,
        CodeContextTracing.SpanName.searchSymbol,
        CodeContextTracing.SpanName.grepCode,
    ]

    /// The names of the metrics that the test must see.
    private static let expectedMetricNames: Set<String> = [
        CodeContextTracing.MetricName.indexDuration,
        CodeContextTracing.MetricName.filesIndexed,
        CodeContextTracing.MetricName.lspServerRestarts,
    ]

    @Test(.timeLimit(.minutes(TelemetryContentSafetyTests.timeLimitMinutes)))
    internal func noSpanLogRecordOrMetricHoldsTheContentOfTheUser() async throws {
        _ = CapturedLogRecords.handler
        let capture = ContentSafetyCapture(marker: Self.makeMarker())
        let sessionServerName = "content-safety-\(UUID().uuidString)"

        try await withTemporaryWorkspace { root in
            try write(Self.markedSource(capture.marker), to: Self.markedFilePath, in: root)
            try await Self.runIndexPassAndSearches(root: root, capture: capture)
            try await Self.runWatcherBatch(root: root, capture: capture)
            try await Self.runLSPIndexBatch(root: root, serverName: sessionServerName, capture: capture)
        }
        try await Self.runForcedRestart(capture: capture)

        #expect(Set(capture.tracer.finishedSpans.map(\.operationName)).isSuperset(of: Self.expectedSpanNames))
        #expect(Set(Self.metricNames(in: capture.metrics)).isSuperset(of: Self.expectedMetricNames))
        let sessionFailureRecords = CapturedLogRecords.entries(matching: [
            CodeContextTracing.MetadataKey.lspServer: sessionServerName,
            CodeContextTracing.MetadataKey.lspErrorCode: "\(Self.internalErrorCode)",
        ])
        #expect(!sessionFailureRecords.isEmpty)
        let daemonFailureRecords = CapturedLogRecords.entries(matching: [
            CodeContextTracing.MetadataKey.errorType: String(reflecting: ContentMarkedError.self)
        ])
        #expect(!daemonFailureRecords.isEmpty)
        let leaks = TelemetryContentCheck.places(holding: capture.marker, tracer: capture.tracer, metrics: capture.metrics)
        #expect(leaks.isEmpty, "\(leaks.joined(separator: "\n"))")
    }

    // MARK: - Paths

    /// Runs the first index pass of a context over `root`, then a search, a symbol search and a
    /// grep for the marker, and stops the context.
    ///
    /// The index pass embeds the chunk of the marked source file, and the search embeds the
    /// marker as its query.
    /// - Parameters:
    ///   - root: The root directory that holds the marked source file.
    ///   - capture: The telemetry stores and the marker of the test.
    private static func runIndexPassAndSearches(root: URL, capture: ContentSafetyCapture) async throws {
        let context = try await CodeContext<FakeLanguageServerConnection>(
            rootDirectory: root,
            embedder: FakeEmbedder(dimension: embeddingDimension),
            clock: ManualClock(),
            eventSource: FakeFileEventSource(),
            autoInstall: LspAutoInstall(isEnabled: false),
            metrics: CodeContextMetrics(factory: capture.metrics),
            tracer: capture.tracer,
            connectionFactory: fakeConnectionFactory(pid: 1, processState: ProcessState())
        )
        try await context.start()
        await context.waitForFirstIndexPass()
        let hits = try await context.searchCode(query: capture.marker, topK: searchLimit).hits
        let symbols = try await context.searchSymbol(query: capture.marker, maxResults: searchLimit)
        let grep = try await context.grepCode(pattern: capture.marker, maxResults: searchLimit)
        await context.stop()

        #expect(!hits.isEmpty)
        #expect(!symbols.isEmpty)
        #expect(!grep.matches.isEmpty)
    }

    /// Changes the marked source file and flushes one watcher batch for it.
    /// - Parameters:
    ///   - root: The root directory that holds the marked source file.
    ///   - capture: The telemetry stores and the marker of the test.
    private static func runWatcherBatch(root: URL, capture: ContentSafetyCapture) async throws {
        try write(markedSource(capture.marker) + "// \(capture.marker)\n", to: markedFilePath, in: root)
        let clock = ManualClock()
        let eventSource = FakeFileEventSource()
        let watcher = Watcher(
            store: try Store(rootDirectory: root),
            rootDirectory: root,
            eventSource: eventSource,
            clock: clock,
            debounceInterval: debounceInterval,
            tracer: capture.tracer,
            nudgeWorkers: {}
        )
        await watcher.start()
        await eventSource.emit(RawFileEvent(url: root.appendingPathComponent(markedFilePath), kind: .modified))
        await clock.waitForWaiter()
        clock.advance(by: debounceInterval)
        await watcher.waitForQuiescence()
        await watcher.stop()
    }

    /// Indexes the marked source file through an `LspSession` over a fake connection.
    ///
    /// The fake server gives a symbol whose name is the marker, and it refuses the call hierarchy
    /// request with an error whose message is the marker. Thus the session writes its failure
    /// record, and the worker adds the file to the `lsp` layer counter.
    /// - Parameters:
    ///   - root: The root directory that holds the marked source file.
    ///   - serverName: The name of the fake server. The failure record holds it.
    ///   - capture: The telemetry stores and the marker of the test.
    private static func runLSPIndexBatch(root: URL, serverName: String, capture: ContentSafetyCapture) async throws {
        let store = try Store(rootDirectory: root)
        try await store.markDirty(filePath: markedFilePath, contentHash: Data(capture.marker.utf8), fileSize: 1)
        let connection = FakeLanguageServerConnection()
        let range = LSPRange(start: Position(line: 0, character: 0), end: Position(line: markedFunctionEndLine, character: 0))
        let symbol = DocumentSymbol(name: capture.marker, detail: capture.marker, kind: .function, range: range, selectionRange: range, children: nil)
        await connection.setDocumentSymbolsResult(.success([symbol]))
        await connection.setPrepareCallHierarchyResult(.failure(WireError.serverError(code: internalErrorCode, message: capture.marker)))
        let session = LspSession(connection: connection, languageID: "swift", serverName: serverName, capabilities: .everyGatedMethod)

        let indexed = try await LSPIndexWorker<FakeLanguageServerConnection>.drainBatch(
            store: store,
            rootDirectory: root,
            extensions: ["swift"],
            session: session,
            metrics: CodeContextMetrics(factory: capture.metrics)
        )

        #expect(indexed == 1)
    }

    /// Starts a daemon over a fake connection, then forces a restart that fails. The failed
    /// handshake throws an error whose description is the marker, and the standard error text of
    /// the fake server is the marker.
    /// - Parameter capture: The telemetry stores and the marker of the test.
    private static func runForcedRestart(capture: ContentSafetyCapture) async throws {
        let marker = capture.marker
        let starts = Counter()
        let processState = ProcessState()
        let daemon = LSPDaemon<FakeLanguageServerConnection>(
            spec: ServerSpec(command: fakeServerCommand, languageIDs: ["fake"], installHint: "none"),
            workspaceRoot: daemonWorkspaceRoot,
            clock: ManualClock(),
            metrics: CodeContextMetrics(factory: capture.metrics),
            connectionFactory: { _, _ in
                let connection = FakeLanguageServerConnection()
                if await starts.increment() > 1 {
                    await connection.setInitializeResult(to: .failure(ContentMarkedError(marker: marker)))
                }
                return ConnectionHandle(
                    connection: connection,
                    pid: 1,
                    isAlive: { await processState.isAlive },
                    waitForExit: { await processState.waitForExit() },
                    terminate: { await processState.markTerminated() },
                    stderrTail: { marker }
                )
            }
        )

        try await daemon.start()
        await #expect(throws: CodeContextError.self) {
            try await daemon.forceRestart()
        }
    }

    // MARK: - Helpers

    /// Makes a marker text that no other test makes. The marker is a Swift identifier, so it can
    /// be the name of a function in the marked source file.
    /// - Returns: The marker text.
    private static func makeMarker() -> String {
        "cckContentMarker" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    /// Gives a Swift source file whose function name and body hold `marker`.
    /// - Parameter marker: The marker text.
    /// - Returns: The source text.
    private static func markedSource(_ marker: String) -> String {
        "func \(marker)() -> String {\n    \"\(marker)\"\n}\n"
    }

    /// Gives the name of each metric of `metrics`.
    /// - Parameter metrics: The factory that holds the metrics.
    /// - Returns: The names of the counters and the timers.
    private static func metricNames(in metrics: TestMetrics) -> [String] {
        metrics.counters.map(\.label) + metrics.timers.map(\.label)
    }
}

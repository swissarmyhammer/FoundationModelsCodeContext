import Foundation
import InMemoryLogging
import InMemoryTracing
import MetricsTestKit
import Testing
import Tracing

@testable import FoundationModelsCodeContext

/// Finds each telemetry value of a test that holds a marker text.
///
/// This is a local copy of `TelemetryContentCheck` in the unit target
/// (`Tests/FoundationModelsCodeContextTests/TelemetryContentSafetyTests.swift`). A SwiftPM test
/// target cannot import the test target of an other package, so the helper is restated here. Keep
/// this copy in step with its original.
///
/// The check reads three stores: the finished spans of an explicit `InMemoryTracer`, the metrics
/// of an explicit `TestMetrics` factory, and the log records of `CapturedLogRecords`, which this
/// test process sets up one time. The log capture holds the records of all the tasks of the
/// process, also of a detached task. The standard error loop and the reader loop of
/// `ProcessLanguageServerConnection` write their records from detached tasks.
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
        // `SpanAttributes` is not a `Sequence`, and its only public walk is a closure. A for-in loop
        // needs the dictionary of the attributes, thus the function reads it through a `Mirror`.
        // If the storage has a different form, the function gives the full text of the attributes
        // as one place. Thus no attribute goes out of the check.
        guard
            let storage = Mirror(reflecting: attributes).descendant(attributeStorageLabel)
                as? [String: SpanAttribute]
        else {
            return ["\(owner) attributes = \(attributes)"]
        }
        var places: [String] = []
        for (key, value) in storage {
            places.append("\(owner) \(key) = \(value)")
        }
        return places
    }

    /// The label of the stored property of `SpanAttributes` that holds the attributes.
    private static let attributeStorageLabel = "_attributes"

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

/// Proves that a request to a real language server subprocess puts no content in the telemetry
/// of the package (rules 4 and 5 of the OpenTelemetry design): no LSP wire payload, no standard
/// error text of the server and no error message of the server.
///
/// The test starts a real `swift <script>` child process that runs the scripted language server
/// of the unit target. Thus it is an integration test, and it lives in this nested package. The
/// content-safety test of the paths that work with fakes is in the unit target
/// (`Tests/FoundationModelsCodeContextTests/TelemetryContentSafetyTests.swift`).
///
/// The test makes a new marker text. The scripted server writes the marker to its standard
/// error, sends it in a notification, sends it in the answer to the first request and sends it
/// in the error message of the answer to the second request. The document URI of each request
/// holds the marker too. The test sends the two requests through a
/// `ProcessLanguageServerConnection`. Then it fails on each span, log or metric value that holds
/// the marker: the `lspRequest` spans, the "enter" records, the `lsp-wire` records, the standard
/// error records and the `lsp.request.duration` timers.
///
/// The test gives an explicit `InMemoryTracer` and an explicit `TestMetrics` factory to the
/// connection. It reads the log records from `CapturedLogRecords`, which this test process sets up
/// one time.
internal struct TelemetryContentSafetyTests {
    /// The command that starts the scripted server.
    private static let serverCommand = "swift"

    /// The JSON-RPC method name of each request of the test.
    private static let hoverMethod = "textDocument/hover"

    /// The JSON-RPC error code of the scripted error answer: an internal error of the server.
    private static let internalErrorCode = -32_603

    /// The LSP message type of the scripted `window/logMessage` notification: an information
    /// message.
    private static let infoMessageType = 3

    /// The number of requests that the test sends: one gets an answer, and one gets an error.
    private static let requestCount = 2

    /// The time that the test waits for the standard error tail to hold the marker, in seconds.
    /// It is the same budget as the logging content test of this package.
    private static let stderrBudgetSeconds = 60

    /// The time between two polls of the standard error tail, in milliseconds.
    private static let stderrPollIntervalMilliseconds = 10

    @Test
    internal func aRequestToALanguageServerPutsNoContentInTheTelemetry() async throws {
        _ = CapturedLogRecords.handler
        let marker = Self.makeMarker()
        let tracer = InMemoryTracer()
        let metrics = TestMetrics()
        let connection = try ProcessLanguageServerConnection(
            command: Self.serverCommand,
            arguments: [ScriptedLSPServer.path, try Self.script(holding: marker)],
            metrics: CodeContextMetrics(factory: metrics),
            tracer: tracer
        )

        let uri = DocumentURI("file:///\(marker).swift")
        let hover = try? await connection.hover(in: uri, at: Position(line: 0, character: 0))
        let failedHover = try? await connection.hover(in: uri, at: Position(line: 0, character: 0))
        let sawStderr = try? await poll(budget: .seconds(Self.stderrBudgetSeconds), interval: .milliseconds(Self.stderrPollIntervalMilliseconds)) {
            connection.recentStderrTail().contains(marker)
        }
        await connection.close()

        #expect(hover?.contents == marker)
        #expect(failedHover == nil)
        #expect(sawStderr == true)
        let requestSpans = tracer.finishedSpans.filter { $0.operationName == CodeContextTracing.SpanName.lspRequest }
        #expect(requestSpans.count == Self.requestCount)
        let requestTimers = metrics.timers.filter { $0.label == CodeContextTracing.MetricName.lspRequestDuration }
        #expect(requestTimers.count == Self.requestCount)
        #expect(!Self.stderrRecords(of: marker).isEmpty)
        #expect(!Self.wireRecords().isEmpty)
        let leaks = TelemetryContentCheck.places(holding: marker, tracer: tracer, metrics: metrics)
        #expect(leaks.isEmpty, "\(leaks.joined(separator: "\n"))")
    }

    /// Makes a marker text that no other test makes.
    /// - Returns: The marker text.
    private static func makeMarker() -> String {
        "cck-telemetry-marker-\(UUID().uuidString)"
    }

    /// Gives the script of the scripted server. The server writes `marker` to its standard error,
    /// answers the first request with `marker` and answers the second request with an error whose
    /// message is `marker`.
    /// - Parameter marker: The marker text.
    /// - Returns: The script as JSON text.
    /// - Throws: When the script cannot be encoded as JSON.
    private static func script(holding marker: String) throws -> String {
        let steps: [[String: Any]] = [
            ["action": "stderr", "text": marker],
            ["action": "read"],
            ["action": "notify", "method": "window/logMessage", "params": ["type": infoMessageType, "message": marker]],
            ["action": "respond", "which": 0, "result": ["contents": ["kind": "markdown", "value": marker]]],
            ["action": "read"],
            ["action": "respondError", "which": 1, "code": internalErrorCode, "message": marker],
            ["action": "hang"],
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: steps), as: UTF8.self)
    }

    /// Gives the standard error records of a chunk that has the size of `marker`. The test fails
    /// when no such record exists, because then the check proves nothing about the standard error
    /// path.
    /// - Parameter marker: The marker text that the server wrote to its standard error.
    /// - Returns: The records.
    private static func stderrRecords(of marker: String) -> [InMemoryLogHandler.Entry] {
        CapturedLogRecords.entries(matching: [
            CapturedLogRecords.loggerLabelKey: CodeContextTracing.LoggerLabel.lsp,
            CodeContextTracing.MetadataKey.bytes: "\(marker.utf8.count)",
        ])
    }

    /// Gives the wire records of the hover requests. The test fails when no such record exists,
    /// because then the check proves nothing about the wire path.
    /// - Returns: The records.
    private static func wireRecords() -> [InMemoryLogHandler.Entry] {
        CapturedLogRecords.entries(matching: [
            CapturedLogRecords.loggerLabelKey: CodeContextTracing.LoggerLabel.lspWire,
            CodeContextTracing.MetadataKey.lspMethod: hoverMethod,
        ])
    }
}

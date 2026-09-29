import Foundation
import MetricsTestKit
import Testing

@testable import FoundationModelsCodeContext

/// Proves that a request to a real language server subprocess records one
/// duration value (rule 3 of the OpenTelemetry design), with the JSON-RPC
/// method name, the server name and the outcome as dimensions.
///
/// The test starts a real `swift <script>` child process that runs the
/// scripted language server of the unit target. Thus it is an integration
/// test, and it lives in this nested package. The unit target tests the
/// recording itself with fakes, in `MetricsTests`.
///
/// The test gives its own `TestMetrics` factory to the connection, so it
/// does not bootstrap the global metrics system.
internal struct LSPRequestMetricsTests {
    /// The JSON-RPC method name of the request that the test sends.
    private static let hoverMethod = "textDocument/hover"

    /// The hover text that the scripted server sends back.
    private static let hoverText = "scripted hover"

    @Test(.timeLimit(.minutes(1)))
    internal func aRequestToAScriptedServerRecordsOneDurationWithTheMethodName() async throws {
        let steps: [[String: Any]] = [
            ["action": "read"],
            ["action": "respond", "which": 0, "result": ["contents": ["kind": "markdown", "value": Self.hoverText]]],
            ["action": "hang"],
        ]
        let metrics = TestMetrics()

        let hover = try await ScriptedLSPServer.withConnection(steps: steps, metrics: CodeContextMetrics(factory: metrics)) { connection in
            try? await connection.hover(in: DocumentURI("file:///Sample.swift"), at: Position(line: 0, character: 0))
        }

        #expect(hover?.contents == Self.hoverText)
        let timer = try metrics.expectTimer(
            CodeContextTracing.MetricName.lspRequestDuration,
            [
                (CodeContextTracing.AttributeKey.lspMethod, Self.hoverMethod),
                (CodeContextTracing.AttributeKey.lspServer, ScriptedLSPServer.command),
                (CodeContextTracing.AttributeKey.lspOutcome, CodeContextMetrics.LSPRequestOutcome.ok.rawValue),
            ]
        )
        #expect(timer.values.count == 1)
    }
}

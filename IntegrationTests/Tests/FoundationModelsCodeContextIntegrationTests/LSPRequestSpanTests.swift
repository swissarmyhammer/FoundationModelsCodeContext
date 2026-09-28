import Foundation
import InMemoryLogging
import InMemoryTracing
import Testing
import Tracing

@testable import FoundationModelsCodeContext

/// Proves that each request to a real language server subprocess gives one
/// `lspRequest` span of kind `.client` (rules 1, 3 and 4 of the OpenTelemetry
/// design), and writes one "enter" log record before the request is sent
/// (rule 8, hang detection).
///
/// The tests start a real `swift <script>` child process that runs the
/// scripted language server of the unit target. Thus they are integration
/// tests, and they live in this nested package.
///
/// Each test gives its own `InMemoryTracer` to the connection, so it does not
/// bootstrap the global tracing system. The "enter" record test reads the
/// records from `CapturedLogRecords`, the logging capture that this test
/// process bootstraps one time.
internal struct LSPRequestSpanTests {
    /// The JSON-RPC method name of the request that each test sends.
    private static let hoverMethod = "textDocument/hover"

    /// The command that starts the scripted server. It is the value of the
    /// server attribute.
    private static let serverCommand = "swift"

    /// The hover text that the scripted server sends back.
    private static let hoverText = "scripted hover"

    /// The JSON-RPC error code of the scripted error response: an internal
    /// error of the server.
    private static let internalErrorCode = -32_603

    /// The message of the scripted error response. No telemetry place may
    /// hold it, because a server message can hold content.
    private static let errorMarker = "scripted server failure marker"

    /// The message of the "enter" record of each request.
    private static let enterMessage = "enter \(CodeContextTracing.SpanName.lspRequest)"

    @Test
    internal func aRequestToAScriptedServerGivesOneClientSpanWithTheMethodName() async throws {
        let tracer = InMemoryTracer()

        let hover = try await Self.sendHover(
            answeredBy: ["action": "respond", "which": 0, "result": ["contents": ["kind": "markdown", "value": Self.hoverText]]],
            tracer: tracer
        )

        #expect(hover?.contents == Self.hoverText)
        let span = try Self.onlyRequestSpan(in: tracer)
        #expect(span.kind == .client)
        #expect(span.attributes.get(CodeContextTracing.AttributeKey.lspMethod) == .string(Self.hoverMethod))
        #expect(span.attributes.get(CodeContextTracing.AttributeKey.lspServer) == .string(Self.serverCommand))
        #expect(span.attributes.get(CodeContextTracing.AttributeKey.lspRequestId) != nil)
        #expect(try #require(Self.intValue(of: CodeContextTracing.AttributeKey.lspRequestBytes, in: span)) > 0)
        #expect(try #require(Self.intValue(of: CodeContextTracing.AttributeKey.lspResponseBytes, in: span)) > 0)
        #expect(span.errors.isEmpty)
    }

    @Test
    internal func aScriptedErrorResponseRecordsOnlyTheErrorTypeOnTheSpan() async throws {
        let tracer = InMemoryTracer()

        let hover = try? await Self.sendHover(
            answeredBy: ["action": "respondError", "which": 0, "code": Self.internalErrorCode, "message": Self.errorMarker],
            tracer: tracer
        )

        #expect(hover == nil)
        let span = try Self.onlyRequestSpan(in: tracer)
        let recorded = try #require(span.errors.first)
        #expect(span.errors.count == 1)
        #expect(String(describing: recorded.error) == String(reflecting: WireError.self))
        #expect(!String(reflecting: recorded.error).contains(Self.errorMarker))
        #expect(span.status?.code == .error)
    }

    @Test
    internal func aRequestWritesAnEnterRecordBeforeItIsSent() async throws {
        _ = CapturedLogRecords.handler

        _ = try await Self.sendHover(
            answeredBy: ["action": "respond", "which": 0, "result": ["contents": ["kind": "markdown", "value": Self.hoverText]]],
            tracer: InMemoryTracer()
        )

        let records = CapturedLogRecords.entries(matching: [
            CodeContextTracing.MetadataKey.lspMethod: Self.hoverMethod,
            CodeContextTracing.MetadataKey.lspServer: Self.serverCommand,
        ])
        #expect(records.contains { $0.message.description == Self.enterMessage })
    }

    /// Starts the scripted server, sends one hover request that `answer`
    /// answers, and closes the connection.
    /// - Parameters:
    ///   - answer: The script step that answers the request.
    ///   - tracer: The tracer of the connection.
    /// - Returns: The hover result.
    /// - Throws: The error of the request.
    private static func sendHover(answeredBy answer: [String: Any], tracer: InMemoryTracer) async throws -> Hover? {
        let steps: [[String: Any]] = [["action": "read"], answer, ["action": "hang"]]
        let script = String(decoding: try JSONSerialization.data(withJSONObject: steps), as: UTF8.self)
        let connection = try ProcessLanguageServerConnection(
            command: serverCommand,
            arguments: [ScriptedLSPServer.path, script],
            tracer: tracer
        )
        do {
            let hover = try await connection.hover(in: DocumentURI("file:///Sample.swift"), at: Position(line: 0, character: 0))
            await connection.close()
            return hover
        } catch {
            await connection.close()
            throw error
        }
    }

    /// Gives the one `lspRequest` span of `tracer`.
    /// - Parameter tracer: The tracer of the connection.
    /// - Returns: The span.
    /// - Throws: When the tracer does not hold exactly one `lspRequest` span.
    private static func onlyRequestSpan(in tracer: InMemoryTracer) throws -> FinishedInMemorySpan {
        let spans = tracer.finishedSpans.filter { $0.operationName == CodeContextTracing.SpanName.lspRequest }
        #expect(spans.count == 1)
        return try #require(spans.first)
    }

    /// Gives the integer value of an attribute of `span`.
    /// - Parameters:
    ///   - key: The attribute key.
    ///   - span: The span.
    /// - Returns: The value, or `nil` when the span has no integer attribute
    ///   under `key`.
    private static func intValue(of key: String, in span: FinishedInMemorySpan) -> Int64? {
        switch span.attributes.get(key) {
        case .int64(let value):
            value
        default:
            nil
        }
    }
}

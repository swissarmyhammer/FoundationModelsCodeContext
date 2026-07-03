import Foundation
import Testing

@testable import CodeContextKit

/// End-to-end tests for `ProcessLanguageServerConnection`, driven against a
/// real child process: `Support/scripted-lsp-server.swift`, a tiny
/// Content-Length-framed JSON-RPC stub launched the same way a real
/// language server is (`/usr/bin/env swift <script> <script-json>`). See
/// that file's header comment for the scripting DSL.
///
/// Covers the behaviors that only a real process boundary can exercise:
/// request/response over actual pipes, responses arriving out of order,
/// a server-initiated notification surfacing while a request is still
/// in flight, and the injectable-clock timeout path.
struct ConnectionTests {
    /// The absolute path to the scripted subprocess, resolved relative to this test file so it
    /// doesn't depend on the working directory `swift test` is invoked from.
    private static let scriptedServerPath: String = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Support/scripted-lsp-server.swift")
            .path
    }()

    /// Spawns a `ProcessLanguageServerConnection` against the scripted subprocess.
    /// - Parameters:
    ///   - steps: The subprocess's script, per `scripted-lsp-server.swift`'s DSL.
    ///   - requestTimeout: The per-request timeout to configure the connection with.
    ///   - clock: The clock to configure the connection with.
    private static func makeConnection(
        steps: [[String: Any]],
        requestTimeout: Duration = .seconds(30),
        clock: any Clock<Duration> = ContinuousClock()
    ) throws -> ProcessLanguageServerConnection {
        let scriptData = try JSONSerialization.data(withJSONObject: steps)
        let scriptJSON = String(decoding: scriptData, as: UTF8.self)
        return try ProcessLanguageServerConnection(
            command: "swift",
            arguments: [scriptedServerPath, scriptJSON],
            requestTimeout: requestTimeout,
            clock: clock
        )
    }

    /// A minimal wire-shape `DocumentSymbol` JSON object named `name`.
    private static func documentSymbolJSON(name: String) -> [String: Any] {
        [
            "name": name,
            "kind": 12,
            "range": ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 1]],
            "selectionRange": ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 1]],
        ]
    }

    @Test
    func requestReceivesItsScriptedTypedResponse() async throws {
        let steps: [[String: Any]] = [
            ["action": "read"],
            ["action": "respond", "which": 0, "result": [Self.documentSymbolJSON(name: "widget")]],
        ]
        let connection = try Self.makeConnection(steps: steps)

        let symbols = try await connection.documentSymbols(in: DocumentURI("file:///a.swift"))

        #expect(symbols.count == 1)
        #expect(symbols.first?.name == "widget")
        #expect(symbols.first?.kind == .function)

        await connection.close()
    }

    @Test
    func outOfOrderResponsesAreMatchedByIDNotArrivalOrder() async throws {
        // Two concurrent calls, matched by request identity (`uri`) rather than
        // physical read order: nothing guarantees which of two `async let`
        // calls wins the race to be scheduled onto the connection's actor
        // first, so the script targets each response by the document URI its
        // request named, not by "the first/second request read". The
        // subprocess still answers the file:///b.swift request *before* the
        // file:///a.swift request — the wire's classic out-of-order case —
        // but which physical JSON-RPC id that corresponds to is irrelevant:
        // each concurrent caller must receive its own typed result regardless
        // of which id it was assigned or which response arrived first.
        let steps: [[String: Any]] = [
            ["action": "read"],
            ["action": "read"],
            ["action": "respond", "uri": "file:///b.swift", "result": [Self.documentSymbolJSON(name: "b-result")]],
            ["action": "respond", "uri": "file:///a.swift", "result": [Self.documentSymbolJSON(name: "a-result")]],
        ]
        let connection = try Self.makeConnection(steps: steps)

        async let aCall = connection.documentSymbols(in: DocumentURI("file:///a.swift"))
        async let bCall = connection.documentSymbols(in: DocumentURI("file:///b.swift"))
        let (aResult, bResult) = try await (aCall, bCall)

        #expect(aResult.first?.name == "a-result")
        #expect(bResult.first?.name == "b-result")

        await connection.close()
    }

    @Test
    func serverInitiatedPublishDiagnosticsSurfacesWhileARequestIsInFlight() async throws {
        let diagnosticJSON: [String: Any] = [
            "range": ["start": ["line": 1, "character": 0], "end": ["line": 1, "character": 5]],
            "severity": 1,
            "message": "boom",
        ]
        let steps: [[String: Any]] = [
            ["action": "read"],
            [
                "action": "notify",
                "method": "textDocument/publishDiagnostics",
                "params": ["uri": "file:///c.swift", "diagnostics": [diagnosticJSON]],
            ],
            ["action": "respond", "which": 0, "result": [[String: Any]]()],
        ]
        let connection = try Self.makeConnection(steps: steps)

        async let symbolsCall = connection.documentSymbols(in: DocumentURI("file:///c.swift"))

        var notificationIterator = connection.serverNotifications.makeAsyncIterator()
        let notification = await notificationIterator.next()

        let symbols = try await symbolsCall
        #expect(symbols.isEmpty)

        guard case let .publishDiagnostics(uri, diagnostics) = notification else {
            Issue.record("expected a publishDiagnostics notification, got \(String(describing: notification))")
            await connection.close()
            return
        }
        #expect(uri == DocumentURI("file:///c.swift"))
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.message == "boom")
        #expect(diagnostics.first?.severity == .error)

        await connection.close()
    }

    @Test
    func requestFailsWithTimeoutWhenNoResponseArrives() async throws {
        let steps: [[String: Any]] = [
            ["action": "read"],
            ["action": "hang"],
        ]
        let clock = ManualClock()
        let connection = try Self.makeConnection(steps: steps, requestTimeout: .seconds(30), clock: clock)

        let pendingCall = Task {
            try await connection.documentSymbols(in: DocumentURI("file:///never-answered.swift"))
        }

        // Synchronize with the connection's internal timeout race before advancing the clock,
        // rather than racing a real-time sleep against `clock.sleep(for:)`.
        await clock.waitForWaiter()
        clock.advance(by: .seconds(30))

        do {
            _ = try await pendingCall.value
            Issue.record("expected the request to fail with a timeout")
        } catch let error as CodeContextError {
            guard case .timeout = error else {
                Issue.record("expected .timeout, got \(error)")
                await connection.close()
                return
            }
        }

        await connection.close()
    }
}

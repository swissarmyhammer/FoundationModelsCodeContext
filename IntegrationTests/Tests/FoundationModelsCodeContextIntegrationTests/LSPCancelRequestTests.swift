import Foundation
import Testing

@testable import FoundationModelsCodeContext

/// Proves that a request that times out sends the notification
/// `$/cancelRequest` with the id of the request to a real language server
/// subprocess, and that the late reply of the server does not answer the next
/// request.
///
/// The test starts a real `swift <script>` child process that runs the
/// scripted language server of the unit target. Thus it is an integration
/// test, and it lives in this nested package. The unit target tests the
/// timeout and the late-reply drop of the pending-request table without a
/// process, in `PendingRequestTableTests`.
///
/// The connection uses the real clock and the request timeout of
/// `ScriptedLSPServer`. Thus the first request waits for that full time
/// before it fails. The next request then gets its answer at once.
@Suite
internal struct LSPCancelRequestTests {
    /// The JSON-RPC id of the first request that a new connection sends.
    private static let firstClientRequestID = 0

    /// The document of the request that times out.
    private static let timedOutURI = "file:///timed-out.swift"

    /// The document of the request after the timeout.
    private static let nextURI = "file:///next.swift"

    /// The hover text of the late reply to the request that timed out.
    private static let lateHoverText = "late"

    /// The hover text of the reply to the request after the timeout.
    private static let nextHoverText = "next"

    /// A wire-shape `Hover` JSON object that holds `text`.
    /// - Parameter text: The markdown text of the hover.
    /// - Returns: The JSON object, as `JSONSerialization` writes it.
    private static func hoverJSON(text: String) -> [String: Any] {
        ["contents": ["kind": "markdown", "value": text]]
    }

    @Test(.timeLimit(.minutes(1)))
    internal func aTimedOutRequestSendsCancelRequestWithItsID() async throws {
        // The script reads the request, and then reads the `$/cancelRequest` notification and
        // asserts the id that it holds. A missing or wrong notification stops the script, and then
        // the next request fails. The script then answers the timed-out request late, and after
        // that it answers the next request. Thus the next request also proves that the late reply
        // does not answer it.
        let steps: [[String: Any]] = [
            ["action": "read", "expectID": Self.firstClientRequestID, "expectURI": Self.timedOutURI],
            ["action": "read", "expectMethod": "$/cancelRequest", "expectParams": ["id": Self.firstClientRequestID]],
            ["action": "respond", "uri": Self.timedOutURI, "result": Self.hoverJSON(text: Self.lateHoverText)],
            ["action": "read", "expectURI": Self.nextURI],
            ["action": "respond", "uri": Self.nextURI, "result": Self.hoverJSON(text: Self.nextHoverText)],
            ["action": "hang"],
        ]
        let position = Position(line: .zero, character: .zero)

        try await ScriptedLSPServer.withConnection(steps: steps) { connection in
            let error = await #expect(throws: CodeContextError.self) {
                try await connection.hover(in: DocumentURI(Self.timedOutURI), at: position)
            }
            #expect(error?.caseName == "timeout")

            let hover = try await connection.hover(in: DocumentURI(Self.nextURI), at: position)
            #expect(hover?.contents == Self.nextHoverText)
        }
    }
}

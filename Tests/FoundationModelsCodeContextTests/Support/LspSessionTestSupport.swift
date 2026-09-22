import Foundation
import Synchronization

@testable import FoundationModelsCodeContext

extension ServerCapabilities {
    /// Capabilities of a server that advertises each gated method.
    ///
    /// The default of `FakeLanguageServerConnection` and of the test-only
    /// `LspSession(connection:languageID:)`: a test that does not name the
    /// capabilities gets a server that answers each request.
    static let everyGatedMethod = ServerCapabilities(callHierarchy: true, workspaceSymbol: true, implementation: true)
}

extension LspSession {
    /// Creates a session over a server that advertises each gated method,
    /// for tests that are not about the capability gate.
    /// - Parameters:
    ///   - connection: The connection the session drives.
    ///   - languageID: The LSP `languageId` to send on every `didOpen`.
    init(connection: Connection, languageID: String) {
        self.init(connection: connection, languageID: languageID, serverName: "fake-lsp", capabilities: .everyGatedMethod)
    }
}

/// The log lines that a `LspSession` failure log wrote, for tests to read.
///
/// A `Mutex` holds the lines, because the session calls the log sink
/// synchronously from inside its own actor.
final class CapturedLogLines: Sendable {
    /// The lines written so far, oldest first.
    private let lines = Mutex<[String]>([])

    /// Records one log line. Pass this method as the failure log of a session.
    /// - Parameter line: The line the session wrote.
    @Sendable
    func append(_ line: String) {
        lines.withLock { $0.append(line) }
    }

    /// Every line written so far, oldest first.
    var all: [String] {
        lines.withLock { $0 }
    }
}

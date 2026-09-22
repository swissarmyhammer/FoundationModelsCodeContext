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

    /// Capabilities of a server that advertises no gated method.
    ///
    /// `pylsp` 1.14 advertises these capabilities: no call hierarchy, no
    /// workspace symbols and no implementations.
    static let noGatedMethod = ServerCapabilities(callHierarchy: false, workspaceSymbol: false, implementation: false)
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

    /// Makes a Python session over a `pylsp` server that advertises
    /// `capabilities`, and writes its failure log into `failureLog`.
    /// - Parameters:
    ///   - connection: The connection the session drives.
    ///   - capabilities: The gated capabilities that the server advertises.
    ///     Defaults to `ServerCapabilities.noGatedMethod`, as `pylsp` 1.14 does.
    ///   - failureLog: Keeps the failure log lines of the session for the test to read.
    /// - Returns: The session.
    static func makePylsp(
        over connection: Connection,
        advertising capabilities: ServerCapabilities = .noGatedMethod,
        failureLog: CapturedLogLines = CapturedLogLines()
    ) -> LspSession {
        LspSession(
            connection: connection,
            languageID: "python",
            serverName: "pylsp",
            capabilities: capabilities,
            failureLog: failureLog.append
        )
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

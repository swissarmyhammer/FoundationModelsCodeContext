import Foundation
import InMemoryLogging
import Logging

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
    /// `capabilities`, and writes its log records into `logHandler`.
    /// - Parameters:
    ///   - connection: The connection the session drives.
    ///   - capabilities: The gated capabilities that the server advertises.
    ///     Defaults to `ServerCapabilities.noGatedMethod`, as `pylsp` 1.14 does.
    ///   - logHandler: Keeps the log records of the session for the test to read.
    /// - Returns: The session.
    static func makePylsp(
        over connection: Connection,
        advertising capabilities: ServerCapabilities = .noGatedMethod,
        logHandler: InMemoryLogHandler = InMemoryLogHandler()
    ) -> LspSession {
        LspSession(
            connection: connection,
            languageID: "python",
            serverName: "pylsp",
            capabilities: capabilities,
            logger: Logger(label: CodeContextTracing.LoggerLabel.lsp) { _ in logHandler }
        )
    }
}

import Darwin
import Foundation

@testable import FoundationModelsCodeContext

/// A host process for the tests that kill a host with `SIGKILL`.
///
/// The helper starts one language server through the real
/// `ProcessLanguageServerConnection`, as a Code Context host does, runs the
/// `initialize` handshake and an optional hover, writes the pid of the server
/// to its standard output (see `HostConfiguration.serverPIDLine(_:)`), and then
/// waits until something kills it. The test then kills it with `SIGKILL`, thus
/// no `close()` and no `deinit` of the connection runs, and counts what stays
/// of the server.
///
/// The one argument of the helper is a `HostConfiguration` as JSON text. The
/// helper exits with status 1, and writes the error to its standard error,
/// when the configuration or the start of the server fails.
@main
internal enum LanguageServerHost {
    /// The time of one sleep of the wait for the kill.
    private static let idleInterval: Duration = .seconds(idleIntervalSeconds)

    /// The number of seconds in `idleInterval`.
    private static let idleIntervalSeconds = 3600

    /// The version of the document that the hover opens.
    private static let documentVersion = 1

    /// The exit status of a failed start.
    private static let failureStatus: Int32 = 1

    /// Starts the server, writes its pid, and waits for the kill.
    internal static func main() async {
        do {
            let configuration = try HostConfiguration.decoded(fromArguments: CommandLine.arguments)
            let connection = try await startServer(configuration)
            FileHandle.standardOutput.write(Data(HostConfiguration.serverPIDLine(connection.pid).utf8))
            try await waitForKill(holding: connection)
        } catch {
            FileHandle.standardError.write(Data("LanguageServerHost: \(error)\n".utf8))
            exit(failureStatus)
        }
    }

    /// Starts the server of `configuration`, runs the handshake, and sends the
    /// hover of `configuration`. Closes the connection when a step fails.
    /// - Parameter configuration: What the helper starts and asks.
    /// - Returns: The connection to the running server.
    /// - Throws: The error of the start, of the handshake or of the hover.
    private static func startServer(_ configuration: HostConfiguration) async throws -> ProcessLanguageServerConnection {
        let connection = try ProcessLanguageServerConnection(command: configuration.command, arguments: configuration.arguments)
        do {
            let rootURI = DocumentURI(URL(fileURLWithPath: configuration.rootPath, isDirectory: true).absoluteString)
            _ = try await connection.initialize(rootURI: rootURI)
            try await connection.initialized()
            if let hover = configuration.hover {
                try await sendHover(hover, over: connection)
            }
            return connection
        } catch {
            await connection.close()
            throw error
        }
    }

    /// Opens the document of `hover` and sends the hover request.
    /// - Parameters:
    ///   - hover: The document and the position.
    ///   - connection: The connection to the running server.
    /// - Throws: The error of the read of the document, or of a request.
    private static func sendHover(_ hover: HostConfiguration.Hover, over connection: ProcessLanguageServerConnection) async throws {
        let uri = DocumentURI(URL(fileURLWithPath: hover.path).absoluteString)
        let text = try String(contentsOfFile: hover.path, encoding: .utf8)
        try await connection.didOpen(uri: uri, languageID: hover.languageID, version: documentVersion, text: text)
        _ = try await connection.hover(in: uri, at: Position(line: hover.line, character: hover.character))
    }

    /// Keeps `connection` alive until something kills this process.
    /// - Parameter connection: The connection to the running server.
    /// - Throws: `CancellationError`, which does not occur in the helper.
    private static func waitForKill(holding connection: ProcessLanguageServerConnection) async throws {
        defer { withExtendedLifetime(connection) {} }
        while true {
            try await Task.sleep(for: idleInterval)
        }
    }
}

import Darwin
import Foundation

/// What the `LanguageServerHost` helper starts and asks, and the line that it
/// writes when the server runs.
///
/// The test encodes the configuration as JSON text in the one argument of the
/// helper, and reads the line from the standard output of the helper. Both
/// sides use this type, thus the format has one definition.
internal struct HostConfiguration: Codable, Sendable {
    /// A hover request that the helper sends after the handshake, for example
    /// to make `pylsp` start its Jedi subprocess.
    internal struct Hover: Codable, Sendable {
        /// The absolute path of the document. The helper opens it first.
        internal let path: String

        /// The LSP language id of the document, for example `python`.
        internal let languageID: String

        /// The zero-based line of the hover position.
        internal let line: Int

        /// The zero-based UTF-16 character of the hover position.
        internal let character: Int
    }

    /// The errors of `decoded(fromArguments:)`.
    internal enum Failure: Error {
        /// The helper got no argument, or more than one.
        case wrongArgumentCount(Int)
    }

    /// The name of the helper executable.
    internal static let executableName = "LanguageServerHost"

    /// The text in front of the pid of the server on the line that the
    /// helper writes.
    private static let serverPIDPrefix = "server-pid="

    /// The number of arguments of the helper process: the program name and
    /// the JSON text.
    private static let argumentCount = 2

    /// The command of the language server, looked up on `$PATH`.
    internal let command: String

    /// The arguments of the command.
    internal let arguments: [String]

    /// The absolute path of the workspace root that the `initialize`
    /// request names.
    internal let rootPath: String

    /// The hover request after the handshake, or `nil` for none.
    internal let hover: Hover?

    /// Encodes the configuration as the one argument of the helper.
    /// - Returns: The JSON text.
    /// - Throws: The error of the encoder.
    internal func encodedArgument() throws -> String {
        String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }

    /// Decodes the configuration from the arguments of the helper process.
    /// - Parameter arguments: The arguments of the process, the program name
    ///   first.
    /// - Returns: The configuration.
    /// - Throws: `Failure.wrongArgumentCount`, or the error of the decoder.
    internal static func decoded(fromArguments arguments: [String]) throws -> HostConfiguration {
        guard arguments.count == argumentCount, let text = arguments.last else {
            throw Failure.wrongArgumentCount(arguments.count)
        }
        return try JSONDecoder().decode(HostConfiguration.self, from: Data(text.utf8))
    }

    /// The line that the helper writes when its server runs.
    /// - Parameter pid: The pid of the server.
    /// - Returns: The line, with its line break.
    internal static func serverPIDLine(_ pid: pid_t) -> String {
        "\(serverPIDPrefix)\(pid)\n"
    }

    /// Reads the pid of the server from a line that the helper wrote.
    /// - Parameter line: One line of the standard output of the helper, with
    ///   no line break.
    /// - Returns: The pid, or `nil` when the line holds no pid of a server.
    internal static func serverPID(inLine line: String) -> pid_t? {
        guard line.hasPrefix(serverPIDPrefix) else {
            return nil
        }
        return pid_t(line.dropFirst(serverPIDPrefix.count))
    }
}

import Darwin
import Foundation

@testable import FoundationModelsCodeContext
@testable import LanguageServerHost

/// A running `LanguageServerHost` helper process: a host that started one
/// language server through `ProcessLanguageServerConnection` and waits.
internal struct HostProcess {
    /// The errors of `withHost(configuration:_:)`.
    internal enum Failure: Error {
        /// The helper ended its standard output before it wrote the pid of
        /// its server, for example because the server did not start. The
        /// payload is the standard error text of the helper, which names the
        /// cause.
        case noServerPID(standardError: String)
    }

    /// The pid of the language server that the helper started. The server
    /// leads its own process group, thus this is also the id of that group.
    internal let serverPID: pid_t

    /// The helper process.
    private let helper: ProcessGroupChild

    /// Kills the helper with `SIGKILL`, thus no code of the helper runs after
    /// the call, and waits for its reap. Only the helper gets the signal, not
    /// its server.
    internal func kill() async {
        _ = Darwin.kill(helper.pid, SIGKILL)
        await helper.waitUntilExit()
    }

    /// Starts the helper with `configuration`, waits until it wrote the pid of
    /// its server, runs `body`, and then kills the helper and each process
    /// that stays in the group of the server, on every exit path.
    /// - Parameters:
    ///   - configuration: What the helper starts and asks.
    ///   - body: The test body, given the running helper.
    /// - Returns: `body`'s result.
    /// - Throws: `Failure.noServerPID` when the helper wrote no pid, the
    ///   error of the start of the helper, or whatever `body` throws.
    internal static func withHost<T>(
        configuration: HostConfiguration,
        _ body: (HostProcess) async throws -> T
    ) async throws -> T {
        let standardOutput = Pipe()
        let standardError = Pipe()
        let helper = try ProcessGroupChild.spawn(
            executableURL: executableURL,
            arguments: [try configuration.encodedArgument()],
            standardInput: .nullDevice,
            standardOutput: standardOutput,
            standardError: standardError
        )
        var serverPID: pid_t?
        return try await withAsyncCleanup {
            serverPID = try await readServerPID(from: standardOutput)
            guard let serverPID else {
                await helper.waitUntilExit()
                let errorText = String(decoding: standardError.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                throw Failure.noServerPID(standardError: errorText)
            }
            return try await body(HostProcess(serverPID: serverPID, helper: helper))
        } cleanup: {
            helper.signalGroup(SIGKILL)
            await helper.waitUntilExit()
            if let serverPID, !ProcessTable.members(ofGroup: serverPID).isEmpty {
                _ = Darwin.kill(-serverPID, SIGKILL)
            }
        }
    }

    /// The `LanguageServerHost` executable. SwiftPM builds it next to the
    /// test bundle, because the test target depends on it.
    private static var executableURL: URL {
        Bundle(for: BundleMarker.self).bundleURL
            .deletingLastPathComponent()
            .appending(path: HostConfiguration.executableName)
    }

    /// Reads the standard output of the helper until the line that holds the
    /// pid of its server.
    /// - Parameter standardOutput: The pipe that gets the standard output of
    ///   the helper.
    /// - Returns: The pid, or `nil` when the output ends first.
    /// - Throws: The error of a read of the pipe.
    private static func readServerPID(from standardOutput: Pipe) async throws -> pid_t? {
        for try await line in standardOutput.fileHandleForReading.bytes.lines {
            if let pid = HostConfiguration.serverPID(inLine: line) {
                return pid
            }
        }
        return nil
    }
}

/// A class of this test module, for `Bundle(for:)`, which finds the bundle of a
/// class. A struct has no such lookup.
private final class BundleMarker {}

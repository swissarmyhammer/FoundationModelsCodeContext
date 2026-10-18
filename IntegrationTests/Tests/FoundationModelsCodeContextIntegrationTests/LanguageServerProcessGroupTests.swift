import Darwin
import Foundation
import ScriptedLSPServerSupport
import Testing

@testable import FoundationModelsCodeContext

/// Proves that no process of a language server stays alive after its
/// connection stops: `close()` kills the full process group of the server,
/// and the release of a connection with no `close()` kills the server.
///
/// Each test starts a real `sh` or `sleep` child process as the language
/// server.
/// Thus these tests are integration tests, and they live in this nested
/// package. The server never speaks JSON-RPC: the tests read only the process
/// ids and the standard error tail of the connection.
@Suite
internal struct LanguageServerProcessGroupTests {
    /// The number of seconds that each `sleep` process of a server script
    /// sleeps. The time is much longer than each test, thus only a kill stops
    /// the process in the test.
    private static let sleepSeconds = 600

    /// The text in front of the process id that the server script writes to
    /// its standard error.
    private static let childPIDLabel = "child="

    /// The server script that starts one child process and then waits for it.
    /// The child is in the process group of the server, and it is not the
    /// server process. The script writes the process id of the child to its
    /// standard error.
    private static let childStartingScript =
        "sleep \(sleepSeconds) & echo \"\(childPIDLabel)$!\" >&2; wait"

    /// The longest real time that a test waits for the process id of the
    /// child on the standard error of the server.
    private static let childPIDBudget: Duration = .seconds(childPIDBudgetSeconds)

    /// The number of seconds in `childPIDBudget`.
    private static let childPIDBudgetSeconds = 10

    /// The longest real time that a test waits for a killed process to go
    /// away. A process goes away when its parent reaps it, some milliseconds
    /// after the kill.
    private static let exitBudget: Duration = .seconds(exitBudgetSeconds)

    /// The number of seconds in `exitBudget`.
    private static let exitBudgetSeconds = 5

    /// The time between two checks of a process.
    private static let pollInterval: Duration = .milliseconds(pollIntervalMilliseconds)

    /// The number of milliseconds in `pollInterval`.
    private static let pollIntervalMilliseconds = 10

    @Test(.timeLimit(.minutes(1)))
    internal func closeKillsTheChildProcessThatTheServerStarted() async throws {
        let connection = try ProcessLanguageServerConnection(
            command: "sh",
            arguments: ["-c", Self.childStartingScript]
        )
        let childPID = try await withAsyncCleanup {
            try await Self.childPID(of: connection)
        } cleanup: {
            await connection.close()
        }

        #expect(try await Self.waitUntilGone(childPID), "the child process of the server is alive after close()")
    }

    @Test(.timeLimit(.minutes(1)))
    internal func releasingTheConnectionWithNoCloseKillsTheServerProcess() async throws {
        var connection: ProcessLanguageServerConnection? = try ProcessLanguageServerConnection(
            command: "sleep",
            arguments: [String(Self.sleepSeconds)]
        )
        let serverPID = try #require(connection?.pid)
        #expect(processExists(serverPID), "the server process did not start")

        connection = nil

        #expect(
            try await Self.waitUntilGone(serverPID),
            "the server process is alive after the release of its connection"
        )
    }

    /// Reads the process id of the child from the standard error tail of the
    /// server.
    /// - Parameter connection: The connection to the server that runs
    ///   `childStartingScript`.
    /// - Returns: The process id of the child.
    /// - Throws: When the tail holds no process id in `childPIDBudget`.
    private static func childPID(of connection: ProcessLanguageServerConnection) async throws -> pid_t {
        let isWritten = try await poll(budget: childPIDBudget, interval: pollInterval) {
            parsedChildPID(in: connection.recentStderrTail()) != nil
        }
        #expect(isWritten, "the server wrote no child process id to its standard error")
        return try #require(parsedChildPID(in: connection.recentStderrTail()))
    }

    /// Finds the process id after `childPIDLabel` in `text`.
    /// - Parameter text: The standard error tail of the server.
    /// - Returns: The process id, or `nil` when `text` holds no complete id.
    private static func parsedChildPID(in text: String) -> pid_t? {
        guard let labelRange = text.range(of: childPIDLabel) else {
            return nil
        }
        let line = text[labelRange.upperBound...].prefix { $0 != "\n" }
        return pid_t(line)
    }

    /// Polls until no process has the id `pid`, for at most `exitBudget`.
    /// - Parameter pid: The process id to check.
    /// - Returns: `true` when the process goes away in the budget.
    /// - Throws: `CancellationError` when the test is cancelled.
    private static func waitUntilGone(_ pid: pid_t) async throws -> Bool {
        try await poll(budget: exitBudget, interval: pollInterval) {
            !processExists(pid)
        }
    }
}

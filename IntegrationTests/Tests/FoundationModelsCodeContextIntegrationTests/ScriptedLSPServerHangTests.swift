import Darwin
import Foundation
import ScriptedLSPServerSupport
import Testing

@testable import FoundationModelsCodeContext

/// Proves that the "hang" step of the scripted language server stops the
/// script when the standard input of the script closes.
///
/// When a test binary crashes, no code calls `close()` on the connection, and
/// no code kills the process group of the script. The exit of the test binary
/// closes only the write end of the standard input pipe of the script. A
/// script that does not stop at the end of its standard input then stays
/// alive with the parent process id 1.
///
/// The test starts a real `swift <script>` child process, thus it is an
/// integration test, and it lives in this nested package. It starts the child
/// with `ProcessGroupChild.spawn`, not through a connection, because a
/// connection cannot close only the standard input of its server.
/// `ProcessGroupChild` keeps the exited child unreaped while the test holds it,
/// thus its process id stays until the cleanup. So the test reads the exit
/// from `ProcessGroupChild.isRunning`, which is `false` from the exit on.
@Suite
internal struct ScriptedLSPServerHangTests {
    /// The line that the script writes to its standard error just before its
    /// "hang" step.
    private static let hangStepMarker = "the script is at its hang step"

    /// The steps of the script: write `hangStepMarker`, then hang.
    private static var steps: [[String: Any]] {
        [
            ["action": "stderr", "text": "\(hangStepMarker)\n"],
            ["action": "hang"],
        ]
    }

    /// The longest real time that the test waits for the script to go away
    /// after its standard input closes. The script exits some milliseconds
    /// after the close, thus the value is very generous for a busy machine.
    private static let exitBudget: Duration = .seconds(exitBudgetSeconds)

    /// The number of seconds in `exitBudget`.
    private static let exitBudgetSeconds = 30

    /// The time between two checks of the process.
    private static let pollInterval: Duration = .milliseconds(pollIntervalMilliseconds)

    /// The number of milliseconds in `pollInterval`.
    private static let pollIntervalMilliseconds = 10

    @Test(.timeLimit(.minutes(1)))
    internal func aHangStepStopsTheScriptWhenItsStandardInputCloses() async throws {
        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()
        let child = try ProcessGroupChild.spawn(
            executableURL: URL(fileURLWithPath: ProcessUtilities.envExecutablePath),
            arguments: [ScriptedLSPServer.command] + ScriptedLSPServer.arguments(steps: Self.steps),
            standardInput: .pipe(standardInput),
            standardOutput: standardOutput,
            standardError: standardError
        )
        let pid = child.pid

        try await withAsyncCleanup {
            try #require(try await Self.waitForHangStepMarker(on: standardError), "the script did not reach its hang step")
            #expect(processExists(pid), "the script stopped before its standard input closed")

            try standardInput.fileHandleForWriting.close()

            let isExited = try await poll(budget: Self.exitBudget, interval: Self.pollInterval) {
                !child.isRunning
            }
            #expect(isExited, "the script at its hang step is alive after its standard input closed")
        } cleanup: {
            child.signalGroup(SIGKILL)
            await child.waitUntilExit()
            withExtendedLifetime(standardOutput) {}
        }
    }

    /// Reads the standard error of the script until it holds
    /// `hangStepMarker`, or until it ends.
    /// - Parameter standardError: The pipe that gets the standard error of the
    ///   script.
    /// - Returns: `true` when a line holds `hangStepMarker`; `false` when the
    ///   standard error ends first, for example because the script did not
    ///   compile.
    /// - Throws: The error of a read of the pipe.
    private static func waitForHangStepMarker(on standardError: Pipe) async throws -> Bool {
        for try await line in standardError.fileHandleForReading.bytes.lines where line.contains(hangStepMarker) {
            return true
        }
        return false
    }
}

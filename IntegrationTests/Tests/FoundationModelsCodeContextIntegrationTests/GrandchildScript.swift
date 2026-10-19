import Darwin
import Foundation
import ScriptedLSPServerSupport

@testable import FoundationModelsCodeContext

/// The script steps and the checks of the tests that give the scripted
/// language server a child process of its own: a grandchild of the host.
///
/// The grandchild models the Jedi subprocess of `pylsp`. It is in the process
/// group of the server, and it ignores `SIGTERM`. See the "spawnGrandchild"
/// step in the header comment of the script.
internal enum GrandchildScript {
    /// What the grandchild does after its start.
    internal enum Wait {
        /// The grandchild sleeps, and only `SIGKILL` stops it. It shows that a
        /// stop of the server kills each process of its group.
        case sleep

        /// The grandchild reads its standard input until the end of the file,
        /// and then exits, as the Jedi subprocess does. The server holds the
        /// write end of that input, thus the grandchild exits when the server
        /// exits.
        case untilEndOfInput

        /// Whether the step asks for an exit at the end of the input.
        fileprivate var exitsAtEndOfInput: Bool {
            switch self {
            case .sleep:
                false
            case .untilEndOfInput:
                true
            }
        }
    }

    /// The longest real time that a test waits for the scripted server to
    /// start its grandchild. The `swift` interpreter compiles the script before
    /// the first step runs, which can take some seconds on a busy machine.
    internal static let startBudget: Duration = .seconds(startBudgetSeconds)

    /// The number of seconds in `startBudget`.
    private static let startBudgetSeconds = 30

    /// The longest real time that a test waits for a process to go away.
    internal static let exitBudget: Duration = .seconds(exitBudgetSeconds)

    /// The number of seconds in `exitBudget`.
    private static let exitBudgetSeconds = 30

    /// The time between two checks of a process or of the pid file.
    internal static let pollInterval: Duration = .milliseconds(pollIntervalMilliseconds)

    /// The number of milliseconds in `pollInterval`.
    private static let pollIntervalMilliseconds = 20

    /// The steps that answer the `initialize` request and read the
    /// `initialized` notification of the client.
    internal static var handshakeSteps: [[String: Any]] {
        [
            ["action": "read", "expectMethod": "initialize"],
            ["action": "respond", "which": 0, "result": ["capabilities": [String: Any]()]],
            ["action": "read", "expectMethod": "initialized"],
        ]
    }

    /// The steps that answer the `shutdown` request and read the `exit`
    /// notification. The script ends after them, thus the server exits as a
    /// real server does, and only its grandchild stays in its group.
    internal static var shutdownSteps: [[String: Any]] {
        [
            ["action": "read", "expectMethod": "shutdown"],
            ["action": "respond", "which": shutdownRequestIndex, "result": NSNull()],
            ["action": "read", "expectMethod": "exit"],
        ]
    }

    /// The read-order index of the `shutdown` request in a script that runs
    /// `handshakeSteps` first: after `initialize` and `initialized`.
    private static let shutdownRequestIndex = 2

    /// The step that starts a grandchild and writes its pid to `pidFile`.
    /// - Parameters:
    ///   - pidFile: The file that gets the pid of the grandchild.
    ///   - wait: What the grandchild does after its start.
    /// - Returns: The step.
    internal static func spawnStep(pidFile: URL, wait: Wait) -> [String: Any] {
        ["action": "spawnGrandchild", "pidFile": pidFile.path, "exitsAtEndOfInput": wait.exitsAtEndOfInput]
    }

    /// The spec of a scripted server that runs `steps`, for a daemon or a
    /// supervisor that starts the server through the production connection
    /// factory.
    /// - Parameter steps: The script steps.
    /// - Returns: The spec.
    /// - Throws: When the steps cannot be encoded as JSON, or when the joined
    ///   script file cannot be written.
    internal static func serverSpec(steps: [[String: Any]]) throws -> ServerSpec {
        ServerSpec(
            command: ScriptedLSPServer.command,
            arguments: try ScriptedLSPServer.arguments(steps: steps),
            languageIDs: ["swift"],
            installHint: "the scripted server needs no install"
        )
    }

    /// Polls `pidFile` until a server wrote a pid to it, then removes the
    /// file, thus a later wait reads the pid of a later server.
    /// - Parameter pidFile: The file of a "spawnGrandchild" step.
    /// - Returns: The pid of the grandchild, or `nil` when no server wrote the
    ///   file in `startBudget`.
    /// - Throws: `CancellationError` when the test is cancelled.
    internal static func takeGrandchildPID(from pidFile: URL) async throws -> pid_t? {
        var pid: pid_t?
        try await poll(budget: startBudget, interval: pollInterval) {
            pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { pid_t($0) }
            return pid != nil
        }
        try? FileManager.default.removeItem(at: pidFile)
        return pid
    }

    /// Polls until no process has the id `pid`, for at most `exitBudget`.
    /// - Parameter pid: The process id to check.
    /// - Returns: `true` when the process goes away in the budget.
    /// - Throws: `CancellationError` when the test is cancelled.
    internal static func waitUntilGone(_ pid: pid_t) async throws -> Bool {
        try await poll(budget: exitBudget, interval: pollInterval) {
            !processExists(pid)
        }
    }

    /// Polls until the process group `groupID` has no process.
    /// - Parameters:
    ///   - groupID: The process group of a server.
    ///   - budget: The longest real time to wait. Defaults to `exitBudget`.
    /// - Returns: `true` when the group has no process in the budget.
    /// - Throws: `CancellationError` when the test is cancelled.
    internal static func waitUntilGroupIsEmpty(_ groupID: pid_t, budget: Duration = exitBudget) async throws -> Bool {
        try await poll(budget: budget, interval: pollInterval) {
            ProcessTable.members(ofGroup: groupID).isEmpty
        }
    }

    /// Kills each process that a failed test left in the group `groupID`. A
    /// test that passes leaves no process, and the call then does nothing.
    /// - Parameter groupID: The process group of a server.
    internal static func killLeftovers(ofGroup groupID: pid_t) {
        _ = kill(-groupID, SIGKILL)
    }
}

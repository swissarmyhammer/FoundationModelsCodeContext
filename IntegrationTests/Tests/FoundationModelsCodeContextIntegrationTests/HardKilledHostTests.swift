import Darwin
import Foundation
import Testing

@testable import FoundationModelsCodeContext
@testable import LanguageServerHost

/// Proves what stays of a language server when its host process is killed with
/// `SIGKILL`, thus no `close()` and no `deinit` runs.
///
/// A helper host process (`LanguageServerHost`) starts the server through the
/// real `ProcessLanguageServerConnection`, writes the pid of the server, and
/// waits. The test kills the helper with `SIGKILL`, as the SWE-bench harness
/// kills an agent at its time limit, and then counts the processes left in the
/// process group of the server. The server leads that group, thus each process
/// in it belongs to this server and to no other host on the machine.
///
/// The kill closes the pipes of the helper. The server reads the end of its
/// standard input and exits, and a child of the server that reads a pipe from
/// the server then reads the end of that pipe. The Jedi subprocess of `pylsp`
/// is such a child. A child of the server that reads no pipe from the server
/// does not see the death of the host, and nothing kills it: see the
/// documentation of `ProcessLanguageServerConnection`.
///
/// The tests start real processes, thus they are integration tests, and they
/// live in this nested package.
@Suite
internal struct HardKilledHostTests {
    /// The name of the pid file of the grandchild in the workspace of a test.
    private static let pidFileName = "grandchild.pid"

    /// The longest real time that the server group of the real `pylsp` test
    /// gets to go away after the kill of the host. `pylsp` reads the end of
    /// its input only after it answered each request that it read before, and
    /// the probe of 2026-10-19 measured up to 35 seconds for a backlog of
    /// 3000 requests. The test sends one request, thus it needs much less.
    private static let pylspExitBudget: Duration = .seconds(pylspExitBudgetSeconds)

    /// The number of seconds in `pylspExitBudget`.
    private static let pylspExitBudgetSeconds = 45

    /// The Python fixture of the real `pylsp` test. The hover on `join`
    /// makes Jedi infer a compiled module, which starts its subprocess.
    private static let pythonSource = "import os\n\n\ndef helper():\n    return os.path.join('a', 'b')\n"

    /// The hover position of the real `pylsp` test: on `join`.
    private static let pythonHoverPosition = Position(line: 4, character: 20)

    @Test(.timeLimit(.minutes(1)))
    internal func aHardKilledHostLeavesNoProcessOfTheScriptedServerGroup() async throws {
        try await withTemporaryWorkspace { root in
            let pidFile = root.appending(path: Self.pidFileName)
            let steps = GrandchildScript.handshakeSteps + [
                GrandchildScript.spawnStep(pidFile: pidFile, wait: .untilEndOfInput),
                ["action": "hang"],
            ]
            let configuration = HostConfiguration(
                command: ScriptedLSPServer.command,
                arguments: try ScriptedLSPServer.arguments(steps: steps),
                rootPath: root.path,
                hover: nil
            )
            try await HostProcess.withHost(configuration: configuration) { host in
                let grandchildPID = try #require(try await GrandchildScript.takeGrandchildPID(from: pidFile))
                #expect(ProcessTable.groupID(of: grandchildPID) == host.serverPID, "the grandchild is not in the group of the server")

                await host.kill()

                let isEmpty = try await GrandchildScript.waitUntilGroupIsEmpty(host.serverPID)
                #expect(isEmpty, "processes of the server group stay after the kill of the host: \(Self.describeGroup(host.serverPID))")
            }
        }
    }

    @Test(.enabled(if: LiveServers.isPylspOnPath, "pylsp not found on $PATH"), .timeLimit(.minutes(2)))
    internal func aHardKilledHostLeavesNoPylspOrJediProcess() async throws {
        try await withTemporaryWorkspace { root in
            try write(Self.pythonSource, to: "sample.py", in: root)
            let configuration = HostConfiguration(
                command: "pylsp",
                arguments: [],
                rootPath: root.path,
                hover: HostConfiguration.Hover(
                    path: root.appending(path: "sample.py").path,
                    languageID: "python",
                    line: Self.pythonHoverPosition.line,
                    character: Self.pythonHoverPosition.character
                )
            )
            try await HostProcess.withHost(configuration: configuration) { host in
                #expect(
                    JediProcesses.count(inGroupOf: host.serverPID) > .zero,
                    "the hover started no Jedi subprocess, thus the test proves nothing: \(Self.describeGroup(host.serverPID))"
                )

                await host.kill()

                let isEmpty = try await GrandchildScript.waitUntilGroupIsEmpty(host.serverPID, budget: Self.pylspExitBudget)
                #expect(isEmpty, "pylsp processes stay after the kill of the host: \(Self.describeGroup(host.serverPID))")
            }
        }
    }

    /// Describes each process of the group `groupID`, for a failure message.
    /// - Parameter groupID: The process group of a server.
    /// - Returns: One `<pid> <arguments>` entry for each member.
    private static func describeGroup(_ groupID: pid_t) -> String {
        ProcessTable.members(ofGroup: groupID)
            .map { pid in "\(pid) \(ProcessTable.arguments(of: pid).joined(separator: " "))" }
            .joined(separator: "; ")
    }
}

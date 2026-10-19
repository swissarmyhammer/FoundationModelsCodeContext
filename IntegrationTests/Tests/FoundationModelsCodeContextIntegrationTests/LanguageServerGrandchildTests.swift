import Darwin
import Foundation
import Testing

@testable import FoundationModelsCodeContext

/// Proves that each way to stop a language server also kills the child process
/// that the server started, also when that child ignores `SIGTERM` and does not
/// stop when the server exits.
///
/// The grandchild models the Jedi subprocess of `pylsp`: `pylsp` starts it with
/// a plain `subprocess.Popen`, thus it is in the process group of `pylsp`. The
/// scripted server starts it with the "spawnGrandchild" step, as a `sleep` that
/// ignores `SIGTERM`. Only a `SIGKILL` to the group stops it, thus each test
/// fails when a stop path signals only the server, or skips `close()`.
///
/// The tests start real `swift <script>` processes, thus they are integration
/// tests, and they live in this nested package.
@Suite
internal struct LanguageServerGrandchildTests {
    /// The name of the pid file of the grandchild in the workspace of a test.
    private static let pidFileName = "grandchild.pid"

    /// The shutdown grace that the daemon test gives its daemon. The scripted
    /// server exits right after the `exit` notification, thus a short grace is
    /// sufficient.
    private static let daemonShutdownGrace: Duration = .seconds(daemonShutdownGraceSeconds)

    /// The number of seconds in `daemonShutdownGrace`.
    private static let daemonShutdownGraceSeconds = 2

    @Test(.timeLimit(.minutes(1)))
    internal func closeKillsAGrandchildThatIgnoresSIGTERM() async throws {
        try await withTemporaryWorkspace { root in
            let pidFile = root.appending(path: Self.pidFileName)
            let steps = [GrandchildScript.spawnStep(pidFile: pidFile, wait: .sleep), ["action": "hang"]]
            try await ScriptedLSPServer.withConnection(steps: steps) { connection in
                let grandchildPID = try #require(
                    try await GrandchildScript.takeGrandchildPID(from: pidFile),
                    "the scripted server started no grandchild"
                )
                #expect(ProcessTable.groupID(of: grandchildPID) == connection.pid, "the grandchild is not in the group of the server")

                await connection.close()

                #expect(try await GrandchildScript.waitUntilGone(grandchildPID), "the grandchild is alive after close()")
                GrandchildScript.killLeftovers(ofGroup: connection.pid)
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    internal func forceRestartKillsTheGrandchildOfTheOldServer() async throws {
        try await withTemporaryWorkspace { root in
            let pidFile = root.appending(path: Self.pidFileName)
            let spec = try GrandchildScript.serverSpec(steps: Self.serverSteps(pidFile: pidFile))
            let daemon = LSPDaemon<ProcessLanguageServerConnection>(
                spec: spec,
                workspaceRoot: root,
                connectionFactory: LSPDaemon<ProcessLanguageServerConnection>.processConnectionFactory()
            )
            await daemon.setShutdownGrace(Self.daemonShutdownGrace)
            try await withAsyncCleanup {
                try await daemon.start()
                let oldGrandchildPID = try #require(try await GrandchildScript.takeGrandchildPID(from: pidFile))

                try await daemon.forceRestart()

                #expect(
                    try await GrandchildScript.waitUntilGone(oldGrandchildPID),
                    "the grandchild of the old server is alive after forceRestart()"
                )
                let newGrandchildPID = try #require(try await GrandchildScript.takeGrandchildPID(from: pidFile))
                await daemon.shutdown()
                #expect(try await GrandchildScript.waitUntilGone(newGrandchildPID), "the grandchild is alive after shutdown()")
            } cleanup: {
                await daemon.shutdown()
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    internal func supervisorShutdownAndStartKillTheGrandchildOfEachServer() async throws {
        try await withTemporaryWorkspace { root in
            let pidFile = root.appending(path: Self.pidFileName)
            let spec = try GrandchildScript.serverSpec(steps: Self.serverSteps(pidFile: pidFile))
            let supervisor = LspSupervisor<ProcessLanguageServerConnection>(
                workspaceRoot: root,
                serverSpecs: { _ in [spec] },
                connectionFactory: LSPDaemon<ProcessLanguageServerConnection>.processConnectionFactory()
            )
            try await withAsyncCleanup {
                for round in ["first start", "second start"] {
                    try await supervisor.start()
                    let grandchildPID = try #require(
                        try await GrandchildScript.takeGrandchildPID(from: pidFile),
                        "the server of the \(round) started no grandchild"
                    )

                    await supervisor.shutdown()

                    #expect(
                        try await GrandchildScript.waitUntilGone(grandchildPID),
                        "the grandchild of the \(round) is alive after the supervisor shutdown"
                    )
                }
            } cleanup: {
                await supervisor.shutdown()
            }
        }
    }

    /// The steps of a server that a daemon starts: the handshake, a grandchild
    /// that sleeps, and the shutdown.
    /// - Parameter pidFile: The file that gets the pid of the grandchild.
    /// - Returns: The steps.
    private static func serverSteps(pidFile: URL) -> [[String: Any]] {
        GrandchildScript.handshakeSteps
            + [GrandchildScript.spawnStep(pidFile: pidFile, wait: .sleep)]
            + GrandchildScript.shutdownSteps
    }
}

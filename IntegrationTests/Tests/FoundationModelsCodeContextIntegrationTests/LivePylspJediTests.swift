import Darwin
import Foundation
import Testing

@testable import FoundationModelsCodeContext

/// Real-`pylsp` test of the Jedi subprocesses of one session: the count stays
/// bounded while the session answers requests across several files, and a
/// restart or a stop of the server leaves none of the old server.
///
/// Each count reads only the process group of the `pylsp` that the daemon
/// started (see `JediProcesses`), thus a `pylsp` of another host on the machine
/// does not change it. The `.enabled(if:)` trait skips the test when `pylsp`
/// is not on `$PATH`.
@Suite
internal struct LivePylspJediTests {
    /// The Python modules of the fixture, by file name. Each one uses a
    /// compiled module of the standard library, thus each hover or definition
    /// makes Jedi ask its subprocess.
    private static let modules: [(name: String, source: String)] = [
        ("first.py", "import os\n\n\ndef first():\n    return os.path.join('a', 'b')\n"),
        ("second.py", "import json\nfrom first import first\n\ndef second():\n    return json.dumps(first())\n"),
        ("third.py", "import math\nfrom second import second\n\ndef third():\n    return math.floor(len(second()))\n"),
    ]

    /// The positions that the test asks about in each module, on the `return`
    /// line: the name of the standard library module, and the name of the
    /// member of that module.
    private static let positions = [Position(line: 4, character: 11), Position(line: 4, character: 16)]

    /// The most Jedi subprocesses that one session may have at a time. Jedi
    /// starts one subprocess for each Python environment; the fixture has one.
    /// The bound allows one more for a subprocess that Jedi starts again.
    private static let maximumJediCount = 2

    /// The shutdown grace of the daemon: the production default.
    private static let shutdownGrace = LSPDaemonLimits.defaultShutdownGrace

    @Test(.enabled(if: LiveServers.isPylspOnPath, "pylsp not found on $PATH"), .timeLimit(.minutes(2)))
    internal func theJediCountStaysBoundedInOneSessionAndARestartOrAStopLeavesNone() async throws {
        try await withTemporaryWorkspace { root in
            for module in Self.modules {
                try write(module.source, to: module.name, in: root)
            }
            let spec = try #require(PythonLanguage.languageServer)
            let daemon = LSPDaemon<ProcessLanguageServerConnection>(
                spec: spec,
                workspaceRoot: root,
                connectionFactory: LSPDaemon<ProcessLanguageServerConnection>.processConnectionFactory()
            )
            await daemon.setShutdownGrace(Self.shutdownGrace)
            try await withAsyncCleanup {
                try await daemon.start()
                let session = try #require(await daemon.session())
                let pylspPID = try #require(Self.runningPID(in: await daemon.state()), "the daemon is not running after start()")

                let counts = try await Self.jediCountsAfterRequests(session: session, root: root, pylspPID: pylspPID)

                #expect((counts.max() ?? .zero) > .zero, "no request started a Jedi subprocess, thus the test proves nothing")
                #expect(counts.allSatisfy { $0 <= Self.maximumJediCount }, "the Jedi count grew in one session: \(counts)")

                try await daemon.forceRestart()

                #expect(
                    try await GrandchildScript.waitUntilGroupIsEmpty(pylspPID),
                    "pylsp or Jedi processes of the old server stay after the restart: \(JediProcesses.count(inGroupOf: pylspPID)) Jedi"
                )
                let restartedSession = try #require(await daemon.session())
                let restartedPID = try #require(Self.runningPID(in: await daemon.state()), "the daemon is not running after forceRestart()")
                let restartedCounts = try await Self.jediCountsAfterRequests(session: restartedSession, root: root, pylspPID: restartedPID)
                #expect(
                    restartedCounts.allSatisfy { $0 <= Self.maximumJediCount },
                    "the Jedi count grew in the session after the restart: \(restartedCounts)"
                )

                await daemon.shutdown()

                #expect(
                    try await GrandchildScript.waitUntilGroupIsEmpty(restartedPID),
                    "pylsp or Jedi processes stay after the stop: \(JediProcesses.count(inGroupOf: restartedPID)) Jedi"
                )
            } cleanup: {
                await daemon.shutdown()
            }
        }
    }

    /// Gives the pid of the server of a running daemon.
    /// - Parameter state: The state of the daemon.
    /// - Returns: The pid of `.running`, or `nil` for each other state.
    private static func runningPID(in state: LSPDaemonState) -> pid_t? {
        guard case .running(let pid) = state else {
            return nil
        }
        return pid_t(pid)
    }

    /// Opens each module, asks a hover and a definition at each position, and
    /// counts the Jedi subprocesses after each request.
    /// - Parameters:
    ///   - session: The session of the running `pylsp`.
    ///   - root: The workspace root that holds the modules.
    ///   - pylspPID: The pid of `pylsp`, the id of its process group.
    /// - Returns: The count after each request, in order.
    /// - Throws: The error of a request.
    private static func jediCountsAfterRequests(
        session: LspSession<ProcessLanguageServerConnection>,
        root: URL,
        pylspPID: pid_t
    ) async throws -> [Int] {
        var counts: [Int] = []
        for module in modules {
            let url = root.appending(path: module.name)
            let uri = DocumentURI(url.absoluteString)
            try await session.syncOpen(uri: uri, text: module.source)
            for position in positions {
                _ = try await session.hover(uri: uri, at: position)
                counts.append(JediProcesses.count(inGroupOf: pylspPID))
                _ = try await session.definition(uri: uri, at: position)
                counts.append(JediProcesses.count(inGroupOf: pylspPID))
            }
        }
        return counts
    }
}

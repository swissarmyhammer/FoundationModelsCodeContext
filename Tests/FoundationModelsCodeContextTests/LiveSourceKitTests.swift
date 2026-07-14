import Darwin
import Foundation
import Testing

@testable import FoundationModelsCodeContext

/// Gated, real-`sourcekit-lsp` end-to-end smoke test, per plan.md's testing strategy: spawn a real
/// daemon against a temp Swift package fixture, confirm a live `definition` answer, `kill -9` the
/// daemon's child process, and assert the supervisor auto-restarts it (state evidence, not log
/// scraping) before a fresh `definition` succeeds again.
///
/// Skipped whenever `CCK_LIVE_LSP` isn't `"1"` (the suite-level trait below), and skipped again —
/// this time per-test, since the suite-level gate might legitimately be on for a machine that
/// still lacks a Swift toolchain — whenever `sourcekit-lsp` isn't resolvable on `$PATH`. Both use
/// Swift Testing's `.enabled(if:)` trait rather than an in-body early return: unlike a test that
/// merely returns having made no assertions (which reports as a vacuous *pass*), a disabled
/// `ConditionTrait` reports the test as genuinely *skipped*, matching this task's acceptance
/// criteria ("the suite reports skipped, exit 0") precisely.
///
/// `.serialized`-style isolation isn't declared here (there is exactly one `@Test` in this suite),
/// but every real subprocess this test spawns is guaranteed torn down on every exit path via
/// `withLiveContext`, mirroring `ConnectionTests.swift`'s `withConnection` helper — see that type's
/// doc comment for the leaked-process/leaked-thread incident this pattern exists to prevent.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CCK_LIVE_LSP"] == "1", "gated behind CCK_LIVE_LSP=1"))
struct LiveSourceKitTests {
    /// The fixture's only source file, relative to the fixture's root — the path every
    /// `context.definition(filePath:...)` call in this suite targets.
    private static let fixtureRelativePath = "Sources/Fixture/Greeter.swift"

    /// The zero-based line of `fixtureRelativePath`'s `return helper()` call.
    private static let fixtureCallLine = 2

    /// A zero-based character offset squarely inside the `helper` identifier on
    /// `fixtureCallLine` (not at either edge of the token), so an off-by-one in this constant
    /// can't accidentally land outside the identifier sourcekit-lsp resolves against.
    private static let fixtureCallCharacter = 17

    // MARK: - Availability

    /// Whether `sourcekit-lsp` resolves on `$PATH`, checked the same way a shell resolves a bare
    /// command name — mirrors `LSPDaemon`'s private `isExecutableOnPath(_:)`, reimplemented here
    /// (rather than reached into across the file, where it's `private`) since this is a distinct,
    /// test-only availability probe rather than the daemon's own startup guard.
    private static var isSourceKitLSPOnPath: Bool {
        guard let pathVariable = ProcessInfo.processInfo.environment["PATH"] else { return false }
        return pathVariable.split(separator: ":").contains { directory in
            FileManager.default.isExecutableFile(atPath: (String(directory) as NSString).appendingPathComponent("sourcekit-lsp"))
        }
    }

    // MARK: - Fixture

    /// Writes a minimal, real SwiftPM package fixture into `root`: a `Package.swift` manifest (so
    /// `ProjectDetection` spawns a real `sourcekit-lsp` daemon rooted here, unlike
    /// `CodeContextE2ETests`' deliberately marker-less fixtures) plus one source file whose
    /// `greet()` calls the free function `helper()` in the same file — same-file symbol
    /// resolution sourcekit-lsp can answer without waiting on a full background package build.
    private static func writeFixture(in root: URL) throws {
        try write(
            """
            // swift-tools-version: 6.1
            import PackageDescription

            let package = Package(
                name: "Fixture",
                targets: [
                    .target(name: "Fixture")
                ]
            )
            """,
            to: "Package.swift",
            in: root
        )
        try write(
            """
            struct Greeter {
                func greet() -> String {
                    return helper()
                }
            }

            func helper() -> String {
                "hello"
            }
            """,
            to: fixtureRelativePath,
            in: root
        )
    }

    // MARK: - Connection factory

    /// Mirrors `LSPDaemon.processConnectionFactory(clock:)`, but with an overridable per-request
    /// timeout: this suite's very first `textDocument/definition` request can race a real,
    /// cold-started `sourcekit-lsp`'s background package-graph resolution, and the 30-second
    /// production default has less headroom than this smoke test needs to stay reliable on a
    /// loaded machine.
    /// - Parameter requestTimeout: The per-request timeout every spawned connection is configured with.
    /// - Returns: A factory that spawns `spec.command` with `spec.args` as a real child process.
    private static func liveConnectionFactory(requestTimeout: Duration) -> ConnectionFactory<ProcessLanguageServerConnection> {
        { spec, _ in
            let connection = try ProcessLanguageServerConnection(
                command: spec.command,
                arguments: spec.args,
                requestTimeout: requestTimeout
            )
            return ConnectionHandle(
                connection: connection,
                pid: connection.pid,
                isAlive: { await connection.isRunning() },
                waitForExit: { await connection.waitUntilExit() },
                terminate: { await connection.close() },
                stderrTail: { connection.recentStderrTail() }
            )
        }
    }

    /// Builds a `CodeContext<ProcessLanguageServerConnection>` for `rootDirectory`, runs `body`
    /// against it, and guarantees `context.stop()` runs on every exit path (success or throw) —
    /// see this type's doc comment for why that guarantee matters here.
    /// - Parameters:
    ///   - rootDirectory: The workspace root to open.
    ///   - body: The test body, given the live-wired facade.
    /// - Returns: `body`'s result.
    /// - Throws: Rethrows whatever `body` (or `CodeContext.start()`) throws, after `stop()` has
    ///   already run.
    private static func withLiveContext<T: Sendable>(
        rootDirectory: URL,
        _ body: (CodeContext<ProcessLanguageServerConnection>) async throws -> T
    ) async throws -> T {
        let context = try await CodeContext<ProcessLanguageServerConnection>(
            rootDirectory: rootDirectory,
            embedder: FakeEmbedder(dimension: 8),
            connectionFactory: Self.liveConnectionFactory(requestTimeout: .seconds(90))
        )
        do {
            let result = try await body(context)
            await context.stop()
            return result
        } catch {
            await context.stop()
            throw error
        }
    }

    // MARK: - Polling

    /// Polls `condition` at `interval` until it returns `true` or `budget` elapses (real wall-clock
    /// time — this suite drives a real subprocess, so no injectable clock applies).
    /// - Parameters:
    ///   - budget: The total time to keep polling before giving up.
    ///   - interval: How long to sleep between polls. Defaults to 250ms.
    ///   - condition: Checked before every sleep; polling stops the moment it returns `true`.
    /// - Returns: `true` if `condition` became true within `budget`; `false` otherwise.
    @discardableResult
    private static func poll(
        budget: Duration,
        interval: Duration = .milliseconds(250),
        until condition: () async throws -> Bool
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: budget)
        while true {
            if try await condition() { return true }
            guard clock.now < deadline else { return false }
            try await Task.sleep(for: interval)
        }
    }

    /// The current status of the managed `sourcekit-lsp` daemon, if any.
    /// - Parameter context: The facade to read `lspStatus()` from.
    /// - Returns: The `sourcekit-lsp` entry from `context.lspStatus()`, or `nil` if it isn't (yet)
    ///   managed.
    private static func sourceKitStatus(_ context: CodeContext<ProcessLanguageServerConnection>) async -> ServerStatus? {
        await context.lspStatus().first { $0.command == "sourcekit-lsp" }
    }

    /// Polls `context.definition(...)` at the fixture's call site until it answers from the live
    /// LSP layer, or `budget` elapses.
    /// - Parameters:
    ///   - context: The facade to query.
    ///   - budget: The total time to keep retrying before giving up.
    /// - Returns: The last observed `DefinitionResult` (whether or not it ultimately reached
    ///   `.liveLSP` within budget).
    /// - Throws: Rethrows whatever `context.definition(...)` throws.
    private static func pollForLiveDefinition(
        context: CodeContext<ProcessLanguageServerConnection>,
        budget: Duration
    ) async throws -> DefinitionResult? {
        var lastResult: DefinitionResult?
        try await Self.poll(budget: budget, interval: .milliseconds(500)) {
            let result = try await context.definition(
                filePath: Self.fixtureRelativePath,
                line: Self.fixtureCallLine,
                character: Self.fixtureCallCharacter
            )
            lastResult = result
            return result.sourceLayer == .liveLSP
        }
        return lastResult
    }

    // MARK: - The smoke test

    @Test(.enabled(if: LiveSourceKitTests.isSourceKitLSPOnPath, "sourcekit-lsp not found on $PATH"))
    func liveSourceKitSurvivesACrashAndAutoRestarts() async throws {
        try await withTemporaryWorkspace { root in
            try Self.writeFixture(in: root)

            try await Self.withLiveContext(rootDirectory: root) { context in
                try await context.start()

                // `start()` returns once the *tree-sitter/embedding* settle is synchronous, but a
                // Swift-backed workspace's LSP indexing layer only drains via the background
                // `LSPIndexWorker` task it spawns — so `state.isReady` may still read `false` for a
                // moment after `start()` returns. Poll for it rather than asserting immediately.
                let becameReady = try await Self.poll(budget: .seconds(90)) {
                    await context.state.isReady
                }
                #expect(becameReady, "workspace never reached state.isReady within budget")

                guard case let .running(originalPid) = await Self.sourceKitStatus(context)?.state else {
                    Issue.record("expected sourcekit-lsp to be .running after settling, got \(String(describing: await Self.sourceKitStatus(context)))")
                    return
                }
                #expect(originalPid > 0)

                // Live definition, before crashing anything.
                let firstResult = try await Self.pollForLiveDefinition(context: context, budget: .seconds(60))
                #expect(firstResult?.sourceLayer == .liveLSP, "expected a live-LSP definition before the crash, got \(String(describing: firstResult))")

                // Crash the daemon's child process out from under the supervisor.
                #expect(kill(originalPid, SIGKILL) == 0, "kill -9 on the daemon's own pid failed")

                // Wait for restart evidence read from `state.servers` itself (never log scraping):
                // a `.failed` status with a nonzero attempt count, followed by `.running` again
                // under a *different* pid — proof a fresh process was actually spawned, not that
                // the killed one somehow lingered as "running".
                var observedFailedWithAttempts = false
                var restartedPid: Int32?
                try await Self.poll(budget: .seconds(150), interval: .milliseconds(200)) {
                    switch await Self.sourceKitStatus(context)?.state {
                    case let .failed(_, attempts) where attempts >= 1:
                        observedFailedWithAttempts = true
                        return false
                    case let .running(pid) where pid != originalPid:
                        restartedPid = pid
                        return true
                    default:
                        return false
                    }
                }
                #expect(observedFailedWithAttempts, "never observed a .failed(attempts >= 1) status between the kill and the restart")
                #expect(restartedPid != nil, "supervisor never restarted sourcekit-lsp under a fresh pid")

                // Post-restart: a fresh definition must succeed again over the new process.
                let secondResult = try await Self.pollForLiveDefinition(context: context, budget: .seconds(60))
                #expect(secondResult?.sourceLayer == .liveLSP, "expected a live-LSP definition after the restart, got \(String(describing: secondResult))")
            }
        }
    }
}

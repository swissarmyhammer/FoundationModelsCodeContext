import Foundation
import Testing

@testable import FoundationModelsCodeContext

/// End-to-end tests for the `CodeContext` facade, driven entirely against `FakeLanguageServerConnection`
/// and `FakeEmbedder` — no real subprocess, no real FSEvents stream, and (since every fixture here has
/// no project-marker file) no real LSP daemon ever spawns. This exercises the facade's own lifecycle
/// wiring (`init` → `start()` → ops → `stop()`) rather than re-testing any individual subsystem, which
/// already has its own dedicated test suite.
///
/// Fixtures deliberately omit `Package.swift`/`*.xcodeproj` markers so `ProjectDetection.detectProjects`
/// finds nothing: this keeps every test here free of the "does a real `sourcekit-lsp` need to be on
/// `$PATH`" concern the gated live smoke test (a separate, later task) owns instead. `CodeContext.start()`
/// still settles deterministically in this configuration, because every file's language has no
/// registered LSP server, so the facade's own `markUncoveredLspFilesDone()` step marks the LSP layer
/// trivially drained.
struct CodeContextE2ETests {
    /// Builds a `CodeContext<FakeLanguageServerConnection>` for `rootDirectory`, wired to a fake
    /// filesystem-event source (never a real FSEvents stream) and a fake LSP connection factory (never
    /// invoked in these tests, since no fixture here has a detected project/server spec, but still
    /// required to satisfy the general initializer's type).
    private static func makeCodeContext(
        rootDirectory: URL,
        embedder: TextEmbedding
    ) async throws -> CodeContext<FakeLanguageServerConnection> {
        try await CodeContext<FakeLanguageServerConnection>(
            rootDirectory: rootDirectory,
            embedder: embedder,
            eventSource: FakeFileEventSource(),
            connectionFactory: fakeConnectionFactory(pid: 1, processState: ProcessState())
        )
    }

    /// Writes a small, deterministic two-symbol Swift fixture (`Greeter.greet()` calling the free
    /// function `helper()`) into `root`, with no project marker file.
    private static func writeFixture(in root: URL) throws {
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
            to: "Greeter.swift",
            in: root
        )
    }

    // MARK: - Full lifecycle

    @Test
    func fullLifecycleFixtureStartsAnswersOpsAndStopsCleanly() async throws {
        try await withTemporaryWorkspace { root in
            try Self.writeFixture(in: root)

            let context = try await Self.makeCodeContext(rootDirectory: root, embedder: FakeEmbedder(dimension: 8))

            try await context.start()

            #expect(await context.state.isReady)

            let symbolMatches = try await context.searchSymbol(query: "greet")
            #expect(symbolMatches.contains { $0.name == "greet" })

            let codeResult = try await context.searchCode(query: "hello")
            #expect(codeResult.query == "hello")

            let graph = try await context.callGraph(of: "greet", direction: .outbound)
            #expect(graph.root.name == "greet")

            let report = try await context.diagnostics(scope: .file("Greeter.swift"))
            #expect(report.pending == false)

            await context.stop()

            // stop() must be safe to call again (idempotent no-op) and must not hang.
            await context.stop()
        }
    }

    // MARK: - start() retry after failure

    @Test
    func startResetsIsStartedOnFailureSoARetryActuallyStarts() async throws {
        try await withTemporaryWorkspace { root in
            try Self.writeFixture(in: root)
            try write("func blocked() {}", to: "Blocked/Blocked.swift", in: root)

            let context = try await Self.makeCodeContext(rootDirectory: root, embedder: FakeEmbedder(dimension: 8))

            // Block read access to a subdirectory so `Reconciler.reconcile`'s directory walk
            // (`start()`'s first throwing step) fails without touching the store's own already-open
            // database file under `.code-context/`.
            let blockedDirectory = root.appendingPathComponent("Blocked")
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blockedDirectory.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blockedDirectory.path) }

            await #expect(throws: (any Error).self) {
                try await context.start()
            }

            // Restore access and retry. A buggy `start()` that leaves `isStarted` permanently
            // `true` after the failure above would make this second call silently no-op (return
            // without throwing, but without ever actually starting anything) instead of genuinely
            // retrying.
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blockedDirectory.path)

            try await context.start()

            // A meaningful assertion, not a vacuous one: `state.isReady` alone would pass even on
            // a `guard !isStarted else { return }` no-op retry, since a workspace with zero files
            // ever walked is trivially "drained". Checking `filesWalked > 0` and that the fixture's
            // symbol is actually indexed proves this second `start()` call genuinely re-ran
            // `Reconciler.reconcile` and the tree-sitter drain, not that it silently did nothing.
            let status = await context.indexStatus()
            #expect(status.filesWalked > 0)
            let symbolMatches = try await context.searchSymbol(query: "greet")
            #expect(symbolMatches.contains { $0.name == "greet" })

            await context.stop()
        }
    }

    // MARK: - detectProjects() re-scan

    @Test
    func detectProjectsRescansAfterAddingMarkerFile() async throws {
        try await withTemporaryWorkspace { root in
            try Self.writeFixture(in: root)

            let context = try await Self.makeCodeContext(rootDirectory: root, embedder: FakeEmbedder(dimension: 8))
            try await context.start()

            let initialProjects = await context.state.projects
            #expect(initialProjects.isEmpty)

            try write("// swift-tools-version: 6.1\n", to: "Package.swift", in: root)

            let rescanned = try await context.detectProjects()
            #expect(rescanned.contains { $0.language == "swift" })

            let publishedProjects = await context.state.projects
            #expect(publishedProjects.contains { $0.language == "swift" })

            await context.stop()
        }
    }

    // MARK: - rebuildIndex / indexStatus round-trip

    @Test
    func rebuildIndexTreeSitterRedrainsAndIndexStatusReflectsIt() async throws {
        try await withTemporaryWorkspace { root in
            try Self.writeFixture(in: root)

            let context = try await Self.makeCodeContext(rootDirectory: root, embedder: FakeEmbedder(dimension: 8))
            try await context.start()

            let settledStatus = await context.indexStatus()
            #expect(settledStatus.filesWalked > 0)
            #expect(settledStatus.isDrained)

            let rebuildResult = try await context.rebuildIndex(layer: .treeSitter)
            #expect(rebuildResult.layer == .treeSitter)
            #expect(rebuildResult.filesMarked > 0)

            let redrainedStatus = await context.indexStatus()
            #expect(redrainedStatus.isDrained)
            #expect(redrainedStatus.filesParsed == redrainedStatus.filesWalked)

            await context.stop()
        }
    }

    // MARK: - Dual-workspace isolation

    @Test
    func twoCodeContextsOnTwoWorkspacesRunConcurrentlyWithoutInterference() async throws {
        try await withTemporaryWorkspace { rootA in
            try await withTemporaryWorkspace { rootB in
                try write(
                    """
                    func onlyInWorkspaceA() -> Int { 1 }
                    """,
                    to: "A.swift",
                    in: rootA
                )
                try write(
                    """
                    func onlyInWorkspaceB() -> Int { 2 }
                    """,
                    to: "B.swift",
                    in: rootB
                )

                let contextA = try await Self.makeCodeContext(rootDirectory: rootA, embedder: FakeEmbedder(dimension: 8))
                let contextB = try await Self.makeCodeContext(rootDirectory: rootB, embedder: FakeEmbedder(dimension: 8))

                async let startA: Void = contextA.start()
                async let startB: Void = contextB.start()
                _ = try await (startA, startB)

                async let matchesA = contextA.searchSymbol(query: "onlyInWorkspaceA")
                async let matchesB = contextB.searchSymbol(query: "onlyInWorkspaceB")
                let (foundInA, foundInB) = try await (matchesA, matchesB)

                #expect(foundInA.contains { $0.name == "onlyInWorkspaceA" })
                #expect(foundInB.contains { $0.name == "onlyInWorkspaceB" })

                // Each workspace's index is independent: workspace A never sees workspace B's symbol.
                let crossCheckA = try await contextA.searchSymbol(query: "onlyInWorkspaceB")
                #expect(!crossCheckA.contains { $0.name == "onlyInWorkspaceB" })

                async let stopA: Void = contextA.stop()
                async let stopB: Void = contextB.stop()
                _ = await (stopA, stopB)
            }
        }
    }

    // MARK: - Auto-install / isReady integration

    /// Whether this test's PHP fixture can genuinely exercise the auto-install path: `npm` (the
    /// `intelephense` installer's `tool`) must be resolvable on `$PATH` so `ServerInstaller`'s own
    /// early `BinaryLookup.isOnPath(installer.tool)` gate passes and actually reaches (and can
    /// therefore be gated by) the injected `FakeInstallRunner`; and `intelephense` itself must be
    /// *absent* so the daemon genuinely lands `.notFound` rather than starting `.running`
    /// immediately because the machine running this test happens to already have it installed.
    /// Checked via the same shared `BinaryLookup` helper `LSPDaemon`/`ServerInstaller` use for
    /// their own real `$PATH` lookups. Mirrors `LiveSourceKitTests`' own `.enabled(if:)` gating
    /// pattern: a genuine *skip* (not a vacuous pass) when the environment doesn't support the
    /// scenario, in either direction.
    private static var canExercisePHPAutoInstall: Bool {
        BinaryLookup.isOnPath("npm") && !BinaryLookup.isOnPath("intelephense")
    }

    @Test(.enabled(if: CodeContextE2ETests.canExercisePHPAutoInstall, "gated on npm present and intelephense absent from $PATH"))
    func isReadyIsFalseWhileAnAutoInstallIsPendingAndTrueOnceItResolves() async throws {
        try await withTemporaryWorkspace { root in
            try write("{\"name\": \"fixture/fixture\"}", to: "composer.json", in: root)

            // Scripted to fail (never actually installs anything) and gated shut up front: a fake
            // install that resolved before this test's own very next statement got scheduled
            // (especially under load) could otherwise flicker straight past the `.installing`
            // assertion below into an already-`.notFound` re-settle. Closing the gate guarantees
            // the install cannot resolve until this test explicitly opens it — reachable here only
            // because `canExercisePHPAutoInstall` above confirmed `npm` (`intelephense`'s
            // installer tool) really is on `$PATH`, so `ServerInstaller.install(spec:)` actually
            // proceeds to (and suspends on) this runner rather than short-circuiting before ever
            // reaching it.
            let runner = FakeInstallRunner()
            await runner.updateResult(.success(InstallRunResult(exitCode: 1, output: "boom")))
            await runner.closeGate()

            let context = try await CodeContext<FakeLanguageServerConnection>(
                rootDirectory: root,
                embedder: FakeEmbedder(dimension: 8),
                eventSource: FakeFileEventSource(),
                installRunner: runner,
                connectionFactory: fakeConnectionFactory(pid: 1, processState: ProcessState())
            )

            try await context.start()

            // Immediately after start() returns, the intelephense daemon must already be
            // observably `.installing` (per `LspSupervisor`'s no-flicker guarantee), so `isReady`
            // must already be `false` — not merely "eventually" once some background loop catches
            // up.
            #expect(!(await context.state.isReady), "isReady must be false the moment start() returns while the auto-install is pending")
            let statusesWhileInstalling = await context.lspStatus()
            #expect(statusesWhileInstalling.first { $0.command == "intelephense" }?.state == .installing)

            // Release the gated install now that the pending-install assertions above are made.
            await runner.openGate()

            // Poll (real time, bounded) until the failed install's forced restart has re-landed
            // `.notFound`, at which point isReady must become true again.
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while ContinuousClock.now < deadline {
                if await context.state.isReady { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(await context.state.isReady, "isReady must become true again once the failed auto-install resolves and the daemon re-settles")

            let finalState = await context.lspStatus().first { $0.command == "intelephense" }?.state
            #expect(finalState == .notFound, "the daemon must re-settle at .notFound, not .running or .failed")

            let invocations = await runner.invocations
            #expect(invocations.count == 1, "the installer must run exactly once")

            await context.stop()
        }
    }
}

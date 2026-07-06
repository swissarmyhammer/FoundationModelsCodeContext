import Foundation
import GRDB
import Testing

@testable import CodeContextKit

/// Tests for `Sources/CodeContextKit/Diagnostics/`: the settle engine's
/// quiescence/hard-timeout timing, severity-floor filtering, scope
/// resolution (working tree / file glob / sha range) against a real temp git
/// repo fixture, dependents fold-in seeded through real `lsp_call_edges`
/// rows, and the pending-flag truth table.
struct DiagnosticsTests {
    // MARK: - Fixtures

    private static func diagnostic(severity: DiagnosticSeverity, message: String) -> Diagnostic {
        Diagnostic(
            range: LSPRange(start: Position(line: 0, character: 0), end: Position(line: 0, character: 1)),
            severity: severity,
            code: nil,
            source: nil,
            message: message
        )
    }

    /// Runs `git` in `directory`, failing the test on a non-zero exit code —
    /// the shared fixture helper every scope-resolution test uses to build a
    /// real temp git repo.
    ///
    /// Delegates to the production `GitShell.run(arguments:in:)` rather than
    /// spawning its own `Process`, both to avoid duplicating that logic and
    /// so every `git` invocation in this test file — fixture setup and the
    /// `DiagnosticsScopeResolver` calls under test alike — funnels through
    /// `GitShell`'s single serial dispatch queue (see its doc comment).
    @discardableResult
    private static func runGit(_ arguments: [String], in directory: URL) async throws -> String {
        do {
            return try await GitShell.run(arguments: arguments, in: directory)
        } catch {
            Issue.record("git \(arguments) failed: \(error.localizedDescription)")
            return ""
        }
    }

    private static func initRepo(at root: URL) async throws {
        try await runGit(["init"], in: root)
        try await runGit(["config", "user.email", "test@example.com"], in: root)
        try await runGit(["config", "user.name", "Test"], in: root)
    }

    private static func commitAll(in root: URL, message: String) async throws {
        try await runGit(["add", "-A"], in: root)
        try await runGit(["commit", "-m", message], in: root)
    }

    /// Inserts an `indexed_files` row (via `Reconciler.reconcile`) for every
    /// path in `paths`, satisfying `lsp_symbols`/`lsp_call_edges`' foreign
    /// keys, mirroring `CallGraphOpsTests`' identical fixture helper.
    private static func seedIndexedFiles(store: Store, root: URL, paths: [String]) async throws {
        for path in paths {
            try write("// fixture\n", to: path, in: root)
        }
        _ = try await Reconciler.reconcile(store: store, rootDirectory: root)
    }

    private static func insertSymbol(store: Store, id: Int64, name: String, filePath: String) async throws {
        try await store.write { db in
            try db.execute(
                sql: """
                INSERT INTO lsp_symbols (id, name, kind, file_path, start_line, start_column, end_line, end_column)
                VALUES (?, ?, 'function', ?, 0, 0, 10, 0)
                """,
                arguments: [id, name, filePath]
            )
        }
    }

    private static func insertEdge(store: Store, callerID: Int64, calleeID: Int64, filePath: String) async throws {
        try await store.write { db in
            try db.execute(
                sql: """
                INSERT INTO lsp_call_edges (caller_id, callee_id, file_path, from_ranges, source)
                VALUES (?, ?, ?, '[]', 'lsp')
                """,
                arguments: [callerID, calleeID, filePath]
            )
        }
    }

    // MARK: - Settle timing matrix (manual clock)

    @Test
    func settleFiresAfterQuiescenceWindowWhenNoUpdatesArrive() async throws {
        let clock = ManualClock()
        let (stream, continuation) = AsyncStream<DiagnosticUpdate>.makeStream()
        let uri = DocumentURI("file:///repo/a.swift")

        let task = Task {
            await Settle.settleStream(
                stream: stream,
                watched: [uri],
                initial: [uri: []],
                settleWindow: .milliseconds(300),
                hardTimeout: .seconds(5),
                clock: clock
            )
        }

        await clock.waitForWaiter(count: 2)
        clock.advance(by: .milliseconds(300))

        let outcome = await task.value
        #expect(outcome == .settled([uri: []]))
        continuation.finish()
    }

    @Test
    func updateAtT200RestartsQuiescenceWindowSoSettleFiresAtT500NotT300() async throws {
        let clock = ManualClock()
        let (stream, continuation) = AsyncStream<DiagnosticUpdate>.makeStream()
        let uri = DocumentURI("file:///repo/a.swift")
        let diag = Self.diagnostic(severity: .error, message: "boom")

        let task = Task {
            await Settle.settleStream(
                stream: stream,
                watched: [uri],
                initial: [uri: []],
                settleWindow: .milliseconds(300),
                hardTimeout: .seconds(5),
                clock: clock
            )
        }

        await clock.waitForWaiter(count: 2)
        clock.advance(by: .milliseconds(200))
        continuation.yield(DiagnosticUpdate(uri: uri, diagnostics: [diag]))

        // Wait specifically for the *restarted* debounce window's own deadline (200ms now +
        // 300ms settleWindow = 500ms) to actually be registered on the clock before advancing any
        // further — not a fixed real-time sleep guessing that the drain task has recorded the
        // update and the settle loop has looped back by then. `waitForWaiter(count:)` alone can't
        // tell "the stale iteration-1 waiters are still registered" apart from "the restarted
        // iteration-2 waiters are registered", since it only checks a count, and a fixed sleep can
        // be wrong for however long the code under test's own scheduling is starved — see task
        // `^vhcye6y`: this exact gap caused two full-suite hangs under severe scheduler contention
        // even though `Settle`/`UpdateMailbox` were already correct.
        await clock.waitForWaiter(withDeadline: ManualClock.Instant(offset: .milliseconds(500)))

        // The window must have restarted: at t=300 (the *original* deadline)
        // the task must still be running, not settled.
        clock.advance(by: .milliseconds(100))
        try await Task.sleep(for: .milliseconds(20))
        #expect(task.isCancelled == false)

        clock.advance(by: .milliseconds(200)) // now at t=500, the *restarted* deadline
        let outcome = await task.value
        #expect(outcome == .settled([uri: [diag]]))
        continuation.finish()
    }

    @Test
    func continuousUpdatesResultInPendingAtHardTimeout() async throws {
        let clock = ManualClock()
        let (stream, continuation) = AsyncStream<DiagnosticUpdate>.makeStream()
        let uri = DocumentURI("file:///repo/a.swift")

        let task = Task {
            await Settle.settleStream(
                stream: stream,
                watched: [uri],
                initial: [uri: []],
                settleWindow: .milliseconds(300),
                hardTimeout: .seconds(5),
                clock: clock
            )
        }

        for _ in 0 ..< 19 {
            await clock.waitForWaiter(count: 2)
            clock.advance(by: .milliseconds(250))
            continuation.yield(DiagnosticUpdate(uri: uri, diagnostics: []))
            // A real (short) suspension every iteration, giving the settle
            // task's race loop an actual chance to run: `waitForWaiter`'s
            // guard can be satisfied by waiters left over from the
            // *previous* iteration without ever truly suspending, which
            // would otherwise let this tight loop starve the settle task of
            // scheduling time before it can process each update and
            // re-arm its debounce sleep.
            try await Task.sleep(for: .milliseconds(5))
        }
        // 19 * 250ms = 4750ms elapsed; push past the 5s hard deadline.
        await clock.waitForWaiter(count: 2)
        clock.advance(by: .milliseconds(500))

        let outcome = await task.value
        #expect(outcome == .pending)
        continuation.finish()
    }

    @Test
    func updatesForUnwatchedURIsAreIgnored() async throws {
        let clock = ManualClock()
        let (stream, continuation) = AsyncStream<DiagnosticUpdate>.makeStream()
        let watchedURI = DocumentURI("file:///repo/watched.swift")
        let otherURI = DocumentURI("file:///repo/other.swift")

        let task = Task {
            await Settle.settleStream(
                stream: stream,
                watched: [watchedURI],
                initial: [watchedURI: []],
                settleWindow: .milliseconds(300),
                hardTimeout: .seconds(5),
                clock: clock
            )
        }

        await clock.waitForWaiter(count: 2)
        continuation.yield(DiagnosticUpdate(uri: otherURI, diagnostics: [Self.diagnostic(severity: .error, message: "ignored")]))
        clock.advance(by: .milliseconds(300))

        let outcome = await task.value
        #expect(outcome == .settled([watchedURI: []]))
        continuation.finish()
    }

    // MARK: - Severity floor + pending flag truth table (full pipeline)

    @Test
    func defaultSeverityFloorExcludesHintAndInformationDiagnostics() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("let x = 1\n", to: "a.swift", in: root)
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)

            let connection = FakeLanguageServerConnection()
            await connection.setPullDiagnosticsResult(.success([
                Self.diagnostic(severity: .error, message: "err"),
                Self.diagnostic(severity: .warning, message: "warn"),
                Self.diagnostic(severity: .information, message: "info"),
                Self.diagnostic(severity: .hint, message: "hint"),
            ]))
            let session = LspSession(connection: connection, languageID: "swift")

            let report = try await DiagnosticsOps.diagnostics(
                store: store,
                session: session,
                rootDirectory: root,
                scope: .file("a.swift"),
                severity: .warning,
                includeDependents: false,
                clock: ContinuousClock()
            )

            #expect(report.records.map(\.message).sorted() == ["err", "warn"])
            #expect(report.pending == false)
        }
    }

    @Test
    func loweringFloorToHintIncludesEveryDiagnostic() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("let x = 1\n", to: "a.swift", in: root)
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)

            let connection = FakeLanguageServerConnection()
            await connection.setPullDiagnosticsResult(.success([
                Self.diagnostic(severity: .error, message: "err"),
                Self.diagnostic(severity: .warning, message: "warn"),
                Self.diagnostic(severity: .information, message: "info"),
                Self.diagnostic(severity: .hint, message: "hint"),
            ]))
            let session = LspSession(connection: connection, languageID: "swift")

            let report = try await DiagnosticsOps.diagnostics(
                store: store,
                session: session,
                rootDirectory: root,
                scope: .file("a.swift"),
                severity: .hint,
                includeDependents: false,
                clock: ContinuousClock()
            )

            #expect(report.records.map(\.message).sorted() == ["err", "hint", "info", "warn"])
        }
    }

    @Test
    func noSessionMeansNoLiveLayerAndNeverPending() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("let x = 1\n", to: "a.swift", in: root)
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)

            let report = try await DiagnosticsOps.diagnostics(
                store: store,
                session: Optional<LspSession<FakeLanguageServerConnection>>.none,
                rootDirectory: root,
                scope: .file("a.swift"),
                includeDependents: false,
                clock: ManualClock()
            )

            #expect(report.records.isEmpty)
            #expect(report.pending == false)
        }
    }

    @Test
    func serverRunningButNotReadyFlagsReportPendingEvenWhenEmpty() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("let x = 1\n", to: "a.swift", in: root)
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)

            let connection = FakeLanguageServerConnection()
            // ServerCancelled (-32802): the LSP "still loading" signal that
            // flips LspSession.isReady to false.
            await connection.setPullDiagnosticsResult(.failure(WireError.serverError(code: -32802, message: "still loading")))
            let session = LspSession(connection: connection, languageID: "swift")

            let report = try await DiagnosticsOps.diagnostics(
                store: store,
                session: session,
                rootDirectory: root,
                scope: .file("a.swift"),
                includeDependents: false,
                clock: ContinuousClock()
            )

            #expect(report.records.isEmpty)
            #expect(report.pending == true)
        }
    }

    @Test
    func settleTimeoutFlagsReportPending() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("let x = 1\n", to: "a.swift", in: root)
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)

            let connection = FakeLanguageServerConnection()
            await connection.setPullDiagnosticsResult(.success([]))
            let session = LspSession(connection: connection, languageID: "swift")
            let clock = ManualClock()

            let diagnoseTask = Task {
                try await DiagnosticsOps.diagnostics(
                    store: store,
                    session: session,
                    rootDirectory: root,
                    scope: .file("a.swift"),
                    includeDependents: false,
                    hardTimeout: .seconds(5),
                    clock: clock
                )
            }

            let uri = DocumentURI(root.appendingPathComponent("a.swift").absoluteString)
            for _ in 0 ..< 19 {
                await clock.waitForWaiter(count: 2)
                clock.advance(by: .milliseconds(250))
                await connection.emit(notification: .publishDiagnostics(uri: uri, diagnostics: []))
                // See the identical comment in `continuousUpdatesResultInPendingAtHardTimeout`.
                try await Task.sleep(for: .milliseconds(5))
            }
            await clock.waitForWaiter(count: 2)
            clock.advance(by: .milliseconds(500))

            let report = try await diagnoseTask.value
            #expect(report.pending == true)
        }
    }

    // MARK: - Scope resolution against a temp git repo fixture

    @Test
    func workingTreeScopeResolvesModifiedUntrackedAndStagedFiles() async throws {
        try await withTemporaryWorkspace { root in
            try write("let a = 1\n", to: "tracked.swift", in: root)
            try write("let b = 1\n", to: "untouched.swift", in: root)
            try await Self.initRepo(at: root)
            try await Self.commitAll(in: root, message: "initial")

            // Unstaged modification.
            try write("let a = 2\n", to: "tracked.swift", in: root)
            // Untracked new file.
            try write("let c = 1\n", to: "new.swift", in: root)
            // Staged new file.
            try write("let d = 1\n", to: "staged.swift", in: root)
            try await Self.runGit(["add", "staged.swift"], in: root)

            let resolved = try await DiagnosticsScopeResolver.resolvePaths(scope: .workingTree, rootDirectory: root)

            #expect(Set(resolved) == ["tracked.swift", "new.swift", "staged.swift"])
            #expect(resolved.contains("untouched.swift") == false)
        }
    }

    @Test
    func fileScopeExpandsGlobPatternsUnderRoot() async throws {
        try await withTemporaryWorkspace { root in
            try write("// a\n", to: "src/a.swift", in: root)
            try write("// b\n", to: "src/b.swift", in: root)
            try write("// c\n", to: "src/c.txt", in: root)
            try await Self.initRepo(at: root)
            try await Self.commitAll(in: root, message: "initial")

            let resolved = try await DiagnosticsScopeResolver.resolvePaths(scope: .file("src/*.swift"), rootDirectory: root)

            #expect(Set(resolved) == ["src/a.swift", "src/b.swift"])
        }
    }

    @Test
    func fileScopeWithLiteralPathReturnsThatOnePath() async throws {
        try await withTemporaryWorkspace { root in
            try write("// a\n", to: "src/a.swift", in: root)
            try await Self.initRepo(at: root)
            try await Self.commitAll(in: root, message: "initial")

            let resolved = try await DiagnosticsScopeResolver.resolvePaths(scope: .file("src/a.swift"), rootDirectory: root)

            #expect(resolved == ["src/a.swift"])
        }
    }

    @Test
    func shaScopeResolvesFilesChangedSinceARange() async throws {
        try await withTemporaryWorkspace { root in
            try write("let a = 1\n", to: "a.swift", in: root)
            try await Self.initRepo(at: root)
            try await Self.commitAll(in: root, message: "first")
            let firstSHA = try await Self.runGit(["rev-parse", "HEAD"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)

            try write("let b = 1\n", to: "b.swift", in: root)
            try await Self.commitAll(in: root, message: "second")

            let resolved = try await DiagnosticsScopeResolver.resolvePaths(scope: .sha(firstSHA), rootDirectory: root)

            #expect(resolved == ["b.swift"])
        }
    }

    @Test
    func scopeResolutionExcludesNonDiagnosableExtensions() async throws {
        try await withTemporaryWorkspace { root in
            try write("hello", to: "README.md", in: root)
            try await Self.initRepo(at: root)
            try await Self.commitAll(in: root, message: "initial")
            try write("hello world", to: "README.md", in: root)

            let resolved = try await DiagnosticsScopeResolver.resolvePaths(scope: .workingTree, rootDirectory: root)

            #expect(resolved.isEmpty)
        }
    }

    // MARK: - Dependents fold-in

    @Test
    func oneHopDependentsResolvesInboundCallersViaBlastRadius() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await Self.seedIndexedFiles(store: store, root: root, paths: ["target.swift", "caller.swift"])
            try await Self.insertSymbol(store: store, id: 1, name: "target_fn", filePath: "target.swift")
            try await Self.insertSymbol(store: store, id: 2, name: "caller_fn", filePath: "caller.swift")
            try await Self.insertEdge(store: store, callerID: 2, calleeID: 1, filePath: "caller.swift")

            let dependents = await DiagnosticsOps<FakeLanguageServerConnection>.oneHopDependents(store: store, filePath: "target.swift")

            #expect(dependents == ["caller.swift"])
        }
    }

    @Test
    func oneHopDependentsExcludesSelfAndReturnsEmptyForUnindexedFile() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)

            let dependents = await DiagnosticsOps<FakeLanguageServerConnection>.oneHopDependents(store: store, filePath: "nonexistent.swift")

            #expect(dependents.isEmpty)
        }
    }

    @Test
    func buildReportExcludesCleanDependentsAndRanksBrokenOnesAfterTargets() throws {
        let targetURI = DocumentURI("file:///repo/target.swift")
        let brokenDependentURI = DocumentURI("file:///repo/broken.swift")
        let cleanDependentURI = DocumentURI("file:///repo/clean.swift")
        let noisyDependentURI = DocumentURI("file:///repo/noisy.swift")

        let uriDiagnostics: [DocumentURI: [Diagnostic]] = [
            targetURI: [Self.diagnostic(severity: .error, message: "target error")],
            brokenDependentURI: [Self.diagnostic(severity: .warning, message: "one warning")],
            cleanDependentURI: [],
            noisyDependentURI: [
                Self.diagnostic(severity: .error, message: "e1"),
                Self.diagnostic(severity: .error, message: "e2"),
            ],
        ]

        let report = DiagnosticsOps<FakeLanguageServerConnection>.buildReport(
            uriDiagnostics: uriDiagnostics,
            targets: ["target.swift"],
            dependentFiles: ["broken.swift", "clean.swift", "noisy.swift"],
            rootDirectory: URL(fileURLWithPath: "/repo"),
            severity: .warning,
            perReportCap: 100,
            pending: false
        )

        // `noisy.swift` contributes two records (its two seeded errors), so
        // it appears twice, consecutively, ahead of `broken.swift`'s single
        // record — ranking is per *file* (errors-then-warnings-then-path),
        // not per individual record.
        let paths = report.records.map(\.path)
        #expect(paths == ["target.swift", "noisy.swift", "noisy.swift", "broken.swift"], "broken dependents rank after targets, most-errors-first; clean dependents are excluded entirely")
        #expect(report.records.contains { $0.path == "clean.swift" } == false)
    }

    @Test
    func buildReportCapsTotalRecordsAtPerReportCap() throws {
        var uriDiagnostics: [DocumentURI: [Diagnostic]] = [:]
        let targetURI = DocumentURI("file:///repo/target.swift")
        uriDiagnostics[targetURI] = (0 ..< 150).map { Self.diagnostic(severity: .error, message: "e\($0)") }

        let report = DiagnosticsOps<FakeLanguageServerConnection>.buildReport(
            uriDiagnostics: uriDiagnostics,
            targets: ["target.swift"],
            dependentFiles: [],
            rootDirectory: URL(fileURLWithPath: "/repo"),
            severity: .warning,
            perReportCap: 100,
            pending: false
        )

        #expect(report.records.count == 100)
    }

    @Test
    func countsReflectOnlyErrorsAndWarnings() {
        let records = [
            DiagnosticRecord(path: "a.swift", range: Self.pointRange, severity: .error, message: "e"),
            DiagnosticRecord(path: "a.swift", range: Self.pointRange, severity: .warning, message: "w"),
            DiagnosticRecord(path: "a.swift", range: Self.pointRange, severity: .information, message: "i"),
            DiagnosticRecord(path: "a.swift", range: Self.pointRange, severity: .hint, message: "h"),
        ]

        let counts = Counts.from(records: records)

        #expect(counts.errors == 1)
        #expect(counts.warnings == 1)
    }

    private static var pointRange: LSPRange {
        LSPRange(start: Position(line: 0, character: 0), end: Position(line: 0, character: 1))
    }
}

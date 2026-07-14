import Foundation

/// The `diagnose` op: resolves a scope to concrete files, syncs and pulls
/// live diagnostics for them (and their one-hop dependents), waits for the
/// results to settle, and ranks/caps them into a `DiagnosticsReport`.
///
/// Port of `swissarmyhammer-diagnostics`'s `diagnose.rs`
/// (`diagnose`/`diagnose_with_outcome`), generic over `Connection` exactly
/// like `LiveOpsCore` — `session: LspSession<Connection>?` is `nil` when no
/// live language server layer is available for this workspace, matching
/// that type's established convention, rather than a Rust-style
/// `session.is_running()` query on an always-present session object.
enum DiagnosticsOps<Connection: LanguageServerConnection> {
    /// Diagnoses `scope` against `store`/`session`, returning a report of
    /// every target's (and folded-in broken dependent's) diagnostics.
    ///
    /// - Parameters:
    ///   - store: The workspace's index store — used to resolve one-hop dependents via `blastRadius`.
    ///   - session: The live session to sync/pull/settle through, or `nil` if no live layer is available.
    ///   - rootDirectory: The workspace root `scope` is resolved against.
    ///   - scope: Which files to diagnose.
    ///   - severity: The severity floor: records less severe than this are excluded. Defaults to `.warning`
    ///     (excludes `.information`/`.hint`); lower to `.hint` to include everything.
    ///   - includeDependents: Whether broken one-hop dependents fold into the report. Defaults to `true`.
    ///   - settleWindow: How long a watched file must go quiet before its diagnostics are considered settled. Defaults to 300ms.
    ///   - hardTimeout: The maximum time to wait for settling before flagging the report pending. Defaults to 5 seconds.
    ///   - perReportCap: The maximum number of records in the returned report. Defaults to 100.
    ///   - clock: The clock the settle window and hard timeout are measured against. Defaults to `ContinuousClock()`.
    /// - Returns: The resulting report.
    /// - Throws: Rethrows `DiagnosticsScopeResolver.resolvePaths(scope:rootDirectory:)`'s `git` invocation failures.
    static func diagnostics(
        store: Store,
        session: LspSession<Connection>?,
        rootDirectory: URL,
        scope: DiagnosticsScope,
        severity: DiagnosticSeverity = .warning,
        includeDependents: Bool = true,
        settleWindow: Duration = .milliseconds(300),
        hardTimeout: Duration = .seconds(5),
        perReportCap: Int = 100,
        clock: any Clock<Duration> = ContinuousClock()
    ) async throws -> DiagnosticsReport {
        let targets = try await DiagnosticsScopeResolver.resolvePaths(scope: scope, rootDirectory: rootDirectory)
        let dependentFiles = includeDependents ? await resolveDependents(store: store, targets: targets) : []
        let allFiles = targets + dependentFiles

        var uriDiagnostics: [DocumentURI: [Diagnostic]] = [:]
        var settlePending = false
        var notReady = false

        if let session {
            for file in allFiles {
                await syncAndPull(file: file, rootDirectory: rootDirectory, session: session)
            }

            let watchedURIs = allFiles.map { documentURI(forRelativePath: $0, rootDirectory: rootDirectory) }
            let outcome = await Settle.settle(session: session, uris: watchedURIs, settleWindow: settleWindow, hardTimeout: hardTimeout, clock: clock)
            switch outcome {
            case let .settled(state):
                uriDiagnostics = state
            case .pending:
                settlePending = true
            }
            notReady = await !session.isReady
        }

        return buildReport(
            uriDiagnostics: uriDiagnostics,
            targets: targets,
            dependentFiles: dependentFiles,
            rootDirectory: rootDirectory,
            severity: severity,
            perReportCap: perReportCap,
            pending: settlePending || notReady
        )
    }

    // MARK: - Dependents fold-in

    /// The sorted, deduplicated union of every target's one-hop inbound
    /// dependents, excluding files already in `targets`.
    /// - Parameters:
    ///   - store: The workspace's index store to query.
    ///   - targets: The scope's already-resolved target files.
    /// - Returns: The dependent files, sorted, excluding anything already a target.
    static func resolveDependents(store: Store, targets: [String]) async -> [String] {
        let targetSet = Set(targets)
        var collected: Set<String> = []
        for target in targets {
            let dependents = await oneHopDependents(store: store, filePath: target)
            collected.formUnion(dependents.filter { !targetSet.contains($0) })
        }
        return collected.sorted()
    }

    /// The direct (one-hop) inbound callers of `filePath`'s symbols, via
    /// `BlastRadiusOps.blastRadius(store:file:symbol:maxHops:)`.
    ///
    /// Ports the Rust reference's `diagnose.rs::BlastRadiusDependents::one_hop`,
    /// which swallows *any* `get_blastradius` failure into an empty result
    /// (an unindexed or errored file yields no known dependents, not an
    /// error) — this port swallows every thrown error identically, not only
    /// `CodeContextError.notFound` (which in practice can't even occur here,
    /// since `symbol` is always `nil`).
    ///
    /// Unlike the Rust reference's `Dependents` trait (needed because
    /// `rusqlite::Connection` is `!Sync`, forcing an eager
    /// `PrecomputedDependents::resolve` pass), this Swift port's `Store` is
    /// safely usable directly across `await`, so there is no equivalent
    /// indirection to port — this is a plain `async` function, not a
    /// protocol with two implementations.
    /// - Parameters:
    ///   - store: The workspace's index store to query.
    ///   - filePath: The file to find inbound callers of.
    /// - Returns: The distinct dependent file paths (excluding `filePath` itself), sorted.
    static func oneHopDependents(store: Store, filePath: String) async -> [String] {
        do {
            let radius = try await BlastRadiusOps.blastRadius(store: store, file: filePath, maxHops: 1)
            let files = radius.hops.flatMap { hop in
                hop.symbols.filter { $0.filePath != filePath }.map(\.filePath)
            }
            return Set(files).sorted()
        } catch {
            return []
        }
    }

    // MARK: - Sync + pull

    /// Best-effort syncs `file`'s current disk content to `session`, then
    /// unconditionally pulls its diagnostics — both swallowing failures.
    ///
    /// Ports `diagnose_with_outcome`'s "for each path: best-effort
    /// `sync_open`, then *always* `pull_diagnostics`" step: pulling
    /// regardless of whether the sync succeeded (and regardless of whether
    /// the file could even be read) ensures the report reflects the
    /// server's current answer rather than depending solely on the
    /// watcher's own async pulls, matching the fix noted in the Rust
    /// reference's git history ("pull target files in diagnose").
    /// - Parameters:
    ///   - file: The file to sync and pull, relative to `rootDirectory`.
    ///   - rootDirectory: The workspace root `file` is relative to.
    ///   - session: The session to sync and pull through.
    private static func syncAndPull(file: String, rootDirectory: URL, session: LspSession<Connection>) async {
        let uri = documentURI(forRelativePath: file, rootDirectory: rootDirectory)
        if RelativePath.isSafeRelativePath(file), let text = readFileContents(relativePath: file, rootDirectory: rootDirectory) {
            try? await session.syncOpen(uri: uri, text: text)
        }
        _ = try? await session.pullDiagnostics(uri: uri)
    }

    /// Reads `relativePath`'s content from disk as UTF-8 text, or `nil` if it can't be read or decoded.
    private static func readFileContents(relativePath: String, rootDirectory: URL) -> String? {
        let fileURL = rootDirectory.appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: fileURL), let contents = String(data: data, encoding: .utf8) else {
            return nil
        }
        return contents
    }

    /// Builds `relativePath`'s `DocumentURI`, relative to `rootDirectory`.
    private static func documentURI(forRelativePath relativePath: String, rootDirectory: URL) -> DocumentURI {
        DocumentURI(rootDirectory.appendingPathComponent(relativePath).absoluteString)
    }

    // MARK: - Report building

    /// Groups, ranks, and caps `uriDiagnostics` into a `DiagnosticsReport`.
    ///
    /// Ports `diagnose.rs::build_report`: targets are always included first,
    /// in their original (already-deduplicated) scope order; dependents are
    /// included only when "broken" (`errors + warnings > 0`, counted
    /// *after* `severity` filtering — a dependent whose only problem is
    /// below the floor counts as clean), ranked by `(errors desc, warnings
    /// desc, path asc)`, then appended after targets; the combined list is
    /// truncated to `perReportCap`.
    /// - Parameters:
    ///   - uriDiagnostics: The settle engine's per-uri diagnostics (or empty, if settling never produced any).
    ///   - targets: The scope's resolved target files, in query order.
    ///   - dependentFiles: The resolved one-hop dependent files (already excluding targets).
    ///   - rootDirectory: The workspace root uris are relativized against.
    ///   - severity: The severity floor: records less severe than this are excluded.
    ///   - perReportCap: The maximum number of records in the returned report.
    ///   - pending: Whether the report may be incomplete.
    /// - Returns: The built report.
    static func buildReport(
        uriDiagnostics: [DocumentURI: [Diagnostic]],
        targets: [String],
        dependentFiles: [String],
        rootDirectory: URL,
        severity: DiagnosticSeverity,
        perReportCap: Int,
        pending: Bool
    ) -> DiagnosticsReport {
        var recordsByPath: [String: [DiagnosticRecord]] = [:]
        for (uri, diagnostics) in uriDiagnostics {
            let path = RelativePath.relativeFilePath(fromURI: uri, rootDirectory: rootDirectory)
            let filtered = diagnostics
                .filter { $0.severity.rawValue <= severity.rawValue }
                .map { DiagnosticRecord.from(diagnostic: $0, path: path) }
            guard !filtered.isEmpty else { continue }
            recordsByPath[path, default: []].append(contentsOf: filtered)
        }

        var out: [DiagnosticRecord] = []
        for target in targets {
            out.append(contentsOf: recordsByPath[target] ?? [])
        }
        out.append(contentsOf: rankBrokenDependents(dependentFiles, recordsByPath: recordsByPath).flatMap(\.records))

        if out.count > perReportCap {
            out = Array(out.prefix(perReportCap))
        }

        return DiagnosticsReport(records: out, pending: pending)
    }

    /// One dependent file's records plus the error/warning counts driving its rank.
    private struct RankedDependent {
        let path: String
        let records: [DiagnosticRecord]
        let errors: Int
        let warnings: Int
    }

    /// Filters `dependentFiles` to only those with `errors + warnings > 0`
    /// (post-severity-filter), sorted `(errors desc, warnings desc, path asc)`.
    private static func rankBrokenDependents(_ dependentFiles: [String], recordsByPath: [String: [DiagnosticRecord]]) -> [RankedDependent] {
        var ranked: [RankedDependent] = []
        for dependent in dependentFiles {
            let records = recordsByPath[dependent] ?? []
            let counts = Counts.from(records: records)
            guard counts.errors + counts.warnings > 0 else { continue }
            ranked.append(RankedDependent(path: dependent, records: records, errors: counts.errors, warnings: counts.warnings))
        }
        return ranked.sorted { lhs, rhs in
            if lhs.errors != rhs.errors { return lhs.errors > rhs.errors }
            if lhs.warnings != rhs.warnings { return lhs.warnings > rhs.warnings }
            return lhs.path < rhs.path
        }
    }
}

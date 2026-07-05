import Foundation

/// The public facade actor tying every subsystem in this package together for one workspace.
///
/// Ports plan.md's "Goal": one process, one workspace, one owner of the index and the LSP
/// servers. `init(rootDirectory:embedder:)` opens (creating if necessary) the workspace's
/// `Store` and builds the shared `nonisolated let state: CodeContextState` observable exactly
/// once; `start()` reconciles the on-disk index against the workspace, detects projects, starts
/// the LSP supervisor, runs an initial full drain so `state.isReady` reflects reality by the time
/// `start()` returns, and then spawns the continuous background workers (indexing loop, per-server
/// LSP index workers, filesystem watcher) as owned structured-concurrency tasks; `stop()` tears
/// every one of those down, in order, before returning.
///
/// Generic over `Connection` so tests can drive this facade entirely against
/// `FakeLanguageServerConnection` (see `Tests/CodeContextKitTests/Support/`) without ever spawning
/// a real language-server process — production code uses the `where Connection ==
/// ProcessLanguageServerConnection` convenience initializer below, which is the only initializer
/// visible outside this module (the general initializer takes an internal `ConnectionFactory`, so
/// it can't itself be `public`).
///
/// Every op below is a thin pass-through to the already-built, independently tested op engines
/// (`SymbolOps`, `CallGraphOps`, `BlastRadiusOps`, `GrepCode`, `SearchCode`, `FindDuplicatesOps`,
/// `QueryAST`, `IndexAdmin`, `LiveOpsCore`, `LiveOpsExtended`, `DiagnosticsOps`) — this type's own
/// job is wiring lifetime and cross-cutting state (project detection, the LSP supervisor, the
/// `SearchCorpus` cache, and the observable `state`), not reimplementing any of them.
public actor CodeContext<Connection: LanguageServerConnection> {
    /// Unified, SwiftUI-observable snapshot of this workspace: detected projects, LSP daemon
    /// health, indexing progress, and live diagnostics. Created once in `init` and never replaced.
    public nonisolated let state: CodeContextState

    /// The workspace root this facade was opened for.
    private let rootDirectory: URL

    /// The embedder used by the tree-sitter worker's embedding step and by `searchCode(...)`.
    private let embedder: TextEmbedding

    /// The workspace's index store, opened once in `init`.
    private let store: Store

    /// The workspace's lazily-loaded, generation-invalidated search corpus, backing
    /// `searchCode(...)` and `findDuplicates(...)`.
    private let corpus: SearchCorpus

    /// Manages the fleet of LSP daemons for this workspace's detected projects.
    private let supervisor: LspSupervisor<Connection>

    /// The clock the index loop's idle sleep and the watcher's debounce timer wait against.
    /// Defaults to `ContinuousClock()`; tests inject a fake or a fast interval.
    private let clock: any Clock<Duration>

    /// The raw filesystem-change event source the watcher subscribes to. Defaults to
    /// `FSEventsFileEventSource()`; tests inject `FakeFileEventSource` so no real FSEvents stream
    /// (and its detached-queue teardown) is ever involved.
    private let eventSource: any FileEventSource

    /// How long the background index loop idles between passes when nothing new triggered it.
    private static var indexLoopIdleSleep: Duration { .milliseconds(300) }

    /// Whether `start()` has completed and `stop()` has not yet been called; guards both methods
    /// against being run twice concurrently or out of order.
    private var isStarted = false

    /// The workspace's filesystem watcher, created and started in `start()`, `nil` before that and
    /// after `stop()`.
    private var watcher: Watcher?

    /// The background task that periodically drains the tree-sitter/embedding layers and
    /// publishes fresh `state.indexing`/`state.servers` snapshots. Cancelled and awaited in
    /// `stop()`.
    private var indexLoopTask: Task<Void, Never>?

    /// One continuous drain task per LSP server spec with a non-empty extension set, each running
    /// `LSPIndexWorker.run(...)` until cancelled. Cancelled and awaited in `stop()`.
    private var lspIndexTasks: [Task<Void, Never>] = []

    /// File extensions (lowercased, no leading dot) covered by a currently detected server spec —
    /// i.e. a language for which some daemon is (or could be) managing LSP indexing. Recomputed in
    /// `start()` from the detected projects, and consulted by `markUncoveredLspFilesDone()` so a
    /// file whose language has no registered server is treated as trivially LSP-indexed (there is
    /// nothing for any worker to ever do for it) rather than staying dirty forever and blocking
    /// `state.isReady`.
    private var coveredLspExtensions: Set<String> = []

    /// Creates the facade for `rootDirectory`: opens (creating if necessary) the index store and
    /// builds the shared observable `state`. No indexing, project detection, or LSP activity
    /// happens until `start()` is called.
    ///
    /// Not `public`: `connectionFactory` is typed against the internal `ConnectionFactory`
    /// typealias, so this initializer can never satisfy a public declaration's visibility
    /// requirements. Production callers use the `where Connection ==
    /// ProcessLanguageServerConnection` convenience initializer below; tests call this one
    /// directly (via `@testable import`) with a factory that hands back
    /// `FakeLanguageServerConnection`s.
    ///
    /// - Parameters:
    ///   - rootDirectory: The workspace root to open. Enters exactly once, here.
    ///   - embedder: The embedder used for the tree-sitter worker's embedding step and for
    ///     `searchCode(...)`.
    ///   - clock: The clock the index loop and watcher debounce timer sleep against. Defaults to
    ///     `ContinuousClock()`; tests inject a faster or manually-driven clock.
    ///   - eventSource: The raw filesystem-change event source the watcher subscribes to. Defaults
    ///     to `FSEventsFileEventSource()`; tests inject `FakeFileEventSource`.
    ///   - connectionFactory: Spawns a fresh connection for every LSP daemon the supervisor
    ///     creates. Production code passes `LSPDaemon.processConnectionFactory()`; tests pass one
    ///     backed by `FakeLanguageServerConnection`.
    /// - Throws: `CodeContextError.storage` if the index store can't be opened or migrated.
    init(
        rootDirectory: URL,
        embedder: TextEmbedding,
        clock: any Clock<Duration> = ContinuousClock(),
        eventSource: any FileEventSource = FSEventsFileEventSource(),
        connectionFactory: @escaping ConnectionFactory<Connection>
    ) async throws {
        self.rootDirectory = rootDirectory
        self.embedder = embedder
        self.clock = clock
        self.eventSource = eventSource

        let store = try Store(rootDirectory: rootDirectory)
        self.store = store
        corpus = SearchCorpus(store: store)
        state = await CodeContextState(rootDirectory: rootDirectory)
        supervisor = LspSupervisor(workspaceRoot: rootDirectory, clock: clock, connectionFactory: connectionFactory)
    }

    /// Ensures every spawned task, the watcher, and every managed LSP daemon are torn down even if
    /// a caller never calls `stop()`. Best-effort and synchronous only (actor `deinit` can't
    /// `await`): `stop()` is the real, awaited teardown path this exists only as a safety net for.
    deinit {
        indexLoopTask?.cancel()
        for task in lspIndexTasks {
            task.cancel()
        }
    }

    // MARK: - Lifecycle

    /// Reconciles the on-disk index, detects projects, starts the LSP supervisor, runs an initial
    /// full drain, and spawns the continuous background workers.
    ///
    /// By the time this method returns, `state.isReady` reflects the workspace's actual settled
    /// state (not merely the vacuously-ready zero state `CodeContextState` starts in): the initial
    /// drain below runs the tree-sitter/embedding pass to completion and marks every file whose
    /// language has no registered LSP server as trivially LSP-indexed, so a workspace with no
    /// LSP-backed languages present settles deterministically without waiting on any background
    /// task. A workspace whose detected projects *do* have registered servers still settles
    /// against however quickly (or slowly) those daemons start — `state.servers`/`state.indexing`
    /// continue to update from the background index loop below as that catches up.
    ///
    /// Safe to call only once; a second call while already started is a no-op. A call that
    /// throws leaves this facade exactly as if `start()` had never been called — `isStarted`
    /// is reset to `false` and any LSP daemons the supervisor may have already spawned are shut
    /// down — so a caller is free to fix the underlying problem and retry `start()` rather than
    /// being stuck with a permanently-`true` `isStarted` guarding a facade that never actually
    /// started anything.
    /// - Throws: Rethrows `Reconciler.reconcile`'s and `ProjectDetection.detectProjects`'s
    ///   filesystem errors, `LspSupervisor.start()`'s project-detection errors, or `Store`'s
    ///   storage errors from the initial drain.
    public func start() async throws {
        guard !isStarted else { return }
        isStarted = true

        do {
            _ = try await Reconciler.reconcile(store: store, rootDirectory: rootDirectory)

            let projects = try ProjectDetection.detectProjects(rootDirectory: rootDirectory)
            await state.publishProjects(projects)

            try await supervisor.start()
            await publishServersStatus()

            let specs = ProjectDetection.serverSpecs(for: projects)
            coveredLspExtensions = Self.coveredExtensions(for: specs)

            // Initial, synchronous settle so `state.isReady` is accurate the moment this
            // returns, rather than only eventually once the background loop below has had a
            // chance to run.
            try await runOneIndexPass()

            let watcher = Watcher(
                store: store,
                rootDirectory: rootDirectory,
                eventSource: eventSource,
                clock: clock,
                nudgeWorkers: { [weak self] in
                    try? await self?.runOneIndexPass()
                }
            )
            await watcher.start()
            self.watcher = watcher

            indexLoopTask = Task { [weak self] in
                await self?.runIndexLoop()
            }

            lspIndexTasks = specs.compactMap { spec in
                let extensions = Self.extensions(forCommand: spec.command)
                guard !extensions.isEmpty else { return nil }
                return Task { [weak self] in
                    guard let self else { return }
                    try? await LSPIndexWorker<Connection>.run(
                        store: self.store,
                        rootDirectory: self.rootDirectory,
                        extensions: extensions,
                        sessionProvider: { [weak self] in
                            await self?.supervisor.session(forFileExtension: extensions[0])
                        },
                        clock: self.clock
                    )
                }
            }
        } catch {
            // Nothing above spawns a task or starts the watcher until every throwing step has
            // already succeeded, so on failure the only thing that might need tearing down is
            // the LSP supervisor itself — shutting it down is a harmless no-op if it never
            // started any daemon (or was never even reached). Resetting `isStarted` here (rather
            // than leaving it `true`) is what makes a caller's retry actually re-attempt startup
            // instead of silently no-op'ing against the `guard !isStarted` above.
            await supervisor.shutdown()
            isStarted = false
            throw error
        }
    }

    /// Tears down everything `start()` spawned: cancels and awaits the index loop and every
    /// per-server LSP index task, stops the watcher, and shuts down every managed LSP daemon —
    /// each fully awaited before the next step starts, so no task, subprocess, or in-flight
    /// request from this workspace is still running once this method returns.
    ///
    /// Does not close `store` itself: this facade's indexed ops (`getSymbol(...)`,
    /// `searchSymbol(...)`, etc.) remain queryable against the on-disk index after `stop()`, so
    /// `store` stays a live, non-optional property for the actor's whole lifetime. Its underlying
    /// `DatabasePool` only closes once every reference to this `CodeContext` (including this
    /// actor's own) is released and it deinits — the same automatic-close-on-deallocation
    /// GRDB itself guarantees for any `DatabasePool`, not something `stop()` triggers early.
    ///
    /// Safe to call more than once; a call while not started is a no-op.
    public func stop() async {
        guard isStarted else { return }
        isStarted = false

        indexLoopTask?.cancel()
        await indexLoopTask?.value
        indexLoopTask = nil

        for task in lspIndexTasks {
            task.cancel()
        }
        for task in lspIndexTasks {
            await task.value
        }
        lspIndexTasks.removeAll()

        await watcher?.stop()
        watcher = nil

        await supervisor.shutdown()
    }

    // MARK: - Project detection

    /// Re-scans the workspace for projects and refreshes `state.projects`.
    ///
    /// Unlike `start()`'s one-time project detection, this does not restart the LSP supervisor or
    /// spawn new daemons for a newly detected server — it only updates `state.projects` so a
    /// caller (or a SwiftUI harness bound to `state`) sees the current project set. A later
    /// `start()`-style daemon spawn for a project detected only after `start()` already ran is out
    /// of this task's scope (this facade's project detection is a snapshot, refreshed on demand).
    /// - Returns: The freshly detected projects (also published into `state.projects`).
    /// - Throws: Rethrows `ProjectDetection.detectProjects(rootDirectory:)`'s filesystem errors.
    @discardableResult
    public func detectProjects() async throws -> [DetectedProject] {
        let projects = try ProjectDetection.detectProjects(rootDirectory: rootDirectory)
        await state.publishProjects(projects)
        return projects
    }

    // MARK: - Index status and rebuild

    /// A snapshot of per-layer indexing progress, read directly from `state.indexing`.
    /// - Returns: The most recently published `IndexProgress`.
    public func indexStatus() async -> IndexProgress {
        await state.indexing
    }

    /// A snapshot of every managed LSP daemon's current lifecycle state, read directly from
    /// `state.servers`.
    /// - Returns: The most recently published server statuses.
    public func lspStatus() async -> [ServerStatus] {
        await state.servers
    }

    /// Marks `layer` dirty across the whole workspace (via `IndexAdmin.rebuildIndex`), then
    /// immediately re-drains so `indexStatus()` reflects the rebuild rather than staying stale
    /// until the background index loop's next tick.
    /// - Parameter layer: Which layer(s) to reset and re-drain.
    /// - Returns: Which layer was reset and how many files were marked dirty.
    /// - Throws: Rethrows `Store`'s storage errors.
    @discardableResult
    public func rebuildIndex(layer: RebuildLayer) async throws -> RebuildIndexResult {
        let result = try await IndexAdmin.rebuildIndex(store: store, layer: layer)
        try await runOneIndexPass()
        return result
    }

    // MARK: - Indexed ops

    /// See `SymbolOps.getSymbol(store:query:maxResults:)`.
    public func getSymbol(query: String, maxResults: Int = 50) async throws -> GetSymbolResult {
        try await SymbolOps.getSymbol(store: store, query: query, maxResults: maxResults)
    }

    /// See `SymbolOps.searchSymbol(store:query:kind:maxResults:)`.
    public func searchSymbol(query: String, kind: SymbolMetaType? = nil, maxResults: Int = 50) async throws -> [SearchSymbolMatch] {
        try await SymbolOps.searchSymbol(store: store, query: query, kind: kind, maxResults: maxResults)
    }

    /// See `SymbolOps.listSymbols(store:file:)`.
    public func listSymbols(file: String) async throws -> [SymbolLocation] {
        try await SymbolOps.listSymbols(store: store, file: file)
    }

    /// See `CallGraphOps.callGraph(store:of:direction:maxDepth:)`.
    public func callGraph(of symbol: String, direction: CallGraphDirection = .outbound, maxDepth: Int = 2) async throws -> CallGraph {
        try await CallGraphOps.callGraph(store: store, of: symbol, direction: direction, maxDepth: maxDepth)
    }

    /// See `BlastRadiusOps.blastRadius(store:file:symbol:maxHops:)`.
    public func blastRadius(file: String, symbol: String? = nil, maxHops: Int = 3) async throws -> BlastRadius {
        try await BlastRadiusOps.blastRadius(store: store, file: file, symbol: symbol, maxHops: maxHops)
    }

    /// See `GrepCode.run(store:pattern:languages:filePattern:maxResults:)`.
    public func grepCode(
        pattern: String,
        languages: [String] = [],
        filePattern: String? = nil,
        maxResults: Int = 50
    ) async throws -> GrepCodeResult {
        try await GrepCode.run(store: store, pattern: pattern, languages: languages, filePattern: filePattern, maxResults: maxResults)
    }

    /// See `SearchCode.run(corpus:embedder:query:topK:weights:)`.
    public func searchCode(query: String, topK: Int = 20, weights: SearchWeights = .default) async throws -> SearchCodeResult {
        try await SearchCode.run(corpus: corpus, embedder: embedder, query: query, topK: topK, weights: weights)
    }

    /// See `FindDuplicatesOps.findDuplicates(corpus:file:minSimilarity:minChunkBytes:maxPerChunk:)`.
    public func findDuplicates(
        file: String? = nil,
        minSimilarity: Double = 0.85,
        minChunkBytes: Int = 100,
        maxPerChunk: Int = 5
    ) async throws -> FindDuplicatesResult {
        try await FindDuplicatesOps.findDuplicates(
            corpus: corpus, file: file, minSimilarity: minSimilarity, minChunkBytes: minChunkBytes, maxPerChunk: maxPerChunk
        )
    }

    /// See `QueryAST.run(rootDirectory:language:query:options:)`.
    public func queryAST(language: String, query: String, options: QueryASTOptions = QueryASTOptions()) async throws -> QueryASTResult {
        try QueryAST.run(rootDirectory: rootDirectory, language: language, query: query, options: options)
    }

    // MARK: - Live ops

    /// See `LiveOpsCore.definition(store:session:rootDirectory:filePath:line:character:includeSource:)`.
    public func definition(filePath: String, line: Int, character: Int, includeSource: Bool = false) async throws -> DefinitionResult {
        let session = await session(forFilePath: filePath)
        return try await LiveOpsCore<Connection>.definition(
            store: store, session: session, rootDirectory: rootDirectory,
            filePath: filePath, line: line, character: character, includeSource: includeSource
        )
    }

    /// See `LiveOpsCore.typeDefinition(store:session:rootDirectory:filePath:line:character:includeSource:)`.
    public func typeDefinition(filePath: String, line: Int, character: Int, includeSource: Bool = false) async throws -> DefinitionResult {
        let session = await session(forFilePath: filePath)
        return try await LiveOpsCore<Connection>.typeDefinition(
            store: store, session: session, rootDirectory: rootDirectory,
            filePath: filePath, line: line, character: character, includeSource: includeSource
        )
    }

    /// See `LiveOpsCore.hover(store:session:rootDirectory:filePath:line:character:)`.
    public func hover(filePath: String, line: Int, character: Int) async throws -> HoverResult {
        let session = await session(forFilePath: filePath)
        return try await LiveOpsCore<Connection>.hover(
            store: store, session: session, rootDirectory: rootDirectory, filePath: filePath, line: line, character: character
        )
    }

    /// See `LiveOpsCore.references(store:session:rootDirectory:filePath:line:character:includeDeclaration:maxResults:)`.
    public func references(
        filePath: String,
        line: Int,
        character: Int,
        includeDeclaration: Bool = false,
        maxResults: Int? = nil
    ) async throws -> ReferencesResult {
        let session = await session(forFilePath: filePath)
        return try await LiveOpsCore<Connection>.references(
            store: store, session: session, rootDirectory: rootDirectory, filePath: filePath, line: line, character: character,
            includeDeclaration: includeDeclaration, maxResults: maxResults
        )
    }

    /// See `LiveOpsCore.implementations(store:session:rootDirectory:filePath:line:character:includeSource:maxResults:)`.
    public func implementations(
        filePath: String,
        line: Int,
        character: Int,
        includeSource: Bool = false,
        maxResults: Int = 20 // mirrors LiveOpsCore's own private defaultMaxImplementations
    ) async throws -> ImplementationsResult {
        let session = await session(forFilePath: filePath)
        return try await LiveOpsCore<Connection>.implementations(
            store: store, session: session, rootDirectory: rootDirectory, filePath: filePath, line: line, character: character,
            includeSource: includeSource, maxResults: maxResults
        )
    }

    /// See `LiveOpsExtended.codeActions(session:rootDirectory:filePath:startLine:startCharacter:endLine:endCharacter:diagnostics:only:)`.
    public func codeActions(
        filePath: String,
        startLine: Int,
        startCharacter: Int,
        endLine: Int,
        endCharacter: Int,
        diagnostics: [Diagnostic] = [],
        only: [String]? = nil
    ) async throws -> CodeActionsResult {
        let session = await session(forFilePath: filePath)
        return try await LiveOpsExtended<Connection>.codeActions(
            session: session, rootDirectory: rootDirectory, filePath: filePath,
            startLine: startLine, startCharacter: startCharacter, endLine: endLine, endCharacter: endCharacter,
            diagnostics: diagnostics, only: only
        )
    }

    /// See `LiveOpsExtended.renameEdits(session:rootDirectory:filePath:line:character:newName:)`.
    public func renameEdits(filePath: String, line: Int, character: Int, newName: String) async throws -> RenameEditsResult {
        let session = await session(forFilePath: filePath)
        return try await LiveOpsExtended<Connection>.renameEdits(
            session: session, rootDirectory: rootDirectory, filePath: filePath, line: line, character: character, newName: newName
        )
    }

    /// See `LiveOpsExtended.inboundCalls(store:session:rootDirectory:filePath:line:character:)`.
    public func inboundCalls(filePath: String, line: Int, character: Int) async throws -> InboundCallsResult {
        let session = await session(forFilePath: filePath)
        return try await LiveOpsExtended<Connection>.inboundCalls(
            store: store, session: session, rootDirectory: rootDirectory, filePath: filePath, line: line, character: character
        )
    }

    /// See `LiveOpsExtended.workspaceSymbols(supervisor:rootDirectory:query:)`.
    public func workspaceSymbols(query: String) async throws -> WorkspaceSymbolsResult {
        try await LiveOpsExtended<Connection>.workspaceSymbols(supervisor: supervisor, rootDirectory: rootDirectory, query: query)
    }

    // MARK: - Diagnostics

    /// See `DiagnosticsOps.diagnostics(store:session:rootDirectory:scope:severity:includeDependents:settleWindow:hardTimeout:perReportCap:clock:)`.
    ///
    /// Routes through `supervisor.anySession()` for the live layer, matching
    /// `workspaceSymbols(query:)`'s document-less session routing: a diagnostics scope can span
    /// several files across several languages, so there is no single per-file session to resolve
    /// from up front.
    public func diagnostics(
        scope: DiagnosticsScope,
        severity: DiagnosticSeverity = .warning,
        includeDependents: Bool = true,
        settleWindow: Duration = .milliseconds(300),
        hardTimeout: Duration = .seconds(5),
        perReportCap: Int = 100
    ) async throws -> DiagnosticsReport {
        let session = await supervisor.anySession()
        return try await DiagnosticsOps<Connection>.diagnostics(
            store: store, session: session, rootDirectory: rootDirectory, scope: scope,
            severity: severity, includeDependents: includeDependents,
            settleWindow: settleWindow, hardTimeout: hardTimeout, perReportCap: perReportCap, clock: clock
        )
    }

    // MARK: - Background index loop

    /// Runs until cancelled: sleeps `indexLoopIdleSleep`, then runs one more index pass and
    /// republishes `state.servers`. Sleeping first (rather than draining immediately on spawn)
    /// avoids redundantly repeating the pass `start()` already ran just before spawning this task.
    private func runIndexLoop() async {
        while !Task.isCancelled {
            do {
                try await clock.sleep(for: Self.indexLoopIdleSleep)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            try? await runOneIndexPass()
            await publishServersStatus()
        }
    }

    /// Drains the tree-sitter/embedding layers for every currently dirty file, marks every file
    /// whose language has no registered LSP server as trivially LSP-indexed, and republishes
    /// `state.indexing`. Shared by `start()`'s initial settle, the background index loop, the
    /// watcher's `nudgeWorkers` callback, and `rebuildIndex(layer:)` — every place that needs "redo
    /// a pass and make `state`/`indexStatus()` reflect it" goes through this one method.
    /// - Throws: Rethrows `Store`'s storage errors.
    private func runOneIndexPass() async throws {
        try await TreeSitterWorker.run(store: store, rootDirectory: rootDirectory, embedder: embedder)
        try await markUncoveredLspFilesDone()
        await publishIndexingStatus()
    }

    /// Marks every dirty file whose extension isn't covered by any currently detected LSP server
    /// spec as LSP-indexed, without ever touching a file a spawned `LSPIndexWorker` is actually
    /// responsible for. See `coveredLspExtensions`'s doc comment for why this is necessary for
    /// `state.isReady` to ever become true in a workspace with no LSP-backed languages present.
    /// - Throws: Rethrows `Store`'s storage errors.
    private func markUncoveredLspFilesDone() async throws {
        let dirtyPaths = try await store.drainLspDirty()
        for relativePath in dirtyPaths {
            let fileExtension = URL(fileURLWithPath: relativePath).pathExtension.lowercased()
            guard !coveredLspExtensions.contains(fileExtension) else { continue }
            try await store.markIndexed(filePath: relativePath, layer: .lsp)
        }
    }

    /// Reads `IndexAdmin.indexStatus(store:)` and republishes it into `state.indexing` as an
    /// `IndexProgress`, swallowing any storage failure (logged, not propagated) since this is a
    /// best-effort background refresh, not a caller-facing operation.
    private func publishIndexingStatus() async {
        guard let status = try? await IndexAdmin.indexStatus(store: store) else { return }
        let progress = IndexProgress(
            filesWalked: status.totalFiles,
            filesParsed: status.treeSitterIndexedFiles,
            filesEmbedded: status.embeddedIndexedFiles,
            filesLspIndexed: status.lspIndexedFiles
        )
        await state.publishIndexing(progress)
    }

    /// Reads `supervisor.status()` and republishes it into `state.servers`.
    private func publishServersStatus() async {
        await state.publishServers(await supervisor.status())
    }

    // MARK: - Session routing

    /// Resolves the live session for `filePath`'s extension, or `nil` if no managed daemon
    /// currently serves that language.
    /// - Parameter filePath: The file to route, relative to `rootDirectory`.
    /// - Returns: The routed session, or `nil` if unavailable.
    private func session(forFilePath filePath: String) async -> LspSession<Connection>? {
        await supervisor.session(forFileExtension: URL(fileURLWithPath: filePath).pathExtension)
    }

    // MARK: - Server-spec extension mapping

    /// The file extensions (lowercased, no leading dot) covered by every `Languages.all` module
    /// whose `languageServer.command` is managed by one of `specs`.
    /// - Parameter specs: The detected, deduped server specs (see
    ///   `ProjectDetection.serverSpecs(for:)`).
    /// - Returns: The union of every covered module's `fileExtensions`.
    private static func coveredExtensions(for specs: [ServerSpec]) -> Set<String> {
        let commands = Set(specs.map(\.command))
        return Set(
            Languages.all
                .filter { module in module.languageServer.map { commands.contains($0.command) } ?? false }
                .flatMap { module in module.fileExtensions.map { $0.lowercased() } }
        )
    }

    /// The file extensions (lowercased, no leading dot) of every `Languages.all` module whose
    /// `languageServer.command` equals `command` — the extension set one spawned
    /// `LSPIndexWorker` task drains for the daemon managing `command`.
    /// - Parameter command: The server spec's command to match modules against.
    /// - Returns: The matching modules' extensions, in no particular order.
    private static func extensions(forCommand command: String) -> [String] {
        Languages.all
            .filter { module in module.languageServer?.command == command }
            .flatMap { module in module.fileExtensions.map { $0.lowercased() } }
    }
}

extension CodeContext where Connection == ProcessLanguageServerConnection {
    /// Creates the facade for `rootDirectory`, wired to spawn real subprocess-backed LSP daemons.
    ///
    /// This is the only initializer visible outside this module — see plan.md's Goal:
    /// ```swift
    /// let context = try await CodeContext(rootDirectory: ..., embedder: someEmbedder)
    /// try await context.start()
    /// ```
    /// - Parameters:
    ///   - rootDirectory: The workspace root to open. Enters exactly once, here.
    ///   - embedder: The embedder used for the tree-sitter worker's embedding step and for
    ///     `searchCode(...)`.
    /// - Throws: `CodeContextError.storage` if the index store can't be opened or migrated.
    public init(rootDirectory: URL, embedder: TextEmbedding) async throws {
        try await self.init(
            rootDirectory: rootDirectory,
            embedder: embedder,
            connectionFactory: LSPDaemon<ProcessLanguageServerConnection>.processConnectionFactory()
        )
    }
}

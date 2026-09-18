import Foundation

/// The public facade actor tying every subsystem in this package together for one workspace.
///
/// Ports plan.md's "Goal": one process, one workspace, one owner of the index and the LSP
/// servers. `init(rootDirectory:embedder:)` opens (creating if necessary) the workspace's
/// `Store` and builds the shared `nonisolated let state: CodeContextState` observable exactly
/// once; `start()` reconciles the on-disk index against the workspace, detects projects, starts
/// the LSP supervisor, and then spawns the continuous background workers (indexing loop, per-server
/// LSP index workers, filesystem watcher) as owned structured-concurrency tasks; `stop()` tears
/// every one of those down, in order, before returning.
///
/// `start()` does not wait for the index. The indexing loop runs the first index pass, which can
/// be long for a large workspace, and `waitForFirstIndexPass()` waits for that pass.
///
/// Generic over `Connection` so tests can drive this facade entirely against
/// `FakeLanguageServerConnection` (see `Tests/FoundationModelsCodeContextTests/Support/`) without ever spawning
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
    ///
    /// Public so sibling packages can learn which root a resolved context is rooted at, and rebase
    /// context-relative paths (such as every `DiagnosticRecord.path`) onto a root of their own.
    /// `nonisolated` is safe because this is an immutable `let`: cross-actor reads are
    /// data-race-free, so consumers can read it without `await`.
    public nonisolated let rootDirectory: URL

    /// The embedder used by the tree-sitter worker's embedding step and by `searchCode(...)`.
    ///
    /// `nil` means that the host turned the embedding layer off: no pass makes embeddings, and
    /// `searchCode(...)` and `findDuplicates(...)` throw `CodeContextError.embeddingDisabled`.
    private let embedder: TextEmbedding?

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

    /// Default `maxResults` for the bounded index-scan queries (`getSymbol(...)`,
    /// `searchSymbol(...)`, `grepCode(...)`) that don't need a caller-tunable cap most of the time.
    ///
    /// It returns `CodeContextDefaults.maxQueryResults`, the one source of this value.
    ///
    /// A computed property, like `indexLoopIdleSleep` above: `CodeContext` is generic over
    /// `Connection`, and generic types can't have stored static properties. `@usableFromInline`,
    /// not `public`: `CodeContextManager`'s `public` fan-out methods refer to it from their default
    /// argument values, which requires at least this visibility, but it isn't meant as API surface
    /// in its own right.
    @usableFromInline
    static var defaultMaxQueryResults: Int { CodeContextDefaults.maxQueryResults }

    /// Default `includeSource` for the live ops (`definition(...)`, `typeDefinition(...)`,
    /// `implementations(...)`) that can optionally embed the resolved location's source text.
    ///
    /// It returns `CodeContextDefaults.includeSource`, the one source of this value. See
    /// `defaultMaxQueryResults`'s doc comment for why this is a computed, `@usableFromInline`
    /// property rather than a stored `private` constant.
    @usableFromInline
    static var defaultIncludeSource: Bool { CodeContextDefaults.includeSource }

    /// Whether `start()` has completed and `stop()` has not yet been called; guards both methods
    /// against being run twice concurrently or out of order.
    private var isStarted = false

    /// The progress of the first index pass that the index loop runs after `start()`.
    private enum FirstIndexPass {
        /// No first pass runs: `start()` did not make one, or the pass is complete.
        case notRunning

        /// The first pass runs. The payload holds each `waitForFirstIndexPass()` call that
        /// waits for the pass.
        case running(waiters: [CheckedContinuation<Void, Never>])
    }

    /// The progress of the first index pass. `start()` sets `.running`, and the index loop sets
    /// `.notRunning` when the pass is complete, fails, or is cancelled.
    private var firstIndexPass = FirstIndexPass.notRunning

    /// The workspace's filesystem watcher, created and started in `start()`, `nil` before that and
    /// after `stop()`.
    private var watcher: Watcher?

    /// The background task that periodically requests an index pass (the pass task drains the
    /// tree-sitter/embedding layers) and publishes fresh `state.indexing`/`state.servers`
    /// snapshots. Cancelled and awaited in `stop()`.
    private var indexLoopTask: Task<Void, Never>?

    /// One caller that waits for an index pass.
    private struct IndexPassWaiter {
        /// The number of the pass request of the caller. The wait ends when a pass that started
        /// after this request is complete.
        let request: Int

        /// The continuation of the caller. It gets the result of the pass.
        let continuation: CheckedContinuation<Void, any Error>
    }

    /// The task that runs the index passes, one at a time. It is `nil` while no pass runs and no
    /// request waits. `stop()` cancels it and awaits it.
    private var indexPassTask: Task<Void, Never>?

    /// The number of pass requests up to now. Each `requestIndexPass()` call adds one.
    private var requestedIndexPassCount = 0

    /// The highest request number that a pass included. A pass includes each request that came
    /// before the pass started.
    private var servedIndexPassCount = 0

    /// The callers that wait for a pass, by wait identifier.
    private var indexPassWaiters: [Int: IndexPassWaiter] = [:]

    /// The wait identifier of the subsequent `requestIndexPassAndWait()` call.
    private var nextIndexPassWaiterID = 0

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
    ///     `searchCode(...)`, or `nil` to turn the embedding layer off.
    ///   - clock: The clock the index loop and watcher debounce timer sleep against. Defaults to
    ///     `ContinuousClock()`; tests inject a faster or manually-driven clock.
    ///   - eventSource: The raw filesystem-change event source the watcher subscribes to. Defaults
    ///     to `FSEventsFileEventSource()`; tests inject `FakeFileEventSource`.
    ///   - autoInstall: The opt-out policy gating whether the supervisor may auto-install a
    ///     `.notFound` server's binary via its `ServerSpec.installer`. Defaults to
    ///     `LspAutoInstall()` (enabled, 300-second timeout); existing callers compile unchanged.
    ///   - installRunner: The process-running seam the supervisor's `ServerInstaller` drives.
    ///     Defaults to `ProcessInstallRunner()`; tests inject a scripted `FakeInstallRunner` so an
    ///     auto-install integration test never spawns (or has any real side effect from) a real
    ///     installer command.
    ///   - connectionFactory: Spawns a fresh connection for every LSP daemon the supervisor
    ///     creates. Production code passes `LSPDaemon.processConnectionFactory()`; tests pass one
    ///     backed by `FakeLanguageServerConnection`.
    /// - Throws: `CodeContextError.storage` if the index store can't be opened or migrated.
    init(
        rootDirectory: URL,
        embedder: TextEmbedding?,
        clock: any Clock<Duration> = ContinuousClock(),
        eventSource: any FileEventSource = FSEventsFileEventSource(),
        autoInstall: LspAutoInstall = LspAutoInstall(),
        installRunner: any InstallRunner = ProcessInstallRunner(),
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
        supervisor = LspSupervisor(
            workspaceRoot: rootDirectory,
            clock: clock,
            autoInstall: autoInstall,
            installRunner: installRunner,
            connectionFactory: connectionFactory
        )
    }

    /// Ensures every spawned task, the watcher, and every managed LSP daemon are torn down even if
    /// a caller never calls `stop()`. Best-effort and synchronous only (actor `deinit` can't
    /// `await`): `stop()` is the real, awaited teardown path this exists only as a safety net for.
    deinit {
        indexLoopTask?.cancel()
        indexPassTask?.cancel()
        for task in lspIndexTasks {
            task.cancel()
        }
    }

    // MARK: - Lifecycle

    /// Reconciles the on-disk index, detects projects, starts the LSP supervisor, and spawns the
    /// continuous background workers.
    ///
    /// This method does not run an index pass, thus its time does not depend on the parse and
    /// the embedding of the workspace. The index loop task runs the first pass immediately after
    /// this method makes the task. While that pass runs, each operation answers from the part of
    /// the index that is complete, and `waitForFirstIndexPass()` waits for the pass.
    ///
    /// Before this method returns, it publishes the index status that the reconcile gives. Thus
    /// `state.isReady` is `false` while files wait for a layer, not the vacuously-ready zero state
    /// `CodeContextState` starts in. `state.servers`/`state.indexing` continue to update from the
    /// background index loop as that catches up.
    ///
    /// Safe to call only once; a second call while already started is a no-op. A call that
    /// throws leaves this facade exactly as if `start()` had never been called — `isStarted`
    /// is reset to `false` and any LSP daemons the supervisor may have already spawned are shut
    /// down — so a caller is free to fix the underlying problem and retry `start()` rather than
    /// being stuck with a permanently-`true` `isStarted` guarding a facade that never actually
    /// started anything.
    /// - Throws: Rethrows `Reconciler.reconcile`'s and `ProjectDetection.detectProjects`'s
    ///   filesystem errors, and `LspSupervisor.start()`'s project-detection errors.
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

            // The reconcile found the files that wait for a layer. Publish that status now, so
            // that `state.isReady` is `false` until the first pass of the index loop is complete.
            await publishIndexingStatus()

            let watcher = Watcher(
                store: store,
                rootDirectory: rootDirectory,
                eventSource: eventSource,
                clock: clock,
                nudgeWorkers: { [weak self] in
                    await self?.nudgeIndexPass()
                }
            )
            await watcher.start()
            self.watcher = watcher

            firstIndexPass = .running(waiters: [])
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
    /// A call during an index pass cancels that pass. The pass looks for cancellation
    /// before each file and before each embedding batch, thus this method waits for one
    /// embedding batch at most. Each `waitForFirstIndexPass()` call that waits then returns, and
    /// each `rebuildIndex(layer:)` call that waits throws `CancellationError`.
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
        await cancelIndexPasses()
        await indexLoopTask?.value
        indexLoopTask = nil
        finishFirstIndexPass()

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

    /// Waits until the first index pass after `start()` is complete.
    ///
    /// `start()` returns before the index is complete. A caller that needs the complete
    /// tree-sitter and embedding layers, for example a batch program or a test, calls this
    /// method after `start()`. A caller that can use a partial index does not call it.
    ///
    /// The method returns immediately when no first pass runs: before `start()`, after the pass
    /// is complete, and after `stop()`. It also returns when the pass fails or when `stop()`
    /// cancels the pass. Thus read `indexStatus()` to see how much of the index is complete.
    /// LSP indexing is not part of this pass, because it continues in its own tasks.
    public func waitForFirstIndexPass() async {
        guard case .running = firstIndexPass else { return }
        await withCheckedContinuation { continuation in
            addFirstIndexPassWaiter(continuation)
        }
    }

    /// Records one `waitForFirstIndexPass()` call that waits, or resumes it immediately when
    /// the first pass does not run.
    /// - Parameter continuation: The continuation of the call that waits.
    private func addFirstIndexPassWaiter(_ continuation: CheckedContinuation<Void, Never>) {
        guard case .running(let waiters) = firstIndexPass else {
            continuation.resume()
            return
        }
        firstIndexPass = .running(waiters: waiters + [continuation])
    }

    /// Marks the first index pass as not running and resumes each call that waits for it.
    /// A call while the first pass does not run is a no-op.
    private func finishFirstIndexPass() {
        guard case .running(let waiters) = firstIndexPass else { return }
        firstIndexPass = .notRunning
        for waiter in waiters {
            waiter.resume()
        }
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

    /// A snapshot of per-layer indexing progress.
    ///
    /// The method reads the counts from the store and publishes them into `state.indexing`
    /// before it returns. Thus the snapshot shows the progress of a pass that runs, not only the
    /// result of the last complete pass. `IndexProgress.isEmbeddingEnabled` shows whether the
    /// host turned the embedding layer off.
    /// - Returns: The current `IndexProgress`.
    public func indexStatus() async -> IndexProgress {
        await publishIndexingStatus()
        return await state.indexing
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
    ///
    /// Only one index pass runs at a time. When a pass runs during this call, the method does not
    /// start a second pass. It waits for a pass that started after the rebuild, because only
    /// such a pass is sure to drain each file that the rebuild marked.
    /// - Parameter layer: Which layer(s) to reset and re-drain.
    /// - Returns: Which layer was reset and how many files were marked dirty.
    /// - Throws: Rethrows `Store`'s storage errors, and `CancellationError` when `stop()` cancels
    ///   the pass or when the task of the caller is cancelled.
    @discardableResult
    public func rebuildIndex(layer: RebuildLayer) async throws -> RebuildIndexResult {
        let result = try await IndexAdmin.rebuildIndex(store: store, layer: layer)
        try await requestIndexPassAndWait()
        return result
    }

    // MARK: - Indexed ops

    /// See `SymbolOps.getSymbol(store:query:maxResults:)`.
    public func getSymbol(query: String, maxResults: Int = CodeContextDefaults.maxQueryResults) async throws -> GetSymbolResult {
        try await SymbolOps.getSymbol(store: store, query: query, maxResults: maxResults)
    }

    /// See `SymbolOps.searchSymbol(store:query:kind:maxResults:)`.
    public func searchSymbol(query: String, kind: SymbolMetaType? = nil, maxResults: Int = CodeContextDefaults.maxQueryResults) async throws -> [SearchSymbolMatch] {
        try await SymbolOps.searchSymbol(store: store, query: query, kind: kind, maxResults: maxResults)
    }

    /// See `SymbolOps.listSymbols(store:file:)`.
    public func listSymbols(file: String) async throws -> [SymbolLocation] {
        try await SymbolOps.listSymbols(store: store, file: file)
    }

    /// See `CallGraphOps.callGraph(store:of:direction:maxDepth:)`.
    public func callGraph(
        of symbol: String,
        direction: CallGraphDirection = CodeContextDefaults.callGraphDirection,
        maxDepth: Int = CodeContextDefaults.callGraphMaxDepth
    ) async throws -> CallGraph {
        try await CallGraphOps.callGraph(store: store, of: symbol, direction: direction, maxDepth: maxDepth)
    }

    /// See `BlastRadiusOps.blastRadius(store:file:symbol:maxHops:)`.
    public func blastRadius(file: String, symbol: String? = nil, maxHops: Int = CodeContextDefaults.blastRadiusMaxHops) async throws -> BlastRadius {
        try await BlastRadiusOps.blastRadius(store: store, file: file, symbol: symbol, maxHops: maxHops)
    }

    /// See `GrepCode.run(store:pattern:languages:filePattern:maxResults:)`.
    public func grepCode(
        pattern: String,
        languages: [String] = CodeContextDefaults.grepLanguages,
        filePattern: String? = nil,
        maxResults: Int = CodeContextDefaults.maxQueryResults
    ) async throws -> GrepCodeResult {
        try await GrepCode.run(store: store, pattern: pattern, languages: languages, filePattern: filePattern, maxResults: maxResults)
    }

    /// See `SearchCode.run(corpus:embedder:query:topK:weights:)`.
    /// - Throws: `CodeContextError.embeddingDisabled` when this context has no embedder, and
    ///   the errors of `SearchCode.run(corpus:embedder:query:topK:weights:)`.
    public func searchCode(
        query: String,
        topK: Int = CodeContextDefaults.searchTopK,
        weights: SearchWeights = CodeContextDefaults.searchWeights
    ) async throws -> SearchCodeResult {
        let embedder = try requireEmbedder()
        return try await SearchCode.run(corpus: corpus, embedder: embedder, query: query, topK: topK, weights: weights)
    }

    /// See `FindDuplicatesOps.findDuplicates(corpus:file:minSimilarity:minChunkBytes:maxPerChunk:)`.
    /// - Throws: `CodeContextError.embeddingDisabled` when this context has no embedder, because
    ///   the comparison uses the chunk embeddings, and the errors of
    ///   `FindDuplicatesOps.findDuplicates(corpus:file:minSimilarity:minChunkBytes:maxPerChunk:)`.
    public func findDuplicates(
        file: String? = nil,
        minSimilarity: Double = CodeContextDefaults.duplicateMinSimilarity,
        minChunkBytes: Int = CodeContextDefaults.duplicateMinChunkBytes,
        maxPerChunk: Int = CodeContextDefaults.duplicateMaxPerChunk
    ) async throws -> FindDuplicatesResult {
        _ = try requireEmbedder()
        return try await FindDuplicatesOps.findDuplicates(
            corpus: corpus, file: file, minSimilarity: minSimilarity, minChunkBytes: minChunkBytes, maxPerChunk: maxPerChunk
        )
    }

    /// Gives the embedder, for an operation that cannot give a useful result without the
    /// embedding layer.
    /// - Returns: The embedder of this context.
    /// - Throws: `CodeContextError.embeddingDisabled` when the host turned the embedding layer
    ///   off.
    private func requireEmbedder() throws -> TextEmbedding {
        guard let embedder else {
            throw CodeContextError.embeddingDisabled
        }
        return embedder
    }

    /// See `QueryAST.run(rootDirectory:language:query:options:)`.
    public func queryAST(language: String, query: String, options: QueryASTOptions = QueryASTOptions()) async throws -> QueryASTResult {
        try QueryAST.run(rootDirectory: rootDirectory, language: language, query: query, options: options)
    }

    // MARK: - Live ops

    /// See `LiveOpsCore.definition(store:session:rootDirectory:filePath:line:character:includeSource:)`.
    public func definition(filePath: String, line: Int, character: Int, includeSource: Bool = CodeContextDefaults.includeSource) async throws -> DefinitionResult {
        let session = await session(forFilePath: filePath)
        return try await LiveOpsCore<Connection>.definition(
            store: store, session: session, rootDirectory: rootDirectory,
            filePath: filePath, line: line, character: character, includeSource: includeSource
        )
    }

    /// See `LiveOpsCore.typeDefinition(store:session:rootDirectory:filePath:line:character:includeSource:)`.
    public func typeDefinition(filePath: String, line: Int, character: Int, includeSource: Bool = CodeContextDefaults.includeSource) async throws -> DefinitionResult {
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
        includeDeclaration: Bool = CodeContextDefaults.referencesIncludeDeclaration,
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
        includeSource: Bool = CodeContextDefaults.includeSource,
        maxResults: Int = CodeContextDefaults.implementationsMaxResults
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
        severity: DiagnosticSeverity = CodeContextDefaults.diagnosticsSeverity,
        includeDependents: Bool = CodeContextDefaults.diagnosticsIncludeDependents,
        settleWindow: Duration = CodeContextDefaults.diagnosticsSettleWindow,
        hardTimeout: Duration = CodeContextDefaults.diagnosticsHardTimeout,
        perReportCap: Int = CodeContextDefaults.diagnosticsPerReportCap
    ) async throws -> DiagnosticsReport {
        let session = await supervisor.anySession()
        return try await DiagnosticsOps<Connection>.diagnostics(
            store: store, session: session, rootDirectory: rootDirectory, scope: scope,
            severity: severity, includeDependents: includeDependents,
            settleWindow: settleWindow, hardTimeout: hardTimeout, perReportCap: perReportCap, clock: clock
        )
    }

    // MARK: - Background index loop

    /// Runs the first index pass, then runs until cancelled: sleeps `indexLoopIdleSleep`, then
    /// runs one more index pass and republishes `state.servers`.
    ///
    /// The first pass runs here and not in `start()`, because the parse and the embedding of a
    /// large workspace can be long, and `start()` must not wait for them.
    private func runIndexLoop() async {
        await runFirstIndexPass()
        while !Task.isCancelled {
            do {
                try await clock.sleep(for: Self.indexLoopIdleSleep)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            try? await requestIndexPassAndWait()
            await publishServersStatus()
        }
    }

    /// Runs the first index pass after `start()`, then resumes each `waitForFirstIndexPass()`
    /// call that waits.
    ///
    /// A pass that `stop()` cancels is not a failure, and it writes no log entry. Each other
    /// failure writes a log entry, and the subsequent passes of the loop try again.
    private func runFirstIndexPass() async {
        do {
            try await requestIndexPassAndWait()
        } catch is CancellationError {
            // `stop()` cancelled the pass. `stop()` reports nothing, thus no log entry.
        } catch {
            Log.index.error("the first index pass failed: \(String(describing: error), privacy: .public)")
        }
        await publishServersStatus()
        finishFirstIndexPass()
    }

    // MARK: - One index pass at a time

    /// Requests an index pass for the watcher, and does not wait for the pass.
    ///
    /// The watcher calls this method in its debounce task, and a new file event cancels that
    /// task. Thus the pass must not run in the task of the watcher. A call while this context is
    /// not started is a no-op, because `stop()` must not leave a pass that runs.
    private func nudgeIndexPass() {
        guard isStarted else { return }
        requestIndexPass()
    }

    /// Requests an index pass, and starts the pass task when no pass task runs.
    ///
    /// A request during a pass does not start a second pass. The pass task runs one more pass
    /// after the current pass is complete, and that one pass serves all the requests that came
    /// during the current pass.
    /// - Returns: The number of this request, for `addIndexPassWaiter(_:id:)`.
    @discardableResult
    private func requestIndexPass() -> Int {
        requestedIndexPassCount += 1
        if indexPassTask == nil {
            indexPassTask = Task { [weak self] in
                await self?.runRequestedIndexPasses()
            }
        }
        return requestedIndexPassCount
    }

    /// Requests an index pass, then waits until a pass that started after the request is
    /// complete. The index loop (the first pass included) and `rebuildIndex(layer:)` call this
    /// method.
    ///
    /// The pass runs in the pass task, not in the task of the caller. Thus the cancellation of
    /// the caller stops only this wait, and the pass continues for the other callers.
    /// - Throws: The error of the pass, and `CancellationError` when `stop()` cancels the pass or
    ///   when the task of the caller is cancelled.
    private func requestIndexPassAndWait() async throws {
        let request = requestIndexPass()
        let waiterID = nextIndexPassWaiterID
        nextIndexPassWaiterID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                addIndexPassWaiter(IndexPassWaiter(request: request, continuation: continuation), id: waiterID)
            }
        } onCancel: {
            // The cancellation handler is synchronous, thus it needs a task to get into the actor.
            Task { await self.cancelIndexPassWaiter(id: waiterID) }
        }
    }

    /// Records one caller that waits for a pass.
    ///
    /// The caller does not wait when its task is already cancelled, because the cancellation
    /// handler ran before this record and found no waiter. The caller also does not wait when no
    /// pass task runs, because no pass can then end the wait.
    /// - Parameters:
    ///   - waiter: The caller that waits.
    ///   - id: The wait identifier of the caller.
    private func addIndexPassWaiter(_ waiter: IndexPassWaiter, id: Int) {
        guard !Task.isCancelled, indexPassTask != nil else {
            waiter.continuation.resume(throwing: CancellationError())
            return
        }
        indexPassWaiters[id] = waiter
    }

    /// Ends the wait of one caller whose task is cancelled. A call for a caller that does not
    /// wait is a no-op.
    /// - Parameter id: The wait identifier of the caller.
    private func cancelIndexPassWaiter(id: Int) {
        indexPassWaiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }

    /// Gives `result` to each caller whose request is not after `request`.
    /// - Parameters:
    ///   - request: The highest request number that the result is applicable to.
    ///   - result: The result of the pass.
    private func resumeIndexPassWaiters(upTo request: Int, with result: Result<Void, any Error>) {
        for (id, waiter) in indexPassWaiters where waiter.request <= request {
            indexPassWaiters[id] = nil
            waiter.continuation.resume(with: result)
        }
    }

    /// The body of the pass task: runs one pass at a time while a request is not served and the
    /// task is not cancelled.
    ///
    /// A failed pass also serves its requests, and its callers get the error. Thus a fault that
    /// stays does not make a loop without end, and the index loop tries again after its sleep.
    /// When `stop()` cancels the task, each caller that continues to wait gets
    /// `CancellationError`.
    private func runRequestedIndexPasses() async {
        while servedIndexPassCount < requestedIndexPassCount, !Task.isCancelled {
            let request = requestedIndexPassCount
            let result = await indexPassResult()
            servedIndexPassCount = request
            resumeIndexPassWaiters(upTo: request, with: result)
        }
        indexPassTask = nil
        resumeIndexPassWaiters(upTo: requestedIndexPassCount, with: .failure(CancellationError()))
    }

    /// Cancels the pass task and waits until it is complete, for `stop()`.
    ///
    /// A `rebuildIndex(layer:)` call during the wait can start a new pass task. The loop cancels
    /// that task also, thus no pass runs when this method returns.
    private func cancelIndexPasses() async {
        while let task = indexPassTask {
            task.cancel()
            await task.value
        }
    }

    /// Runs one index pass and gives its result as a value.
    /// - Returns: `.success` for a complete pass, or `.failure` with the error of the pass.
    private func indexPassResult() async -> Result<Void, any Error> {
        do {
            try await runOneIndexPass()
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /// Drains the tree-sitter/embedding layers for every currently dirty file, marks every file
    /// whose language has no registered LSP server as trivially LSP-indexed, and republishes
    /// `state.indexing`.
    ///
    /// Only the pass task calls this method, thus two passes cannot run at the same time. Each
    /// other place that needs a pass calls `requestIndexPass()` or `requestIndexPassAndWait()`.
    /// - Throws: Rethrows `Store`'s storage errors, and `CancellationError` when the task is
    ///   cancelled during the pass.
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
            filesLspIndexed: status.lspIndexedFiles,
            isEmbeddingEnabled: embedder != nil
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
    ///     `searchCode(...)`. Give `nil` to turn the embedding layer off: the symbol, call graph
    ///     and language-server operations stay available, no pass makes embeddings, and
    ///     `searchCode(...)` and `findDuplicates(...)` throw `CodeContextError.embeddingDisabled`.
    ///   - autoInstall: The opt-out policy gating whether the supervisor may auto-install a
    ///     `.notFound` server's binary via its `ServerSpec.installer`. Defaults to
    ///     `LspAutoInstall()` (enabled, 300-second timeout); existing callers compile unchanged.
    /// - Throws: `CodeContextError.storage` if the index store can't be opened or migrated.
    public init(rootDirectory: URL, embedder: TextEmbedding?, autoInstall: LspAutoInstall = LspAutoInstall()) async throws {
        try await self.init(
            rootDirectory: rootDirectory,
            embedder: embedder,
            autoInstall: autoInstall,
            connectionFactory: LSPDaemon<ProcessLanguageServerConnection>.processConnectionFactory()
        )
    }
}

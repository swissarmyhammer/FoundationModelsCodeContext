import Foundation
import FoundationModelsExtras

/// Owns and routes to one `CodeContext` per open workspace root, enforcing a strict
/// non-overlapping-roots invariant across every root currently open.
///
/// Mirrors `CodeContext`'s own visibility pattern exactly: an internal general initializer
/// `init(embedder:clock:eventSource:connectionFactory:)` stores the pieces used to build every
/// context this manager creates (so tests inject `FakeLanguageServerConnection`/
/// `FakeFileEventSource`/`ManualClock`), and the only initializer visible outside this module is
/// the `where Connection == ProcessLanguageServerConnection` convenience initializer below — the
/// general initializer takes an internal `ConnectionFactory`, so it can never itself be `public`.
///
/// `CodeContext` stays public and unchanged: this actor builds on it, never wraps or hides it, so
/// every accessor below hands back the real `CodeContext` instance a caller can keep using
/// directly. This is a keep-all-started lifecycle — every successful `context(for:)` call has
/// already run `start()` on the context it returns.
///
/// `start()` does not wait for the first index pass. Thus a context that `context(for:)` returns
/// can have a partial index. A caller that needs the complete index calls
/// `waitForFirstIndexPass()` on the returned context.
///
/// ## Sharing one context among several users
///
/// Several users of one process that work in the same root — for example several agent sessions
/// with the same working directory — share one `CodeContext`, thus one watcher, one index loop,
/// one LSP fleet and one database pool. Each user calls `acquire(root:)` once and
/// `release(root:)` once. The last release stops the context. `close(root:)` stops it at once,
/// whatever the count of leases.
///
/// Every root is keyed by `rootKey(for:)`: the standardized URL with its symlinks resolved. Thus
/// a symlink to a root and the root itself share one context.
///
/// One manager has one embedder, one auto-install policy and one index-directory rule, which
/// every context of the manager gets. An acquire cannot bring another embedder. A host that needs
/// a context with another embedder makes another manager.
public actor CodeContextManager<Connection: LanguageServerConnection> {
    /// One entry per open root's context, keyed by `rootKey(for:)` of that root.
    private var contexts: [URL: CodeContext<Connection>] = [:]

    /// The count of the leases of each open root that `acquire(root:)` gave, keyed like
    /// `contexts`. A root opened only with `context(for:)` or `context(containing:)` has no entry.
    private var leases: [URL: Int] = [:]

    /// The in-flight create+start `Task` for a root currently being opened, keyed by that root's
    /// standardized URL, so concurrent `context(for:)` calls for the *same* root dedupe onto one
    /// create+start rather than each racing to build (and orphan) its own `CodeContext`. Mirrors
    /// `LspSupervisor.inFlightStart`'s coalescing pattern, keyed per-root instead of singleton
    /// since a manager can have several independent opens in flight at once.
    private var inFlightOpens: [URL: Task<CodeContext<Connection>, Error>] = [:]

    /// Every currently open context, keyed by its standardized root URL.
    ///
    /// Internal, not `private`: `Ops/ManagerQueries.swift`'s fan-out queries (`searchCode`,
    /// `searchSymbol`, `grepCode`) live in a different file in this module and need to enumerate
    /// every open context to fan a query out across all of them. `contexts` itself stays
    /// `private` so nothing outside this file can mutate it; this computed property is the
    /// read-only surface those queries iterate over.
    var openContexts: [URL: CodeContext<Connection>] { contexts }

    /// The embedder that each `CodeContext` of this manager receives. `nil` turns the embedding
    /// layer off for each `CodeContext` that this manager creates. Then `searchCode` and
    /// `findDuplicates` throw `CodeContextError.embeddingDisabled`.
    private let embedder: PooledEmbedding?

    /// The clock handed to every `CodeContext` this manager creates. Defaults to
    /// `ContinuousClock()`; tests inject a fake or manually-driven clock.
    private let clock: any Clock<Duration>

    /// The filesystem-change event source handed to every `CodeContext` this manager creates.
    /// Defaults to `FSEventsFileEventSource()`; tests inject `FakeFileEventSource`. `nil` turns
    /// the watcher off for each `CodeContext` that this manager creates.
    private let eventSource: (any FileEventSource)?

    /// The opt-out policy handed to every `CodeContext` this manager creates, gating whether that
    /// context's supervisor may auto-install a `.notFound` server's binary via its
    /// `ServerSpec.installer`.
    private let autoInstall: LspAutoInstall

    /// The process-running seam handed to every `CodeContext` this manager creates, which its
    /// supervisor's `ServerInstaller` drives. Defaults to `ProcessInstallRunner()`; tests inject a
    /// scripted `FakeInstallRunner` so an auto-install integration test driven through this manager
    /// never spawns (or has any real side effect from) a real installer command.
    private let installRunner: any InstallRunner

    /// Gives the index directory of each root that this manager opens, from its `rootKey(for:)`.
    /// `nil` gives each context the default `<root>/.code-context`.
    private let indexDirectory: (@Sendable (URL) -> URL)?

    /// Spawns a fresh LSP connection for every daemon any `CodeContext` this manager creates ends
    /// up needing.
    private let connectionFactory: ConnectionFactory<Connection>

    /// Unified, SwiftUI-observable aggregate of every open root's `CodeContextState`.
    public nonisolated let state: ManagerState

    /// Creates a manager that will build every `CodeContext` it opens from these same stored
    /// pieces. No root is opened and no context is created until `context(for:)` or
    /// `context(containing:)` is called.
    ///
    /// Not `public`: `connectionFactory` is typed against the internal `ConnectionFactory`
    /// typealias, so this initializer can never satisfy a public declaration's visibility
    /// requirements — mirrors `CodeContext`'s own internal general initializer. Production
    /// callers use the `where Connection == ProcessLanguageServerConnection` convenience
    /// initializer below; tests call this one directly (via `@testable import`) with a factory
    /// that hands back `FakeLanguageServerConnection`s.
    ///
    /// - Parameters:
    ///   - embedder: The embedder that each `CodeContext` of this manager receives. `nil` turns
    ///     the embedding layer off for each `CodeContext` that this manager creates. Then
    ///     `searchCode` and `findDuplicates` throw `CodeContextError.embeddingDisabled`.
    ///   - clock: The clock handed to every `CodeContext` this manager creates. Defaults to
    ///     `ContinuousClock()`; tests inject a faster or manually-driven clock.
    ///   - eventSource: The filesystem-change event source handed to every `CodeContext` this
    ///     manager creates, or `nil` to turn the watcher of each context off. Defaults to
    ///     `FSEventsFileEventSource()`; tests inject `FakeFileEventSource`.
    ///   - autoInstall: The opt-out policy handed to every `CodeContext` this manager creates.
    ///     Defaults to `LspAutoInstall()` (enabled, 300-second timeout); existing callers compile
    ///     unchanged.
    ///   - installRunner: The process-running seam handed to every `CodeContext` this manager
    ///     creates, which its supervisor's `ServerInstaller` drives. Defaults to
    ///     `ProcessInstallRunner()`; tests inject a scripted `FakeInstallRunner` so an auto-install
    ///     integration test driven through this manager never spawns a real installer command.
    ///   - indexDirectory: Gives the index directory of each root, from its `rootKey(for:)`.
    ///     Defaults to `nil`, which gives each context `<root>/.code-context`.
    ///   - connectionFactory: Spawns a fresh connection for every LSP daemon any created
    ///     `CodeContext`'s supervisor ends up needing.
    init(
        embedder: PooledEmbedding?,
        clock: any Clock<Duration> = ContinuousClock(),
        eventSource: (any FileEventSource)? = FSEventsFileEventSource(),
        autoInstall: LspAutoInstall = LspAutoInstall(),
        installRunner: any InstallRunner = ProcessInstallRunner(),
        indexDirectory: (@Sendable (URL) -> URL)? = nil,
        connectionFactory: @escaping ConnectionFactory<Connection>
    ) async {
        self.embedder = embedder
        self.clock = clock
        self.eventSource = eventSource
        self.autoInstall = autoInstall
        self.installRunner = installRunner
        self.indexDirectory = indexDirectory
        self.connectionFactory = connectionFactory
        state = await ManagerState()
    }

    // MARK: - Root key

    /// The key of `url` in this manager: the standardized URL with its symlinks resolved.
    ///
    /// Every method of this manager keys its roots with this function, thus a symlink to a root
    /// and the root itself are one root. A host that keys its own data per root, for example an
    /// index directory, uses this function to get the same key.
    /// - Parameter url: A root or a path.
    /// - Returns: `url.standardizedFileURL.resolvingSymlinksInPath()`.
    public static func rootKey(for url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    // MARK: - Open / route

    /// Returns the `CodeContext` for `root`, opening (and starting) one if none is already open
    /// for it — applying the overlap rule against every currently open root first.
    ///
    /// `root` is keyed with `rootKey(for:)` before any comparison, then:
    /// - **Exact match** against an already-open root: returns that root's existing context.
    /// - **`root` is a descendant** of an already-open root: returns that ancestor's context —
    ///   its walker already covers the subtree, so no separate context is ever created for a
    ///   directory nested inside one already open.
    /// - **`root` is an ancestor** of one or more already-open (or still-opening) roots: throws
    ///   `CodeContextError.overlappingRoot`, naming the conflicting children. The caller must
    ///   `close(root:)` every already-open one before opening the ancestor (a still-opening one
    ///   settles on its own once its own `context(for:)` call returns or throws).
    /// - **Otherwise**: builds a fresh `CodeContext` from this manager's stored pieces, `start()`s
    ///   it, registers it, and publishes it into `state`. A `start()` failure leaves this manager
    ///   unregistered for `root` — the context is never added to `contexts` — and the error
    ///   propagates to every caller awaiting this open.
    ///
    /// Every overlap/dedupe check above tests both `contexts` (fully open roots) and
    /// `inFlightOpens` (roots currently mid-open, not yet registered) — not `contexts` alone.
    /// Without also consulting `inFlightOpens`, two brand-new, never-before-seen roots opened
    /// concurrently — one nested inside the other — would each pass the overlap check (neither
    /// is yet in `contexts`) and each build and start its own `CodeContext`, leaving two live,
    /// started contexts for overlapping roots simultaneously: exactly the "strict
    /// non-overlapping-roots invariant" this type exists to enforce. Folding `inFlightOpens` into
    /// every check closes that gap: whichever concurrent call reaches the actor's synchronous
    /// overlap check first stakes the claim (by being the one to store into `inFlightOpens`); the
    /// other either dedupes onto it (same or descendant root) or is rejected as overlapping
    /// (ancestor root) before it ever creates a `CodeContext`.
    ///
    /// Concurrent calls for the *same* root dedupe onto one create+start via `inFlightOpens`,
    /// mirroring `LspSupervisor.start()`'s `inFlightStart` coalescing: only the first caller's
    /// task actually builds and starts a `CodeContext`; every other concurrent caller for that
    /// root awaits that same task's result instead of racing to build its own. A concurrent call
    /// for a *descendant* of a root currently being opened dedupes the same way, awaiting the
    /// in-flight ancestor's task and returning its result rather than racing to build its own.
    ///
    /// Accepts any directory, git repo or not: non-git workspaces are an explicit-open feature —
    /// only `context(containing:)`'s lazy routing through `RootDiscovery` is git-scoped.
    /// - Parameter root: The workspace root to open or fetch.
    /// - Returns: `root`'s `CodeContext`, already started. `start()` does not wait for the first
    ///   index pass, thus the index can be partial. A caller that needs the complete index calls
    ///   `waitForFirstIndexPass()` on the returned context.
    /// - Throws: `CodeContextError.overlappingRoot` if `root` is an ancestor of one or more
    ///   already-open or still-opening roots; otherwise rethrows `CodeContext.init`'s or
    ///   `start()`'s errors (including a still-opening ancestor's own failure, when `root` is a
    ///   descendant of one).
    public func context(for root: URL) async throws -> CodeContext<Connection> {
        let standardizedRoot = Self.rootKey(for: root)

        if let existing = contexts[standardizedRoot] {
            return existing
        }
        if let ancestor = openContext(ancestorOf: standardizedRoot) {
            return ancestor
        }
        if let exactInFlight = inFlightOpens[standardizedRoot] {
            return try await exactInFlight.value
        }
        if let ancestorInFlight = inFlightOpen(ancestorOf: standardizedRoot) {
            return try await ancestorInFlight.value
        }

        let overlappingDescendants = Set(
            descendantRoots(of: standardizedRoot, in: contexts.keys)
                + descendantRoots(of: standardizedRoot, in: inFlightOpens.keys)
        )
        guard overlappingDescendants.isEmpty else {
            throw CodeContextError.overlappingRoot(
                overlappingDescendants.map(\.path).sorted().joined(separator: ", ")
            )
        }

        let openTask = Task { try await self.createStartAndRegister(root: standardizedRoot) }
        inFlightOpens[standardizedRoot] = openTask
        defer { inFlightOpens[standardizedRoot] = nil }
        return try await openTask.value
    }

    /// Resolves the `CodeContext` covering `path`, preferring an already-open root and only
    /// falling back to discovering (and optionally opening) `path`'s enclosing git repo.
    ///
    /// Resolution order:
    /// 1. Longest-prefix match against already-open roots (`path` itself or a descendant of one)
    ///    — never throws on this path, since every candidate is already open and started.
    /// 2. `RootDiscovery.gitRoot(containing:)` to find `path`'s enclosing repo root. If found and
    ///    `openIfNeeded` is `true`, routes through the throwing `context(for:)` to open it (which
    ///    still applies the overlap rule, since a discovered git root could itself be an ancestor
    ///    of some other already-open root).
    /// 3. `nil` — no open root covers `path`, no enclosing git repo exists, or one exists but
    ///    `openIfNeeded` is `false`.
    /// - Parameters:
    ///   - path: The file or directory to resolve a covering workspace for.
    ///   - openIfNeeded: Whether to lazily open `path`'s enclosing git repo when no already-open
    ///     root covers it. Defaults to `true`.
    /// - Returns: The covering `CodeContext`, or `nil` per the resolution order above.
    /// - Throws: Rethrows `context(for:)`'s errors when `openIfNeeded` triggers a fresh open.
    public func context(containing path: URL, openIfNeeded: Bool = true) async throws -> CodeContext<Connection>? {
        let standardizedPath = Self.rootKey(for: path)

        if let covering = openContext(coveringOrAncestorOf: standardizedPath) {
            return covering
        }

        guard let gitRoot = RootDiscovery.gitRoot(containing: standardizedPath), openIfNeeded else {
            return nil
        }
        return try await context(for: gitRoot)
    }

    // MARK: - Acquire / release

    /// Returns the shared `CodeContext` for `root` and adds one lease to it.
    ///
    /// Opens `root` like `context(for:)` does, with the same overlap rule, thus a `root` inside an
    /// open root gets the context of that open root and leases it. Each call needs one
    /// `release(root:)` call later. The last release stops the context.
    /// - Parameter root: The workspace root to open or share.
    /// - Returns: The started context of `root`, or of the open root that covers `root`.
    /// - Throws: Rethrows the errors of `context(for:)`. A failed acquire adds no lease.
    public func acquire(root: URL) async throws -> CodeContext<Connection> {
        let context = try await self.context(for: root)
        leases[context.rootDirectory, default: 0] += 1
        return context
    }

    /// Removes one lease that `acquire(root:)` gave, and stops the context when that was its last
    /// lease.
    ///
    /// `root` can be any path that the open root covers, for example the same path that the
    /// acquire got. A no-op for a path that no open root covers, or for an open root that has no
    /// lease, thus it never stops a context that only `context(for:)` opened.
    /// - Parameter root: The root that was acquired.
    public func release(root: URL) async {
        guard let context = openContext(coveringOrAncestorOf: Self.rootKey(for: root)) else {
            return
        }
        let key = context.rootDirectory
        guard let count = leases[key] else {
            return
        }
        if count > 1 {
            leases[key] = count - 1
            return
        }
        await close(root: key)
    }

    // MARK: - Close / shutdown

    /// Stops and removes `root`'s context, if one is open, and drops its leases.
    ///
    /// A no-op — neither throwing nor doing anything — for a root that isn't currently open.
    /// - Parameter root: The workspace root to close. Keyed with `rootKey(for:)` before use,
    ///   matching every other root comparison in this actor.
    public func close(root: URL) async {
        let standardizedRoot = Self.rootKey(for: root)
        leases[standardizedRoot] = nil
        guard let context = contexts.removeValue(forKey: standardizedRoot) else {
            return
        }
        await context.stop()
        await state.publishClosed(root: standardizedRoot)
    }

    /// Closes every currently open root.
    ///
    /// Snapshots `contexts.keys` into an array before iterating, since each `close(root:)` call
    /// mutates `contexts` — iterating the dictionary's own (live) `keys` view while mutating it
    /// underneath the loop would be unsafe.
    public func shutdown() async {
        for root in Array(contexts.keys) {
            await close(root: root)
        }
    }

    // MARK: - Overlap rule

    /// The already-open root's context that `standardizedPath` is a descendant of, if any.
    ///
    /// The overlap rule enforced by `context(for:)` guarantees at most one open root can ever be
    /// an ancestor of a given path, so the first match `firstAncestorValue(of:in:)` finds is the
    /// only one there ever is.
    /// - Parameter standardizedPath: An already-standardized path to check.
    /// - Returns: The already-open root's context that is an ancestor of `standardizedPath`, or
    ///   `nil` if none exists.
    private func openContext(ancestorOf standardizedPath: URL) -> CodeContext<Connection>? {
        firstAncestorValue(of: standardizedPath, in: contexts)
    }

    /// The already-open root's context that `standardizedPath` is either equal to or a descendant
    /// of, if any — the resolution `context(containing:)` needs, unlike `openContext(ancestorOf:)`
    /// which only ever tests for strict descendance.
    /// - Parameter standardizedPath: An already-standardized path to check.
    /// - Returns: The already-open root's context that `standardizedPath` equals or is a
    ///   descendant of, or `nil` if none exists.
    private func openContext(coveringOrAncestorOf standardizedPath: URL) -> CodeContext<Connection>? {
        if let exact = contexts[standardizedPath] {
            return exact
        }
        return openContext(ancestorOf: standardizedPath)
    }

    /// Every URL in `roots` that is a descendant of `standardizedPath` — the shared filtering
    /// logic behind both halves of `context(for:)`'s overlap-descendant check, which previously
    /// existed as two near-identical functions (`openRoots(descendantsOf:)` and
    /// `inFlightRoots(descendantsOf:)`) differing only in which key collection they filtered
    /// (`contexts.keys` vs. `inFlightOpens.keys`).
    /// - Parameters:
    ///   - standardizedPath: An already-standardized path to check.
    ///   - roots: The candidate root URLs to filter — typically `contexts.keys` or
    ///     `inFlightOpens.keys`.
    /// - Returns: The subset of `roots` that are descendants of `standardizedPath`.
    private func descendantRoots(of standardizedPath: URL, in roots: some Sequence<URL>) -> [URL] {
        roots.filter { Self.isDescendant($0, of: standardizedPath) }
    }

    /// The in-flight open task for a root currently being opened that `standardizedPath` is a
    /// descendant of, if any — the still-opening counterpart of `openContext(ancestorOf:)`,
    /// needed so a concurrent open of a brand-new child root dedupes onto (awaits) its still-
    /// opening, brand-new parent instead of racing to build its own context for the same
    /// subtree. See `context(for:)`'s documentation for why `inFlightOpens` must be checked here
    /// alongside `contexts`.
    /// - Parameter standardizedPath: An already-standardized path to check.
    /// - Returns: The in-flight open task for a still-opening root that `standardizedPath` is a
    ///   descendant of, or `nil` if none exists.
    private func inFlightOpen(ancestorOf standardizedPath: URL) -> Task<CodeContext<Connection>, Error>? {
        firstAncestorValue(of: standardizedPath, in: inFlightOpens)
    }

    /// The value in `dictionary` keyed by a root that `standardizedPath` is a descendant of, if
    /// any — the shared ancestor-lookup logic behind both `openContext(ancestorOf:)` and
    /// `inFlightOpen(ancestorOf:)`, which previously existed as two near-identical functions
    /// differing only in which dictionary they scanned (`contexts` vs. `inFlightOpens`) and the
    /// type of value returned (`CodeContext` vs. `Task`).
    ///
    /// The overlap rule enforced by `context(for:)` guarantees at most one key in either
    /// dictionary can ever be an ancestor of a given path, so the first match found is the only
    /// one there ever is.
    /// - Parameters:
    ///   - standardizedPath: An already-standardized path to check.
    ///   - dictionary: The root-keyed mapping to scan — typically `contexts` or `inFlightOpens`.
    /// - Returns: The value keyed by the root that is an ancestor of `standardizedPath`, or `nil`
    ///   if none exists.
    private func firstAncestorValue<T>(of standardizedPath: URL, in dictionary: [URL: T]) -> T? {
        dictionary.first { Self.isDescendant(standardizedPath, of: $0.key) }?.value
    }

    /// Whether `path` is strictly inside `root` — i.e. `root` is a proper ancestor directory of
    /// `path` — using a trailing-separator prefix test so a sibling directory whose name merely
    /// starts with `root`'s own path (e.g. `/a/foo-bar` vs. `/a/foo`) is never mistaken for an
    /// actual descendant.
    /// - Parameters:
    ///   - path: The candidate descendant path.
    ///   - root: The candidate ancestor path.
    /// - Returns: `true` only if `path.path` begins with `root.path` followed by a path
    ///   separator (never merely `root.path` itself as a plain string prefix).
    private static func isDescendant(_ path: URL, of root: URL) -> Bool {
        let rootPathWithSeparator = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return path.path.hasPrefix(rootPathWithSeparator)
    }

    // MARK: - Create + register

    /// Builds a fresh `CodeContext` for `root` from this manager's stored pieces, starts it, and
    /// — only once `start()` has actually succeeded — registers it in `contexts` and publishes it
    /// into `state`.
    ///
    /// Run inside the single `Task` `context(for:)` stores in `inFlightOpens` for `root`, so this
    /// method's mutations (`contexts[root] = ...`, `state.publishOpened(...)`) happen exactly
    /// once per root even when several callers concurrently requested the same open — they all
    /// await this one task's result rather than each running their own copy of this method.
    /// - Parameter root: The already-standardized workspace root to open.
    /// - Returns: The freshly created and started context.
    /// - Throws: Rethrows `CodeContext.init`'s or `start()`'s errors; on failure `root` is left
    ///   unregistered.
    private func createStartAndRegister(root: URL) async throws -> CodeContext<Connection> {
        let context = try await CodeContext<Connection>(
            rootDirectory: root,
            indexDirectory: indexDirectory?(root),
            embedder: embedder,
            clock: clock,
            eventSource: eventSource,
            autoInstall: autoInstall,
            installRunner: installRunner,
            connectionFactory: connectionFactory
        )
        try await context.start()

        contexts[root] = context
        await state.publishOpened(root: root, state: context.state)
        return context
    }
}

extension CodeContextManager where Connection == ProcessLanguageServerConnection {
    /// Creates a manager wired to spawn real subprocess-backed LSP daemons for every workspace it
    /// opens.
    ///
    /// This is the only initializer visible outside this module — mirrors `CodeContext`'s own
    /// `where Connection == ProcessLanguageServerConnection` convenience initializer.
    /// - Parameters:
    ///   - embedder: The embedder that each `CodeContext` of this manager receives. `nil` turns
    ///     the embedding layer off for each `CodeContext` that this manager creates. Then
    ///     `searchCode` and `findDuplicates` throw `CodeContextError.embeddingDisabled`.
    ///   - autoInstall: The opt-out policy handed to every `CodeContext` this manager creates.
    ///     Defaults to `LspAutoInstall()` (enabled, 300-second timeout); existing callers compile
    ///     unchanged.
    ///   - eventSource: The raw filesystem-change event source of the watcher of each
    ///     `CodeContext` that this manager creates. Defaults to `FSEventsFileEventSource()`. Give
    ///     `nil` to turn the watchers off: then no FSEvents stream starts.
    ///   - indexDirectory: Gives the index directory (`kit.db`) of each root, from its
    ///     `rootKey(for:)`. Defaults to `nil`, which gives each context `<root>/.code-context`.
    ///     Give a directory outside the root to keep the index out of it, for example when the
    ///     root is in a synced folder.
    public init(
        embedder: PooledEmbedding?,
        autoInstall: LspAutoInstall = LspAutoInstall(),
        eventSource: (any FileEventSource)? = FSEventsFileEventSource(),
        indexDirectory: (@Sendable (URL) -> URL)? = nil
    ) async {
        await self.init(
            embedder: embedder,
            eventSource: eventSource,
            autoInstall: autoInstall,
            indexDirectory: indexDirectory,
            connectionFactory: LSPDaemon<ProcessLanguageServerConnection>.processConnectionFactory()
        )
    }
}

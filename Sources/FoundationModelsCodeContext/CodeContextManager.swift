import Foundation

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
public actor CodeContextManager<Connection: LanguageServerConnection> {
    /// One entry per open root's context, keyed by that root's standardized URL.
    private var contexts: [URL: CodeContext<Connection>] = [:]

    /// The in-flight create+start `Task` for a root currently being opened, keyed by that root's
    /// standardized URL, so concurrent `context(for:)` calls for the *same* root dedupe onto one
    /// create+start rather than each racing to build (and orphan) its own `CodeContext`. Mirrors
    /// `LspSupervisor.inFlightStart`'s coalescing pattern, keyed per-root instead of singleton
    /// since a manager can have several independent opens in flight at once.
    private var inFlightOpens: [URL: Task<CodeContext<Connection>, Error>] = [:]

    /// The embedder handed to every `CodeContext` this manager creates.
    private let embedder: TextEmbedding

    /// The clock handed to every `CodeContext` this manager creates. Defaults to
    /// `ContinuousClock()`; tests inject a fake or manually-driven clock.
    private let clock: any Clock<Duration>

    /// The filesystem-change event source handed to every `CodeContext` this manager creates.
    /// Defaults to `FSEventsFileEventSource()`; tests inject `FakeFileEventSource`.
    private let eventSource: any FileEventSource

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
    ///   - embedder: The embedder handed to every `CodeContext` this manager creates.
    ///   - clock: The clock handed to every `CodeContext` this manager creates. Defaults to
    ///     `ContinuousClock()`; tests inject a faster or manually-driven clock.
    ///   - eventSource: The filesystem-change event source handed to every `CodeContext` this
    ///     manager creates. Defaults to `FSEventsFileEventSource()`; tests inject
    ///     `FakeFileEventSource`.
    ///   - connectionFactory: Spawns a fresh connection for every LSP daemon any created
    ///     `CodeContext`'s supervisor ends up needing.
    init(
        embedder: TextEmbedding,
        clock: any Clock<Duration> = ContinuousClock(),
        eventSource: any FileEventSource = FSEventsFileEventSource(),
        connectionFactory: @escaping ConnectionFactory<Connection>
    ) async {
        self.embedder = embedder
        self.clock = clock
        self.eventSource = eventSource
        self.connectionFactory = connectionFactory
        state = await ManagerState()
    }

    // MARK: - Open / route

    /// Returns the `CodeContext` for `root`, opening (and starting) one if none is already open
    /// for it — applying the overlap rule against every currently open root first.
    ///
    /// `root` is standardized before any comparison, then:
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
    /// - Returns: `root`'s `CodeContext`, already started.
    /// - Throws: `CodeContextError.overlappingRoot` if `root` is an ancestor of one or more
    ///   already-open or still-opening roots; otherwise rethrows `CodeContext.init`'s or
    ///   `start()`'s errors (including a still-opening ancestor's own failure, when `root` is a
    ///   descendant of one).
    public func context(for root: URL) async throws -> CodeContext<Connection> {
        let standardizedRoot = root.standardizedFileURL

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
        let standardizedPath = path.standardizedFileURL

        if let covering = openContext(coveringOrAncestorOf: standardizedPath) {
            return covering
        }

        guard let gitRoot = RootDiscovery.gitRoot(containing: standardizedPath), openIfNeeded else {
            return nil
        }
        return try await context(for: gitRoot)
    }

    // MARK: - Close / shutdown

    /// Stops and removes `root`'s context, if one is open.
    ///
    /// A no-op — neither throwing nor doing anything — for a root that isn't currently open.
    /// - Parameter root: The workspace root to close. Standardized before use, matching every
    ///   other root comparison in this actor.
    public func close(root: URL) async {
        let standardizedRoot = root.standardizedFileURL
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
    /// an ancestor of a given path, so the first match found is the only one there ever is.
    /// - Parameter standardizedPath: An already-standardized path to check.
    /// - Returns: The already-open root's context that is an ancestor of `standardizedPath`, or
    ///   `nil` if none exists.
    private func openContext(ancestorOf standardizedPath: URL) -> CodeContext<Connection>? {
        for (openRoot, context) in contexts where Self.isDescendant(standardizedPath, of: openRoot) {
            return context
        }
        return nil
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
        for (pendingRoot, task) in inFlightOpens where Self.isDescendant(standardizedPath, of: pendingRoot) {
            return task
        }
        return nil
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
            embedder: embedder,
            clock: clock,
            eventSource: eventSource,
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
    /// - Parameter embedder: The embedder handed to every `CodeContext` this manager creates.
    public init(embedder: TextEmbedding) async {
        await self.init(
            embedder: embedder,
            connectionFactory: LSPDaemon<ProcessLanguageServerConnection>.processConnectionFactory()
        )
    }
}

import Foundation
import Observation

/// A snapshot of per-layer indexing progress across a workspace's tracked files.
///
/// Published wholesale by the tree-sitter and LSP indexing workers as they drain `Store`'s dirty
/// flags (see plan.md's "The index" section): `filesWalked` is the total file count the startup
/// walk/reconcile pass discovered, and each remaining count is how many of those files have
/// finished that layer. `CodeContextState.isReady` treats a layer as drained once its count has
/// caught up to `filesWalked` (see `isDrained`).
public struct IndexProgress: Sendable, Equatable {
    /// The number of files discovered by the startup walk/reconcile pass.
    public let filesWalked: Int

    /// The number of files with tree-sitter parsing complete (`ts_indexed = 1`).
    public let filesParsed: Int

    /// The number of files with embedding complete (`embedded = 1`).
    public let filesEmbedded: Int

    /// The number of files with LSP indexing complete (`lsp_indexed = 1`).
    public let filesLspIndexed: Int

    /// Creates an indexing-progress snapshot.
    /// - Parameters:
    ///   - filesWalked: The number of files discovered by the startup walk/reconcile pass.
    ///   - filesParsed: The number of files with tree-sitter parsing complete.
    ///   - filesEmbedded: The number of files with embedding complete.
    ///   - filesLspIndexed: The number of files with LSP indexing complete.
    public init(filesWalked: Int, filesParsed: Int, filesEmbedded: Int, filesLspIndexed: Int) {
        self.filesWalked = filesWalked
        self.filesParsed = filesParsed
        self.filesEmbedded = filesEmbedded
        self.filesLspIndexed = filesLspIndexed
    }

    /// The initial progress snapshot before any file has been walked: every layer trivially
    /// drained (there is nothing yet to index).
    public static let zero = IndexProgress(filesWalked: 0, filesParsed: 0, filesEmbedded: 0, filesLspIndexed: 0)

    /// Whether every indexing layer has caught up to `filesWalked` — no indexing work remains
    /// outstanding for any layer.
    public var isDrained: Bool {
        filesParsed >= filesWalked && filesEmbedded >= filesWalked && filesLspIndexed >= filesWalked
    }
}

/// Unified, SwiftUI-observable snapshot of one workspace's `CodeContext`: detected projects, LSP
/// daemon health, indexing progress, and live diagnostics.
///
/// Ports plan.md's "Observable state for SwiftUI" design. `CodeContext` vends exactly one
/// instance of this class per workspace — a `nonisolated public let` created once at `init` and
/// never replaced — and publishes into it, hopping to the main actor, from the indexing workers,
/// the LSP supervisor's health loop, and the session's diagnostics stream; a SwiftUI harness binds
/// directly to the instance and observes it like any other `@Observable` model. Every stored
/// property is `private(set)`: state only changes through the `publish*` methods below.
@MainActor
@Observable
public final class CodeContextState {
    /// The workspace root this state describes, fixed at construction.
    public private(set) var rootDirectory: URL

    /// Every project detected under `rootDirectory`, filled by project detection during
    /// `CodeContext.start()` and refreshed by `CodeContext.detectProjects()`.
    public private(set) var projects: [DetectedProject]

    /// Every managed LSP daemon's current lifecycle state, one entry per unique server command.
    public private(set) var servers: [ServerStatus]

    /// Per-layer indexing progress across the workspace's tracked files.
    public private(set) var indexing: IndexProgress

    /// Live diagnostics per open document. Each publish replaces the named URI's array wholesale
    /// — matching the LSP `publishDiagnostics` notification's own replace semantics — it is never
    /// appended to.
    public private(set) var diagnostics: [DocumentURI: [Diagnostic]]

    /// Whether the workspace has finished settling: every indexing layer has drained
    /// (`IndexProgress.isDrained`) and every managed server has reached a settled lifecycle state
    /// (running, not found, or permanently failed — see `isSettled(_:)`).
    ///
    /// Both conditions are vacuously true of the zero/empty state this class starts in (see
    /// `init(rootDirectory:)`), so a freshly constructed instance reports `isReady == true` until
    /// the first `publishIndexing(_:)`/`publishServers(_:)` call supersedes it with real work —
    /// there is, after all, nothing outstanding to wait for yet. Callers that need to distinguish
    /// "nothing started" from "genuinely settled" should track whether `CodeContext.start()` has
    /// been called, rather than reading this flag alone.
    public private(set) var isReady: Bool

    /// Creates the observable state for a workspace, before any indexing or LSP activity has been
    /// published into it. `isReady` starts `true` — see its documentation for why the zero/empty
    /// initial state is vacuously ready.
    /// - Parameter rootDirectory: The workspace root this state describes.
    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
        self.projects = []
        self.servers = []
        self.indexing = .zero
        self.diagnostics = [:]
        self.isReady = Self.computeIsReady(indexing: .zero, servers: [])
    }

    // MARK: - Publisher API

    /// Publishes a freshly detected project list, replacing `projects` wholesale.
    ///
    /// `nonisolated` so callers on any isolation domain (worker tasks, actor-isolated
    /// subsystems) can call it directly; the mutation itself hops onto the main actor, and this
    /// method suspends until that mutation has landed, so callers — and tests — can `await` its
    /// visible effect rather than firing-and-forgetting it.
    /// - Parameter projects: The newly detected project list.
    public nonisolated func publishProjects(_ projects: [DetectedProject]) async {
        await MainActor.run {
            self.projects = projects
        }
    }

    /// Publishes a fresh managed-server status snapshot, replacing `servers` wholesale, and
    /// recomputes `isReady`.
    ///
    /// See `publishProjects(_:)`'s documentation for this method's `nonisolated`/awaitable shape.
    /// - Parameter servers: The newly observed server statuses, one per managed daemon.
    public nonisolated func publishServers(_ servers: [ServerStatus]) async {
        await MainActor.run {
            self.servers = servers
            self.isReady = Self.computeIsReady(indexing: self.indexing, servers: servers)
        }
    }

    /// Publishes a fresh indexing-progress snapshot, replacing `indexing` wholesale, and
    /// recomputes `isReady`.
    ///
    /// See `publishProjects(_:)`'s documentation for this method's `nonisolated`/awaitable shape.
    /// - Parameter indexing: The newly observed per-layer indexing progress.
    public nonisolated func publishIndexing(_ indexing: IndexProgress) async {
        await MainActor.run {
            self.indexing = indexing
            self.isReady = Self.computeIsReady(indexing: indexing, servers: self.servers)
        }
    }

    /// Publishes a fresh diagnostics array for one document, replacing that URI's entry wholesale
    /// rather than appending to it — matching the LSP `publishDiagnostics` notification's own
    /// replace semantics (each notification carries the complete, current diagnostic set for the
    /// URI, not a delta).
    ///
    /// See `publishProjects(_:)`'s documentation for this method's `nonisolated`/awaitable shape.
    /// - Parameters:
    ///   - uri: The document these diagnostics apply to.
    ///   - diagnostics: The document's complete, current diagnostic set.
    public nonisolated func publishDiagnostics(uri: DocumentURI, diagnostics: [Diagnostic]) async {
        await MainActor.run {
            self.diagnostics[uri] = diagnostics
        }
    }

    // MARK: - isReady derivation

    /// The consecutive-failure count past which a `.failed` daemon state is considered
    /// permanently settled rather than still being retried.
    ///
    /// Mirrors `LSPDaemon`'s private backoff give-up threshold (5, documented in plan.md's LSP
    /// subsystem section: "giving up after 5 consecutive failures"). Duplicated here rather than
    /// shared because `LSPDaemon` never exposes that threshold — it's an internal detail of its
    /// own retry policy, whereas this is a distinct concern (classifying a snapshot for SwiftUI
    /// state) that needs the same number without reaching into `LSPDaemon`'s private state.
    private static let maxConsecutiveFailures = 5

    /// Computes `isReady` from an indexing snapshot and a server-status snapshot.
    ///
    /// `true` only when every indexing layer has drained (`IndexProgress.isDrained`) and every
    /// managed server has reached a settled lifecycle state (`isSettled(_:)`). An empty `servers`
    /// array is vacuously "every server settled" — no daemons were ever spawned, e.g. a workspace
    /// with no LSP-backed languages.
    /// - Parameters:
    ///   - indexing: The indexing-progress snapshot to evaluate.
    ///   - servers: The server-status snapshot to evaluate.
    /// - Returns: Whether the workspace should be considered ready.
    private static func computeIsReady(indexing: IndexProgress, servers: [ServerStatus]) -> Bool {
        indexing.isDrained && servers.allSatisfy { isSettled($0.state) }
    }

    /// Whether a daemon lifecycle state is settled — the supervisor's health loop will not
    /// spontaneously change it further without external intervention (`forceRestart()`).
    ///
    /// A `switch`, not a `[LSPDaemonState: Bool]` dictionary: `LSPDaemonState` is a closed enum
    /// colocated with this, its only consumer, so an exhaustive switch turns a missing case into
    /// a compile error instead of a silently-wrong default — the same principle this codebase
    /// applies in `IndexAdmin`'s and `IndexLayer`'s enum-to-value mappings.
    /// - Parameter state: The daemon lifecycle state to classify.
    /// - Returns: `true` for `.running` and `.notFound`, `true` for `.failed` once `attempts` has
    ///   reached `maxConsecutiveFailures`, and `false` for every other state.
    private static func isSettled(_ state: LSPDaemonState) -> Bool {
        switch state {
        case .running, .notFound:
            true
        case let .failed(_, attempts):
            attempts >= maxConsecutiveFailures
        case .notStarted, .starting, .installing, .shuttingDown:
            false
        }
    }
}

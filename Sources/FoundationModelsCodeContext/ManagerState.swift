import Foundation
import Observation

/// Unified, SwiftUI-observable aggregate of every open root's `CodeContextState`.
///
/// A multi-root host (e.g. a SwiftUI app that lets a user open several workspaces at once) vends
/// exactly one `ManagerState` instance and publishes into it as roots open and close, mirroring
/// `CodeContextState`'s own publish/observe contract: every stored property is `private(set)`,
/// and the only mutation paths are the `nonisolated` async `publish*` methods below, which hop to
/// the main actor via `MainActor.run` and are awaitable. Because each `CodeContextState` is
/// itself `@Observable`, a SwiftUI view that reads `isReady` — or drills into a specific root's
/// state via `contexts` — tracks through to every child state's own published properties.
@MainActor
@Observable
public final class ManagerState {
    /// One entry per open root, keyed by the root's standardized URL (`URL.standardizedFileURL`)
    /// so callers can open the same directory via different (but equivalent) path spellings and
    /// still resolve to the same entry.
    public private(set) var contexts: [URL: CodeContextState]

    /// Every open root's standardized URL, sorted by path for stable SwiftUI iteration (e.g.
    /// `ForEach(manager.roots, id: \.self)`).
    public var roots: [URL] {
        contexts.keys.sorted { $0.path < $1.path }
    }

    /// Whether every open root has finished settling — see `CodeContextState.isReady`.
    ///
    /// Vacuously `true` when `contexts` is empty (no roots open, so nothing outstanding to wait
    /// for), matching how `CodeContextState.isReady` documents its own vacuous initial state.
    /// Computed rather than cached: each `CodeContextState` is itself `@Observable`, so reading
    /// this property inside a SwiftUI view tracks through `contexts.values` to every child's own
    /// `isReady`, and a child's `isReady` flipping is observed without `ManagerState` needing to
    /// republish anything itself.
    public var isReady: Bool {
        contexts.values.allSatisfy(\.isReady)
    }

    /// Creates an empty aggregate, before any root has been opened.
    public init() {
        self.contexts = [:]
    }

    // MARK: - Publisher API

    /// Publishes a newly opened root, adding its state under the root's standardized URL.
    ///
    /// `nonisolated` so callers on any isolation domain (worker tasks, actor-isolated
    /// subsystems) can call it directly; the mutation itself hops onto the main actor, and this
    /// method suspends until that mutation has landed, so callers — and tests — can `await` its
    /// visible effect rather than firing-and-forgetting it.
    /// - Parameters:
    ///   - root: The workspace root being opened. Standardized before use as the `contexts` key.
    ///   - state: The root's observable state, typically the instance `CodeContext` vends for it.
    public nonisolated func publishOpened(root: URL, state: CodeContextState) async {
        await MainActor.run {
            self.contexts[root.standardizedFileURL] = state
        }
    }

    /// Publishes a closed root, removing its entry.
    ///
    /// See `publishOpened(root:state:)`'s documentation for this method's
    /// `nonisolated`/awaitable shape.
    /// - Parameter root: The workspace root being closed. Standardized before use, matching
    ///   `publishOpened(root:state:)`'s key.
    public nonisolated func publishClosed(root: URL) async {
        await MainActor.run {
            _ = self.contexts.removeValue(forKey: root.standardizedFileURL)
        }
    }
}

import Foundation
import FoundationModelsCodeContext
import FoundationModelsRouter

/// A runnable executable demonstrating multi-root `CodeContextManager` lifecycle and fan-out queries.
///
/// The second "way in" to this package (see plan.md's Goal, and the sibling `CodeContextExample`'s
/// single-root walkthrough): point it at a *parent* directory holding several repositories and it
/// exercises `CodeContextManager`'s workspace-wide surface end to end — discover every repo root
/// beneath the parent, open each explicitly, resolve one file's covering root lazily, fan a search
/// out across every open root with root-qualified results, then shut every context down together.
///
/// ## Why this resolves through `FoundationModelsRouter` directly
///
/// See `CodeContextExample/main.swift`'s doc comment for the full rationale: this package ships no
/// embedder factory — `RoutedEmbedderAdapter`'s public initializer takes an already-resolved
/// `RoutedEmbedder` handle, so a host resolves a `FoundationModelsRouter` profile and injects the
/// embedder rather than the library owning that lifecycle itself. This file plays that host's part,
/// calling `Router.resolve(profile:reporting:)` directly and handing the single resulting embedder
/// to every root `CodeContextManager` opens.
///
/// ## What this file does and does not exercise
///
/// Same dependency-light, compile-verifying intent as `CodeContextExample`: this target links
/// nothing beyond `FoundationModelsCodeContext` and `FoundationModelsRouter` themselves — no
/// Hugging Face Hub client, no MLX weight loader, no live LSP daemons — so `swift build` stays fast.
/// `swift build` / `swift test` are this package's automated verification; a real, weight-
/// downloading `swift run ManagerExample [parent] [query]` needs the pieces `CodeContextExample`'s
/// header documents (a configured `LiveModelLoader`, installed language servers on `PATH`), and is
/// a local smoke step only, not part of automated verification. Like `CodeContext`,
/// `CodeContextManager` auto-installs a detected language's missing server by default and hands the
/// same policy to every root it opens — pass `autoInstall: LspAutoInstall(isEnabled: false)` to opt
/// out (see the package README's "Language servers" section); this example relies on the default.

let arguments = CommandLine.arguments
let parentPath = arguments.count > 1 ? arguments[1] : FileManager.default.currentDirectoryPath
let parentDirectory = URL(fileURLWithPath: parentPath, isDirectory: true)
let query = arguments.count > 2 ? arguments[2] : "TODO"

// MARK: - Resolve a RoutedEmbedder

// One embedder, shared by every `CodeContext` the manager opens below — mirrors
// `CodeContextExample`'s single-root resolve, just handed to a manager instead of one context.
let profileDefinition = ProfileDefinition(
    name: "manager-example",
    description: "Multi-root CodeContextManager example: resolves an embedder shared by every open root.",
    standard: ["mlx-community/Qwen2.5-3B-Instruct-4bit"],
    flash: ["mlx-community/SmolLM-135M-Instruct-4bit"],
    embedding: ["mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ"]
)

let router = Router(
    recordingsDir: FileManager.default.temporaryDirectory
        .appendingPathComponent("ManagerExample-\(UUID().uuidString)", isDirectory: true)
)

let profile = try await router.resolve(profile: profileDefinition, reporting: ResolutionProgress())
let embedder = RoutedEmbedderAdapter(routedEmbedder: profile.embedding)

// MARK: - Create the manager and discover every repo root under the parent directory

let manager = await CodeContextManager(embedder: embedder)

let discoveredRoots = try RootDiscovery.discoverRoots(under: parentDirectory)
print("Discovered \(discoveredRoots.count) repo root(s) under \(parentDirectory.path):")
for root in discoveredRoots {
    print("  \(root.path)")
}

// MARK: - Open each discovered root explicitly

for root in discoveredRoots {
    _ = try await manager.context(for: root)
}

// `ManagerState.contexts` is `@MainActor`-isolated, mirroring `CodeContextState`'s own
// observable-state contract; a `main.swift` top-level entry point runs on the main actor by
// default, so no `await` is needed to read either `contexts` or a `CodeContextState`'s
// `isReady` here — only truly cross-actor calls elsewhere in this file (e.g. into `manager`
// itself) do.
let openedStates = manager.state.contexts
for root in discoveredRoots {
    let isReady = openedStates[root]?.isReady ?? false
    print("Opened \(root.path) — ready: \(isReady)")
}

// MARK: - Demonstrate lazy routing via context(containing:)

// Every discovered root is already open above, so this resolves via `context(containing:)`'s
// already-open-root fast path rather than its lazy `RootDiscovery.gitRoot` fallback — but it is the
// same call a host would make for an arbitrary file path without knowing in advance which (if any)
// open root, or undiscovered sibling repo, covers it.
if let sampleRoot = discoveredRoots.first, let sampleFile = firstRegularFile(under: sampleRoot) {
    if let containingContext = try await manager.context(containing: sampleFile) {
        // `containingContext.state` is `nonisolated`; `rootDirectory` is `@MainActor`-isolated
        // but this top-level entry point already runs on the main actor (see the comment above),
        // so no `await` is needed here either.
        let containingRoot = containingContext.state.rootDirectory
        print("context(containing:) for \(sampleFile.path) resolved to root: \(containingRoot.path)")
    } else {
        print("context(containing:) for \(sampleFile.path) found no covering root")
    }
} else {
    print("No regular file found under any discovered root — skipping the context(containing:) demonstration")
}

// MARK: - Fan-out search across every open root

// Scores are per-root-normalized (see `CodeContextManager.searchCode`'s doc comment) — never
// compare `rooted.value.hit.score` across two different `rooted.root`s.
let (searchResults, searchFailures) = await manager.searchCode(query: query)
print("searchCode(\"\(query)\") fan-out results:")
for rooted in searchResults {
    print("  [\(rooted.root.path)] \(rooted.value.filePath) score=\(rooted.value.hit.score)")
}
for failure in searchFailures {
    print("  FanOutFailure root=\(failure.root.path): \(failure.message)")
}

// MARK: - Shutdown

await manager.shutdown()
await profile.release()

// MARK: - Helpers

/// The first regular (non-directory, non-symlink) file found under `directory`, skipping hidden
/// entries, or `nil` if the tree contains none.
///
/// Used only to pick a concrete sample path for the `context(containing:)` demonstration above —
/// not part of this package's public API.
/// - Parameter directory: The directory to search beneath.
/// - Returns: The first regular file found, or `nil` if none exists.
func firstRegularFile(under directory: URL) -> URL? {
    guard let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        return nil
    }
    for entry in enumerator {
        guard let url = entry as? URL else { continue }
        if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            return url
        }
    }
    return nil
}

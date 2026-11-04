import ExampleSupport
import Foundation
import FoundationModelsCodeContext
import FoundationModelsExtras

/// A runnable executable demonstrating multi-root `CodeContextManager` lifecycle and fan-out queries.
///
/// The second "way in" to this package (see plan.md's Goal, and the single-root walkthrough in the sibling
/// `CodeContextExample`). Point it at a *parent* directory that holds several repositories. It then uses the
/// workspace-wide surface of `CodeContextManager` from start to end: it finds each repo root below the parent,
/// opens each root explicitly, finds the root that covers one file lazily, sends a search to each open root with
/// root-qualified results, then shuts down all contexts together.
///
/// ## The caller supplies the embedding model
///
/// The caller gives any `PooledEmbedding` value to `CodeContextManager(embedder:selection:)`, and the manager gives
/// that one embedder to each root it opens. This file uses `HashingEmbedder` of the `ExampleSupport` target, which
/// needs no model and no network. The contract of the embedder is described in `CodeContextExample`.
///
/// ## The caller supplies the selection model
///
/// The caller gives a `SelectionFactory` to the manager, and the manager gives it to each root it opens. This
/// file gives the on-device model through `ExampleSelection`, where the contract is described.
///
/// ## What this file does and does not exercise
///
/// The intent is the same as `CodeContextExample`: few dependencies, and compile verification. A real
/// `swift run ManagerExample [parent] [query]` needs language servers on `PATH`. Like `CodeContext`, `CodeContextManager` auto-installs the missing server of a
/// detected language by default and gives the same policy to each root it opens. Give
/// `autoInstall: LspAutoInstall(isEnabled: false)` to opt out (see the "Language servers" section of the package
/// README). This example uses the default.

/// Runs the whole walkthrough. The state lives in this function and not in top-level globals.
///
/// `@MainActor` keeps the main-actor isolation that a top-level entry point has, so the code below reads
/// `manager.state.contexts` and each `CodeContextState` without an `await`.
@MainActor
func runExample() async throws {
    let parentDirectory = ExampleArguments.directoryURL()
    let query = ExampleArguments.query()

    // MARK: - Make the caller-defined embedder

    // One embedder, shared by each `CodeContext` that the manager opens below. It is the same embedder as in
    // `CodeContextExample` (it has a fixed vector length), but this file gives it to a manager, not to one context.
    let embedder = HashingEmbedder.example

    // MARK: - Create the manager and discover every repo root under the parent directory

    // The selection factory of the `ExampleSupport` target.
    let selection = ExampleSelection.onDeviceModel

    let manager = await CodeContextManager(embedder: embedder, selection: selection)

    let discoveredRoots = try RootDiscovery.discoverRoots(under: parentDirectory)
    ExampleOutput.report("Discovered \(discoveredRoots.count) repo root(s) under \(parentDirectory.path):")
    for root in discoveredRoots {
        ExampleOutput.report("  \(root.path)")
    }

    // MARK: - Open each discovered root explicitly

    // `context(for:)` returns before the index of the root is complete. `waitForFirstIndexPass()` waits for the
    // complete first index pass, thus the ready state and the search below read a complete index.
    for root in discoveredRoots {
        let context = try await manager.context(for: root)
        await context.waitForFirstIndexPass()
    }

    // `ManagerState.contexts` is `@MainActor`-isolated, mirroring `CodeContextState`'s own
    // observable-state contract; a `main.swift` top-level entry point runs on the main actor by
    // default, so no `await` is needed to read either `contexts` or a `CodeContextState`'s
    // `isReady` here — only truly cross-actor calls elsewhere in this file (e.g. into `manager`
    // itself) do.
    let openedStates = manager.state.contexts
    for root in discoveredRoots {
        let isReady = openedStates[root]?.isReady ?? false
        ExampleOutput.report("Opened \(root.path) — ready: \(isReady)")
    }

    // MARK: - Demonstrate lazy routing via context(containing:)

    /// Shows `context(containing:)` for one file of the first discovered root.
    ///
    /// Every discovered root is already open, so this resolves via the already-open-root fast path of
    /// `context(containing:)` and not its lazy `RootDiscovery.gitRoot` fallback. It is the same call that a
    /// host makes for an arbitrary file path, without knowing in advance which (if any) open root, or
    /// undiscovered sibling repo, covers it.
    ///
    /// It runs on the main actor like the walkthrough, so `containingContext.state` and its `rootDirectory`
    /// are read without an `await`.
    ///
    /// - Throws: What `firstRegularFile(under:)` and `context(containing:)` throw.
    func demonstrateRouting() async throws {
        guard let sampleRoot = discoveredRoots.first, let sampleFile = try firstRegularFile(under: sampleRoot) else {
            ExampleOutput.report("No regular file found under any discovered root — skipping the context(containing:) demonstration")
            return
        }
        guard let containingContext = try await manager.context(containing: sampleFile) else {
            ExampleOutput.report("context(containing:) for \(sampleFile.path) found no covering root")
            return
        }
        ExampleOutput.report(
            "context(containing:) for \(sampleFile.path) resolved to root: \(containingContext.state.rootDirectory.path)"
        )
    }

    try await demonstrateRouting()

    // MARK: - Fan-out search across every open root

    // Scores are per-root-normalized (see `CodeContextManager.searchCode`'s doc comment) — never
    // compare `rooted.value.hit.score` across two different `rooted.root`s.
    let (searchResults, searchFailures) = try await manager.searchCode(query: query)
    ExampleOutput.report("searchCode(\"\(query)\") fan-out results:")
    for rooted in searchResults {
        ExampleOutput.report("  [\(rooted.root.path)] \(rooted.value.filePath) score=\(rooted.value.hit.score)")
    }
    for failure in searchFailures {
        ExampleOutput.report("  FanOutFailure root=\(failure.root.path): \(failure.message)")
    }

    // MARK: - Shutdown

    // Shut down the manager. This stops each context that it opened. The embedder holds no resources, so it needs no
    // teardown.
    await manager.shutdown()
}

try await runExample()

// MARK: - Helpers

/// The first regular (non-directory, non-symlink) file found under `directory`, skipping hidden
/// entries, or `nil` if the tree contains none.
///
/// Used only to pick a concrete sample path for the `context(containing:)` demonstration above —
/// not part of this package's public API.
/// - Parameter directory: The directory to search beneath.
/// - Returns: The first regular file found, or `nil` if none exists.
/// - Throws: `CocoaError` with `.fileReadUnknown` when the directory cannot be enumerated, and the
///   error of `resourceValues(forKeys:)` when the type of an entry cannot be read. Neither error is
///   hidden as "no regular file".
func firstRegularFile(under directory: URL) throws -> URL? {
    let unreadable = CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: directory.path])
    guard
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
    else {
        throw unreadable
    }
    for entry in enumerator {
        guard let url = entry as? URL else {
            throw unreadable
        }
        if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            return url
        }
    }
    return nil
}

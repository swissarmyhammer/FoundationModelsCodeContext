import Foundation
import FoundationModelsCodeContext

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
/// This package loads no embedding model. The caller gives any `TextEmbedding` value to
/// `CodeContextManager(embedder:)`, and the manager gives that one embedder to each root it opens. The protocol has
/// two members: `dimension`, and `embed(_:)`, which returns one unit-length vector for each text. A production host
/// wraps its real model (for example an MLX embedder) in a small conformance with these two members. This file
/// defines `HashingEmbedder`, a conformance that needs no model and no network (see `CodeContextExample` for more).
///
/// ## What this file does and does not exercise
///
/// The intent is the same as `CodeContextExample`: few dependencies, and compile verification. This target links
/// only `FoundationModelsCodeContext`, and starts no live LSP daemons, so `swift build` stays fast.
/// `swift build` and `swift test` are the automated verification of this package. A real
/// `swift run ManagerExample [parent] [query]` needs language servers on `PATH`, and is a local smoke step only, not
/// part of automated verification. Like `CodeContext`, `CodeContextManager` auto-installs the missing server of a
/// detected language by default and gives the same policy to each root it opens. Give
/// `autoInstall: LspAutoInstall(isEnabled: false)` to opt out (see the "Language servers" section of the package
/// README). This example uses the default.

let arguments = CommandLine.arguments
let parentPath = arguments.count > 1 ? arguments[1] : FileManager.default.currentDirectoryPath
let parentDirectory = URL(fileURLWithPath: parentPath, isDirectory: true)
let query = arguments.count > 2 ? arguments[2] : "TODO"

// MARK: - Make the caller-defined embedder

// One embedder, shared by each `CodeContext` that the manager opens below. It is the same embedder as in
// `CodeContextExample`, but this file gives it to a manager, not to one context.
// The number of hash buckets, thus the length of each embedding vector.
let embeddingDimension = 256
private let embedder = HashingEmbedder(dimension: embeddingDimension)

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

// Shut down the manager. This stops each context that it opened. The embedder holds no resources, so it needs no
// teardown.
await manager.shutdown()

// MARK: - Helpers

/// The first regular (non-directory, non-symlink) file found under `directory`, skipping hidden
/// entries, or `nil` if the tree contains none.
///
/// Used only to pick a concrete sample path for the `context(containing:)` demonstration above —
/// not part of this package's public API.
/// - Parameter directory: The directory to search beneath.
/// - Returns: The first regular file found, or `nil` if none exists.
func firstRegularFile(under directory: URL) -> URL? {
    guard
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
    else {
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

// MARK: - A caller-defined TextEmbedding

// Each example keeps its own copy of `HashingEmbedder`. An executable target
// cannot share source with a different executable target, and a shared target
// for approximately 20 lines costs more than it gives.

/// A `TextEmbedding` that needs no model: it counts hashed tokens.
///
/// This type shows all of the contract that a caller supplies: a `dimension`,
/// and an `embed(_:)` that returns one unit-length vector for each text. A
/// production host puts its real model (for example an MLX embedder) behind
/// the same two members.
///
/// The vectors are the same in each process. The bucket of a token is the
/// 64-bit FNV-1a hash of its UTF-8 bytes. Do not use `Hasher` or `hashValue`
/// here: their seed changes in each process, and the index stays on disk in
/// `<root>/.code-context`, so vectors from two runs would not match.
private struct HashingEmbedder: TextEmbedding {
    /// The 64-bit FNV-1a offset basis, the start value of each hash.
    private static let fnvOffsetBasis: UInt64 = 0xCBF2_9CE4_8422_2325

    /// The 64-bit FNV-1a prime, the multiplier for each byte.
    private static let fnvPrime: UInt64 = 0x0000_0100_0000_01B3

    /// The length of each vector that `embed(_:)` returns.
    let dimension: Int

    /// Makes an embedder that returns vectors of `dimension` length.
    ///
    /// - Parameter dimension: The number of hash buckets. It must be more than 0.
    init(dimension: Int) {
        precondition(dimension > 0, "HashingEmbedder needs a dimension that is more than 0")
        self.dimension = dimension
    }

    /// Returns one L2-normalized vector of bucket counts for each text, in order.
    ///
    /// - Parameter texts: The texts to embed.
    /// - Returns: One `dimension`-length vector for each text, in the order of `texts`.
    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map(vector(for:))
    }

    /// Adds 1 to the bucket of each token in `text`, then scales the counts to unit length.
    ///
    /// - Parameter text: The text to embed.
    /// - Returns: A unit-length vector. When `text` has no tokens, the zero vector, unchanged.
    private func vector(for text: String) -> [Float] {
        let counts = Self.tokens(in: text).reduce(into: [Float](repeating: 0, count: dimension)) { counts, token in
            counts[bucket(for: token)] += 1
        }
        let magnitude = counts.reduce(0) { sum, count in sum + count * count }.squareRoot()
        guard magnitude > 0 else {
            return counts
        }
        return counts.map { count in count / magnitude }
    }

    /// The bucket of `token`: the 64-bit FNV-1a hash of its UTF-8 bytes, modulo `dimension`.
    ///
    /// - Parameter token: One token from `tokens(in:)`.
    /// - Returns: An index in `0..<dimension`.
    private func bucket(for token: String) -> Int {
        let hash = token.utf8.reduce(Self.fnvOffsetBasis) { hash, byte in
            (hash ^ UInt64(byte)) &* Self.fnvPrime
        }
        return Int(hash % UInt64(dimension))
    }

    /// Splits `text` on each character that is not a letter, a digit or `_`, and makes each token lowercase.
    ///
    /// - Parameter text: The text to split.
    /// - Returns: The lowercase tokens, in order. Empty when `text` has no letters, digits or `_`.
    private static func tokens(in text: String) -> [String] {
        text.split { character in !isTokenCharacter(character) }.map { token in token.lowercased() }
    }

    /// Tells if `character` is part of a token: a letter, a digit or `_`.
    ///
    /// - Parameter character: The character to examine.
    /// - Returns: `true` for a letter, a digit or `_`; `false` for each other character.
    private static func isTokenCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isWholeNumber || character == "_"
    }
}

import Foundation
import FoundationModels
import FoundationModelsCodeContext

/// # Runnable demo: standalone, single-root `CodeContext`.
///
/// This is the standalone "way in" to this package (see plan.md's Goal). Point
/// it at one repository root. It then uses the public API from start to end: it
/// makes an embedder, opens a `CodeContext`, starts it, runs two read-only
/// queries, and stops the context.
///
/// ## The caller supplies the embedding model
///
/// This package loads no embedding model. The caller gives any `TextEmbedding`
/// value to `CodeContext(rootDirectory:embedder:)`. The protocol has two
/// members: `dimension`, and `embed(_:)`, which returns one unit-length vector
/// for each text. A production host wraps its real model (for example an MLX
/// embedder) in a small conformance with these two members.
///
/// This file defines `HashingEmbedder`, a conformance that needs no model and
/// no network. It counts hashed tokens, so `searchCode` finds texts that share
/// words, not texts that share meaning. Put a real model behind the same two
/// members to get semantic search.
///
/// ## What this file does and does not exercise
///
/// This target links only `FoundationModelsCodeContext`, so `swift build` stays
/// fast and has few dependencies. The job of this file is to compile-verify and
/// document the public surface of the package. It holds no library logic.
///
///   - Live LSP-backed ops and full indexing need the language servers of the
///     workspace on `PATH`. By default `CodeContext` auto-installs a missing
///     server for a detected language (opt out with
///     `CodeContext(..., autoInstall: LspAutoInstall(isEnabled: false))`; see
///     the "Language servers" section of the package README). Thus this example
///     needs no extra code for this, and gives no `autoInstall:` argument.
///
/// Run with `swift run CodeContextExample [root] [query]` as a local smoke
/// step. It is not part of the automated verification of this package
/// (`swift build` and `swift test` are).

let arguments = CommandLine.arguments
let rootPath = arguments.count > 1 ? arguments[1] : FileManager.default.currentDirectoryPath
let rootDirectory = URL(fileURLWithPath: rootPath, isDirectory: true)
let query = arguments.count > 2 ? arguments[2] : "TODO"

// MARK: - Make the caller-defined embedder

// The number of hash buckets, thus the length of each embedding vector.
let embeddingDimension = 256
private let embedder = HashingEmbedder(dimension: embeddingDimension)

// MARK: - Open, start, query, and stop a CodeContext

let context = try await CodeContext(rootDirectory: rootDirectory, embedder: embedder)
try await context.start()

// `start()` returns before the index is complete. This call waits for the
// complete first index pass, thus each query below reads a complete index.
await context.waitForFirstIndexPass()

// MARK: - The FoundationModels tools of this context

// `CodeContextTools.make(context:)` gives the three tools of one `CodeContext`.
// A host gives them to a `LanguageModelSession`. This example only prints the
// name of each tool and its op strings: it calls no language model.
//
// This demo is a command-line program, and it has no logging system. Each
// `print` below writes the result that the reader asked for, and not a debug
// log. Thus each one carries the swiftlint directive for
// `no_direct_standard_out_logs` on the line immediately above it.
let tools = try CodeContextTools.make(context: context)
for tool in tools {
    let operations = CodeContextTools.operationNames[tool.name] ?? []
    // swiftlint:disable:next no_direct_standard_out_logs
    print("Tool \(tool.name): \(operations.joined(separator: ", "))")
}

// MARK: - Query the context

let projects = try await context.detectProjects()
// swiftlint:disable:next no_direct_standard_out_logs
print("Detected projects: \(projects)")

let indexProgress = await context.indexStatus()
// swiftlint:disable:next no_direct_standard_out_logs
print("Index status: \(indexProgress)")

let symbolMatches = try await context.searchSymbol(query: query)
// swiftlint:disable:next no_direct_standard_out_logs
print("searchSymbol(\"\(query)\") matches: \(symbolMatches)")

let codeHits = try await context.searchCode(query: query)
// swiftlint:disable:next no_direct_standard_out_logs
print("searchCode(\"\(query)\") hits: \(codeHits)")

await context.stop()

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

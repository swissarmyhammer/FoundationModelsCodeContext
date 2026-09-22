import Foundation

@testable import FoundationModelsCodeContext

// Local copies of the small unit-target helpers this suite uses
// (`TestSupport.swift`, `Support/FakeEmbedder.swift` in the root package).
// A SwiftPM test target cannot import another package's test target, so the
// helpers are restated here. Keep each copy in step with its original.

/// Creates a fresh temporary workspace directory for `body`, removed
/// afterwards regardless of outcome.
func withTemporaryWorkspace<T>(_ body: (URL) async throws -> T) async throws -> T {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "FoundationModelsCodeContextIntegrationTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    return try await body(root)
}

/// Writes `content` to `relativePath` under `root`, creating any missing
/// intermediate directories.
func write(_ content: String, to relativePath: String, in root: URL) throws {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try content.write(to: url, atomically: true, encoding: .utf8)
}

/// The default time between two polls of `poll(budget:interval:until:)`,
/// in milliseconds.
let defaultPollIntervalMilliseconds = 250

/// The vector length of the `FakeEmbedder` that `withLiveContext` gives to
/// each live context. The live suites do not test the embeddings, thus a
/// small length is sufficient.
let liveEmbeddingDimension = 8

/// Polls `condition` at `interval` until it returns `true` or `budget` elapses
/// (real wall-clock time: the live suites drive a real subprocess, so no
/// injectable clock applies).
/// - Parameters:
///   - budget: The total time to keep polling before giving up.
///   - interval: How long to sleep between polls. Defaults to `defaultPollIntervalMilliseconds`.
///   - condition: Checked before every sleep; polling stops the moment it returns `true`.
/// - Returns: `true` if `condition` became true within `budget`; `false` otherwise.
@discardableResult
func poll(
    budget: Duration,
    interval: Duration = .milliseconds(defaultPollIntervalMilliseconds),
    until condition: () async throws -> Bool
) async throws -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: budget)
    while true {
        if try await condition() { return true }
        guard clock.now < deadline else { return false }
        try await Task.sleep(for: interval)
    }
}

/// Builds a `CodeContext<ProcessLanguageServerConnection>` for
/// `rootDirectory`, runs `body` against it, and runs `context.stop()` on
/// every exit path (success or throw), so that no real language-server
/// process outlives the test.
/// - Parameters:
///   - rootDirectory: The workspace root to open.
///   - connectionFactory: Spawns the real language-server processes.
///   - body: The test body, given the live-wired facade.
/// - Returns: `body`'s result.
/// - Throws: Rethrows whatever `body` (or the `CodeContext` initializer)
///   throws, after `stop()` has run.
func withLiveContext<T: Sendable>(
    rootDirectory: URL,
    connectionFactory: @escaping ConnectionFactory<ProcessLanguageServerConnection>,
    _ body: (CodeContext<ProcessLanguageServerConnection>) async throws -> T
) async throws -> T {
    let context = try await CodeContext<ProcessLanguageServerConnection>(
        rootDirectory: rootDirectory,
        embedder: FakeEmbedder(dimension: liveEmbeddingDimension),
        connectionFactory: connectionFactory
    )
    do {
        let result = try await body(context)
        await context.stop()
        return result
    } catch {
        await context.stop()
        throw error
    }
}

/// A deterministic, hash-based `TextEmbedding` test double.
///
/// The same input text always produces the same L2-normalized vector, derived
/// from a stable FNV-1a hash of the text (not Swift's per-process `Hasher`,
/// which is seed-randomized), so tests run without a real model or GPU. This
/// copy drops the root unit target's injected-failure hook; this suite does
/// not use it.
struct FakeEmbedder: TextEmbedding {
    let dimension: Int

    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { text in Self.vector(forText: text, dimension: dimension) }
    }

    /// Deterministically derives an L2-normalized vector from `text`'s
    /// stable hash.
    private static func vector(forText text: String, dimension: Int) -> [Float] {
        guard dimension > 0 else {
            return []
        }

        var generator = SplitMix64(seed: fnv1aHash(ofText: text))
        var components = (0..<dimension).map { _ in Float.random(in: -1...1, using: &generator) }
        let magnitude = sqrt(
            components.reduce(Float(0)) { partial, component in partial + component * component })
        if magnitude > 0 {
            for index in components.indices {
                components[index] /= magnitude
            }
        }
        return components
    }

    /// A stable (process-independent) 64-bit FNV-1a hash of `text`'s UTF-8
    /// bytes, used to seed `SplitMix64` so the same text always yields the
    /// same vector.
    private static func fnv1aHash(ofText text: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01B3
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
    }
}

/// A splitmix64 pseudo-random generator, seeded once and then producing a
/// repeatable, seed-determined stream. Backs `FakeEmbedder`'s determinism.
private struct SplitMix64: RandomNumberGenerator {
    /// The increment that each step adds to `state` (the 64-bit golden ratio).
    private static let increment: UInt64 = 0x9E37_79B9_7F4A_7C15

    /// The multiplier of the first mix step of the output.
    private static let firstMixMultiplier: UInt64 = 0xBF58_476D_1CE4_E5B9

    /// The multiplier of the second mix step of the output.
    private static let secondMixMultiplier: UInt64 = 0x94D0_49BB_1331_11EB

    private var state: UInt64

    /// Creates a generator that will deterministically reproduce the same
    /// output stream for the same `seed`.
    ///
    /// - Parameter seed: The generator's starting state.
    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= Self.increment
        var result = state
        result = (result ^ (result >> 30)) &* Self.firstMixMultiplier
        result = (result ^ (result >> 27)) &* Self.secondMixMultiplier
        return result ^ (result >> 31)
    }
}

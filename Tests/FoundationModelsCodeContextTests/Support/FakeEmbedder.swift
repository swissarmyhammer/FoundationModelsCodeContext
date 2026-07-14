import FoundationModelsCodeContext
import Foundation

/// A deterministic, hash-based `TextEmbedding` test double.
///
/// The same input text always produces the same L2-normalized vector,
/// derived from a stable FNV-1a hash of the text (not Swift's per-process
/// `Hasher`, which is seed-randomized), so tests can assert on embedding
/// determinism without a real model or GPU. `dimension` is configurable so
/// tests can exercise the store's dimension-mismatch re-embed path, and an
/// optional injected failure lets tests exercise the worker's
/// graceful-skip path.
struct FakeEmbedder: TextEmbedding {
    let dimension: Int

    /// When set, every call to `embed(_:)` throws this error instead of
    /// producing vectors.
    private let failure: (any Error)?

    /// Creates a fake embedder that deterministically hashes text into
    /// vectors of `dimension` length.
    ///
    /// - Parameters:
    ///   - dimension: The length of every vector this embedder produces.
    ///   - failure: When non-nil, `embed(_:)` throws this error instead of
    ///     computing vectors. Defaults to `nil`.
    init(dimension: Int, failure: (any Error)? = nil) {
        self.dimension = dimension
        self.failure = failure
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        if let failure {
            throw failure
        }
        return texts.map { text in Self.vector(forText: text, dimension: dimension) }
    }

    /// Deterministically derives an L2-normalized vector from `text`'s
    /// stable hash.
    private static func vector(forText text: String, dimension: Int) -> [Float] {
        guard dimension > 0 else {
            return []
        }

        var generator = SplitMix64(seed: fnv1aHash(ofText: text))
        var components = (0..<dimension).map { _ in Float.random(in: -1...1, using: &generator) }
        let magnitude = sqrt(components.reduce(Float(0)) { partial, component in partial + component * component })
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
/// repeatable, seed-determined stream.
///
/// Backs `FakeEmbedder`'s determinism: given the same seed (`FakeEmbedder`
/// derives it from a text's FNV-1a hash), it always yields the same sequence
/// of values, independent of Swift's per-process-randomized `Hasher`.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    /// Creates a generator that will deterministically reproduce the same
    /// output stream for the same `seed`.
    ///
    /// - Parameter seed: The generator's starting state.
    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var result = state
        result = (result ^ (result >> 30)) &* 0xBF58_476D_1CE4_E5B9
        result = (result ^ (result >> 27)) &* 0x94D0_49BB_1331_11EB
        return result ^ (result >> 31)
    }
}

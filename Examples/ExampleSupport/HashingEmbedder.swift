import FoundationModelsExtras

/// A `PooledEmbedding` that needs no model: it counts hashed tokens.
///
/// This type shows all of the contract that a caller supplies: an `embed(texts:)`
/// that returns one unit-length vector for each text. The embedder declares no
/// vector length: CodeContext reads the length from the vectors. A production
/// host puts its real model (for example an MLX embedder) behind the same
/// member.
///
/// The two example programs that need an embedder share this one type, thus they make the same
/// vectors for the same text.
///
/// The test target has its own `FakeEmbedder`. It is a different embedder on purpose: it seeds a
/// random generator with the hash of the whole text, so no two texts are near. This embedder counts
/// hashed tokens, so texts that share words are near. The two do not share code, because they do
/// not share the algorithm.
///
/// The vectors are the same in each process. The bucket of a token is the
/// 64-bit FNV-1a hash of its UTF-8 bytes. Do not use `Hasher` or `hashValue`
/// here: their seed changes in each process, and the index stays on disk in
/// `<root>/.code-context`, so vectors from two runs would not match.
public struct HashingEmbedder: PooledEmbedding {
    /// The 64-bit FNV-1a offset basis, the start value of each hash.
    private static let fnvOffsetBasis: UInt64 = 0xCBF2_9CE4_8422_2325

    /// The 64-bit FNV-1a prime, the multiplier for each byte.
    private static let fnvPrime: UInt64 = 0x0000_0100_0000_01B3

    /// The number of hash buckets that the example programs use, thus the length of each vector.
    private static let exampleVectorLength = 256

    /// The embedder that the example programs use. They share it, thus the vector length is
    /// defined one time and the programs make the same vectors for the same text.
    public static let example = HashingEmbedder(vectorLength: exampleVectorLength)

    /// The length of each vector that `embed(texts:)` returns.
    public let vectorLength: Int

    /// Makes an embedder that returns vectors of `vectorLength` length.
    ///
    /// - Parameter vectorLength: The number of hash buckets. It must be more than 0.
    public init(vectorLength: Int) {
        guard vectorLength > 0 else {
            preconditionFailure("HashingEmbedder needs a vector length that is more than 0")
        }
        self.vectorLength = vectorLength
    }

    /// Returns one L2-normalized vector of bucket counts for each text, in order.
    ///
    /// - Parameter texts: The texts to embed.
    /// - Returns: One `vectorLength`-length vector for each text, in the order of `texts`.
    public func embed(texts: [String]) async throws -> [[Float]] {
        texts.map(vector(for:))
    }

    /// Adds 1 to the bucket of each token in `text`, then scales the counts to unit length.
    ///
    /// - Parameter text: The text to embed.
    /// - Returns: A unit-length vector. When `text` has no tokens, the zero vector, unchanged.
    private func vector(for text: String) -> [Float] {
        let counts = Self.tokens(in: text).reduce(into: [Float](repeating: 0, count: vectorLength)) { counts, token in
            counts[bucket(for: token)] += 1
        }
        let magnitude = counts.reduce(0) { sum, count in sum + count * count }.squareRoot()
        guard magnitude > 0 else {
            return counts
        }
        return counts.map { count in count / magnitude }
    }

    /// The bucket of `token`: the 64-bit FNV-1a hash of its UTF-8 bytes, modulo `vectorLength`.
    ///
    /// - Parameter token: One token from `tokens(in:)`.
    /// - Returns: An index in `0..<vectorLength`.
    private func bucket(for token: String) -> Int {
        let hash = token.utf8.reduce(Self.fnvOffsetBasis) { hash, byte in
            (hash ^ UInt64(byte)) &* Self.fnvPrime
        }
        return Int(hash % UInt64(vectorLength))
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

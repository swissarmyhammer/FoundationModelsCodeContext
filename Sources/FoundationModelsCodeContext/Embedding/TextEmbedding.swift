/// A seam for converting text into fixed-length embedding vectors.
///
/// Abstracts over the concrete embedding backend so callers — chiefly
/// `TreeSitterWorker`'s embedding step — depend on this narrow protocol
/// rather than a specific implementation. `RoutedEmbedderAdapter` wraps
/// FoundationModelsRouter's `RoutedEmbedder` for production use; tests
/// substitute `FakeEmbedder`, a deterministic, GPU-free double.
public protocol TextEmbedding: Sendable {
    /// The length of every embedding vector this embedder produces.
    var dimension: Int { get }

    /// Embeds each input string into a `dimension`-length vector, in order.
    ///
    /// - Parameter texts: The strings to embed.
    /// - Returns: One `dimension`-length vector per input, in the same
    ///   order as `texts`.
    /// - Throws: If the underlying embedding computation fails.
    func embed(_ texts: [String]) async throws -> [[Float]]
}

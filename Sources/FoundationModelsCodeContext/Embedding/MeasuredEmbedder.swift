import Tracing

/// An embedder, and the length of the vectors that it returns.
///
/// `TextEmbedding` declares no vector length: an embedder that loads its model at the first call
/// cannot know the length before that call. This actor gets the length from the first vector that
/// the embedder returns. When the embedder has returned no vector yet,
/// ``vectorLength(tracer:)`` embeds one short probe text. After the first vector, the actor
/// embeds no probe again.
///
/// `CodeContext` keeps one `MeasuredEmbedder` for its life, thus each context embeds the probe
/// one time only. The index pass compares the length with the dimension that the index recorded
/// earlier (see `TreeSitterWorker`).
internal actor MeasuredEmbedder {
    /// The error when the probe gives no vector length.
    internal enum MeasurementError: Error {
        /// The probe call returned no vector, or a vector with no component.
        case probeGaveNoVectorLength
    }

    /// The text that ``vectorLength(tracer:)`` embeds when the embedder has returned no vector
    /// yet.
    ///
    /// The text is short, and it holds no content of the user.
    internal static let probeText = "vector length probe"

    /// The embedder that makes the vectors.
    internal nonisolated let embedder: TextEmbedding

    /// The length of the first vector that `embedder` returned, or `nil` before that vector.
    private var knownVectorLength: Int?

    /// Makes a measured embedder that knows no vector length yet.
    ///
    /// - Parameter embedder: The embedder that makes the vectors.
    internal init(embedder: TextEmbedding) {
        self.embedder = embedder
    }

    /// Gives the length of the vectors of `embedder`.
    ///
    /// The first call embeds the probe text, and keeps the length of the probe vector. Each
    /// subsequent call gives that length and embeds nothing. A call that throws keeps no length,
    /// thus the next call embeds the probe again.
    ///
    /// - Parameter tracer: The tracer of the span of the probe call, or `nil` to read the
    ///   bootstrapped tracer at the time of the call.
    /// - Returns: The length of the first vector that `embedder` returned. It is more than 0.
    /// - Throws: The error of `embedder`, and `MeasurementError.probeGaveNoVectorLength` when the
    ///   probe call returns no vector, or a vector with no component.
    internal func vectorLength(tracer: (any Tracer)?) async throws -> Int {
        if let knownVectorLength {
            return knownVectorLength
        }
        let vectors = try await CodeContextSpans.embed([Self.probeText], with: embedder, tracer: tracer)
        guard let length = vectors.first?.count, length > 0 else {
            throw MeasurementError.probeGaveNoVectorLength
        }
        knownVectorLength = length
        return length
    }
}

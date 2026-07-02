/// The per-signal raw scores that contributed to a `Hit`.
///
/// These are the *raw* per-doc signal values, before RRF fusion and the
/// rank-based normalization that produces `Hit.score`. They are kept on
/// the hit so a consumer can threshold on a raw value directly — but each
/// field has a **different range**, and none of the three is the same
/// `[0,1]` scale as `Hit.score`. A raw-threshold consumer must pick the
/// field it means and use that field's documented range; do not assume a
/// common `[0,1]` scale across them. Ported from the Rust crate's
/// `lib.rs`.
public struct Signals: Sendable, Equatable {
    /// BM25 lexical score. **Unbounded** non-negative (`>= 0.0`): a higher
    /// value means a stronger lexical match, but there is no fixed upper
    /// bound — it grows with term frequency and field weighting. `0.0`
    /// when no query term matches or the corpus is empty.
    public let bm25: Double

    /// Character-trigram (fuzzy) score: for a single field this is
    /// `Trigram.dice(query, field)` in `[0,1]`, but a **field-weighted
    /// aggregate** across several fields (`Σ field.weight *
    /// Trigram.dice(query, field.text)`) ranges over `[0, Σ field
    /// weights]` and so **can exceed 1.0** when fields carry weight > 1 or
    /// several fields match. It is NOT guaranteed to be the `[0,1]` Dice
    /// range.
    public let trigram: Double

    /// Embedding cosine-similarity score, in **`[-1.0, 1.0]`** (not
    /// `[0,1]`): `1.0` is identical direction, `-1.0` opposite, `0.0`
    /// orthogonal or when either the query or the doc lacks an embedding.
    public let cosine: Double

    /// Build the per-signal raw scores that contributed to a `Hit`.
    ///
    /// - Parameters:
    ///   - bm25: the BM25 lexical score.
    ///   - trigram: the character-trigram (fuzzy) score.
    ///   - cosine: the embedding cosine-similarity score.
    public init(bm25: Double, trigram: Double, cosine: Double) {
        self.bm25 = bm25
        self.trigram = trigram
        self.cosine = cosine
    }
}

/// A scored search result for a single document.
///
/// Ported from the Rust crate's `lib.rs`.
public struct Hit: Sendable, Equatable {
    /// The id of the matched document.
    public let id: String

    /// The combined, weighted score, normalized to `[0, 1]` by
    /// `RRF.normalize(_:weights:k:)`.
    public let score: Double

    /// The individual signal scores that produced `score`.
    public let signals: Signals

    /// Build a scored search result for a single document.
    ///
    /// - Parameters:
    ///   - id: the id of the matched document.
    ///   - score: the combined, weighted, `[0, 1]`-normalized score.
    ///   - signals: the individual signal scores that produced `score`.
    public init(id: String, score: Double, signals: Signals) {
        self.id = id
        self.score = score
        self.signals = signals
    }
}

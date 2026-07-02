/// Reciprocal Rank Fusion: combine several ranked lists of document indices
/// into one fused ranking (see plan.md "Search"). Ported from the Rust
/// crate's `score.rs`.
///
/// `RRF(d) = Σ_r w_r / (k + rank_r(d))` summed over the lists `r` in which
/// document `d` appears. **Ranks are 0-based**: rank `0` is the best
/// (first) position in a list. A document absent from a list contributes
/// nothing for that list — graceful degradation, no zero-fill — which is
/// what lets a chunk missing a signal (e.g. not yet embedded) still be
/// ranked by the signals it does have.
public enum RRF {
    /// The default Reciprocal Rank Fusion constant, from the original RRF
    /// paper. Larger values flatten the contribution difference between
    /// adjacent ranks.
    public static let k: Double = 60.0

    /// Fuse several ranked lists of document indices via Reciprocal Rank
    /// Fusion.
    ///
    /// A document ranked in more than one list accumulates a contribution
    /// from each, so a doc ranked in two signals outranks a doc ranked
    /// equally well in only one.
    ///
    /// - Parameters:
    ///   - rankedLists: one array of document indices per signal, ordered
    ///     best (rank 0) to worst.
    ///   - weights: the weight `w_r` for each list, positionally aligned
    ///     with `rankedLists`.
    ///   - k: the RRF constant (defaults to `RRF.k`).
    /// - Precondition: `rankedLists.count == weights.count`.
    /// - Returns: a map from document index to its fused score. Only
    ///   documents appearing in at least one list are present.
    public static func fuse(rankedLists: [[Int]], weights: [Double], k: Double = RRF.k) -> [Int: Double] {
        precondition(
            rankedLists.count == weights.count,
            "RRF.fuse: rankedLists and weights must be the same length"
        )
        var fused: [Int: Double] = [:]
        for (list, weight) in zip(rankedLists, weights) {
            for (rank, document) in list.enumerated() {
                fused[document, default: 0.0] += weight / (k + Double(rank))
            }
        }
        return fused
    }

    /// Normalize a fused-score map to `[0, 1]`.
    ///
    /// Divides every value by the maximum score a document could achieve —
    /// ranking first (rank `0`) in every one of `weights`' signals. This is
    /// the same normalization the top-level search applies to turn a raw
    /// `fuse(...)` result into a `Hit.score`.
    ///
    /// - Parameters:
    ///   - fused: doc index -> raw fused score, as returned by `fuse`.
    ///   - weights: the per-signal weights used to produce `fused`.
    ///   - k: the RRF constant used to produce `fused` (defaults to
    ///     `RRF.k`).
    /// - Returns: `fused` with every value divided by the maximum
    ///   achievable score; every value is `0.0` when that maximum is `0.0`
    ///   (e.g. all weights are zero).
    public static func normalize(_ fused: [Int: Double], weights: [Double], k: Double = RRF.k) -> [Int: Double] {
        let maximum = weights.reduce(0.0) { $0 + $1 / k }
        guard maximum != 0.0 else { return fused.mapValues { _ in 0.0 } }
        return fused.mapValues { $0 / maximum }
    }
}

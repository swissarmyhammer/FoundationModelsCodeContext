import RankKit

// FoundationModelsCodeContext's home-grown search/ranking primitives (BM25, RRF, Trigram,
// Tokenizer, Hit/Signals — all ports of the Rust `swissarmyhammer-search`
// crate) now live in the sibling RankKit package, which extracted them
// verbatim. `Hit` and `Signals` were public API here before the extraction,
// so they are re-exported as typealiases to keep
// `CodeContext.searchCode(query:topK:weights:)` consumers source-compatible;
// everything else is reached through `import RankKit` directly.

/// A scored search result for a single document — see `RankKit.Hit`.
///
/// Re-exported so library consumers that used `FoundationModelsCodeContext.Hit` before
/// the ranking primitives moved to RankKit keep compiling unchanged.
public typealias Hit = RankKit.Hit

/// The per-signal raw scores that contributed to a `Hit` — see
/// `RankKit.Signals`.
///
/// Re-exported so library consumers that used `FoundationModelsCodeContext.Signals`
/// before the ranking primitives moved to RankKit keep compiling unchanged.
public typealias Signals = RankKit.Signals

import Foundation
import Testing

@testable import CodeContextKit

/// Golden-ordering and formula tests for the BM25, trigram-Dice, and RRF
/// primitives, ported from `crates/swissarmyhammer-search`'s
/// `tokenize.rs`/`score.rs` test suites (see plan.md "Search").
struct RankerTests {
    // MARK: - Tokenizer

    @Test
    func camelCaseSplitsLowercased() {
        #expect(Tokenizer.tokenize("getUserById") == ["get", "user", "by", "id"])
    }

    @Test
    func snakeCaseSplits() {
        #expect(Tokenizer.tokenize("get_user_by_id") == ["get", "user", "by", "id"])
    }

    @Test
    func acronymRunSplits() {
        #expect(Tokenizer.tokenize("getHTTPResponse") == ["get", "http", "response"])
    }

    @Test
    func digitBoundaryExcludedKeepsSha256Whole() {
        #expect(Tokenizer.tokenize("sha256_hash") == ["sha256", "hash"])
    }

    @Test
    func digitBoundaryExcludedKeepsUtf8Whole() {
        #expect(Tokenizer.tokenize("utf8") == ["utf8"])
    }

    @Test
    func punctuationStrippedNoEmptyStrings() {
        #expect(Tokenizer.tokenize("fn parse_config() -> Result") == ["fn", "parse", "config", "result"])
    }

    @Test
    func termFrequencyPreservedDuplicatesNotDeduped() {
        #expect(Tokenizer.tokenize("foo foo bar") == ["foo", "foo", "bar"])
    }

    @Test
    func emptyInputYieldsNoTokens() {
        #expect(Tokenizer.tokenize("").isEmpty)
    }

    @Test
    func periodBetweenLettersGluesRunLikeUnicodeWordsMidNumLet() {
        // Mirrors Rust's `unicode_words()`, which treats `.` as `MidNumLet`
        // and glues a letter-flanked period into one word rather than
        // breaking on it; `.` is not an identifier boundary, so the glued
        // run stays a single token.
        #expect(Tokenizer.tokenize("foo.bar") == ["foo.bar"])
    }

    @Test
    func apostropheBetweenLettersGluesContraction() {
        #expect(Tokenizer.tokenize("don't") == ["don't"])
    }

    @Test
    func leadingAndTrailingPeriodsAreStrippedNotGlued() {
        // A `.`/`'` only glues when flanked by a letter/digit on *both*
        // sides; at the start/end of the text there is no flanking
        // character, so it behaves like ordinary punctuation.
        #expect(Tokenizer.tokenize(".foo.") == ["foo"])
    }

    @Test
    func charTrigramsSlidingWindowsLowercased() {
        #expect(Tokenizer.charTrigrams("get_user") == ["get", "et_", "t_u", "_us", "use", "ser"])
    }

    @Test
    func charTrigramsLowercasesInput() {
        #expect(Tokenizer.charTrigrams("ABCD") == ["abc", "bcd"])
    }

    @Test
    func charTrigramsShortStringIsEmpty() {
        #expect(Tokenizer.charTrigrams("").isEmpty)
        #expect(Tokenizer.charTrigrams("a").isEmpty)
        #expect(Tokenizer.charTrigrams("ab").isEmpty)
        #expect(Tokenizer.charTrigrams("abc") == ["abc"])
    }

    // MARK: - Trigram Dice

    @Test
    func trigramDiceIdenticalIsOne() {
        #expect(Trigram.dice("get_user", "get_user") == 1.0)
    }

    @Test
    func trigramDiceTypoRescueAboveThreshold() {
        #expect(Trigram.dice("getUsr", "get_user") > 0.4)
    }

    @Test
    func trigramDiceDisjointIsZero() {
        #expect(Trigram.dice("abcdef", "uvwxyz") == 0.0)
    }

    @Test
    func trigramDiceNoTrigramsIsZero() {
        #expect(Trigram.dice("ab", "get_user") == 0.0)
        #expect(Trigram.dice("get_user", "") == 0.0)
    }

    // MARK: - BM25

    /// Reference Okapi BM25 term contribution, for hand-comparison against
    /// `BM25Corpus.score`.
    private func referenceTerm(
        n: Double, df: Double, tf: Double, documentLength: Double, averageDocumentLength: Double
    ) -> Double {
        let idf = log(1.0 + (n - df + 0.5) / (df + 0.5))
        let lengthNorm = BM25.k1 * (1.0 - BM25.b + BM25.b * documentLength / averageDocumentLength)
        return idf * tf * (BM25.k1 + 1.0) / (tf + lengthNorm)
    }

    @Test
    func bm25SingleTermMatchesHandComputed() {
        // 3-doc corpus, query "foo". doc lens 4, 2, 6 -> avgdl = 4.0.
        // "foo" appears in docs 0 and 1 -> df = 2, N = 3.
        let query = ["foo"]
        let corpus = BM25Corpus(
            queryTokens: query,
            documents: [
                (4, Set(["foo"])),
                (2, Set(["foo"])),
                (6, Set()),
            ]
        )
        let got = corpus.score(weightedTermFrequency: ["foo": 1.0], documentLength: 4, queryTokens: query)
        let want = referenceTerm(n: 3.0, df: 2.0, tf: 1.0, documentLength: 4.0, averageDocumentLength: 4.0)
        #expect(abs(got - want) < 1e-4)
    }

    @Test
    func bm25TwoTermMatchesHandComputed() {
        // Query "foo bar". df(foo)=2, df(bar)=1, N=3, avgdl=4.0.
        let query = ["foo", "bar"]
        let corpus = BM25Corpus(
            queryTokens: query,
            documents: [
                (4, Set(["foo", "bar"])),
                (2, Set(["foo"])),
                (6, Set()),
            ]
        )
        let got = corpus.score(
            weightedTermFrequency: ["foo": 1.0, "bar": 1.0], documentLength: 4, queryTokens: query
        )
        let want =
            referenceTerm(n: 3.0, df: 2.0, tf: 1.0, documentLength: 4.0, averageDocumentLength: 4.0)
            + referenceTerm(n: 3.0, df: 1.0, tf: 1.0, documentLength: 4.0, averageDocumentLength: 4.0)
        #expect(abs(got - want) < 1e-4)
    }

    @Test
    func bm25RarerTermScoresHigher() {
        // Same tf/doc_len, but "rare" has df 1 vs "common" df 3.
        let query = ["rare", "common"]
        let corpus = BM25Corpus(
            queryTokens: query,
            documents: [
                (4, Set(["rare", "common"])),
                (4, Set(["common"])),
                (4, Set(["common"])),
            ]
        )
        let rare = corpus.score(weightedTermFrequency: ["rare": 1.0], documentLength: 4, queryTokens: ["rare"])
        let common = corpus.score(
            weightedTermFrequency: ["common": 1.0], documentLength: 4, queryTokens: ["common"]
        )
        #expect(rare > common)
    }

    @Test
    func bm25HighWeightFieldScoresHigher() {
        // Identical corpus and doc_len; only the weighted tf differs.
        let query = ["foo"]
        let corpus = BM25Corpus(queryTokens: query, documents: [(4, Set(["foo"])), (4, Set(["foo"]))])
        let high = corpus.score(weightedTermFrequency: ["foo": 3.0], documentLength: 4, queryTokens: query)
        let low = corpus.score(weightedTermFrequency: ["foo": 1.0], documentLength: 4, queryTokens: query)
        #expect(high > low)
    }

    @Test
    func bm25SymbolPathMatchOutranksBodyOnlyMatchForSameTerm() {
        // Same corpus, same doc length; one doc's weighted tf comes from a
        // symbol_path occurrence (x5), the other's from a body-only
        // occurrence (x1) of the same term. This is the acceptance
        // criterion for BM25.swift's two-field weighting.
        let query = ["parse"]
        let corpus = BM25Corpus(queryTokens: query, documents: [(4, Set(["parse"])), (4, Set(["parse"]))])
        let symbolPathMatch = corpus.score(
            weightedTermFrequency: ["parse": BM25.symbolPathFieldWeight],
            documentLength: 4,
            queryTokens: query
        )
        let bodyOnlyMatch = corpus.score(
            weightedTermFrequency: ["parse": BM25.bodyFieldWeight],
            documentLength: 4,
            queryTokens: query
        )
        #expect(symbolPathMatch > bodyOnlyMatch)
    }

    @Test
    func bm25RepeatedQueryTermNotDoubleCounted() {
        let query = ["foo", "foo"]
        let corpus = BM25Corpus(queryTokens: query, documents: [(4, Set(["foo"])), (4, Set())])
        let got = corpus.score(weightedTermFrequency: ["foo": 1.0], documentLength: 4, queryTokens: query)
        let want = referenceTerm(n: 2.0, df: 1.0, tf: 1.0, documentLength: 4.0, averageDocumentLength: 4.0)
        #expect(abs(got - want) < 1e-4)
    }

    @Test
    func bm25EmptyCorpusIsZero() {
        let query = ["foo"]
        let corpus = BM25Corpus(queryTokens: query, documents: [(Int, Set<String>)]())
        #expect(corpus.score(weightedTermFrequency: ["foo": 1.0], documentLength: 0, queryTokens: query) == 0.0)
    }

    // MARK: - RRF

    @Test
    func rrfTwoListsBeatOne() {
        // doc 0 is rank-0 in lists 0 and 1; doc 1 is rank-0 only in list 2.
        let fused = RRF.fuse(
            rankedLists: [[0, 1], [0, 2], [1, 0]],
            weights: [1.0, 1.0, 1.0]
        )
        #expect(fused[0]! > fused[1]!)
    }

    @Test
    func rrfMatchesHandComputed() {
        let fused = RRF.fuse(rankedLists: [[0, 1], [1, 0]], weights: [1.0, 1.0], k: 60.0)
        // doc0: 1/60 + 1/61 ; doc1: 1/61 + 1/60 -> equal.
        let want = 1.0 / 60.0 + 1.0 / 61.0
        #expect(abs(fused[0]! - want) < 1e-6)
        #expect(abs(fused[1]! - want) < 1e-6)
    }

    @Test
    func rrfMissingDocContributesNothing() {
        let fused = RRF.fuse(rankedLists: [[0], [1]], weights: [1.0, 1.0], k: 60.0)
        #expect(abs(fused[0]! - 1.0 / 60.0) < 1e-6)
        #expect(abs(fused[1]! - 1.0 / 60.0) < 1e-6)
    }

    @Test
    func rrfWeightEffect() {
        let fused = RRF.fuse(rankedLists: [[0], [1]], weights: [2.0, 1.0], k: 60.0)
        #expect(fused[0]! > fused[1]!)
        #expect(abs(fused[0]! - 2.0 / 60.0) < 1e-6)
    }

    @Test
    func rrfNormalizeRankZeroEverywhereIsOne() {
        // "best" (doc 0) is rank-0 in both signals -> the maximum
        // achievable score, so normalization lands exactly at 1.0.
        let fused = RRF.fuse(rankedLists: [[0, 1], [0, 1]], weights: [1.0, 1.0])
        let normalized = RRF.normalize(fused, weights: [1.0, 1.0])
        #expect(abs(normalized[0]! - 1.0) < 1e-6)
        #expect(normalized[0]! > normalized[1]!)
    }

    @Test
    func rrfNormalizeWithNoWeightsIsZeroEverywhere() {
        let fused = RRF.fuse(rankedLists: [[0]], weights: [0.0])
        let normalized = RRF.normalize(fused, weights: [0.0])
        #expect(normalized[0] == 0.0)
    }

    // MARK: - Golden ordering: fused BM25 + trigram ranking

    @Test
    func fusedBm25AndTrigramSignalsRankSymbolPathMatchFirst() {
        // Two documents share the query term "parse" in their body, but
        // only "strong" also has it in a symbol_path field (weight x5) and
        // an exact-identifier trigram match; RRF fusion of the BM25 and
        // trigram rankings puts "strong" first, mirroring the Rust crate's
        // `strong_high_weight_lexical_beats_mediocre` golden case.
        let query = ["parse"]
        let corpus = BM25Corpus(queryTokens: query, documents: [(6, Set(["parse"])), (6, Set(["parse"]))])
        let strongBm25 = corpus.score(
            weightedTermFrequency: ["parse": BM25.symbolPathFieldWeight + BM25.bodyFieldWeight],
            documentLength: 6,
            queryTokens: query
        )
        let mediocreBm25 = corpus.score(
            weightedTermFrequency: ["parse": BM25.bodyFieldWeight],
            documentLength: 6,
            queryTokens: query
        )
        let strongTrigram = Trigram.dice("parse", "parse")
        let mediocreTrigram = Trigram.dice("parse", "the config value is read lazily later on")

        // Assert the per-signal claim directly, so this golden-ordering
        // test is self-evidently testing what it claims — not just
        // inferring it from the ranking arrays built below.
        #expect(strongBm25 > mediocreBm25)
        #expect(strongTrigram > mediocreTrigram)

        let bm25Ranking = [0, 1]
        let trigramRanking = [0, 1]

        let fused = RRF.fuse(rankedLists: [bm25Ranking, trigramRanking], weights: [1.0, 1.0])
        #expect(fused[0]! > fused[1]!)
    }

    // MARK: - Hit / Signals

    @Test
    func signalsAndHitStoreConstructorArguments() {
        let signals = Signals(bm25: 1.5, trigram: 0.75, cosine: 0.9)
        #expect(signals.bm25 == 1.5)
        #expect(signals.trigram == 0.75)
        #expect(signals.cosine == 0.9)

        let hit = Hit(id: "chunk-1", score: 0.42, signals: signals)
        #expect(hit.id == "chunk-1")
        #expect(hit.score == 0.42)
        #expect(hit.signals == signals)
    }
}

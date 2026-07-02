/// Character-trigram Sørensen-Dice similarity — the typo/partial-identifier
/// fuzzy-match signal (see plan.md "Search"). Ported from the Rust crate's
/// `score.rs`.
public enum Trigram {
    /// Sørensen-Dice coefficient over the *sets* of character trigrams of
    /// two strings.
    ///
    /// Computes `2·|A∩B| / (|A|+|B|)` where `A` and `B` are the
    /// deduplicated canonical trigram sets (`canonicalTrigramSet(_:)`) of
    /// each input.
    ///
    /// Each input is canonicalized through `Tokenizer.tokenize(_:)` and
    /// re-joined with single spaces before trigramming. This normalizes
    /// identifier delimiters so that `camelCase`, `snake_case`, and
    /// `kebab-case` spellings of the same words share trigrams — which is
    /// what makes the signal a *typo / style* rescue rather than a literal
    /// substring match. Without it, `"getUsr"` and `"get_user"` would share
    /// only the `get` trigram (Dice 0.2); after canonicalization they
    /// become `"get usr"` vs `"get user"` and overlap strongly (Dice >
    /// 0.7).
    ///
    /// - Parameters:
    ///   - query: the first string to compare.
    ///   - target: the second string to compare. Order is irrelevant.
    /// - Returns: a similarity in `[0.0, 1.0]`; `1.0` for equal canonical
    ///   trigram sets, `0.0` when either side yields no trigrams (too short
    ///   after canonicalization) or the sets are disjoint.
    public static func dice(_ query: String, _ target: String) -> Double {
        let queryTrigrams = canonicalTrigramSet(query)
        let targetTrigrams = canonicalTrigramSet(target)
        guard !queryTrigrams.isEmpty, !targetTrigrams.isEmpty else { return 0.0 }
        let intersectionCount = Double(queryTrigrams.intersection(targetTrigrams).count)
        return 2.0 * intersectionCount / Double(queryTrigrams.count + targetTrigrams.count)
    }

    /// Canonicalize `text` (tokenize, re-join with spaces) and return its
    /// trigram set.
    ///
    /// This is the single authority for "does this string have trigrams?":
    /// callers detecting whether the trigram signal carries data for a
    /// query, and `dice(_:_:)` itself, both go through this canonical form
    /// — so a string with an empty canonical trigram set can never
    /// contribute a non-zero trigram score.
    ///
    /// - Parameter text: the string to canonicalize and trigram.
    /// - Returns: the deduplicated set of length-3 character windows of the
    ///   canonical form.
    public static func canonicalTrigramSet(_ text: String) -> Set<String> {
        let canonical = Tokenizer.tokenize(text).joined(separator: " ")
        return Set(Tokenizer.charTrigrams(canonical))
    }
}

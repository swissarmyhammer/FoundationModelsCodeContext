/// Code-aware tokenization: identifier splitting and character trigrams.
///
/// Pure functions with no DB or embedding access, feeding the BM25 and
/// trigram-Dice scoring stages (see plan.md "Search"). There is
/// deliberately no stemming: fuzziness is carried by the character-trigram
/// signal, not by stemming. Ported from the Rust crate's `tokenize.rs`.
public enum Tokenizer {
    /// Tokenize `text` into lowercased, code-aware terms.
    ///
    /// `text` is first split into maximal runs of word-forming characters
    /// (letters, digits, `_`, `-`), and any run with no letter or digit
    /// (bare punctuation, e.g. a lone `-`) is discarded. A `.` or `'` that
    /// sits between two letters/digits (`foo.bar`, `don't`) glues its run
    /// together rather than splitting it, mirroring the `MidNumLet`
    /// word-break class the Rust port's `unicode_words()` relies on — a
    /// `.`/`'` elsewhere (leading, trailing, or beside other punctuation)
    /// still ends the run. Each remaining run is then split on identifier
    /// boundaries: `_`/`-` delimiters, `camelCase`/`PascalCase` transitions
    /// (`getUser` -> `get`, `User`), and acronym runs (`HTTPResponse` ->
    /// `HTTP`, `Response`) — `.`/`'` are not identifier boundaries, so a
    /// glued run like `foo.bar` stays one token. Digit boundaries are
    /// deliberately excluded so identifiers like `sha256` and `utf8` stay
    /// whole. Every resulting segment is lowercased.
    ///
    /// Duplicates are preserved (BM25 needs term frequency, so terms are
    /// not deduplicated) and empty segments are dropped.
    ///
    /// - Parameter text: the text to tokenize.
    /// - Returns: the lowercased, code-aware tokens, in order.
    public static func tokenize(_ text: String) -> [String] {
        let characters = Array(text)
        var tokens: [String] = []
        var run: [Character] = []
        run.reserveCapacity(16)

        func flushRun() {
            defer { run.removeAll(keepingCapacity: true) }
            guard run.contains(where: { $0.isLetter || $0.isNumber }) else { return }
            tokens.append(contentsOf: splitRun(run))
        }

        for index in characters.indices {
            let character = characters[index]
            if isWordCharacter(character) || isGluedSeparator(character, in: characters, at: index) {
                run.append(character)
            } else {
                flushRun()
            }
        }
        flushRun()
        return tokens
    }

    /// Return the sliding length-3 character windows of `text`, lowercased.
    ///
    /// Windows are taken over `Character` (extended grapheme clusters), so
    /// the result is Unicode-safe. Strings with fewer than 3 characters
    /// return an empty array.
    ///
    /// - Parameter text: the string to window.
    /// - Returns: each 3-character window of the lowercased `text`, in order.
    public static func charTrigrams(_ text: String) -> [String] {
        let characters = Array(text.lowercased())
        guard characters.count >= 3 else { return [] }
        return (0...(characters.count - 3)).map { start in
            String(characters[start...(start + 2)])
        }
    }

    /// Whether `character` belongs to a word run: a letter, digit,
    /// underscore, or hyphen.
    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "-"
    }

    /// Whether `characters[at]` is a `.`/`'` flanked by a letter or digit on
    /// both sides, so it glues rather than breaks the surrounding run.
    ///
    /// This mirrors the Unicode `MidNumLet` word-break class (`.` and `'`)
    /// that Rust's `unicode_words()` uses: `foo.bar` and `don't` are single
    /// words, but a leading/trailing `.`/`'`, or one next to other
    /// punctuation, still ends the run.
    private static func isGluedSeparator(_ character: Character, in characters: [Character], at index: Int) -> Bool {
        guard character == "." || character == "'" else { return false }
        guard index > characters.startIndex, index + 1 < characters.endIndex else { return false }
        let previous = characters[index - 1]
        let next = characters[index + 1]
        return (previous.isLetter || previous.isNumber) && (next.isLetter || next.isNumber)
    }

    /// Split one maximal word-forming run into identifier sub-words.
    ///
    /// First splits on the `_`/`-` delimiters, then splits each delimited
    /// piece on `camelCase`/`PascalCase`/acronym boundaries.
    private static func splitRun(_ run: [Character]) -> [String] {
        run.split(whereSeparator: { $0 == "_" || $0 == "-" }).flatMap(splitCaseBoundaries)
    }

    /// Split a delimiter-free segment on `camelCase`/`PascalCase`/acronym
    /// boundaries, lowercasing each resulting piece.
    ///
    /// A boundary falls between a lowercase and following uppercase letter
    /// (`get|User`), and between the last two letters of an uppercase run
    /// that is itself followed by a lowercase letter (`HTTP|Response`).
    /// Digits never introduce a boundary, so `sha256` and `utf8` stay
    /// whole.
    private static func splitCaseBoundaries(_ segment: ArraySlice<Character>) -> [String] {
        let characters = Array(segment)
        guard !characters.isEmpty else { return [] }

        var boundaries: [Int] = []
        for index in 1..<characters.count {
            let previous = characters[index - 1]
            let current = characters[index]
            let isLowerToUpper = previous.isLowercase && current.isUppercase
            let isAcronymEnd =
                previous.isUppercase && current.isUppercase
                && index + 1 < characters.count && characters[index + 1].isLowercase
            if isLowerToUpper || isAcronymEnd {
                boundaries.append(index)
            }
        }

        var segments: [String] = []
        var start = 0
        for boundary in boundaries {
            segments.append(String(characters[start..<boundary]))
            start = boundary
        }
        segments.append(String(characters[start...]))
        return segments.map { $0.lowercased() }
    }
}

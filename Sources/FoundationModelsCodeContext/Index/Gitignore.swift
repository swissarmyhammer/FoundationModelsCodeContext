import Foundation

/// A single compiled ignore pattern from one line of a `.gitignore`, an
/// `.ignore` or a `.git/info/exclude` file.
///
/// The pattern does not know its directory. `PathFilter` keeps the patterns of
/// each directory, and it gives each pattern the path of the candidate
/// relative to that directory.
///
/// Hand-rolled rather than pulled from a package dependency: `Package.swift`
/// had no gitignore-parsing library when `Walker` was written, so this
/// implements just enough of the syntax to be correct against
/// `ReconcilerTests`'s fixtures — glob wildcards (`*`, `**`, `?`),
/// character classes (`[abc]`, `[!abc]`), `!` negation, directory-only
/// trailing `/`, and anchored (contains a non-trailing `/`) vs.
/// basename-anywhere matching. It does not attempt full parity with every
/// corner case of `git`'s own matcher (e.g. escaped metacharacters beyond
/// `\!`/`\#`, `\`-escaped trailing spaces are trimmed but not otherwise
/// unescaped).
struct GitignorePattern: Sendable {
    /// `true` for a `!`-prefixed pattern that re-includes a path an
    /// earlier pattern excluded.
    let isNegated: Bool

    /// `true` for a pattern ending in `/`, which matches directories only.
    let isDirectoryOnly: Bool

    /// `true` when the pattern contains a `/` other than a single trailing
    /// one, meaning it only matches relative to its base directory rather than
    /// at any depth beneath it.
    let isAnchored: Bool

    /// The compiled glob-to-regex matcher for the pattern's body, with any
    /// `!` prefix, directory-only trailing `/`, and anchoring leading `/`
    /// already stripped.
    let regex: NSRegularExpression

    /// Parses each line of the text of a rule file into a pattern.
    ///
    /// - Parameter contents: The text of a `.gitignore`, an `.ignore` or a
    ///   `.git/info/exclude` file.
    /// - Returns: The patterns, in the order of the lines. A blank line, a
    ///   comment and a line that this matcher cannot compile give no pattern.
    static func patterns(in contents: String) -> [GitignorePattern] {
        contents.split(separator: "\n", omittingEmptySubsequences: false).compactMap { rawLine in
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : String(rawLine)
            return GitignorePattern(line: line)
        }
    }

    /// Parses one `.gitignore` line into a pattern, or returns `nil` for a
    /// blank line, a comment, or a pattern this matcher can't compile.
    ///
    /// - Parameter line: One raw line from a rule file, without its trailing
    ///   newline.
    init?(line: String) {
        var pattern = line
        while pattern.hasSuffix(" "), !pattern.hasSuffix("\\ ") {
            pattern.removeLast()
        }
        if pattern.isEmpty || pattern.hasPrefix("#") {
            return nil
        }

        var negated = false
        if pattern.hasPrefix("!") {
            negated = true
            pattern.removeFirst()
        } else if pattern.hasPrefix("\\!") || pattern.hasPrefix("\\#") {
            pattern.removeFirst()
        }
        if pattern.isEmpty {
            return nil
        }

        var directoryOnly = false
        if pattern.hasSuffix("/") {
            directoryOnly = true
            pattern.removeLast()
        }
        if pattern.isEmpty {
            return nil
        }

        let anchored = pattern.contains("/")
        if pattern.hasPrefix("/") {
            pattern.removeFirst()
        }
        if pattern.isEmpty {
            return nil
        }

        guard let regex = Self.compile(glob: pattern) else {
            return nil
        }

        isNegated = negated
        isDirectoryOnly = directoryOnly
        isAnchored = anchored
        self.regex = regex
    }

    /// Whether this pattern matches an entry at `relativePath` (relative to
    /// the base directory of the pattern, using `/` separators).
    ///
    /// - Parameters:
    ///   - relativePath: The candidate entry's path relative to the base
    ///     directory of the pattern.
    ///   - isDirectory: Whether the candidate entry is a directory.
    func matches(relativePath: String, isDirectory: Bool) -> Bool {
        if isDirectoryOnly, !isDirectory {
            return false
        }
        // Anchored patterns match the full path from the base directory;
        // unanchored patterns match the basename at any depth beneath it.
        let candidate = isAnchored ? relativePath : (relativePath as NSString).lastPathComponent
        let range = NSRange(candidate.startIndex..., in: candidate)
        return regex.firstMatch(in: candidate, range: range) != nil
    }

    /// Translates a gitignore glob body into an anchored regular
    /// expression: `*` matches within one path segment, `**` (optionally
    /// followed by `/`) matches across segments, `?` matches one
    /// non-separator character, and `[...]`/`[!...]` character classes pass
    /// through with `!` remapped to regex's `^` negation.
    private static func compile(glob: String) -> NSRegularExpression? {
        var result = "^"
        var index = glob.startIndex
        while index < glob.endIndex {
            let character = glob[index]
            switch character {
            case "*":
                let afterFirstStar = glob.index(after: index)
                guard afterFirstStar < glob.endIndex, glob[afterFirstStar] == "*" else {
                    result += "[^/]*"
                    index = afterFirstStar
                    continue
                }
                let afterSecondStar = glob.index(after: afterFirstStar)
                if afterSecondStar < glob.endIndex, glob[afterSecondStar] == "/" {
                    result += "(.*/)?"
                    index = glob.index(after: afterSecondStar)
                } else {
                    result += ".*"
                    index = afterSecondStar
                }
            case "?":
                result += "[^/]"
                index = glob.index(after: index)
            case "[":
                var classEnd = glob.index(after: index)
                var classContent = "["
                if classEnd < glob.endIndex, glob[classEnd] == "!" {
                    classContent += "^"
                    classEnd = glob.index(after: classEnd)
                }
                while classEnd < glob.endIndex, glob[classEnd] != "]" {
                    classContent.append(glob[classEnd])
                    classEnd = glob.index(after: classEnd)
                }
                classContent += "]"
                result += classContent
                index = classEnd < glob.endIndex ? glob.index(after: classEnd) : classEnd
            default:
                result += NSRegularExpression.escapedPattern(for: String(character))
                index = glob.index(after: index)
            }
        }
        result += "$"
        return try? NSRegularExpression(pattern: result)
    }
}

import Foundation

/// A single compiled `.gitignore` pattern, scoped to the directory whose
/// `.gitignore` file defined it.
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
struct GitignorePattern {
    /// `true` for a `!`-prefixed pattern that re-includes a path an
    /// earlier pattern excluded.
    let isNegated: Bool

    /// `true` for a pattern ending in `/`, which matches directories only.
    let isDirectoryOnly: Bool

    /// `true` when the pattern contains a `/` other than a single trailing
    /// one, meaning it only matches relative to its base directory rather than
    /// at any depth beneath it.
    let isAnchored: Bool

    /// The path components of the standardized directory that contains the
    /// `.gitignore` file this pattern came from, computed one time (see
    /// `RelativePath.components(of:)`). `GitignoreStack` compares each walked
    /// entry with each pattern, thus a standardized URL for each comparison
    /// is too expensive for a large tree.
    let baseDirectoryComponents: [String]

    /// The compiled glob-to-regex matcher for the pattern's body, with any
    /// `!` prefix, directory-only trailing `/`, and anchoring leading `/`
    /// already stripped.
    let regex: NSRegularExpression

    /// Parses one `.gitignore` line into a pattern, or returns `nil` for a
    /// blank line, a comment, or a pattern this matcher can't compile.
    ///
    /// - Parameters:
    ///   - line: One raw line from a `.gitignore` file, without its
    ///     trailing newline.
    ///   - baseDirectory: The directory containing the `.gitignore` file
    ///     `line` came from.
    init?(line: String, baseDirectory: URL) {
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
        baseDirectoryComponents = RelativePath.components(of: baseDirectory)
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

/// Accumulates `.gitignore` rules along a directory path, root-to-leaf, and
/// evaluates ignore decisions the way `git` does for nested gitignore
/// files: the last matching pattern wins, and a nested directory's own
/// `.gitignore` patterns are evaluated after (so they take precedence over)
/// its ancestors'.
struct GitignoreStack {
    private var patterns: [GitignorePattern]

    /// An empty stack, with no accumulated `.gitignore` rules yet — used at
    /// the root of a walk.
    init() {
        patterns = []
    }

    /// Returns a copy of this stack with `directory`'s own `.gitignore`
    /// rules appended, for evaluating that directory's children.
    ///
    /// - Parameter directory: The directory whose `.gitignore` (if any)
    ///   should extend this stack.
    /// - Returns: `self` unchanged if `directory` has no readable
    ///   `.gitignore`; otherwise a new stack with its patterns appended.
    func appending(gitignoreAt directory: URL) -> GitignoreStack {
        let gitignoreURL = directory.appendingPathComponent(".gitignore", isDirectory: false)
        guard let contents = try? String(contentsOf: gitignoreURL, encoding: .utf8) else {
            return self
        }
        var next = self
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : String(rawLine)
            if let pattern = GitignorePattern(line: line, baseDirectory: directory) {
                next.patterns.append(pattern)
            }
        }
        return next
    }

    /// Whether `url` should be excluded from the walk under the
    /// accumulated rules.
    ///
    /// - Parameters:
    ///   - url: The candidate entry's full filesystem URL.
    ///   - isDirectory: Whether the candidate entry is a directory.
    /// - Returns: `true` if the last pattern (across all accumulated
    ///   `.gitignore` files) that applies to `url` is a non-negated match.
    func isIgnored(_ url: URL, isDirectory: Bool) -> Bool {
        isIgnored(pathComponents: RelativePath.components(of: url), isDirectory: isDirectory)
    }

    /// Whether the entry with the standardized path components
    /// `urlComponents` should be excluded from the walk under the
    /// accumulated rules.
    ///
    /// `Walker` calls this form for each entry of a tree. It builds the
    /// components of a child from the components of its directory, thus it
    /// makes no standardized URL for each entry, and no pattern makes one.
    ///
    /// - Parameters:
    ///   - urlComponents: The path components of the candidate entry, as
    ///     `RelativePath.components(of:)` gives them.
    ///   - isDirectory: Whether the candidate entry is a directory.
    /// - Returns: `true` if the last pattern (across all accumulated
    ///   `.gitignore` files) that applies to the entry is a non-negated match.
    func isIgnored(pathComponents urlComponents: [String], isDirectory: Bool) -> Bool {
        var ignored = false
        for pattern in patterns {
            guard let relative = RelativePath.of(components: urlComponents, relativeTo: pattern.baseDirectoryComponents) else {
                continue
            }
            if pattern.matches(relativePath: relative, isDirectory: isDirectory) {
                ignored = !pattern.isNegated
            }
        }
        return ignored
    }
}

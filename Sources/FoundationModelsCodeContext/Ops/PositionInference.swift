import Foundation

/// The position that a position operation uses, when the caller did not give
/// the exact column.
///
/// A model knows the file, the line and the name that it wants, but it rarely
/// knows the exact column. `PositionInference` then finds the position, and
/// this value tells the model which position the operation used.
public struct ResolvedPosition: Codable, Sendable, Equatable {
    /// The zero-based line that the operation uses.
    public let line: Int

    /// The zero-based UTF-16 column that the operation uses.
    public let character: Int

    /// Why the position is different from the arguments, or `nil` when the
    /// arguments gave the position exactly.
    public let note: String?

    /// Whether the operation found the position itself.
    public var isInferred: Bool { note != nil }

    /// Makes a resolved position.
    /// - Parameters:
    ///   - line: The zero-based line.
    ///   - character: The zero-based UTF-16 column.
    ///   - note: Why the position is different from the arguments, or `nil`.
    public init(line: Int, character: Int, note: String? = nil) {
        self.line = line
        self.character = character
        self.note = note
    }
}

/// Finds the position for a position operation from a line and, when the
/// caller has them, a column and a symbol name.
///
/// The rules, in order:
/// 1. A symbol name: its first whole-identifier occurrence on the line, else
///    on the nearest line within `symbolSearchRadius` lines.
/// 2. A column in the line: the column, as given.
/// 3. A column one past the end of the line: a one-based column, minus one.
/// 4. Otherwise: the first identifier on the line that is not a keyword.
enum PositionInference {
    /// How many lines before and after the given line a symbol search looks.
    static let symbolSearchRadius = 3

    /// The keywords that rule 4 skips: they are never the symbol that the
    /// caller wants. The set holds the keywords of the common languages of the
    /// index; a name that is a keyword in one language only is not in it.
    static let keywords: Set<String> = [
        "abstract", "and", "as", "assert", "async", "await", "break", "case", "catch", "class", "const",
        "continue", "def", "default", "defer", "del", "do", "elif", "else", "enum", "except", "export",
        "extends", "extension", "final", "finally", "fn", "for", "from", "func", "function", "global", "go",
        "guard", "if", "impl", "implements", "import", "in", "interface", "internal", "is", "lambda", "let",
        "mod", "module", "mut", "mutating", "new", "nonlocal", "not", "or", "override", "package", "pass",
        "private", "protected", "protocol", "pub", "public", "raise", "return", "static", "struct", "switch",
        "throw", "throws", "trait", "try", "typealias", "use", "val", "var", "where", "while", "with", "yield",
    ]

    /// Finds the position.
    /// - Parameters:
    ///   - text: The text of the file, or `nil` when it cannot be read. With no
    ///     text the position is the line and the column (0 when none).
    ///   - line: The zero-based line that the caller gave.
    ///   - character: The zero-based UTF-16 column that the caller gave, or
    ///     `nil`.
    ///   - symbol: The name of the symbol that the caller wants, or `nil`. A
    ///     dotted name such as `Class.member` uses its last component.
    /// - Returns: The position, with a note when it is not the one given.
    static func resolve(text: String?, line: Int, character: Int?, symbol: String?) -> ResolvedPosition {
        guard let text else {
            return ResolvedPosition(line: line, character: character ?? 0)
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard line >= 0, line < lines.count else {
            return ResolvedPosition(line: line, character: character ?? 0)
        }
        if let name = symbolName(symbol) {
            if let character, identifier(at: character, in: lines[line]) == name {
                return ResolvedPosition(line: line, character: character)
            }
            if let found = nearestOccurrence(of: name, around: line, in: lines) {
                let place = found.line == line ? "on line \(line)" : "on line \(found.line), not on line \(line)"
                return ResolvedPosition(
                    line: found.line,
                    character: found.character,
                    note: "Used the position of `\(name)` \(place), at character \(found.character)."
                )
            }
        }
        let width = lines[line].utf16.count
        if let character {
            if character >= 0, character < max(width, 1) {
                return ResolvedPosition(line: line, character: character)
            }
            if character == width, width > 0 {
                return ResolvedPosition(
                    line: line,
                    character: character - 1,
                    note: "Character \(character) is past the end of line \(line); used it as a 1-based column, character \(character - 1)."
                )
            }
        }
        guard let first = firstIdentifier(in: lines[line]) else {
            return ResolvedPosition(line: line, character: character.map { min(max($0, 0), width) } ?? 0)
        }
        let reason = character == nil ? "No character was given" : "Character \(character ?? 0) is not in line \(line)"
        return ResolvedPosition(
            line: line,
            character: first.character,
            note: "\(reason); used the first name on the line, `\(first.name)`, at character \(first.character)."
        )
    }

    /// The identifier to search for: the last component of a dotted name,
    /// without spaces or a call suffix, or `nil` when there is none.
    private static func symbolName(_ symbol: String?) -> String? {
        guard let symbol else { return nil }
        let base = symbol.split(separator: "(").first.map(String.init) ?? symbol
        let last = base.split(separator: ".").last.map(String.init) ?? base
        let name = last.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// Finds `name` on `line`, then on the lines around it, nearest first; a
    /// line before wins over a line after at the same distance.
    private static func nearestOccurrence(of name: String, around line: Int, in lines: [Substring]) -> Position? {
        var order = [line]
        for distance in 1...symbolSearchRadius {
            order.append(line - distance)
            order.append(line + distance)
        }
        for candidate in order where candidate >= 0 && candidate < lines.count {
            if let found = SymbolNameLocator.position(
                ofName: name, from: Position(line: candidate, character: 0), throughLine: candidate, in: lines
            ) {
                return found
            }
        }
        return nil
    }

    /// The identifier that covers the UTF-16 column `character` of `line`, or
    /// `nil` when the column is not inside an identifier.
    private static func identifier(at character: Int, in line: Substring) -> String? {
        identifiers(in: line).first { $0.character <= character && character < $0.character + $0.name.utf16.count }?.name
    }

    /// The first identifier of `line` that is not a keyword and does not start
    /// with a digit.
    private static func firstIdentifier(in line: Substring) -> (name: String, character: Int)? {
        identifiers(in: line).first { !keywords.contains($0.name) && !($0.name.first?.isNumber ?? true) }
    }

    /// Each identifier of `line`, with its UTF-16 column, in order. The text
    /// of a string literal and the text after a `#` or `//` comment start are
    /// not read.
    private static func identifiers(in line: Substring) -> [(name: String, character: Int)] {
        var result: [(name: String, character: Int)] = []
        var current = ""
        var start = 0
        var column = 0
        var previous: Character?
        var quote: Character?
        for character in line {
            defer {
                column += character.utf16.count
                previous = character
            }
            if let open = quote {
                if character == open && previous != "\\" {
                    quote = nil
                }
                continue
            }
            if character == "#" || (character == "/" && previous == "/") {
                break
            }
            if character == "\"" || character == "'" || character == "`" {
                quote = character
            }
            if SymbolNameLocator.isIdentifierCharacter(character) {
                if current.isEmpty { start = column }
                current.append(character)
            } else if !current.isEmpty {
                result.append((current, start))
                current = ""
            }
        }
        if !current.isEmpty {
            result.append((current, start))
        }
        return result
    }
}

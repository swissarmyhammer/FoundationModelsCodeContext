import Foundation

/// Finds the position of the name of a symbol in the source text.
///
/// A `textDocument/references` request must point at the name of a
/// symbol. Some servers give a symbol range that starts before the name:
/// `pylsp` gives the flat `SymbolInformation` shape, and its range starts at
/// the `def` keyword. A request at that position gives no references. The
/// references fallback of `LSPIndexWorker` therefore finds the name in the
/// text of the symbol and sends the request there.
enum SymbolNameLocator {
    /// Finds the first whole-identifier occurrence of `name` at or after
    /// `start`, on the lines from `start.line` through `endLine`.
    ///
    /// An occurrence inside a longer identifier does not count: `de` is not
    /// found inside `def`. The column of the result is in UTF-16 code units,
    /// as LSP positions are.
    /// - Parameters:
    ///   - name: The name of the symbol.
    ///   - start: Where the search starts: the start of the selection range
    ///     of the symbol. Its column is in UTF-16 code units.
    ///   - endLine: The last line of the symbol; the search does not go past it.
    ///   - lines: The text of the file, split at each line feed.
    /// - Returns: The position of the name, or `nil` when the lines of the
    ///   symbol do not hold it.
    static func position(ofName name: String, from start: Position, throughLine endLine: Int, in lines: [Substring]) -> Position? {
        guard !name.isEmpty, start.line >= 0, start.line < lines.count else {
            return nil
        }
        let lastLine = min(endLine, lines.count - 1)
        guard start.line <= lastLine else {
            return nil
        }
        for lineIndex in start.line...lastLine {
            let fromColumn = lineIndex == start.line ? start.character : 0
            if let column = identifierColumn(of: name, in: lines[lineIndex], fromUTF16Column: fromColumn) {
                return Position(line: lineIndex, character: column)
            }
        }
        return nil
    }

    /// Finds the first whole-identifier occurrence of `name` in `line`, at or
    /// after the UTF-16 column `fromColumn`.
    /// - Parameters:
    ///   - name: The identifier to find.
    ///   - line: One line of text.
    ///   - fromColumn: The UTF-16 column where the search starts.
    /// - Returns: The UTF-16 column of the occurrence, or `nil` when the line
    ///   does not hold `name` as a whole identifier.
    private static func identifierColumn(of name: String, in line: Substring, fromUTF16Column fromColumn: Int) -> Int? {
        // A column inside a character (for example between the two code
        // units of an emoji) is not a place where a name can start.
        guard fromColumn >= 0, fromColumn <= line.utf16.count,
            let startIndex = line.utf16.index(line.startIndex, offsetBy: fromColumn).samePosition(in: line.base)
        else {
            return nil
        }
        var searchStart = startIndex
        while let found = line.range(of: name, range: searchStart..<line.endIndex) {
            if isIdentifierBoundary(before: found.lowerBound, in: line) && isIdentifierBoundary(at: found.upperBound, in: line) {
                return line.utf16.distance(from: line.startIndex, to: found.lowerBound)
            }
            searchStart = line.index(after: found.lowerBound)
        }
        return nil
    }

    /// Whether the character before `index` is not part of an identifier.
    private static func isIdentifierBoundary(before index: Substring.Index, in line: Substring) -> Bool {
        guard index > line.startIndex else {
            return true
        }
        return !isIdentifierCharacter(line[line.index(before: index)])
    }

    /// Whether the character at `index` is not part of an identifier.
    private static func isIdentifierBoundary(at index: Substring.Index, in line: Substring) -> Bool {
        guard index < line.endIndex else {
            return true
        }
        return !isIdentifierCharacter(line[index])
    }

    /// Whether `character` can be part of an identifier: a letter, a digit,
    /// `_` or `$`.
    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "$"
    }
}

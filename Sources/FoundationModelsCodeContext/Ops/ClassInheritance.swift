import Foundation

/// Reads the base classes of a class from the source text of its chunk, and
/// orders a class and its bases the way Python looks up an attribute.
///
/// `SymbolOps.getSymbol(store:query:maxResults:)` uses this for its
/// `SymbolMatchTier.inherited` tier: a `Class.member` query whose class does
/// not define `member` resolves to the `member` of the first base class in
/// that order. The index has no inheritance table, so the bases come from the
/// class header in `ts_chunks.text` at query time.
enum ClassInheritance {
    /// The file extensions whose class headers `baseNames(ofClassText:filePath:)`
    /// can read.
    private static let pythonExtensions: Set<String> = ["py", "pyi"]

    /// The names of the base classes in the header of a class, in the order
    /// they are written.
    ///
    /// Only Python is read: `class B(A, mixins.C, metaclass=M):` gives
    /// `["A", "mixins.C"]`. Keyword arguments, `*args`, `**kwargs` and the
    /// subscript of a generic base (`Generic[T]` gives `Generic`) are left
    /// out. A file in another language gives no bases.
    ///
    /// - Parameters:
    ///   - text: The source text of the class chunk. It can start with
    ///     decorators.
    ///   - filePath: The path of the file of the class, to know its language.
    /// - Returns: The base class names, each as written, possibly dotted.
    static func baseNames(ofClassText text: String, filePath: String) -> [String] {
        let fileExtension = (filePath as NSString).pathExtension.lowercased()
        guard pythonExtensions.contains(fileExtension) else {
            return []
        }
        return pythonBaseNames(ofClassText: text)
    }

    /// The base class names of the first `class` header in `text`. See
    /// `baseNames(ofClassText:filePath:)`.
    private static func pythonBaseNames(ofClassText text: String) -> [String] {
        let characters = Array(text)
        guard var index = indexAfterClassName(in: characters) else {
            return []
        }
        index = skippingWhitespace(in: characters, from: index)
        // A Python 3.12 type parameter list, `class B[T](A):`, comes before
        // the bases.
        if index < characters.count, characters[index] == "[" {
            guard let closing = indexOfMatchingClose(in: characters, from: index) else {
                return []
            }
            index = skippingWhitespace(in: characters, from: closing + 1)
        }
        guard index < characters.count, characters[index] == "(",
            let closing = indexOfMatchingClose(in: characters, from: index)
        else {
            return []
        }
        return topLevelArguments(String(characters[(index + 1)..<closing])).compactMap(baseName(ofArgument:))
    }

    /// The index just past the class name of the first line that starts with
    /// `class `, or `nil` when no line does.
    private static func indexAfterClassName(in characters: [Character]) -> Int? {
        let keyword = Array("class ")
        var lineStart = 0
        while lineStart < characters.count {
            let start = skippingWhitespace(in: characters, from: lineStart, acrossLines: false)
            if start + keyword.count <= characters.count, Array(characters[start..<(start + keyword.count)]) == keyword {
                var index = skippingWhitespace(in: characters, from: start + keyword.count, acrossLines: false)
                while index < characters.count, characters[index].isLetter || characters[index].isNumber || characters[index] == "_" {
                    index += 1
                }
                return index
            }
            guard let newline = characters[lineStart...].firstIndex(of: "\n") else {
                return nil
            }
            lineStart = newline + 1
        }
        return nil
    }

    /// The index of the first character at or after `index` that is not
    /// white space.
    private static func skippingWhitespace(in characters: [Character], from index: Int, acrossLines: Bool = true) -> Int {
        var index = index
        while index < characters.count, characters[index].isWhitespace, acrossLines || !characters[index].isNewline {
            index += 1
        }
        return index
    }

    /// The index of the bracket that closes the bracket at `index`, or `nil`
    /// when the text ends first.
    private static func indexOfMatchingClose(in characters: [Character], from index: Int) -> Int? {
        var depth = 0
        for position in index..<characters.count {
            switch characters[position] {
            case "(", "[", "{":
                depth += 1
            case ")", "]", "}":
                depth -= 1
                if depth == 0 {
                    return position
                }
            default:
                break
            }
        }
        return nil
    }

    /// Splits an argument list at the commas that are not inside brackets.
    private static func topLevelArguments(_ list: String) -> [String] {
        var arguments: [String] = []
        var current = ""
        var depth = 0
        for character in list {
            switch character {
            case "(", "[", "{":
                depth += 1
            case ")", "]", "}":
                depth -= 1
            case "," where depth == 0:
                arguments.append(current)
                current = ""
                continue
            default:
                break
            }
            current.append(character)
        }
        arguments.append(current)
        return arguments
    }

    /// The base class name of one argument of a class header, or `nil` for a
    /// keyword argument, a starred argument or an empty one.
    private static func baseName(ofArgument argument: String) -> String? {
        var name = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        if let subscriptStart = name.firstIndex(of: "[") {
            name = String(name[..<subscriptStart])
        }
        guard !name.isEmpty, !name.hasPrefix("*"), !name.contains("=") else {
            return nil
        }
        return name
    }

    /// Orders `start` and its base classes with the C3 linearization, the
    /// method resolution order of Python.
    ///
    /// A cycle in the bases, or an order that C3 cannot make, does not fail:
    /// the classes that remain are added in the order of their sequences, so
    /// the result always holds each reachable class once.
    ///
    /// - Parameters:
    ///   - start: The class to order.
    ///   - bases: The direct base classes of a class, in the order they are
    ///     written.
    /// - Returns: `start`, then its bases in lookup order.
    static func methodResolutionOrder<Key: Hashable>(of start: Key, bases: (Key) -> [Key]) -> [Key] {
        var memo: [Key: [Key]] = [:]
        var visiting: Set<Key> = []
        return linearize(start, bases: bases, memo: &memo, visiting: &visiting)
    }

    /// The C3 linearization of `key`. See
    /// `methodResolutionOrder(of:bases:)`.
    private static func linearize<Key: Hashable>(
        _ key: Key,
        bases: (Key) -> [Key],
        memo: inout [Key: [Key]],
        visiting: inout Set<Key>
    ) -> [Key] {
        if let known = memo[key] {
            return known
        }
        guard visiting.insert(key).inserted else {
            return [key]
        }
        defer { visiting.remove(key) }

        let directBases = bases(key).filter { $0 != key }
        var sequences = directBases.map { linearize($0, bases: bases, memo: &memo, visiting: &visiting) } + [directBases]
        var order = [key]
        while true {
            sequences.removeAll { $0.isEmpty }
            guard !sequences.isEmpty else {
                break
            }
            let head = sequences.lazy.map { $0[0] }.first { candidate in
                !sequences.contains { $0.dropFirst().contains(candidate) }
            }
            guard let head else {
                for key in sequences.joined() where !order.contains(key) {
                    order.append(key)
                }
                break
            }
            if !order.contains(head) {
                order.append(head)
            }
            sequences = sequences.map { $0.first == head ? Array($0.dropFirst()) : $0 }
        }
        memo[key] = order
        return order
    }
}

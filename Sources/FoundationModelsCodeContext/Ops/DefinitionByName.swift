import Foundation
import GRDB

/// Resolves the name at a cursor to its definitions in the index, for the
/// index fallback of `definition`.
///
/// The position lookup of the index gives the symbol that encloses the
/// cursor. That is the right answer on the name that a definition declares
/// (`def helper` at `helper`), and a wrong one at a call or a reference: at
/// `helper()` inside `user()` it gives `user`. So when the cursor is on a
/// name that no definition declares at that place, this type finds the
/// definitions with that name, ranked: the same file, then the module that
/// the file imports the name from, then the rest.
enum DefinitionByName {
    /// What the lookup found at the cursor.
    enum Lookup {
        /// The cursor is not on a name, or it is on a defining name that the
        /// index has no row for at that line: the position lookup answers.
        case byPosition

        /// The cursor is on the name that this definition declares there.
        case declaration(Candidate)

        /// The cursor is on a call or a reference to a name. The candidates
        /// are the definitions with that name, best first; there can be none.
        case byName(candidates: [Candidate], note: String)
    }

    /// One definition with the name at the cursor.
    struct Candidate {
        /// The definition.
        let symbol: LayeredSymbolInfo

        /// The index table that holds the definition.
        let layer: SourceLayer

        /// Why the definition ranks where it does.
        let rank: Rank
    }

    /// The rank of a candidate; a smaller raw value comes first.
    enum Rank: Int {
        /// The definition is in the file of the cursor.
        case sameFile

        /// The definition is in the module that the file imports the name,
        /// or its qualifier, from.
        case imported

        /// Any other definition with the name.
        case other
    }

    /// The `resolvedBy` value of a `DefinitionResult` that this type made.
    static let resolvedBy = "name"

    /// The most candidates that a result gives.
    static let maxCandidates = 10

    /// The keywords that declare a definition: the name after one of them is
    /// the defining name, not a reference.
    static let definingKeywords: Set<String> = [
        "def", "class", "func", "function", "fn", "struct", "enum", "protocol", "interface", "trait", "type",
        "typealias", "actor",
    ]

    /// Finds what the cursor is on, and the definitions of its name.
    /// - Parameters:
    ///   - db: The index database.
    ///   - text: The text of the file of the cursor, or `nil` when it cannot
    ///     be read.
    ///   - filePath: The file of the cursor, relative to the workspace root.
    ///   - line: The zero-based line of the cursor.
    ///   - character: The zero-based UTF-16 column of the cursor.
    /// - Returns: The definition that the cursor's name declares, the ranked
    ///   definitions of a called or referenced name, or `.byPosition`.
    /// - Throws: The error that a query throws.
    static func lookup(db: Database, text: String?, filePath: String, line: Int, character: Int) throws -> Lookup {
        guard let text else { return .byPosition }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard line >= 0, line < lines.count else { return .byPosition }
        let tokens = PositionInference.identifiers(in: lines[line])
        guard
            let index = tokens.firstIndex(where: {
                $0.character <= character && character < $0.character + $0.name.utf16.count
            })
        else {
            return .byPosition
        }
        let name = tokens[index].name
        if PositionInference.keywords.contains(name) {
            return .byPosition
        }
        let found = try definitions(named: name, db: db)
        if let declared = found.first(where: { $0.symbol.filePath == filePath && $0.symbol.range.start.line == line }) {
            return .declaration(Candidate(symbol: declared.symbol, layer: declared.layer, rank: .sameFile))
        }
        if index > 0 && definingKeywords.contains(tokens[index - 1].name) {
            return .byPosition
        }
        let qualifier = qualifier(before: tokens[index].character, in: lines[line])
        let modules = importedModules(name: name, qualifier: qualifier, filePath: filePath, lines: lines)
        let ranked =
            found
            .map { definition in
                Candidate(symbol: definition.symbol, layer: definition.layer, rank: rank(of: definition.symbol, filePath: filePath, modules: modules))
            }
            .sorted { lhs, rhs in
                (lhs.rank.rawValue, lhs.symbol.filePath, lhs.symbol.range.start.line)
                    < (rhs.rank.rawValue, rhs.symbol.filePath, rhs.symbol.range.start.line)
            }
        let candidates = Array(ranked.prefix(maxCandidates))
        return .byName(candidates: candidates, note: note(name: name, candidates: candidates, total: ranked.count))
    }

    /// The note of a lookup by name.
    private static func note(name: String, candidates: [Candidate], total: Int) -> String {
        guard let first = candidates.first else {
            return "No definition named `\(name)` is in the index. The position is on a call or a reference to `\(name)`, not on a definition."
        }
        let source = "No language server answered, so the index resolved `\(name)` by name."
        if total == 1 {
            return "\(source) One definition has the name, in \(first.symbol.filePath)."
        }
        let shown = total > candidates.count ? " The first \(candidates.count) are shown." : ""
        return "\(source) \(total) definitions have the name; they are ranked: the same file, then the imported module, then the rest.\(shown)"
    }

    /// Each definition named `name`: the `lsp_symbols` rows, and the
    /// `ts_chunks` rows whose leaf name is `name` and that no `lsp_symbols`
    /// row of the same name in the same file overlaps.
    private static func definitions(named name: String, db: Database) throws -> [(symbol: LayeredSymbolInfo, layer: SourceLayer)] {
        let lspRows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(Schema.LspSymbols.kind), \(Schema.LspSymbols.detail), \(Schema.LspSymbols.filePath), \
                       \(Schema.LspSymbols.startLine), \(Schema.LspSymbols.startColumn), \
                       \(Schema.LspSymbols.endLine), \(Schema.LspSymbols.endColumn) \
                FROM \(Schema.LspSymbols.table) WHERE \(Schema.LspSymbols.name) = ?
                """,
            arguments: [name]
        )
        var result: [(symbol: LayeredSymbolInfo, layer: SourceLayer)] = lspRows.map { row in
            let range = LSPRange(
                start: Position(line: row[Schema.LspSymbols.startLine], character: row[Schema.LspSymbols.startColumn]),
                end: Position(line: row[Schema.LspSymbols.endLine], character: row[Schema.LspSymbols.endColumn])
            )
            let symbol = LayeredSymbolInfo(
                name: name, qualifiedPath: nil, kind: row[Schema.LspSymbols.kind], detail: row[Schema.LspSymbols.detail],
                filePath: row[Schema.LspSymbols.filePath], range: range
            )
            return (symbol, .lspIndex)
        }
        let chunkRows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(Schema.TsChunks.filePath), \(Schema.TsChunks.startLine), \(Schema.TsChunks.endLine), \
                       \(Schema.TsChunks.symbolPath), \(Schema.TsChunks.kind) \
                FROM \(Schema.TsChunks.table) \
                WHERE \(Schema.TsChunks.symbolPath) = ? OR \(Schema.TsChunks.symbolPath) LIKE ? ESCAPE '\\'
                """,
            arguments: [name, "%" + Chunker.symbolPathSeparator + likeEscaped(name)]
        )
        for row in chunkRows {
            let qualifiedPath: String = row[Schema.TsChunks.symbolPath]
            guard SymbolOps.leafName(ofQualifiedPath: qualifiedPath) == name else { continue }
            let filePath: String = row[Schema.TsChunks.filePath]
            let startLine: Int = row[Schema.TsChunks.startLine]
            let endLine: Int = row[Schema.TsChunks.endLine]
            let overlapped = result.contains { existing in
                existing.layer == .lspIndex && existing.symbol.filePath == filePath
                    && existing.symbol.range.start.line >= startLine && existing.symbol.range.start.line <= endLine
            }
            guard !overlapped else { continue }
            let symbol = LayeredSymbolInfo(
                name: name, qualifiedPath: qualifiedPath, kind: row[Schema.TsChunks.kind], detail: nil, filePath: filePath,
                range: LSPRange(start: Position(line: startLine, character: 0), end: Position(line: endLine, character: 0))
            )
            result.append((symbol, .treeSitter))
        }
        return result
    }

    /// `text` with the `LIKE` wildcards `%` and `_` and the escape `\`
    /// escaped.
    private static func likeEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    /// The name before a `.` that comes right before the UTF-16 column
    /// `column` of `line`: `models` in `models.Model`. `nil` when the name at
    /// `column` has no qualifier.
    private static func qualifier(before column: Int, in line: Substring) -> String? {
        let prefix = String(line.utf16.prefix(column)) ?? ""
        guard prefix.hasSuffix(".") else { return nil }
        let beforeDot = prefix.dropLast()
        let name = String(beforeDot.reversed().prefix(while: SymbolNameLocator.isIdentifierCharacter).reversed())
        return name.isEmpty ? nil : name
    }

    /// The module paths, as relative file paths without an extension, that
    /// the file imports `name` or `qualifier` from: `django/db/models` for
    /// `from django.db.models import Model` and the name `Model`.
    ///
    /// The import forms are Python's: `from M import a, b as c` and
    /// `import M` / `import M as q`. A relative module (`.x`) is relative to
    /// the directory of the file.
    private static func importedModules(name: String, qualifier: String?, filePath: String, lines: [Substring]) -> [String] {
        let local = qualifier ?? name
        var modules: [String] = []
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let words = line.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "(" || $0 == ")" }).map(String.init)
            if words.first == "from", words.count >= 4, words[2] == "import" {
                let imported = importedNames(words.dropFirst(3))
                if let original = imported[local] {
                    // `from M import x`: with a qualifier, `x` is itself a module (M.x).
                    let module = qualifier == nil ? words[1] : words[1] + "." + original
                    modules.append(modulePath(module, relativeTo: filePath))
                }
            } else if words.first == "import", words.count >= 2 {
                for (alias, module) in importedNames(words.dropFirst(1), modulesAreNames: true) where alias == local {
                    modules.append(modulePath(module, relativeTo: filePath))
                }
            }
        }
        return modules
    }

    /// The local names of an import list, each mapped to its original name:
    /// `a`, `b as c` gives `["a": "a", "c": "b"]`. With `modulesAreNames`,
    /// a dotted module `a.b` binds its last part `b` and maps to `a.b`.
    private static func importedNames(_ words: ArraySlice<String>, modulesAreNames: Bool = false) -> [String: String] {
        var result: [String: String] = [:]
        let items = Array(words)
        var index = 0
        while index < items.count {
            let original = items[index]
            if index + 2 < items.count, items[index + 1] == "as" {
                result[items[index + 2]] = original
                index += 3
            } else {
                let local = modulesAreNames ? (original.split(separator: ".").last.map(String.init) ?? original) : original
                result[local] = original
                index += 1
            }
        }
        return result
    }

    /// The relative file path, without an extension, of the Python module
    /// `module`, seen from `filePath`.
    private static func modulePath(_ module: String, relativeTo filePath: String) -> String {
        let dots = module.prefix(while: { $0 == "." }).count
        let parts = module.dropFirst(dots).split(separator: ".").map(String.init)
        guard dots > 0 else { return parts.joined(separator: "/") }
        var directory = filePath.split(separator: "/").dropLast().map(String.init)
        directory.removeLast(min(dots - 1, directory.count))
        return (directory + parts).joined(separator: "/")
    }

    /// The rank of `symbol` for a cursor in `filePath` whose name the file
    /// imports from `modules`.
    private static func rank(of symbol: LayeredSymbolInfo, filePath: String, modules: [String]) -> Rank {
        if symbol.filePath == filePath {
            return .sameFile
        }
        let path = symbol.filePath
        let withoutExtension = (path as NSString).deletingPathExtension
        for module in modules where !module.isEmpty {
            if withoutExtension == module || withoutExtension.hasSuffix("/" + module) || withoutExtension == module + "/__init__"
                || withoutExtension.hasSuffix("/" + module + "/__init__")
            {
                return .imported
            }
        }
        return .other
    }
}

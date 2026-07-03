import Foundation
import SwiftTreeSitter

/// Options controlling a `QueryAST.run(rootDirectory:language:query:options:)` invocation.
public struct QueryASTOptions: Sendable, Equatable {
    /// The maximum number of matches to return before truncating.
    public let maxResults: Int

    /// Creates query AST options.
    ///
    /// - Parameter maxResults: The maximum number of matches to return
    ///   before truncating. Defaults to 50.
    public init(maxResults: Int = 50) {
        self.maxResults = maxResults
    }
}

/// One captured node from a tree-sitter query match.
public struct ASTCapture: Sendable, Equatable {
    /// The capture's name, e.g. `"name"` for a `@name` capture.
    public let name: String

    /// The captured node's tree-sitter kind, e.g. `"identifier"`.
    public let kind: String

    /// The captured node's source text.
    public let text: String

    /// The captured node's zero-based start line.
    public let startLine: Int

    /// The captured node's zero-based end line.
    public let endLine: Int

    /// The captured node's start offset, in UTF-8 bytes, within its file's content.
    public let startByte: Int

    /// The captured node's end offset, in UTF-8 bytes, within its file's content.
    public let endByte: Int

    /// Creates an AST capture.
    ///
    /// - Parameters:
    ///   - name: The capture's name.
    ///   - kind: The captured node's tree-sitter kind.
    ///   - text: The captured node's source text.
    ///   - startLine: The captured node's zero-based start line.
    ///   - endLine: The captured node's zero-based end line.
    ///   - startByte: The captured node's start offset, in UTF-8 bytes.
    ///   - endByte: The captured node's end offset, in UTF-8 bytes.
    public init(
        name: String,
        kind: String,
        text: String,
        startLine: Int,
        endLine: Int,
        startByte: Int,
        endByte: Int
    ) {
        self.name = name
        self.kind = kind
        self.text = text
        self.startLine = startLine
        self.endLine = endLine
        self.startByte = startByte
        self.endByte = endByte
    }
}

/// One match from a query, with every capture it produced.
public struct ASTMatch: Sendable, Equatable {
    /// The matched file's path, relative to the query's root directory.
    public let file: String

    /// The match's captures, in query-declaration order.
    public let captures: [ASTCapture]

    /// Creates an AST match.
    ///
    /// - Parameters:
    ///   - file: The matched file's path, relative to the query's root
    ///     directory.
    ///   - captures: The match's captures, in query-declaration order.
    public init(file: String, captures: [ASTCapture]) {
        self.file = file
        self.captures = captures
    }
}

/// The result of a `QueryAST.run(rootDirectory:language:query:options:)` invocation.
public struct QueryASTResult: Sendable, Equatable {
    /// The matches found, in file-then-match order, capped at `QueryASTOptions.maxResults`.
    public let matches: [ASTMatch]

    /// The number of files successfully read and parsed.
    public let filesScanned: Int

    /// `true` if `matches` was capped by `QueryASTOptions.maxResults` before every candidate file was scanned.
    public let truncated: Bool

    /// Creates a query AST result.
    ///
    /// - Parameters:
    ///   - matches: The matches found, capped at `QueryASTOptions.maxResults`.
    ///   - filesScanned: The number of files successfully read and parsed.
    ///   - truncated: `true` if `matches` was capped before every candidate
    ///     file was scanned.
    public init(matches: [ASTMatch], filesScanned: Int, truncated: Bool) {
        self.matches = matches
        self.filesScanned = filesScanned
        self.truncated = truncated
    }
}

/// Compiles a user-supplied tree-sitter S-expression query at runtime and
/// runs it against every matching file on disk under a root directory.
///
/// Port of the Rust `swissarmyhammer-code-context::ops::query_ast` module
/// (`crates/swissarmyhammer-code-context/src/ops/query_ast.rs`), adapted to
/// resolve both the language and the candidate file list itself: the Rust
/// reference takes an already-resolved `tree_sitter::Language` and an
/// explicit file list supplied by its MCP-tool caller, while this port takes
/// a language name (looked up in `Languages.all`) and discovers files itself
/// via `Walker` — gitignore-aware, filtered to the module's
/// `fileExtensions` — rather than re-implementing gitignore semantics or
/// requiring a caller-supplied list.
public enum QueryAST {
    /// Runs `query` against every file of `language` found under
    /// `rootDirectory`.
    ///
    /// Files are discovered via
    /// `Walker.enumerateFiles(rootDirectory:extensions:)` (gitignore-aware,
    /// root and nested `.gitignore`s honored), filtered to `language`'s
    /// registered `fileExtensions`, and visited in ascending relative-path
    /// order for deterministic results across runs. A file that can't be
    /// read as UTF-8 text, or that fails to parse, is silently skipped and
    /// does not count toward `filesScanned` — mirroring the Rust
    /// reference's warn-and-skip behavior for unreadable/unparseable files.
    ///
    /// - Parameters:
    ///   - rootDirectory: The directory to scan `language`'s files under.
    ///   - language: The target language's `LanguageModule.name`, matched
    ///     case-insensitively against `Languages.all`.
    ///   - query: The tree-sitter S-expression query text to compile and
    ///     run, e.g. `"(function_item name: (identifier) @name)"`.
    ///   - options: Result-count controls. Defaults to `QueryASTOptions()`.
    /// - Returns: Every match found, capped at `options.maxResults`, plus
    ///   how many files were scanned and whether results were truncated.
    /// - Throws: `CodeContextError.query` if `language` isn't registered in
    ///   `Languages.all`, has no `treeSitterLanguage`, or `query` fails to
    ///   compile. Rethrows
    ///   `Walker.enumerateFiles(rootDirectory:extensions:)`'s errors.
    public static func run(
        rootDirectory: URL,
        language: String,
        query: String,
        options: QueryASTOptions = QueryASTOptions()
    ) throws -> QueryASTResult {
        let module = try resolveModule(named: language)
        let grammar = try resolveGrammar(for: module)
        let compiledQuery = try compile(query: query, for: grammar)

        let parser = Parser()
        do {
            try parser.setLanguage(grammar)
        } catch {
            throw CodeContextError.query("failed to set parser language for '\(module.name)': \(error)")
        }

        let extensions = Set(module.fileExtensions.map { $0.lowercased() })
        let files = try Walker.enumerateFiles(rootDirectory: rootDirectory, extensions: extensions)
            .sorted { $0.path < $1.path }

        return scan(files: files, rootDirectory: rootDirectory, parser: parser, query: compiledQuery, options: options)
    }

    /// Parses each of `files` in turn, running `query` against it and
    /// collecting captured matches until every file is scanned or
    /// `options.maxResults` is reached.
    private static func scan(
        files: [URL],
        rootDirectory: URL,
        parser: Parser,
        query: Query,
        options: QueryASTOptions
    ) -> QueryASTResult {
        var matches: [ASTMatch] = []
        var filesScanned = 0
        var truncated = false

        for fileURL in files {
            guard let data = try? Data(contentsOf: fileURL), let contents = String(data: data, encoding: .utf8) else {
                continue
            }
            guard let tree = parser.parse(contents), let root = tree.rootNode else {
                continue
            }
            filesScanned += 1

            let relativePath = RelativePath.of(fileURL, relativeTo: rootDirectory) ?? fileURL.lastPathComponent
            let cursor = query.execute(node: root, in: tree)
            truncated = collectMatches(
                from: cursor,
                relativePath: relativePath,
                contents: contents,
                options: options,
                into: &matches
            )
            if truncated {
                break
            }
        }

        return QueryASTResult(matches: matches, filesScanned: filesScanned, truncated: truncated)
    }

    /// Runs `cursor` to completion against one file's already-parsed AST,
    /// appending a captured `ASTMatch` to `matches` for every non-empty
    /// match, until either `cursor` is exhausted or `options.maxResults` is
    /// reached.
    ///
    /// - Returns: `true` if `options.maxResults` was reached — the signal
    ///   `scan(files:rootDirectory:parser:query:options:)` uses to stop
    ///   visiting further files.
    private static func collectMatches(
        from cursor: QueryCursor,
        relativePath: String,
        contents: String,
        options: QueryASTOptions,
        into matches: inout [ASTMatch]
    ) -> Bool {
        for match in cursor {
            let captures = match.captures.compactMap { capture in
                makeCapture(from: capture, source: contents)
            }
            if !captures.isEmpty {
                matches.append(ASTMatch(file: relativePath, captures: captures))
            }
            if matches.count >= options.maxResults {
                return true
            }
        }
        return false
    }

    /// Looks up `name` in `Languages.all`, matched case-insensitively.
    private static func resolveModule(named name: String) throws -> any LanguageModule.Type {
        guard let module = Languages.all.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            let available = Languages.all.map { $0.name }.joined(separator: ", ")
            throw CodeContextError.query("unknown language '\(name)'; available languages: \(available)")
        }
        return module
    }

    /// Resolves `module`'s tree-sitter grammar, or throws if it has none.
    private static func resolveGrammar(for module: any LanguageModule.Type) throws -> Language {
        guard let grammar = module.treeSitterLanguage else {
            throw CodeContextError.query("language '\(module.name)' has no tree-sitter grammar available")
        }
        return grammar
    }

    /// Compiles `query` for `grammar`, translating a `SwiftTreeSitter`
    /// `QueryError` into a descriptive `CodeContextError.query`.
    private static func compile(query: String, for grammar: Language) throws -> Query {
        do {
            return try Query(language: grammar, data: Data(query.utf8))
        } catch {
            throw CodeContextError.query("invalid S-expression query: \(describe(queryCompilationError: error))")
        }
    }

    /// Renders a `SwiftTreeSitter.QueryError` as a human-readable message
    /// including its byte offset, or falls back to `error`'s own
    /// description for any other failure `Query.init(language:data:)`
    /// might throw.
    ///
    /// This is the only place this module pattern-matches `QueryError`'s
    /// cases: Swift has no reflection-based way to extract an enum's
    /// associated value generically, so a switch mapping each case straight
    /// to its message is the single source of truth for the mapping — a
    /// separate case-label-keyed lookup table would only duplicate each
    /// case name across two places instead of one.
    private static func describe(queryCompilationError error: Error) -> String {
        guard let queryError = error as? QueryError else {
            return String(describing: error)
        }
        switch queryError {
        case .none:
            return "no error"
        case let .syntax(offset):
            return "syntax error at byte offset \(offset)"
        case let .nodeType(offset):
            return "invalid node type at byte offset \(offset)"
        case let .field(offset):
            return "invalid field name at byte offset \(offset)"
        case let .capture(offset):
            return "invalid capture name at byte offset \(offset)"
        case let .structure(offset):
            return "invalid query structure at byte offset \(offset)"
        case let .unknown(offset):
            return "unknown query error at byte offset \(offset)"
        }
    }

    /// Builds an `ASTCapture` from a query capture, or `nil` if its node's
    /// range can't be resolved against `source` (only possible for a
    /// malformed tree, not expected in practice).
    private static func makeCapture(from capture: QueryCapture, source: String) -> ASTCapture? {
        guard let (text, startByte, endByte) = Chunker.extractTextAndRange(of: capture.node, in: source) else {
            return nil
        }
        return ASTCapture(
            name: capture.name ?? "",
            kind: capture.node.nodeType ?? "",
            text: text,
            startLine: Int(capture.node.pointRange.lowerBound.row),
            endLine: Int(capture.node.pointRange.upperBound.row),
            startByte: startByte,
            endByte: endByte
        )
    }
}

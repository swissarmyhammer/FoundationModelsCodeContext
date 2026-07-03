import SwiftTreeSitter

/// A file's relative path and text content, ready for `Chunker` to parse and
/// chunk.
///
/// Pairs the two pieces of information the tree-sitter worker has on hand
/// after reading a dirty file off disk: the workspace-relative path stored
/// in `ts_chunks.file_path`, and the file's full text. `Chunker` re-parses
/// this text on every call rather than accepting an already-parsed tree,
/// keeping it a simple, stateless, single-purpose type.
public struct SourceFile: Sendable, Equatable {
    /// The file's path relative to the workspace root, using `/` separators
    /// — the same string `TreeSitterWorker` stores in `ts_chunks.file_path`.
    public let relativePath: String

    /// The file's full text content.
    public let contents: String

    /// Creates a source file ready for chunking.
    ///
    /// - Parameters:
    ///   - relativePath: The file's path relative to the workspace root.
    ///   - contents: The file's full text content.
    public init(relativePath: String, contents: String) {
        self.relativePath = relativePath
        self.contents = contents
    }
}

/// One semantic chunk extracted from a parsed source file: a single
/// definition-like node, its byte/line range, its text, and its qualified
/// symbol path.
///
/// Port of the Rust `swissarmyhammer-treesitter::chunk::SemanticChunk`
/// (`crates/swissarmyhammer-treesitter/src/chunk.rs`), flattened to eagerly
/// hold `text`/`symbolPath` rather than lazily deriving them from a
/// `ChunkSource`/`Node` pair — `SemanticChunk` here has no tree-sitter
/// dependency of its own, since `Chunker.chunk(file:module:)` is a one-shot
/// conversion straight into the row shape `ts_chunks` stores.
public struct SemanticChunk: Sendable, Equatable {
    /// The file's path relative to the workspace root.
    public let filePath: String

    /// The chunk's start offset, in UTF-8 bytes, within the file's content.
    public let startByte: Int

    /// The chunk's end offset, in UTF-8 bytes, within the file's content.
    public let endByte: Int

    /// The chunk's zero-based start line.
    public let startLine: Int

    /// The chunk's zero-based end line.
    public let endLine: Int

    /// The chunk's source text.
    public let text: String

    /// The chunk's qualified symbol path, e.g. `Struct.method` for a method
    /// nested in a container, or `function` for a top-level definition.
    public let symbolPath: String

    /// The chunk's meta-type, from the owning `LanguageModule`'s
    /// `chunkKinds` map.
    public let kind: SymbolMetaType

    /// Creates a semantic chunk.
    ///
    /// - Parameters:
    ///   - filePath: The file's path relative to the workspace root.
    ///   - startByte: The chunk's start offset, in UTF-8 bytes.
    ///   - endByte: The chunk's end offset, in UTF-8 bytes.
    ///   - startLine: The chunk's zero-based start line.
    ///   - endLine: The chunk's zero-based end line.
    ///   - text: The chunk's source text.
    ///   - symbolPath: The chunk's qualified symbol path.
    ///   - kind: The chunk's meta-type.
    public init(
        filePath: String,
        startByte: Int,
        endByte: Int,
        startLine: Int,
        endLine: Int,
        text: String,
        symbolPath: String,
        kind: SymbolMetaType
    ) {
        self.filePath = filePath
        self.startByte = startByte
        self.endByte = endByte
        self.startLine = startLine
        self.endLine = endLine
        self.text = text
        self.symbolPath = symbolPath
        self.kind = kind
    }
}

/// Extracts `SemanticChunk`s from a source file's AST, generic over any
/// `LanguageModule`.
///
/// Port of `swissarmyhammer-treesitter::chunk`'s `chunk_file` and its
/// `collect_symbol_names`/`extract_node_name` helpers
/// (`crates/swissarmyhammer-treesitter/src/chunk.rs`), made data-driven over
/// `LanguageModule.chunkKinds`/`containerNodeKinds` instead of the Rust
/// file's flat, single-language-set `EMBEDDABLE_NODE_KINDS`/`CONTAINER_KINDS`
/// constants — one conforming `LanguageModule` per language replaces one
/// combined table per Rust source family.
public enum Chunker {
    /// Node fields tried, in order, to find a definition's own name.
    ///
    /// Ported verbatim from the Rust reference's `extract_node_name`, which
    /// tries `"name"`, `"identifier"`, then `"declarator"` before falling
    /// back to the `impl_item`-specific `"type"` field heuristic.
    private static let nameFields = ["name", "identifier", "declarator"]

    /// The longest text a name-field match may have to be accepted as a
    /// simple identifier, per the Rust reference's `try_extract_name_field`.
    private static let maxNameFieldLength = 100

    /// The longest text an `impl` block's type name may have to be accepted,
    /// per the Rust reference's `extract_impl_type_name`.
    private static let maxImplTypeNameLength = 50

    /// Separator joining qualified symbol path components, e.g.
    /// `Struct.method`.
    private static let symbolPathSeparator = "."

    /// Parses `file`'s content with `module`'s tree-sitter grammar and
    /// extracts one `SemanticChunk` per AST node whose kind is in
    /// `module.chunkKinds`.
    ///
    /// Returns an empty array — rather than throwing — if `module` has no
    /// `treeSitterLanguage`, or if parsing fails; `TreeSitterWorker` treats
    /// both the same as "no chunks found this pass" and still marks the
    /// file indexed, matching the Rust reference's skip-and-continue
    /// behavior for unparseable files.
    ///
    /// - Parameters:
    ///   - file: The source file to chunk.
    ///   - module: The language module supplying the grammar and chunk-kind
    ///     tables.
    /// - Returns: One chunk per matched definition node, in AST traversal
    ///   order.
    public static func chunk(file: SourceFile, module: any LanguageModule.Type) -> [SemanticChunk] {
        guard let language = module.treeSitterLanguage else {
            return []
        }

        let parser = Parser()
        do {
            try parser.setLanguage(language)
        } catch {
            return []
        }

        guard let tree = parser.parse(file.contents), let root = tree.rootNode else {
            return []
        }

        var chunks: [SemanticChunk] = []
        collectChunks(node: root, file: file, module: module, into: &chunks)
        return chunks
    }

    /// Recurses `node` and its descendants, appending a `SemanticChunk` for
    /// every node whose kind is in `module.chunkKinds`.
    ///
    /// Port of the Rust reference's `extract_chunks_recursive`, which always
    /// recurses into every child — named and anonymous alike — regardless of
    /// whether the current node itself was chunked, so nested definitions
    /// (a method inside a class, a function inside a module) are still
    /// found.
    private static func collectChunks(
        node: Node,
        file: SourceFile,
        module: any LanguageModule.Type,
        into chunks: inout [SemanticChunk]
    ) {
        if let kind = module.chunkKinds[node.nodeType ?? ""],
           let chunk = makeChunk(node: node, kind: kind, file: file, module: module)
        {
            chunks.append(chunk)
        }

        for childIndex in 0..<node.childCount {
            guard let child = node.child(at: childIndex) else {
                continue
            }
            collectChunks(node: child, file: file, module: module, into: &chunks)
        }
    }

    /// Builds a `SemanticChunk` for `node`, or `nil` if `node`'s range can't
    /// be resolved against `file.contents` (only possible for a malformed
    /// tree, not expected in practice).
    private static func makeChunk(
        node: Node,
        kind: SymbolMetaType,
        file: SourceFile,
        module: any LanguageModule.Type
    ) -> SemanticChunk? {
        guard let (text, range) = extractTextAndRange(of: node, in: file.contents) else {
            return nil
        }

        let startByte = file.contents.utf8.distance(from: file.contents.startIndex, to: range.lowerBound)
        let endByte = file.contents.utf8.distance(from: file.contents.startIndex, to: range.upperBound)
        let names = collectSymbolNames(node: node, file: file, module: module)
        let symbolPath = names.isEmpty ? (node.nodeType ?? "") : names.joined(separator: symbolPathSeparator)

        return SemanticChunk(
            filePath: file.relativePath,
            startByte: startByte,
            endByte: endByte,
            startLine: Int(node.pointRange.lowerBound.row),
            endLine: Int(node.pointRange.upperBound.row),
            text: text,
            symbolPath: symbolPath,
            kind: kind
        )
    }

    /// Collects `node`'s qualified symbol name components, outermost first.
    ///
    /// Port of the Rust reference's `collect_symbol_names`.
    private static func collectSymbolNames(node: Node, file: SourceFile, module: any LanguageModule.Type) -> [String] {
        var names: [String] = []
        collectSymbolNames(node: node, file: file, module: module, into: &names)
        return names.reversed()
    }

    /// Appends `node`'s own name (if any) to `names`, then walks up through
    /// ancestors — skipping intermediate wrapper nodes like a class body —
    /// until it finds one that is itself chunked or is a container, and
    /// recurses into that one.
    ///
    /// Port of the Rust reference's `collect_names_recursive`.
    private static func collectSymbolNames(
        node: Node,
        file: SourceFile,
        module: any LanguageModule.Type,
        into names: inout [String]
    ) {
        if let name = extractNodeName(node: node, file: file, module: module) {
            names.append(name)
        }

        var ancestor = node
        while let parent = ancestor.parent {
            let parentKind = parent.nodeType ?? ""
            if module.chunkKinds[parentKind] != nil || module.containerNodeKinds.contains(parentKind) {
                collectSymbolNames(node: parent, file: file, module: module, into: &names)
                return
            }
            ancestor = parent
        }
    }

    /// Extracts `node`'s own name via the `name`/`identifier`/`declarator`
    /// field heuristics, falling back to the Rust reference's `impl_item`
    /// special case (`"impl <Type>"`, from the `type` field). Returns `nil`
    /// if none apply.
    private static func extractNodeName(node: Node, file: SourceFile, module: any LanguageModule.Type) -> String? {
        for fieldName in nameFields {
            if let name = extractNameField(node: node, fieldName: fieldName, file: file) {
                return name
            }
        }

        if node.nodeType == "impl_item" {
            return extractImplTypeName(node: node, file: file)
        }

        return nil
    }

    /// Extracts and validates `fieldName`'s text on `node`, or `nil` if the
    /// field is absent or the text isn't a simple identifier (contains a
    /// space or exceeds `maxNameFieldLength`).
    private static func extractNameField(node: Node, fieldName: String, file: SourceFile) -> String? {
        guard let fieldNode = node.child(byFieldName: fieldName),
              let fieldText = extractText(of: fieldNode, in: file.contents),
              !fieldText.contains(" "),
              isValidSymbolText(text: fieldText, maxLength: maxNameFieldLength)
        else {
            return nil
        }
        return fieldText
    }

    /// Extracts an `impl` block's implemented type name from its `type`
    /// field, formatted as `"impl <Type>"`.
    ///
    /// Port of the Rust reference's `extract_impl_type_name`.
    private static func extractImplTypeName(node: Node, file: SourceFile) -> String? {
        guard let typeNode = node.child(byFieldName: "type"),
              let typeText = extractText(of: typeNode, in: file.contents),
              isValidSymbolText(text: typeText, maxLength: maxImplTypeNameLength)
        else {
            return nil
        }
        return "impl \(typeText)"
    }

    /// Validates that `text` is suitable for a symbol path component: no
    /// newline, and shorter than `maxLength`.
    ///
    /// Port of the Rust reference's `is_valid_symbol_text`.
    private static func isValidSymbolText(text: String, maxLength: Int) -> Bool {
        !text.contains("\n") && text.count < maxLength
    }

    /// Extracts `node`'s source text via its UTF-16-based `range`, converted
    /// to a `String` range against `source`.
    private static func extractText(of node: Node, in source: String) -> String? {
        extractTextAndRange(of: node, in: source)?.text
    }

    /// Resolves `node`'s UTF-16-based `range` to a `String` range against
    /// `source`, and extracts the text it spans.
    ///
    /// Shared by `makeChunk` (which also needs the `String.Index` range for
    /// its UTF-8 byte-offset math) and `extractText` (which only needs the
    /// text), so the two don't each reimplement the same
    /// `Range(node.range, in:)` conversion and `nil`-on-failure guard.
    private static func extractTextAndRange(
        of node: Node,
        in source: String
    ) -> (text: String, range: Range<String.Index>)? {
        guard let range = Range(node.range, in: source) else {
            return nil
        }
        return (String(source[range]), range)
    }
}

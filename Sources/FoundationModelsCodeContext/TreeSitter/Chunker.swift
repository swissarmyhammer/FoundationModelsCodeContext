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
    ///
    /// Not `private`: `SymbolOps` reuses this same separator when deriving
    /// a leaf name from a qualified `symbol_path` and when building the
    /// suffix-match pattern for `getSymbol`'s suffix tier, so the "." used
    /// to build a path and the "." used to search it never drift apart.
    static let symbolPathSeparator = "."

    /// How many levels the recursive tree-sitter walks in this module descend
    /// before they stop.
    ///
    /// A parse tree deeper than the running thread's stack does not raise a
    /// catchable error — it terminates the process. Hand-written source comes
    /// nowhere near that, but the walks are handed whatever is on disk, and
    /// machine-generated input reaches it easily: most grammars parse a long
    /// chained expression such as `a + b + c + …` into a left-nested binary
    /// spine one node deep per term.
    ///
    /// This is a deliberate cutoff, not a level nothing real reaches. `128`
    /// was picked against four measurements:
    ///
    /// - **Swift source in this repository reaches 39.** Parsing all 126
    ///   Swift files under `Sources/` and `Tests/` and taking the deepest AST
    ///   level in each tops out at 39.
    /// - **The 50-deep nested-`if` fixture reaches 106.** `swiftNestedIfs` in
    ///   the test target, whose innermost `if` holds a definition of its own,
    ///   is already far past anything a person writes and still fits.
    /// - **60 levels of nested YAML mappings reach 184.** The measurement
    ///   above is one grammar, and the shallow-AST conclusion does not carry
    ///   to the others: `YAMLLanguage.containerNodeKinds` nests about three
    ///   AST levels per indent level and `MarkdownLanguage`'s `section` nests
    ///   per heading level, so `128` corresponds to roughly 42 levels of YAML
    ///   indentation. Hand-written YAML is nowhere near that; generated YAML
    ///   past that depth loses the definitions below the bound, which is the
    ///   trade this constant exists to make.
    /// - **The stack dies between 448 and 512 frames.** Bisected in a debug
    ///   build on a Swift concurrency cooperative-pool thread, whose 512 KB
    ///   stack is the smallest these walks run on — `TreeSitterWorker` calls
    ///   `chunk(file:module:)` from an `async` context, so that is the real
    ///   budget, not the main thread's 8 MB. Measured when one level was one
    ///   `collectChunks` frame, and one level is still one frame — a shared
    ///   `walk(from:direction:context:astDepth:visit:)` frame in its place — so
    ///   the measurement carries over unchanged. A visitor's frame is not
    ///   stacked: `visit` returns before the walk descends, so at most one is
    ///   live at a time, at the deepest node reached. That lowered the metric
    ///   walk's peak rather than raising it: `Complexity.accumulate`'s wide
    ///   frame used to *be* the recursion chain and is now transient. `128`
    ///   keeps peak usage near a quarter of the budget.
    ///
    /// A 5000-term expression spine parses 5005 levels deep and is cut off
    /// long before it can do damage. Reaching the bound is not an error — each
    /// walk keeps what it found above the bound, matching this type's
    /// return-empty-rather-than-throw convention for unparseable files.
    ///
    /// Two of the walks count something other than absolute AST level, and
    /// both say so where they are started: `collectSymbolNames(node:file:module:)`
    /// walks `WalkDirection.nearestAncestor(matching:)`, where one level is one
    /// enclosing chunked-or-container node rather than one parent, and
    /// `Complexity.metrics(under:functionNodeKinds:)` starts its walk at the
    /// symbol it was asked to measure rather than at the parse root — so that
    /// walk can touch absolute levels past this number, while still only ever
    /// stacking `128` frames of its own.
    ///
    /// Not `private`: `Complexity` correlates the nodes its walk visits back to
    /// the chunks `chunk(file:module:)` produced — a correlation that only holds
    /// while both walks stop at the same depth — and the test target asserts
    /// against this same number. Every walk over a parse tree in this module
    /// runs through `walk(from:direction:context:astDepth:visit:)`, the one
    /// place the bound is applied, so no walk can drift away from it.
    static let maxASTDepth = 128

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
        guard let (_, root) = parseFile(contents: file.contents, module: module) else {
            return []
        }

        return collectChunks(root: root, file: file, module: module)
    }

    /// Parses `contents` with `module`'s tree-sitter grammar.
    ///
    /// Shared by `chunk(file:module:)` and
    /// `TSCallGraph.writeCallEdges(db:file:module:)`, which both need a
    /// parsed tree and its root node before walking it for their own node
    /// kinds — the parser-setup and parse-failure handling used to be
    /// duplicated verbatim between the two; it now lives here once so a
    /// fix to parsing behavior lands in both places at once.
    ///
    /// Not `private`: `TSCallGraph` calls through to this same helper
    /// rather than reimplementing parser setup.
    ///
    /// - Parameters:
    ///   - contents: The source text to parse.
    ///   - module: The language module supplying the grammar.
    /// - Returns: The parsed tree and its root node, or `nil` if `module`
    ///   has no `treeSitterLanguage`, the parser fails to accept the
    ///   grammar, or parsing fails to produce a tree with a root node.
    static func parseFile(contents: String, module: any LanguageModule.Type) -> (tree: MutableTree, root: Node)? {
        guard let language = module.treeSitterLanguage else {
            return nil
        }

        let parser = Parser()
        do {
            try parser.setLanguage(language)
        } catch {
            return nil
        }

        guard let tree = parser.parse(contents), let root = tree.rootNode else {
            return nil
        }

        return (tree, root)
    }

    /// Which nodes a bounded walk continues into after visiting one.
    ///
    /// Direction is the only structural difference between the walks over a
    /// parse tree in this module, which is what lets them all share
    /// `walk(from:direction:context:visit:)` instead of each carrying its own
    /// copy of the traversal and its own application of the `maxASTDepth`
    /// bound.
    enum WalkDirection {
        /// Every child of the visited node, named and anonymous alike, in
        /// order — so a definition nested inside another is still reached,
        /// whether or not the node enclosing it was itself of interest.
        ///
        /// One level is one AST level.
        case children

        /// The nearest ancestor `matches` accepts, with the ancestors between
        /// skipped rather than visited; the walk ends at the first visited node
        /// with no accepted ancestor above it.
        ///
        /// One level is one accepted ancestor, which is more than one AST level
        /// whenever any were skipped on the way to it.
        case nearestAncestor(matching: (Node) -> Bool)
    }

    /// Visits `node`, then everything `direction` leads to from it, stopping at
    /// `maxASTDepth`.
    ///
    /// The one bounded traversal behind every walk over a parse tree in this
    /// module: `chunk(file:module:)`'s chunk and symbol-name walks,
    /// `TSCallGraph.writeCallEdges(db:file:module:)`'s call-site walk, and
    /// `Complexity`'s node-index and metric walks. Each of them supplies what
    /// it does per node as `visit` and accumulates into what that closure
    /// captures, so the recursion, the depth counter, and the bound exist in
    /// exactly one place and cannot drift apart between the walks.
    ///
    /// Reaching the bound is not an error, and nothing is thrown: `visit` keeps
    /// whatever it gathered above it, matching this type's
    /// return-empty-rather-than-throw convention for input it cannot fully
    /// handle.
    ///
    /// Not `private`: `TSCallGraph` and `Complexity` walk parse trees through
    /// this same function rather than recursing themselves.
    ///
    /// - Parameters:
    ///   - node: The node to start from, itself visited first.
    ///   - direction: Which nodes to continue into after visiting one.
    ///   - context: The value `visit` is handed for `node` itself.
    ///   - visit: Called once per visited node, with the context the node above
    ///     it produced; returns the context the nodes below it are visited
    ///     with.
    static func walk<Context>(
        from node: Node,
        direction: WalkDirection,
        context: Context,
        visit: (Node, Context) -> Context
    ) {
        walk(from: node, direction: direction, context: context, astDepth: 0, visit: visit)
    }

    /// Visits `node`, then everything `direction` leads to from it, stopping at
    /// `maxASTDepth`, for a walk whose nodes need nothing from the nodes above
    /// them.
    ///
    /// - Parameters:
    ///   - node: The node to start from, itself visited first.
    ///   - direction: Which nodes to continue into after visiting one.
    ///   - visit: Called once per visited node.
    static func walk(from node: Node, direction: WalkDirection, visit: (Node) -> Void) {
        walk(from: node, direction: direction, context: ()) { visitedNode, _ in
            visit(visitedNode)
        }
    }

    /// Carries a walk one level, or stops it at `maxASTDepth`.
    ///
    /// - Parameters:
    ///   - node: The node to visit.
    ///   - direction: Which nodes to continue into after visiting `node`.
    ///   - context: The value `visit` is handed for `node`.
    ///   - astDepth: How many levels below the walk's starting node `node`
    ///     sits, counted in whatever unit `direction` advances by.
    ///   - visit: The per-node visitor.
    private static func walk<Context>(
        from node: Node,
        direction: WalkDirection,
        context: Context,
        astDepth: Int,
        visit: (Node, Context) -> Context
    ) {
        guard astDepth < maxASTDepth else {
            return
        }

        let nextContext = visit(node, context)

        switch direction {
        case .children:
            for childIndex in 0..<node.childCount {
                guard let child = node.child(at: childIndex) else {
                    continue
                }
                walk(
                    from: child, direction: direction, context: nextContext,
                    astDepth: astDepth + 1, visit: visit)
            }
        case .nearestAncestor(let matches):
            var descendant = node
            while let ancestor = descendant.parent {
                if matches(ancestor) {
                    walk(
                        from: ancestor, direction: direction, context: nextContext,
                        astDepth: astDepth + 1, visit: visit)
                    return
                }
                descendant = ancestor
            }
        }
    }

    /// Walks `root` and its descendants, collecting a `SemanticChunk` for every
    /// node whose kind is in `module.chunkKinds`.
    ///
    /// Port of the Rust reference's `extract_chunks_recursive`, which always
    /// recurses into every child — named and anonymous alike — regardless of
    /// whether the current node itself was chunked, so nested definitions
    /// (a method inside a class, a function inside a module) are still
    /// found. `WalkDirection.children` is that same traversal.
    ///
    /// - Parameters:
    ///   - root: The node to walk, itself included.
    ///   - file: The source file `root` was parsed from.
    ///   - module: The language module supplying the chunk-kind table.
    /// - Returns: One chunk per matched definition node, in AST traversal
    ///   order — the ones found above `maxASTDepth` if the tree runs deeper
    ///   than the bound.
    private static func collectChunks(
        root: Node,
        file: SourceFile,
        module: any LanguageModule.Type
    ) -> [SemanticChunk] {
        var chunks: [SemanticChunk] = []
        walk(from: root, direction: .children) { node in
            if let kind = module.chunkKinds[node.nodeType ?? ""],
               let chunk = makeChunk(node: node, kind: kind, file: file, module: module)
            {
                chunks.append(chunk)
            }
        }
        return chunks
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
        guard let (text, startByte, endByte) = extractTextAndRange(of: node, in: file.contents) else {
            return nil
        }

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

    /// Collects `node`'s qualified symbol name components, outermost first:
    /// `node`'s own name (if any), then the name of each enclosing definition
    /// or container above it.
    ///
    /// Port of the Rust reference's `collect_symbol_names` and its
    /// `collect_names_recursive`, which climbs past intermediate wrapper nodes
    /// like a class body rather than naming them —
    /// `WalkDirection.nearestAncestor(matching:)` is that same climb, with
    /// `qualifiesSymbolPath(node:module:)` deciding which ancestors count.
    ///
    /// Stops climbing at `maxASTDepth` without throwing: the components
    /// gathered so far still form the symbol path, which is a shorter
    /// qualification rather than an error. That bound is defensive rather than
    /// load-bearing here: the only caller is `makeChunk`, reached from
    /// `collectChunks`, which itself only descends to `maxASTDepth`, and each
    /// climb consumes at least one AST level — so this walk can never reach
    /// deeper than the downward walk already stopped at.
    ///
    /// - Parameters:
    ///   - node: The node whose qualified name to collect.
    ///   - file: The source file `node` was parsed from.
    ///   - module: The language module supplying the chunk-kind and container
    ///     tables.
    /// - Returns: The name components, outermost first; empty if neither `node`
    ///   nor any enclosing definition has a name.
    private static func collectSymbolNames(node: Node, file: SourceFile, module: any LanguageModule.Type) -> [String] {
        var names: [String] = []
        let direction = WalkDirection.nearestAncestor(matching: { ancestor in
            qualifiesSymbolPath(node: ancestor, module: module)
        })
        walk(from: node, direction: direction) { named in
            if let name = extractNodeName(node: named, file: file, module: module) {
                names.append(name)
            }
        }
        return names.reversed()
    }

    /// Whether `node` contributes a component to a nested definition's
    /// qualified symbol path, which is what makes it one level of the climb
    /// `collectSymbolNames(node:file:module:)` makes.
    ///
    /// A container counts as well as a definition, and a container need not be
    /// a definition at all — `YAMLLanguage` counts a `block_mapping`,
    /// `MarkdownLanguage` a `section`.
    ///
    /// - Parameters:
    ///   - node: The ancestor node to test.
    ///   - module: The language module supplying the chunk-kind and container
    ///     tables.
    /// - Returns: `true` if `node`'s kind is in either table.
    private static func qualifiesSymbolPath(node: Node, module: any LanguageModule.Type) -> Bool {
        let kind = node.nodeType ?? ""
        return module.chunkKinds[kind] != nil || module.containerNodeKinds.contains(kind)
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
    /// `source`, and extracts both the text it spans and its UTF-8
    /// byte-offset bounds.
    ///
    /// Shared by `makeChunk` (which needs both the text and the byte
    /// offsets) and `extractText` (which only needs the text), so the two
    /// don't each reimplement the same `Range(node.range, in:)` conversion,
    /// `nil`-on-failure guard, and `utf8.distance(from:to:)` byte-offset
    /// math.
    ///
    /// Not `private`: `QueryAST` reuses this same UTF-16-NSRange-to-UTF-8
    /// conversion for its captures' text and byte offsets, and `TSCallGraph`
    /// reuses it for a call site's own range and its callee sub-node's text,
    /// so the three tree-sitter consumers in this module don't each carry
    /// their own copy of the conversion.
    internal static func extractTextAndRange(
        of node: Node,
        in source: String
    ) -> (text: String, startByte: Int, endByte: Int)? {
        guard let range = Range(node.range, in: source) else {
            return nil
        }
        let startByte = source.utf8.distance(from: source.startIndex, to: range.lowerBound)
        let endByte = source.utf8.distance(from: source.startIndex, to: range.upperBound)
        return (String(source[range]), startByte, endByte)
    }
}

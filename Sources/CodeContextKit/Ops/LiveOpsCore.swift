import Foundation
import GRDB

// ---------------------------------------------------------------------------
// Result types
// ---------------------------------------------------------------------------

/// A location where a symbol is defined (or implemented), with optional
/// source text and enriched symbol info.
///
/// Shared by `LiveOpsCore.definition`, `LiveOpsCore.typeDefinition`, and
/// `LiveOpsCore.implementations` — all three ops resolve to the same
/// "file + range + optional source + optional symbol" shape, so this port
/// uses one type where the Rust reference declares
/// `DefinitionLocation`/`GetTypeDefinitionResult` separately for an identical
/// shape (see `crates/swissarmyhammer-code-context/src/ops/get_type_definition.rs`).
struct DefinitionLocation: Codable, Sendable, Equatable {
    /// The file containing the location, relative to the workspace root.
    let filePath: String

    /// The location's span.
    let range: LSPRange

    /// The source text at `range`, read from disk, if requested.
    let sourceText: String?

    /// The enclosing symbol, if known from the LSP index or tree-sitter.
    let symbol: LayeredSymbolInfo?
}

/// Result of `LiveOpsCore.definition`/`LiveOpsCore.typeDefinition`.
struct DefinitionResult: Codable, Sendable, Equatable {
    /// The definition locations found — empty (never an error) when no layer has data.
    let locations: [DefinitionLocation]

    /// Which data layer provided the result.
    let sourceLayer: SourceLayer
}

/// Result of `LiveOpsCore.hover`.
struct HoverResult: Codable, Sendable, Equatable {
    /// The hover content (markdown, type signature, or source text) — empty
    /// (never an error) when no layer has data.
    let contents: String

    /// The range the hover applies to, if available.
    let range: LSPRange?

    /// Symbol information from the layer, if available.
    let symbol: LayeredSymbolInfo?

    /// Which data layer provided the result.
    let sourceLayer: SourceLayer
}

/// A single reference location with its enclosing symbol.
struct ReferenceLocation: Codable, Sendable, Equatable {
    /// The file containing the reference, relative to the workspace root.
    let filePath: String

    /// The reference's span.
    let range: LSPRange

    /// The enclosing symbol (e.g. the function this reference is inside), if known.
    let enclosingSymbol: LayeredSymbolInfo?
}

/// References grouped by file path.
struct FileReferenceGroup: Codable, Sendable, Equatable {
    /// The file path shared by every reference in this group.
    let filePath: String

    /// References within this file.
    let references: [ReferenceLocation]
}

/// Result of `LiveOpsCore.references`.
struct ReferencesResult: Codable, Sendable, Equatable {
    /// Every reference location (after truncation by `maxResults`).
    let references: [ReferenceLocation]

    /// The total number of references found before truncation.
    let totalCount: Int

    /// References grouped by file.
    let byFile: [FileReferenceGroup]

    /// Which data layer provided the results.
    let sourceLayer: SourceLayer
}

/// Result of `LiveOpsCore.implementations`.
struct ImplementationsResult: Codable, Sendable, Equatable {
    /// The implementation locations found — empty (never an error) when no layer has data.
    let implementations: [DefinitionLocation]

    /// Which data layer provided the results.
    let sourceLayer: SourceLayer
}

// ---------------------------------------------------------------------------
// LiveOpsCore
// ---------------------------------------------------------------------------

/// The five core live code-intelligence ops — `definition`, `typeDefinition`,
/// `hover`, `references`, `implementations` — each resolved through the same
/// three-layer cascade in priority order:
///
/// 1. **Live LSP** — syncs the current disk text to the shared `LspSession`
///    (`syncOpen`), then issues the op's typed live request.
/// 2. **LSP index** — looks up persisted `lsp_symbols`/`lsp_call_edges` data
///    via `LayeredContext`.
/// 3. **Tree-sitter** — falls back to the persisted `ts_chunks` index via
///    `LayeredContext`.
/// 4. **None** — an empty result tagged `SourceLayer.none`. Never an error:
///    "no data at this location" is a valid, common answer, not a failure.
///
/// Each op returns a `Codable & Sendable` result carrying its `sourceLayer`,
/// so a caller (or a test) always knows which layer answered.
///
/// Port of the Rust `swissarmyhammer-code-context::ops::{get_definition,
/// get_type_definition, get_hover, get_references, get_implementations}`
/// modules, cascaded through `LayeredContext` — with two deliberate
/// divergences from the Rust reference, both required by this task:
///
/// - **Both follower-router seams are removed.** The Rust reference's
///   `LayeredContext` can serve its live-LSP layer either from an in-process
///   `SharedLspSession` or, on a process with no session of its own, by
///   routing requests to another process's session over IPC
///   (`LiveLspRouter`/`MultiLspRouter`). This Swift port has no such
///   cross-process leader/follower topology, so every op here takes a plain
///   `LspSession<Connection>?` — `nil` when no live layer is available, a
///   real session otherwise — with no routing seam to bridge.
/// - **Every op cascades through all three layers uniformly**, including
///   `typeDefinition` and `implementations`. The Rust reference restricts
///   `get_type_definition` to live LSP only (no index fallback at all) and
///   skips the LSP-index layer entirely for `get_implementations` ("no
///   equivalent relationship stored"). This port's schema draws no such
///   distinction — `lsp_symbols`/`ts_chunks` describe *a* symbol at a
///   location regardless of which specific LSP capability asked for it — so
///   this port's `typeDefinition` reuses exactly the same layer-2/3 lookup as
///   `definition` (see `DefinitionResult`'s doc comment), and
///   `implementations`' layer-2 answer is the cursor's own declaring symbol
///   (a degenerate but consistent answer) rather than being skipped
///   outright. This keeps the four-layer contract uniform across all five
///   ops, matching this task's acceptance criteria.
enum LiveOpsCore<Connection: LanguageServerConnection> {
    // MARK: - Cascade

    /// Runs the shared three-branch fallback every op follows: try the live
    /// layer, then the persisted layers, then fall back to an explicit empty
    /// result.
    ///
    /// `liveLayer` and `indexedLayers` each return `nil` to signal "this
    /// layer had nothing, try the next one" — a thrown error, by contrast,
    /// propagates immediately rather than falling through, so a genuine
    /// storage failure is never silently swallowed as "no data" (only a
    /// live-LSP connection failure is, inside each op's own `liveLayer`
    /// closure — see e.g. `liveDefinition`).
    ///
    /// - Parameters:
    ///   - liveLayer: Attempts the live-LSP layer; swallows connection
    ///     failures into `nil` itself.
    ///   - indexedLayers: Attempts the LSP-index layer, then tree-sitter, in
    ///     one closure (typically one `Store.read` covering both).
    ///   - empty: Builds the `SourceLayer.none` result when neither layer had data.
    /// - Returns: The first layer's result, or `empty()`.
    /// - Throws: Rethrows whatever `liveLayer`/`indexedLayers` throw.
    ///
    /// Not `private`: `LiveOpsExtended` (`Ops/LiveOpsExtended.swift`) reuses
    /// this exact cascade shape for `codeActions`/`inboundCalls` rather than
    /// duplicating it, matching this type's own "every op cascades
    /// uniformly" design (see this type's doc comment).
    static func cascade<T: Sendable>(
        liveLayer: () async throws -> T?,
        indexedLayers: () async throws -> T?,
        empty: () -> T
    ) async throws -> T {
        if let live = try await liveLayer() {
            return live
        }
        if let indexed = try await indexedLayers() {
            return indexed
        }
        return empty()
    }

    // MARK: - definition

    /// Finds the definition site(s) of the symbol at a position.
    ///
    /// - Parameters:
    ///   - store: The workspace's index store to query.
    ///   - session: The live session to query, or `nil` if no live layer is available.
    ///   - rootDirectory: The workspace root `filePath` is relative to.
    ///   - filePath: The file containing the cursor position, relative to `rootDirectory`.
    ///   - line: The zero-based cursor line.
    ///   - character: The zero-based cursor character offset.
    ///   - includeSource: Whether to read and include source text from disk at each location.
    /// - Returns: The definition locations, tagged with the layer that produced them.
    /// - Throws: Rethrows `Store`'s storage errors.
    static func definition(
        store: Store,
        session: LspSession<Connection>?,
        rootDirectory: URL,
        filePath: String,
        line: Int,
        character: Int,
        includeSource: Bool = false
    ) async throws -> DefinitionResult {
        try await cascade(
            liveLayer: {
                try await liveDefinition(
                    session: session, store: store, rootDirectory: rootDirectory,
                    filePath: filePath, line: line, character: character, includeSource: includeSource,
                    method: { try await $0.definition(uri: $1, at: $2) }
                )
            },
            indexedLayers: {
                try await indexedDefinition(store: store, rootDirectory: rootDirectory, filePath: filePath, line: line, character: character, includeSource: includeSource)
            },
            empty: { DefinitionResult(locations: [], sourceLayer: .none) }
        )
    }

    // MARK: - typeDefinition

    /// Finds the type-definition site(s) of the symbol at a position.
    ///
    /// Reuses `definition`'s layer-2/3 lookup — see `LiveOpsCore`'s
    /// type-level doc comment for why this port draws no distinction between
    /// "definition" and "type definition" data in the persisted layers.
    ///
    /// - Parameters:
    ///   - store: The workspace's index store to query.
    ///   - session: The live session to query, or `nil` if no live layer is available.
    ///   - rootDirectory: The workspace root `filePath` is relative to.
    ///   - filePath: The file containing the cursor position, relative to `rootDirectory`.
    ///   - line: The zero-based cursor line.
    ///   - character: The zero-based cursor character offset.
    ///   - includeSource: Whether to read and include source text from disk at each location.
    /// - Returns: The type-definition locations, tagged with the layer that produced them.
    /// - Throws: Rethrows `Store`'s storage errors.
    static func typeDefinition(
        store: Store,
        session: LspSession<Connection>?,
        rootDirectory: URL,
        filePath: String,
        line: Int,
        character: Int,
        includeSource: Bool = false
    ) async throws -> DefinitionResult {
        try await cascade(
            liveLayer: {
                try await liveDefinition(
                    session: session, store: store, rootDirectory: rootDirectory,
                    filePath: filePath, line: line, character: character, includeSource: includeSource,
                    method: { try await $0.typeDefinition(uri: $1, at: $2) }
                )
            },
            indexedLayers: {
                try await indexedDefinition(store: store, rootDirectory: rootDirectory, filePath: filePath, line: line, character: character, includeSource: includeSource)
            },
            empty: { DefinitionResult(locations: [], sourceLayer: .none) }
        )
    }

    /// Shared live-layer implementation for `definition`/`typeDefinition`,
    /// parameterized by which typed `LspSession` method to call.
    ///
    /// Returns `nil` (triggering fallback) when: there is no session,
    /// `syncOpen` or the live request fails (a connection failure — see
    /// `LiveOpsCore`'s type-level doc comment on never surfacing these), or
    /// the live request answers with zero locations.
    private static func liveDefinition(
        session: LspSession<Connection>?,
        store: Store,
        rootDirectory: URL,
        filePath: String,
        line: Int,
        character: Int,
        includeSource: Bool,
        method: (LspSession<Connection>, DocumentURI, Position) async throws -> [Location]
    ) async throws -> DefinitionResult? {
        guard let session, let uri = await syncLiveDocument(session: session, rootDirectory: rootDirectory, filePath: filePath) else {
            return nil
        }
        let rawLocations: [Location]
        do {
            rawLocations = try await method(session, uri, Position(line: line, character: character))
        } catch {
            return nil
        }
        guard !rawLocations.isEmpty else { return nil }

        let locations = try await store.read { db in
            try rawLocations.map { location -> DefinitionLocation in
                let path = RelativePath.relativeFilePath(fromURI: location.uri, rootDirectory: rootDirectory)
                let sourceText = includeSource ? readSourceRange(rootDirectory: rootDirectory, filePath: path, range: location.range) : nil
                let symbol = try LayeredContext.enrichLocation(db: db, filePath: path, range: location.range).symbol
                return DefinitionLocation(filePath: path, range: location.range, sourceText: sourceText, symbol: symbol)
            }
        }
        return DefinitionResult(locations: locations, sourceLayer: .liveLSP)
    }

    /// Shared indexed-layer implementation for `definition`/`typeDefinition`:
    /// the LSP-index symbol at the cursor, else the tree-sitter chunk at the
    /// cursor's line.
    private static func indexedDefinition(
        store: Store,
        rootDirectory: URL,
        filePath: String,
        line: Int,
        character: Int,
        includeSource: Bool
    ) async throws -> DefinitionResult? {
        try await store.read { db in
            try indexedLookup(
                db: db, filePath: filePath, line: line, character: character,
                fromSymbol: { symbol in
                    let sourceText = includeSource ? readSourceRange(rootDirectory: rootDirectory, filePath: symbol.filePath, range: symbol.range) : nil
                    let location = DefinitionLocation(filePath: symbol.filePath, range: symbol.range, sourceText: sourceText, symbol: symbol)
                    return DefinitionResult(locations: [location], sourceLayer: .lspIndex)
                },
                fromChunk: { chunk in
                    let range = LSPRange(start: Position(line: chunk.startLine, character: 0), end: Position(line: chunk.endLine, character: 0))
                    let location = DefinitionLocation(filePath: filePath, range: range, sourceText: includeSource ? chunk.text : nil, symbol: nil)
                    return DefinitionResult(locations: [location], sourceLayer: .treeSitter)
                }
            )
        }
    }

    // MARK: - hover

    /// Finds hover information for the symbol at a position.
    ///
    /// - Parameters:
    ///   - store: The workspace's index store to query.
    ///   - session: The live session to query, or `nil` if no live layer is available.
    ///   - rootDirectory: The workspace root `filePath` is relative to.
    ///   - filePath: The file containing the cursor position, relative to `rootDirectory`.
    ///   - line: The zero-based cursor line.
    ///   - character: The zero-based cursor character offset.
    /// - Returns: The hover result, tagged with the layer that produced it.
    /// - Throws: Rethrows `Store`'s storage errors.
    static func hover(
        store: Store,
        session: LspSession<Connection>?,
        rootDirectory: URL,
        filePath: String,
        line: Int,
        character: Int
    ) async throws -> HoverResult {
        try await cascade(
            liveLayer: {
                try await liveHover(session: session, store: store, rootDirectory: rootDirectory, filePath: filePath, line: line, character: character)
            },
            indexedLayers: {
                try await indexedHover(store: store, filePath: filePath, line: line, character: character)
            },
            empty: { HoverResult(contents: "", range: nil, symbol: nil, sourceLayer: .none) }
        )
    }

    private static func liveHover(
        session: LspSession<Connection>?,
        store: Store,
        rootDirectory: URL,
        filePath: String,
        line: Int,
        character: Int
    ) async throws -> HoverResult? {
        guard let session, let uri = await syncLiveDocument(session: session, rootDirectory: rootDirectory, filePath: filePath) else {
            return nil
        }
        let hover: Hover?
        do {
            hover = try await session.hover(uri: uri, at: Position(line: line, character: character))
        } catch {
            return nil
        }
        guard let hover, !hover.contents.isEmpty else { return nil }

        var symbol: LayeredSymbolInfo?
        if let range = hover.range {
            symbol = try await store.read { db in try LayeredContext.enrichLocation(db: db, filePath: filePath, range: range).symbol }
        }
        return HoverResult(contents: hover.contents, range: hover.range, symbol: symbol, sourceLayer: .liveLSP)
    }

    private static func indexedHover(store: Store, filePath: String, line: Int, character: Int) async throws -> HoverResult? {
        try await store.read { db in
            try indexedLookup(
                db: db, filePath: filePath, line: line, character: character,
                fromSymbol: { symbol in
                    let contents = symbol.detail ?? "\(symbol.name) (\(symbol.kind))"
                    return HoverResult(contents: contents, range: symbol.range, symbol: symbol, sourceLayer: .lspIndex)
                },
                fromChunk: { chunk in
                    let range = LSPRange(start: Position(line: chunk.startLine, character: 0), end: Position(line: chunk.endLine, character: 0))
                    return HoverResult(contents: chunk.text, range: range, symbol: nil, sourceLayer: .treeSitter)
                }
            )
        }
    }

    /// Shared "LSP-index symbol at the cursor, else the tree-sitter chunk at
    /// the cursor's line, else no data" lookup used by both
    /// `indexedDefinition` and `indexedHover` — the two layer-2/3 helpers
    /// whose only difference was this control structure's per-branch result
    /// construction.
    ///
    /// - Parameters:
    ///   - db: The database connection to query.
    ///   - filePath: The file containing the cursor position.
    ///   - line: The zero-based cursor line.
    ///   - character: The zero-based cursor character offset.
    ///   - fromSymbol: Builds the result from an `lsp_symbols` match.
    ///   - fromChunk: Builds the result from a `ts_chunks` match, tried only when `fromSymbol` had none.
    /// - Returns: `fromSymbol`'s result, else `fromChunk`'s, else `nil` when neither layer matched.
    /// - Throws: Rethrows whatever the underlying `LayeredContext` queries or the closures throw.
    private static func indexedLookup<T>(
        db: Database,
        filePath: String,
        line: Int,
        character: Int,
        fromSymbol: (LayeredSymbolInfo) throws -> T,
        fromChunk: (LayeredChunkInfo) throws -> T
    ) throws -> T? {
        let range = pointRange(line: line, character: character)
        if let symbol = try LayeredContext.lspSymbolAt(db: db, filePath: filePath, range: range) {
            return try fromSymbol(symbol)
        }
        if let chunk = try LayeredContext.tsChunkAt(db: db, filePath: filePath, line: line) {
            return try fromChunk(chunk)
        }
        return nil
    }

    // MARK: - references

    /// Finds every reference to the symbol at a position.
    ///
    /// - Parameters:
    ///   - store: The workspace's index store to query.
    ///   - session: The live session to query, or `nil` if no live layer is available.
    ///   - rootDirectory: The workspace root `filePath` is relative to.
    ///   - filePath: The file containing the cursor position, relative to `rootDirectory`.
    ///   - line: The zero-based cursor line.
    ///   - character: The zero-based cursor character offset.
    ///   - includeDeclaration: Whether the declaration site itself should be included (live layer only).
    ///   - maxResults: The maximum number of references to return, or `nil` for unlimited.
    /// - Returns: The references result, tagged with the layer that produced it.
    /// - Throws: Rethrows `Store`'s storage errors.
    static func references(
        store: Store,
        session: LspSession<Connection>?,
        rootDirectory: URL,
        filePath: String,
        line: Int,
        character: Int,
        includeDeclaration: Bool = false,
        maxResults: Int? = nil
    ) async throws -> ReferencesResult {
        try await cascade(
            liveLayer: {
                try await liveReferences(
                    session: session, store: store, rootDirectory: rootDirectory, filePath: filePath,
                    line: line, character: character, includeDeclaration: includeDeclaration, maxResults: maxResults
                )
            },
            indexedLayers: {
                try await indexedReferences(store: store, filePath: filePath, line: line, character: character, maxResults: maxResults)
            },
            empty: { ReferencesResult(references: [], totalCount: 0, byFile: [], sourceLayer: .none) }
        )
    }

    private static func liveReferences(
        session: LspSession<Connection>?,
        store: Store,
        rootDirectory: URL,
        filePath: String,
        line: Int,
        character: Int,
        includeDeclaration: Bool,
        maxResults: Int?
    ) async throws -> ReferencesResult? {
        guard let session, let uri = await syncLiveDocument(session: session, rootDirectory: rootDirectory, filePath: filePath) else {
            return nil
        }
        let rawLocations: [Location]
        do {
            rawLocations = try await session.references(uri: uri, at: Position(line: line, character: character), includeDeclaration: includeDeclaration)
        } catch {
            return nil
        }
        guard !rawLocations.isEmpty else { return nil }

        let references = try await store.read { db in
            try rawLocations.map { location -> ReferenceLocation in
                let path = RelativePath.relativeFilePath(fromURI: location.uri, rootDirectory: rootDirectory)
                let symbol = try LayeredContext.enrichLocation(db: db, filePath: path, range: location.range).symbol
                return ReferenceLocation(filePath: path, range: location.range, enclosingSymbol: symbol)
            }
        }
        return buildReferencesResult(references: references, maxResults: maxResults, sourceLayer: .liveLSP)
    }

    private static func indexedReferences(store: Store, filePath: String, line: Int, character: Int, maxResults: Int?) async throws -> ReferencesResult? {
        try await store.read { db in
            if let result = try tryLspIndexReferences(db: db, filePath: filePath, line: line, character: character, maxResults: maxResults) {
                return result
            }
            return try tryTreeSitterReferences(db: db, filePath: filePath, line: line, maxResults: maxResults)
        }
    }

    /// Layer 2 for `references`: the symbol at the cursor, then every caller
    /// recorded against it in `lsp_call_edges`, one reference per call site
    /// (or the caller's own range, when no call sites were recorded for an edge).
    private static func tryLspIndexReferences(db: Database, filePath: String, line: Int, character: Int, maxResults: Int?) throws -> ReferencesResult? {
        let range = pointRange(line: line, character: character)
        guard let row = try LayeredContext.lspSymbolRow(db: db, filePath: filePath, range: range) else { return nil }
        let callers = try LayeredContext.lspCallersOf(db: db, symbolID: row.id)
        guard !callers.isEmpty else { return nil }

        var rawLocations: [(filePath: String, range: LSPRange)] = []
        for caller in callers {
            if caller.callSites.isEmpty {
                rawLocations.append((caller.symbol.filePath, caller.symbol.range))
            } else {
                rawLocations.append(contentsOf: caller.callSites.map { (caller.symbol.filePath, $0) })
            }
        }

        let references = try rawLocations.map { location -> ReferenceLocation in
            let symbol = try LayeredContext.enrichLocation(db: db, filePath: location.filePath, range: location.range).symbol
            return ReferenceLocation(filePath: location.filePath, range: location.range, enclosingSymbol: symbol)
        }
        return buildReferencesResult(references: references, maxResults: maxResults, sourceLayer: .lspIndex)
    }

    /// Layer 3 for `references`: extracts an identifier from the chunk at the
    /// cursor's line, then searches every chunk's text for that identifier.
    ///
    /// Returns a `SourceLayer.treeSitter` result whenever a chunk and
    /// identifier were found at the cursor — even if the subsequent search
    /// matched nothing — matching the Rust reference's `try_treesitter`,
    /// which is unconditional once a search term exists. Only "no chunk (or
    /// no identifiable token) at the cursor at all" falls through to `nil`
    /// (the cascade's own `SourceLayer.none`).
    private static func tryTreeSitterReferences(db: Database, filePath: String, line: Int, maxResults: Int?) throws -> ReferencesResult? {
        guard
            let chunk = try LayeredContext.tsChunkAt(db: db, filePath: filePath, line: line),
            let searchTerm = extractIdentifier(atLine: line, chunkText: chunk.text, chunkStartLine: chunk.startLine)
        else {
            return nil
        }

        let searchLimit = maxResults.map { $0 * 3 } ?? 200
        let chunks = try LayeredContext.tsChunksMatching(db: db, query: searchTerm, max: searchLimit)
        let references = try chunks.map { matched -> ReferenceLocation in
            let range = LSPRange(start: Position(line: matched.startLine, character: 0), end: Position(line: matched.startLine, character: 0))
            let symbol = try LayeredContext.enrichLocation(db: db, filePath: matched.filePath, range: range).symbol
            return ReferenceLocation(filePath: matched.filePath, range: range, enclosingSymbol: symbol)
        }
        return buildReferencesResult(references: references, maxResults: maxResults, sourceLayer: .treeSitter)
    }

    /// Builds the final `ReferencesResult`, truncating to `maxResults` and grouping by file.
    private static func buildReferencesResult(references: [ReferenceLocation], maxResults: Int?, sourceLayer: SourceLayer) -> ReferencesResult {
        let totalCount = references.count
        let truncated: [ReferenceLocation]
        if let maxResults, references.count > maxResults {
            truncated = Array(references.prefix(maxResults))
        } else {
            truncated = references
        }
        return ReferencesResult(references: truncated, totalCount: totalCount, byFile: groupByFile(truncated), sourceLayer: sourceLayer)
    }

    /// Groups reference locations by file path, sorted by file path
    /// ascending (matching the Rust reference's `BTreeMap<&str, _>` grouping,
    /// which iterates in sorted-key rather than insertion order) — each
    /// group's own references keep their original relative order.
    private static func groupByFile(_ references: [ReferenceLocation]) -> [FileReferenceGroup] {
        var groups: [String: [ReferenceLocation]] = [:]
        for reference in references {
            groups[reference.filePath, default: []].append(reference)
        }
        return groups.keys.sorted().map { FileReferenceGroup(filePath: $0, references: groups[$0] ?? []) }
    }

    /// Extracts an identifier from `chunkText`'s line at `atLine`, using a
    /// simple heuristic: the longest word-like (alphanumeric + underscore,
    /// starting with a letter or underscore) token on that line.
    ///
    /// Port of the Rust reference's `extract_identifier_at_line`.
    ///
    /// - Parameters:
    ///   - atLine: The target zero-based line, in the same coordinate space as `chunkStartLine`.
    ///   - chunkText: The chunk's full source text.
    ///   - chunkStartLine: The chunk's zero-based start line.
    /// - Returns: The longest word-like token on the target line, or `nil` if
    ///   the line is out of the chunk's bounds or has no identifiable token.
    private static func extractIdentifier(atLine: Int, chunkText: String, chunkStartLine: Int) -> String? {
        let lineOffset = atLine - chunkStartLine
        let lines = chunkText.components(separatedBy: "\n")
        guard lineOffset >= 0, lineOffset < lines.count else { return nil }
        let line = lines[lineOffset]

        let tokens = line.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") })
            .filter { token in
                guard let first = token.first else { return false }
                return first.isLetter || first == "_"
            }
        return tokens.max(by: { $0.count < $1.count }).map(String.init)
    }

    // MARK: - implementations

    /// Finds every implementation of the symbol (typically a trait/interface) at a position.
    ///
    /// - Parameters:
    ///   - store: The workspace's index store to query.
    ///   - session: The live session to query, or `nil` if no live layer is available.
    ///   - rootDirectory: The workspace root `filePath` is relative to.
    ///   - filePath: The file containing the cursor position, relative to `rootDirectory`.
    ///   - line: The zero-based cursor line.
    ///   - character: The zero-based cursor character offset.
    ///   - includeSource: Whether to read and include source text from disk at each location.
    ///   - maxResults: The maximum number of results to return. Defaults to `defaultMaxImplementations`.
    /// - Returns: The implementations result, tagged with the layer that produced it.
    /// - Throws: Rethrows `Store`'s storage errors.
    static func implementations(
        store: Store,
        session: LspSession<Connection>?,
        rootDirectory: URL,
        filePath: String,
        line: Int,
        character: Int,
        includeSource: Bool = false,
        maxResults: Int = defaultMaxImplementations
    ) async throws -> ImplementationsResult {
        try await cascade(
            liveLayer: {
                try await liveImplementations(
                    session: session, store: store, rootDirectory: rootDirectory, filePath: filePath,
                    line: line, character: character, includeSource: includeSource, maxResults: maxResults
                )
            },
            indexedLayers: {
                try await indexedImplementations(
                    store: store, rootDirectory: rootDirectory, filePath: filePath, line: line, character: character,
                    includeSource: includeSource, maxResults: maxResults
                )
            },
            empty: { ImplementationsResult(implementations: [], sourceLayer: .none) }
        )
    }

    /// Default cap on implementation results, mirroring the Rust reference's `DEFAULT_MAX_IMPLEMENTATIONS`.
    private static var defaultMaxImplementations: Int { 20 }

    private static func liveImplementations(
        session: LspSession<Connection>?,
        store: Store,
        rootDirectory: URL,
        filePath: String,
        line: Int,
        character: Int,
        includeSource: Bool,
        maxResults: Int
    ) async throws -> ImplementationsResult? {
        guard let session, let uri = await syncLiveDocument(session: session, rootDirectory: rootDirectory, filePath: filePath) else {
            return nil
        }
        let rawLocations: [Location]
        do {
            rawLocations = try await session.implementations(uri: uri, at: Position(line: line, character: character))
        } catch {
            return nil
        }
        guard !rawLocations.isEmpty else { return nil }

        let implementations = try await store.read { db in
            try rawLocations.prefix(maxResults).map { location -> DefinitionLocation in
                let path = RelativePath.relativeFilePath(fromURI: location.uri, rootDirectory: rootDirectory)
                let sourceText = includeSource ? readSourceRange(rootDirectory: rootDirectory, filePath: path, range: location.range) : nil
                let symbol = try LayeredContext.enrichLocation(db: db, filePath: path, range: location.range).symbol
                return DefinitionLocation(filePath: path, range: location.range, sourceText: sourceText, symbol: symbol)
            }
        }
        return ImplementationsResult(implementations: implementations, sourceLayer: .liveLSP)
    }

    /// Layer 2/3 for `implementations`.
    ///
    /// Layer 2 (LSP index) reuses the cursor's own declaring symbol as a
    /// single, degenerate "implementation" — see `LiveOpsCore`'s type-level
    /// doc comment for why this port doesn't skip the index layer here the
    /// way the Rust reference does. Layer 3 (tree-sitter) keeps the Rust
    /// reference's actual heuristic: resolve the cursor's symbol name (via
    /// `enrichLocation`, which by this point can only resolve through
    /// tree-sitter — layer 2 already found nothing) and search chunk text
    /// for `"impl <name>"`.
    ///
    /// `sourceText` is gated on `includeSource` uniformly across both
    /// layers here (and the live layer above), matching
    /// `definition`/`typeDefinition`'s contract: a caller controls whether
    /// source text is populated, rather than it varying by which layer
    /// happened to answer.
    private static func indexedImplementations(
        store: Store,
        rootDirectory: URL,
        filePath: String,
        line: Int,
        character: Int,
        includeSource: Bool,
        maxResults: Int
    ) async throws -> ImplementationsResult? {
        try await store.read { db in
            let range = pointRange(line: line, character: character)
            if let symbol = try LayeredContext.lspSymbolAt(db: db, filePath: filePath, range: range) {
                let sourceText = includeSource ? readSourceRange(rootDirectory: rootDirectory, filePath: symbol.filePath, range: symbol.range) : nil
                let location = DefinitionLocation(filePath: symbol.filePath, range: symbol.range, sourceText: sourceText, symbol: symbol)
                return ImplementationsResult(implementations: [location], sourceLayer: .lspIndex)
            }

            guard let name = try LayeredContext.enrichLocation(db: db, filePath: filePath, range: range).symbol?.name else {
                return nil
            }
            let chunks = try LayeredContext.tsChunksMatching(db: db, query: "impl \(name)", max: maxResults)
            guard !chunks.isEmpty else { return nil }

            let implementations = chunks.map { chunk -> DefinitionLocation in
                let chunkRange = LSPRange(start: Position(line: chunk.startLine, character: 0), end: Position(line: chunk.endLine, character: 0))
                let symbol = LayeredSymbolInfo(
                    name: SymbolOps.leafName(ofQualifiedPath: chunk.symbolPath),
                    qualifiedPath: chunk.symbolPath,
                    kind: chunk.kind,
                    detail: nil,
                    filePath: chunk.filePath,
                    range: chunkRange
                )
                return DefinitionLocation(filePath: chunk.filePath, range: chunkRange, sourceText: includeSource ? chunk.text : nil, symbol: symbol)
            }
            return ImplementationsResult(implementations: implementations, sourceLayer: .treeSitter)
        }
    }

    // MARK: - Shared live-layer helpers

    /// Reads `filePath`'s current disk content and syncs it to `session`
    /// before any live request — the "`syncOpen` called with current disk
    /// content before every live request" contract this task's acceptance
    /// criteria requires.
    ///
    /// Any failure (the file can't be read, or `syncOpen` itself throws — a
    /// connection failure) is swallowed into `nil`: per `LiveOpsCore`'s
    /// type-level doc comment, a live-layer failure falls through to the
    /// next layer rather than surfacing.
    ///
    /// `readFileContents(relativePath:rootDirectory:)` rejects a
    /// path-traversal `filePath` before touching disk (see its own doc
    /// comment), so this method's own `DocumentURI` construction below —
    /// which reuses the exact same `filePath` — never runs on an unsafe
    /// path either: the `guard` above already returned `nil` for it.
    ///
    /// - Parameters:
    ///   - session: The session to sync the document to.
    ///   - rootDirectory: The workspace root `filePath` is relative to.
    ///   - filePath: The file to sync, relative to `rootDirectory`.
    /// - Returns: The synced document's URI, or `nil` on any failure.
    ///
    /// Not `private`: `LiveOpsExtended` reuses this exact "sync current disk
    /// content before a live request" helper for `codeActions`/`renameEdits`/
    /// `inboundCalls` rather than duplicating it.
    static func syncLiveDocument(session: LspSession<Connection>, rootDirectory: URL, filePath: String) async -> DocumentURI? {
        guard let contents = readFileContents(relativePath: filePath, rootDirectory: rootDirectory) else {
            return nil
        }
        let uri = DocumentURI(rootDirectory.appendingPathComponent(filePath).absoluteString)
        do {
            try await session.syncOpen(uri: uri, text: contents)
        } catch {
            return nil
        }
        return uri
    }

    /// Reads `relativePath`'s content from disk as UTF-8 text, or `nil` if
    /// it can't be read or decoded, or if `relativePath` fails
    /// `RelativePath.isSafeRelativePath(_:)`'s path-traversal guard.
    ///
    /// This is the sole gateway every disk read in this type goes through
    /// (`readSourceRange`, and `syncLiveDocument`'s own subsequent
    /// `DocumentURI` construction, which only runs after this guard has
    /// already accepted `relativePath`) — see
    /// `RelativePath.isSafeRelativePath(_:)`'s doc comment for why
    /// `relativePath` isn't trusted even though every current caller in
    /// this file passes the op's own `filePath` argument.
    private static func readFileContents(relativePath: String, rootDirectory: URL) -> String? {
        guard RelativePath.isSafeRelativePath(relativePath) else {
            return nil
        }
        let fileURL = rootDirectory.appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: fileURL), let contents = String(data: data, encoding: .utf8) else {
            return nil
        }
        return contents
    }

    /// Reads the source lines spanning `range` (inclusive) from `filePath` on disk, or `nil` if the
    /// file can't be read or `range` falls outside it.
    private static func readSourceRange(rootDirectory: URL, filePath: String, range: LSPRange) -> String? {
        guard let contents = readFileContents(relativePath: filePath, rootDirectory: rootDirectory) else {
            return nil
        }
        let lines = contents.components(separatedBy: "\n")
        let startLine = max(0, range.start.line)
        let endLine = min(lines.count - 1, range.end.line)
        guard startLine <= endLine, startLine < lines.count else { return nil }
        return lines[startLine...endLine].joined(separator: "\n")
    }

    /// Builds a zero-width `LSPRange` at `(line, character)`, the shape
    /// `LayeredContext.lspSymbolAt`/`tsChunkAt` expect for a cursor lookup.
    ///
    /// Not `private`: `LiveOpsExtended.inboundCalls`'s LSP-index layer reuses
    /// this exact cursor-lookup shape.
    static func pointRange(line: Int, character: Int) -> LSPRange {
        LSPRange(start: Position(line: line, character: character), end: Position(line: line, character: character))
    }
}

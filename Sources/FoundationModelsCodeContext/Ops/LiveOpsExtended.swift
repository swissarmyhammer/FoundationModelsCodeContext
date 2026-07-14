import Foundation
import GRDB

// ---------------------------------------------------------------------------
// Result types
// ---------------------------------------------------------------------------

/// Result of `LiveOpsExtended.codeActions`.
public struct CodeActionsResult: Codable, Sendable, Equatable {
    /// The code actions available at the range, each already run through
    /// `codeAction/resolve` — empty (never an error) when no layer has data.
    let actions: [CodeActionItem]

    /// Which data layer produced the result. Always `.liveLSP` or `.none`:
    /// code actions are ephemeral, server-computed suggestions with no
    /// persisted equivalent in `lsp_symbols`/`ts_chunks` (unlike, say,
    /// `references`' `lsp_call_edges`-backed index layer), so there is no
    /// indexed layer to fall back to. This still routes through
    /// `LiveOpsCore.cascade` with a constant-`nil` indexed layer (see
    /// `LiveOpsExtended.codeActions`) purely to keep the same
    /// "which layer answered" shape as every other live op, matching
    /// `LiveOpsCore`'s own uniform-cascade design.
    let sourceLayer: SourceLayer
}

/// Result of `LiveOpsExtended.renameEdits`.
///
/// Deliberately carries no `sourceLayer`: unlike `CodeActionsResult`, a
/// rename has no meaningful "which layer answered" question at all — a
/// rename can only ever be satisfied by a live LSP server (there is no
/// persisted "renameable" fact to fall back to), so the only interesting
/// signal is whether it succeeded at all, which `canRename` already
/// expresses directly.
public struct RenameEditsResult: Codable, Sendable, Equatable {
    /// Whether the symbol at the cursor can be renamed. `false` (never an
    /// error) when there is no live session, the live server reports the
    /// position isn't renameable, or the live request fails outright.
    let canRename: Bool

    /// The renameable range's placeholder text the server suggested, if any.
    let placeholder: String?

    /// The workspace edit that performs the rename, or `nil` when `canRename` is `false`.
    let edit: WorkspaceEdit?
}

/// One caller of a symbol, from `LiveOpsExtended.inboundCalls`.
///
/// A dedicated type rather than reusing `CallHierarchyIncomingCall` directly
/// (mirroring how `LiveOpsCore.DefinitionLocation`/`ReferenceLocation` wrap
/// `Location` rather than returning it raw): this adds the enriched
/// `LayeredSymbolInfo` and a workspace-relative `filePath`, neither of which
/// the raw wire type carries.
struct InboundCall: Codable, Sendable, Equatable {
    /// The caller's name, as reported by the layer that answered.
    let callerName: String

    /// The file containing the caller, relative to the workspace root.
    let filePath: String

    /// The caller's own declaration span.
    let range: LSPRange

    /// The specific call-site ranges within the caller that invoke the
    /// target symbol (empty if the layer recorded none).
    let callSites: [LSPRange]

    /// The caller's enriched symbol info, if known from the LSP index or tree-sitter.
    let symbol: LayeredSymbolInfo?
}

/// Result of `LiveOpsExtended.inboundCalls`.
public struct InboundCallsResult: Codable, Sendable, Equatable {
    /// Every caller found — empty (never an error) when no layer has data.
    let calls: [InboundCall]

    /// Which data layer provided the result.
    let sourceLayer: SourceLayer
}

/// One workspace-symbol match, from `LiveOpsExtended.workspaceSymbols`.
///
/// A dedicated type rather than reusing `SymbolInformation` directly: this
/// relativizes `location.uri` to a workspace-relative `filePath` (mirroring
/// every other `LiveOpsCore`/`LiveOpsExtended` result), which the raw wire
/// type's absolute `DocumentURI` does not express.
struct WorkspaceSymbolInfo: Codable, Sendable, Equatable {
    /// The symbol's name.
    let name: String

    /// The symbol's kind.
    let kind: SymbolKind

    /// The file containing the symbol, relative to the workspace root.
    let filePath: String

    /// The symbol's span.
    let range: LSPRange

    /// The symbol's enclosing container (e.g. a class name), if the server reported one.
    let containerName: String?
}

/// Result of `LiveOpsExtended.workspaceSymbols`.
///
/// Deliberately carries no `sourceLayer`: `workspaceSymbols` is
/// document-less and answered through whichever session `anySession()`
/// finds, with no persisted-layer equivalent to cascade through (unlike
/// `inboundCalls`, there is no per-file cursor position to look up an
/// `lsp_symbols`/`ts_chunks` row against here) — the only outcome worth
/// reporting is the (possibly empty) match list itself.
public struct WorkspaceSymbolsResult: Codable, Sendable, Equatable {
    /// The matching symbols — empty (never an error) when no session is
    /// running or the live request fails.
    let symbols: [WorkspaceSymbolInfo]
}

/// Result of `LiveOpsExtended.lspStatus`.
///
/// Deliberately carries no `sourceLayer`: this is a supervisor snapshot, not
/// a cascaded data lookup — there is nothing to cascade through.
public struct LspStatusResult: Codable, Sendable, Equatable {
    /// A snapshot of every managed daemon's current state, as reported by `LspSupervisor.status()`.
    let servers: [ServerStatus]
}

// ---------------------------------------------------------------------------
// LiveOpsExtended
// ---------------------------------------------------------------------------

/// The remaining five of the ten v1 live code-intelligence ops:
/// `codeActions`, `renameEdits`, `inboundCalls`, `workspaceSymbols`,
/// `lspStatus`.
///
/// Continues `LiveOpsCore`'s layered-cascade conventions where they genuinely
/// apply (`codeActions`, `inboundCalls`) and departs from them, with the
/// reasoning documented on each affected result type, where an op has no
/// persisted-layer or "which layer answered" question to begin with
/// (`renameEdits`, `workspaceSymbols`, `lspStatus`) — see each result type's
/// own doc comment for the specific judgment call.
///
/// Port of the Rust `swissarmyhammer-code-context::ops::{get_code_actions,
/// get_rename_edits (née "rename"), get_inbound_calls, get_workspace_symbols,
/// get_lsp_status}` modules, with the same follower-router removal `LiveOpsCore`
/// documents (every op here takes a plain `LspSession<Connection>?`/
/// `LspSupervisor<Connection>`, never a cross-process router).
enum LiveOpsExtended<Connection: LanguageServerConnection> {
    // MARK: - codeActions

    /// Finds and resolves the code actions available for a range.
    ///
    /// Live-only (see `CodeActionsResult.sourceLayer`'s doc comment): issues
    /// `textDocument/codeAction`, then `codeAction/resolve` for every action
    /// returned, unconditionally — this package makes no capability-gating
    /// distinction between actions that already carry an `edit` and ones
    /// that don't (per plan.md's "no capability gating" convention), so
    /// every action is resolved uniformly rather than only the "lazy" ones a
    /// capability-aware client would single out. A per-action resolve
    /// failure degrades to the unresolved action rather than failing the
    /// whole result, matching this package's "partial data over no data"
    /// philosophy.
    ///
    /// - Parameters:
    ///   - session: The live session to query, or `nil` if no live layer is available.
    ///   - rootDirectory: The workspace root `filePath` is relative to.
    ///   - filePath: The file containing the range, relative to `rootDirectory`.
    ///   - startLine: The zero-based start line of the range.
    ///   - startCharacter: The zero-based start character offset.
    ///   - endLine: The zero-based end line of the range.
    ///   - endCharacter: The zero-based end character offset.
    ///   - diagnostics: The diagnostics currently in scope for the range.
    ///   - only: If non-`nil`, restricts the server to these code-action kinds.
    /// - Returns: The resolved code actions, tagged with the layer that produced them.
    /// - Throws: Rethrows whatever a genuine (non-connection) failure surfaces.
    static func codeActions(
        session: LspSession<Connection>?,
        rootDirectory: URL,
        filePath: String,
        startLine: Int,
        startCharacter: Int,
        endLine: Int,
        endCharacter: Int,
        diagnostics: [Diagnostic] = [],
        only: [String]? = nil
    ) async throws -> CodeActionsResult {
        let range = LSPRange(
            start: Position(line: startLine, character: startCharacter),
            end: Position(line: endLine, character: endCharacter)
        )
        return try await LiveOpsCore<Connection>.cascade(
            liveLayer: {
                try await liveCodeActions(
                    session: session, rootDirectory: rootDirectory, filePath: filePath,
                    range: range, diagnostics: diagnostics, only: only
                )
            },
            // No indexed-layer equivalent exists for code actions — see
            // `CodeActionsResult.sourceLayer`'s doc comment.
            indexedLayers: { nil },
            empty: { CodeActionsResult(actions: [], sourceLayer: .none) }
        )
    }

    private static func liveCodeActions(
        session: LspSession<Connection>?,
        rootDirectory: URL,
        filePath: String,
        range: LSPRange,
        diagnostics: [Diagnostic],
        only: [String]?
    ) async throws -> CodeActionsResult? {
        guard let session, let uri = await LiveOpsCore<Connection>.syncLiveDocument(session: session, rootDirectory: rootDirectory, filePath: filePath) else {
            return nil
        }
        let rawActions: [CodeActionItem]
        do {
            rawActions = try await session.codeActions(uri: uri, range: range, diagnostics: diagnostics, only: only)
        } catch {
            return nil
        }
        guard !rawActions.isEmpty else { return nil }

        var resolved: [CodeActionItem] = []
        resolved.reserveCapacity(rawActions.count)
        for action in rawActions {
            if let resolvedAction = try? await session.resolveCodeAction(item: action) {
                resolved.append(resolvedAction)
            } else {
                // A resolve failure degrades to the unresolved action rather than dropping it or
                // failing the whole result — see this method's caller's doc comment.
                resolved.append(action)
            }
        }
        return CodeActionsResult(actions: resolved, sourceLayer: .liveLSP)
    }

    // MARK: - renameEdits

    /// Renames the symbol at a position, issuing `prepareRename` and
    /// `rename` as one atomic batch.
    ///
    /// Degrades to `canRename: false` (never an error) when: there is no
    /// live session, `syncOpen` fails, the live request fails (a connection
    /// failure), or the server itself reports the position isn't renameable
    /// (a `nil` `prepareRename` range) — in the last case, `rename` is never
    /// called at all, matching correct LSP client behavior (never send a
    /// rename the server already said it can't perform).
    ///
    /// - Parameters:
    ///   - session: The live session to query, or `nil` if no live layer is available.
    ///   - rootDirectory: The workspace root `filePath` is relative to.
    ///   - filePath: The file containing the cursor position, relative to `rootDirectory`.
    ///   - line: The zero-based cursor line.
    ///   - character: The zero-based cursor character offset.
    ///   - newName: The symbol's new name.
    /// - Returns: Whether the rename succeeded, alongside its edit.
    /// - Throws: Rethrows whatever a genuine (non-connection) failure surfaces.
    static func renameEdits(
        session: LspSession<Connection>?,
        rootDirectory: URL,
        filePath: String,
        line: Int,
        character: Int,
        newName: String
    ) async throws -> RenameEditsResult {
        let cannotRename = RenameEditsResult(canRename: false, placeholder: nil, edit: nil)

        guard let session, let uri = await LiveOpsCore<Connection>.syncLiveDocument(session: session, rootDirectory: rootDirectory, filePath: filePath) else {
            return cannotRename
        }

        let batchResult: (prepare: PrepareRenameResult, edit: WorkspaceEdit?)
        do {
            batchResult = try await session.prepareRenameAndRename(
                uri: uri, at: Position(line: line, character: character), newName: newName
            )
        } catch {
            return cannotRename
        }

        guard let edit = batchResult.edit else {
            return cannotRename
        }
        return RenameEditsResult(canRename: true, placeholder: batchResult.prepare.placeholder, edit: edit)
    }

    // MARK: - inboundCalls

    /// Finds every caller of the symbol (typically a function) at a position.
    ///
    /// Cascades live (`prepareCallHierarchy` + `incomingCalls`) to the
    /// LSP-index layer, which reuses `LayeredContext.lspCallersOf` — the same
    /// "callers of this symbol" query `LiveOpsCore.references`' own
    /// LSP-index layer already runs against `lsp_call_edges` (see
    /// `LiveOpsCore.tryLspIndexReferences`). There is no tree-sitter layer
    /// here: `references`' own tree-sitter layer already covers "search
    /// chunk text for this identifier" for exactly this kind of query, so a
    /// second, differently-named copy of the same heuristic under
    /// `inboundCalls` would be pure duplication with no distinguishing
    /// value; skipping it (rather than inventing a redundant heuristic just
    /// to fill the slot) mirrors the Rust reference's own precedent of
    /// skipping a layer when "no equivalent relationship" is worth adding
    /// (see `LiveOpsCore`'s type-level doc comment on `implementations`).
    ///
    /// - Parameters:
    ///   - store: The workspace's index store to query.
    ///   - session: The live session to query, or `nil` if no live layer is available.
    ///   - rootDirectory: The workspace root `filePath` is relative to.
    ///   - filePath: The file containing the cursor position, relative to `rootDirectory`.
    ///   - line: The zero-based cursor line.
    ///   - character: The zero-based cursor character offset.
    /// - Returns: The callers found, tagged with the layer that produced them.
    /// - Throws: Rethrows `Store`'s storage errors.
    static func inboundCalls(
        store: Store,
        session: LspSession<Connection>?,
        rootDirectory: URL,
        filePath: String,
        line: Int,
        character: Int
    ) async throws -> InboundCallsResult {
        try await LiveOpsCore<Connection>.cascade(
            liveLayer: {
                try await liveInboundCalls(
                    session: session, store: store, rootDirectory: rootDirectory,
                    filePath: filePath, line: line, character: character
                )
            },
            indexedLayers: {
                try await indexedInboundCalls(store: store, filePath: filePath, line: line, character: character)
            },
            empty: { InboundCallsResult(calls: [], sourceLayer: .none) }
        )
    }

    private static func liveInboundCalls(
        session: LspSession<Connection>?,
        store: Store,
        rootDirectory: URL,
        filePath: String,
        line: Int,
        character: Int
    ) async throws -> InboundCallsResult? {
        guard let session, let uri = await LiveOpsCore<Connection>.syncLiveDocument(session: session, rootDirectory: rootDirectory, filePath: filePath) else {
            return nil
        }

        let items: [CallHierarchyItem]
        do {
            items = try await session.prepareCallHierarchy(uri: uri, position: Position(line: line, character: character))
        } catch {
            return nil
        }
        guard let target = items.first else { return nil }

        let rawCalls: [CallHierarchyIncomingCall]
        do {
            rawCalls = try await session.incomingCalls(item: target)
        } catch {
            return nil
        }
        guard !rawCalls.isEmpty else { return nil }

        let calls = try await store.read { db in
            try rawCalls.map { call -> InboundCall in
                let path = RelativePath.relativeFilePath(fromURI: call.from.uri, rootDirectory: rootDirectory)
                let symbol = try LayeredContext.enrichLocation(db: db, filePath: path, range: call.from.range).symbol
                return InboundCall(callerName: call.from.name, filePath: path, range: call.from.range, callSites: call.fromRanges, symbol: symbol)
            }
        }
        return InboundCallsResult(calls: calls, sourceLayer: .liveLSP)
    }

    private static func indexedInboundCalls(store: Store, filePath: String, line: Int, character: Int) async throws -> InboundCallsResult? {
        try await store.read { db in
            let range = LiveOpsCore<Connection>.pointRange(line: line, character: character)
            guard let row = try LayeredContext.lspSymbolRow(db: db, filePath: filePath, range: range) else {
                return nil
            }
            let callers = try LayeredContext.lspCallersOf(db: db, symbolID: row.id)
            guard !callers.isEmpty else { return nil }

            let calls = callers.map { caller in
                InboundCall(
                    callerName: caller.symbol.name, filePath: caller.symbol.filePath,
                    range: caller.symbol.range, callSites: caller.callSites, symbol: caller.symbol
                )
            }
            return InboundCallsResult(calls: calls, sourceLayer: .lspIndex)
        }
    }

    // MARK: - workspaceSymbols

    /// Searches the workspace for symbols matching a query string, routed
    /// through any currently running session.
    ///
    /// Document-less (per this task's description): unlike every other op in
    /// `LiveOpsCore`/`LiveOpsExtended`, `workspace/symbol` is not scoped to a
    /// specific open document, so this routes through `supervisor.anySession()`
    /// rather than a caller-supplied `session:` — the caller has no single
    /// file to resolve a language-specific session from in the first place.
    /// Live-only (see `WorkspaceSymbolsResult`'s doc comment): degrades to an
    /// empty result (never an error) when no daemon is running or the live
    /// request fails.
    ///
    /// - Parameters:
    ///   - supervisor: The supervisor to find a running session through.
    ///   - rootDirectory: The workspace root each match's file path is made relative to.
    ///   - query: The search string, interpreted by the server (typically fuzzy).
    /// - Returns: The matching symbols.
    static func workspaceSymbols(
        supervisor: LspSupervisor<Connection>,
        rootDirectory: URL,
        query: String
    ) async throws -> WorkspaceSymbolsResult {
        guard let session = await supervisor.anySession() else {
            return WorkspaceSymbolsResult(symbols: [])
        }

        let rawSymbols: [SymbolInformation]
        do {
            rawSymbols = try await session.workspaceSymbols(query: query)
        } catch {
            return WorkspaceSymbolsResult(symbols: [])
        }

        let symbols = rawSymbols.map { info -> WorkspaceSymbolInfo in
            let path = RelativePath.relativeFilePath(fromURI: info.location.uri, rootDirectory: rootDirectory)
            return WorkspaceSymbolInfo(name: info.name, kind: info.kind, filePath: path, range: info.location.range, containerName: info.containerName)
        }
        return WorkspaceSymbolsResult(symbols: symbols)
    }

    // MARK: - lspStatus

    /// Snapshots every managed daemon's current lifecycle state.
    ///
    /// A thin wrapper over `LspSupervisor.status()` — there is no cascade or
    /// degradation here at all: the supervisor's own managed-daemon map is
    /// the sole source of truth, and an empty result (no daemons managed) is
    /// exactly as valid an answer as a populated one.
    ///
    /// - Parameter supervisor: The supervisor to snapshot.
    /// - Returns: One `ServerStatus` per managed daemon, sorted by command.
    static func lspStatus(supervisor: LspSupervisor<Connection>) async -> LspStatusResult {
        LspStatusResult(servers: await supervisor.status())
    }
}

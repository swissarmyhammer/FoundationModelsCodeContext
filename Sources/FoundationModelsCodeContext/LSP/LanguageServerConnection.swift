import Foundation

/// The typed seam every layer above the LSP transport programs against.
///
/// Per plan.md "LSP subsystem", this is the *only* interface the rest of
/// `FoundationModelsCodeContext` (and its tests) sees for talking to a language server:
/// one `async` method per LSP capability this package uses, typed in and
/// out with the shared value types from `LSPTypes.swift` and the
/// wire-payload structs from `Wire.swift`. No method string, JSON-RPC id,
/// or raw JSON ever crosses this boundary — that is strictly a private
/// implementation detail of `ProcessLanguageServerConnection`. Unit tests
/// program against `FakeLanguageServerConnection` instead, which conforms
/// to the same protocol and never touches JSON at all.
///
/// Declared as `Actor` rather than a plain protocol so every conforming
/// type serializes its own mutable state (in-flight requests, open
/// documents, ...) automatically, the same way `ProcessLanguageServerConnection`
/// serializes access to its pending-request table.
public protocol LanguageServerConnection: Actor {
    // MARK: - Lifecycle

    /// Sends the `initialize` request that starts the LSP handshake.
    /// - Parameter rootURI: The workspace root to advertise to the server, if any.
    /// - Throws: If the server rejects the handshake or the connection is unusable.
    func initialize(rootURI: DocumentURI?) async throws

    /// Sends the `initialized` notification that completes the LSP handshake.
    /// - Throws: If the connection is unusable.
    func initialized() async throws

    /// Sends the `shutdown` request that begins a graceful server shutdown.
    /// - Throws: If the connection is unusable.
    func shutdown() async throws

    /// Sends the `exit` notification that tells the server to terminate.
    /// - Throws: If the connection is unusable.
    func exit() async throws

    // MARK: - Document sync

    /// Notifies the server that a document was opened, sending its full content.
    /// - Parameters:
    ///   - uri: The opened document.
    ///   - languageID: The LSP `languageId` of the document (e.g. `"swift"`).
    ///   - version: The document's version number, starting at the value the caller assigns on open.
    ///   - text: The document's full current content.
    /// - Throws: If the connection is unusable.
    func didOpen(uri: DocumentURI, languageID: String, version: Int, text: String) async throws

    /// Notifies the server of a full-document content replacement.
    /// - Parameters:
    ///   - uri: The changed document.
    ///   - version: The document's new version number.
    ///   - text: The document's full new content.
    /// - Throws: If the connection is unusable.
    func didChange(uri: DocumentURI, version: Int, text: String) async throws

    /// Notifies the server that a document was saved.
    /// - Parameter uri: The saved document.
    /// - Throws: If the connection is unusable.
    func didSave(uri: DocumentURI) async throws

    /// Notifies the server that a document was closed.
    /// - Parameter uri: The closed document.
    /// - Throws: If the connection is unusable.
    func didClose(uri: DocumentURI) async throws

    // MARK: - Symbols & navigation

    /// Requests the symbols declared in a document.
    /// - Parameter uri: The document to query.
    /// - Returns: The document's symbols, normalized to the hierarchical shape
    ///   regardless of which wire shape the server replied with.
    /// - Throws: If the request fails or times out.
    func documentSymbols(in uri: DocumentURI) async throws -> [DocumentSymbol]

    /// Requests the definition site of the symbol at a position.
    /// - Parameters:
    ///   - uri: The document containing the cursor position.
    ///   - position: The cursor position to query.
    /// - Returns: Zero or more definition locations.
    /// - Throws: If the request fails or times out.
    func definition(in uri: DocumentURI, at position: Position) async throws -> [Location]

    /// Requests the type-definition site of the symbol at a position.
    /// - Parameters:
    ///   - uri: The document containing the cursor position.
    ///   - position: The cursor position to query.
    /// - Returns: Zero or more type-definition locations.
    /// - Throws: If the request fails or times out.
    func typeDefinition(in uri: DocumentURI, at position: Position) async throws -> [Location]

    /// Requests hover information for the symbol at a position.
    /// - Parameters:
    ///   - uri: The document containing the cursor position.
    ///   - position: The cursor position to query.
    /// - Returns: The hover contents, or `nil` if the server has nothing to show.
    /// - Throws: If the request fails or times out.
    func hover(in uri: DocumentURI, at position: Position) async throws -> Hover?

    /// Requests every reference to the symbol at a position.
    /// - Parameters:
    ///   - uri: The document containing the cursor position.
    ///   - position: The cursor position to query.
    ///   - includeDeclaration: Whether the declaration site itself should be included.
    /// - Returns: Zero or more reference locations.
    /// - Throws: If the request fails or times out.
    func references(in uri: DocumentURI, at position: Position, includeDeclaration: Bool) async throws -> [Location]

    /// Requests every implementation of the symbol at a position.
    /// - Parameters:
    ///   - uri: The document containing the cursor position.
    ///   - position: The cursor position to query.
    /// - Returns: Zero or more implementation locations.
    /// - Throws: If the request fails or times out.
    func implementations(in uri: DocumentURI, at position: Position) async throws -> [Location]

    // MARK: - Call hierarchy

    /// Requests the call-hierarchy item(s) rooted at a position, the entry point
    /// for `outgoingCalls(of:)`/`incomingCalls(of:)`.
    /// - Parameters:
    ///   - uri: The document containing the cursor position.
    ///   - position: The cursor position to query.
    /// - Returns: Zero or more call-hierarchy items.
    /// - Throws: If the request fails or times out.
    func prepareCallHierarchy(in uri: DocumentURI, at position: Position) async throws -> [CallHierarchyItem]

    /// Requests every call made *from* a call-hierarchy item.
    /// - Parameter item: The item previously returned by `prepareCallHierarchy(in:at:)`.
    /// - Returns: Zero or more outgoing calls.
    /// - Throws: If the request fails or times out.
    func outgoingCalls(of item: CallHierarchyItem) async throws -> [CallHierarchyOutgoingCall]

    /// Requests every call made *into* a call-hierarchy item.
    /// - Parameter item: The item previously returned by `prepareCallHierarchy(in:at:)`.
    /// - Returns: Zero or more incoming calls.
    /// - Throws: If the request fails or times out.
    func incomingCalls(of item: CallHierarchyItem) async throws -> [CallHierarchyIncomingCall]

    // MARK: - Rename

    /// Checks whether the symbol at a position can be renamed.
    /// - Parameters:
    ///   - uri: The document containing the cursor position.
    ///   - position: The cursor position to query.
    /// - Returns: The renameable range and placeholder text, if the server allows a rename here.
    /// - Throws: If the request fails or times out.
    func prepareRename(in uri: DocumentURI, at position: Position) async throws -> PrepareRenameResult

    /// Requests the workspace edit that renames the symbol at a position.
    /// - Parameters:
    ///   - uri: The document containing the cursor position.
    ///   - position: The cursor position to query.
    ///   - newName: The symbol's new name.
    /// - Returns: The edits to apply across the workspace.
    /// - Throws: If the request fails or times out.
    func rename(in uri: DocumentURI, at position: Position, newName: String) async throws -> WorkspaceEdit

    // MARK: - Code actions

    /// Requests the code actions available for a range.
    /// - Parameters:
    ///   - uri: The document containing the range.
    ///   - range: The span to request actions for.
    ///   - diagnostics: The diagnostics currently in scope for `range`.
    ///   - only: If non-`nil`, restricts the server to these code-action kinds.
    /// - Returns: Zero or more code actions.
    /// - Throws: If the request fails or times out.
    func codeActions(in uri: DocumentURI, range: LSPRange, diagnostics: [Diagnostic], only: [String]?) async throws -> [CodeActionItem]

    /// Resolves a code action's deferred fields (typically its `edit`).
    /// - Parameter item: The code action previously returned by `codeActions(in:range:diagnostics:only:)`.
    /// - Returns: The same action with its deferred fields filled in.
    /// - Throws: If the request fails or times out.
    func resolveCodeAction(item: CodeActionItem) async throws -> CodeActionItem

    // MARK: - Workspace

    /// Searches the workspace for symbols matching a query string.
    /// - Parameter query: The search string, interpreted by the server (typically fuzzy).
    /// - Returns: Zero or more matching symbols.
    /// - Throws: If the request fails or times out.
    func workspaceSymbols(query: String) async throws -> [SymbolInformation]

    // MARK: - Diagnostics

    /// Pulls the current diagnostics for a document via `textDocument/diagnostic`.
    /// - Parameter uri: The document to query.
    /// - Returns: The document's current diagnostics, leniently parsed.
    /// - Throws: If the request fails or times out.
    func pullDiagnostics(for uri: DocumentURI) async throws -> [Diagnostic]

    /// Notifications the server sends without being asked, fanned out as they arrive.
    ///
    /// Only `publishDiagnostics` is modeled in v1 (see `ServerNotification`).
    var serverNotifications: AsyncStream<ServerNotification> { get }
}

/// A message the language server sends without being asked, rather than as
/// the reply to one of `LanguageServerConnection`'s requests.
///
/// Only the `textDocument/publishDiagnostics` push is modeled: it is the
/// only server-initiated notification this package's v1 scope consumes
/// (`LspSession`'s diagnostics cache, per plan.md).
public enum ServerNotification: Sendable, Equatable {
    /// The server replaced the diagnostics for `uri` with `diagnostics`.
    case publishDiagnostics(uri: DocumentURI, diagnostics: [Diagnostic])
}

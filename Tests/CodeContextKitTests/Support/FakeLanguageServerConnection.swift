import Foundation

@testable import CodeContextKit

/// An in-memory `LanguageServerConnection` for unit tests: scripted typed
/// responses, induced errors, and call recording — never touches JSON,
/// per plan.md "every LSP layer sits behind `LanguageServerConnection` —
/// unit tests use a scripted in-memory fake ... and never touch JSON."
///
/// Every request-shaped method has a matching `...Result: Result<T, Error>`
/// stored property, defaulting to an empty/`nil` success value; set it to
/// `.failure(someError)` before a call to induce that call's failure (a
/// stand-in for a crashed or misbehaving server). Every invocation is
/// recorded to `calls` in order, so tests can assert what was called with
/// what arguments.
actor FakeLanguageServerConnection: LanguageServerConnection {
    /// One recorded invocation of a `LanguageServerConnection` method.
    enum Call: Equatable {
        case initialize(rootURI: DocumentURI?)
        case initialized
        case shutdown
        case exit
        case didOpen(uri: DocumentURI, languageID: String, version: Int, text: String)
        case didChange(uri: DocumentURI, version: Int, text: String)
        case didSave(uri: DocumentURI)
        case didClose(uri: DocumentURI)
        case documentSymbols(uri: DocumentURI)
        case definition(uri: DocumentURI, position: Position)
        case typeDefinition(uri: DocumentURI, position: Position)
        case hover(uri: DocumentURI, position: Position)
        case references(uri: DocumentURI, position: Position, includeDeclaration: Bool)
        case implementations(uri: DocumentURI, position: Position)
        case prepareCallHierarchy(uri: DocumentURI, position: Position)
        case outgoingCalls(item: CallHierarchyItem)
        case incomingCalls(item: CallHierarchyItem)
        case prepareRename(uri: DocumentURI, position: Position)
        case rename(uri: DocumentURI, position: Position, newName: String)
        case codeActions(uri: DocumentURI, range: LSPRange, diagnostics: [Diagnostic], only: [String]?)
        case resolveCodeAction(title: String)
        case workspaceSymbols(query: String)
        case pullDiagnostics(uri: DocumentURI)
    }

    /// Every call made on this fake so far, in invocation order.
    private(set) var calls: [Call] = []

    // MARK: - Scripted results

    var initializeResult: Result<Void, Error> = .success(())
    var initializedResult: Result<Void, Error> = .success(())
    var shutdownResult: Result<Void, Error> = .success(())
    var exitResult: Result<Void, Error> = .success(())
    var didOpenResult: Result<Void, Error> = .success(())
    var didChangeResult: Result<Void, Error> = .success(())
    var didSaveResult: Result<Void, Error> = .success(())
    var didCloseResult: Result<Void, Error> = .success(())
    var documentSymbolsResult: Result<[DocumentSymbol], Error> = .success([])
    var definitionResult: Result<[Location], Error> = .success([])
    var typeDefinitionResult: Result<[Location], Error> = .success([])
    var hoverResult: Result<Hover?, Error> = .success(nil)
    var referencesResult: Result<[Location], Error> = .success([])
    var implementationsResult: Result<[Location], Error> = .success([])
    var prepareCallHierarchyResult: Result<[CallHierarchyItem], Error> = .success([])
    var outgoingCallsResult: Result<[CallHierarchyOutgoingCall], Error> = .success([])
    var incomingCallsResult: Result<[CallHierarchyIncomingCall], Error> = .success([])
    var prepareRenameResult: Result<PrepareRenameResult, Error> = .success(PrepareRenameResult(range: nil, placeholder: nil))
    var renameResult: Result<WorkspaceEdit, Error> = .success(WorkspaceEdit(changes: nil))
    var codeActionsResult: Result<[CodeActionItem], Error> = .success([])
    var resolveCodeActionResult: Result<CodeActionItem, Error>?
    var workspaceSymbolsResult: Result<[SymbolInformation], Error> = .success([])
    var pullDiagnosticsResult: Result<[Diagnostic], Error> = .success([])

    private let notificationContinuation: AsyncStream<ServerNotification>.Continuation

    /// Server-initiated notifications, fed by tests via `emit(notification:)`.
    nonisolated let serverNotifications: AsyncStream<ServerNotification>

    /// Creates a fake connection with every scripted result at its default (empty/success) value.
    init() {
        let (notificationStream, continuation) = AsyncStream.makeStream(of: ServerNotification.self)
        self.serverNotifications = notificationStream
        self.notificationContinuation = continuation
    }

    /// Scripts the result `pullDiagnostics(for:)` returns (or throws) on its next call.
    /// - Parameter result: The scripted outcome to install as `pullDiagnosticsResult`.
    func setPullDiagnosticsResult(_ result: Result<[Diagnostic], Error>) {
        pullDiagnosticsResult = result
    }

    /// Scripts the result `initialize(rootURI:)` returns (or throws) on its next call.
    /// - Parameter result: The scripted outcome to install as `initializeResult`.
    func setInitializeResult(to result: Result<Void, Error>) {
        initializeResult = result
    }

    /// Scripts the result `documentSymbols(in:)` returns (or throws) on its next call.
    /// - Parameter result: The scripted outcome to install as `documentSymbolsResult`.
    func setDocumentSymbolsResult(_ result: Result<[DocumentSymbol], Error>) {
        documentSymbolsResult = result
    }

    /// Scripts the result `prepareCallHierarchy(in:at:)` returns (or throws) on its next call.
    /// - Parameter result: The scripted outcome to install as `prepareCallHierarchyResult`.
    func setPrepareCallHierarchyResult(_ result: Result<[CallHierarchyItem], Error>) {
        prepareCallHierarchyResult = result
    }

    /// Scripts the result `outgoingCalls(of:)` returns (or throws) on its next call.
    /// - Parameter result: The scripted outcome to install as `outgoingCallsResult`.
    func setOutgoingCallsResult(_ result: Result<[CallHierarchyOutgoingCall], Error>) {
        outgoingCallsResult = result
    }

    /// Pushes a server-initiated notification onto `serverNotifications`, simulating an
    /// unsolicited message like `textDocument/publishDiagnostics`.
    /// - Parameter notification: The notification to emit.
    func emit(notification: ServerNotification) {
        notificationContinuation.yield(notification)
    }

    // MARK: - LanguageServerConnection

    func initialize(rootURI: DocumentURI?) async throws {
        calls.append(.initialize(rootURI: rootURI))
        try initializeResult.get()
    }

    func initialized() async throws {
        calls.append(.initialized)
        try initializedResult.get()
    }

    func shutdown() async throws {
        calls.append(.shutdown)
        try shutdownResult.get()
    }

    func exit() async throws {
        calls.append(.exit)
        try exitResult.get()
    }

    func didOpen(uri: DocumentURI, languageID: String, version: Int, text: String) async throws {
        calls.append(.didOpen(uri: uri, languageID: languageID, version: version, text: text))
        try didOpenResult.get()
    }

    func didChange(uri: DocumentURI, version: Int, text: String) async throws {
        calls.append(.didChange(uri: uri, version: version, text: text))
        try didChangeResult.get()
    }

    func didSave(uri: DocumentURI) async throws {
        calls.append(.didSave(uri: uri))
        try didSaveResult.get()
    }

    func didClose(uri: DocumentURI) async throws {
        calls.append(.didClose(uri: uri))
        try didCloseResult.get()
    }

    func documentSymbols(in uri: DocumentURI) async throws -> [DocumentSymbol] {
        calls.append(.documentSymbols(uri: uri))
        return try documentSymbolsResult.get()
    }

    func definition(in uri: DocumentURI, at position: Position) async throws -> [Location] {
        calls.append(.definition(uri: uri, position: position))
        return try definitionResult.get()
    }

    func typeDefinition(in uri: DocumentURI, at position: Position) async throws -> [Location] {
        calls.append(.typeDefinition(uri: uri, position: position))
        return try typeDefinitionResult.get()
    }

    func hover(in uri: DocumentURI, at position: Position) async throws -> Hover? {
        calls.append(.hover(uri: uri, position: position))
        return try hoverResult.get()
    }

    func references(in uri: DocumentURI, at position: Position, includeDeclaration: Bool) async throws -> [Location] {
        calls.append(.references(uri: uri, position: position, includeDeclaration: includeDeclaration))
        return try referencesResult.get()
    }

    func implementations(in uri: DocumentURI, at position: Position) async throws -> [Location] {
        calls.append(.implementations(uri: uri, position: position))
        return try implementationsResult.get()
    }

    func prepareCallHierarchy(in uri: DocumentURI, at position: Position) async throws -> [CallHierarchyItem] {
        calls.append(.prepareCallHierarchy(uri: uri, position: position))
        return try prepareCallHierarchyResult.get()
    }

    func outgoingCalls(of item: CallHierarchyItem) async throws -> [CallHierarchyOutgoingCall] {
        calls.append(.outgoingCalls(item: item))
        return try outgoingCallsResult.get()
    }

    func incomingCalls(of item: CallHierarchyItem) async throws -> [CallHierarchyIncomingCall] {
        calls.append(.incomingCalls(item: item))
        return try incomingCallsResult.get()
    }

    func prepareRename(in uri: DocumentURI, at position: Position) async throws -> PrepareRenameResult {
        calls.append(.prepareRename(uri: uri, position: position))
        return try prepareRenameResult.get()
    }

    func rename(in uri: DocumentURI, at position: Position, newName: String) async throws -> WorkspaceEdit {
        calls.append(.rename(uri: uri, position: position, newName: newName))
        return try renameResult.get()
    }

    func codeActions(in uri: DocumentURI, range: LSPRange, diagnostics: [Diagnostic], only: [String]?) async throws -> [CodeActionItem] {
        calls.append(.codeActions(uri: uri, range: range, diagnostics: diagnostics, only: only))
        return try codeActionsResult.get()
    }

    func resolveCodeAction(item: CodeActionItem) async throws -> CodeActionItem {
        calls.append(.resolveCodeAction(title: item.title))
        // Defaults to echoing the action back unchanged (the common no-op
        // resolve) unless a test has scripted `resolveCodeActionResult`.
        return try (resolveCodeActionResult ?? .success(item)).get()
    }

    func workspaceSymbols(query: String) async throws -> [SymbolInformation] {
        calls.append(.workspaceSymbols(query: query))
        return try workspaceSymbolsResult.get()
    }

    func pullDiagnostics(for uri: DocumentURI) async throws -> [Diagnostic] {
        calls.append(.pullDiagnostics(uri: uri))
        return try pullDiagnosticsResult.get()
    }
}

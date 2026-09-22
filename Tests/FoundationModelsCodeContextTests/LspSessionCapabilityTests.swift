import Foundation
import Testing

@testable import FoundationModelsCodeContext

/// Tests for the capability gate and the failure log of `LspSession`.
///
/// A server that does not advertise a gated method gets no request for it
/// (`pylsp` has no call hierarchy, no workspace symbols and no
/// implementations). A request failure is logged one time for each
/// (server, request) pair, with the code and the message of the server
/// error.
struct LspSessionCapabilityTests {
    /// Capabilities of a server that advertises no gated method, as `pylsp` does.
    private static let noGatedMethod = ServerCapabilities(callHierarchy: false, workspaceSymbol: false, implementation: false)

    /// The document every request in this suite is about.
    private static let uri = DocumentURI("file:///tmp/sample.py")

    /// The cursor position every request in this suite is about.
    private static let position = Position(line: 0, character: 4)

    /// A call-hierarchy item for the incoming and outgoing call requests.
    private static let item = CallHierarchyItem(
        name: "helper",
        kind: .function,
        detail: nil,
        uri: uri,
        range: LSPRange(start: Position(line: 0, character: 0), end: Position(line: 2, character: 0)),
        selectionRange: LSPRange(start: position, end: Position(line: 0, character: 10))
    )

    /// The server error `pylsp` sends for a method it does not have.
    private static let methodNotFound = WireError.serverError(code: -32601, message: "Method Not Found: textDocument/prepareCallHierarchy")

    /// Makes a session over `connection` that advertises no gated method.
    private static func sessionWithoutGatedMethods(
        over connection: FakeLanguageServerConnection,
        failureLog: CapturedLogLines = CapturedLogLines()
    ) -> LspSession<FakeLanguageServerConnection> {
        LspSession(
            connection: connection,
            languageID: "python",
            serverName: "pylsp",
            capabilities: noGatedMethod,
            failureLog: failureLog.append
        )
    }

    // MARK: - Capability gate

    @Test
    func prepareCallHierarchyIsNotSentWhenTheServerDoesNotAdvertiseCallHierarchy() async {
        let connection = FakeLanguageServerConnection()
        let session = Self.sessionWithoutGatedMethods(over: connection)

        await #expect(throws: LspSessionError.notAdvertised(.prepareCallHierarchy)) {
            try await session.prepareCallHierarchy(uri: Self.uri, position: Self.position)
        }
        #expect(await connection.calls.isEmpty)
    }

    @Test
    func outgoingCallsIsNotSentWhenTheServerDoesNotAdvertiseCallHierarchy() async {
        let connection = FakeLanguageServerConnection()
        let session = Self.sessionWithoutGatedMethods(over: connection)

        await #expect(throws: LspSessionError.notAdvertised(.outgoingCalls)) {
            try await session.outgoingCalls(item: Self.item)
        }
        #expect(await connection.calls.isEmpty)
    }

    @Test
    func incomingCallsIsNotSentWhenTheServerDoesNotAdvertiseCallHierarchy() async {
        let connection = FakeLanguageServerConnection()
        let session = Self.sessionWithoutGatedMethods(over: connection)

        await #expect(throws: LspSessionError.notAdvertised(.incomingCalls)) {
            try await session.incomingCalls(item: Self.item)
        }
        #expect(await connection.calls.isEmpty)
    }

    @Test
    func workspaceSymbolsIsNotSentWhenTheServerDoesNotAdvertiseWorkspaceSymbols() async {
        let connection = FakeLanguageServerConnection()
        let session = Self.sessionWithoutGatedMethods(over: connection)

        await #expect(throws: LspSessionError.notAdvertised(.workspaceSymbols)) {
            try await session.workspaceSymbols(query: "helper")
        }
        #expect(await connection.calls.isEmpty)
    }

    @Test
    func implementationsIsNotSentWhenTheServerDoesNotAdvertiseImplementations() async {
        let connection = FakeLanguageServerConnection()
        let session = Self.sessionWithoutGatedMethods(over: connection)

        await #expect(throws: LspSessionError.notAdvertised(.implementations)) {
            try await session.implementations(uri: Self.uri, at: Self.position)
        }
        #expect(await connection.calls.isEmpty)
    }

    @Test
    func referencesIsSentAlsoWhenTheServerAdvertisesNoGatedMethod() async throws {
        let connection = FakeLanguageServerConnection()
        let session = Self.sessionWithoutGatedMethods(over: connection)

        _ = try await session.references(uri: Self.uri, at: Self.position, includeDeclaration: false)

        #expect(await connection.calls == [.references(uri: Self.uri, position: Self.position, includeDeclaration: false)])
    }

    @Test
    func prepareCallHierarchyIsSentWhenTheServerAdvertisesCallHierarchy() async throws {
        let connection = FakeLanguageServerConnection()
        let session = LspSession(
            connection: connection,
            languageID: "swift",
            serverName: "sourcekit-lsp",
            capabilities: ServerCapabilities(callHierarchy: true, workspaceSymbol: false, implementation: false)
        )

        _ = try await session.prepareCallHierarchy(uri: Self.uri, position: Self.position)

        #expect(await connection.calls == [.prepareCallHierarchy(uri: Self.uri, position: Self.position)])
    }

    @Test
    func notAdvertisedDescriptionNamesTheRequest() {
        let error: Error = LspSessionError.notAdvertised(.prepareCallHierarchy)

        #expect(error.localizedDescription == "the server does not advertise prepareCallHierarchy")
    }

    // MARK: - Failure log

    @Test
    func aFailureLogLineNamesTheServerTheRequestTheCodeAndTheMessage() async {
        let lines = CapturedLogLines()
        let session = Self.sessionWithoutGatedMethods(over: FakeLanguageServerConnection(), failureLog: lines)

        await session.logFailure(of: .prepareCallHierarchy, context: "django/utils/tree.py:make_hashable", error: Self.methodNotFound)

        #expect(
            lines.all == [
                "pylsp: prepareCallHierarchy failed for django/utils/tree.py:make_hashable: "
                    + "server error -32601: Method Not Found: textDocument/prepareCallHierarchy "
                    + "(the log does not show the next prepareCallHierarchy failures of this server)"
            ])
    }

    @Test
    func aRequestThatFailsForEachSymbolIsLoggedOneTime() async {
        let lines = CapturedLogLines()
        let session = Self.sessionWithoutGatedMethods(over: FakeLanguageServerConnection(), failureLog: lines)

        for symbol in ["make_hashable", "Node", "add"] {
            await session.logFailure(of: .prepareCallHierarchy, context: "tree.py:\(symbol)", error: Self.methodNotFound)
        }

        #expect(lines.all.count == 1)
    }

    @Test
    func eachFailingRequestGetsItsOwnLogLine() async {
        let lines = CapturedLogLines()
        let session = Self.sessionWithoutGatedMethods(over: FakeLanguageServerConnection(), failureLog: lines)

        await session.logFailure(of: .prepareCallHierarchy, context: "tree.py:add", error: Self.methodNotFound)
        await session.logFailure(of: .references, context: "tree.py:add", error: Self.methodNotFound)
        await session.logFailure(of: .references, context: "tree.py:Node", error: Self.methodNotFound)

        #expect(lines.all.count == 2)
    }
}

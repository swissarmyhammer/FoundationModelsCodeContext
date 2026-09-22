import Foundation
import Testing

@testable import FoundationModelsCodeContext

/// Tests for the capability gate and the failure log of `LspSession`.
///
/// A server that does not advertise a gated method gets no request for it
/// (`pylsp` has no call hierarchy, no workspace symbols and no
/// implementations). A server that advertises a gated method gets the
/// request. A request failure is logged one time for each (server, request)
/// pair, with the code and the message of the server error.
struct LspSessionCapabilityTests {
    /// Capabilities of a server that advertises call hierarchy and no other gated method.
    private static let callHierarchyOnly = ServerCapabilities(callHierarchy: true, workspaceSymbol: false, implementation: false)

    /// Capabilities of a server that advertises workspace symbols and no other gated method.
    private static let workspaceSymbolOnly = ServerCapabilities(callHierarchy: false, workspaceSymbol: true, implementation: false)

    /// Capabilities of a server that advertises implementations and no other gated method.
    private static let implementationOnly = ServerCapabilities(callHierarchy: false, workspaceSymbol: false, implementation: true)

    /// The document every request in this suite is about.
    private static let uri = DocumentURI("file:///tmp/sample.py")

    /// The cursor position every request in this suite is about.
    private static let position = Position(line: 0, character: 4)

    /// The query of the workspace-symbol requests in this suite.
    private static let query = "helper"

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

    // MARK: - Capability gate: not advertised

    @Test
    func prepareCallHierarchyIsNotSentWhenTheServerDoesNotAdvertiseCallHierarchy() async {
        let connection = FakeLanguageServerConnection()
        let session = LspSession.makePylsp(over: connection)

        await #expect(throws: LspSessionError.notAdvertised(.prepareCallHierarchy)) {
            try await session.prepareCallHierarchy(uri: Self.uri, position: Self.position)
        }
        #expect(await connection.calls.isEmpty)
    }

    @Test
    func outgoingCallsIsNotSentWhenTheServerDoesNotAdvertiseCallHierarchy() async {
        let connection = FakeLanguageServerConnection()
        let session = LspSession.makePylsp(over: connection)

        await #expect(throws: LspSessionError.notAdvertised(.outgoingCalls)) {
            try await session.outgoingCalls(item: Self.item)
        }
        #expect(await connection.calls.isEmpty)
    }

    @Test
    func incomingCallsIsNotSentWhenTheServerDoesNotAdvertiseCallHierarchy() async {
        let connection = FakeLanguageServerConnection()
        let session = LspSession.makePylsp(over: connection)

        await #expect(throws: LspSessionError.notAdvertised(.incomingCalls)) {
            try await session.incomingCalls(item: Self.item)
        }
        #expect(await connection.calls.isEmpty)
    }

    @Test
    func workspaceSymbolsIsNotSentWhenTheServerDoesNotAdvertiseWorkspaceSymbols() async {
        let connection = FakeLanguageServerConnection()
        let session = LspSession.makePylsp(over: connection)

        await #expect(throws: LspSessionError.notAdvertised(.workspaceSymbols)) {
            try await session.workspaceSymbols(query: Self.query)
        }
        #expect(await connection.calls.isEmpty)
    }

    @Test
    func implementationsIsNotSentWhenTheServerDoesNotAdvertiseImplementations() async {
        let connection = FakeLanguageServerConnection()
        let session = LspSession.makePylsp(over: connection)

        await #expect(throws: LspSessionError.notAdvertised(.implementations)) {
            try await session.implementations(uri: Self.uri, at: Self.position)
        }
        #expect(await connection.calls.isEmpty)
    }

    @Test
    func referencesIsSentAlsoWhenTheServerAdvertisesNoGatedMethod() async throws {
        let connection = FakeLanguageServerConnection()
        let session = LspSession.makePylsp(over: connection)

        _ = try await session.references(uri: Self.uri, at: Self.position, includeDeclaration: false)

        #expect(await connection.calls == [.references(uri: Self.uri, position: Self.position, includeDeclaration: false)])
    }

    // MARK: - Capability gate: advertised

    @Test
    func prepareCallHierarchyIsSentWhenTheServerAdvertisesCallHierarchy() async throws {
        let connection = FakeLanguageServerConnection()
        let session = LspSession.makePylsp(over: connection, advertising: Self.callHierarchyOnly)

        _ = try await session.prepareCallHierarchy(uri: Self.uri, position: Self.position)

        #expect(await connection.calls == [.prepareCallHierarchy(uri: Self.uri, position: Self.position)])
    }

    @Test
    func outgoingCallsIsSentWhenTheServerAdvertisesCallHierarchy() async throws {
        let connection = FakeLanguageServerConnection()
        let session = LspSession.makePylsp(over: connection, advertising: Self.callHierarchyOnly)

        _ = try await session.outgoingCalls(item: Self.item)

        #expect(await connection.calls == [.outgoingCalls(item: Self.item)])
    }

    @Test
    func incomingCallsIsSentWhenTheServerAdvertisesCallHierarchy() async throws {
        let connection = FakeLanguageServerConnection()
        let session = LspSession.makePylsp(over: connection, advertising: Self.callHierarchyOnly)

        _ = try await session.incomingCalls(item: Self.item)

        #expect(await connection.calls == [.incomingCalls(item: Self.item)])
    }

    @Test
    func workspaceSymbolsIsSentWhenTheServerAdvertisesWorkspaceSymbols() async throws {
        let connection = FakeLanguageServerConnection()
        let session = LspSession.makePylsp(over: connection, advertising: Self.workspaceSymbolOnly)

        _ = try await session.workspaceSymbols(query: Self.query)

        #expect(await connection.calls == [.workspaceSymbols(query: Self.query)])
    }

    @Test
    func implementationsIsSentWhenTheServerAdvertisesImplementations() async throws {
        let connection = FakeLanguageServerConnection()
        let session = LspSession.makePylsp(over: connection, advertising: Self.implementationOnly)

        _ = try await session.implementations(uri: Self.uri, at: Self.position)

        #expect(await connection.calls == [.implementations(uri: Self.uri, position: Self.position)])
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
        let session = LspSession.makePylsp(over: FakeLanguageServerConnection(), failureLog: lines)

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
        let session = LspSession.makePylsp(over: FakeLanguageServerConnection(), failureLog: lines)

        for symbol in ["make_hashable", "Node", "add"] {
            await session.logFailure(of: .prepareCallHierarchy, context: "tree.py:\(symbol)", error: Self.methodNotFound)
        }

        #expect(lines.all.count == 1)
    }

    @Test
    func eachFailingRequestGetsItsOwnLogLine() async {
        let lines = CapturedLogLines()
        let session = LspSession.makePylsp(over: FakeLanguageServerConnection(), failureLog: lines)

        await session.logFailure(of: .prepareCallHierarchy, context: "tree.py:add", error: Self.methodNotFound)
        await session.logFailure(of: .references, context: "tree.py:add", error: Self.methodNotFound)
        await session.logFailure(of: .references, context: "tree.py:Node", error: Self.methodNotFound)

        #expect(lines.all.count == 2)
    }
}

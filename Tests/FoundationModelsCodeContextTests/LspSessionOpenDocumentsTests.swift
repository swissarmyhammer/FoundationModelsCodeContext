import Foundation
import Testing

@testable import FoundationModelsCodeContext

/// Tests for the open-document policy of `LspSession`: the limit on the number
/// of open documents, the least-recently-used close at the limit, the use
/// count that keeps a document open while an op uses it, and the sequence of
/// two syncs of one document at the same time.
///
/// Each test drives the session against `FakeLanguageServerConnection`, thus no
/// real server or JSON is involved.
struct LspSessionOpenDocumentsTests {
    /// The limit that each test gives the session. It is small, thus a test
    /// gets to the limit with few documents.
    private static let limit = 2

    /// The longest real time that a test waits for a second `didOpen` that
    /// must not come.
    private static let secondDidOpenTimeout: Duration = .milliseconds(200)

    /// The text that each test syncs. The text does not change the policy.
    private static let text = "let x = 1"

    /// The URI of the numbered fixture document `index`.
    private static func uri(_ index: Int) -> DocumentURI {
        DocumentURI("file:///tmp/doc\(index).swift")
    }

    /// The session under test, with a limit of `limit` open documents.
    private static func makeSession(over connection: FakeLanguageServerConnection) -> LspSession<FakeLanguageServerConnection> {
        LspSession(connection: connection, languageID: "swift", maximumOpenDocuments: limit)
    }

    /// The URIs of the `didClose` calls that `connection` got, in order.
    private static func closedURIs(_ connection: FakeLanguageServerConnection) async -> [DocumentURI] {
        await connection.uris { if case .didClose(let uri) = $0 { uri } else { nil } }
    }

    /// The number of `didOpen` calls that `connection` got.
    private static func didOpenCount(_ connection: FakeLanguageServerConnection) async -> Int {
        await connection.uris { if case .didOpen(let uri, _, _, _) = $0 { uri } else { nil } }.count
    }

    @Test
    func anOpenPastTheLimitClosesTheOldestDocument() async throws {
        let connection = FakeLanguageServerConnection()
        let session = Self.makeSession(over: connection)

        for index in 0...Self.limit {
            try await session.syncOpen(uri: Self.uri(index), text: Self.text, owner: .tool)
        }

        #expect(await Self.closedURIs(connection) == [Self.uri(0)])
        let open = await session.openDocuments()
        #expect(open.count == Self.limit)
        #expect(open[Self.uri(0)] == nil, "the oldest document must close")
    }

    @Test
    func aSyncMakesADocumentTheMostRecentlyUsed() async throws {
        let connection = FakeLanguageServerConnection()
        let session = Self.makeSession(over: connection)
        try await session.syncOpen(uri: Self.uri(0), text: Self.text, owner: .tool)
        try await session.syncOpen(uri: Self.uri(1), text: Self.text, owner: .tool)

        try await session.syncOpen(uri: Self.uri(0), text: Self.text, owner: .tool)
        try await session.syncOpen(uri: Self.uri(Self.limit), text: Self.text, owner: .tool)

        #expect(await Self.closedURIs(connection) == [Self.uri(1)])
    }

    @Test
    func aDocumentThatAnOpUsesIsNotClosedAtTheLimit() async throws {
        let connection = FakeLanguageServerConnection()
        let session = Self.makeSession(over: connection)
        try await session.beginUse(uri: Self.uri(0), text: Self.text, owner: .tool)
        try await session.syncOpen(uri: Self.uri(1), text: Self.text, owner: .tool)

        try await session.syncOpen(uri: Self.uri(Self.limit), text: Self.text, owner: .tool)

        #expect(await Self.closedURIs(connection) == [Self.uri(1)])
        #expect(await session.openDocuments()[Self.uri(0)] != nil, "a document in use must stay open")
        await session.endUse(uri: Self.uri(0))
    }

    @Test
    func anOpenFailsWhenEachOpenDocumentIsInUse() async throws {
        let connection = FakeLanguageServerConnection()
        let session = Self.makeSession(over: connection)
        for index in 0..<Self.limit {
            try await session.beginUse(uri: Self.uri(index), text: Self.text, owner: .tool)
        }

        await #expect(throws: LspSessionError.openDocumentLimit(Self.limit)) {
            try await session.syncOpen(uri: Self.uri(Self.limit), text: Self.text, owner: .tool)
        }

        #expect(await session.openDocuments().count == Self.limit)
        #expect(await Self.closedURIs(connection).isEmpty)
    }

    @Test
    func anOpenFailsWhenTheCloseAtTheLimitFails() async throws {
        let connection = FakeLanguageServerConnection()
        let session = Self.makeSession(over: connection)
        for index in 0..<Self.limit {
            try await session.syncOpen(uri: Self.uri(index), text: Self.text, owner: .tool)
        }
        await connection.setDidCloseResult(.failure(WireError.missingResult))

        await #expect(throws: WireError.missingResult) {
            try await session.syncOpen(uri: Self.uri(Self.limit), text: Self.text, owner: .tool)
        }

        let open = await session.openDocuments()
        #expect(open.count == Self.limit, "the count must not go above the limit")
        #expect(open[Self.uri(Self.limit)] == nil)
        #expect(await Self.didOpenCount(connection) == Self.limit)
    }

    @Test
    func twoSyncsOfOneDocumentAtTheSameTimeSendOneDidOpen() async throws {
        let connection = FakeLanguageServerConnection()
        let session = Self.makeSession(over: connection)
        let gate = AsyncGate()
        await connection.setDidOpenCallHook { await gate.waitUntilOpen() }

        let first = Task { try await session.syncOpen(uri: Self.uri(0), text: Self.text, owner: .tool) }
        try await waitUntil { await Self.didOpenCount(connection) == 1 }
        let second = Task { try await session.syncOpen(uri: Self.uri(0), text: Self.text, owner: .tool) }
        let sentSecondDidOpen = try await waitUntil(timeout: Self.secondDidOpenTimeout) {
            await Self.didOpenCount(connection) > 1
        }
        await gate.open()
        try await first.value
        try await second.value

        #expect(!sentSecondDidOpen)
        #expect(await Self.didOpenCount(connection) == 1)
        #expect(await session.openDocuments()[Self.uri(0)]?.version == 1)
    }

    @Test
    func closeIfOwnedClosesOnlyADocumentOfThatOwner() async throws {
        let connection = FakeLanguageServerConnection()
        let session = Self.makeSession(over: connection)
        try await session.syncOpen(uri: Self.uri(0), text: Self.text, owner: .indexer)
        try await session.syncOpen(uri: Self.uri(1), text: Self.text, owner: .tool)

        try await session.closeIfOwned(uri: Self.uri(0), by: .indexer)
        try await session.closeIfOwned(uri: Self.uri(1), by: .indexer)

        #expect(await Self.closedURIs(connection) == [Self.uri(0)])
    }

    @Test
    func aToolSyncMakesTheToolOpsTheOwner() async throws {
        let connection = FakeLanguageServerConnection()
        let session = Self.makeSession(over: connection)
        try await session.syncOpen(uri: Self.uri(0), text: Self.text, owner: .indexer)
        try await session.syncOpen(uri: Self.uri(0), text: Self.text, owner: .tool)
        try await session.syncOpen(uri: Self.uri(0), text: Self.text, owner: .indexer)

        try await session.closeIfOwned(uri: Self.uri(0), by: .indexer)

        #expect(await Self.closedURIs(connection).isEmpty, "the tool ops own the document from the first tool sync")
    }

    @Test
    func closeIfOwnedDoesNotCloseADocumentInUse() async throws {
        let connection = FakeLanguageServerConnection()
        let session = Self.makeSession(over: connection)
        try await session.beginUse(uri: Self.uri(0), text: Self.text, owner: .indexer)

        try await session.closeIfOwned(uri: Self.uri(0), by: .indexer)
        #expect(await Self.closedURIs(connection).isEmpty)

        await session.endUse(uri: Self.uri(0))
        try await session.closeIfOwned(uri: Self.uri(0), by: .indexer)
        #expect(await Self.closedURIs(connection) == [Self.uri(0)])
    }

    @Test
    func aFailedBeginUseEndsTheUse() async throws {
        let connection = FakeLanguageServerConnection()
        let session = Self.makeSession(over: connection)
        try await session.syncOpen(uri: Self.uri(0), text: Self.text, owner: .indexer)
        await connection.setDidChangeResult(.failure(WireError.missingResult))

        await #expect(throws: WireError.missingResult) {
            try await session.beginUse(uri: Self.uri(0), text: "let x = 2", owner: .indexer)
        }
        try await session.closeIfOwned(uri: Self.uri(0), by: .indexer)

        #expect(await Self.closedURIs(connection) == [Self.uri(0)], "a failed use must not keep the document in use")
    }
}

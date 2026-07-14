import Foundation
import Testing

@testable import FoundationModelsCodeContext

/// Tests for `LspSession`, driven entirely against `FakeLanguageServerConnection`
/// so no real subprocess or JSON is ever involved.
///
/// Covers the behaviors called out in plan.md's session semantics: the
/// open-document dedupe/versioning contract of `syncOpen`, the diagnostics
/// cache and multi-subscriber fan-out fed by `serverNotifications`, the
/// readiness state machine driven by pull-diagnostic "still loading"
/// replies, and the doc-set/cache reset used for restart correctness.
struct LspSessionTests {
    /// A single diagnostic at an arbitrary but fixed range, used where the
    /// test only cares about the diagnostic's identity (its `message`), not
    /// its position.
    private static func diagnostic(message: String) -> Diagnostic {
        Diagnostic(
            range: LSPRange(start: Position(line: 0, character: 0), end: Position(line: 0, character: 1)),
            severity: .error,
            code: nil,
            source: nil,
            message: message
        )
    }

    /// True if `call` is a `.didOpen` invocation, for counting occurrences
    /// in `FakeLanguageServerConnection.calls` without depending on its
    /// associated values.
    private static func isDidOpen(_ call: FakeLanguageServerConnection.Call) -> Bool {
        if case .didOpen = call { return true }
        return false
    }

    /// True if `call` is a `.didChange` invocation, mirroring `isDidOpen(_:)`.
    private static func isDidChange(_ call: FakeLanguageServerConnection.Call) -> Bool {
        if case .didChange = call { return true }
        return false
    }

    @Test
    func syncOpenSendsExactlyOneDidOpenForTheFirstCall() async throws {
        let connection = FakeLanguageServerConnection()
        let session = LspSession(connection: connection, languageID: "swift")
        let uri = DocumentURI("file:///tmp/a.swift")

        try await session.syncOpen(uri: uri, text: "let x = 1")

        let calls = await connection.calls
        #expect(calls.count == 1)
        #expect(calls == [.didOpen(uri: uri, languageID: "swift", version: 1, text: "let x = 1")])
    }

    @Test
    func syncOpenSuppressesDuplicateOpenWithIdenticalText() async throws {
        let connection = FakeLanguageServerConnection()
        let session = LspSession(connection: connection, languageID: "swift")
        let uri = DocumentURI("file:///tmp/b.swift")

        try await session.syncOpen(uri: uri, text: "let x = 1")
        try await session.syncOpen(uri: uri, text: "let x = 1")

        let calls = await connection.calls
        #expect(calls.filter(Self.isDidOpen).count == 1, "identical re-sync must not re-open the document")
        #expect(calls.filter(Self.isDidChange).count == 0, "identical re-sync must not emit a didChange")
    }

    @Test
    func syncOpenSendsDidChangeWithIncrementedVersionOnEditedText() async throws {
        let connection = FakeLanguageServerConnection()
        let session = LspSession(connection: connection, languageID: "swift")
        let uri = DocumentURI("file:///tmp/c.swift")

        try await session.syncOpen(uri: uri, text: "let x = 1")
        try await session.syncOpen(uri: uri, text: "let x = 2")

        let calls = await connection.calls
        #expect(calls.filter(Self.isDidOpen).count == 1, "an edit must not re-open the document")
        #expect(calls == [
            .didOpen(uri: uri, languageID: "swift", version: 1, text: "let x = 1"),
            .didChange(uri: uri, version: 2, text: "let x = 2"),
        ])

        let docs = await session.openDocuments()
        #expect(docs[uri]?.version == 2)
    }

    @Test
    func syncOpenSuppressesNoOpChangeWithIdenticalText() async throws {
        let connection = FakeLanguageServerConnection()
        let session = LspSession(connection: connection, languageID: "swift")
        let uri = DocumentURI("file:///tmp/d.swift")

        try await session.syncOpen(uri: uri, text: "let x = 1")
        try await session.syncOpen(uri: uri, text: "let x = 2")
        try await session.syncOpen(uri: uri, text: "let x = 2")

        let calls = await connection.calls
        #expect(calls.filter(Self.isDidChange).count == 1, "a repeated identical sync must not emit a second didChange")
    }

    @Test
    func publishDiagnosticsNotificationUpdatesTheCache() async throws {
        let connection = FakeLanguageServerConnection()
        let session = LspSession(connection: connection, languageID: "swift")
        let uri = DocumentURI("file:///tmp/e.swift")

        var updates = await session.diagnosticUpdates().makeAsyncIterator()
        await connection.emit(notification: .publishDiagnostics(uri: uri, diagnostics: [Self.diagnostic(message: "boom")]))
        _ = await updates.next()

        let cached = await session.diagnostics(for: uri)
        #expect(cached.count == 1)
        #expect(cached.first?.message == "boom")
    }

    @Test
    func publishDiagnosticsNotificationReachesEverySubscriber() async throws {
        let connection = FakeLanguageServerConnection()
        let session = LspSession(connection: connection, languageID: "swift")
        let uri = DocumentURI("file:///tmp/f.swift")

        var firstSubscriber = await session.diagnosticUpdates().makeAsyncIterator()
        var secondSubscriber = await session.diagnosticUpdates().makeAsyncIterator()

        await connection.emit(notification: .publishDiagnostics(uri: uri, diagnostics: [Self.diagnostic(message: "shared")]))

        let firstUpdate = await firstSubscriber.next()
        let secondUpdate = await secondSubscriber.next()

        #expect(firstUpdate?.uri == uri)
        #expect(firstUpdate?.diagnostics.first?.message == "shared")
        #expect(secondUpdate?.uri == uri)
        #expect(secondUpdate?.diagnostics.first?.message == "shared")
    }

    @Test
    func pullDiagnosticsFeedsTheSameCacheAsPush() async throws {
        let connection = FakeLanguageServerConnection()
        let session = LspSession(connection: connection, languageID: "swift")
        let uri = DocumentURI("file:///tmp/g.swift")

        await connection.setPullDiagnosticsResult(.success([Self.diagnostic(message: "pulled")]))

        let pulled = try await session.pullDiagnostics(uri: uri)
        #expect(pulled.count == 1)
        #expect(pulled.first?.message == "pulled")

        let cached = await session.diagnostics(for: uri)
        #expect(cached.count == 1)
        #expect(cached.first?.message == "pulled")
    }

    @Test
    func pullDiagnosticsReachesEverySubscriber() async throws {
        let connection = FakeLanguageServerConnection()
        let session = LspSession(connection: connection, languageID: "swift")
        let uri = DocumentURI("file:///tmp/pulled-fanout.swift")

        var firstSubscriber = await session.diagnosticUpdates().makeAsyncIterator()
        var secondSubscriber = await session.diagnosticUpdates().makeAsyncIterator()

        await connection.setPullDiagnosticsResult(.success([Self.diagnostic(message: "pulled-shared")]))
        _ = try await session.pullDiagnostics(uri: uri)

        let firstUpdate = await firstSubscriber.next()
        let secondUpdate = await secondSubscriber.next()

        #expect(firstUpdate?.uri == uri)
        #expect(firstUpdate?.diagnostics.first?.message == "pulled-shared")
        #expect(secondUpdate?.uri == uri)
        #expect(secondUpdate?.diagnostics.first?.message == "pulled-shared")
    }

    @Test
    func pullDiagnosticsServerCancelledFlipsReadinessFalseWithoutCaching() async throws {
        let connection = FakeLanguageServerConnection()
        let session = LspSession(connection: connection, languageID: "swift")
        let uri = DocumentURI("file:///tmp/h.swift")

        let readyBefore = await session.isReady
        #expect(readyBefore, "a fresh session starts ready")

        await connection.setPullDiagnosticsResult(.failure(WireError.serverError(code: -32802, message: "server cancelled")))

        let pulled = try await session.pullDiagnostics(uri: uri)
        #expect(pulled.isEmpty, "a not-ready pull yields no diagnostics")

        let readyAfter = await session.isReady
        #expect(!readyAfter, "a ServerCancelled pull must mark the session not-ready")

        let cached = await session.diagnostics(for: uri)
        #expect(cached.isEmpty, "a not-ready pull must not cache an empty (clean) set")
    }

    @Test
    func pullDiagnosticsContentModifiedFlipsReadinessFalse() async throws {
        let connection = FakeLanguageServerConnection()
        let session = LspSession(connection: connection, languageID: "swift")
        let uri = DocumentURI("file:///tmp/i.swift")

        await connection.setPullDiagnosticsResult(.failure(WireError.serverError(code: -32801, message: "content modified")))

        _ = try await session.pullDiagnostics(uri: uri)

        let readyAfter = await session.isReady
        #expect(!readyAfter, "a ContentModified pull must mark the session not-ready")
    }

    @Test
    func realPullAnswerMarksSessionReadyAgainAfterNotReady() async throws {
        let connection = FakeLanguageServerConnection()
        let session = LspSession(connection: connection, languageID: "swift")
        let uri = DocumentURI("file:///tmp/j.swift")

        await connection.setPullDiagnosticsResult(.failure(WireError.serverError(code: -32802, message: "server cancelled")))
        _ = try await session.pullDiagnostics(uri: uri)
        #expect(!(await session.isReady))

        await connection.setPullDiagnosticsResult(.success([]))
        _ = try await session.pullDiagnostics(uri: uri)
        #expect(await session.isReady, "a real (even empty) report means the server is ready again")
    }

    @Test
    func pullDiagnosticsGenuineErrorPropagatesWithoutTouchingReadinessOrCache() async throws {
        let connection = FakeLanguageServerConnection()
        let session = LspSession(connection: connection, languageID: "swift")
        let uri = DocumentURI("file:///tmp/genuine-error.swift")

        await connection.setPullDiagnosticsResult(.failure(WireError.serverError(code: -32000, message: "boom")))

        await #expect(throws: WireError.self) {
            _ = try await session.pullDiagnostics(uri: uri)
        }

        #expect(await session.isReady, "a genuine (non-not-ready) error must not flip readiness")
        #expect(await session.diagnostics(for: uri).isEmpty, "a genuine error must not cache anything")
    }

    @Test
    func terminatedSubscriberIsRemovedFromTheFanOutSet() async throws {
        let connection = FakeLanguageServerConnection()
        let session = LspSession(connection: connection, languageID: "swift")

        let stream = await session.diagnosticUpdates()
        #expect(await session.diagnosticsSubscriberCount() == 1)

        // Cancelling the consuming task terminates the stream's iteration,
        // which fires `onTermination` and should remove the subscriber's
        // continuation from the session's fan-out set.
        let consumer = Task {
            for await _ in stream {}
        }
        consumer.cancel()
        _ = await consumer.value

        // `onTermination` hops back onto the actor via a detached `Task`, so
        // poll briefly for that hop to land rather than asserting immediately.
        var remaining = await session.diagnosticsSubscriberCount()
        var attempts = 0
        while remaining != 0, attempts < 100 {
            try await Task.sleep(for: .milliseconds(10))
            remaining = await session.diagnosticsSubscriberCount()
            attempts += 1
        }
        #expect(remaining == 0, "a terminated subscriber must be removed from the fan-out set")
    }

    @Test
    func resetDocumentsLetsTheNextSyncOpenReopen() async throws {
        let connection = FakeLanguageServerConnection()
        let session = LspSession(connection: connection, languageID: "swift")
        let uri = DocumentURI("file:///tmp/k.swift")

        try await session.syncOpen(uri: uri, text: "let x = 1")
        #expect(await connection.calls.filter(Self.isDidOpen).count == 1)

        await session.resetDocuments()
        let docsAfterReset = await session.openDocuments()
        #expect(docsAfterReset.isEmpty, "reset must forget every open document")

        try await session.syncOpen(uri: uri, text: "let x = 1")
        let openCount = await connection.calls.filter(Self.isDidOpen).count
        #expect(openCount == 2, "re-sync after reset must emit a fresh didOpen, not a suppressed duplicate")
    }

    @Test
    func resetDocumentsClearsTheDiagnosticsCache() async throws {
        let connection = FakeLanguageServerConnection()
        let session = LspSession(connection: connection, languageID: "swift")
        let uri = DocumentURI("file:///tmp/l.swift")

        var updates = await session.diagnosticUpdates().makeAsyncIterator()
        await connection.emit(notification: .publishDiagnostics(uri: uri, diagnostics: [Self.diagnostic(message: "stale")]))
        _ = await updates.next()
        #expect(await session.diagnostics(for: uri).count == 1)

        await session.resetDocuments()

        #expect(await session.diagnostics(for: uri).isEmpty, "reset must clear the derived diagnostics cache")
    }

    @Test
    func diagnosticsForUnknownURIIsEmpty() async throws {
        let connection = FakeLanguageServerConnection()
        let session = LspSession(connection: connection, languageID: "swift")

        let cached = await session.diagnostics(for: DocumentURI("file:///tmp/never-seen.swift"))
        #expect(cached.isEmpty)
    }
}

import Foundation
import GRDB
import Testing

@testable import FoundationModelsCodeContext

/// Tests for `LSPIndexWorker`: the drain → documentSymbol → call-hierarchy →
/// persist → mark-indexed cycle against a real on-disk `Store`, driven
/// entirely through `FakeLanguageServerConnection` so no real subprocess or
/// JSON is ever involved.
///
/// Covers the acceptance criteria from the LSP indexer worker task: flattened
/// symbols with qualified paths and lsp-sourced edges persist from a
/// scripted fixture drain, a shrinking symbol set propagates invalidation to
/// dependent files, a connection error mid-batch leaves the failing file
/// dirty with no partial rows while the rest of the batch still proceeds,
/// and idle/session-unavailable backoff is paced by an injectable clock.
struct LSPIndexWorkerTests {
    // MARK: - Fixtures

    /// Builds a `DocumentSymbol` fixture with a `selectionRange` inside
    /// `range` (matching a real server's shape), defaulting `startColumn`/
    /// `endColumn` to values that keep the fixture terse for tests that
    /// don't care about columns.
    private static func documentSymbol(
        name: String,
        kind: SymbolKind,
        startLine: Int,
        endLine: Int,
        detail: String? = nil,
        children: [DocumentSymbol]? = nil
    ) -> DocumentSymbol {
        DocumentSymbol(
            name: name,
            detail: detail,
            kind: kind,
            range: LSPRange(start: Position(line: startLine, character: 0), end: Position(line: endLine, character: 1)),
            selectionRange: LSPRange(start: Position(line: startLine, character: 0), end: Position(line: startLine, character: name.count)),
            children: children
        )
    }

    /// Builds the `DocumentURI` `LSPIndexWorker` computes internally for a
    /// workspace-relative path, so a test can script a `CallHierarchyItem`'s
    /// `uri` to point at a specific fixture file.
    private static func uri(for relativePath: String, in root: URL) -> DocumentURI {
        DocumentURI(root.appendingPathComponent(relativePath).absoluteString)
    }

    /// Builds a `CallHierarchyItem` fixture naming a single-line symbol.
    private static func callHierarchyItem(name: String, uri: DocumentURI) -> CallHierarchyItem {
        CallHierarchyItem(
            name: name,
            kind: .function,
            detail: nil,
            uri: uri,
            range: LSPRange(start: Position(line: 0, character: 0), end: Position(line: 0, character: 1)),
            selectionRange: LSPRange(start: Position(line: 0, character: 0), end: Position(line: 0, character: name.count))
        )
    }

    /// Seeds `filePath`'s `indexed_files` row as fully dirty (all three
    /// layers `0`), the state `LSPIndexWorker` expects to find a file in
    /// before draining it.
    private static func seedDirty(store: Store, filePath: String) async throws {
        try await store.markDirty(filePath: filePath, contentHash: Data(filePath.utf8), fileSize: 1)
    }

    // MARK: - Golden drain: flattened symbols with qualified paths

    @Test
    func drainBatchPersistsFlattenedSymbolsFromNestedDocumentSymbols() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("struct Sample {\n    func method() {}\n}\n", to: "Sample.swift", in: root)
            try await Self.seedDirty(store: store, filePath: "Sample.swift")

            let connection = FakeLanguageServerConnection()
            let structSymbol = Self.documentSymbol(
                name: "Sample",
                kind: .struct,
                startLine: 0,
                endLine: 2,
                children: [Self.documentSymbol(name: "method", kind: .method, startLine: 1, endLine: 1)]
            )
            await connection.setDocumentSymbolsResult(.success([structSymbol]))

            let session = LspSession(connection: connection, languageID: "swift")
            let indexedCount = try await LSPIndexWorker<FakeLanguageServerConnection>.drainBatch(
                store: store,
                rootDirectory: root,
                extensions: ["swift"],
                session: session
            )

            #expect(indexedCount == 1)
            #expect(try await store.drainLspDirty().isEmpty)

            let rows: [[String]] = try await store.read { db in
                try Row.fetchAll(
                    db,
                    sql: "SELECT name, kind, start_line FROM lsp_symbols ORDER BY start_line"
                ).map { row in
                    ["\(row["name"] as String)", "\(row["kind"] as String)", "\(row["start_line"] as Int)"]
                }
            }
            #expect(rows == [["Sample", "struct", "0"], ["method", "method", "1"]])
        }
    }

    @Test
    func drainBatchClosesTheDocumentAfterQuerying() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("func topLevel() {}\n", to: "Sample.swift", in: root)
            try await Self.seedDirty(store: store, filePath: "Sample.swift")

            let connection = FakeLanguageServerConnection()
            await connection.setDocumentSymbolsResult(
                .success([Self.documentSymbol(name: "topLevel", kind: .function, startLine: 0, endLine: 0)])
            )

            let session = LspSession(connection: connection, languageID: "swift")
            try await LSPIndexWorker<FakeLanguageServerConnection>.drainBatch(
                store: store,
                rootDirectory: root,
                extensions: ["swift"],
                session: session
            )

            let calls = await connection.calls
            #expect(
                calls.contains(where: { if case .didClose = $0 { true } else { false } }),
                "the worker must close the document after querying it"
            )
        }
    }

    // MARK: - LSP-sourced call edges

    @Test
    func drainBatchPersistsLspSourcedCallEdgeFromCallHierarchy() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("func helper() {}\n", to: "A.swift", in: root)
            try write("func caller() { helper() }\n", to: "B.swift", in: root)
            try await Self.seedDirty(store: store, filePath: "A.swift")

            let connection = FakeLanguageServerConnection()
            let session = LspSession(connection: connection, languageID: "swift")

            // Drain A first, so its `helper` symbol row exists before B's
            // outgoing call resolves against it. B is not yet dirty, so this
            // pass only ever touches A.
            await connection.setDocumentSymbolsResult(
                .success([Self.documentSymbol(name: "helper", kind: .function, startLine: 0, endLine: 0)])
            )
            _ = try await LSPIndexWorker<FakeLanguageServerConnection>.drainBatch(
                store: store, rootDirectory: root, extensions: ["swift"], session: session
            )

            // Now mark B dirty and drain it: its own symbol is `caller`, and
            // its outgoing call hierarchy points at `helper` in A.swift.
            try await Self.seedDirty(store: store, filePath: "B.swift")
            let callerSymbol = Self.documentSymbol(name: "caller", kind: .function, startLine: 0, endLine: 0)
            let calleeItem = Self.callHierarchyItem(name: "helper", uri: Self.uri(for: "A.swift", in: root))
            let callerItem = Self.callHierarchyItem(name: "caller", uri: Self.uri(for: "B.swift", in: root))

            await connection.setDocumentSymbolsResult(.success([callerSymbol]))
            await connection.setPrepareCallHierarchyResult(.success([callerItem]))
            await connection.setOutgoingCallsResult(.success([
                CallHierarchyOutgoingCall(
                    to: calleeItem,
                    fromRanges: [LSPRange(start: Position(line: 0, character: 17), end: Position(line: 0, character: 23))]
                ),
            ]))

            let indexedCount = try await LSPIndexWorker<FakeLanguageServerConnection>.drainBatch(
                store: store, rootDirectory: root, extensions: ["swift"], session: session
            )
            #expect(indexedCount == 1)

            let edgeRows: [[String]] = try await store.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                    SELECT caller.name AS caller_name, callee.name AS callee_name, e.file_path, e.source, e.from_ranges \
                    FROM lsp_call_edges e \
                    JOIN lsp_symbols caller ON caller.id = e.caller_id \
                    JOIN lsp_symbols callee ON callee.id = e.callee_id
                    """
                ).map { row in
                    [
                        row["caller_name"] as String, row["callee_name"] as String, row["file_path"] as String,
                        row["source"] as String, row["from_ranges"] as String,
                    ]
                }
            }
            #expect(edgeRows == [["caller", "helper", "B.swift", "lsp", "[[0,17,0,23]]"]])
        }
    }

    // MARK: - Invalidation

    @Test
    func shrinkingASymbolSetMarksDependentFilesLspDirty() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("func helper() {}\nfunc other() {}\n", to: "A.swift", in: root)
            try write("func caller() { helper() }\n", to: "B.swift", in: root)
            try await Self.seedDirty(store: store, filePath: "A.swift")

            let connection = FakeLanguageServerConnection()
            let session = LspSession(connection: connection, languageID: "swift")

            // A starts with two symbols: `helper` and `other`. B is not yet
            // dirty, so this pass only ever touches A.
            await connection.setDocumentSymbolsResult(.success([
                Self.documentSymbol(name: "helper", kind: .function, startLine: 0, endLine: 0),
                Self.documentSymbol(name: "other", kind: .function, startLine: 1, endLine: 1),
            ]))
            _ = try await LSPIndexWorker<FakeLanguageServerConnection>.drainBatch(
                store: store, rootDirectory: root, extensions: ["swift"], session: session
            )

            // Now mark B dirty: it calls A's `helper`, producing an
            // lsp-sourced edge into it.
            try await Self.seedDirty(store: store, filePath: "B.swift")
            let calleeItem = Self.callHierarchyItem(name: "helper", uri: Self.uri(for: "A.swift", in: root))
            let callerItem = Self.callHierarchyItem(name: "caller", uri: Self.uri(for: "B.swift", in: root))

            await connection.setDocumentSymbolsResult(
                .success([Self.documentSymbol(name: "caller", kind: .function, startLine: 0, endLine: 0)])
            )
            await connection.setPrepareCallHierarchyResult(.success([callerItem]))
            await connection.setOutgoingCallsResult(.success([
                CallHierarchyOutgoingCall(
                    to: calleeItem,
                    fromRanges: [LSPRange(start: Position(line: 0, character: 17), end: Position(line: 0, character: 23))]
                ),
            ]))
            _ = try await LSPIndexWorker<FakeLanguageServerConnection>.drainBatch(
                store: store, rootDirectory: root, extensions: ["swift"], session: session
            )

            let edgeCountBeforeShrink = try await store.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM lsp_call_edges") ?? 0
            }
            #expect(edgeCountBeforeShrink == 1)
            #expect(try await store.drainLspDirty().isEmpty, "both files should be clean before the shrink")

            // Re-index A with `helper` removed but `other` kept at its
            // original line 1 (blanking line 0 rather than deleting it, so
            // `other`'s start line doesn't collide with `helper`'s old
            // position — a collision would make the upsert below rename
            // `helper`'s row in place instead of deleting it, since both
            // would resolve to the same `(file_path, start_line)` identity).
            // `other` remains a callable `.function` symbol, so its own
            // call-hierarchy scripting must be reset to empty here — leaving
            // B's stale `prepareCallHierarchyResult`/`outgoingCallsResult`
            // scripted would otherwise splice a bogus edge back onto the
            // just-deleted `helper` symbol within this same pass.
            try write("\nfunc other() {}\n", to: "A.swift", in: root)
            try await store.markDirty(filePath: "A.swift", contentHash: Data("A.swift-v2".utf8), fileSize: 2)
            await connection.setDocumentSymbolsResult(.success([
                Self.documentSymbol(name: "other", kind: .function, startLine: 1, endLine: 1),
            ]))
            await connection.setPrepareCallHierarchyResult(.success([]))
            await connection.setOutgoingCallsResult(.success([]))
            _ = try await LSPIndexWorker<FakeLanguageServerConnection>.drainBatch(
                store: store, rootDirectory: root, extensions: ["swift"], session: session
            )

            // B held an edge into the now-deleted `helper` symbol, so it must
            // be flagged lsp-dirty for a later pass to refresh its edges.
            let dirtyAfterShrink = try await store.drainLspDirty()
            #expect(dirtyAfterShrink == ["B.swift"])

            let helperRowCount = try await store.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM lsp_symbols WHERE name = 'helper'") ?? 0
            }
            #expect(helperRowCount == 0, "the deleted symbol's row must be gone")

            let edgeCountAfterShrink = try await store.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM lsp_call_edges") ?? 0
            }
            #expect(edgeCountAfterShrink == 0, "the cascade must remove the edge into the deleted symbol")
        }
    }

    // MARK: - Mid-batch atomicity

    @Test
    func drainBatchLeavesAFailingFileDirtyWithNoPartialRowsAndContinuesTheBatch() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("func fromA() {}\n", to: "A.swift", in: root)
            try write("func fromB() {}\n", to: "B.swift", in: root)
            try await Self.seedDirty(store: store, filePath: "A.swift")
            try await Self.seedDirty(store: store, filePath: "B.swift")

            let connection = FakeLanguageServerConnection()
            await connection.setDocumentSymbolsResult(.failure(SimulatedConnectionFailure()))

            let session = LspSession(connection: connection, languageID: "swift")
            let indexedCount = try await LSPIndexWorker<FakeLanguageServerConnection>.drainBatch(
                store: store, rootDirectory: root, extensions: ["swift"], session: session
            )

            #expect(indexedCount == 0)

            let stillDirty = try await store.drainLspDirty()
            #expect(stillDirty == ["A.swift", "B.swift"], "a documentSymbol failure must leave both files dirty")

            let symbolCount = try await store.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM lsp_symbols") ?? 0
            }
            #expect(symbolCount == 0, "no partial rows may be committed for a file whose symbol phase failed")

            // Both files must have been *attempted* — proving the loop
            // continues to the next dirty file after the first one throws,
            // rather than aborting the whole batch on the first failure.
            let queriedURIs: Set<DocumentURI> = await Set(connection.calls.compactMap { call in
                if case let .documentSymbols(uri) = call { return uri }
                return nil
            })
            #expect(queriedURIs == [Self.uri(for: "A.swift", in: root), Self.uri(for: "B.swift", in: root)])
        }
    }

    @Test
    func aFileThatFailedPreviouslySucceedsCleanlyOnceTheConnectionRecovers() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("func fromA() {}\n", to: "A.swift", in: root)
            try await Self.seedDirty(store: store, filePath: "A.swift")

            let connection = FakeLanguageServerConnection()
            await connection.setDocumentSymbolsResult(.failure(SimulatedConnectionFailure()))
            let session = LspSession(connection: connection, languageID: "swift")

            _ = try await LSPIndexWorker<FakeLanguageServerConnection>.drainBatch(
                store: store, rootDirectory: root, extensions: ["swift"], session: session
            )
            #expect(try await store.drainLspDirty() == ["A.swift"])

            await connection.setDocumentSymbolsResult(
                .success([Self.documentSymbol(name: "fromA", kind: .function, startLine: 0, endLine: 0)])
            )
            let indexedCount = try await LSPIndexWorker<FakeLanguageServerConnection>.drainBatch(
                store: store, rootDirectory: root, extensions: ["swift"], session: session
            )

            #expect(indexedCount == 1)
            #expect(try await store.drainLspDirty().isEmpty)
            let symbolNames: [String] = try await store.read { db in
                try String.fetchAll(db, sql: "SELECT name FROM lsp_symbols")
            }
            #expect(symbolNames == ["fromA"])
        }
    }

    // MARK: - Unreadable file handling

    @Test
    func drainBatchMarksAnUnreadableFileIndexedWithoutTouchingTheConnection() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            // Seed the row without writing the file to disk, so it's unreadable.
            try await Self.seedDirty(store: store, filePath: "Missing.swift")

            let connection = FakeLanguageServerConnection()
            let session = LspSession(connection: connection, languageID: "swift")

            let indexedCount = try await LSPIndexWorker<FakeLanguageServerConnection>.drainBatch(
                store: store, rootDirectory: root, extensions: ["swift"], session: session
            )

            #expect(indexedCount == 1)
            #expect(try await store.drainLspDirty().isEmpty)
            let calls = await connection.calls
            #expect(calls.isEmpty, "an unreadable file must never reach the connection")
        }
    }

    // MARK: - Path-traversal rejection

    @Test
    func drainBatchRejectsAPathTraversalRelativePathWithoutTouchingTheConnection() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            // A real, readable file sitting just outside the workspace root —
            // if `..` components in `file_path` were resolved instead of
            // rejected, this file would actually be read and indexed,
            // proving the traversal is live rather than coincidentally
            // absent (an outright-missing target would hit the pre-existing
            // "unreadable file" skip either way and wouldn't discriminate).
            try write("func secret() {}\n", to: "../secret.swift", in: root)
            // A `file_path` that escapes the workspace root should never be
            // resolved against disk or handed to the language server, even
            // though `dirtyFiles` will happily return whatever string is
            // stored in `indexed_files.file_path`.
            try await Self.seedDirty(store: store, filePath: "../secret.swift")

            let connection = FakeLanguageServerConnection()
            await connection.setDocumentSymbolsResult(
                .success([Self.documentSymbol(name: "secret", kind: .function, startLine: 0, endLine: 0)])
            )
            let session = LspSession(connection: connection, languageID: "swift")

            let indexedCount = try await LSPIndexWorker<FakeLanguageServerConnection>.drainBatch(
                store: store, rootDirectory: root, extensions: ["swift"], session: session
            )

            #expect(indexedCount == 1)
            #expect(try await store.drainLspDirty().isEmpty)
            let calls = await connection.calls
            #expect(calls.isEmpty, "a path-traversal relative path must never reach the connection")
            let symbolCount = try await store.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM lsp_symbols") ?? 0
            }
            #expect(symbolCount == 0, "the out-of-root file's symbols must never be persisted")
        }
    }

    // MARK: - Extension filtering

    @Test
    func dirtyFilesNotMatchingExtensionsAreLeftUntouched() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("func topLevel() {}\n", to: "Sample.py", in: root)
            try await Self.seedDirty(store: store, filePath: "Sample.py")

            let connection = FakeLanguageServerConnection()
            let session = LspSession(connection: connection, languageID: "swift")

            let indexedCount = try await LSPIndexWorker<FakeLanguageServerConnection>.drainBatch(
                store: store, rootDirectory: root, extensions: ["swift"], session: session
            )

            #expect(indexedCount == 0)
            #expect(try await store.drainLspDirty() == ["Sample.py"])
        }
    }

    // MARK: - Idle / session-unavailable backoff (ManualClock)

    @Test
    func runSleepsForIdleSleepWhenNoDirtyFilesThenDrainsOnceOneAppears() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            let connection = FakeLanguageServerConnection()
            let session = LspSession(connection: connection, languageID: "swift")
            let clock = ManualClock()
            let configuration = LSPIndexWorkerConfiguration()

            let runTask = Task {
                try await LSPIndexWorker<FakeLanguageServerConnection>.run(
                    store: store,
                    rootDirectory: root,
                    extensions: ["swift"],
                    sessionProvider: { session },
                    configuration: configuration,
                    clock: clock
                )
            }

            // The loop finds no dirty files and enters its idle sleep.
            await clock.waitForWaiter()

            // Seed a dirty file while the loop is asleep, then release the
            // idle sleep by advancing by exactly `idleSleep`.
            try write("func topLevel() {}\n", to: "Sample.swift", in: root)
            try await Self.seedDirty(store: store, filePath: "Sample.swift")
            await connection.setDocumentSymbolsResult(
                .success([Self.documentSymbol(name: "topLevel", kind: .function, startLine: 0, endLine: 0)])
            )
            clock.advance(by: configuration.idleSleep)

            // The loop drains the newly-dirty file, then goes idle again.
            await clock.waitForWaiter()
            runTask.cancel()
            _ = try? await runTask.value

            #expect(try await store.drainLspDirty().isEmpty)
            let symbolNames: [String] = try await store.read { db in
                try String.fetchAll(db, sql: "SELECT name FROM lsp_symbols")
            }
            #expect(symbolNames == ["topLevel"])
        }
    }

    @Test
    func runSleepsForSessionUnavailableSleepThenDrainsOnceASessionAppears() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("func topLevel() {}\n", to: "Sample.swift", in: root)
            try await Self.seedDirty(store: store, filePath: "Sample.swift")

            let connection = FakeLanguageServerConnection()
            await connection.setDocumentSymbolsResult(
                .success([Self.documentSymbol(name: "topLevel", kind: .function, startLine: 0, endLine: 0)])
            )

            let sessionBox = SessionBox()
            let clock = ManualClock()
            let configuration = LSPIndexWorkerConfiguration()

            let runTask = Task {
                try await LSPIndexWorker<FakeLanguageServerConnection>.run(
                    store: store,
                    rootDirectory: root,
                    extensions: ["swift"],
                    sessionProvider: { await sessionBox.current },
                    configuration: configuration,
                    clock: clock
                )
            }

            // A dirty file exists, but no session is available yet.
            await clock.waitForWaiter()
            #expect(try await store.drainLspDirty() == ["Sample.swift"], "must stay dirty while no session is available")

            // The daemon "starts": a session becomes available. Advancing by
            // exactly `sessionUnavailableSleep` releases the retry.
            await sessionBox.set(LspSession(connection: connection, languageID: "swift"))
            clock.advance(by: configuration.sessionUnavailableSleep)

            // The loop drains the file now that a session exists, then goes
            // idle again.
            await clock.waitForWaiter()
            runTask.cancel()
            _ = try? await runTask.value

            #expect(try await store.drainLspDirty().isEmpty)
        }
    }
}

/// An error a scripted `FakeLanguageServerConnection` throws to simulate a
/// connection failure (e.g. a broken pipe mid-request), distinct from any
/// production error type so a test can assert on it unambiguously.
private struct SimulatedConnectionFailure: Error {}

/// A settable box holding the current `LspSession`, used to script
/// `LSPIndexWorker.run`'s `sessionProvider` closure as "unavailable, then
/// available" without restarting the loop.
private actor SessionBox {
    var current: LspSession<FakeLanguageServerConnection>?

    func set(_ session: LspSession<FakeLanguageServerConnection>?) {
        current = session
    }
}

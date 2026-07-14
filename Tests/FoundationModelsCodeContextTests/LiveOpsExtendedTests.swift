import Foundation
import Testing

@testable import FoundationModelsCodeContext

/// A trivial error used to script a live-LSP request failure without
/// depending on any concrete `Error` type.
private struct InducedExtendedOpsError: Error {}

/// Tests for `LiveOpsExtended`'s five remaining v1 live ops: `codeActions`,
/// `renameEdits`, `inboundCalls`, `workspaceSymbols`, `lspStatus`.
///
/// Covers this task's acceptance criteria: `renameEdits`'s
/// `prepareRename`/`rename` atomicity under genuine concurrency and its
/// graceful `canRename: false` degradation with no live session,
/// `codeActions`'s codeAction-then-resolve flow, `inboundCalls`'s live/index
/// cascade and mapping, `workspaceSymbols`'s `anySession()` routing, and
/// `lspStatus`'s supervisor snapshot.
struct LiveOpsExtendedTests {
    // MARK: - Fixtures

    private static func serverSpec(command: String = "true") -> ServerSpec {
        ServerSpec(command: command, languageIDs: ["fake"], healthCheckInterval: .seconds(60), installHint: "install the fake LSP server")
    }

    /// Inserts one `lsp_symbols` row, mirroring `LayeredOpsTests.insertLspSymbol`.
    private static func insertLspSymbol(
        store: Store,
        id: Int64,
        name: String,
        kind: String = "function",
        filePath: String,
        startLine: Int,
        startColumn: Int = 0,
        endLine: Int,
        endColumn: Int = 0
    ) async throws {
        try await store.write { db in
            try db.execute(
                sql: """
                INSERT INTO lsp_symbols (id, name, kind, file_path, start_line, start_column, end_line, end_column, detail)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL)
                """,
                arguments: [id, name, kind, filePath, startLine, startColumn, endLine, endColumn]
            )
        }
    }

    /// Inserts one `lsp_call_edges` row from `callerID` to `calleeID`.
    private static func insertCallEdge(store: Store, callerID: Int64, calleeID: Int64, filePath: String) async throws {
        try await store.write { db in
            try db.execute(
                sql: """
                INSERT INTO lsp_call_edges (caller_id, callee_id, file_path, from_ranges, source)
                VALUES (?, ?, ?, '[]', 'lsp')
                """,
                arguments: [callerID, calleeID, filePath]
            )
        }
    }

    // MARK: - renameEdits: atomicity

    /// Two concurrent `renameEdits` calls must never interleave their own
    /// `prepareRename`/`rename` pair with the other's — the connection's call
    /// order must show two contiguous (prepare, rename) pairs, never two
    /// `prepareRename` calls landing back-to-back before either `rename`.
    @Test
    func renameEditsRunsPrepareRenameAndRenameAsOneAtomicBatchUnderConcurrentCallers() async throws {
        try await withTemporaryWorkspace { root in
            try write("func sample() {}\n", to: "Sample.swift", in: root)

            let connection = FakeLanguageServerConnection()
            let renameableRange = LSPRange(start: Position(line: 0, character: 5), end: Position(line: 0, character: 11))
            await connection.setPrepareRenameResult(.success(PrepareRenameResult(range: renameableRange, placeholder: "sample")))
            await connection.setRenameResult(.success(WorkspaceEdit(changes: ["file:///Sample.swift": [TextEdit(range: renameableRange, newText: "renamed")]])))

            // Delay right after a `prepareRename` call is recorded, before it returns — giving a
            // concurrently-launched second `renameEdits` call a real window to attempt (and,
            // absent the session's rename lock, succeed at) slipping its own `prepareRename` in
            // before the first call's `rename` runs.
            await connection.setRenameCallHook { call in
                if case .prepareRename = call {
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }

            let session = LspSession(connection: connection, languageID: "swift")

            async let first = LiveOpsExtended<FakeLanguageServerConnection>.renameEdits(
                session: session, rootDirectory: root, filePath: "Sample.swift", line: 0, character: 5, newName: "renamedA"
            )
            async let second = LiveOpsExtended<FakeLanguageServerConnection>.renameEdits(
                session: session, rootDirectory: root, filePath: "Sample.swift", line: 0, character: 5, newName: "renamedB"
            )
            let (resultA, resultB) = try await (first, second)

            #expect(resultA.canRename)
            #expect(resultB.canRename)

            let renameRelatedCalls = await connection.calls.filter { call in
                if case .prepareRename = call { return true }
                if case .rename = call { return true }
                return false
            }
            #expect(renameRelatedCalls.count == 4)

            // Structural proof of atomicity: prepare/rename must alternate in contiguous pairs
            // (P, R, P, R) — interleaving would instead produce (P, P, R, R) or similar.
            func isPrepare(_ call: FakeLanguageServerConnection.Call) -> Bool {
                if case .prepareRename = call { return true }
                return false
            }
            func isRename(_ call: FakeLanguageServerConnection.Call) -> Bool {
                if case .rename = call { return true }
                return false
            }
            #expect(isPrepare(renameRelatedCalls[0]))
            #expect(isRename(renameRelatedCalls[1]))
            #expect(isPrepare(renameRelatedCalls[2]))
            #expect(isRename(renameRelatedCalls[3]))
        }
    }

    // MARK: - renameEdits: degradation

    @Test
    func renameEditsWithNoLiveSessionReturnsCanRenameFalseNotAnError() async throws {
        try await withTemporaryWorkspace { root in
            try write("func sample() {}\n", to: "Sample.swift", in: root)

            let result = try await LiveOpsExtended<FakeLanguageServerConnection>.renameEdits(
                session: nil, rootDirectory: root, filePath: "Sample.swift", line: 0, character: 5, newName: "renamed"
            )

            #expect(!result.canRename)
            #expect(result.edit == nil)
        }
    }

    @Test
    func renameEditsWhenServerRefusesPrepareRenameReturnsCanRenameFalseWithoutCallingRename() async throws {
        try await withTemporaryWorkspace { root in
            try write("func sample() {}\n", to: "Sample.swift", in: root)

            let connection = FakeLanguageServerConnection()
            await connection.setPrepareRenameResult(.success(PrepareRenameResult(range: nil, placeholder: nil)))
            let session = LspSession(connection: connection, languageID: "swift")

            let result = try await LiveOpsExtended<FakeLanguageServerConnection>.renameEdits(
                session: session, rootDirectory: root, filePath: "Sample.swift", line: 0, character: 5, newName: "renamed"
            )

            #expect(!result.canRename)
            let calls = await connection.calls
            #expect(!calls.contains { if case .rename = $0 { return true }; return false })
        }
    }

    @Test
    func renameEditsSwallowsAConnectionFailureIntoCanRenameFalse() async throws {
        try await withTemporaryWorkspace { root in
            try write("func sample() {}\n", to: "Sample.swift", in: root)

            let connection = FakeLanguageServerConnection()
            await connection.setPrepareRenameResult(.failure(InducedExtendedOpsError()))
            let session = LspSession(connection: connection, languageID: "swift")

            let result = try await LiveOpsExtended<FakeLanguageServerConnection>.renameEdits(
                session: session, rootDirectory: root, filePath: "Sample.swift", line: 0, character: 5, newName: "renamed"
            )

            #expect(!result.canRename)
        }
    }

    // MARK: - codeActions

    @Test
    func codeActionsResolvesEveryActionReturnedByTheLiveLayer() async throws {
        try await withTemporaryWorkspace { root in
            try write("func sample() {}\n", to: "Sample.swift", in: root)

            let connection = FakeLanguageServerConnection()
            let unresolved = CodeActionItem(title: "Add missing import", kind: "quickfix", diagnostics: nil, isPreferred: nil, edit: nil, command: nil, data: .string("resolve-me"))
            let resolved = CodeActionItem(title: "Add missing import", kind: "quickfix", diagnostics: nil, isPreferred: nil, edit: WorkspaceEdit(changes: ["file:///Sample.swift": [TextEdit(range: LSPRange(start: Position(line: 0, character: 0), end: Position(line: 0, character: 0)), newText: "import Foundation\n")]]), command: nil, data: .string("resolve-me"))
            await connection.setCodeActionsResult(.success([unresolved]))
            await connection.setResolveCodeActionResult(.success(resolved))
            let session = LspSession(connection: connection, languageID: "swift")

            let result = try await LiveOpsExtended<FakeLanguageServerConnection>.codeActions(
                session: session, rootDirectory: root, filePath: "Sample.swift",
                startLine: 0, startCharacter: 0, endLine: 0, endCharacter: 10
            )

            #expect(result.sourceLayer == .liveLSP)
            #expect(result.actions == [resolved])

            let calls = await connection.calls
            #expect(calls.contains { if case .resolveCodeAction = $0 { return true }; return false })
        }
    }

    @Test
    func codeActionsWithNoLiveSessionReturnsEmptyNotAnError() async throws {
        try await withTemporaryWorkspace { root in
            try write("func sample() {}\n", to: "Sample.swift", in: root)

            let result = try await LiveOpsExtended<FakeLanguageServerConnection>.codeActions(
                session: nil, rootDirectory: root, filePath: "Sample.swift",
                startLine: 0, startCharacter: 0, endLine: 0, endCharacter: 10
            )

            #expect(result.actions.isEmpty)
            #expect(result.sourceLayer == .none)
        }
    }

    // MARK: - inboundCalls

    @Test
    func inboundCallsMapsLiveIncomingCallsWithEnrichedSymbols() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("func callee() {}\nfunc caller() { callee() }\n", to: "Sample.swift", in: root)
            try await store.markDirty(filePath: "Sample.swift", contentHash: Data("Sample.swift".utf8), fileSize: 40)
            try await Self.insertLspSymbol(store: store, id: 1, name: "caller", filePath: "Sample.swift", startLine: 1, endLine: 1)

            let connection = FakeLanguageServerConnection()
            let calleeItem = CallHierarchyItem(
                name: "callee", kind: .function, detail: nil,
                uri: DocumentURI(root.appendingPathComponent("Sample.swift").absoluteString),
                range: LSPRange(start: Position(line: 0, character: 5), end: Position(line: 0, character: 11)),
                selectionRange: LSPRange(start: Position(line: 0, character: 5), end: Position(line: 0, character: 11))
            )
            await connection.setPrepareCallHierarchyResult(.success([calleeItem]))
            let callerItem = CallHierarchyItem(
                name: "caller", kind: .function, detail: nil,
                uri: DocumentURI(root.appendingPathComponent("Sample.swift").absoluteString),
                range: LSPRange(start: Position(line: 1, character: 0), end: Position(line: 1, character: 27)),
                selectionRange: LSPRange(start: Position(line: 1, character: 5), end: Position(line: 1, character: 11))
            )
            let incomingCall = CallHierarchyIncomingCall(
                from: callerItem,
                fromRanges: [LSPRange(start: Position(line: 1, character: 16), end: Position(line: 1, character: 22))]
            )
            await connection.setIncomingCallsResult(.success([incomingCall]))

            let session = LspSession(connection: connection, languageID: "swift")

            let result = try await LiveOpsExtended<FakeLanguageServerConnection>.inboundCalls(
                store: store, session: session, rootDirectory: root, filePath: "Sample.swift", line: 0, character: 5
            )

            #expect(result.sourceLayer == .liveLSP)
            #expect(result.calls.count == 1)
            #expect(result.calls[0].callerName == "caller")
            #expect(result.calls[0].filePath == "Sample.swift")
            #expect(result.calls[0].callSites.count == 1)
            #expect(result.calls[0].symbol?.name == "caller")
        }
    }

    @Test
    func inboundCallsFallsBackToLspIndexCallersWhenNoLiveSession() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("func callee() {}\nfunc caller() { callee() }\n", to: "Sample.swift", in: root)
            try await store.markDirty(filePath: "Sample.swift", contentHash: Data("Sample.swift".utf8), fileSize: 40)
            try await Self.insertLspSymbol(store: store, id: 1, name: "callee", filePath: "Sample.swift", startLine: 0, endLine: 0)
            try await Self.insertLspSymbol(store: store, id: 2, name: "caller", filePath: "Sample.swift", startLine: 1, endLine: 1)
            try await Self.insertCallEdge(store: store, callerID: 2, calleeID: 1, filePath: "Sample.swift")

            let result = try await LiveOpsExtended<FakeLanguageServerConnection>.inboundCalls(
                store: store, session: nil, rootDirectory: root, filePath: "Sample.swift", line: 0, character: 5
            )

            #expect(result.sourceLayer == .lspIndex)
            #expect(result.calls.count == 1)
            #expect(result.calls[0].callerName == "caller")
        }
    }

    @Test
    func inboundCallsReturnsEmptyNoneWhenNoLayerHasData() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("func lonely() {}\n", to: "Sample.swift", in: root)
            try await store.markDirty(filePath: "Sample.swift", contentHash: Data("Sample.swift".utf8), fileSize: 20)

            let result = try await LiveOpsExtended<FakeLanguageServerConnection>.inboundCalls(
                store: store, session: nil, rootDirectory: root, filePath: "Sample.swift", line: 0, character: 5
            )

            #expect(result.sourceLayer == .none)
            #expect(result.calls.isEmpty)
        }
    }

    // MARK: - workspaceSymbols

    @Test
    func workspaceSymbolsRoutesThroughAnyRunningSession() async throws {
        try await withTemporaryWorkspace { root in
            let processState = ProcessState()
            let connection = FakeLanguageServerConnection()
            let symbolURI = DocumentURI(root.appendingPathComponent("Sample.swift").absoluteString)
            await connection.setWorkspaceSymbolsResult(.success([
                SymbolInformation(
                    name: "sample", kind: .function,
                    location: Location(uri: symbolURI, range: LSPRange(start: Position(line: 0, character: 0), end: Position(line: 0, character: 6))),
                    containerName: nil
                ),
            ]))

            let daemon = LSPDaemon<FakeLanguageServerConnection>(
                spec: Self.serverSpec(),
                workspaceRoot: root,
                clock: ManualClock(),
                connectionFactory: { _, _ in
                    ConnectionHandle(
                        connection: connection,
                        pid: 1,
                        isAlive: { await processState.isAlive },
                        waitForExit: { await processState.waitForExit() },
                        terminate: { await processState.markTerminated() }
                    )
                }
            )
            try await daemon.start()

            let supervisor = LspSupervisor<FakeLanguageServerConnection>(
                workspaceRoot: root, clock: ManualClock(),
                connectionFactory: fakeConnectionFactory(pid: 2, processState: ProcessState())
            )
            await supervisor.insertDaemonForTesting(spec: Self.serverSpec(), daemon: daemon)

            let result = try await LiveOpsExtended<FakeLanguageServerConnection>.workspaceSymbols(
                supervisor: supervisor, rootDirectory: root, query: "sample"
            )

            #expect(result.symbols.count == 1)
            #expect(result.symbols[0].name == "sample")
            #expect(result.symbols[0].filePath == "Sample.swift")
        }
    }

    @Test
    func workspaceSymbolsReturnsEmptyWhenNoDaemonIsRunning() async throws {
        try await withTemporaryWorkspace { root in
            let supervisor = LspSupervisor<FakeLanguageServerConnection>(
                workspaceRoot: root, clock: ManualClock(),
                connectionFactory: fakeConnectionFactory(pid: 1, processState: ProcessState())
            )

            let result = try await LiveOpsExtended<FakeLanguageServerConnection>.workspaceSymbols(
                supervisor: supervisor, rootDirectory: root, query: "sample"
            )

            #expect(result.symbols.isEmpty)
        }
    }

    // MARK: - lspStatus

    @Test
    func lspStatusReflectsSupervisorDaemonStates() async throws {
        try await withTemporaryWorkspace { root in
            let processState = ProcessState()
            let daemon = LSPDaemon<FakeLanguageServerConnection>(
                spec: Self.serverSpec(command: "true"),
                workspaceRoot: root,
                clock: ManualClock(),
                connectionFactory: fakeConnectionFactory(pid: 42, processState: processState)
            )
            try await daemon.start()

            let supervisor = LspSupervisor<FakeLanguageServerConnection>(
                workspaceRoot: root, clock: ManualClock(),
                connectionFactory: fakeConnectionFactory(pid: 42, processState: processState)
            )
            await supervisor.insertDaemonForTesting(spec: Self.serverSpec(command: "true"), daemon: daemon)

            let result = await LiveOpsExtended<FakeLanguageServerConnection>.lspStatus(supervisor: supervisor)

            #expect(result.servers.count == 1)
            #expect(result.servers[0].command == "true")
            #expect(result.servers[0].state == .running(pid: 42))
        }
    }

    @Test
    func lspStatusIsEmptyWhenNoDaemonIsManaged() async throws {
        try await withTemporaryWorkspace { root in
            let supervisor = LspSupervisor<FakeLanguageServerConnection>(
                workspaceRoot: root, clock: ManualClock(),
                connectionFactory: fakeConnectionFactory(pid: 1, processState: ProcessState())
            )

            let result = await LiveOpsExtended<FakeLanguageServerConnection>.lspStatus(supervisor: supervisor)

            #expect(result.servers.isEmpty)
        }
    }
}

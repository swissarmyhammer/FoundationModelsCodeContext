import Foundation
import GRDB
import Testing

@testable import FoundationModelsCodeContext

/// Tests for the references fallback of `LSPIndexWorker`: a server with no
/// call hierarchy (the `pylsp` shape) gets no `prepareCallHierarchy`
/// request, and the callers of each symbol come from `textDocument/references`
/// instead. The call graph, the blast radius and the inbound calls then read
/// those callers from the index.
///
/// The fixture is the `sample.py` reproduction of the kanban task, plus a
/// second file that calls `helper` from another module. The scripted
/// `documentSymbol` and `references` answers are the answers `pylsp` 1.14
/// gave for the same text.
struct LSPIndexWorkerReferencesTests {
    /// The `sample.py` reproduction: `main` calls `helper`.
    private static let sampleSource = "def helper():\n    return 1\n\n\ndef main():\n    return helper()\n"

    /// A second module whose `caller_two` calls `helper`. The local variable
    /// `x` is a symbol too in the `pylsp` answer, and it must not be taken
    /// as the caller.
    private static let otherSource = "from sample import helper\n\n\ndef caller_two():\n    x = helper()\n    return x\n"

    /// Capabilities of `pylsp` 1.14: no gated method.
    private static let pylspCapabilities = ServerCapabilities(callHierarchy: false, workspaceSymbol: false, implementation: false)

    /// The position of the name `helper` in `sample.py`.
    private static let helperName = Position(line: 0, character: 4)

    /// The error `pylsp` sends for a method it does not have.
    private static let methodNotFound = WireError.serverError(code: -32601, message: "Method Not Found: textDocument/references")

    /// Builds a flat `pylsp`-shaped symbol: the range starts at column 0 and
    /// the selection range is the same range.
    private static func flatSymbol(name: String, kind: SymbolKind, startLine: Int, endLine: Int, startColumn: Int = 0) -> DocumentSymbol {
        let range = LSPRange(start: Position(line: startLine, character: startColumn), end: Position(line: endLine, character: 0))
        return DocumentSymbol(name: name, detail: nil, kind: kind, range: range, selectionRange: range, children: nil)
    }

    /// The document uri `LSPIndexWorker` computes for a workspace-relative path.
    private static func uri(for relativePath: String, in root: URL) -> DocumentURI {
        DocumentURI(root.appendingPathComponent(relativePath).absoluteString)
    }

    /// A one-line location in `relativePath`.
    private static func location(_ relativePath: String, in root: URL, line: Int, from start: Int, to end: Int) -> Location {
        Location(
            uri: uri(for: relativePath, in: root),
            range: LSPRange(start: Position(line: line, character: start), end: Position(line: line, character: end))
        )
    }

    /// Writes both fixture files, marks them dirty and scripts the `pylsp`
    /// answers on `connection`.
    private static func seedPythonFixture(root: URL, store: Store, connection: FakeLanguageServerConnection) async throws {
        try write(sampleSource, to: "sample.py", in: root)
        try write(otherSource, to: "other.py", in: root)
        for path in ["sample.py", "other.py"] {
            try await store.markDirty(filePath: path, contentHash: Data(path.utf8), fileSize: 1)
        }

        await connection.setDocumentSymbolsResult(
            .success([
                flatSymbol(name: "helper", kind: .function, startLine: 0, endLine: 2),
                flatSymbol(name: "main", kind: .function, startLine: 4, endLine: 6),
            ]),
            for: uri(for: "sample.py", in: root)
        )
        await connection.setDocumentSymbolsResult(
            .success([
                flatSymbol(name: "caller_two", kind: .function, startLine: 3, endLine: 6),
                flatSymbol(name: "x", kind: .variable, startLine: 4, endLine: 4, startColumn: 4),
            ]),
            for: uri(for: "other.py", in: root)
        )
        await connection.setReferencesResult(
            .success([
                location("sample.py", in: root, line: 5, from: 11, to: 17),
                location("other.py", in: root, line: 4, from: 8, to: 14),
            ]),
            in: uri(for: "sample.py", in: root),
            at: helperName
        )
    }

    /// Makes a session over `connection` with the capabilities of `pylsp`.
    private static func pylspSession(
        over connection: FakeLanguageServerConnection,
        failureLog: CapturedLogLines = CapturedLogLines()
    ) -> LspSession<FakeLanguageServerConnection> {
        LspSession(
            connection: connection,
            languageID: "python",
            serverName: "pylsp",
            capabilities: pylspCapabilities,
            failureLog: failureLog.append
        )
    }

    /// Drains every dirty Python file through `session`.
    private static func drainPython(store: Store, root: URL, session: LspSession<FakeLanguageServerConnection>) async throws {
        try await LSPIndexWorker<FakeLanguageServerConnection>.drainBatch(
            store: store, rootDirectory: root, extensions: ["py"], session: session
        )
    }

    /// Every stored call edge as `[caller, callee, owner file, source]`, sorted.
    private static func edgeRows(store: Store) async throws -> [[String]] {
        try await store.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT caller.name AS caller_name, callee.name AS callee_name, e.file_path, e.source \
                    FROM lsp_call_edges e \
                    JOIN lsp_symbols caller ON caller.id = e.caller_id \
                    JOIN lsp_symbols callee ON callee.id = e.callee_id \
                    WHERE e.source = 'lsp'
                    """
            ).map { row in
                [row["caller_name"] as String, row["callee_name"] as String, row["file_path"] as String, row["source"] as String]
            }.sorted { $0.lexicographicallyPrecedes($1) }
        }
    }

    // MARK: - No call hierarchy request

    @Test
    func theWorkerSendsNoCallHierarchyRequestToAServerWithoutCallHierarchy() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            let connection = FakeLanguageServerConnection()
            try await Self.seedPythonFixture(root: root, store: store, connection: connection)

            try await Self.drainPython(store: store, root: root, session: Self.pylspSession(over: connection))

            let calls = await connection.calls
            #expect(!calls.contains { if case .prepareCallHierarchy = $0 { true } else { false } })
            #expect(!calls.contains { if case .outgoingCalls = $0 { true } else { false } })
        }
    }

    @Test
    func theWorkerAsksForReferencesAtTheNameOfTheSymbol() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            let connection = FakeLanguageServerConnection()
            try await Self.seedPythonFixture(root: root, store: store, connection: connection)

            try await Self.drainPython(store: store, root: root, session: Self.pylspSession(over: connection))

            let calls = await connection.calls
            #expect(calls.contains(.references(uri: Self.uri(for: "sample.py", in: root), position: Self.helperName, includeDeclaration: false)))
        }
    }

    // MARK: - Callers from references

    @Test
    func referencesBecomeCallEdgesIntoTheSymbol() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            let connection = FakeLanguageServerConnection()
            try await Self.seedPythonFixture(root: root, store: store, connection: connection)

            try await Self.drainPython(store: store, root: root, session: Self.pylspSession(over: connection))

            #expect(
                try await Self.edgeRows(store: store) == [
                    ["caller_two", "helper", "sample.py", "lsp"],
                    ["main", "helper", "sample.py", "lsp"],
                ])
        }
    }

    @Test
    func callGraphInboundGivesTheCallersFromReferences() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            let connection = FakeLanguageServerConnection()
            try await Self.seedPythonFixture(root: root, store: store, connection: connection)
            try await Self.drainPython(store: store, root: root, session: Self.pylspSession(over: connection))

            let graph = try await CallGraphOps.callGraph(store: store, of: "sample.py:0:4", direction: .inbound, maxDepth: 1)

            let lspCallers = graph.edges.filter { $0.source == .lsp }.map(\.caller.name).sorted()
            #expect(graph.root.name == "helper")
            #expect(lspCallers == ["caller_two", "main"])
        }
    }

    @Test
    func blastRadiusGivesTheCallersFromReferences() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            let connection = FakeLanguageServerConnection()
            try await Self.seedPythonFixture(root: root, store: store, connection: connection)
            try await Self.drainPython(store: store, root: root, session: Self.pylspSession(over: connection))

            let radius = try await BlastRadiusOps.blastRadius(store: store, file: "sample.py", symbol: "helper", maxHops: 1)

            let affected = radius.hops.flatMap(\.symbols).filter { $0.source == .lsp }.map(\.name).sorted()
            #expect(affected == ["caller_two", "main"])
        }
    }

    @Test
    func inboundCallsFromTheIndexGiveTheCallersFromReferences() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            let connection = FakeLanguageServerConnection()
            try await Self.seedPythonFixture(root: root, store: store, connection: connection)
            try await Self.drainPython(store: store, root: root, session: Self.pylspSession(over: connection))

            let result = try await LiveOpsExtended<FakeLanguageServerConnection>.inboundCalls(
                store: store, session: nil, rootDirectory: root, filePath: "sample.py", line: 0, character: 4
            )

            #expect(result.sourceLayer == .lspIndex)
            #expect(result.calls.map(\.callerName).sorted() == ["caller_two", "main"])
        }
    }

    @Test
    func liveInboundCallsAskForReferencesWhenTheServerHasNoCallHierarchy() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            let connection = FakeLanguageServerConnection()
            try await Self.seedPythonFixture(root: root, store: store, connection: connection)
            let session = Self.pylspSession(over: connection)
            try await Self.drainPython(store: store, root: root, session: session)

            // A new caller in `other.py`. Only `other.py` is indexed again, so
            // the edges that `sample.py` owns do not have it yet; the live
            // references request does.
            try write(Self.otherSource + "\n\ndef caller_three():\n    return helper()\n", to: "other.py", in: root)
            try await store.markDirty(filePath: "other.py", contentHash: Data("changed".utf8), fileSize: 1)
            await connection.setDocumentSymbolsResult(
                .success([
                    Self.flatSymbol(name: "caller_two", kind: .function, startLine: 3, endLine: 6),
                    Self.flatSymbol(name: "caller_three", kind: .function, startLine: 8, endLine: 10),
                ]),
                for: Self.uri(for: "other.py", in: root)
            )
            await connection.setReferencesResult(
                .success([
                    Self.location("sample.py", in: root, line: 5, from: 11, to: 17),
                    Self.location("other.py", in: root, line: 4, from: 8, to: 14),
                    Self.location("other.py", in: root, line: 9, from: 11, to: 17),
                ]),
                in: Self.uri(for: "sample.py", in: root),
                at: Self.helperName
            )
            try await Self.drainPython(store: store, root: root, session: session)

            let result = try await LiveOpsExtended<FakeLanguageServerConnection>.inboundCalls(
                store: store, session: session, rootDirectory: root, filePath: "sample.py", line: 0, character: 4
            )

            #expect(result.sourceLayer == .liveLSP)
            #expect(result.calls.map(\.callerName).sorted() == ["caller_three", "caller_two", "main"])
            let calls = await connection.calls
            #expect(!calls.contains { if case .prepareCallHierarchy = $0 { true } else { false } })
            #expect(!calls.contains { if case .incomingCalls = $0 { true } else { false } })
        }
    }

    // MARK: - Failure log

    @Test
    func aReferencesFailureIsLoggedOneTimeForAllSymbols() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            let connection = FakeLanguageServerConnection()
            try await Self.seedPythonFixture(root: root, store: store, connection: connection)
            await connection.setReferencesResult(.failure(Self.methodNotFound), in: Self.uri(for: "sample.py", in: root), at: Self.helperName)
            await connection.setReferencesResult(.failure(Self.methodNotFound))
            let lines = CapturedLogLines()

            try await Self.drainPython(store: store, root: root, session: Self.pylspSession(over: connection, failureLog: lines))

            #expect(lines.all.count == 1)
            #expect(lines.all.first?.contains("server error -32601: Method Not Found: textDocument/references") == true)
        }
    }

    @Test
    func aCallHierarchyFailureIsLoggedOneTimeForAllSymbols() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            let connection = FakeLanguageServerConnection()
            try await Self.seedPythonFixture(root: root, store: store, connection: connection)
            let refused = WireError.serverError(code: -32601, message: "Method Not Found: textDocument/prepareCallHierarchy")
            await connection.setPrepareCallHierarchyResult(.failure(refused))
            let lines = CapturedLogLines()
            let session = LspSession(
                connection: connection,
                languageID: "python",
                serverName: "a-server",
                capabilities: .everyGatedMethod,
                failureLog: lines.append
            )

            try await Self.drainPython(store: store, root: root, session: session)

            #expect(lines.all.count == 1)
            #expect(lines.all.first?.contains("server error -32601") == true)
        }
    }

    // MARK: - Invalidation of an edge owned by the callee file

    @Test
    func deletingACallerInAnotherFileMarksTheOwnerOfTheEdgeLspDirty() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            let connection = FakeLanguageServerConnection()
            try await Self.seedPythonFixture(root: root, store: store, connection: connection)
            let session = Self.pylspSession(over: connection)
            try await Self.drainPython(store: store, root: root, session: session)

            // `caller_two` moves to another line, so its old row is deleted;
            // the edge into `helper` that `sample.py` owns goes with it.
            try write("\n" + Self.otherSource, to: "other.py", in: root)
            try await store.markDirty(filePath: "other.py", contentHash: Data("changed".utf8), fileSize: 1)
            await connection.setDocumentSymbolsResult(
                .success([Self.flatSymbol(name: "caller_two", kind: .function, startLine: 4, endLine: 7)]),
                for: Self.uri(for: "other.py", in: root)
            )
            try await Self.drainPython(store: store, root: root, session: session)

            let dirty = try await store.drainLspDirty()
            #expect(dirty.contains("sample.py"))
        }
    }
}

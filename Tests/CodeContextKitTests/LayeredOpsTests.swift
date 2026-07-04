import Foundation
import GRDB
import Testing

@testable import CodeContextKit

/// A trivial error used to script a live-LSP request failure without
/// depending on any concrete `Error` type.
private struct InducedConnectionError: Error {}

/// Tests for `LiveOpsCore`'s four-layer cascade (live LSP -> LSP index ->
/// tree-sitter -> none) across all five ops (`definition`, `typeDefinition`,
/// `hover`, `references`, `implementations`).
///
/// Covers the acceptance criteria from the layered-cascade task: the full
/// 4-layer x 5-op matrix, fall-through on an induced live-LSP error, and the
/// `syncOpen`-before-every-live-request ordering contract.
struct LayeredOpsTests {
    // MARK: - Fixtures

    /// Writes `content` to `relativePath` under `root` and marks it dirty in
    /// `store`, so both the on-disk file (for live-layer `syncOpen`/source
    /// reads) and the `indexed_files` foreign-key row (for `lsp_symbols`/
    /// `ts_chunks` fixture rows) exist before a test seeds layer data.
    private static func seedFile(store: Store, root: URL, relativePath: String, content: String) async throws {
        try write(content, to: relativePath, in: root)
        try await store.markDirty(filePath: relativePath, contentHash: Data(relativePath.utf8), fileSize: Int64(content.utf8.count))
    }

    /// Inserts one `lsp_symbols` row.
    private static func insertLspSymbol(
        store: Store,
        id: Int64,
        name: String,
        kind: String = "function",
        filePath: String,
        startLine: Int,
        startColumn: Int = 0,
        endLine: Int,
        endColumn: Int = 0,
        detail: String? = nil
    ) async throws {
        try await store.write { db in
            try db.execute(
                sql: """
                INSERT INTO lsp_symbols (id, name, kind, file_path, start_line, start_column, end_line, end_column, detail)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [id, name, kind, filePath, startLine, startColumn, endLine, endColumn, detail]
            )
        }
    }

    /// Inserts one `lsp_call_edges` row from `callerID` to `calleeID`.
    private static func insertCallEdge(store: Store, callerID: Int64, calleeID: Int64, filePath: String, fromRanges: String = "[]") async throws {
        try await store.write { db in
            try db.execute(
                sql: """
                INSERT INTO lsp_call_edges (caller_id, callee_id, file_path, from_ranges, source)
                VALUES (?, ?, ?, ?, 'lsp')
                """,
                arguments: [callerID, calleeID, filePath, fromRanges]
            )
        }
    }

    /// Builds a `FakeLanguageServerConnection`-backed session, scripting
    /// every op result the caller supplies.
    private static func liveSession(
        definition: [Location]? = nil,
        typeDefinition: [Location]? = nil,
        hover: Hover? = nil,
        references: [Location]? = nil,
        implementations: [Location]? = nil,
        induceError: Bool = false
    ) async -> (session: LspSession<FakeLanguageServerConnection>, connection: FakeLanguageServerConnection) {
        let connection = FakeLanguageServerConnection()
        if induceError {
            await connection.setDefinitionResult(.failure(InducedConnectionError()))
            await connection.setTypeDefinitionResult(.failure(InducedConnectionError()))
            await connection.setHoverResult(.failure(InducedConnectionError()))
            await connection.setReferencesResult(.failure(InducedConnectionError()))
            await connection.setImplementationsResult(.failure(InducedConnectionError()))
        } else {
            if let definition { await connection.setDefinitionResult(.success(definition)) }
            if let typeDefinition { await connection.setTypeDefinitionResult(.success(typeDefinition)) }
            if let hover { await connection.setHoverResult(.success(hover)) }
            if let references { await connection.setReferencesResult(.success(references)) }
            if let implementations { await connection.setImplementationsResult(.success(implementations)) }
        }
        let session = LspSession(connection: connection, languageID: "swift")
        return (session, connection)
    }

    // MARK: - definition: full cascade

    @Test
    func definitionReturnsLiveLSPWhenSessionHasAnAnswer() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await Self.seedFile(store: store, root: root, relativePath: "Sample.swift", content: "func sample() {}\n")

            let liveLocation = Location(
                uri: DocumentURI(root.appendingPathComponent("Sample.swift").absoluteString),
                range: LSPRange(start: Position(line: 0, character: 5), end: Position(line: 0, character: 11))
            )
            let (session, _) = await Self.liveSession(definition: [liveLocation])

            let result = try await LiveOpsCore<FakeLanguageServerConnection>.definition(
                store: store, session: session, rootDirectory: root, filePath: "Sample.swift", line: 0, character: 5
            )

            #expect(result.sourceLayer == .liveLSP)
            #expect(result.locations.count == 1)
            #expect(result.locations[0].filePath == "Sample.swift")
        }
    }

    @Test
    func definitionReturnsLspIndexWhenSessionNilAndIndexPopulated() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await Self.seedFile(store: store, root: root, relativePath: "Sample.swift", content: "func sample() {}\n")
            try await Self.insertLspSymbol(store: store, id: 1, name: "sample", filePath: "Sample.swift", startLine: 0, endLine: 0)

            let result = try await LiveOpsCore<FakeLanguageServerConnection>.definition(
                store: store, session: nil, rootDirectory: root, filePath: "Sample.swift", line: 0, character: 0
            )

            #expect(result.sourceLayer == .lspIndex)
            #expect(result.locations.first?.symbol?.name == "sample")
        }
    }

    @Test
    func definitionReturnsTreeSitterWhenIndexEmptyAndChunksPresent() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await Self.seedFile(store: store, root: root, relativePath: "Sample.swift", content: "func sample() {}\n")
            try await insertChunk(store: store, filePath: "Sample.swift", symbolPath: "sample", text: "func sample() {}", startLine: 0, endLine: 0)

            let result = try await LiveOpsCore<FakeLanguageServerConnection>.definition(
                store: store, session: nil, rootDirectory: root, filePath: "Sample.swift", line: 0, character: 0
            )

            #expect(result.sourceLayer == .treeSitter)
            #expect(result.locations.count == 1)
        }
    }

    @Test
    func definitionReturnsNoneWithEmptyPayloadWhenAllLayersEmpty() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await Self.seedFile(store: store, root: root, relativePath: "Sample.swift", content: "func sample() {}\n")

            let result = try await LiveOpsCore<FakeLanguageServerConnection>.definition(
                store: store, session: nil, rootDirectory: root, filePath: "Sample.swift", line: 0, character: 0
            )

            #expect(result.sourceLayer == .none)
            #expect(result.locations.isEmpty)
        }
    }

    // MARK: - typeDefinition: full cascade

    @Test
    func typeDefinitionReturnsLiveLSPWhenSessionHasAnAnswer() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await Self.seedFile(store: store, root: root, relativePath: "Sample.swift", content: "struct Sample {}\n")

            let liveLocation = Location(
                uri: DocumentURI(root.appendingPathComponent("Sample.swift").absoluteString),
                range: LSPRange(start: Position(line: 0, character: 7), end: Position(line: 0, character: 13))
            )
            let (session, _) = await Self.liveSession(typeDefinition: [liveLocation])

            let result = try await LiveOpsCore<FakeLanguageServerConnection>.typeDefinition(
                store: store, session: session, rootDirectory: root, filePath: "Sample.swift", line: 0, character: 0
            )

            #expect(result.sourceLayer == .liveLSP)
            #expect(result.locations.count == 1)
        }
    }

    @Test
    func typeDefinitionReturnsLspIndexWhenSessionNilAndIndexPopulated() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await Self.seedFile(store: store, root: root, relativePath: "Sample.swift", content: "struct Sample {}\n")
            try await Self.insertLspSymbol(store: store, id: 1, name: "Sample", kind: "struct", filePath: "Sample.swift", startLine: 0, endLine: 0)

            let result = try await LiveOpsCore<FakeLanguageServerConnection>.typeDefinition(
                store: store, session: nil, rootDirectory: root, filePath: "Sample.swift", line: 0, character: 0
            )

            #expect(result.sourceLayer == .lspIndex)
        }
    }

    @Test
    func typeDefinitionReturnsTreeSitterWhenIndexEmptyAndChunksPresent() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await Self.seedFile(store: store, root: root, relativePath: "Sample.swift", content: "struct Sample {}\n")
            try await insertChunk(store: store, filePath: "Sample.swift", symbolPath: "Sample", text: "struct Sample {}", kind: .type, startLine: 0, endLine: 0)

            let result = try await LiveOpsCore<FakeLanguageServerConnection>.typeDefinition(
                store: store, session: nil, rootDirectory: root, filePath: "Sample.swift", line: 0, character: 0
            )

            #expect(result.sourceLayer == .treeSitter)
        }
    }

    @Test
    func typeDefinitionReturnsNoneWithEmptyPayloadWhenAllLayersEmpty() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await Self.seedFile(store: store, root: root, relativePath: "Sample.swift", content: "struct Sample {}\n")

            let result = try await LiveOpsCore<FakeLanguageServerConnection>.typeDefinition(
                store: store, session: nil, rootDirectory: root, filePath: "Sample.swift", line: 0, character: 0
            )

            #expect(result.sourceLayer == .none)
            #expect(result.locations.isEmpty)
        }
    }

    // MARK: - hover: full cascade

    @Test
    func hoverReturnsLiveLSPWhenSessionHasAnAnswer() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await Self.seedFile(store: store, root: root, relativePath: "Sample.swift", content: "func sample() {}\n")

            let (session, _) = await Self.liveSession(hover: Hover(contents: "func sample()", range: nil))

            let result = try await LiveOpsCore<FakeLanguageServerConnection>.hover(
                store: store, session: session, rootDirectory: root, filePath: "Sample.swift", line: 0, character: 5
            )

            #expect(result.sourceLayer == .liveLSP)
            #expect(result.contents == "func sample()")
        }
    }

    @Test
    func hoverReturnsLspIndexWhenSessionNilAndIndexPopulated() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await Self.seedFile(store: store, root: root, relativePath: "Sample.swift", content: "func sample() {}\n")
            try await Self.insertLspSymbol(
                store: store, id: 1, name: "sample", filePath: "Sample.swift", startLine: 0, endLine: 0, detail: "() -> Void"
            )

            let result = try await LiveOpsCore<FakeLanguageServerConnection>.hover(
                store: store, session: nil, rootDirectory: root, filePath: "Sample.swift", line: 0, character: 0
            )

            #expect(result.sourceLayer == .lspIndex)
            #expect(result.contents == "() -> Void")
        }
    }

    @Test
    func hoverReturnsTreeSitterWhenIndexEmptyAndChunksPresent() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await Self.seedFile(store: store, root: root, relativePath: "Sample.swift", content: "func sample() {}\n")
            try await insertChunk(store: store, filePath: "Sample.swift", symbolPath: "sample", text: "func sample() {}", startLine: 0, endLine: 0)

            let result = try await LiveOpsCore<FakeLanguageServerConnection>.hover(
                store: store, session: nil, rootDirectory: root, filePath: "Sample.swift", line: 0, character: 0
            )

            #expect(result.sourceLayer == .treeSitter)
            #expect(result.contents.contains("func sample()"))
        }
    }

    @Test
    func hoverReturnsNoneWithEmptyPayloadWhenAllLayersEmpty() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await Self.seedFile(store: store, root: root, relativePath: "Sample.swift", content: "func sample() {}\n")

            let result = try await LiveOpsCore<FakeLanguageServerConnection>.hover(
                store: store, session: nil, rootDirectory: root, filePath: "Sample.swift", line: 0, character: 0
            )

            #expect(result.sourceLayer == .none)
            #expect(result.contents.isEmpty)
        }
    }

    // MARK: - references: full cascade

    @Test
    func referencesReturnsLiveLSPWhenSessionHasAnAnswer() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await Self.seedFile(store: store, root: root, relativePath: "Sample.swift", content: "func sample() {}\nsample()\n")

            let liveLocation = Location(
                uri: DocumentURI(root.appendingPathComponent("Sample.swift").absoluteString),
                range: LSPRange(start: Position(line: 1, character: 0), end: Position(line: 1, character: 6))
            )
            let (session, _) = await Self.liveSession(references: [liveLocation])

            let result = try await LiveOpsCore<FakeLanguageServerConnection>.references(
                store: store, session: session, rootDirectory: root, filePath: "Sample.swift", line: 0, character: 5
            )

            #expect(result.sourceLayer == .liveLSP)
            #expect(result.totalCount == 1)
        }
    }

    @Test
    func referencesReturnsLspIndexWhenSessionNilAndIndexPopulated() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await Self.seedFile(store: store, root: root, relativePath: "Lib.swift", content: "func process() {}\n")
            try await Self.seedFile(store: store, root: root, relativePath: "Caller.swift", content: "func handleRequest() { process() }\n")

            try await Self.insertLspSymbol(store: store, id: 1, name: "process", filePath: "Lib.swift", startLine: 0, endLine: 0)
            try await Self.insertLspSymbol(store: store, id: 2, name: "handleRequest", filePath: "Caller.swift", startLine: 0, endLine: 0)
            try await Self.insertCallEdge(store: store, callerID: 2, calleeID: 1, filePath: "Caller.swift")

            let result = try await LiveOpsCore<FakeLanguageServerConnection>.references(
                store: store, session: nil, rootDirectory: root, filePath: "Lib.swift", line: 0, character: 0
            )

            #expect(result.sourceLayer == .lspIndex)
            #expect(result.totalCount == 1)
            #expect(result.references.first?.filePath == "Caller.swift")
        }
    }

    @Test
    func referencesReturnsTreeSitterWhenIndexEmptyAndChunksPresent() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await Self.seedFile(store: store, root: root, relativePath: "Target.swift", content: "func myFunction() {}\n")
            try await Self.seedFile(store: store, root: root, relativePath: "User.swift", content: "myFunction()\n")

            try await insertChunk(store: store, filePath: "Target.swift", symbolPath: "myFunction", text: "func myFunction() {}", startLine: 0, endLine: 0)
            try await insertChunk(store: store, filePath: "User.swift", symbolPath: "caller", text: "myFunction()", startLine: 0, endLine: 0)

            let result = try await LiveOpsCore<FakeLanguageServerConnection>.references(
                store: store, session: nil, rootDirectory: root, filePath: "Target.swift", line: 0, character: 5
            )

            #expect(result.sourceLayer == .treeSitter)
            #expect(result.totalCount >= 1)
        }
    }

    @Test
    func referencesReturnsNoneWithEmptyPayloadWhenAllLayersEmpty() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)

            let result = try await LiveOpsCore<FakeLanguageServerConnection>.references(
                store: store, session: nil, rootDirectory: root, filePath: "Nonexistent.swift", line: 0, character: 0
            )

            #expect(result.sourceLayer == .none)
            #expect(result.references.isEmpty)
            #expect(result.totalCount == 0)
            #expect(result.byFile.isEmpty)
        }
    }

    // MARK: - implementations: full cascade

    @Test
    func implementationsReturnsLiveLSPWhenSessionHasAnAnswer() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await Self.seedFile(store: store, root: root, relativePath: "Drawable.swift", content: "protocol Drawable {}\n")

            let liveLocation = Location(
                uri: DocumentURI(root.appendingPathComponent("Circle.swift").absoluteString),
                range: LSPRange(start: Position(line: 0, character: 0), end: Position(line: 0, character: 6))
            )
            let (session, _) = await Self.liveSession(implementations: [liveLocation])

            let result = try await LiveOpsCore<FakeLanguageServerConnection>.implementations(
                store: store, session: session, rootDirectory: root, filePath: "Drawable.swift", line: 0, character: 9
            )

            #expect(result.sourceLayer == .liveLSP)
            #expect(result.implementations.count == 1)
        }
    }

    @Test
    func implementationsReturnsLspIndexWhenSessionNilAndIndexPopulated() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await Self.seedFile(store: store, root: root, relativePath: "Drawable.swift", content: "protocol Drawable {}\n")
            try await Self.insertLspSymbol(store: store, id: 1, name: "Drawable", kind: "interface", filePath: "Drawable.swift", startLine: 0, endLine: 0)

            let result = try await LiveOpsCore<FakeLanguageServerConnection>.implementations(
                store: store, session: nil, rootDirectory: root, filePath: "Drawable.swift", line: 0, character: 0
            )

            #expect(result.sourceLayer == .lspIndex)
            #expect(result.implementations.count == 1)
        }
    }

    @Test
    func implementationsReturnsTreeSitterWhenIndexEmptyAndChunksPresent() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await Self.seedFile(store: store, root: root, relativePath: "Drawable.swift", content: "protocol Drawable {}\n")
            try await insertChunk(store: store, filePath: "Drawable.swift", symbolPath: "Drawable", text: "protocol Drawable {}", kind: .type, startLine: 0, endLine: 0)
            try await insertChunk(
                store: store, filePath: "Circle.swift", symbolPath: "Circle.Drawable",
                text: "impl Drawable for Circle { func draw() {} }", startLine: 0, endLine: 0
            )

            let result = try await LiveOpsCore<FakeLanguageServerConnection>.implementations(
                store: store, session: nil, rootDirectory: root, filePath: "Drawable.swift", line: 0, character: 9
            )

            #expect(result.sourceLayer == .treeSitter)
            #expect(result.implementations.count == 1)
        }
    }

    @Test
    func implementationsReturnsNoneWithEmptyPayloadWhenAllLayersEmpty() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await Self.seedFile(store: store, root: root, relativePath: "Drawable.swift", content: "protocol Drawable {}\n")

            let result = try await LiveOpsCore<FakeLanguageServerConnection>.implementations(
                store: store, session: nil, rootDirectory: root, filePath: "Drawable.swift", line: 0, character: 0
            )

            #expect(result.sourceLayer == .none)
            #expect(result.implementations.isEmpty)
        }
    }

    // MARK: - Fall-through on induced live-LSP error

    @Test
    func definitionFallsThroughToLspIndexOnInducedLiveError() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await Self.seedFile(store: store, root: root, relativePath: "Sample.swift", content: "func sample() {}\n")
            try await Self.insertLspSymbol(store: store, id: 1, name: "sample", filePath: "Sample.swift", startLine: 0, endLine: 0)

            let (session, _) = await Self.liveSession(induceError: true)

            let result = try await LiveOpsCore<FakeLanguageServerConnection>.definition(
                store: store, session: session, rootDirectory: root, filePath: "Sample.swift", line: 0, character: 0
            )

            #expect(result.sourceLayer == .lspIndex, "a live connection failure must fall through, not surface")
        }
    }

    @Test
    func hoverFallsThroughToTreeSitterOnInducedLiveError() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await Self.seedFile(store: store, root: root, relativePath: "Sample.swift", content: "func sample() {}\n")
            try await insertChunk(store: store, filePath: "Sample.swift", symbolPath: "sample", text: "func sample() {}", startLine: 0, endLine: 0)

            let (session, _) = await Self.liveSession(induceError: true)

            let result = try await LiveOpsCore<FakeLanguageServerConnection>.hover(
                store: store, session: session, rootDirectory: root, filePath: "Sample.swift", line: 0, character: 0
            )

            #expect(result.sourceLayer == .treeSitter, "a live connection failure must fall through, not surface")
        }
    }

    @Test
    func referencesFallsThroughToNoneOnInducedLiveErrorWithNoIndexData() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await Self.seedFile(store: store, root: root, relativePath: "Sample.swift", content: "func sample() {}\n")

            let (session, _) = await Self.liveSession(induceError: true)

            let result = try await LiveOpsCore<FakeLanguageServerConnection>.references(
                store: store, session: session, rootDirectory: root, filePath: "Sample.swift", line: 0, character: 0
            )

            #expect(result.sourceLayer == .none, "an induced connection failure must never surface as a thrown error")
            #expect(result.references.isEmpty)
        }
    }

    // MARK: - syncOpen ordering

    @Test
    func definitionSyncsCurrentDiskContentBeforeIssuingTheLiveRequest() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await Self.seedFile(store: store, root: root, relativePath: "Sample.swift", content: "func sample() {}\n")

            let liveLocation = Location(
                uri: DocumentURI(root.appendingPathComponent("Sample.swift").absoluteString),
                range: LSPRange(start: Position(line: 0, character: 5), end: Position(line: 0, character: 11))
            )
            let (session, connection) = await Self.liveSession(definition: [liveLocation])

            _ = try await LiveOpsCore<FakeLanguageServerConnection>.definition(
                store: store, session: session, rootDirectory: root, filePath: "Sample.swift", line: 0, character: 5
            )

            let calls = await connection.calls
            let openIndex = calls.firstIndex { if case .didOpen = $0 { true } else { false } }
            let definitionIndex = calls.firstIndex { if case .definition = $0 { true } else { false } }

            let unwrappedOpenIndex = try #require(openIndex, "syncOpen must call didOpen for a never-before-seen document")
            let unwrappedDefinitionIndex = try #require(definitionIndex)
            #expect(unwrappedOpenIndex < unwrappedDefinitionIndex, "syncOpen must run before the live definition request")

            if case let .didOpen(_, _, _, text) = calls[unwrappedOpenIndex] {
                #expect(text == "func sample() {}\n", "syncOpen must send the current on-disk content")
            } else {
                Issue.record("expected a didOpen call")
            }
        }
    }

    @Test
    func referencesSyncsCurrentDiskContentBeforeIssuingTheLiveRequest() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await Self.seedFile(store: store, root: root, relativePath: "Sample.swift", content: "func sample() {}\nsample()\n")

            let liveLocation = Location(
                uri: DocumentURI(root.appendingPathComponent("Sample.swift").absoluteString),
                range: LSPRange(start: Position(line: 1, character: 0), end: Position(line: 1, character: 6))
            )
            let (session, connection) = await Self.liveSession(references: [liveLocation])

            _ = try await LiveOpsCore<FakeLanguageServerConnection>.references(
                store: store, session: session, rootDirectory: root, filePath: "Sample.swift", line: 0, character: 5
            )

            let calls = await connection.calls
            let openIndex = calls.firstIndex { if case .didOpen = $0 { true } else { false } }
            let referencesIndex = calls.firstIndex { if case .references = $0 { true } else { false } }

            let unwrappedOpenIndex = try #require(openIndex)
            let unwrappedReferencesIndex = try #require(referencesIndex)
            #expect(unwrappedOpenIndex < unwrappedReferencesIndex, "syncOpen must run before the live references request")
        }
    }

    @Test
    func hoverSyncsCurrentDiskContentBeforeIssuingTheLiveRequest() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await Self.seedFile(store: store, root: root, relativePath: "Sample.swift", content: "func sample() {}\n")

            let (session, connection) = await Self.liveSession(hover: Hover(contents: "func sample()", range: nil))

            _ = try await LiveOpsCore<FakeLanguageServerConnection>.hover(
                store: store, session: session, rootDirectory: root, filePath: "Sample.swift", line: 0, character: 5
            )

            let calls = await connection.calls
            let openIndex = calls.firstIndex { if case .didOpen = $0 { true } else { false } }
            let hoverIndex = calls.firstIndex { if case .hover = $0 { true } else { false } }

            let unwrappedOpenIndex = try #require(openIndex)
            let unwrappedHoverIndex = try #require(hoverIndex)
            #expect(unwrappedOpenIndex < unwrappedHoverIndex, "syncOpen must run before the live hover request")
        }
    }

    @Test
    func typeDefinitionSyncsCurrentDiskContentBeforeIssuingTheLiveRequest() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await Self.seedFile(store: store, root: root, relativePath: "Sample.swift", content: "struct Sample {}\n")

            let liveLocation = Location(
                uri: DocumentURI(root.appendingPathComponent("Sample.swift").absoluteString),
                range: LSPRange(start: Position(line: 0, character: 7), end: Position(line: 0, character: 13))
            )
            let (session, connection) = await Self.liveSession(typeDefinition: [liveLocation])

            _ = try await LiveOpsCore<FakeLanguageServerConnection>.typeDefinition(
                store: store, session: session, rootDirectory: root, filePath: "Sample.swift", line: 0, character: 0
            )

            let calls = await connection.calls
            let openIndex = calls.firstIndex { if case .didOpen = $0 { true } else { false } }
            let typeDefinitionIndex = calls.firstIndex { if case .typeDefinition = $0 { true } else { false } }

            let unwrappedOpenIndex = try #require(openIndex)
            let unwrappedTypeDefinitionIndex = try #require(typeDefinitionIndex)
            #expect(unwrappedOpenIndex < unwrappedTypeDefinitionIndex, "syncOpen must run before the live typeDefinition request")
        }
    }

    @Test
    func implementationsSyncsCurrentDiskContentBeforeIssuingTheLiveRequest() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await Self.seedFile(store: store, root: root, relativePath: "Drawable.swift", content: "protocol Drawable {}\n")

            let liveLocation = Location(
                uri: DocumentURI(root.appendingPathComponent("Circle.swift").absoluteString),
                range: LSPRange(start: Position(line: 0, character: 0), end: Position(line: 0, character: 6))
            )
            let (session, connection) = await Self.liveSession(implementations: [liveLocation])

            _ = try await LiveOpsCore<FakeLanguageServerConnection>.implementations(
                store: store, session: session, rootDirectory: root, filePath: "Drawable.swift", line: 0, character: 9
            )

            let calls = await connection.calls
            let openIndex = calls.firstIndex { if case .didOpen = $0 { true } else { false } }
            let implementationsIndex = calls.firstIndex { if case .implementations = $0 { true } else { false } }

            let unwrappedOpenIndex = try #require(openIndex)
            let unwrappedImplementationsIndex = try #require(implementationsIndex)
            #expect(unwrappedOpenIndex < unwrappedImplementationsIndex, "syncOpen must run before the live implementations request")
        }
    }

    // MARK: - Fall-through on induced live-LSP error (typeDefinition, implementations)

    @Test
    func typeDefinitionFallsThroughToLspIndexOnInducedLiveError() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await Self.seedFile(store: store, root: root, relativePath: "Sample.swift", content: "struct Sample {}\n")
            try await Self.insertLspSymbol(store: store, id: 1, name: "Sample", kind: "struct", filePath: "Sample.swift", startLine: 0, endLine: 0)

            let (session, _) = await Self.liveSession(induceError: true)

            let result = try await LiveOpsCore<FakeLanguageServerConnection>.typeDefinition(
                store: store, session: session, rootDirectory: root, filePath: "Sample.swift", line: 0, character: 0
            )

            #expect(result.sourceLayer == .lspIndex, "a live connection failure must fall through, not surface")
        }
    }

    @Test
    func implementationsFallsThroughToLspIndexOnInducedLiveError() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await Self.seedFile(store: store, root: root, relativePath: "Drawable.swift", content: "protocol Drawable {}\n")
            try await Self.insertLspSymbol(store: store, id: 1, name: "Drawable", kind: "interface", filePath: "Drawable.swift", startLine: 0, endLine: 0)

            let (session, _) = await Self.liveSession(induceError: true)

            let result = try await LiveOpsCore<FakeLanguageServerConnection>.implementations(
                store: store, session: session, rootDirectory: root, filePath: "Drawable.swift", line: 0, character: 0
            )

            #expect(result.sourceLayer == .lspIndex, "a live connection failure must fall through, not surface")
        }
    }

    // MARK: - references: non-empty from_ranges decoding

    @Test
    func referencesDecodesNonEmptyFromRangesIntoCallSiteLocations() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await Self.seedFile(store: store, root: root, relativePath: "Lib.swift", content: "func process() {}\n")
            try await Self.seedFile(store: store, root: root, relativePath: "Caller.swift", content: "func handleRequest() {\n    process()\n}\n")

            try await Self.insertLspSymbol(store: store, id: 1, name: "process", filePath: "Lib.swift", startLine: 0, endLine: 0)
            try await Self.insertLspSymbol(store: store, id: 2, name: "handleRequest", filePath: "Caller.swift", startLine: 0, endLine: 2)
            // A non-trivial from_ranges payload — a single call site strictly
            // narrower than (and offset from) the caller's own declaration
            // range (line 0-2), so a passing assertion actually proves the
            // JSON array-of-quads was decoded, not merely that the caller's
            // whole-symbol range fallback (the empty-from_ranges path
            // exercised elsewhere) was used instead.
            try await Self.insertCallEdge(store: store, callerID: 2, calleeID: 1, filePath: "Caller.swift", fromRanges: "[[1,4,1,11]]")

            let result = try await LiveOpsCore<FakeLanguageServerConnection>.references(
                store: store, session: nil, rootDirectory: root, filePath: "Lib.swift", line: 0, character: 0
            )

            #expect(result.sourceLayer == .lspIndex)
            #expect(result.totalCount == 1)
            let reference = try #require(result.references.first)
            #expect(reference.filePath == "Caller.swift")
            #expect(reference.range.start.line == 1)
            #expect(reference.range.start.character == 4)
            #expect(reference.range.end.line == 1)
            #expect(reference.range.end.character == 11)
        }
    }

    // MARK: - Security: path-traversal rejection

    @Test
    func definitionRejectsAPathTraversalFilePathWithoutTouchingTheConnectionOrDiskOutsideTheWorkspace() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            // A real, readable file sitting just outside the workspace root —
            // if '..' components in `filePath` were resolved instead of
            // rejected, this file would actually be opened and queried,
            // proving the traversal guard is live rather than coincidentally
            // absent (a missing target would look identical to any other
            // unreadable file). Mirrors LSPIndexWorkerTests's identical
            // `isSafeRelativePath` regression test.
            try write("func secret() {}\n", to: "../secret.swift", in: root)

            let liveLocation = Location(
                uri: DocumentURI(root.appendingPathComponent("../secret.swift").absoluteString),
                range: LSPRange(start: Position(line: 0, character: 5), end: Position(line: 0, character: 11))
            )
            let (session, connection) = await Self.liveSession(definition: [liveLocation])

            let result = try await LiveOpsCore<FakeLanguageServerConnection>.definition(
                store: store, session: session, rootDirectory: root, filePath: "../secret.swift", line: 0, character: 0
            )

            #expect(result.sourceLayer == .none, "a path-traversal filePath must never be resolved against disk")
            let calls = await connection.calls
            #expect(calls.isEmpty, "a path-traversal filePath must never reach syncOpen or the live request")
        }
    }

    // MARK: - implementations: sourceText gated on includeSource

    @Test
    func implementationsOmitsSourceTextFromTreeSitterLayerByDefault() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await Self.seedFile(store: store, root: root, relativePath: "Drawable.swift", content: "protocol Drawable {}\n")
            try await insertChunk(store: store, filePath: "Drawable.swift", symbolPath: "Drawable", text: "protocol Drawable {}", kind: .type, startLine: 0, endLine: 0)
            try await insertChunk(
                store: store, filePath: "Circle.swift", symbolPath: "Circle.Drawable",
                text: "impl Drawable for Circle { func draw() {} }", startLine: 0, endLine: 0
            )

            let result = try await LiveOpsCore<FakeLanguageServerConnection>.implementations(
                store: store, session: nil, rootDirectory: root, filePath: "Drawable.swift", line: 0, character: 9
            )

            #expect(result.sourceLayer == .treeSitter)
            #expect(result.implementations.first?.sourceText == nil, "sourceText must be gated on includeSource, matching definition/typeDefinition")
        }
    }

    @Test
    func implementationsIncludesSourceTextFromTreeSitterLayerWhenRequested() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await Self.seedFile(store: store, root: root, relativePath: "Drawable.swift", content: "protocol Drawable {}\n")
            try await insertChunk(store: store, filePath: "Drawable.swift", symbolPath: "Drawable", text: "protocol Drawable {}", kind: .type, startLine: 0, endLine: 0)
            try await insertChunk(
                store: store, filePath: "Circle.swift", symbolPath: "Circle.Drawable",
                text: "impl Drawable for Circle { func draw() {} }", startLine: 0, endLine: 0
            )

            let result = try await LiveOpsCore<FakeLanguageServerConnection>.implementations(
                store: store, session: nil, rootDirectory: root, filePath: "Drawable.swift", line: 0, character: 9, includeSource: true
            )

            #expect(result.sourceLayer == .treeSitter)
            #expect(result.implementations.first?.sourceText == "impl Drawable for Circle { func draw() {} }")
        }
    }

    @Test
    func implementationsIncludesSourceTextFromLspIndexLayerWhenRequested() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await Self.seedFile(store: store, root: root, relativePath: "Drawable.swift", content: "protocol Drawable {}\n")
            try await Self.insertLspSymbol(store: store, id: 1, name: "Drawable", kind: "interface", filePath: "Drawable.swift", startLine: 0, endLine: 0)

            let result = try await LiveOpsCore<FakeLanguageServerConnection>.implementations(
                store: store, session: nil, rootDirectory: root, filePath: "Drawable.swift", line: 0, character: 0, includeSource: true
            )

            #expect(result.sourceLayer == .lspIndex)
            #expect(result.implementations.first?.sourceText == "protocol Drawable {}")
        }
    }

    @Test
    func implementationsIncludesSourceTextFromLiveLayerWhenRequested() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await Self.seedFile(store: store, root: root, relativePath: "Drawable.swift", content: "protocol Drawable {}\n")

            let liveLocation = Location(
                uri: DocumentURI(root.appendingPathComponent("Drawable.swift").absoluteString),
                range: LSPRange(start: Position(line: 0, character: 0), end: Position(line: 0, character: 21))
            )
            let (session, _) = await Self.liveSession(implementations: [liveLocation])

            let result = try await LiveOpsCore<FakeLanguageServerConnection>.implementations(
                store: store, session: session, rootDirectory: root, filePath: "Drawable.swift", line: 0, character: 9, includeSource: true
            )

            #expect(result.sourceLayer == .liveLSP)
            #expect(result.implementations.first?.sourceText == "protocol Drawable {}")
        }
    }
}

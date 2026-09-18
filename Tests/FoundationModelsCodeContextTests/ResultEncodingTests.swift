import Foundation
import FoundationModelsRanker
import Testing

@testable import FoundationModelsCodeContext

/// Tests that each op result type encodes to JSON with `JSONEncoder` and
/// `.sortedKeys`, the same output formatting that the tools use.
///
/// The JSON keys must be the Swift property names. The two exceptions are the
/// custom forms that `SearchCodeMatch` and `FindDuplicatesScope` document.
struct ResultEncodingTests {
    /// A span on one line, used by each diagnostic fixture.
    private static let diagnosticRange = LSPRange(
        start: Position(line: 2, character: 4),
        end: Position(line: 2, character: 9)
    )

    /// Encodes `value` with `.sortedKeys`.
    ///
    /// - Parameter value: The value to encode.
    /// - Returns: The JSON data.
    /// - Throws: An `EncodingError` when `value` cannot be encoded.
    private static func encodeSorted<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }

    /// Encodes `value` with `.sortedKeys` and returns the JSON text.
    ///
    /// - Parameter value: The value to encode.
    /// - Returns: The JSON text.
    /// - Throws: An `EncodingError` when `value` cannot be encoded.
    private static func encodedText<Value: Encodable>(_ value: Value) throws -> String {
        try #require(String(data: try encodeSorted(value), encoding: .utf8))
    }

    /// Encodes `value` with `.sortedKeys` and parses the JSON object again.
    ///
    /// - Parameter value: The value to encode. It must encode as a JSON object.
    /// - Returns: The parsed JSON object.
    /// - Throws: An `EncodingError` when `value` cannot be encoded, or an
    ///   expectation failure when the JSON is not an object.
    private static func encodedObject<Value: Encodable>(_ value: Value) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: try encodeSorted(value)) as? [String: Any])
    }

    // MARK: - SearchCodeResult

    @Test
    func searchCodeResultEncodesHitsAndIndexingProgress() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await insertChunk(
                store: store,
                filePath: "A.swift",
                symbolPath: "A.validate",
                text: "func validate(request: Request) -> Bool { true }",
                startLine: 3,
                endLine: 5
            )
            let result = try await SearchCode.run(corpus: SearchCorpus(store: store), embedder: nil, query: "validate")
            let match = try #require(result.hits.first)

            let json = try Self.encodedObject(result)

            #expect(Set(json.keys) == ["query", "hits", "indexingProgress"])
            #expect(json["query"] as? String == "validate")
            let hits = try #require(json["hits"] as? [[String: Any]])
            #expect(hits.count == result.hits.count)
            let firstHit = try #require(hits.first)
            #expect(Set(firstHit.keys) == ["hit", "filePath", "symbolPath", "kind", "startLine", "endLine", "text"])
            #expect(firstHit["filePath"] as? String == "A.swift")
            #expect(firstHit["symbolPath"] as? String == "A.validate")
            #expect(firstHit["kind"] as? String == "function")
            #expect(firstHit["startLine"] as? Int == 3)
            #expect(firstHit["endLine"] as? Int == 5)
            #expect(firstHit["text"] as? String == match.text)

            let hit = try #require(firstHit["hit"] as? [String: Any])
            #expect(Set(hit.keys) == ["id", "score", "signals"])
            #expect(hit["id"] as? String == match.hit.id)
            #expect(hit["score"] as? Double == match.hit.score)
            let signals = try #require(hit["signals"] as? [String: Any])
            #expect(Set(signals.keys) == ["bm25", "trigram", "cosine"])
            #expect(signals["bm25"] as? Double == match.hit.signals.bm25)
            #expect(signals["trigram"] as? Double == match.hit.signals.trigram)
            #expect(signals["cosine"] as? Double == match.hit.signals.cosine)

            let progress = try #require(json["indexingProgress"] as? [String: Any])
            #expect(Set(progress.keys) == ["totalChunks", "embeddedChunks", "note"])
            #expect(progress["totalChunks"] as? Int == 1)
            #expect(progress["embeddedChunks"] as? Int == 0)
            #expect(progress["note"] as? String == result.indexingProgress?.note)
        }
    }

    @Test
    func searchCodeMatchEncodesTheHitScoreAndSignalsAsPlainNumbers() throws {
        let match = SearchCodeMatch(
            hit: Hit(id: "7", score: 0.5, signals: Signals(bm25: 2.5, trigram: 0.25, cosine: -0.5)),
            filePath: "A.swift",
            symbolPath: "A.run",
            kind: .method,
            startLine: 1,
            endLine: 2,
            text: "body"
        )

        let text = try Self.encodedText(match)

        #expect(
            text
                == #"{"endLine":2,"filePath":"A.swift","hit":{"id":"7","score":0.5,"#
                + #""signals":{"bm25":2.5,"cosine":-0.5,"trigram":0.25}},"#
                + #""kind":"method","startLine":1,"symbolPath":"A.run","text":"body"}"#
        )
    }

    @Test
    func searchCodeResultLeavesOutANilIndexingProgress() throws {
        let result = SearchCodeResult(query: "q", hits: [], indexingProgress: nil)

        #expect(try Self.encodedText(result) == #"{"hits":[],"query":"q"}"#)
    }

    // MARK: - FindDuplicatesResult

    @Test
    func findDuplicatesResultEncodesScopeGroupsAndCounts() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await insertChunk(
                store: store,
                filePath: "A.swift",
                symbolPath: "A.validate",
                text: "func validate() {}",
                embedding: [1, 0, 0]
            )
            try await insertChunk(
                store: store,
                filePath: "B.swift",
                symbolPath: "B.check",
                text: "func check() {}",
                embedding: [1, 0, 0]
            )
            let result = try await FindDuplicatesOps.findDuplicates(
                corpus: SearchCorpus(store: store),
                file: "A.swift",
                minChunkBytes: 1
            )
            let similarity = try #require(result.groups.first?.duplicates.first?.similarity)

            let json = try Self.encodedObject(result)

            #expect(Set(json.keys) == ["scope", "groups", "sourceChunks", "comparedChunks"])
            #expect(json["scope"] as? [String: String] == ["kind": "file", "path": "A.swift"])
            #expect(json["sourceChunks"] as? Int == 1)
            #expect(json["comparedChunks"] as? Int == 2)
            let groups = try #require(json["groups"] as? [[String: Any]])
            #expect(groups.count == 1)
            let group = try #require(groups.first)
            #expect(Set(group.keys) == ["source", "duplicates"])

            let source = try #require(group["source"] as? [String: Any])
            #expect(Set(source.keys) == ["filePath", "symbolPath", "kind", "startLine", "endLine", "text"])
            #expect(source["filePath"] as? String == "A.swift")
            #expect(source["symbolPath"] as? String == "A.validate")
            #expect(source["kind"] as? String == "function")
            #expect(source["text"] as? String == "func validate() {}")

            let duplicates = try #require(group["duplicates"] as? [[String: Any]])
            #expect(duplicates.count == 1)
            let duplicate = try #require(duplicates.first)
            #expect(Set(duplicate.keys) == ["chunk", "similarity"])
            #expect(duplicate["similarity"] as? Double == similarity)
            let chunk = try #require(duplicate["chunk"] as? [String: Any])
            #expect(chunk["filePath"] as? String == "B.swift")
            #expect(chunk["symbolPath"] as? String == "B.check")
        }
    }

    @Test
    func findDuplicatesScopeEncodesWorkspaceAndFile() throws {
        #expect(try Self.encodedText(FindDuplicatesScope.workspace) == #"{"kind":"workspace"}"#)
        #expect(try Self.encodedText(FindDuplicatesScope.file("A.swift")) == #"{"kind":"file","path":"A.swift"}"#)
    }

    // MARK: - QueryASTResult

    @Test
    func queryASTResultEncodesMatchesAndCaptures() async throws {
        try await withTemporaryWorkspace { root in
            try write("fn hello() {}\n", to: "test.rs", in: root)
            let result = try QueryAST.run(
                rootDirectory: root,
                language: "rust",
                query: "(function_item name: (identifier) @name)"
            )

            let json = try Self.encodedObject(result)

            #expect(Set(json.keys) == ["matches", "filesScanned", "truncated"])
            #expect(json["filesScanned"] as? Int == 1)
            #expect(json["truncated"] as? Bool == false)
            let matches = try #require(json["matches"] as? [[String: Any]])
            #expect(matches.count == 1)
            let match = try #require(matches.first)
            #expect(Set(match.keys) == ["file", "captures"])
            #expect(match["file"] as? String == "test.rs")

            let captures = try #require(match["captures"] as? [[String: Any]])
            #expect(captures.count == 1)
            let capture = try #require(captures.first)
            #expect(Set(capture.keys) == ["name", "kind", "text", "startLine", "endLine", "startByte", "endByte"])
            #expect(capture["name"] as? String == "name")
            #expect(capture["kind"] as? String == "identifier")
            #expect(capture["text"] as? String == "hello")
            #expect(capture["startLine"] as? Int == 0)
            #expect(capture["endLine"] as? Int == 0)
            #expect(capture["startByte"] as? Int == 3)
            #expect(capture["endByte"] as? Int == 8)
        }
    }

    // MARK: - DiagnosticsReport

    @Test
    func diagnosticsReportEncodesRecordsCountsAndPending() throws {
        let report = DiagnosticsReport(
            records: [
                DiagnosticRecord(
                    path: "a.swift",
                    range: Self.diagnosticRange,
                    severity: .error,
                    message: "bad type",
                    code: "E0308",
                    source: "swiftc",
                    containingSymbol: "A.run"
                ),
                DiagnosticRecord(path: "a.swift", range: Self.diagnosticRange, severity: .warning, message: "unused"),
            ],
            pending: true
        )

        let json = try Self.encodedObject(report)

        #expect(Set(json.keys) == ["records", "counts", "pending"])
        #expect(json["pending"] as? Bool == true)
        #expect(json["counts"] as? [String: Int] == ["errors": 1, "warnings": 1])
        let records = try #require(json["records"] as? [[String: Any]])
        #expect(records.count == 2)

        let first = try #require(records.first)
        #expect(
            Set(first.keys) == ["path", "range", "severity", "message", "code", "source", "containingSymbol"]
        )
        #expect(first["path"] as? String == "a.swift")
        #expect(first["message"] as? String == "bad type")
        #expect(first["code"] as? String == "E0308")
        #expect(first["source"] as? String == "swiftc")
        #expect(first["containingSymbol"] as? String == "A.run")
        let range = try #require(first["range"] as? [String: [String: Int]])
        #expect(range["start"] == ["line": 2, "character": 4])
        #expect(range["end"] == ["line": 2, "character": 9])

        let second = try #require(records.last)
        #expect(Set(second.keys) == ["path", "range", "severity", "message"])
    }

    @Test
    func diagnosticSeverityStaysNumeric() throws {
        let severities: [DiagnosticSeverity] = [.error, .warning, .information, .hint]
        #expect(try severities.map { try Self.encodedText($0) } == ["1", "2", "3", "4"])

        let record = DiagnosticRecord(path: "a.swift", range: Self.diagnosticRange, severity: .hint, message: "m")
        let json = try Self.encodedObject(record)
        #expect(json["severity"] as? Int == 4)
        #expect(json["severity"] as? String == nil)
    }

    // MARK: - IndexProgress

    @Test
    func indexProgressEncodesEveryLayerCount() throws {
        let progress = IndexProgress(filesWalked: 4, filesParsed: 3, filesEmbedded: 2, filesLspIndexed: 1)

        #expect(
            try Self.encodedText(progress)
                == #"{"filesEmbedded":2,"filesLspIndexed":1,"filesParsed":3,"filesWalked":4,"isEmbeddingEnabled":true}"#
        )
    }
}

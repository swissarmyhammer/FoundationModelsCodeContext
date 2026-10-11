import Foundation
import GRDB
import Testing

@testable import FoundationModelsCodeContext

/// Tests for the embed text of a chunk: the text that the embedding step
/// sends to the embedder.
///
/// A container chunk embeds a summary: its declaration, its doc text, and the
/// declaration of each member chunk. Any other chunk embeds its full text.
/// `ts_chunks.text` keeps the full text of each chunk.
///
/// `Goldens/embedding-text/<language>/` holds one source file and the
/// expected embed text of one container chunk in it.
struct EmbeddingTextTests {
    /// One golden case: a source file, its language, and the container chunk
    /// whose embed text `expected.txt` holds.
    struct GoldenCase: Sendable, CustomTestStringConvertible {
        /// The folder of the case below `Goldens/embedding-text/`.
        let folder: String

        /// The file name of the source file in `folder`.
        let sourceFileName: String

        /// The language module that chunks the source file.
        let module: any LanguageModule.Type

        /// The symbol path of the container chunk.
        let containerSymbolPath: String

        /// The symbol paths of chunks in the source file that are not
        /// containers.
        let otherSymbolPaths: [String]

        var testDescription: String { folder }
    }

    /// The golden cases: one for each language that the task names, and one
    /// for a decorated Python class.
    ///
    /// The container of the decorated case is the `decorated_definition`
    /// chunk that wraps the class. That wrapper has no name, thus its symbol
    /// path is its node kind.
    static let goldenCases = [
        GoldenCase(
            folder: "swift", sourceFileName: "source.swift", module: SwiftLanguage.self, containerSymbolPath: "Cache",
            otherSymbolPaths: ["Cache.value", "Cache.Entry.matches"]),
        GoldenCase(
            folder: "rust", sourceFileName: "source.rs", module: RustLanguage.self, containerSymbolPath: "impl Stack<T>",
            otherSymbolPaths: ["Stack", "impl Stack<T>.peek", "impl Stack<T>.LIMIT"]),
        GoldenCase(
            folder: "python", sourceFileName: "source.py", module: PythonLanguage.self, containerSymbolPath: "Repository",
            otherSymbolPaths: ["helper", "Repository.find", "Repository.size"]),
        GoldenCase(
            folder: "python-decorated", sourceFileName: "source.py", module: PythonLanguage.self,
            containerSymbolPath: "decorated_definition", otherSymbolPaths: ["label", "Row.__lt__", "Row.width"]),
    ]

    /// The folder of the golden cases.
    private static let goldensFolder = PackagePaths.testGoldens.appending(path: "embedding-text")

    /// The vector length of the fake embedder of the worker tests.
    private static let vectorLength = 8

    /// Reads the source file of `goldenCase`.
    private static func source(of goldenCase: GoldenCase) throws -> String {
        let url = goldensFolder.appending(path: goldenCase.folder).appending(path: goldenCase.sourceFileName)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Reads the expected embed text of `goldenCase`, without the final
    /// newline of the file.
    private static func expectedEmbeddingText(of goldenCase: GoldenCase) throws -> String {
        let url = goldensFolder.appending(path: goldenCase.folder).appending(path: "expected.txt")
        let contents = try String(contentsOf: url, encoding: .utf8)
        return contents.hasSuffix("\n") ? String(contents.dropLast()) : contents
    }

    /// Chunks the source file of `goldenCase`.
    private static func chunks(of goldenCase: GoldenCase) throws -> [SemanticChunk] {
        let file = SourceFile(relativePath: goldenCase.sourceFileName, contents: try source(of: goldenCase))
        return Chunker.chunk(file: file, module: goldenCase.module)
    }

    // MARK: - Chunker

    @Test(arguments: goldenCases)
    func aContainerChunkEmbedsItsDeclarationDocTextAndMemberDeclarations(_ goldenCase: GoldenCase) throws {
        let chunks = try Self.chunks(of: goldenCase)

        let container = try #require(chunks.first { $0.symbolPath == goldenCase.containerSymbolPath })
        #expect(container.embeddingText == (try Self.expectedEmbeddingText(of: goldenCase)))
    }

    @Test(arguments: goldenCases)
    func aContainerChunkKeepsItsFullTextAsItsText(_ goldenCase: GoldenCase) throws {
        let source = try Self.source(of: goldenCase)
        let chunks = try Self.chunks(of: goldenCase)

        let container = try #require(chunks.first { $0.symbolPath == goldenCase.containerSymbolPath })
        let startIndex = source.utf8.index(source.startIndex, offsetBy: container.startByte)
        let endIndex = source.utf8.index(source.startIndex, offsetBy: container.endByte)
        #expect(container.text == String(source[startIndex..<endIndex]))
        #expect(container.text != container.embeddingText)
    }

    @Test(arguments: goldenCases)
    func aChunkThatIsNotAContainerEmbedsItsFullText(_ goldenCase: GoldenCase) throws {
        let chunks = try Self.chunks(of: goldenCase)

        for symbolPath in goldenCase.otherSymbolPaths {
            let chunk = try #require(chunks.first { $0.symbolPath == symbolPath })
            #expect(chunk.embeddingText == chunk.text)
        }
    }

    @Test
    func pythonTakesTheDocTextFromTheFirstStringOfTheBodyAndNotFromACommentBeforeTheClass() throws {
        let source = """
            # A comment before the class.
            class Plain:
                \"\"\"The doc text.\"\"\"

                def run(self):
                    pass
            """
        let file = SourceFile(relativePath: "plain.py", contents: source)

        let chunks = Chunker.chunk(file: file, module: PythonLanguage.self)

        let container = try #require(chunks.first { $0.symbolPath == "Plain" })
        #expect(container.embeddingText == "class Plain:\n\"\"\"The doc text.\"\"\"\ndef run(self):")
    }

    @Test
    func theDecoratedDefinitionChunkOfAPythonFunctionEmbedsItsFullText() throws {
        let source = """
            @functools.cache
            def load(path):
                \"\"\"Give the text at `path`.\"\"\"
                return path
            """
        let file = SourceFile(relativePath: "load.py", contents: source)

        let chunks = Chunker.chunk(file: file, module: PythonLanguage.self)

        let wrapper = try #require(chunks.first { $0.symbolPath == "decorated_definition" })
        #expect(wrapper.text == source)
        #expect(wrapper.embeddingText == wrapper.text)
    }

    @Test
    func aCommentThatABlankLineSeparatesFromTheDeclarationIsNotDocText() throws {
        let source = """
            // A comment about the file.

            struct Point {
                func length() -> Double { 0 }
            }
            """
        let file = SourceFile(relativePath: "Point.swift", contents: source)

        let chunks = Chunker.chunk(file: file, module: SwiftLanguage.self)

        let container = try #require(chunks.first { $0.symbolPath == "Point" })
        #expect(container.embeddingText == "struct Point\nfunc length() -> Double")
    }

    // MARK: - Worker

    @Test
    func theWorkerStoresTheFullTextAndEmbedsTheEmbedText() async throws {
        let goldenCase = Self.goldenCases[0]
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write(try Self.source(of: goldenCase), to: goldenCase.sourceFileName, in: root)
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)

            try await TreeSitterWorker.run(store: store, rootDirectory: root, embedder: FakeEmbedder(vectorLength: Self.vectorLength))

            let expectedChunks = try Self.chunks(of: goldenCase)
            let rows = try await Self.storedChunks(in: store)
            #expect(rows.map(\.text) == expectedChunks.map(\.text))
            let expectedVectors = try await FakeEmbedder(vectorLength: Self.vectorLength).embed(texts: expectedChunks.map(\.embeddingText))
            #expect(rows.map(\.vector) == expectedVectors)
        }
    }

    @Test
    func aChangeOfTheEmbedTextVersionEmbedsEachChunkAgainOneTime() async throws {
        let goldenCase = Self.goldenCases[0]
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write(try Self.source(of: goldenCase), to: goldenCase.sourceFileName, in: root)
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)
            try await TreeSitterWorker.run(store: store, rootDirectory: root, embedder: FakeEmbedder(vectorLength: Self.vectorLength))
            #expect(try await store.embeddingTextVersion() == Chunker.embeddingTextVersion)

            // Make the index look like an index of the earlier rules: the
            // vectors of the full texts, and an earlier version.
            let fullTexts = try await Self.storedChunks(in: store).map(\.text)
            let fullTextVectors = try await FakeEmbedder(vectorLength: Self.vectorLength).embed(texts: fullTexts)
            try await store.write { db in
                for (index, vector) in fullTextVectors.enumerated() {
                    try db.execute(
                        sql: "UPDATE ts_chunks SET embedding = ?, embedding_text = NULL WHERE id = (SELECT id FROM ts_chunks ORDER BY id LIMIT 1 OFFSET ?)",
                        arguments: [EmbeddingCodec.encode(vector), index])
                }
            }
            try await store.setEmbeddingTextVersion(Chunker.embeddingTextVersion - 1)

            let log = EmbedCallLog()
            try await TreeSitterWorker.run(
                store: store, rootDirectory: root, embedder: GatedEmbedder(vectorLength: Self.vectorLength, log: log))

            let rows = try await Self.storedChunks(in: store)
            let expectedVectors = try await FakeEmbedder(vectorLength: Self.vectorLength).embed(
                texts: try Self.chunks(of: goldenCase).map(\.embeddingText))
            #expect(rows.map(\.vector) == expectedVectors)
            #expect(await log.batchSizes.reduce(0, +) == rows.count)
            #expect(try await store.embeddingTextVersion() == Chunker.embeddingTextVersion)

            let nextLog = EmbedCallLog()
            try await TreeSitterWorker.run(
                store: store, rootDirectory: root, embedder: GatedEmbedder(vectorLength: Self.vectorLength, log: nextLog))
            #expect(await nextLog.batchSizes.isEmpty)
        }
    }

    /// One stored `ts_chunks` row: its full text and its decoded embedding.
    private struct StoredChunk {
        let text: String
        let vector: [Float]?
    }

    /// Reads each `ts_chunks` row, in identifier order.
    private static func storedChunks(in store: Store) async throws -> [StoredChunk] {
        try await store.read { db in
            try Row.fetchAll(db, sql: "SELECT text, embedding FROM ts_chunks ORDER BY id").map { row in
                let embedding: Data? = row["embedding"]
                return StoredChunk(text: row["text"], vector: embedding.map(EmbeddingCodec.decode))
            }
        }
    }
}

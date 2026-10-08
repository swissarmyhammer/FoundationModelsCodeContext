import Foundation
import FoundationModelsExtras
import InMemoryLogging
import InMemoryTracing
import Testing
import Tracing

@testable import FoundationModelsCodeContext

/// Tests for the spans of the package (rules 1, 3, 4 and 8 of the OpenTelemetry design): the index
/// pass, the watcher batch, the embed call, the search, the symbol search and the grep.
///
/// Each test gives its own `InMemoryTracer` to the code under test, and reads the finished spans
/// from it. No test bootstraps the global tracing system, thus the tests can run in parallel. Each
/// test uses fakes only. The test of the LSP request span starts a real scripted language server,
/// thus it is in the `IntegrationTests` package.
///
/// The "enter" log record tests read the records from `CapturedLogRecords`, the logging capture
/// that this test process bootstraps one time. The `TelemetryCapture` helper of
/// FoundationModelsExtras bootstraps the logging system too, and a second bootstrap stops the
/// process, thus these tests do not use it.
internal struct TracingSpanTests {
    /// The number of fixture files of the index pass tests.
    private static let fixtureFileCount = 3

    /// The time limit of each test that starts background work, in minutes.
    private static let timeLimitMinutes = 1

    /// The length of each vector of the fake embedder.
    private static let embeddingDimension = 8

    /// The maximum number of results that each search test asks for.
    private static let searchLimit = 5

    /// The query of each search test.
    private static let searchQuery = "retry backoff strategy"

    /// The debounce interval of the watcher test.
    private static let debounceInterval: Duration = .seconds(1)

    /// The file names of the watcher batch test.
    private static let watcherBatchFiles = ["a.rs", "b.rs"]

    // MARK: - Index pass

    @Test(.timeLimit(.minutes(TracingSpanTests.timeLimitMinutes)))
    internal func anIndexPassGivesOneIndexPassSpanWithTheCountOfIndexedFiles() async throws {
        let tracer = InMemoryTracer()
        try await Self.runFirstIndexPass(embedder: nil, tracer: tracer)

        let passSpans = Self.spans(named: CodeContextTracing.SpanName.indexPass, in: tracer)
        #expect(passSpans.count == 1)
        let passSpan = try #require(passSpans.first)
        #expect(passSpan.attributes.get(CodeContextTracing.AttributeKey.indexFilesIndexed) == .int64(Int64(Self.fixtureFileCount)))
        #expect(passSpan.errors.isEmpty)
    }

    @Test(.timeLimit(.minutes(TracingSpanTests.timeLimitMinutes)))
    internal func theEmbedSpansOfAnIndexPassAreChildrenOfThePassSpan() async throws {
        let tracer = InMemoryTracer()
        try await Self.runFirstIndexPass(embedder: FakeEmbedder(vectorLength: Self.embeddingDimension), tracer: tracer)

        let passSpan = try #require(Self.spans(named: CodeContextTracing.SpanName.indexPass, in: tracer).first)
        let embedSpans = Self.spans(named: CodeContextTracing.SpanName.embed, in: tracer)
        // One embed span for each fixture file, and one for the probe that gets the vector length.
        #expect(embedSpans.count == Self.fixtureFileCount + 1)
        for embedSpan in embedSpans {
            #expect(embedSpan.parentSpanID == passSpan.spanID)
            #expect(embedSpan.attributes.get(CodeContextTracing.AttributeKey.embeddingDimension) == .int64(Int64(Self.embeddingDimension)))
        }
    }

    @Test(.timeLimit(.minutes(TracingSpanTests.timeLimitMinutes)))
    internal func anIndexPassWritesAnEnterRecordBeforeTheWork() async throws {
        _ = CapturedLogRecords.handler
        try await Self.runFirstIndexPass(embedder: nil, tracer: InMemoryTracer())

        #expect(!Self.enterRecords(forSpanNamed: CodeContextTracing.SpanName.indexPass).isEmpty)
    }

    // MARK: - Watcher batch

    @Test(.timeLimit(.minutes(TracingSpanTests.timeLimitMinutes)))
    internal func aWatcherFlushGivesOneWatcherBatchSpanWithTheBatchSize() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            for fileName in Self.watcherBatchFiles {
                try write("fn \(fileName.prefix(1))() {}", to: fileName, in: root)
            }
            let tracer = InMemoryTracer()
            let clock = ManualClock()
            let eventSource = FakeFileEventSource()
            let watcher = Watcher(
                store: store,
                rootDirectory: root,
                eventSource: eventSource,
                clock: clock,
                debounceInterval: Self.debounceInterval,
                tracer: tracer,
                nudgeWorkers: {}
            )
            await watcher.start()

            for fileName in Self.watcherBatchFiles {
                await eventSource.emit(RawFileEvent(url: root.appendingPathComponent(fileName), kind: .modified))
            }
            await clock.waitForWaiter()
            clock.advance(by: Self.debounceInterval)
            await watcher.waitForQuiescence()
            await watcher.stop()

            let batchSpans = Self.spans(named: CodeContextTracing.SpanName.watcherBatch, in: tracer)
            #expect(batchSpans.count == 1)
            let batchSpan = try #require(batchSpans.first)
            #expect(batchSpan.attributes.get(CodeContextTracing.AttributeKey.watcherBatchSize) == .int64(Int64(Self.watcherBatchFiles.count)))
        }
    }

    // MARK: - Search and embed

    @Test
    internal func aSearchCodeCallGivesOneSearchSpanAndOneEmbedSpanAsItsChild() async throws {
        try await withTemporaryWorkspace { root in
            let corpus = try await Self.makeEmbeddedCorpus(root: root)
            let tracer = InMemoryTracer()

            let result = try await SearchCode.run(
                corpus: corpus,
                embedder: FakeEmbedder(vectorLength: Self.embeddingDimension),
                query: Self.searchQuery,
                topK: Self.searchLimit,
                tracer: tracer
            )

            let searchSpans = Self.spans(named: CodeContextTracing.SpanName.search, in: tracer)
            let embedSpans = Self.spans(named: CodeContextTracing.SpanName.embed, in: tracer)
            #expect(searchSpans.count == 1)
            #expect(embedSpans.count == 1)
            let searchSpan = try #require(searchSpans.first)
            let embedSpan = try #require(embedSpans.first)
            #expect(embedSpan.parentSpanID == searchSpan.spanID)
            #expect(searchSpan.attributes.get(CodeContextTracing.AttributeKey.searchLimit) == .int64(Int64(Self.searchLimit)))
            #expect(searchSpan.attributes.get(CodeContextTracing.AttributeKey.searchResultCount) == .int64(Int64(result.hits.count)))
            #expect(embedSpan.attributes.get(CodeContextTracing.AttributeKey.embeddingInputCount) == .int64(1))
            #expect(embedSpan.attributes.get(CodeContextTracing.AttributeKey.embeddingDimension) == .int64(Int64(Self.embeddingDimension)))
        }
    }

    @Test
    internal func anEmbedCallWritesAnEnterRecordBeforeTheWork() async throws {
        _ = CapturedLogRecords.handler
        try await withTemporaryWorkspace { root in
            let corpus = try await Self.makeEmbeddedCorpus(root: root)

            _ = try await SearchCode.run(
                corpus: corpus,
                embedder: FakeEmbedder(vectorLength: Self.embeddingDimension),
                query: Self.searchQuery,
                tracer: InMemoryTracer()
            )

            #expect(!Self.enterRecords(forSpanNamed: CodeContextTracing.SpanName.embed).isEmpty)
        }
    }

    @Test
    internal func aFailedEmbedCallRecordsOnlyTheErrorTypeOnItsSpan() async throws {
        try await withTemporaryWorkspace { root in
            let corpus = try await Self.makeEmbeddedCorpus(root: root)
            let tracer = InMemoryTracer()
            let failure = MarkedEmbedError(marker: Self.searchQuery)

            _ = try await SearchCode.run(
                corpus: corpus,
                embedder: FakeEmbedder(vectorLength: Self.embeddingDimension, failure: failure),
                query: Self.searchQuery,
                tracer: tracer
            )

            let embedSpan = try #require(Self.spans(named: CodeContextTracing.SpanName.embed, in: tracer).first)
            let recorded = try #require(embedSpan.errors.first)
            #expect(embedSpan.errors.count == 1)
            #expect(String(describing: recorded.error) == String(reflecting: MarkedEmbedError.self))
            #expect(!String(reflecting: recorded.error).contains(Self.searchQuery))
            #expect(embedSpan.status?.code == .error)
            // The span gets the dimension from a returned vector. A failed call returns none.
            #expect(embedSpan.attributes.get(CodeContextTracing.AttributeKey.embeddingDimension) == nil)
        }
    }

    @Test
    internal func aSearchWithNoTracerGivesTheSameHits() async throws {
        try await withTemporaryWorkspace { root in
            let corpus = try await Self.makeEmbeddedCorpus(root: root)
            let embedder = FakeEmbedder(vectorLength: Self.embeddingDimension)

            let traced = try await SearchCode.run(corpus: corpus, embedder: embedder, query: Self.searchQuery, tracer: InMemoryTracer())
            let untraced = try await SearchCode.run(corpus: corpus, embedder: embedder, query: Self.searchQuery)

            #expect(traced.hits.map(\.symbolPath) == untraced.hits.map(\.symbolPath))
            #expect(!untraced.hits.isEmpty)
        }
    }

    // MARK: - Symbol search and grep

    @Test
    internal func aSearchSymbolCallGivesOneSearchSymbolSpanWithTheResultCount() async throws {
        try await withTemporaryWorkspace { root in
            let tracer = InMemoryTracer()
            let context = try await Self.makeContext(root: root, embedder: nil, tracer: tracer)
            try await insertChunk(store: Store(rootDirectory: root), filePath: "A.swift", symbolPath: "A.retry", text: "func retry() {}")

            let matches = try await context.searchSymbol(query: "retry", maxResults: Self.searchLimit)

            let spans = Self.spans(named: CodeContextTracing.SpanName.searchSymbol, in: tracer)
            #expect(spans.count == 1)
            let span = try #require(spans.first)
            #expect(span.attributes.get(CodeContextTracing.AttributeKey.searchLimit) == .int64(Int64(Self.searchLimit)))
            #expect(span.attributes.get(CodeContextTracing.AttributeKey.searchResultCount) == .int64(Int64(matches.count)))
        }
    }

    @Test
    internal func aGrepCodeCallGivesOneGrepCodeSpanWithTheResultCount() async throws {
        try await withTemporaryWorkspace { root in
            let tracer = InMemoryTracer()
            let context = try await Self.makeContext(root: root, embedder: nil, tracer: tracer)
            try await insertChunk(store: Store(rootDirectory: root), filePath: "A.swift", symbolPath: "A.retry", text: "func retry() {}")

            let result = try await context.grepCode(pattern: "retry", maxResults: Self.searchLimit)

            let spans = Self.spans(named: CodeContextTracing.SpanName.grepCode, in: tracer)
            #expect(spans.count == 1)
            let span = try #require(spans.first)
            #expect(span.attributes.get(CodeContextTracing.AttributeKey.searchLimit) == .int64(Int64(Self.searchLimit)))
            #expect(span.attributes.get(CodeContextTracing.AttributeKey.searchResultCount) == .int64(Int64(result.matches.count)))
        }
    }

    // MARK: - Search span helper

    @Test
    internal func theSearchSpanHelperSetsTheLimitAndTheResultCountOfTheBody() async throws {
        let tracer = InMemoryTracer()
        let values = [1, 2, 3]

        let output = try await CodeContextSpans.withSearchSpan(
            CodeContextTracing.SpanName.search,
            tracer: tracer,
            limit: Self.searchLimit,
            resultCount: \.count
        ) {
            values
        }

        let spans = Self.spans(named: CodeContextTracing.SpanName.search, in: tracer)
        #expect(output == values)
        #expect(spans.count == 1)
        let span = try #require(spans.first)
        #expect(span.attributes.get(CodeContextTracing.AttributeKey.searchLimit) == .int64(Int64(Self.searchLimit)))
        #expect(span.attributes.get(CodeContextTracing.AttributeKey.searchResultCount) == .int64(Int64(values.count)))
        #expect(span.errors.isEmpty)
    }

    @Test
    internal func theSearchSpanHelperRecordsOnlyTheErrorTypeWhenTheBodyThrows() async throws {
        let tracer = InMemoryTracer()
        let failure = MarkedEmbedError(marker: Self.searchQuery)

        await #expect(throws: MarkedEmbedError.self) {
            try await CodeContextSpans.withSearchSpan(
                CodeContextTracing.SpanName.grepCode,
                tracer: tracer,
                limit: Self.searchLimit,
                resultCount: { (values: [Int]) in values.count },
                {
                    throw failure
                }
            )
        }

        let span = try #require(Self.spans(named: CodeContextTracing.SpanName.grepCode, in: tracer).first)
        let recorded = try #require(span.errors.first)
        #expect(span.errors.count == 1)
        #expect(String(describing: recorded.error) == String(reflecting: MarkedEmbedError.self))
        #expect(!String(reflecting: recorded.error).contains(Self.searchQuery))
        #expect(span.attributes.get(CodeContextTracing.AttributeKey.searchResultCount) == nil)
        #expect(span.status?.code == .error)
    }

    // MARK: - Helpers

    /// Writes the fixture files, starts a context that opens its spans through `tracer`, waits
    /// for the first index pass and stops the context.
    /// - Parameters:
    ///   - embedder: The embedder of the context, or `nil` to turn the embedding layer off.
    ///   - tracer: The tracer of the context.
    private static func runFirstIndexPass(embedder: PooledEmbedding?, tracer: InMemoryTracer) async throws {
        try await withTemporaryWorkspace { root in
            for index in 0..<fixtureFileCount {
                try write("func greet\(index)() -> String {\n    \"hello\"\n}\n", to: "Greeter\(index).swift", in: root)
            }
            let context = try await makeContext(root: root, embedder: embedder, tracer: tracer)
            try await context.start()
            await context.waitForFirstIndexPass()
            await context.stop()
        }
    }

    /// Makes a context over fakes that opens its spans through `tracer`. It is not started.
    /// - Parameters:
    ///   - root: The root directory of the context.
    ///   - embedder: The embedder of the context, or `nil` to turn the embedding layer off.
    ///   - tracer: The tracer of the context.
    /// - Returns: The context.
    private static func makeContext(
        root: URL,
        embedder: PooledEmbedding?,
        tracer: InMemoryTracer
    ) async throws -> CodeContext<FakeLanguageServerConnection> {
        try await CodeContext<FakeLanguageServerConnection>(
            rootDirectory: root,
            embedder: embedder,
            clock: ManualClock(),
            eventSource: FakeFileEventSource(),
            autoInstall: LspAutoInstall(isEnabled: false),
            tracer: tracer,
            connectionFactory: fakeConnectionFactory(pid: 1, processState: ProcessState())
        )
    }

    /// Makes a corpus that holds one chunk with an embedding, so that a search embeds its query.
    /// - Parameter root: The root directory of the store.
    /// - Returns: The corpus.
    private static func makeEmbeddedCorpus(root: URL) async throws -> SearchCorpus {
        let store = try Store(rootDirectory: root)
        let vectors = try await FakeEmbedder(vectorLength: embeddingDimension).embed(texts: [searchQuery])
        try await insertChunk(
            store: store,
            filePath: "Network.swift",
            symbolPath: "Network.retryBackoffStrategy",
            text: "apply retry backoff strategy before requesting again",
            embedding: vectors.first
        )
        return SearchCorpus(store: store)
    }

    /// Gives the finished spans of `tracer` that have the name `name`.
    /// - Parameters:
    ///   - name: The operation name of the spans.
    ///   - tracer: The tracer that holds the spans.
    /// - Returns: The spans, in the order of their end.
    private static func spans(named name: String, in tracer: InMemoryTracer) -> [FinishedInMemorySpan] {
        tracer.finishedSpans.filter { $0.operationName == name }
    }

    /// Gives the "enter" records of the spans that have the name `spanName`.
    /// - Parameter spanName: The operation name of the span.
    /// - Returns: The records whose message is `enter <spanName>`.
    private static func enterRecords(forSpanNamed spanName: String) -> [InMemoryLogHandler.Entry] {
        CapturedLogRecords.entries.filter { $0.message.description == "enter \(spanName)" }
    }
}

/// An embed error whose description holds a marker text, to prove that a span does not record
/// the description of an error.
private struct MarkedEmbedError: Error, CustomStringConvertible {
    /// The marker text.
    let marker: String

    /// The text that `String(describing:)` gives: the marker.
    var description: String { marker }
}

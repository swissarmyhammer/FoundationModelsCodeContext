import Foundation
import Testing

@testable import FoundationModelsCodeContext

/// The error that the fake selection model throws, so a test can find it again at the end of
/// the call.
private struct SelectionSessionFailure: Error, Equatable {
    /// A marker that tells this failure from another one.
    let reason: String
}

/// Tests for the selection step of `SearchCode.run(corpus:embedder:selection:query:topK:weights:tracer:)`:
/// retrieval gives the candidates, and the selection model reorders or filters them.
///
/// The model is a `FakeLanguageModel` that plays a script. No test of this suite loads a real
/// model.
struct SearchCodeSelectionTests {
    // MARK: - Fixtures

    /// The query of every test. Each chunk of the fixture holds each word, thus retrieval returns
    /// every chunk.
    private static let query = "retry backoff"

    /// The symbol paths of the chunks of the fixture.
    private static let symbolPaths = ["Network.retryAlpha", "Network.retryBeta", "Network.retryGamma"]

    /// An id that no candidate has.
    private static let unknownID = "no-such-candidate-id-7f3a"

    /// Makes a corpus of the three chunks of `symbolPaths`.
    private static func makeCorpus(store: Store) async throws -> SearchCorpus {
        for symbolPath in symbolPaths {
            try await insertChunk(
                store: store, filePath: "\(symbolPath).swift", symbolPath: symbolPath,
                text: "func \(symbolPath)() { retry backoff before the request }"
            )
        }
        return SearchCorpus(store: store)
    }

    /// Runs the full search with `model`.
    private static func run(
        corpus: SearchCorpus, model: FakeLanguageModel, factoryCalls: FactoryCallLog = FactoryCallLog(), topK: Int = 20
    ) async throws -> SearchCodeResult {
        try await SearchCode.run(
            corpus: corpus, embedder: nil, selection: model.factory(recording: factoryCalls), query: query, topK: topK
        )
    }

    /// The ids of the retrieval hits of the fixture, in retrieval order.
    private static func retrievedIDs(corpus: SearchCorpus) async throws -> [String] {
        try await SearchCode.retrieve(corpus: corpus, embedder: nil, query: query).hits.map(\.hit.id)
    }

    // MARK: - Selection reorders and filters

    @Test
    func theSelectionModelReordersTheRetrievalCandidates() async throws {
        try await withTemporaryWorkspace { root in
            let corpus = try await Self.makeCorpus(store: Store(rootDirectory: root))
            let retrieved = try await Self.retrievedIDs(corpus: corpus)

            let result = try await Self.run(corpus: corpus, model: FakeLanguageModel(selecting: retrieved.reversed()))

            #expect(result.hits.map(\.hit.id) == retrieved.reversed())
        }
    }

    @Test
    func theSelectionModelFiltersTheRetrievalCandidates() async throws {
        try await withTemporaryWorkspace { root in
            let corpus = try await Self.makeCorpus(store: Store(rootDirectory: root))
            let retrieved = try await Self.retrievedIDs(corpus: corpus)

            let result = try await Self.run(corpus: corpus, model: FakeLanguageModel(selecting: [retrieved[1]]))

            #expect(result.hits.map(\.hit.id) == [retrieved[1]])
        }
    }

    @Test
    func aSelectedMatchKeepsTheScoreAndTheSignalsOfRetrieval() async throws {
        try await withTemporaryWorkspace { root in
            let corpus = try await Self.makeCorpus(store: Store(rootDirectory: root))
            let retrieval = try await SearchCode.retrieve(corpus: corpus, embedder: nil, query: Self.query)
            let lastCandidate = try #require(retrieval.hits.last)

            let result = try await Self.run(corpus: corpus, model: FakeLanguageModel(selecting: [lastCandidate.hit.id]))

            #expect(result.hits.first?.hit == lastCandidate.hit)
        }
    }

    @Test
    func theSelectionResultCarriesTheIndexingNoteOfRetrieval() async throws {
        try await withTemporaryWorkspace { root in
            let corpus = try await Self.makeCorpus(store: Store(rootDirectory: root))
            let retrieved = try await Self.retrievedIDs(corpus: corpus)

            let result = try await Self.run(corpus: corpus, model: FakeLanguageModel(selecting: retrieved))

            #expect(result.indexingProgress?.embeddedChunks == 0)
        }
    }

    @Test
    func theResultIsCutToTopKCandidatesBeforeSelection() async throws {
        try await withTemporaryWorkspace { root in
            let corpus = try await Self.makeCorpus(store: Store(rootDirectory: root))
            let factoryCalls = FactoryCallLog()
            let topK = 2

            _ = try await Self.run(
                corpus: corpus, model: FakeLanguageModel(selecting: []), factoryCalls: factoryCalls, topK: topK
            )

            #expect(factoryCalls.uses.first?.count == topK)
        }
    }

    // MARK: - The factory

    @Test
    func theFactoryReceivesTheIdsOfTheCandidatesInRetrievalOrderOneTime() async throws {
        try await withTemporaryWorkspace { root in
            let corpus = try await Self.makeCorpus(store: Store(rootDirectory: root))
            let retrieved = try await Self.retrievedIDs(corpus: corpus)
            let factoryCalls = FactoryCallLog()

            _ = try await Self.run(corpus: corpus, model: FakeLanguageModel(selecting: []), factoryCalls: factoryCalls)

            #expect(factoryCalls.uses == [retrieved])
        }
    }

    @Test
    func aSearchWithNoCandidateNeitherCallsTheFactoryNorTheModel() async throws {
        try await withTemporaryWorkspace { root in
            let corpus = SearchCorpus(store: try Store(rootDirectory: root))
            let model = FakeLanguageModel(selecting: [])
            let factoryCalls = FactoryCallLog()

            let result = try await Self.run(corpus: corpus, model: model, factoryCalls: factoryCalls)

            #expect(factoryCalls.uses.isEmpty && model.calls.isEmpty && result.hits.isEmpty)
        }
    }

    @Test
    func anErrorOfTheFactoryIsTheErrorOfTheSearch() async throws {
        try await withTemporaryWorkspace { root in
            let corpus = try await Self.makeCorpus(store: Store(rootDirectory: root))
            let failure = SelectionSessionFailure(reason: "the factory cannot make a configuration")

            await #expect(throws: SelectionSessionFailure.self) {
                try await SearchCode.run(corpus: corpus, embedder: nil, selection: { _ in throw failure }, query: Self.query)
            }
        }
    }

    // MARK: - The model

    @Test
    func theModelIsCalledOneTimeForOneSearch() async throws {
        try await withTemporaryWorkspace { root in
            let corpus = try await Self.makeCorpus(store: Store(rootDirectory: root))
            let model = FakeLanguageModel(selecting: [])

            _ = try await Self.run(corpus: corpus, model: model)

            #expect(model.calls.count == 1)
        }
    }

    @Test
    func aSelectionErrorIsTheErrorOfTheSearchAndNoRetrievalOnlyResultReplacesIt() async throws {
        try await withTemporaryWorkspace { root in
            let corpus = try await Self.makeCorpus(store: Store(rootDirectory: root))
            let failure = SelectionSessionFailure(reason: "the selection session failed")

            await #expect(throws: SelectionSessionFailure.self) {
                try await Self.run(corpus: corpus, model: FakeLanguageModel(throwing: failure))
            }
        }
    }

    // MARK: - An id that is not a candidate

    @Test
    func anIdThatIsNotACandidateIsDroppedFromTheResult() async throws {
        try await withTemporaryWorkspace { root in
            let corpus = try await Self.makeCorpus(store: Store(rootDirectory: root))
            let retrieved = try await Self.retrievedIDs(corpus: corpus)

            let result = try await Self.run(
                corpus: corpus, model: FakeLanguageModel(selecting: [Self.unknownID, retrieved[0]])
            )

            #expect(result.hits.map(\.hit.id) == [retrieved[0]])
        }
    }

    @Test
    func anIdThatIsNotACandidateWritesARecordWithNoContent() async throws {
        try await withTemporaryWorkspace { root in
            let corpus = try await Self.makeCorpus(store: Store(rootDirectory: root))
            _ = CapturedLogRecords.handler

            _ = try await Self.run(corpus: corpus, model: FakeLanguageModel(selecting: [Self.unknownID]))

            let records = CapturedLogRecords.entries(holding: SelectionDiagnostics.unknownSelectedIDMessage)
            #expect(!records.isEmpty && CapturedLogRecords.entries(holding: Self.unknownID).isEmpty)
        }
    }
}

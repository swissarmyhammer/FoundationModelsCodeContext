import Foundation
import GRDB
import Testing

@testable import CodeContextKit

/// L2-normalizes `vector`, or returns it unchanged if its magnitude is `0`.
private func normalized(_ vector: [Float]) -> [Float] {
    let magnitude = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
    guard magnitude > 0 else { return vector }
    return vector.map { $0 / magnitude }
}

/// Tests for `FindDuplicatesOps.findDuplicates(corpus:file:minSimilarity:minChunkBytes:maxPerChunk:)`:
/// meta-type-aware near-duplicate grouping, per the task's `/tdd` workflow
/// and acceptance criteria (duplicate grouping golden, cross-meta-type
/// suppression, threshold/self-pair/same-symbol-pair exclusion, and
/// file-scope filtering).
struct FindDuplicatesTests {
    // MARK: - Duplicate grouping golden

    @Test
    func twoNearIdenticalFunctionsInDifferentFilesAreGroupedTogether() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await insertChunk(
                store: store,
                filePath: "A.swift",
                symbolPath: "A.validate",
                text: "func validate(req: Request) -> Bool { checkFields(req) }",
                kind: .function,
                embedding: normalized([0.9, 0.1, 0.0])
            )
            try await insertChunk(
                store: store,
                filePath: "B.swift",
                symbolPath: "B.check",
                text: "func check(req: Request) -> Bool { checkFields(req) }",
                kind: .function,
                embedding: normalized([0.89, 0.11, 0.01])
            )
            let corpus = SearchCorpus(store: store)

            let result = try await FindDuplicatesOps.findDuplicates(corpus: corpus, file: "A.swift", minChunkBytes: 1)

            #expect(result.groups.count == 1)
            let group = try #require(result.groups.first)
            #expect(group.source.filePath == "A.swift")
            #expect(group.source.symbolPath == "A.validate")
            #expect(group.duplicates.count == 1)
            #expect(group.duplicates[0].chunk.filePath == "B.swift")
            #expect(group.duplicates[0].similarity > 0.99)
        }
    }

    // MARK: - Cross-meta-type suppression

    @Test
    func typeChunkAboveThresholdAgainstAFunctionIsNotReported() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await insertChunk(
                store: store,
                filePath: "Function.swift",
                symbolPath: "doWork",
                text: "func doWork() { performTask(); finishUp(); }",
                kind: .function,
                embedding: normalized([1.0, 0.0, 0.0])
            )
            try await insertChunk(
                store: store,
                filePath: "TypeDecl.swift",
                symbolPath: "Worker",
                text: "struct Worker { var task: String; var status: String }",
                kind: .type,
                embedding: normalized([0.99, 0.01, 0.0])
            )
            let corpus = SearchCorpus(store: store)

            let result = try await FindDuplicatesOps.findDuplicates(corpus: corpus, file: "Function.swift", minChunkBytes: 1)

            #expect(result.groups.isEmpty)
        }
    }

    @Test
    func methodAndFunctionShareAPartitionAndCanBeGroupedTogether() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await insertChunk(
                store: store,
                filePath: "Free.swift",
                symbolPath: "process",
                text: "func process(data: Data) -> Data { transform(data) }",
                kind: .function,
                embedding: normalized([0.9, 0.1, 0.0])
            )
            try await insertChunk(
                store: store,
                filePath: "Bound.swift",
                symbolPath: "Pipeline.process",
                text: "func process(data: Data) -> Data { transform(data) }",
                kind: .method,
                embedding: normalized([0.89, 0.11, 0.01])
            )
            let corpus = SearchCorpus(store: store)

            let result = try await FindDuplicatesOps.findDuplicates(corpus: corpus, file: "Free.swift", minChunkBytes: 1)

            #expect(result.groups.count == 1)
            #expect(result.groups[0].duplicates.first?.chunk.symbolPath == "Pipeline.process")
        }
    }

    // MARK: - Similarity threshold

    @Test
    func minSimilarityThresholdSuppressesLowerScoringMatchesUntilLowered() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await insertChunk(
                store: store,
                filePath: "X.swift",
                symbolPath: "alpha",
                text: "func alpha() { doSomethingSpecific(); returnResult(); }",
                kind: .function,
                embedding: normalized([1.0, 0.0])
            )
            try await insertChunk(
                store: store,
                filePath: "Y.swift",
                symbolPath: "beta",
                text: "func beta() { doSomethingElseEntirely(); anotherResult(); }",
                kind: .function,
                embedding: normalized([1.0, 1.0])
            )
            let corpus = SearchCorpus(store: store)

            let defaultResult = try await FindDuplicatesOps.findDuplicates(corpus: corpus, file: "X.swift", minChunkBytes: 1)
            #expect(defaultResult.groups.isEmpty)

            let loweredResult = try await FindDuplicatesOps.findDuplicates(corpus: corpus, file: "X.swift", minSimilarity: 0.5, minChunkBytes: 1)
            #expect(loweredResult.groups.count == 1)
            #expect(loweredResult.groups[0].duplicates[0].similarity >= 0.5)
        }
    }

    // MARK: - Self-pairs and same-symbol pairs

    @Test
    func selfPairIsNeverReportedInWorkspaceScope() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await insertChunk(
                store: store,
                filePath: "Solo.swift",
                symbolPath: "lonely",
                text: "func lonely() { doOneThing(); doAnotherThing(); }",
                kind: .function,
                embedding: normalized([1.0, 0.0, 0.0])
            )
            let corpus = SearchCorpus(store: store)

            let result = try await FindDuplicatesOps.findDuplicates(corpus: corpus, minChunkBytes: 1)

            #expect(result.groups.isEmpty)
        }
    }

    @Test
    func sameSymbolPairAcrossDuplicateRowsIsNeverReported() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            // Two ts_chunks rows sharing the exact same (filePath, symbolPath)
            // identity — as could happen from a re-chunk quirk — with
            // near-identical embeddings. These must never be reported as
            // duplicates of each other, even though the cosine similarity is
            // well above the default threshold.
            try await insertChunk(
                store: store,
                filePath: "Same.swift",
                symbolPath: "repeated",
                text: "func repeated() { doWork(); finish(); }",
                kind: .function,
                startLine: 0,
                endLine: 2,
                embedding: normalized([1.0, 0.0, 0.0])
            )
            try await insertChunk(
                store: store,
                filePath: "Same.swift",
                symbolPath: "repeated",
                text: "func repeated() { doWork(); finish(); }",
                kind: .function,
                startLine: 10,
                endLine: 12,
                embedding: normalized([0.99, 0.01, 0.0])
            )
            let corpus = SearchCorpus(store: store)

            let result = try await FindDuplicatesOps.findDuplicates(corpus: corpus, minChunkBytes: 1)

            #expect(result.groups.isEmpty)
        }
    }

    // MARK: - File scope

    @Test
    func fileScopeOnlyReturnsGroupsWhoseSourceChunkIsInTheGivenFile() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await insertChunk(
                store: store,
                filePath: "A.swift",
                symbolPath: "A.shared",
                text: "func shared() { runCommonLogic(); reportOutcome(); }",
                kind: .function,
                embedding: normalized([0.9, 0.1, 0.0])
            )
            try await insertChunk(
                store: store,
                filePath: "B.swift",
                symbolPath: "B.shared",
                text: "func shared() { runCommonLogic(); reportOutcome(); }",
                kind: .function,
                embedding: normalized([0.89, 0.11, 0.01])
            )
            try await insertChunk(
                store: store,
                filePath: "C.swift",
                symbolPath: "C.unrelated",
                text: "func unrelated() { fetchNetworkData(); parseJson(); }",
                kind: .function,
                embedding: normalized([0.0, 1.0, 0.0])
            )
            let corpus = SearchCorpus(store: store)

            let result = try await FindDuplicatesOps.findDuplicates(corpus: corpus, file: "A.swift", minChunkBytes: 1)

            #expect(result.groups.count == 1)
            #expect(result.groups.allSatisfy { $0.source.filePath == "A.swift" })
        }
    }

    @Test
    func fileScopeCandidatePoolIncludesOtherChunksInTheSameFile() async throws {
        // The Rust reference (find_duplicates.rs) excludes same-file
        // candidates entirely when scoped to a file. This Swift port
        // deliberately deviates — `file` only restricts which chunks are
        // candidate *sources*, not which chunks can be reported as
        // *duplicates* — so two near-identical symbols in the very same
        // file must still be grouped together.
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await insertChunk(
                store: store,
                filePath: "Same.swift",
                symbolPath: "foo",
                text: "func foo() { runCommonLogic(); reportOutcome(); }",
                kind: .function,
                startLine: 0,
                endLine: 2,
                embedding: normalized([0.9, 0.1, 0.0])
            )
            try await insertChunk(
                store: store,
                filePath: "Same.swift",
                symbolPath: "bar",
                text: "func bar() { runCommonLogic(); reportOutcome(); }",
                kind: .function,
                startLine: 10,
                endLine: 12,
                embedding: normalized([0.89, 0.11, 0.01])
            )
            let corpus = SearchCorpus(store: store)

            let result = try await FindDuplicatesOps.findDuplicates(corpus: corpus, file: "Same.swift", minChunkBytes: 1)

            #expect(result.groups.count == 2)
            let fooGroup = try #require(result.groups.first { $0.source.symbolPath == "foo" })
            #expect(fooGroup.duplicates.first?.chunk.symbolPath == "bar")
        }
    }

    @Test
    func workspaceScopeFindsMutualDuplicatesAcrossFilesInBothDirections() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await insertChunk(
                store: store,
                filePath: "A.swift",
                symbolPath: "A.shared",
                text: "func shared() { runCommonLogic(); reportOutcome(); }",
                kind: .function,
                embedding: normalized([0.9, 0.1, 0.0])
            )
            try await insertChunk(
                store: store,
                filePath: "B.swift",
                symbolPath: "B.shared",
                text: "func shared() { runCommonLogic(); reportOutcome(); }",
                kind: .function,
                embedding: normalized([0.89, 0.11, 0.01])
            )
            let corpus = SearchCorpus(store: store)

            let result = try await FindDuplicatesOps.findDuplicates(corpus: corpus, minChunkBytes: 1)

            #expect(result.groups.count == 2)
            #expect(Set(result.groups.map(\.source.filePath)) == ["A.swift", "B.swift"])
        }
    }

    // MARK: - Empty/no-embedding corpus

    @Test
    func emptyCorpusReturnsNoGroups() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            let corpus = SearchCorpus(store: store)

            let result = try await FindDuplicatesOps.findDuplicates(corpus: corpus)

            #expect(result.groups.isEmpty)
            #expect(result.sourceChunks == 0)
            #expect(result.comparedChunks == 0)
        }
    }
}

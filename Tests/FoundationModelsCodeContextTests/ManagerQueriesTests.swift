import Foundation
import Testing

@testable import FoundationModelsCodeContext

/// Tests for `CodeContextManager`'s fan-out queries (`Ops/ManagerQueries.swift`):
/// `searchCode(query:topK:weights:)`, `searchSymbol(query:kind:maxResults:)`, and
/// `grepCode(pattern:languages:filePattern:maxResults:)`.
///
/// `grepCode` is the workhorse for the merge-order/union-cap assertions below: its matches are
/// fully deterministic (sorted by `(filePath, startLine)` within a root, with no fuzzy/fused
/// scoring to control), so the shared `interleave(perRoot:limit:)` logic every one of the three
/// fan-out methods delegates to can be exercised precisely. `searchCode`/`searchSymbol` each get
/// a lighter smoke test confirming root attribution and non-crash behavior, since they share the
/// exact same merge helper `grepCode`'s tests already cover in depth.
///
/// Driven entirely against `FakeLanguageServerConnection` and `FakeEmbedder` via the internal
/// general initializer, mirroring `CodeContextManagerTests`'s own setup. Fixtures deliberately
/// omit project-marker files so no real LSP daemon ever spawns.
struct ManagerQueriesTests {
    // MARK: - Fixtures

    /// Builds a `CodeContextManager<FakeLanguageServerConnection>` wired to a fake filesystem-event
    /// source and a fake LSP connection factory (never actually invoked in these tests, since no
    /// fixture here has a detected project/server spec).
    /// - Returns: A manager wired to fake filesystem-event and connection sources for testing.
    private static func makeManager() async -> CodeContextManager<FakeLanguageServerConnection> {
        await CodeContextManager<FakeLanguageServerConnection>(
            embedder: FakeEmbedder(dimension: 8),
            eventSource: FakeFileEventSource(),
            connectionFactory: fakeConnectionFactory(pid: 1, processState: ProcessState())
        )
    }

    /// Writes a fixture file containing `count` distinct top-level functions, each containing the
    /// literal comment `// MARKERTAG` so `grepCode(pattern: "MARKERTAG")` matches exactly `count`
    /// chunks in this file — one per function, in source (and therefore start-line) order.
    /// - Parameters:
    ///   - root: The workspace root to write the fixture file into.
    ///   - namePrefix: A prefix used to build each function's unique name (e.g. `"a"` yields
    ///     `markerFunc_a0`, `markerFunc_a1`, ...), so fixtures written into different roots never
    ///     collide on symbol name.
    ///   - count: How many distinct marker-containing functions to write.
    private static func writeMarkerFixture(in root: URL, namePrefix: String, count: Int) throws {
        var body = ""
        for index in 0..<count {
            body += """
            func markerFunc_\(namePrefix)\(index)() -> Int {
                // MARKERTAG
                return \(index)
            }

            """
        }
        try write(body, to: "Fixture.swift", in: root)
    }

    /// Writes a fixture file with one function whose body contains `word`, for `searchCode`'s
    /// BM25 keyword-overlap smoke test.
    private static func writeSearchCodeFixture(in root: URL, functionName: String, word: String) throws {
        try write(
            """
            func \(functionName)() -> String {
                // \(word) appears here as a keyword for BM25 to find
                return "\(word)"
            }
            """,
            to: "Fixture.swift", in: root
        )
    }

    /// Writes a fixture file with one function whose name contains `substring`, for
    /// `searchSymbol`'s fuzzy-match smoke test.
    private static func writeSearchSymbolFixture(in root: URL, functionName: String) throws {
        try write("func \(functionName)() -> Int { 1 }\n", to: "Fixture.swift", in: root)
    }

    /// Overwrites every `.code-context/kit.db*` file under `root` in place — never via an atomic
    /// replace, which would swap in a fresh inode any already-open `DatabasePool` connection
    /// wouldn't see — with garbage bytes, so the next query against that root's already-open
    /// context throws `CodeContextError.storage`.
    /// - Parameter root: The workspace root whose already-opened index store to corrupt.
    /// - Throws: File system errors from listing or writing the `.code-context` directory.
    private static func corruptStore(at root: URL) throws {
        let indexDirectory = root.appendingPathComponent(".code-context", isDirectory: true)
        let entries = try FileManager.default.contentsOfDirectory(at: indexDirectory, includingPropertiesForKeys: nil)
        for entry in entries where entry.lastPathComponent.hasPrefix("kit.db") {
            let handle = try FileHandle(forWritingTo: entry)
            handle.write(Data(repeating: 0xFF, count: 8192))
            try handle.close()
        }
    }

    // MARK: - grepCode: rank-major interleave order

    @Test
    func grepCodeInterleavesEveryRootsRankBeforeAnyRootsNextRank() async throws {
        try await withTemporaryWorkspace { workspace in
            let repoA = workspace.appendingPathComponent("repo-a")
            let repoB = workspace.appendingPathComponent("repo-b")
            let repoC = workspace.appendingPathComponent("repo-c")
            try Self.writeMarkerFixture(in: repoA, namePrefix: "a", count: 5)
            try Self.writeMarkerFixture(in: repoB, namePrefix: "b", count: 2)
            try Self.writeMarkerFixture(in: repoC, namePrefix: "c", count: 1)
            let manager = await Self.makeManager()
            _ = try await manager.context(for: repoA)
            _ = try await manager.context(for: repoB)
            _ = try await manager.context(for: repoC)

            let (results, failures) = await manager.grepCode(pattern: "MARKERTAG", maxResults: 100)

            #expect(failures.isEmpty)
            // rank 0: A, B, C (root-path order) — rank 1: A, B (C exhausted) — ranks 2-4: A only.
            let expectedRootOrder = [
                repoA, repoB, repoC,
                repoA, repoB,
                repoA, repoA, repoA,
            ].map(\.standardizedFileURL)
            #expect(results.map(\.root) == expectedRootOrder)
            #expect(results.count == 8)

            await manager.shutdown()
        }
    }

    @Test
    func grepCodeUnionCapSmallerThanOneRootsCountStillSamplesEveryRoot() async throws {
        try await withTemporaryWorkspace { workspace in
            let repoA = workspace.appendingPathComponent("repo-a")
            let repoB = workspace.appendingPathComponent("repo-b")
            let repoC = workspace.appendingPathComponent("repo-c")
            try Self.writeMarkerFixture(in: repoA, namePrefix: "a", count: 5)
            try Self.writeMarkerFixture(in: repoB, namePrefix: "b", count: 2)
            try Self.writeMarkerFixture(in: repoC, namePrefix: "c", count: 1)
            let manager = await Self.makeManager()
            _ = try await manager.context(for: repoA)
            _ = try await manager.context(for: repoB)
            _ = try await manager.context(for: repoC)

            // A cap smaller than repoA's own 5 matches must still include repoB's and repoC's.
            let (results, failures) = await manager.grepCode(pattern: "MARKERTAG", maxResults: 4)

            #expect(failures.isEmpty)
            #expect(results.count == 4)
            let expectedRootOrder = [repoA, repoB, repoC, repoA].map(\.standardizedFileURL)
            #expect(results.map(\.root) == expectedRootOrder)
            #expect(Set(results.map(\.root)) == Set([repoA, repoB, repoC].map(\.standardizedFileURL)))

            await manager.shutdown()
        }
    }

    // MARK: - Root attribution

    @Test
    func grepCodeDistinguishesIdenticallyPathedMatchesByRoot() async throws {
        try await withTemporaryWorkspace { workspace in
            let repoA = workspace.appendingPathComponent("repo-a")
            let repoB = workspace.appendingPathComponent("repo-b")
            // Both roots write the identical relative path "Fixture.swift" with one matching chunk.
            try Self.writeMarkerFixture(in: repoA, namePrefix: "a", count: 1)
            try Self.writeMarkerFixture(in: repoB, namePrefix: "b", count: 1)
            let manager = await Self.makeManager()
            _ = try await manager.context(for: repoA)
            _ = try await manager.context(for: repoB)

            let (results, failures) = await manager.grepCode(pattern: "MARKERTAG", maxResults: 100)

            #expect(failures.isEmpty)
            #expect(results.count == 2)
            #expect(Set(results.map(\.value.filePath)) == ["Fixture.swift"])
            #expect(Set(results.map(\.root)) == Set([repoA, repoB].map(\.standardizedFileURL)))

            await manager.shutdown()
        }
    }

    // MARK: - Partial failure

    @Test
    func singleRootFailureIsCapturedWhileOtherRootsStillSucceed() async throws {
        try await withTemporaryWorkspace { workspace in
            let repoA = workspace.appendingPathComponent("repo-a")
            let repoB = workspace.appendingPathComponent("repo-b")
            try Self.writeMarkerFixture(in: repoA, namePrefix: "a", count: 2)
            try Self.writeMarkerFixture(in: repoB, namePrefix: "b", count: 2)
            let manager = await Self.makeManager()
            _ = try await manager.context(for: repoA)
            _ = try await manager.context(for: repoB)

            try Self.corruptStore(at: repoB)

            let (results, failures) = await manager.grepCode(pattern: "MARKERTAG", maxResults: 100)

            #expect(failures.count == 1)
            let failure = try #require(failures.first)
            #expect(failure.root == repoB.standardizedFileURL)
            #expect(!results.isEmpty)
            #expect(results.allSatisfy { $0.root == repoA.standardizedFileURL })

            await manager.shutdown()
        }
    }

    // MARK: - Zero open roots

    @Test
    func zeroOpenRootsReturnsEmptyResultsAndFailuresForEveryFanOutQuery() async {
        let manager = await Self.makeManager()

        let searchCodeOutcome = await manager.searchCode(query: "anything")
        #expect(searchCodeOutcome.results.isEmpty)
        #expect(searchCodeOutcome.failures.isEmpty)

        let searchSymbolOutcome = await manager.searchSymbol(query: "anything")
        #expect(searchSymbolOutcome.results.isEmpty)
        #expect(searchSymbolOutcome.failures.isEmpty)

        let grepCodeOutcome = await manager.grepCode(pattern: "anything")
        #expect(grepCodeOutcome.results.isEmpty)
        #expect(grepCodeOutcome.failures.isEmpty)

        await manager.shutdown()
    }

    // MARK: - searchCode smoke test

    @Test
    func searchCodeFansOutAndRootQualifiesHitsFromEveryRoot() async throws {
        try await withTemporaryWorkspace { workspace in
            let repoA = workspace.appendingPathComponent("repo-a")
            let repoB = workspace.appendingPathComponent("repo-b")
            try Self.writeSearchCodeFixture(in: repoA, functionName: "rootASearchElephant", word: "elephant")
            try Self.writeSearchCodeFixture(in: repoB, functionName: "rootBSearchElephant", word: "elephant")
            let manager = await Self.makeManager()
            _ = try await manager.context(for: repoA)
            _ = try await manager.context(for: repoB)

            let (results, failures) = await manager.searchCode(query: "elephant")

            #expect(failures.isEmpty)
            #expect(Set(results.map(\.root)) == Set([repoA, repoB].map(\.standardizedFileURL)))
            for rooted in results {
                #expect(rooted.value.hit.signals.bm25 > 0.0)
            }

            await manager.shutdown()
        }
    }

    // MARK: - searchSymbol smoke test

    @Test
    func searchSymbolFansOutAndRootQualifiesMatchesFromEveryRoot() async throws {
        try await withTemporaryWorkspace { workspace in
            let repoA = workspace.appendingPathComponent("repo-a")
            let repoB = workspace.appendingPathComponent("repo-b")
            try Self.writeSearchSymbolFixture(in: repoA, functionName: "gizmoAlpha")
            try Self.writeSearchSymbolFixture(in: repoB, functionName: "gizmoBeta")
            let manager = await Self.makeManager()
            _ = try await manager.context(for: repoA)
            _ = try await manager.context(for: repoB)

            let (results, failures) = await manager.searchSymbol(query: "gizmo")

            #expect(failures.isEmpty)
            #expect(results.count == 2)
            #expect(Set(results.map(\.root)) == Set([repoA, repoB].map(\.standardizedFileURL)))

            await manager.shutdown()
        }
    }
}

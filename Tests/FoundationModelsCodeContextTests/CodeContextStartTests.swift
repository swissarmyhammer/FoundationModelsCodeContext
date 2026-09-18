import Foundation
import Testing

@testable import FoundationModelsCodeContext

/// Tests for the bounded `start()` of `CodeContext`, for `stop()` during the
/// first index pass, and for the embedding layer that a host turns off.
///
/// The fixtures have no project marker, thus no LSP daemon starts.
struct CodeContextStartTests {
    /// The dimension of the fake embedding vectors.
    private static let dimension = 8

    /// The number of fixture files. Each file is one `embed(_:)` call or more,
    /// thus a complete pass makes more than one call.
    private static let fixtureFileCount = 3

    /// The time limit of each test, in minutes. A `start()` or a `stop()` that
    /// waits for the closed gate fails at this limit.
    private static let timeLimitMinutes = 1

    /// Makes a `CodeContext` for `rootDirectory` with a fake event source and
    /// a fake LSP connection factory.
    private static func makeCodeContext(
        rootDirectory: URL,
        embedder: TextEmbedding?
    ) async throws -> CodeContext<FakeLanguageServerConnection> {
        try await CodeContext<FakeLanguageServerConnection>(
            rootDirectory: rootDirectory,
            embedder: embedder,
            eventSource: FakeFileEventSource(),
            autoInstall: LspAutoInstall(isEnabled: false),
            connectionFactory: fakeConnectionFactory(pid: 1, processState: ProcessState())
        )
    }

    /// Writes `fixtureFileCount` Swift files into `root`. File `N` holds the
    /// function `greetN()`.
    private static func writeFixture(in root: URL) throws {
        for index in 0..<fixtureFileCount {
            try write("func greet\(index)() -> String {\n    \"hello\"\n}\n", to: "Greeter\(index).swift", in: root)
        }
    }

    /// Returns `true` when `error` is `CodeContextError.embeddingDisabled`.
    private static func isEmbeddingDisabled(_ error: CodeContextError?) -> Bool {
        if case .embeddingDisabled = error {
            return true
        }
        return false
    }

    @Test(.timeLimit(.minutes(CodeContextStartTests.timeLimitMinutes)))
    func startReturnsBeforeTheEmbeddingStepIsComplete() async throws {
        try await withTemporaryWorkspace { root in
            try Self.writeFixture(in: root)
            let log = EmbedCallLog()
            await log.closeGate()
            let context = try await Self.makeCodeContext(
                rootDirectory: root,
                embedder: GatedEmbedder(dimension: Self.dimension, log: log)
            )

            try await context.start()

            #expect(!(await context.state.isReady))
            await log.waitForFirstCall()
            let matches = try await context.searchSymbol(query: "greet0")
            #expect(matches.contains { $0.name == "greet0" })
            #expect(!(await context.indexStatus().isDrained))

            await log.openGate()
            await context.waitForFirstIndexPass()

            let status = await context.indexStatus()
            #expect(status.filesWalked == Self.fixtureFileCount)
            #expect(status.isDrained)
            #expect(await context.state.isReady)
            await context.stop()
        }
    }

    @Test(.timeLimit(.minutes(CodeContextStartTests.timeLimitMinutes)))
    func stopDuringTheFirstPassCancelsThePass() async throws {
        try await withTemporaryWorkspace { root in
            try Self.writeFixture(in: root)
            let log = EmbedCallLog()
            await log.closeGate()
            let context = try await Self.makeCodeContext(
                rootDirectory: root,
                embedder: GatedEmbedder(dimension: Self.dimension, log: log)
            )
            try await context.start()
            await log.waitForFirstCall()

            await context.stop()

            #expect(await log.batchSizes.count == 1)
            let status = await context.indexStatus()
            #expect(status.filesEmbedded == 0)
        }
    }

    @Test(.timeLimit(.minutes(CodeContextStartTests.timeLimitMinutes)))
    func waitForFirstIndexPassReturnsWhenStopCancelsThePass() async throws {
        try await withTemporaryWorkspace { root in
            try Self.writeFixture(in: root)
            let log = EmbedCallLog()
            await log.closeGate()
            let context = try await Self.makeCodeContext(
                rootDirectory: root,
                embedder: GatedEmbedder(dimension: Self.dimension, log: log)
            )
            try await context.start()
            await log.waitForFirstCall()

            async let waited: Void = context.waitForFirstIndexPass()
            await context.stop()
            await waited

            #expect(!(await context.indexStatus().isDrained))
        }
    }

    @Test(.timeLimit(.minutes(CodeContextStartTests.timeLimitMinutes)))
    func aNilEmbedderTurnsTheEmbeddingLayerOff() async throws {
        try await withTemporaryWorkspace { root in
            try Self.writeFixture(in: root)
            let context = try await Self.makeCodeContext(rootDirectory: root, embedder: nil)
            try await context.start()
            await context.waitForFirstIndexPass()

            let status = await context.indexStatus()
            #expect(!status.isEmbeddingEnabled)
            #expect(status.filesEmbedded == 0)
            #expect(status.isDrained)
            #expect(await context.state.isReady)
            let matches = try await context.searchSymbol(query: "greet0")
            #expect(matches.contains { $0.name == "greet0" })

            let searchError = await #expect(throws: CodeContextError.self) {
                try await context.searchCode(query: "hello")
            }
            #expect(Self.isEmbeddingDisabled(searchError))
            let duplicatesError = await #expect(throws: CodeContextError.self) {
                try await context.findDuplicates()
            }
            #expect(Self.isEmbeddingDisabled(duplicatesError))
            await context.stop()
        }
    }

    @Test(.timeLimit(.minutes(CodeContextStartTests.timeLimitMinutes)))
    func anEmbedderTurnsTheEmbeddingLayerOn() async throws {
        try await withTemporaryWorkspace { root in
            try Self.writeFixture(in: root)
            let context = try await Self.makeCodeContext(rootDirectory: root, embedder: FakeEmbedder(dimension: Self.dimension))
            try await context.start()
            await context.waitForFirstIndexPass()

            let status = await context.indexStatus()
            #expect(status.isEmbeddingEnabled)
            #expect(status.filesEmbedded == Self.fixtureFileCount)
            let result = try await context.searchCode(query: "hello")
            #expect(!result.hits.isEmpty)
            await context.stop()
        }
    }
}

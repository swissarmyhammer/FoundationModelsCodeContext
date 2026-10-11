import Testing

@testable import FoundationModelsCodeContext

/// Tests for `EmbeddingCallQueue`: how it cuts the chunks of several files
/// into calls, when it gives a file back as complete, and what a skipped call
/// removes.
struct EmbeddingCallQueueTests {
    /// The number of chunks of each test file.
    private static let chunksInEachFile = 3

    /// The bound of the number of texts in one call that the tests use. It is
    /// not a multiple of `chunksInEachFile`, thus a call ends inside a file.
    private static let maxTextCount = 4

    /// Makes `chunksInEachFile` chunks for the file at `path`. The text of
    /// each chunk names the file and the chunk.
    ///
    /// - Parameters:
    ///   - path: The path of the file.
    ///   - firstIdentifier: The row identifier of the first chunk.
    /// - Returns: The chunks, in identifier order.
    private static func chunks(of path: String, firstIdentifier: Int64) -> [EmbeddableChunk] {
        (0..<chunksInEachFile).map { index in
            EmbeddableChunk(id: firstIdentifier + Int64(index), text: "\(path)#\(index)")
        }
    }

    /// Gives one vector for each text of `call`. The one component of a vector
    /// is the position of its text in the call.
    private static func vectors(for call: EmbeddingCall) -> [[Float]] {
        call.texts.indices.map { index in [Float(index)] }
    }

    /// Makes a queue that holds the chunks of each file of `paths`.
    private static func queue(of paths: [String]) -> EmbeddingCallQueue {
        var queue = EmbeddingCallQueue()
        for (index, path) in paths.enumerated() {
            queue.append(filePath: path, chunks: chunks(of: path, firstIdentifier: Int64(index * chunksInEachFile)))
        }
        return queue
    }

    @Test
    func aCallTakesTheNextChunksInFileOrderAcrossFiles() {
        var queue = Self.queue(of: ["A", "B"])

        let first = queue.nextCall(maxTextCount: Self.maxTextCount)
        let second = queue.nextCall(maxTextCount: Self.maxTextCount)

        #expect(first.texts == ["A#0", "A#1", "A#2", "B#0"])
        #expect(first.filePaths == ["A", "B"])
        #expect(second.texts == ["B#1", "B#2"])
        #expect(second.filePaths == ["B"])
        #expect(queue.unsentCount == 0)
    }

    @Test
    func aFileIsCompleteOnlyWhenEachOfItsChunksHasAVector() {
        var queue = Self.queue(of: ["A", "B"])

        let first = queue.nextCall(maxTextCount: Self.maxTextCount)
        let firstComplete = queue.complete(first, vectors: Self.vectors(for: first))
        let second = queue.nextCall(maxTextCount: Self.maxTextCount)
        let secondComplete = queue.complete(second, vectors: Self.vectors(for: second))

        #expect(firstComplete.map(\.filePath) == ["A"])
        #expect(firstComplete.first?.vectors == [[0], [1], [2]])
        #expect(secondComplete.map(\.filePath) == ["B"])
        #expect(secondComplete.first?.chunks.map(\.text) == ["B#0", "B#1", "B#2"])
        #expect(secondComplete.first?.vectors == [[3], [0], [1]])
    }

    @Test
    func aSkippedCallRemovesEachFileOfTheCallAndKeepsTheOtherFiles() {
        var queue = Self.queue(of: ["A", "B", "C"])

        let first = queue.nextCall(maxTextCount: Self.maxTextCount)
        queue.skip(first)
        let next = queue.nextCall(maxTextCount: Self.maxTextCount)
        let complete = queue.complete(next, vectors: Self.vectors(for: next))

        #expect(next.texts == ["C#0", "C#1", "C#2"])
        #expect(complete.map(\.filePath) == ["C"])
        #expect(queue.unsentCount == 0)
    }

    @Test
    func aSkippedCallDropsTheVectorsThatAnEarlierCallGaveItsFiles() {
        var queue = Self.queue(of: ["A", "B"])

        let first = queue.nextCall(maxTextCount: Self.maxTextCount)
        let firstComplete = queue.complete(first, vectors: Self.vectors(for: first))
        let second = queue.nextCall(maxTextCount: Self.maxTextCount)
        #expect(!queue.isEmpty)
        queue.skip(second)

        #expect(firstComplete.map(\.filePath) == ["A"])
        #expect(queue.isEmpty)
    }
}

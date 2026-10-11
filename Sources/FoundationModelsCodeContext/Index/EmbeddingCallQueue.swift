/// One `ts_chunks` row's identity and the text to embed for it, fetched for
/// embedding.
struct EmbeddableChunk: Sendable {
    /// The `ts_chunks` row identifier.
    let id: Int64

    /// The text to embed: the embed text of the chunk, which is the chunk
    /// text for each chunk that is not a container.
    let text: String
}

/// The texts of one `embed(texts:)` call, and the file of each text.
struct EmbeddingCall {
    /// The chunks of one file that one call holds.
    struct Part {
        /// The path of the file.
        let filePath: String

        /// The number of texts of the file in the call.
        let textCount: Int
    }

    /// The parts of the call, in file order. The texts of each part follow the
    /// texts of the part before it.
    let parts: [Part]

    /// The texts to embed, in the order of `parts`.
    let texts: [String]

    /// The path of each file that has texts in the call, in file order.
    var filePaths: [String] {
        parts.map(\.filePath)
    }
}

/// One file whose chunks all have a vector, ready to write.
struct EmbeddedFile: Sendable {
    /// The path of the file.
    let filePath: String

    /// The chunks of the file, in identifier order.
    let chunks: [EmbeddableChunk]

    /// One vector for each chunk, in the order of `chunks`.
    let vectors: [[Float]]
}

/// The dirty chunks of several files, in drain order, and the vectors that
/// the embedder gave for them.
///
/// `nextCall(maxTextCount:)` takes the next chunks that no call holds yet, in
/// file order. Thus one call can hold the chunks of more than one file, and
/// the chunks of one large file can go in more than one call.
/// `complete(_:vectors:)` gives back each file whose chunks all have a vector,
/// and only those files. `skip(_:)` removes each file of a failed call: its
/// vectors from earlier calls, and its chunks that no call holds yet. Thus a
/// file is written whole or not at all, and a failed call has an effect on the
/// files of that call only.
///
/// The caller must complete or skip each call before it takes the next call.
struct EmbeddingCallQueue {
    /// One file whose chunks do not all have a vector yet.
    private struct PendingFile {
        /// The path of the file.
        let filePath: String

        /// The chunks of the file, in identifier order.
        let chunks: [EmbeddableChunk]

        /// The number of chunks, from the start of `chunks`, that a call
        /// holds or held.
        var sentCount = 0

        /// The vectors of the first chunks of `chunks`, in the same order.
        var vectors: [[Float]] = []

        /// `true` when each chunk of the file has a vector.
        var isComplete: Bool {
            vectors.count == chunks.count
        }

        /// The number of chunks of the file that no call holds yet.
        var unsentCount: Int {
            chunks.count - sentCount
        }
    }

    /// The files that are not complete, in drain order.
    private var files: [PendingFile] = []

    /// The number of chunks that no call holds yet.
    private(set) var unsentCount = 0

    /// `true` when the queue holds no file.
    var isEmpty: Bool {
        files.isEmpty
    }

    /// Adds the chunks of one file after the files that the queue holds.
    ///
    /// - Parameters:
    ///   - filePath: The path of the file. The queue holds no other file with
    ///     this path.
    ///   - chunks: The chunks of the file, in identifier order. The value has
    ///     one chunk or more.
    mutating func append(filePath: String, chunks: [EmbeddableChunk]) {
        precondition(!chunks.isEmpty, "a file in the queue must have one chunk or more")
        files.append(PendingFile(filePath: filePath, chunks: chunks))
        unsentCount += chunks.count
    }

    /// Takes the next chunks that no call holds yet, in file order, for one
    /// call.
    ///
    /// - Parameter maxTextCount: The maximum number of texts in the call. The
    ///   value is 1 or more.
    /// - Returns: The call. It holds `maxTextCount` texts, or fewer when fewer
    ///   chunks are not sent.
    mutating func nextCall(maxTextCount: Int) -> EmbeddingCall {
        var parts: [EmbeddingCall.Part] = []
        var texts: [String] = []
        for index in files.indices where texts.count < maxTextCount && files[index].unsentCount > 0 {
            let start = files[index].sentCount
            let textCount = min(files[index].unsentCount, maxTextCount - texts.count)
            texts += files[index].chunks[start..<(start + textCount)].map(\.text)
            files[index].sentCount += textCount
            parts.append(EmbeddingCall.Part(filePath: files[index].filePath, textCount: textCount))
        }
        unsentCount -= texts.count
        return EmbeddingCall(parts: parts, texts: texts)
    }

    /// Records the vectors of `call`, and removes and gives back each file
    /// whose chunks all have a vector now.
    ///
    /// - Parameters:
    ///   - call: The last call that `nextCall(maxTextCount:)` gave.
    ///   - vectors: One vector for each text of `call`, in the order of its
    ///     texts.
    /// - Returns: The complete files, in drain order.
    mutating func complete(_ call: EmbeddingCall, vectors: [[Float]]) -> [EmbeddedFile] {
        precondition(vectors.count == call.texts.count, "a call must have one vector for each text")
        var remainingVectors = vectors[...]
        for part in call.parts {
            guard let index = files.firstIndex(where: { $0.filePath == part.filePath }) else {
                preconditionFailure("each file of a call must be in the queue")
            }
            files[index].vectors += remainingVectors.prefix(part.textCount)
            remainingVectors = remainingVectors.dropFirst(part.textCount)
        }
        let completeFiles = files.filter(\.isComplete).map { file in
            EmbeddedFile(filePath: file.filePath, chunks: file.chunks, vectors: file.vectors)
        }
        files.removeAll(where: \.isComplete)
        return completeFiles
    }

    /// Removes each file of `call`: its vectors from earlier calls, and its
    /// chunks that no call holds yet.
    ///
    /// - Parameter call: The last call that `nextCall(maxTextCount:)` gave.
    mutating func skip(_ call: EmbeddingCall) {
        let skippedPaths = Set(call.filePaths)
        let isSkipped: (PendingFile) -> Bool = { file in skippedPaths.contains(file.filePath) }
        unsentCount -= files.filter(isSkipped).map(\.unsentCount).reduce(0, +)
        files.removeAll(where: isSkipped)
    }
}

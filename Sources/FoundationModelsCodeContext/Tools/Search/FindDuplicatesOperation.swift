import FoundationModels
import Operations

/// The `find duplicates` operation of the `code_search` tool.
///
/// It finds the code chunks that are near-duplicates of each other.
@Generable
@Operation(
    verb: "find",
    noun: "duplicates",
    description: "Find the code chunks that are near-duplicates of each other. You can compare the chunks of one file only."
)
internal struct FindDuplicatesOperation {
    /// The file to compare, or `nil` for all the files.
    @Guide(description: "A file path relative to the workspace root.")
    @OperationParam(aliases: ["path", "filePath", "filename"])
    var file: String?

    /// The minimum similarity of a pair, or `nil` for the default.
    @Guide(description: "The minimum similarity of a pair of chunks, from 0.0 to 1.0.")
    @OperationParam(aliases: ["threshold", "similarity"])
    var minSimilarity: Double?

    /// The minimum size of a chunk, or `nil` for the default.
    @Guide(description: "The minimum size, in bytes, of a chunk to compare.")
    @OperationParam(aliases: ["minBytes", "minSize"])
    var minChunkBytes: Int?

    /// The maximum number of duplicates for one chunk, or `nil` for the
    /// default.
    @Guide(description: "The maximum number of duplicates to give for one chunk.")
    @OperationParam(aliases: ["perChunk"])
    var maxPerChunk: Int?
}

extension FindDuplicatesOperation {
    /// Calls `findDuplicates(file:minSimilarity:minChunkBytes:maxPerChunk:)`.
    ///
    /// - Parameter context: The tool context.
    /// - Returns: The engine result, or a corrective message.
    /// - Throws: An error that the model cannot correct.
    func execute(in context: CodeContextToolContext) async throws -> ToolOutcome<FindDuplicatesResult> {
        try await ToolSupport.outcome {
            try await context.operating.findDuplicates(
                file: file,
                minSimilarity: minSimilarity ?? CodeContextDefaults.duplicateMinSimilarity,
                minChunkBytes: minChunkBytes ?? CodeContextDefaults.duplicateMinChunkBytes,
                maxPerChunk: maxPerChunk ?? CodeContextDefaults.duplicateMaxPerChunk
            )
        }
    }
}

import Foundation
import FoundationModelsCodeContext
import FoundationModelsRanker
import Testing

/// Proves that one embedding-model value serves CodeContext and FoundationModelsRanker.
///
/// The embedder in this file conforms only to `FoundationModelsRanker.TextEmbedding`. This file
/// uses a plain `import FoundationModelsCodeContext`, not `@testable import`. Thus it sees only the
/// public API, as a host package sees it. If `FoundationModelsCodeContext.TextEmbedding` is not the
/// same type as `FoundationModelsRanker.TextEmbedding`, this file does not compile.
struct SharedEmbedderTests {
    /// The length of each vector that `RankerConformingEmbedder` returns.
    private static let embeddingDimension = 8

    /// The id of the one item that the test adds to the Ranker corpus.
    private static let itemID = "greeter"

    /// The text of the one item that the test adds to the Ranker corpus.
    private static let itemText = "func greet() prints a greeting"

    /// A caller-defined embedder that conforms to `FoundationModelsRanker.TextEmbedding` and to no
    /// other protocol, with no model and no network.
    ///
    /// The first entry of each vector is the character count of its text, and the other entries
    /// are zero. The vectors are not useful for search. The test examines only that the two APIs
    /// accept the same value.
    private struct RankerConformingEmbedder: FoundationModelsRanker.TextEmbedding {
        /// The length of each vector that `embed(_:)` returns.
        let dimension: Int

        /// Returns one `dimension`-length vector for each text, in order.
        ///
        /// - Parameter texts: The texts to embed.
        /// - Returns: One vector for each text, in the order of `texts`.
        func embed(_ texts: [String]) async throws -> [[Float]] {
            texts.map { text in
                [Float(text.count)] + Array(repeating: 0, count: dimension - 1)
            }
        }
    }

    /// Gives one embedder value to the public `CodeContext` initializer and to
    /// `FoundationModelsRanker.StreamingSearchCorpus(embedder:)`, and then uses each of them.
    ///
    /// The workspace has no project-marker file, so no language server starts. Auto-install is off,
    /// so the test runs no installer.
    @Test
    func oneEmbedderValueServesCodeContextAndRankerCorpus() async throws {
        try await withTemporaryWorkspace { root in
            let embedder = RankerConformingEmbedder(dimension: Self.embeddingDimension)

            let context = try await CodeContext(
                rootDirectory: root,
                embedder: embedder,
                autoInstall: LspAutoInstall(isEnabled: false)
            )
            let corpus = FoundationModelsRanker.StreamingSearchCorpus(embedder: embedder)
            await corpus.add(items: [FoundationModelsRanker.SearchItem(id: Self.itemID, text: Self.itemText)])
            let matches = await corpus.search(Self.itemText)

            #expect(context.rootDirectory == root.standardizedFileURL)
            #expect(matches.map(\.id) == [Self.itemID])
        }
    }
}

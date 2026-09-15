import Foundation
import FoundationModelsCodeContext
import Testing

/// Proves that a caller outside this module can give its own `TextEmbedding` conformance to the
/// public `CodeContextManager` initializer.
///
/// This file uses a plain `import FoundationModelsCodeContext`, not `@testable import`, and it does
/// not import FoundationModelsRanker. Thus it sees only the public API, as a host package sees it.
/// If `TextEmbedding` or the manager initializer stops being public, or if the initializer stops
/// accepting a caller-defined conformance, this file does not compile.
struct CallerEmbedderPublicAPITests {
    /// The length of each vector that `CallerDefinedEmbedder` returns.
    private static let embeddingDimension = 8

    /// A `TextEmbedding` that the caller defines, with no model and no network.
    ///
    /// The first entry of each vector is the character count of its text, and the other entries
    /// are zero. The vectors are not useful for search. This test examines only that the manager
    /// accepts the type.
    private struct CallerDefinedEmbedder: TextEmbedding {
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

    /// Opens a `CodeContextManager` with a caller-defined embedder, opens a temporary root with it,
    /// and then shuts the manager down.
    ///
    /// The workspace has no project-marker file, so no language server starts. Auto-install is off,
    /// so the test runs no installer.
    @Test
    func publicManagerInitAcceptsCallerDefinedEmbedder() async throws {
        try await withTemporaryWorkspace { root in
            let embedder = CallerDefinedEmbedder(dimension: Self.embeddingDimension)
            let manager = await CodeContextManager(embedder: embedder, autoInstall: LspAutoInstall(isEnabled: false))

            let context = try await manager.context(for: root)

            #expect(context.rootDirectory == root.standardizedFileURL)

            await manager.shutdown()
        }
    }
}

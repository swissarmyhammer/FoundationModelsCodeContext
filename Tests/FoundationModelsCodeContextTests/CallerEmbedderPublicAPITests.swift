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

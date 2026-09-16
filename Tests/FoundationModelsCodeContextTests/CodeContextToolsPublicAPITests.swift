import Foundation
import FoundationModels
import FoundationModelsCodeContext
import Testing

/// Proves that a caller outside this module can make the tools of a
/// `CodeContext` with only the public API.
///
/// This file uses a plain `import FoundationModelsCodeContext`, not
/// `@testable import`, and it does not import `Operations`. Thus it sees only
/// the public API, as a host package sees it. If `CodeContextTools.make`,
/// `CodeContextTools.toolNames` or `CodeContextTools.operationNames` stops
/// being public, this file does not compile.
struct CodeContextToolsPublicAPITests {
    /// The length of each vector that the embedder returns.
    private static let embeddingDimension = 8

    /// The number of tools that `CodeContextTools.make` gives.
    private static let toolCount = 3

    /// Makes the three tools of a `CodeContext` that a caller opened with the
    /// public API, and reads the two public tables.
    ///
    /// The workspace has no project-marker file, so no language server starts.
    /// Auto-install is off, so the test runs no installer.
    @Test
    func publicFactoryGivesTheThreeToolsToACaller() async throws {
        try await withTemporaryWorkspace { root in
            let embedder = CallerDefinedEmbedder(dimension: Self.embeddingDimension)
            let manager = await CodeContextManager(embedder: embedder, autoInstall: LspAutoInstall(isEnabled: false))
            let context = try await manager.context(for: root)

            let tools = try CodeContextTools.make(context: context)

            #expect(tools.count == Self.toolCount)
            #expect(tools.map { $0.name } == CodeContextTools.toolNames)
            #expect(CodeContextTools.operationNames.count == Self.toolCount)
            for name in CodeContextTools.toolNames {
                #expect(CodeContextTools.operationNames[name]?.isEmpty == false, "tool: \(name)")
            }

            await manager.shutdown()
        }
    }
}

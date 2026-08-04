import Foundation
import FoundationModelsCodeContext
import Testing

/// Proves `CodeContext.rootDirectory` is genuinely `public nonisolated`, not merely visible to this
/// test target's other suites via `@testable import`.
///
/// Deliberately uses a plain `import FoundationModelsCodeContext`, for the same reason
/// `DiagnosticsReportPublicVisibilityTests` does: a `@testable import` would compile against an
/// `internal` property just as happily, so it could never catch a visibility regression. If
/// `rootDirectory` regressed to `private`/`internal`, or lost `nonisolated`, this file would fail to
/// *compile* rather than fail to run — which is the actual thing under test.
struct CodeContextRootDirectoryPublicVisibilityTests {
    /// Constructs a `CodeContext` through its public initializer and reads `rootDirectory` back
    /// synchronously, off the actor.
    ///
    /// Never calls `start()`: `init` alone opens the store and records `rootDirectory` verbatim, so
    /// no project detection runs and no LSP daemon is ever spawned — which is why, unlike
    /// `DiagnosticsReportPublicVisibilityTests`, this needs no project-marker-free fixture file.
    /// The `nonisolated` half of the contract is what the absent `await` asserts: a plain
    /// actor-isolated `public let` would force `await` here and fail to compile. The `public` half
    /// is asserted by the non-`@testable` import above.
    @Test
    func rootDirectoryIsPubliclyReadableWithoutAwait() async throws {
        try await withTemporaryWorkspace { root in
            let context = try await CodeContext(rootDirectory: root, embedder: FakeEmbedder(dimension: 8))

            // The actual assertion is as much that this *compiles* as that it matches: reading
            // `rootDirectory` with no `await`, from a file with no `@testable import`, is only
            // possible if it is both `public` and `nonisolated`.
            let observedRoot: URL = context.rootDirectory

            #expect(observedRoot == root)
        }
    }
}

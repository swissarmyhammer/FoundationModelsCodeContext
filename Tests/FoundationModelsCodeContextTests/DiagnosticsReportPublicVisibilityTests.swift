import Foundation
import FoundationModelsCodeContext
import Testing

/// Proves `DiagnosticsReport.records`/`.counts`/`.pending` (and `DiagnosticRecord`/`Counts` and
/// their own stored properties) are genuinely `public`, not merely visible to this test target's
/// other suites via `@testable import`.
///
/// Deliberately the one suite in this target with a plain `import FoundationModelsCodeContext` —
/// every other suite here uses `@testable import`, which would trivially compile against
/// `internal` members too and so could never catch a visibility regression. If any of the reads
/// below regressed to `internal`, this file would fail to *compile*, not merely to run — which is
/// the actual thing under test.
struct DiagnosticsReportPublicVisibilityTests {
    /// Writes a fixture file with no project-marker file (no `Package.swift`, `Cargo.toml`, etc.)
    /// alongside it, so `ProjectDetection.detectProjects` finds nothing and no LSP daemon is ever
    /// spawned. This is the only route to a `DiagnosticsReport` reachable from a plain,
    /// non-`@testable` import: `CodeContext`'s public initializer only ever constructs
    /// `CodeContext<ProcessLanguageServerConnection>` (see the README's usage example), and the
    /// fake-connection-driven seam other suites in this target use directly (`DiagnosticsOps`,
    /// `LspSession`) is `internal` on purpose — sibling packages are meant to reach a
    /// `DiagnosticsReport` only through the public `CodeContext.diagnostics(scope:...)` facade.
    /// With no detected project, `diagnostics(scope:)`'s live session resolves to `nil`, so this
    /// never touches a real (or fake) language server connection at all — it exercises the exact
    /// "no live layer" path `DiagnosticsTests.noSessionMeansNoLiveLayerAndNeverPending` covers
    /// from inside the module, reached here from outside it instead.
    @Test
    func diagnosticsReportRecordsCountsAndPendingArePubliclyReadable() async throws {
        try await withTemporaryWorkspace { root in
            try write("let x = 1\n", to: "a.swift", in: root)

            let context = try await CodeContext(rootDirectory: root, embedder: FakeEmbedder(dimension: 8))
            try await context.start()

            let report = try await context.diagnostics(scope: .file("a.swift"))

            // The actual assertion is that this *compiles*: reading `.records`, `.counts`, and
            // `.pending` (and, via `.map(\.message)`, `DiagnosticRecord`'s own public properties)
            // from a file with no `@testable import` is only possible if every one of them is
            // `public`.
            let messages: [String] = report.records.map(\.message)
            let errorCount: Int = report.counts.errors
            let pending: Bool = report.pending

            #expect(messages.isEmpty)
            #expect(errorCount == 0)
            #expect(pending == false)

            await context.stop()
        }
    }
}

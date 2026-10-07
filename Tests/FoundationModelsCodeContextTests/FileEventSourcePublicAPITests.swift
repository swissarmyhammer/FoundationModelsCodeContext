import Foundation
import FoundationModelsCodeContext
import Testing

/// Proves that a host outside this module can give its own `FileEventSource` to the public
/// `CodeContext` and `CodeContextManager` initializers, and that the watcher of each context
/// starts and stops that source.
///
/// This file uses a plain `import FoundationModelsCodeContext`, not `@testable import`. Thus it
/// sees only the public API, as a host package sees it. If the initializers stop accepting an
/// event source, this file does not compile.
///
/// The workspaces have no project-marker file, thus no language server starts. Auto-install is
/// off, thus the tests run no installer.
struct FileEventSourcePublicAPITests {
    @Test
    func publicContextInitGivesTheEventSourceToTheWatcher() async throws {
        try await withTemporaryWorkspace { root in
            let source = RecordingFileEventSource()
            let context = try await CodeContext(
                rootDirectory: root,
                embedder: nil,
                autoInstall: LspAutoInstall(isEnabled: false),
                eventSource: source
            )

            try await context.start()
            let startCount = source.startRecords.count
            await context.stop()

            #expect(startCount == 1)
            #expect(source.stoppedSubscriptionCount == 1)
        }
    }

    @Test
    func publicManagerInitGivesTheEventSourceToEachContext() async throws {
        try await withTemporaryWorkspace { root in
            let source = RecordingFileEventSource()
            let manager = await CodeContextManager(
                embedder: nil,
                autoInstall: LspAutoInstall(isEnabled: false),
                eventSource: source
            )

            _ = try await manager.context(for: root)
            let startCount = source.startRecords.count
            await manager.shutdown()

            #expect(startCount == 1)
            #expect(source.stoppedSubscriptionCount == 1)
        }
    }
}

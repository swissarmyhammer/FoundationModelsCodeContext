import Foundation
import Testing

@testable import FoundationModelsCodeContext

/// Tests for `CodeContextManager`: the open-or-get lifecycle, the overlap rule (descendant
/// routing / ancestor rejection), lazy git-root routing via `context(containing:)`, failed-start
/// non-registration, and `close`/`shutdown` bookkeeping.
///
/// Driven entirely against `FakeLanguageServerConnection` and `FakeEmbedder` via the internal
/// general initializer (never the `public` `where Connection == ProcessLanguageServerConnection`
/// convenience initializer) — mirroring `CodeContextE2ETests`'s own setup. Fixtures deliberately
/// omit project-marker files so no real LSP daemon ever spawns.
struct CodeContextManagerTests {
    // MARK: - Fixtures

    /// Builds a `CodeContextManager<FakeLanguageServerConnection>` wired to a fake filesystem-event
    /// source and a fake LSP connection factory (never actually invoked in these tests, since no
    /// fixture here has a detected project/server spec).
    private static func makeManager() async -> CodeContextManager<FakeLanguageServerConnection> {
        await CodeContextManager<FakeLanguageServerConnection>(
            embedder: FakeEmbedder(dimension: 8),
            eventSource: FakeFileEventSource(),
            connectionFactory: fakeConnectionFactory(pid: 1, processState: ProcessState())
        )
    }

    /// Writes a minimal, deterministic Swift fixture file into `root`, with no project marker.
    private static func writeFixture(in root: URL, fileName: String = "Fixture.swift") throws {
        try write("func fixtureSymbol() -> Int { 1 }\n", to: fileName, in: root)
    }

    /// Creates `url` as a directory containing a `.git` directory, mirroring a normal
    /// (non-worktree) git repository root — mirrors `RootDiscoveryTests`'s own helper.
    private static func makeGitDirRepo(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent(".git"), withIntermediateDirectories: true)
    }

    /// Calls `manager.context(for: root)` and captures its outcome as a `Result` rather than
    /// throwing, so a caller can run two of these concurrently via `async let` and inspect both
    /// outcomes afterward without either one's thrown error unwinding past the other.
    private static func attemptOpen(
        manager: CodeContextManager<FakeLanguageServerConnection>, root: URL
    ) async -> Result<CodeContext<FakeLanguageServerConnection>, Error> {
        do {
            return .success(try await manager.context(for: root))
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Same-root identity

    @Test
    func contextForSameRootTwiceReturnsIdenticalInstanceAndStartsOnce() async throws {
        try await withTemporaryWorkspace { root in
            try Self.writeFixture(in: root)
            let manager = await Self.makeManager()

            let first = try await manager.context(for: root)
            let second = try await manager.context(for: root)

            #expect(first === second)
            let status = await first.indexStatus()
            #expect(status.filesWalked > 0)

            await manager.shutdown()
        }
    }

    // MARK: - Concurrent dedupe

    @Test
    func concurrentContextForSameRootCreatesExactlyOneContext() async throws {
        try await withTemporaryWorkspace { root in
            try Self.writeFixture(in: root)
            let manager = await Self.makeManager()

            async let first = manager.context(for: root)
            async let second = manager.context(for: root)
            let (contextA, contextB) = try await (first, second)

            #expect(contextA === contextB)
            #expect(await manager.state.roots == [root.standardizedFileURL])

            await manager.shutdown()
        }
    }

    /// Concurrently opens two brand-new roots — one nested inside the other, neither previously
    /// registered — and proves the manager never ends up with two live, started contexts for
    /// overlapping roots, regardless of which of the two calls happens to reach the actor's
    /// synchronous overlap check first.
    ///
    /// Without also consulting `inFlightOpens` (not just `contexts`) in the overlap rule, both
    /// calls could pass the check simultaneously (neither root is registered yet) and each build
    /// its own `CodeContext` — the exact cross-root race the overlap rule exists to prevent.
    /// Whichever call wins the race, this asserts one of two valid outcomes: both calls resolve
    /// to the *same* context (the child deduped onto its still-opening parent), or the ancestor
    /// open is rejected with `.overlappingRoot` naming the child that claimed the subtree first.
    /// Both calls failing, or both succeeding with two *different* contexts, are bugs.
    @Test
    func concurrentOpensOfNestedBrandNewRootsNeverProduceTwoLiveOverlappingContexts() async throws {
        try await withTemporaryWorkspace { root in
            let parent = root
            let child = root.appendingPathComponent("child")
            try Self.writeFixture(in: parent, fileName: "Parent.swift")
            try Self.writeFixture(in: child, fileName: "Child.swift")
            let manager = await Self.makeManager()

            async let parentOutcome = Self.attemptOpen(manager: manager, root: parent)
            async let childOutcome = Self.attemptOpen(manager: manager, root: child)
            let (firstOutcome, secondOutcome) = await (parentOutcome, childOutcome)

            switch (firstOutcome, secondOutcome) {
            case let (.success(parentContext), .success(childContext)):
                // The only valid double-success is both calls resolving to the identical
                // (parent) context — never two distinct, independently-started contexts.
                #expect(parentContext === childContext)
            case (.success, .failure(let error)), (.failure(let error), .success):
                #expect(error is CodeContextError)
            case (.failure, .failure):
                Issue.record("both concurrent opens failed: \(firstOutcome) / \(secondOutcome)")
            }

            await manager.shutdown()
        }
    }

    // MARK: - Overlap rule

    @Test
    func openingDescendantOfOpenRootReturnsAncestorContext() async throws {
        try await withTemporaryWorkspace { root in
            let repoRoot = root.appendingPathComponent("repo")
            try Self.writeFixture(in: repoRoot)
            try write("// nested", to: "repo/sub/dir/Nested.swift", in: root)
            let manager = await Self.makeManager()

            let ancestorContext = try await manager.context(for: repoRoot)
            let descendantContext = try await manager.context(for: repoRoot.appendingPathComponent("sub/dir"))

            #expect(ancestorContext === descendantContext)
            #expect(await manager.state.roots == [repoRoot.standardizedFileURL])

            await manager.shutdown()
        }
    }

    @Test
    func openingAncestorOfOpenRootsThrowsOverlappingRootNamingConflictingChild() async throws {
        try await withTemporaryWorkspace { root in
            let repoRoot = root.appendingPathComponent("repo")
            try Self.writeFixture(in: repoRoot)
            let manager = await Self.makeManager()

            _ = try await manager.context(for: repoRoot)

            do {
                _ = try await manager.context(for: root)
                Issue.record("expected CodeContextError.overlappingRoot to be thrown")
            } catch CodeContextError.overlappingRoot(let conflictingChildren) {
                #expect(conflictingChildren.contains(repoRoot.standardizedFileURL.path))
            } catch {
                Issue.record("expected CodeContextError.overlappingRoot, got \(error)")
            }

            // The rejected ancestor open must not have registered anything for `root` itself.
            #expect(await manager.state.roots == [repoRoot.standardizedFileURL])

            await manager.shutdown()
        }
    }

    @Test
    func pathPrefixCheckDoesNotConfuseSiblingDirsSharingNamePrefix() async throws {
        try await withTemporaryWorkspace { root in
            let fooRoot = root.appendingPathComponent("foo")
            let fooBarRoot = root.appendingPathComponent("foo-bar")
            try Self.writeFixture(in: fooRoot)
            try Self.writeFixture(in: fooBarRoot)
            let manager = await Self.makeManager()

            let fooContext = try await manager.context(for: fooRoot)
            let fooBarContext = try await manager.context(for: fooBarRoot)

            #expect(fooContext !== fooBarContext)
            #expect(
                Set(await manager.state.roots) == [fooRoot.standardizedFileURL, fooBarRoot.standardizedFileURL]
            )

            await manager.shutdown()
        }
    }

    // MARK: - `context(containing:)`

    @Test
    func contextContainingResolvesViaAlreadyOpenRootFirst() async throws {
        try await withTemporaryWorkspace { root in
            let repoRoot = root.appendingPathComponent("repo")
            try Self.writeFixture(in: repoRoot)
            let manager = await Self.makeManager()
            let opened = try await manager.context(for: repoRoot)

            let resolved = try await manager.context(containing: repoRoot.appendingPathComponent("Fixture.swift"))

            #expect(resolved === opened)

            await manager.shutdown()
        }
    }

    @Test
    func contextContainingLazilyOpensGitRootWhenOpenIfNeeded() async throws {
        try await withTemporaryWorkspace { root in
            let repoRoot = root.appendingPathComponent("repo")
            try Self.makeGitDirRepo(at: repoRoot)
            try Self.writeFixture(in: repoRoot)
            let manager = await Self.makeManager()

            let resolved = try await manager.context(containing: repoRoot.appendingPathComponent("Fixture.swift"))

            #expect(resolved != nil)
            #expect(await manager.state.roots == [repoRoot.standardizedFileURL])

            await manager.shutdown()
        }
    }

    @Test
    func contextContainingReturnsNilWithoutOpeningWhenOpenIfNeededFalse() async throws {
        try await withTemporaryWorkspace { root in
            let repoRoot = root.appendingPathComponent("repo")
            try Self.makeGitDirRepo(at: repoRoot)
            try Self.writeFixture(in: repoRoot)
            let manager = await Self.makeManager()

            let resolved = try await manager.context(
                containing: repoRoot.appendingPathComponent("Fixture.swift"), openIfNeeded: false
            )

            #expect(resolved == nil)
            #expect(await manager.state.roots.isEmpty)
        }
    }

    @Test
    func contextContainingReturnsNilOutsideAnyRepo() async throws {
        try await withTemporaryWorkspace { root in
            try write("hello", to: "plain/file.txt", in: root)
            let manager = await Self.makeManager()

            let resolved = try await manager.context(containing: root.appendingPathComponent("plain/file.txt"))

            #expect(resolved == nil)
            #expect(await manager.state.roots.isEmpty)
        }
    }

    // MARK: - Failed `start()`

    @Test
    func failedStartLeavesManagerUnregisteredAndPropagatesError() async throws {
        try await withTemporaryWorkspace { root in
            try Self.writeFixture(in: root)
            try write("func blocked() {}", to: "Blocked/Blocked.swift", in: root)
            let manager = await Self.makeManager()

            // Block read access to a subdirectory so `Reconciler.reconcile`'s directory walk
            // (`start()`'s first throwing step) fails, mirroring `CodeContextE2ETests`'s own
            // `startResetsIsStartedOnFailureSoARetryActuallyStarts` setup.
            let blockedDirectory = root.appendingPathComponent("Blocked")
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blockedDirectory.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blockedDirectory.path) }

            await #expect(throws: (any Error).self) {
                try await manager.context(for: root)
            }

            #expect(await manager.state.roots.isEmpty)

            // Restore access and retry: a buggy manager that left `root` registered (or stuck in
            // `inFlightOpens`) after the failure above would either silently no-op this second
            // call or hang it, instead of genuinely retrying.
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blockedDirectory.path)

            let context = try await manager.context(for: root)
            let status = await context.indexStatus()
            #expect(status.filesWalked > 0)
            #expect(await manager.state.roots == [root.standardizedFileURL])

            await manager.shutdown()
        }
    }

    // MARK: - `close` / `shutdown`

    @Test
    func closeStopsContextAndUpdatesState() async throws {
        try await withTemporaryWorkspace { root in
            try Self.writeFixture(in: root)
            let manager = await Self.makeManager()
            _ = try await manager.context(for: root)
            #expect(await manager.state.roots == [root.standardizedFileURL])

            await manager.close(root: root)

            #expect(await manager.state.roots.isEmpty)

            // Re-opening after close must genuinely create a fresh, started context.
            let reopened = try await manager.context(for: root)
            let status = await reopened.indexStatus()
            #expect(status.filesWalked > 0)

            await manager.shutdown()
        }
    }

    @Test
    func closeIsNoOpForUnknownRoot() async throws {
        try await withTemporaryWorkspace { root in
            let manager = await Self.makeManager()

            await manager.close(root: root)

            #expect(await manager.state.roots.isEmpty)
        }
    }

    @Test
    func shutdownClosesEveryOpenRoot() async throws {
        try await withTemporaryWorkspace { rootA in
            try await withTemporaryWorkspace { rootB in
                try Self.writeFixture(in: rootA)
                try Self.writeFixture(in: rootB)
                let manager = await Self.makeManager()

                _ = try await manager.context(for: rootA)
                _ = try await manager.context(for: rootB)
                #expect(await manager.state.roots.count == 2)

                await manager.shutdown()

                #expect(await manager.state.roots.isEmpty)
            }
        }
    }
}

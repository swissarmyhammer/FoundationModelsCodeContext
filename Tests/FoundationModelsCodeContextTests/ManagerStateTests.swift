import Foundation
import Observation
import Testing

@testable import FoundationModelsCodeContext

/// Tests for `ManagerState`, the `@MainActor @Observable` aggregate that tracks one
/// `CodeContextState` per open root. Every publisher is exercised directly against real
/// `CodeContextState` instances (no real `CodeContext`, workers, or LSP daemons involved) — these
/// tests only prove the aggregate's own publish/observe/derive contract, reusing the
/// `IndexProgress`/`ServerStatus` fixtures and patterns from `CodeContextStateTests`.
struct ManagerStateTests {
    /// Workspace root fixtures; no test in this suite touches the filesystem.
    private static let firstRoot = URL(fileURLWithPath: "/tmp/manager-state-tests/b-root")
    private static let secondRoot = URL(fileURLWithPath: "/tmp/manager-state-tests/a-root")

    /// A fully drained indexing snapshot — every layer caught up to `filesWalked`.
    private static let drainedIndexing = IndexProgress(
        filesWalked: 10, filesParsed: 10, filesEmbedded: 10, filesLspIndexed: 10
    )

    /// An indexing snapshot with tree-sitter parsing still behind the walked count.
    private static let undrainedIndexing = IndexProgress(
        filesWalked: 10, filesParsed: 5, filesEmbedded: 10, filesLspIndexed: 10
    )

    // MARK: - Open/close bookkeeping

    @Test
    func publishOpenedAddsEntry() async {
        let manager = await ManagerState()
        let state = await CodeContextState(rootDirectory: Self.firstRoot)

        await manager.publishOpened(root: Self.firstRoot, state: state)

        let contexts = await manager.contexts
        #expect(contexts[Self.firstRoot.standardizedFileURL] === state)
    }

    @Test
    func publishClosedRemovesEntry() async {
        let manager = await ManagerState()
        let state = await CodeContextState(rootDirectory: Self.firstRoot)
        await manager.publishOpened(root: Self.firstRoot, state: state)

        await manager.publishClosed(root: Self.firstRoot)

        let contexts = await manager.contexts
        #expect(contexts.isEmpty)
    }

    @Test
    func publishOpenedKeysByStandardizedRootURL() async {
        let manager = await ManagerState()
        let state = await CodeContextState(rootDirectory: Self.firstRoot)
        let unstandardized = Self.firstRoot.appendingPathComponent("..")
            .appendingPathComponent(Self.firstRoot.lastPathComponent)

        await manager.publishOpened(root: unstandardized, state: state)

        let contexts = await manager.contexts
        #expect(contexts[Self.firstRoot.standardizedFileURL] === state)
    }

    // MARK: - `roots` stays sorted

    @Test
    func rootsIsEmptyInitially() async {
        let manager = await ManagerState()

        let roots = await manager.roots
        #expect(roots.isEmpty)
    }

    @Test
    func rootsStaysSortedByPath() async {
        let manager = await ManagerState()
        let firstState = await CodeContextState(rootDirectory: Self.firstRoot)
        let secondState = await CodeContextState(rootDirectory: Self.secondRoot)

        await manager.publishOpened(root: Self.firstRoot, state: firstState)
        await manager.publishOpened(root: Self.secondRoot, state: secondState)

        let roots = await manager.roots
        #expect(roots == [Self.secondRoot.standardizedFileURL, Self.firstRoot.standardizedFileURL])
    }

    @Test
    func rootsDropsClosedRoot() async {
        let manager = await ManagerState()
        let firstState = await CodeContextState(rootDirectory: Self.firstRoot)
        let secondState = await CodeContextState(rootDirectory: Self.secondRoot)
        await manager.publishOpened(root: Self.firstRoot, state: firstState)
        await manager.publishOpened(root: Self.secondRoot, state: secondState)

        await manager.publishClosed(root: Self.secondRoot)

        let roots = await manager.roots
        #expect(roots == [Self.firstRoot.standardizedFileURL])
    }

    // MARK: - SwiftUI observation

    @Test
    @MainActor
    func observationFiresWhenContextsPublish() async {
        let manager = ManagerState()
        let state = CodeContextState(rootDirectory: Self.firstRoot)
        let observedChange = ObservationFlag()
        withObservationTracking {
            _ = manager.contexts
        } onChange: {
            observedChange.set()
        }

        await manager.publishOpened(root: Self.firstRoot, state: state)

        #expect(observedChange.value)
    }

    // MARK: - `isReady` aggregation

    @Test
    func isReadyTrueWhenEmpty() async {
        let manager = await ManagerState()

        let isReady = await manager.isReady
        #expect(isReady)
    }

    @Test
    func isReadyFalseWhileOneChildUnsettled() async {
        let manager = await ManagerState()
        let readyState = await CodeContextState(rootDirectory: Self.firstRoot)
        await readyState.publishIndexing(Self.drainedIndexing)
        await readyState.publishServers([ServerStatus(command: "rust-analyzer", state: .running(pid: 1))])

        let unsettledState = await CodeContextState(rootDirectory: Self.secondRoot)
        await unsettledState.publishIndexing(Self.undrainedIndexing)

        await manager.publishOpened(root: Self.firstRoot, state: readyState)
        await manager.publishOpened(root: Self.secondRoot, state: unsettledState)

        let isReady = await manager.isReady
        #expect(!isReady)
    }

    @Test
    func isReadyTrueOnceEveryChildIsReady() async {
        let manager = await ManagerState()
        let firstState = await CodeContextState(rootDirectory: Self.firstRoot)
        await firstState.publishIndexing(Self.drainedIndexing)
        await firstState.publishServers([ServerStatus(command: "rust-analyzer", state: .running(pid: 1))])

        let secondState = await CodeContextState(rootDirectory: Self.secondRoot)
        await secondState.publishIndexing(Self.drainedIndexing)
        await secondState.publishServers([ServerStatus(command: "gopls", state: .notFound)])

        await manager.publishOpened(root: Self.firstRoot, state: firstState)
        await manager.publishOpened(root: Self.secondRoot, state: secondState)

        let isReady = await manager.isReady
        #expect(isReady)
    }

    @Test
    func isReadyTracksChildBecomingReadyAfterOpen() async {
        let manager = await ManagerState()
        let state = await CodeContextState(rootDirectory: Self.firstRoot)
        await state.publishIndexing(Self.undrainedIndexing)
        await manager.publishOpened(root: Self.firstRoot, state: state)

        var isReady = await manager.isReady
        #expect(!isReady)

        await state.publishIndexing(Self.drainedIndexing)

        isReady = await manager.isReady
        #expect(isReady)
    }

    @Test
    func isReadyTrueAfterLastUnsettledRootCloses() async {
        let manager = await ManagerState()
        let readyState = await CodeContextState(rootDirectory: Self.firstRoot)
        await readyState.publishIndexing(Self.drainedIndexing)

        let unsettledState = await CodeContextState(rootDirectory: Self.secondRoot)
        await unsettledState.publishIndexing(Self.undrainedIndexing)

        await manager.publishOpened(root: Self.firstRoot, state: readyState)
        await manager.publishOpened(root: Self.secondRoot, state: unsettledState)

        await manager.publishClosed(root: Self.secondRoot)

        let isReady = await manager.isReady
        #expect(isReady)
    }
}

/// A lock-guarded boolean flag `withObservationTracking`'s `onChange` closure can set.
///
/// `onChange` is a `@Sendable () -> Void` closure, so a plain captured `var` can't be mutated
/// from inside it under strict concurrency checking. `@unchecked Sendable` is safe here because
/// every access goes through `lock`, matching the pattern `CodeContextStateTests` already uses.
private final class ObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    /// Sets the flag to `true`.
    func set() {
        lock.lock()
        defer { lock.unlock() }
        flag = true
    }

    /// The flag's current value.
    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}

import Foundation
import Observation
import Testing

@testable import FoundationModelsCodeContext

/// Tests for `CodeContextState`, the `@MainActor @Observable` unified state object `CodeContext`
/// publishes into from its indexing workers, the LSP supervisor's health loop, and the session's
/// diagnostics stream. Every publisher is exercised directly (no real `CodeContext`, workers, or
/// LSP daemons involved) — these tests only prove the state object's own publish/observe/derive
/// contract.
struct CodeContextStateTests {
    /// A workspace root fixture; no test in this suite touches the filesystem.
    private static let workspaceRoot = URL(fileURLWithPath: "/tmp/code-context-state-tests")

    /// A fully drained indexing snapshot — every layer caught up to `filesWalked`.
    private static let drainedIndexing = IndexProgress(
        filesWalked: 10, filesParsed: 10, filesEmbedded: 10, filesLspIndexed: 10
    )

    /// An indexing snapshot with tree-sitter parsing still behind the walked count.
    private static let undrainedIndexing = IndexProgress(
        filesWalked: 10, filesParsed: 5, filesEmbedded: 10, filesLspIndexed: 10
    )

    // MARK: - Publisher -> main-actor mutation

    @Test
    func publishingServersMutatesOnMainActor() async {
        let state = await CodeContextState(rootDirectory: Self.workspaceRoot)
        let status = ServerStatus(command: "rust-analyzer", state: .running(pid: 123))

        await state.publishServers([status])

        let servers = await state.servers
        #expect(servers == [status])
    }

    @Test
    func publishingProjectsMutatesOnMainActor() async {
        let state = await CodeContextState(rootDirectory: Self.workspaceRoot)
        let project = DetectedProject(language: "swift", directory: Self.workspaceRoot)

        await state.publishProjects([project])

        let projects = await state.projects
        #expect(projects == [project])
    }

    @Test
    func publishingIndexingMutatesOnMainActor() async {
        let state = await CodeContextState(rootDirectory: Self.workspaceRoot)

        await state.publishIndexing(Self.drainedIndexing)

        let indexing = await state.indexing
        #expect(indexing == Self.drainedIndexing)
    }

    // MARK: - SwiftUI observation

    @Test
    @MainActor
    func observationFiresWhenServersPublish() async {
        let state = CodeContextState(rootDirectory: Self.workspaceRoot)
        let observedChange = ObservationFlag()
        withObservationTracking {
            _ = state.servers
        } onChange: {
            observedChange.set()
        }

        await state.publishServers([ServerStatus(command: "gopls", state: .starting)])

        #expect(observedChange.value)
    }

    @Test
    @MainActor
    func observationDoesNotFireForUntrackedProperty() async {
        let state = CodeContextState(rootDirectory: Self.workspaceRoot)
        let observedChange = ObservationFlag()
        withObservationTracking {
            _ = state.servers
        } onChange: {
            observedChange.set()
        }

        // Publishing diagnostics never touches `servers`, so the tracked-property observer
        // registered above must not fire.
        await state.publishDiagnostics(uri: DocumentURI("file:///a.swift"), diagnostics: [])

        #expect(!observedChange.value)
    }

    // MARK: - isReady truth table

    @Test
    func isReadyTrueImmediatelyAfterConstruction() async {
        // Both `IndexProgress.zero.isDrained` and `[].allSatisfy(isSettled)` are vacuously true —
        // a workspace with nothing detected yet has no outstanding work to wait for. See
        // `CodeContextState.isReady`'s documentation for why this is the deliberate initial value
        // rather than an accident of vacuous-truth composition.
        let state = await CodeContextState(rootDirectory: Self.workspaceRoot)

        let isReady = await state.isReady
        #expect(isReady)
    }

    @Test
    func isReadyFalseWhenIndexingUndrained() async {
        let state = await CodeContextState(rootDirectory: Self.workspaceRoot)

        await state.publishIndexing(Self.undrainedIndexing)
        await state.publishServers([ServerStatus(command: "rust-analyzer", state: .running(pid: 1))])

        let isReady = await state.isReady
        #expect(!isReady)
    }

    @Test
    func isReadyFalseWhenServerStillStarting() async {
        let state = await CodeContextState(rootDirectory: Self.workspaceRoot)

        await state.publishIndexing(Self.drainedIndexing)
        await state.publishServers([ServerStatus(command: "gopls", state: .starting)])

        let isReady = await state.isReady
        #expect(!isReady)
    }

    @Test
    func isReadyFalseWhenServerStillRetrying() async {
        let state = await CodeContextState(rootDirectory: Self.workspaceRoot)

        await state.publishIndexing(Self.drainedIndexing)
        await state.publishServers([ServerStatus(command: "gopls", state: .failed(reason: "crash", attempts: 2))])

        let isReady = await state.isReady
        #expect(!isReady)
    }

    @Test
    func isReadyTrueWhenServerPermanentlyFailed() async {
        let state = await CodeContextState(rootDirectory: Self.workspaceRoot)

        await state.publishIndexing(Self.drainedIndexing)
        await state.publishServers([ServerStatus(command: "gopls", state: .failed(reason: "crash", attempts: 5))])

        let isReady = await state.isReady
        #expect(isReady)
    }

    @Test
    func isReadyTrueWhenServerRunning() async {
        let state = await CodeContextState(rootDirectory: Self.workspaceRoot)

        await state.publishIndexing(Self.drainedIndexing)
        await state.publishServers([ServerStatus(command: "rust-analyzer", state: .running(pid: 1))])

        let isReady = await state.isReady
        #expect(isReady)
    }

    @Test
    func isReadyTrueWhenServerNotFound() async {
        let state = await CodeContextState(rootDirectory: Self.workspaceRoot)

        await state.publishIndexing(Self.drainedIndexing)
        await state.publishServers([ServerStatus(command: "missing-lsp", state: .notFound)])

        let isReady = await state.isReady
        #expect(isReady)
    }

    @Test
    func isReadyTrueWhenNoServersManaged() async {
        let state = await CodeContextState(rootDirectory: Self.workspaceRoot)

        await state.publishIndexing(Self.drainedIndexing)
        await state.publishServers([])

        let isReady = await state.isReady
        #expect(isReady)
    }

    @Test
    func isReadyFalseWhenOneOfSeveralServersUnsettled() async {
        let state = await CodeContextState(rootDirectory: Self.workspaceRoot)

        await state.publishIndexing(Self.drainedIndexing)
        await state.publishServers([
            ServerStatus(command: "rust-analyzer", state: .running(pid: 1)),
            ServerStatus(command: "gopls", state: .notStarted),
        ])

        let isReady = await state.isReady
        #expect(!isReady)
    }

    // MARK: - Diagnostics per-URI replacement

    @Test
    func publishingDiagnosticsReplacesRatherThanAppends() async {
        let state = await CodeContextState(rootDirectory: Self.workspaceRoot)
        let uri = DocumentURI("file:///repo/main.swift")
        let firstDiagnostic = Diagnostic(
            range: LSPRange(start: Position(line: 0, character: 0), end: Position(line: 0, character: 1)),
            severity: .error, code: nil, source: nil, message: "first"
        )
        let secondDiagnostic = Diagnostic(
            range: LSPRange(start: Position(line: 1, character: 0), end: Position(line: 1, character: 1)),
            severity: .warning, code: nil, source: nil, message: "second"
        )

        await state.publishDiagnostics(uri: uri, diagnostics: [firstDiagnostic])
        await state.publishDiagnostics(uri: uri, diagnostics: [secondDiagnostic])

        let diagnostics = await state.diagnostics
        #expect(diagnostics[uri] == [secondDiagnostic])
    }

    @Test
    func publishingDiagnosticsForOneURILeavesOthersUntouched() async {
        let state = await CodeContextState(rootDirectory: Self.workspaceRoot)
        let firstURI = DocumentURI("file:///repo/a.swift")
        let secondURI = DocumentURI("file:///repo/b.swift")
        let diagnostic = Diagnostic(
            range: LSPRange(start: Position(line: 0, character: 0), end: Position(line: 0, character: 1)),
            severity: .error, code: nil, source: nil, message: "boom"
        )

        await state.publishDiagnostics(uri: firstURI, diagnostics: [diagnostic])
        await state.publishDiagnostics(uri: secondURI, diagnostics: [])

        let diagnostics = await state.diagnostics
        #expect(diagnostics[firstURI] == [diagnostic])
        #expect(diagnostics[secondURI] == [])
    }
}

/// A lock-guarded boolean flag `withObservationTracking`'s `onChange` closure can set.
///
/// `onChange` is a `@Sendable () -> Void` closure, so a plain captured `var` can't be mutated
/// from inside it under strict concurrency checking. `@unchecked Sendable` is safe here because
/// every access goes through `lock`, matching the pattern this codebase already uses for
/// `StderrTailBuffer`/`PendingRequestTable` in `ProcessLanguageServerConnection.swift`.
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

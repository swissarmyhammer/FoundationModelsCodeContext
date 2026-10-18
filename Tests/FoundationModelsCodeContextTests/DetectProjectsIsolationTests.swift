import Foundation
import FoundationModelsExtras
import Testing

@testable import FoundationModelsCodeContext

/// Tests that `CodeContext.detectProjects()` never waits for index work.
///
/// The test holds the first index pass on the gate of a `GatedEmbedder`, and it
/// holds the executor of the `CodeContext` actor and the main actor on a
/// `ThreadGate`. Then it calls `detectProjects()`. The call must answer while
/// each of these stays held. The test opens the gates only after the answer, or
/// after `answerBudget` when no answer comes.
struct DetectProjectsIsolationTests {
    /// The dimension of the fake embedding vectors.
    private static let dimension = 8

    /// The time limit of the test, in minutes.
    private static let timeLimitMinutes = 1

    /// The most time that `detectProjects()` can use while the index pass and the
    /// executors are held. The detection of the small fixture takes some
    /// milliseconds, thus a call that answers in this time did not wait.
    private static let answerBudget: Duration = .seconds(5)

    /// The real time between two reads of the answer.
    private static let answerPollInterval: Duration = .milliseconds(10)

    /// The project marker of the fixture.
    private static let markerFileName = "Package.swift"

    /// The canonical name of the language that the marker identifies.
    private static let swiftLanguageName = "swift"

    @Test(.timeLimit(.minutes(timeLimitMinutes)))
    func detectProjectsAnswersWhileAnIndexPassAndTheActorsAreHeld() async throws {
        try await withTemporaryWorkspace { root in
            try write("// swift-tools-version: 6.2\n", to: Self.markerFileName, in: root)
            try write("func greet() -> String {\n    \"hello\"\n}\n", to: "Greeter.swift", in: root)
            let log = EmbedCallLog()
            await log.closeGate()
            let context = try await Self.makeCodeContext(rootDirectory: root, log: log)
            let projectsWhileHeld = try await withAsyncCleanup {
                try await context.start()
                await log.waitForFirstCall()
                return try await Self.detectProjectsWhileTheActorsAreHeld(context: context)
            } cleanup: {
                await log.openGate()
                await context.stop()
            }

            let projects = try #require(projectsWhileHeld, "detectProjects() did not answer while the index pass and the actors were held")
            #expect(projects.contains { $0.language == Self.swiftLanguageName })
        }
    }

    /// Holds the executor of the `CodeContext` actor and the main actor, calls
    /// `detectProjects()`, and waits at most `answerBudget` for the answer.
    ///
    /// On each path, also when the wait throws, the method opens the two gates
    /// and then awaits the two hold tasks and the detection task. Thus no held
    /// executor and no task stays after the method.
    ///
    /// - Parameter context: The started context.
    /// - Returns: The detected projects, or `nil` when no answer came in the
    ///   budget.
    /// - Throws: The error of `detectProjects()`, or `CancellationError` when the
    ///   task of the test is cancelled.
    private static func detectProjectsWhileTheActorsAreHeld(
        context: CodeContext<FakeLanguageServerConnection>
    ) async throws -> [DetectedProject]? {
        let actorGate = ThreadGate()
        let mainActorGate = ThreadGate()
        let actorHold = Task { await context.blockExecutor(until: actorGate) }
        let mainActorHold = Task { @MainActor in mainActorGate.holdMainActor() }
        let answer = DetectionAnswer()
        // The detection starts only after both executors are held.
        let detection = Task {
            await actorGate.waitUntilHeld()
            await mainActorGate.waitUntilHeld()
            let projects = try await context.detectProjects()
            await answer.record(projects)
        }
        let projectsWhileHeld = try await withAsyncCleanup {
            try await waitForAnswer(answer)
        } cleanup: {
            actorGate.open()
            mainActorGate.open()
            await actorHold.value
            await mainActorHold.value
            _ = await detection.result
        }
        try await detection.value
        return projectsWhileHeld
    }

    /// Reads `answer` again and again until it holds the projects, or until
    /// `answerBudget` elapses.
    ///
    /// - Parameter answer: The record that the detection task fills.
    /// - Returns: The detected projects, or `nil` when no answer came in the budget.
    /// - Throws: `CancellationError` when the task of the test is cancelled.
    private static func waitForAnswer(_ answer: DetectionAnswer) async throws -> [DetectedProject]? {
        try await waitUntil(timeout: answerBudget, pollInterval: answerPollInterval) {
            await answer.projects != nil
        }
        return await answer.projects
    }

    /// Makes a `CodeContext` for `rootDirectory` whose embedder stops at the gate
    /// of `log`, with a fake event source and a fake LSP connection factory.
    ///
    /// - Parameters:
    ///   - rootDirectory: The workspace root.
    ///   - log: The call log whose gate holds the embedding step.
    /// - Returns: The context, not started.
    /// - Throws: The errors of the `CodeContext` initializer.
    private static func makeCodeContext(
        rootDirectory: URL,
        log: EmbedCallLog
    ) async throws -> CodeContext<FakeLanguageServerConnection> {
        try await CodeContext<FakeLanguageServerConnection>(
            rootDirectory: rootDirectory,
            embedder: GatedEmbedder(vectorLength: dimension, log: log),
            eventSource: FakeFileEventSource(),
            autoInstall: LspAutoInstall(isEnabled: false),
            connectionFactory: fakeConnectionFactory(pid: 1, processState: ProcessState())
        )
    }
}

/// The answer of one `detectProjects()` call, which a detection task records.
private actor DetectionAnswer {
    /// The detected projects, or `nil` before the call answers.
    private(set) var projects: [DetectedProject]?

    /// Records the answer of the call.
    ///
    /// - Parameter projects: The detected projects.
    func record(_ projects: [DetectedProject]) {
        self.projects = projects
    }
}

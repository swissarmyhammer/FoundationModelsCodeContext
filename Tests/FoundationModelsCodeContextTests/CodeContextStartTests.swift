import Foundation
import FoundationModelsExtras
import Testing

@testable import FoundationModelsCodeContext

/// Tests for the bounded `start()` of `CodeContext`, for `stop()` during the
/// first index pass, for the rule that one index pass runs at a time, for the
/// embedding layer that a host turns off, for the watcher that a host turns
/// off, and for the calls that stop the language servers and start them again.
///
/// Most fixtures have no project marker, thus no LSP daemon starts. The tests
/// of `stopLanguageServers()` and `startLanguageServers()` write a Cargo
/// manifest, thus the context manages one server. These tests also write a
/// fake server binary, thus the server runs also on a machine that does not
/// have the real server. The auto install is off.
struct CodeContextStartTests {
    /// The pid that each fake server process reports.
    private static let fakeServerPid: Int32 = 1

    /// The command of the server that a Cargo manifest gets.
    private static let rustServerCommand = "rust-analyzer"

    /// The status of the Rust server while it runs on the fake connection.
    private static let runningRustServer = ServerStatus(command: rustServerCommand, state: .running(pid: fakeServerPid))

    /// The file permissions of the fake server binary: the owner can read, write and run it,
    /// and all other users can read and run it.
    private static let executablePermissions = 0o755

    /// The dimension of the fake embedding vectors.
    private static let dimension = 8

    /// The number of fixture files. Each file is one `embed(texts:)` call or more,
    /// thus a complete pass makes more than one call.
    private static let fixtureFileCount = 3

    /// The time limit of each test, in minutes. A `start()` or a `stop()` that
    /// waits for the closed gate fails at this limit.
    private static let timeLimitMinutes = 1

    /// The name of the file that a test makes while the first pass runs.
    private static let lateFileName = "GreeterLate.swift"

    /// The debounce interval of the watcher that `CodeContext` makes. It is the
    /// default of the `debounceInterval` parameter of `Watcher`.
    private static let watcherDebounceInterval: Duration = .seconds(1)

    /// The real time between two reads of the index status in
    /// `waitForIndexStatus(of:_:)`.
    private static let statusPollInterval: Duration = .milliseconds(1)

    /// Reads the index status of `context` again and again until `isExpected`
    /// returns `true`.
    ///
    /// The index passes run in tasks of `context`, thus a test cannot await
    /// them directly. The time limit of the test cancels a wait that cannot
    /// end, and the wait then throws.
    /// - Parameters:
    ///   - context: The context that gives the index status.
    ///   - isExpected: Returns `true` for the status that the test waits for.
    /// - Throws: `CancellationError` when the task of the test is cancelled.
    private static func waitForIndexStatus(
        of context: CodeContext<FakeLanguageServerConnection>,
        _ isExpected: (IndexProgress) -> Bool
    ) async throws {
        while !isExpected(await context.indexStatus()) {
            try await Task.sleep(for: statusPollInterval)
        }
    }

    /// Makes a `CodeContext` for `rootDirectory` with a fake event source and
    /// a fake LSP connection factory.
    ///
    /// A test that sends file events gives its own `clock` and `eventSource`,
    /// and then controls the debounce timer of the watcher. A test that starts
    /// a language server again gives its own `processState` and `serverSpecs`.
    /// - Parameters:
    ///   - rootDirectory: The workspace root of the context.
    ///   - embedder: The embedder of the context, or `nil` to turn the embedding layer off.
    ///   - clock: The clock of the index loop and of the watcher.
    ///   - eventSource: The file event source of the watcher.
    ///   - processState: The liveness of each fake server process.
    ///   - serverSpecs: Gives the server specs of the detected projects.
    private static func makeCodeContext(
        rootDirectory: URL,
        embedder: PooledEmbedding?,
        clock: any Clock<Duration> = ContinuousClock(),
        eventSource: FakeFileEventSource = FakeFileEventSource(),
        processState: ProcessState = ProcessState(),
        serverSpecs: @escaping ServerSpecsForProjects = ProjectDetection.serverSpecs(for:)
    ) async throws -> CodeContext<FakeLanguageServerConnection> {
        try await CodeContext<FakeLanguageServerConnection>(
            rootDirectory: rootDirectory,
            embedder: embedder,
            clock: clock,
            eventSource: eventSource,
            autoInstall: LspAutoInstall(isEnabled: false),
            serverSpecs: serverSpecs,
            connectionFactory: fakeConnectionFactory(pid: Self.fakeServerPid, processState: processState)
        )
    }

    /// Writes `fixtureFileCount` Swift files into `root`. File `N` holds the
    /// function `greetN()`.
    private static func writeFixture(in root: URL) throws {
        for index in 0..<fixtureFileCount {
            try write("func greet\(index)() -> String {\n    \"hello\"\n}\n", to: "Greeter\(index).swift", in: root)
        }
    }

    /// Returns `true` when `error` is `CodeContextError.embeddingDisabled`.
    private static func isEmbeddingDisabled(_ error: CodeContextError?) -> Bool {
        if case .embeddingDisabled = error {
            return true
        }
        return false
    }

    @Test(.timeLimit(.minutes(CodeContextStartTests.timeLimitMinutes)))
    func startReturnsBeforeTheEmbeddingStepIsComplete() async throws {
        try await withTemporaryWorkspace { root in
            try Self.writeFixture(in: root)
            let log = EmbedCallLog()
            await log.closeGate()
            let context = try await Self.makeCodeContext(
                rootDirectory: root,
                embedder: GatedEmbedder(vectorLength: Self.dimension, log: log)
            )

            try await context.start()

            #expect(!(await context.state.isReady))
            await log.waitForFirstCall()
            let matches = try await context.searchSymbol(query: "greet0")
            #expect(matches.contains { $0.name == "greet0" })
            #expect(!(await context.indexStatus().isDrained))

            await log.openGate()
            await context.waitForFirstIndexPass()

            let status = await context.indexStatus()
            #expect(status.filesWalked == Self.fixtureFileCount)
            #expect(status.isDrained)
            #expect(await context.state.isReady)
            await context.stop()
        }
    }

    @Test(.timeLimit(.minutes(CodeContextStartTests.timeLimitMinutes)))
    func stopDuringTheFirstPassCancelsThePass() async throws {
        try await withTemporaryWorkspace { root in
            try Self.writeFixture(in: root)
            let log = EmbedCallLog()
            await log.closeGate()
            let context = try await Self.makeCodeContext(
                rootDirectory: root,
                embedder: GatedEmbedder(vectorLength: Self.dimension, log: log)
            )
            try await context.start()
            await log.waitForFirstCall()

            await context.stop()

            #expect(await log.batchSizes.count == 1)
            let status = await context.indexStatus()
            #expect(status.filesEmbedded == 0)
        }
    }

    @Test(.timeLimit(.minutes(CodeContextStartTests.timeLimitMinutes)))
    func waitForFirstIndexPassReturnsWhenStopCancelsThePass() async throws {
        try await withTemporaryWorkspace { root in
            try Self.writeFixture(in: root)
            let log = EmbedCallLog()
            await log.closeGate()
            let context = try await Self.makeCodeContext(
                rootDirectory: root,
                embedder: GatedEmbedder(vectorLength: Self.dimension, log: log)
            )
            try await context.start()
            await log.waitForFirstCall()

            async let waited: Void = context.waitForFirstIndexPass()
            await context.stop()
            await waited

            #expect(!(await context.indexStatus().isDrained))
        }
    }

    @Test(.timeLimit(.minutes(CodeContextStartTests.timeLimitMinutes)))
    func aNudgeDuringAPassDoesNotEmbedAChunkTwice() async throws {
        try await withTemporaryWorkspace { root in
            try Self.writeFixture(in: root)
            let log = EmbedCallLog()
            await log.closeGate()
            let clock = ManualClock()
            let eventSource = FakeFileEventSource()
            let context = try await Self.makeCodeContext(
                rootDirectory: root,
                embedder: GatedEmbedder(vectorLength: Self.dimension, log: log),
                clock: clock,
                eventSource: eventSource
            )
            try await context.start()
            await log.waitForFirstCall()

            try write("func greetLate() -> String {\n    \"hello\"\n}\n", to: Self.lateFileName, in: root)
            await eventSource.emit(RawFileEvent(url: root.appendingPathComponent(Self.lateFileName), kind: .created))
            await clock.waitForWaiter(withDeadline: clock.now.advanced(by: Self.watcherDebounceInterval))
            clock.advance(by: Self.watcherDebounceInterval)
            try await Self.waitForIndexStatus(of: context) { $0.filesWalked == Self.fixtureFileCount + 1 }

            await log.openGate()
            try await Self.waitForIndexStatus(of: context) { $0.isDrained }

            let embeddedChunkCount = await log.batchSizes.reduce(0, +)
            #expect(embeddedChunkCount == Self.fixtureFileCount + 1)
            await context.stop()
        }
    }

    @Test(.timeLimit(.minutes(CodeContextStartTests.timeLimitMinutes)))
    func rebuildIndexDuringAPassReturnsAfterAPassThatStartedAfterTheRebuild() async throws {
        try await withTemporaryWorkspace { root in
            try Self.writeFixture(in: root)
            let log = EmbedCallLog()
            await log.closeGate()
            let context = try await Self.makeCodeContext(
                rootDirectory: root,
                embedder: GatedEmbedder(vectorLength: Self.dimension, log: log),
                clock: ManualClock()
            )
            try await context.start()
            await log.waitForFirstCall()

            async let rebuild = context.rebuildIndex(layer: .treeSitter)
            try await Self.waitForIndexStatus(of: context) { $0.filesParsed == 0 }
            await log.openGate()
            let result = try await rebuild

            #expect(result.filesMarked == Self.fixtureFileCount)
            #expect(await context.indexStatus().isDrained)
            await context.stop()
        }
    }

    @Test(.timeLimit(.minutes(CodeContextStartTests.timeLimitMinutes)))
    func aCancelledRebuildIndexStopsItsWaitAndThePassContinues() async throws {
        try await withTemporaryWorkspace { root in
            try Self.writeFixture(in: root)
            let log = EmbedCallLog()
            await log.closeGate()
            let context = try await Self.makeCodeContext(
                rootDirectory: root,
                embedder: GatedEmbedder(vectorLength: Self.dimension, log: log),
                clock: ManualClock()
            )
            try await context.start()
            await log.waitForFirstCall()

            let rebuild = Task { try await context.rebuildIndex(layer: .treeSitter) }
            try await Self.waitForIndexStatus(of: context) { $0.filesParsed == 0 }
            rebuild.cancel()

            await #expect(throws: CancellationError.self) {
                try await rebuild.value
            }
            #expect(await log.batchSizes.count == 1)

            await log.openGate()
            try await Self.waitForIndexStatus(of: context) { $0.isDrained }
            await context.stop()
        }
    }

    @Test(.timeLimit(.minutes(CodeContextStartTests.timeLimitMinutes)))
    func aNilEmbedderTurnsTheEmbeddingLayerOff() async throws {
        try await withTemporaryWorkspace { root in
            try Self.writeFixture(in: root)
            let context = try await Self.makeCodeContext(rootDirectory: root, embedder: nil)
            try await context.start()
            await context.waitForFirstIndexPass()

            let status = await context.indexStatus()
            #expect(!status.isEmbeddingEnabled)
            #expect(status.filesEmbedded == 0)
            #expect(status.isDrained)
            #expect(await context.state.isReady)
            let matches = try await context.searchSymbol(query: "greet0")
            #expect(matches.contains { $0.name == "greet0" })

            let searchError = await #expect(throws: CodeContextError.self) {
                try await context.searchCode(query: "hello")
            }
            #expect(Self.isEmbeddingDisabled(searchError))
            let duplicatesError = await #expect(throws: CodeContextError.self) {
                try await context.findDuplicates()
            }
            #expect(Self.isEmbeddingDisabled(duplicatesError))
            await context.stop()
        }
    }

    @Test(.timeLimit(.minutes(CodeContextStartTests.timeLimitMinutes)))
    func anEmbedderTurnsTheEmbeddingLayerOn() async throws {
        try await withTemporaryWorkspace { root in
            try Self.writeFixture(in: root)
            let context = try await Self.makeCodeContext(rootDirectory: root, embedder: FakeEmbedder(vectorLength: Self.dimension))
            try await context.start()
            await context.waitForFirstIndexPass()

            let status = await context.indexStatus()
            #expect(status.isEmbeddingEnabled)
            #expect(status.filesEmbedded == Self.fixtureFileCount)
            let result = try await context.searchCode(query: "hello")
            #expect(!result.hits.isEmpty)
            await context.stop()
        }
    }

    /// The first pass of a context learns the vector length from one probe
    /// vector. A second pass uses the length that the context keeps, thus it
    /// embeds no probe again, and it embeds only the chunks.
    @Test(.timeLimit(.minutes(CodeContextStartTests.timeLimitMinutes)))
    func theProbeIsEmbeddedOneTimeOnlyForTheLifeOfAContext() async throws {
        try await withTemporaryWorkspace { root in
            try Self.writeFixture(in: root)
            let log = EmbedCallLog()
            let context = try await Self.makeCodeContext(
                rootDirectory: root,
                embedder: GatedEmbedder(vectorLength: Self.dimension, log: log),
                clock: ManualClock()
            )
            try await context.start()
            await context.waitForFirstIndexPass()

            _ = try await context.rebuildIndex(layer: .treeSitter)

            let passCount = 2
            #expect(await log.probeCallCount == 1)
            #expect(await log.batchSizes.reduce(0, +) == Self.fixtureFileCount * passCount)
            await context.stop()
        }
    }

    /// A host that gives no event source turns the watcher off. Then `start()`
    /// makes no watcher, thus no FSEvents stream starts.
    @Test(.timeLimit(.minutes(CodeContextStartTests.timeLimitMinutes)))
    func noEventSourceTurnsTheWatcherOff() async throws {
        try await withTemporaryWorkspace { root in
            let context = try await CodeContext(
                rootDirectory: root,
                embedder: nil,
                autoInstall: LspAutoInstall(isEnabled: false),
                eventSource: nil
            )
            try await context.start()
            let isWatching = await context.isWatching
            await context.stop()

            #expect(!isWatching)
        }
    }

    /// A host that gives an event source gets a watcher on that source.
    @Test(.timeLimit(.minutes(CodeContextStartTests.timeLimitMinutes)))
    func anEventSourceTurnsTheWatcherOn() async throws {
        try await withTemporaryWorkspace { root in
            let context = try await Self.makeCodeContext(rootDirectory: root, embedder: nil)
            try await context.start()
            let isWatching = await context.isWatching
            await context.stop()

            #expect(isWatching)
        }
    }

    // MARK: - stopLanguageServers() / startLanguageServers()

    /// Writes a Cargo manifest into `root`. The manifest is a project marker, thus `start()`
    /// manages one server for it.
    /// - Parameter root: The workspace root to write the manifest into.
    private static func writeRustProjectMarker(in root: URL) throws {
        try write("[package]\nname = \"fixture\"", to: "Cargo.toml", in: root)
    }

    /// Writes an executable file with the name of the Rust server into `directory`.
    ///
    /// `LSPDaemon.start()` looks for the binary of the server before it calls the connection
    /// factory. This file makes that lookup succeed on each machine, also when the real server
    /// is not installed. The fake connection factory does not run the file.
    /// - Parameter directory: The directory to write the file into.
    private static func writeFakeRustServerBinary(in directory: URL) throws {
        try write("#!/bin/sh\n", to: rustServerCommand, in: directory)
        try FileManager.default.setAttributes(
            [.posixPermissions: executablePermissions],
            ofItemAtPath: directory.appendingPathComponent(rustServerCommand).path
        )
    }

    /// Gives the server specs that project detection gives, but each installer of a spec has
    /// `directory` as its only extra search directory.
    ///
    /// The real project detection and the real Rust spec stay in use. Only the place where the
    /// binary lookup finds the binary changes. The auto install is off, thus no installer runs.
    /// - Parameter directory: The directory that holds the fake binary of each server.
    /// - Returns: The spec mapping that the context gives to its supervisor.
    private static func serverSpecs(searching directory: URL) -> ServerSpecsForProjects {
        { projects in
            ProjectDetection.serverSpecs(for: projects).map { spec in
                ServerSpec(
                    command: spec.command,
                    arguments: spec.arguments,
                    languageIDs: spec.languageIDs,
                    startupTimeout: spec.startupTimeout,
                    healthCheckInterval: spec.healthCheckInterval,
                    installHint: spec.installHint,
                    installer: spec.installer.map { installer in
                        ServerSpec.InstallSpec(
                            tool: installer.tool,
                            arguments: installer.arguments,
                            extraSearchDirectories: [directory.path]
                        )
                    }
                )
            }
        }
    }

    /// Makes a context for `root` that manages one Rust server. The binary lookup of that server
    /// finds the fake binary in `binaryDirectory`, thus the server runs on each machine.
    /// - Parameters:
    ///   - root: The workspace root of the context.
    ///   - binaryDirectory: The directory that gets the fake binary of the Rust server.
    ///   - processState: The liveness of the fake server process.
    /// - Returns: The context. The caller starts it and stops it.
    private static func makeRustContext(
        root: URL,
        binaryDirectory: URL,
        processState: ProcessState = ProcessState()
    ) async throws -> CodeContext<FakeLanguageServerConnection> {
        try writeRustProjectMarker(in: root)
        try writeFakeRustServerBinary(in: binaryDirectory)
        return try await makeCodeContext(
            rootDirectory: root,
            embedder: nil,
            processState: processState,
            serverSpecs: serverSpecs(searching: binaryDirectory)
        )
    }

    /// Before `start()` and after `stop()`, the two calls do nothing and give `lspStatus()`.
    @Test(.timeLimit(.minutes(CodeContextStartTests.timeLimitMinutes)))
    func stopAndStartLanguageServersOutsideTheLifecycleGiveTheLspStatus() async throws {
        try await withTemporaryWorkspace { root in
            try await withTemporaryWorkspace { binaryDirectory in
                let context = try await Self.makeRustContext(root: root, binaryDirectory: binaryDirectory)

                #expect(await context.stopLanguageServers() == context.lspStatus())
                #expect(try await context.startLanguageServers() == context.lspStatus())

                try await context.start()
                await context.stop()

                #expect(await context.stopLanguageServers() == context.lspStatus())
                #expect(try await context.startLanguageServers() == context.lspStatus())
            }
        }
    }

    /// After `start()`, `stopLanguageServers()` stops each server and publishes the result.
    @Test(.timeLimit(.minutes(CodeContextStartTests.timeLimitMinutes)))
    func stopLanguageServersStopsEachServerAndPublishesTheResult() async throws {
        try await withTemporaryWorkspace { root in
            try await withTemporaryWorkspace { binaryDirectory in
                let context = try await Self.makeRustContext(root: root, binaryDirectory: binaryDirectory)
                try await context.start()
                let serversBeforeTheStop = await context.lspStatus()

                let servers = await context.stopLanguageServers()
                let published = await context.state.servers
                await context.stop()

                #expect(serversBeforeTheStop == [Self.runningRustServer])
                #expect(servers == [ServerStatus(command: Self.rustServerCommand, state: .notStarted)])
                #expect(published == servers)
            }
        }
    }

    /// After `stopLanguageServers()`, `startLanguageServers()` starts each server again and
    /// publishes the result.
    @Test(.timeLimit(.minutes(CodeContextStartTests.timeLimitMinutes)))
    func startLanguageServersAfterAStopStartsEachServerAgainAndPublishesTheResult() async throws {
        try await withTemporaryWorkspace { root in
            try await withTemporaryWorkspace { binaryDirectory in
                let processState = ProcessState()
                let context = try await Self.makeRustContext(
                    root: root,
                    binaryDirectory: binaryDirectory,
                    processState: processState
                )
                try await context.start()
                await context.stopLanguageServers()

                // A graceful stop makes the fake process exit. The new start gets a new process.
                await processState.setAlive(true)
                let servers = try await context.startLanguageServers()
                let published = await context.state.servers
                await context.stop()

                #expect(servers == [Self.runningRustServer])
                #expect(published == servers)
            }
        }
    }
}

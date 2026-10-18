import Foundation
import FoundationModelsExtras
import Testing

@testable import FoundationModelsCodeContext

/// Tests for the bounded `start()` of `CodeContext`, for `stop()` during the
/// first index pass, for the rule that one index pass runs at a time, for the
/// embedding layer that a host turns off, for the watcher that a host turns
/// off, for the calls that stop the language servers and start them again, and
/// for the ignore rules of a context that has no watcher.
///
/// Most fixtures have no project marker, thus no LSP daemon starts. The tests
/// of `stopLanguageServers()` and `startLanguageServers()` write a Cargo
/// manifest, thus the context manages one server. These tests also write a
/// fake server binary, thus the server runs also on a machine that does not
/// have the real server. The auto install is off, except in the test of a
/// failed install, which gives a fake installer runner.
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

    /// The name of the file that a test makes while the first pass runs.
    private static let lateFileName = "GreeterLate.swift"

    /// The debounce interval of the watcher that `CodeContext` makes. It is the
    /// default of the `debounceInterval` parameter of `Watcher`.
    private static let watcherDebounceInterval: Duration = .seconds(1)

    /// Reads the index status of `context` again and again until `isExpected`
    /// returns `true`.
    /// - Parameters:
    ///   - context: The context that gives the index status.
    ///   - isExpected: Returns `true` for the status that the test waits for.
    /// - Throws: `CancellationError` when the task of the test is cancelled.
    private static func waitForIndexStatus(
        of context: CodeContext<FakeLanguageServerConnection>,
        _ isExpected: (IndexProgress) -> Bool
    ) async throws {
        try await waitUntil { isExpected(await context.indexStatus()) }
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
    ///   - eventSource: The file event source of the watcher, or `nil` to turn the watcher off.
    ///   - processState: The liveness of each fake server process.
    ///   - serverSpecs: Gives the server specs of the detected projects.
    ///   - configureConnection: Configures each fake connection before the daemon gets it.
    private static func makeCodeContext(
        rootDirectory: URL,
        embedder: PooledEmbedding?,
        clock: any Clock<Duration> = ContinuousClock(),
        eventSource: FakeFileEventSource? = FakeFileEventSource(),
        processState: ProcessState = ProcessState(),
        serverSpecs: @escaping ServerSpecsForProjects = ProjectDetection.serverSpecs(for:),
        configureConnection: @escaping @Sendable (FakeLanguageServerConnection) async -> Void = { _ in }
    ) async throws -> CodeContext<FakeLanguageServerConnection> {
        try await CodeContext<FakeLanguageServerConnection>(
            rootDirectory: rootDirectory,
            embedder: embedder,
            clock: clock,
            eventSource: eventSource,
            autoInstall: LspAutoInstall(isEnabled: false),
            serverSpecs: serverSpecs,
            connectionFactory: fakeConnectionFactory(
                pid: Self.fakeServerPid,
                processState: processState,
                configureConnection: configureConnection
            )
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

    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
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

    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
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

    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
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

    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
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

    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
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

    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
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

    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
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

    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
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
    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
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
    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
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
    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
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
    /// binary lookup finds the binary changes. The lookup finds the fake binary, thus no
    /// installer runs for a detected server.
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
    ///   - embedder: The embedder of the context, or `nil` to turn the embedding layer off.
    ///   - clock: The clock of the context, of its supervisor and of each daemon.
    ///   - eventSource: The file event source of the watcher, or `nil` to turn the watcher off.
    ///   - configureConnection: Configures each fake connection before the daemon gets it.
    /// - Returns: The context. The caller starts it and stops it.
    private static func makeRustContext(
        root: URL,
        binaryDirectory: URL,
        processState: ProcessState = ProcessState(),
        embedder: PooledEmbedding? = nil,
        clock: any Clock<Duration> = ContinuousClock(),
        eventSource: FakeFileEventSource? = FakeFileEventSource(),
        configureConnection: @escaping @Sendable (FakeLanguageServerConnection) async -> Void = { _ in }
    ) async throws -> CodeContext<FakeLanguageServerConnection> {
        try writeRustProjectMarker(in: root)
        try writeFakeRustServerBinary(in: binaryDirectory)
        return try await makeCodeContext(
            rootDirectory: root,
            embedder: embedder,
            clock: clock,
            eventSource: eventSource,
            processState: processState,
            serverSpecs: serverSpecs(searching: binaryDirectory),
            configureConnection: configureConnection
        )
    }

    // MARK: - A failed install

    /// The installer tool of the server whose install fails. `ServerInstaller` runs an installer
    /// only when its tool is on the PATH, and `true` is on the PATH of each machine. The fake
    /// runner does not run it.
    private static let alwaysPresentInstallerTool = "true"

    /// The exit code that the fake installer gives: a failed install.
    private static let failedInstallExitCode: Int32 = 1

    /// Gives the server specs of `serverSpecs(searching:)` and one more spec for `missingCommand`.
    ///
    /// The binary lookup finds `missingCommand` nowhere, and its installer tool is on the PATH.
    /// Thus the supervisor runs the installer for that server.
    /// - Parameters:
    ///   - directory: The directory that holds the fake binary of each detected server.
    ///   - missingCommand: The command of the server that is on no PATH.
    /// - Returns: The spec mapping that the context gives to its supervisor.
    private static func serverSpecs(searching directory: URL, missingCommand: String) -> ServerSpecsForProjects {
        let detectedSpecs = serverSpecs(searching: directory)
        return { projects in
            detectedSpecs(projects) + [
                ServerSpec(
                    command: missingCommand,
                    languageIDs: ["fake"],
                    installHint: "install \(missingCommand) by hand",
                    installer: ServerSpec.InstallSpec(tool: alwaysPresentInstallerTool)
                )
            ]
        }
    }

    /// Waits until the installer of `command` ran one time and the server of `command` is
    /// `.notFound` again.
    /// - Parameters:
    ///   - context: The context that gives the server status.
    ///   - runner: The fake installer runner of the context.
    ///   - command: The command of the server whose install fails.
    /// - Throws: `CancellationError` when the task of the test is cancelled.
    private static func waitForTheFailedInstall(
        of context: CodeContext<FakeLanguageServerConnection>,
        runner: FakeInstallRunner,
        command: String
    ) async throws {
        try await waitUntil {
            let hasRun = await !runner.invocations.isEmpty
            let state = await context.lspStatus().first { $0.command == command }?.state
            return hasRun && state == .notFound
        }
    }

    /// An installer that exits with 1 does not stop the session: `start()` completes, the server
    /// of that installer stays `.notFound`, the other server runs and the index answers.
    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
    func aFailedInstallLeavesItsServerNotFoundAndTheOtherServerAndTheIndexRunning() async throws {
        try await withTemporaryWorkspace { root in
            try await withTemporaryWorkspace { binaryDirectory in
                try Self.writeFixture(in: root)
                try Self.writeRustProjectMarker(in: root)
                try Self.writeFakeRustServerBinary(in: binaryDirectory)
                let missingCommand = "fake-missing-language-server-\(UUID().uuidString)"
                let runner = FakeInstallRunner()
                await runner.updateResult(.success(InstallRunResult(exitCode: Self.failedInstallExitCode, output: "")))
                let context = try await CodeContext<FakeLanguageServerConnection>(
                    rootDirectory: root,
                    embedder: nil,
                    eventSource: FakeFileEventSource(),
                    installRunner: runner,
                    serverSpecs: Self.serverSpecs(searching: binaryDirectory, missingCommand: missingCommand),
                    connectionFactory: fakeConnectionFactory(pid: Self.fakeServerPid, processState: ProcessState())
                )

                try await context.start()
                try await Self.waitForTheFailedInstall(of: context, runner: runner, command: missingCommand)
                await context.waitForFirstIndexPass()
                let servers = await context.lspStatus()
                let matches = try await context.searchSymbol(query: "greet0")
                let invocations = await runner.invocations
                await context.stop()

                #expect(servers.contains(ServerStatus(command: missingCommand, state: .notFound)))
                #expect(servers.contains(Self.runningRustServer))
                #expect(matches.contains { $0.name == "greet0" })
                #expect(invocations.count == 1)
            }
        }
    }

    /// Before `start()` and after `stop()`, the two calls do nothing and give `lspStatus()`.
    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
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
    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
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
    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
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

    // MARK: - Lifecycle calls during a stop

    /// The real time that a test waits after it starts a lifecycle call in a task, thus the call
    /// arrives at the context while the stop before it still runs.
    private static let lifecycleCallArrivalWindow: Duration = .milliseconds(100)

    /// The name of the Rust source file that the LSP index worker opens.
    private static let rustSourceFileName = "lib.rs"

    /// The shutdown grace of each daemon: the time that a stop waits for a server that does not
    /// exit, before it kills the server.
    private static let shutdownGrace = LSPDaemonLimits.defaultShutdownGrace

    /// Writes one Rust source file into `root`. The LSP index worker of the Rust server opens it,
    /// and the embedding step embeds its chunks.
    /// - Parameter root: The workspace root to write the file into.
    private static func writeRustSource(in root: URL) throws {
        try write("fn greet() -> &'static str {\n    \"hello\"\n}\n", to: rustSourceFileName, in: root)
    }

    /// A `start()` that comes while a `stop()` waits for an LSP index task waits until the stop is
    /// complete. Thus the stop does not stop the watcher of that start, and after the two calls
    /// the context watches the workspace and its server runs.
    ///
    /// The embedding gate stays closed, thus the first index pass ends only when the stop cancels
    /// it. When `waitForFirstIndexPass()` returns, the stop is past the index loop and waits for
    /// the LSP index task, which waits at the closed `didOpen` gate. A cancel does not stop that
    /// wait.
    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
    func aStartDuringAStopWaitsForTheStopAndLeavesTheContextWatchingWithItsServerRunning() async throws {
        try await withTemporaryWorkspace { root in
            try await withTemporaryWorkspace { binaryDirectory in
                try Self.writeRustSource(in: root)
                let log = EmbedCallLog()
                await log.closeGate()
                let didOpenGate = AsyncGate()
                let didOpenArrivals = Counter()
                let context = try await Self.makeRustContext(
                    root: root,
                    binaryDirectory: binaryDirectory,
                    embedder: GatedEmbedder(vectorLength: Self.dimension, log: log),
                    configureConnection: { connection in
                        await connection.setDidOpenCallHook {
                            await didOpenArrivals.increment()
                            await didOpenGate.waitUntilOpen()
                        }
                    }
                )
                try await context.start()
                await log.waitForFirstCall()
                try await waitUntil { await didOpenArrivals.value > 0 }

                let stop = Task { await context.stop() }
                await context.waitForFirstIndexPass()
                let start = Task { try await context.start() }
                try await Task.sleep(for: Self.lifecycleCallArrivalWindow)
                await didOpenGate.open()
                await stop.value
                try await start.value
                let isWatching = await context.isWatching
                let servers = await context.lspStatus()
                await log.openGate()
                await context.stop()

                #expect(isWatching, "the stop must not stop the watcher of the start that came during the stop")
                #expect(servers == [Self.runningRustServer])
            }
        }
    }

    /// A `startLanguageServers()` call that comes while a `stopLanguageServers()` call still waits
    /// for the server to exit leaves one running server for each detected project.
    ///
    /// The fake process does not exit by itself, thus the stop waits for the shutdown grace on
    /// the manual clock until the test advances the clock.
    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
    func startLanguageServersDuringAStopLeavesOneRunningServerForEachProject() async throws {
        try await withTemporaryWorkspace { root in
            try await withTemporaryWorkspace { binaryDirectory in
                let clock = ManualClock()
                let processState = ProcessState()
                await processState.setHangsOnWaitForExit(true)
                let context = try await Self.makeRustContext(
                    root: root,
                    binaryDirectory: binaryDirectory,
                    processState: processState,
                    clock: clock
                )
                try await context.start()

                let stop = Task { await context.stopLanguageServers() }
                await clock.waitForWaiter(withDeadline: clock.now.advanced(by: Self.shutdownGrace))
                let start = Task { try await context.startLanguageServers() }
                try await Task.sleep(for: Self.lifecycleCallArrivalWindow)
                clock.advance(by: Self.shutdownGrace)
                let stopped = await stop.value
                let servers = try await start.value
                let published = await context.state.servers
                await processState.setHangsOnWaitForExit(false)
                await context.stop()

                #expect(stopped == [ServerStatus(command: Self.rustServerCommand, state: .notStarted)])
                #expect(servers == [Self.runningRustServer])
                #expect(published == servers)
            }
        }
    }

    // MARK: - Ignore rules with no watcher

    /// The rule file text that ignores the `build-out/` directory.
    private static let buildOutRule = "build-out/\n"

    /// The path of a Rust file that `buildOutRule` ignores.
    private static let ignoredRustPath = "build-out/generated.rs"

    /// The line of the hover position in each file of the ignore-rule test.
    private static let hoverLine = 0

    /// The character of the hover position: a character in the name `greet`.
    private static let hoverCharacter = 3

    /// A context with no event source has no watcher. Its `start()` still loads the rules of the
    /// rule files into the shared path filter, thus a live operation does not send `didOpen` for
    /// a file that only a `.gitignore` rule ignores.
    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
    func aContextWithNoEventSourceSendsNoDidOpenForAFileThatOnlyAGitignoreRuleIgnores() async throws {
        try await withTemporaryWorkspace { root in
            try await withTemporaryWorkspace { binaryDirectory in
                try Self.writeRustSource(in: root)
                try write(Self.buildOutRule, to: ".gitignore", in: root)
                try write("fn generated() {}\n", to: Self.ignoredRustPath, in: root)
                let connectionBox = Box<FakeLanguageServerConnection?>(nil)
                let context = try await Self.makeRustContext(
                    root: root,
                    binaryDirectory: binaryDirectory,
                    eventSource: nil,
                    configureConnection: { connection in await connectionBox.set(connection) }
                )
                try await context.start()

                for path in [Self.ignoredRustPath, Self.rustSourceFileName] {
                    _ = try await context.hover(filePath: path, line: Self.hoverLine, character: Self.hoverCharacter)
                }
                let connection = await connectionBox.value
                let isWatching = await context.isWatching
                await context.stop()

                let openedPaths = try await #require(connection).openedPaths()
                #expect(!isWatching)
                #expect(openedPaths.contains { $0.hasSuffix("/\(Self.rustSourceFileName)") })
                #expect(!openedPaths.contains { $0.hasSuffix("/\(Self.ignoredRustPath)") })
            }
        }
    }
}

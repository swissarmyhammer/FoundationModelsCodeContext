import Darwin
import Foundation
import Logging

/// Searches `$PATH` for an executable, mirroring how a shell resolves a bare command name to a
/// binary.
///
/// Extracted from `LSPDaemon` (which uses it to gate spawning a language-server binary,
/// surfacing a distinct `.notFound` state before ever spawning) so `ServerInstaller` can reuse
/// the exact same lookup to gate whether an installer's own `tool` (e.g. `"npm"`, `"rustup"`) is
/// available before attempting to run it. `ProcessLanguageServerConnection` also spawns via a
/// `$PATH` lookup (through `/usr/bin/env`), but that lookup surfaces as a generic spawn failure
/// rather than the distinct up-front check both callers of this helper need.
enum BinaryLookup {
    /// Where `resolve(command:extraSearchDirectories:)` found a binary.
    enum Location: Sendable, Equatable {
        /// Found on `$PATH` — the daemon may keep spawning `command` by its bare name.
        case onPath

        /// Found only in one of the caller-supplied extra search directories, at this absolute
        /// path — the daemon must spawn this absolute path directly, since it isn't resolvable
        /// via the plain `$PATH`-relative name.
        case extraSearchDirectory(absolutePath: String)
    }

    /// What the `$PATH` of this process holds, for the warning that a binary is not on the `$PATH`.
    ///
    /// The diagnostics do not change the lookup. They show the cause when a binary that is on
    /// disk is not found, for example a `$PATH` entry that is the literal text `~/.local/bin`.
    struct PathDiagnostics: Sendable, Equatable {
        /// The number of `$PATH` entries that `isOnPath(_:)` searches.
        let entryCount: Int

        /// Each searched `$PATH` entry that is not an absolute path, in `$PATH` order.
        /// `isOnPath(_:)` does not expand `~` or `$HOME` in such an entry.
        let nonAbsoluteEntries: [String]

        /// The log metadata of these diagnostics: the entry count and the non-absolute entries.
        var logMetadata: Logger.Metadata {
            [
                CodeContextTracing.MetadataKey.pathEntryCount: .stringConvertible(entryCount),
                CodeContextTracing.MetadataKey.pathNonAbsoluteEntries: .array(nonAbsoluteEntries.map { .string($0) }),
            ]
        }
    }

    /// Gives the diagnostics of `pathVariable`, with the same split that `isOnPath(_:)` uses.
    /// - Parameter pathVariable: The value of `$PATH`, or `nil` when `$PATH` is not set.
    /// - Returns: The number of searched entries and each searched entry that is not absolute.
    static func pathDiagnostics(pathVariable: String?) -> PathDiagnostics {
        let entries = pathVariable.map(searchDirectories(of:)) ?? []
        return PathDiagnostics(entryCount: entries.count, nonAbsoluteEntries: entries.filter { !$0.hasPrefix("/") })
    }

    /// Splits `pathVariable` into the directories that the lookup searches, in order. An empty
    /// entry is not searched.
    /// - Parameter pathVariable: The value of `$PATH`.
    /// - Returns: The non-empty entries of `pathVariable`.
    private static func searchDirectories(of pathVariable: String) -> [String] {
        pathVariable.split(separator: ":").map(String.init)
    }

    /// Reports whether `command` resolves to an executable file somewhere on `$PATH`.
    /// - Parameter command: The executable name to search for (no path separators).
    /// - Returns: `true` if `command` resolves to an executable file on `$PATH`; `false` otherwise.
    static func isOnPath(_ command: String) -> Bool {
        guard let pathVariable = ProcessInfo.processInfo.environment["PATH"] else { return false }
        for directory in searchDirectories(of: pathVariable) {
            let candidatePath = (directory as NSString).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: candidatePath) {
                return true
            }
        }
        return false
    }

    /// Resolves `command`, searching `$PATH` first and then `extraSearchDirectories` (in order)
    /// once `$PATH` comes up empty.
    ///
    /// `extraSearchDirectories` exists for `LSPDaemon.start()` to also honor
    /// `ServerSpec.installer?.extraSearchDirectories`: native global installers (`go install`,
    /// `rustup component add`) land their binary in a well-known directory (e.g. `~/go/bin`,
    /// `~/.cargo/bin`) that is frequently not on the user's `$PATH`. Each directory may use `~`
    /// for the home directory; expanded here via `NSString.expandingTildeInPath`, matching the
    /// `ServerSpec.InstallSpec.extraSearchDirectories` doc comment's stated contract.
    /// - Parameters:
    ///   - command: The executable name to search for (no path separators).
    ///   - extraSearchDirectories: Additional directories to search, in order, once `$PATH` comes
    ///     up empty for `command`. Defaults to none.
    /// - Returns: `.onPath` if `command` resolves on `$PATH`; `.extraSearchDirectory(absolutePath:)`
    ///   with the resolved absolute path if found in one of `extraSearchDirectories`; `nil` if
    ///   found in neither.
    static func resolve(command: String, extraSearchDirectories: [String] = []) -> Location? {
        if isOnPath(command) { return .onPath }
        for directory in extraSearchDirectories {
            let expandedDirectory = (directory as NSString).expandingTildeInPath
            let candidatePath = (expandedDirectory as NSString).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: candidatePath) {
                return .extraSearchDirectory(absolutePath: candidatePath)
            }
        }
        return nil
    }
}

/// The opt-out policy governing whether `ServerInstaller` may run a language server's
/// machine-actionable installer (`ServerSpec.installer`) automatically.
///
/// On by default. When a spec carries an `InstallSpec`, running its installer means running the
/// ecosystem's *native global installer* directly on the user's machine — `npm install -g`,
/// `rustup component add`, `go install`, `pipx install`, or `brew install`, exactly the commands
/// captured on each `ServerSpec.InstallSpec` (see `Languages/ServerSpec.swift`). That is a real,
/// user-visible side effect: it writes into the user's global npm/cargo/go/pipx/brew state, the
/// same as if the user had typed the command themselves. Set `isEnabled` to `false` to opt out
/// and fall back to `installHint`-only guidance — exactly the behavior before auto-install
/// existed, and always the behavior for a spec whose `installer` is `nil`.
public struct LspAutoInstall: Sendable, Equatable {
    /// Whether `ServerInstaller` may run a spec's installer automatically. Defaults to `true`.
    public var isEnabled: Bool

    /// How long one install command may run before it is treated as failed and force-terminated.
    /// Defaults to 300 seconds — generous enough for a cold `npm install -g` or `go install` on a
    /// slow connection, but still bounded.
    public var timeout: Duration

    /// Creates an auto-install policy.
    /// - Parameters:
    ///   - isEnabled: Whether auto-install is permitted. Defaults to `true`.
    ///   - timeout: How long one install command may run before it is force-terminated as failed.
    ///     Defaults to 300 seconds.
    public init(isEnabled: Bool = true, timeout: Duration = .seconds(300)) {
        self.isEnabled = isEnabled
        self.timeout = timeout
    }
}

/// The outcome of one `InstallRunner.run(tool:arguments:timeout:)` call that completed (as
/// opposed to throwing).
struct InstallRunResult: Sendable, Equatable {
    /// The installer process's exit code. `0` conventionally means success.
    let exitCode: Int32

    /// A bounded tail of the installer's combined stdout+stderr output, for error reporting when
    /// `exitCode != 0`. A log record never holds it; `InstallFailureReason.code(in:)` takes the
    /// only part a log record may hold.
    let output: String
}

/// Takes the error code that a failed installer printed out of the output of the installer.
///
/// `npm` prints its error code on a line of its own: `npm error code <code>` (npm 10 and later)
/// or `npm ERR! code <code>` (npm 9 and earlier), for example
/// `npm error code UNABLE_TO_GET_ISSUER_CERT_LOCALLY`. The other installers (`brew`, `go`,
/// `pipx`, `cargo`, ...) print no such code, thus their output gives no code.
///
/// A log record holds the code, so the code must not hold content. The extractor gives a code
/// only when the code is all of the text after the prefix, and is one to `maximumCodeLength`
/// characters of `codeCharacters`. Free text (a path, a URL, a package name) gives no code.
enum InstallFailureReason {
    /// The start of the line that holds the code, in each output form of `npm`.
    private static let codeLinePrefixes = ["npm error code ", "npm ERR! code "]

    /// The longest code that the extractor gives.
    private static let maximumCodeLength = 64

    /// The characters of a code: capital letters, digits and the underscore.
    private static let codeCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")

    /// Gives the error code that `npm` printed in `output`.
    /// - Parameter output: The output of the installer.
    /// - Returns: The code of the first line that holds a safe code, or `nil` when no line does.
    static func code(in output: String) -> String? {
        output.split(whereSeparator: \.isNewline).lazy.compactMap(code(inLine:)).first
    }

    /// Gives the error code of one line of installer output.
    /// - Parameter line: One line of the output, with no line break.
    /// - Returns: The text after a code line prefix when that text is a safe code, else `nil`.
    private static func code(inLine line: Substring) -> String? {
        guard let prefix = codeLinePrefixes.first(where: { line.hasPrefix($0) }) else {
            return nil
        }
        let code = line.dropFirst(prefix.count)
        guard (1...maximumCodeLength).contains(code.count), code.allSatisfy(codeCharacters.contains) else {
            return nil
        }
        return String(code)
    }
}

/// The process-running seam `ServerInstaller` drives, mirroring how `ConnectionFactory` decouples
/// `LSPDaemon` from real processes: production code runs a real installer via
/// `ProcessInstallRunner`, unit tests substitute a scripted `FakeInstallRunner` and never spawn
/// anything.
protocol InstallRunner: Sendable {
    /// Runs `tool` with `arguments`, bounded by `timeout`.
    /// - Parameters:
    ///   - tool: The installer executable to run, looked up on `$PATH`.
    ///   - arguments: The full argv tail passed to `tool`.
    ///   - timeout: How long to wait before force-terminating `tool` and throwing
    ///     `CodeContextError.timeout`.
    /// - Returns: The completed run's exit code and a bounded output tail.
    /// - Throws: `CodeContextError.spawnFailed` if `tool` could not be launched;
    ///   `CodeContextError.timeout` if `timeout` elapses before `tool` exits.
    func run(tool: String, arguments: [String], timeout: Duration) async throws -> InstallRunResult
}

/// The production `InstallRunner`: spawns `tool` as the leader of a new process group with
/// `ProcessGroupChild`.
///
/// Spawns via `ProcessUtilities.envExecutablePath` (`/usr/bin/env <tool> <args>`), the same
/// shared constant `ProcessLanguageServerConnection` spawns through for its own `$PATH`
/// resolution. The installer gets the null device as its standard input, and one pipe for its
/// standard output and its standard error.
///
/// An installer such as `npm` starts processes of its own: `node` workers, `sh -c` lifecycle
/// scripts, `git`. They are in the process group of the installer. Each end of a run stops the
/// full group with `ProcessGroupChild.terminateGroup(grace:)`: `SIGTERM`, at most
/// `terminationGrace` for the exit of the installer, then `SIGKILL`. Thus no process of the
/// group outlives the run, holds the output pipe open, or holds a lock (the `npm` cache lock)
/// for the next session. A run ends in one of three ways:
/// - The installer exits. The run returns its exit code and its output.
/// - `timeout` elapses first. The run stops the group and throws `CodeContextError.timeout`.
/// - The calling task is cancelled, for example by a production `shutdown()` that races a real
///   `npm` run. The run stops the group and returns the exit code of the installer: the number
///   of the signal that ended it. A caller that shuts down does not wait out the `timeout`.
///
/// A process that leaves the process group (a new session or a new group) gets no signal of
/// the stop, and it can hold the output pipe open. Thus the run waits at most `outputGrace` for
/// the end of the output after the stop. A run never takes longer than `timeout`, plus
/// `terminationGrace` and `outputGrace`, plus the reap of the killed installer.
struct ProcessInstallRunner: InstallRunner {
    /// The number of seconds in `terminationGrace`.
    static let terminationGraceSeconds = 2

    /// The time that a stopped installer gets to exit after `SIGTERM`, before `SIGKILL` goes to
    /// its process group. In this time `npm` can release its cache lock.
    static let terminationGrace: Duration = .seconds(terminationGraceSeconds)

    /// The number of milliseconds in `outputGrace`.
    static let outputGraceMilliseconds = 500

    /// The longest time that a run waits for the end of the output after the stop of the process
    /// group. Only a process outside the group can hold the output pipe open that long.
    static let outputGrace: Duration = .milliseconds(outputGraceMilliseconds)

    /// The count of the most recent output chunks that a run keeps for its result.
    private static let outputTailChunkLimit = 40

    /// The clock the per-run timeout sleeps against. Defaults to `ContinuousClock()`; tests that
    /// need to control the timeout without waiting in real time inject a `ManualClock` — though
    /// the integration tests in `ServerInstallerTests.swift` mostly prefer real, short timeouts
    /// against real short-lived executables instead, since exercising a real spawn and group stop
    /// end-to-end is the point of those cases.
    private let clock: any Clock<Duration>

    /// Creates a process-backed install runner.
    /// - Parameter clock: The clock the per-run timeout sleeps against. Defaults to
    ///   `ContinuousClock()`.
    init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    func run(tool: String, arguments: [String], timeout: Duration) async throws -> InstallRunResult {
        let outputPipe = Pipe()
        let child = try Self.spawn(tool: tool, arguments: arguments, output: outputPipe)
        let tailBuffer = BoundedTailBuffer(maxChunks: Self.outputTailChunkLimit)
        let outputEnd = Self.startDrain(of: outputPipe, into: tailBuffer)

        // The wait for the exit ends at a cancel too, thus `exitedInTime` alone does not tell an
        // exit from a cancel. Only a run that is not cancelled and did not see the exit in time
        // timed out.
        let exitedInTime = await clock.waitForCompletion(atMost: timeout) { await child.waitUntilExit() }
        let isTimedOut = !exitedInTime && !Task.isCancelled
        let exitCode = await Self.stop(child, outputEnd: outputEnd)

        guard !isTimedOut else { throw CodeContextError.timeout(timeout) }
        return InstallRunResult(exitCode: exitCode, output: tailBuffer.snapshot())
    }

    /// Starts `tool` as the leader of a new process group.
    ///
    /// The installer gets the null device as its standard input, not the standard input of the
    /// host. An installer such as `npm` reads its standard input while it runs, and the host can
    /// use its standard input for a protocol (ACP, MCP over stdio).
    /// - Parameters:
    ///   - tool: The installer executable, looked up on `$PATH` by `env(1)`.
    ///   - arguments: The full argv tail passed to `tool`.
    ///   - output: The pipe that gets both the standard output and the standard error of `tool`.
    /// - Returns: The started installer.
    /// - Throws: `CodeContextError.spawnFailed` if `env(1)` could not be launched.
    private static func spawn(tool: String, arguments: [String], output: Pipe) throws -> ProcessGroupChild {
        do {
            return try ProcessGroupChild.spawn(
                executableURL: URL(fileURLWithPath: ProcessUtilities.envExecutablePath),
                arguments: [tool] + arguments,
                standardInput: .nullDevice,
                standardOutput: output,
                standardError: output
            )
        } catch {
            throw CodeContextError.spawnFailed("\(tool): \(error.localizedDescription)")
        }
    }

    /// Starts the thread that reads `outputPipe` to its end and appends each chunk to
    /// `tailBuffer`.
    ///
    /// The read blocks in `read(2)` until each process that holds the write end of the pipe
    /// exits, thus it runs on a dedicated thread, not on a pool thread (see
    /// `ProcessUtilities.runOnDedicatedThread(name:_:)`). The thread keeps `outputPipe`, thus the
    /// read end stays open until the read ends, also when the run returns first.
    /// - Parameters:
    ///   - outputPipe: The pipe that gets the output of the installer.
    ///   - tailBuffer: The bounded tail buffer to append every read chunk to.
    /// - Returns: The end of the output: `true` after the read reached the end of the pipe.
    private static func startDrain(of outputPipe: Pipe, into tailBuffer: BoundedTailBuffer) -> CancellableWaiters<Bool> {
        let outputEnd = CancellableWaiters(false) { isEnded in isEnded }
        let outputFileDescriptor = outputPipe.fileHandleForReading.fileDescriptor
        _ = ProcessUtilities.runOnDedicatedThread(name: "install-output-drain") {
            withExtendedLifetime(outputPipe) {
                drainOutput(fileDescriptor: outputFileDescriptor, into: tailBuffer)
            }
            outputEnd.update { isEnded in isEnded = true }
        }
        return outputEnd
    }

    /// Stops the process group of `child`, waits at most `outputGrace` for the end of the
    /// output, and gives the termination status of `child`.
    ///
    /// The stop runs in its own task, which this function awaits. A cancel of the calling task
    /// does not reach that task: a cancelled run still gives the installer `terminationGrace`
    /// after `SIGTERM`, still waits for the output, and still reaps the installer. Each wait in
    /// the task has a limit, and `SIGKILL` goes to the group before the reap, thus the task ends.
    /// - Parameters:
    ///   - child: The installer.
    ///   - outputEnd: The end of the output, from `startDrain(of:into:)`.
    /// - Returns: The exit status of the installer, or the number of the signal that ended it.
    private static func stop(_ child: ProcessGroupChild, outputEnd: CancellableWaiters<Bool>) async -> Int32 {
        await Task {
            await child.terminateGroup(grace: terminationGrace)
            await ContinuousClock().waitForCompletion(atMost: outputGrace) { await outputEnd.wait() }
            return await child.terminationStatus
        }.value
    }

    /// Reads `fileDescriptor` until EOF, appending every chunk read to `tailBuffer`.
    ///
    /// Runs on a dedicated thread, outside any actor isolation. Delegates the read-decode-append
    /// loop itself to the shared `ProcessUtilities.drainChunks(from:bufferSize:onChunk:)` — the
    /// same helper `ProcessLanguageServerConnection.runStderrDrainLoop` calls — passing only what
    /// differs between the two call sites: what to do with each decoded chunk (append alone here,
    /// vs. log-then-append there).
    /// - Parameters:
    ///   - fileDescriptor: The pipe read end's raw file descriptor.
    ///   - tailBuffer: The bounded tail buffer to append every read chunk to.
    private static func drainOutput(fileDescriptor: Int32, into tailBuffer: BoundedTailBuffer) {
        ProcessUtilities.drainChunks(from: fileDescriptor) { text in
            tailBuffer.append(chunk: text)
        }
    }
}

/// Orchestrates running a language server's machine-actionable installer, subject to the
/// `LspAutoInstall` opt-out policy.
///
/// Per plan.md's LSP subsystem design, this is the auto-install counterpart to `LSPDaemon`: where
/// `LSPDaemon` spawns and monitors a language server itself, `ServerInstaller` spawns the
/// *installer* that puts that server on `$PATH` in the first place, before the daemon ever tries
/// to start it. An actor so every attempted command is tracked without a lock: `install(spec:)`
/// records attempted commands and never retries a completed or in-flight attempt — the backstop
/// against install loops (e.g. an install that "succeeds" per its exit code but doesn't actually
/// leave the binary discoverable, which would otherwise retry forever every time the daemon
/// re-checks `$PATH`). Concurrent callers asking to install the same command all await the same
/// in-flight `Task`, so the underlying installer runs exactly once no matter how many callers ask
/// concurrently.
///
/// Note the cancellation semantics of that shared in-flight `Task`: a caller whose own await of
/// `install(spec:)` is cancelled does *not* cancel the underlying install — the `Task` backing an
/// in-flight attempt is intentionally unstructured (not a structured child of any one caller), so
/// it keeps running to completion for whichever other callers are also awaiting it. It is
/// `ProcessInstallRunner`'s own cancellation handling (see its doc comment) that makes a genuine
/// shutdown of the *runner's* task prompt, not anything `install(spec:)` does with the caller's
/// cancellation here.
actor ServerInstaller {
    /// The opt-out policy gating whether `install(spec:)` may ever invoke `runner`.
    private let policy: LspAutoInstall

    /// The process-running seam. Production code uses the default `ProcessInstallRunner()`; tests
    /// inject a scripted `FakeInstallRunner`.
    private let runner: any InstallRunner

    /// Every attempted install, keyed by `ServerSpec.command`, recording whether the install
    /// succeeded once the runner call completes. Never cleared: a command that reaches this
    /// dictionary — successfully or not — is never retried by this instance again.
    private var attempts: [String: Task<Bool, Never>] = [:]

    /// Creates a server installer.
    /// - Parameters:
    ///   - policy: The opt-out policy gating auto-install. Defaults to `LspAutoInstall()`
    ///     (enabled, 300-second timeout).
    ///   - runner: The process-running seam. Defaults to `ProcessInstallRunner()`.
    init(policy: LspAutoInstall = LspAutoInstall(), runner: any InstallRunner = ProcessInstallRunner()) {
        self.policy = policy
        self.runner = runner
    }

    /// Attempts to install `spec.command` via its `installer`, subject to the auto-install policy.
    ///
    /// Returns `false` immediately — without ever invoking `runner` — when `spec.installer` is
    /// `nil`, when the policy is disabled, or when the installer's own `tool` isn't on `$PATH`
    /// (checked via `BinaryLookup`, the same lookup `LSPDaemon` uses for `spec.command` itself).
    /// Otherwise runs `runner.run(tool:arguments:timeout:)` at most once for this command: a
    /// second call (concurrent or sequential) for the same `spec.command` awaits the first
    /// attempt's already-in-flight or already-completed `Task` instead of running the installer
    /// again.
    /// - Parameter spec: The server spec whose `installer` (if any) to run.
    /// - Returns: `true` if the installer command exited `0`; `false` for a disabled policy, a
    ///   nil/unrunnable installer, a nonzero exit, or a runner throw/timeout.
    func install(spec: ServerSpec) async -> Bool {
        guard policy.isEnabled else { return false }
        guard let installer = spec.installer else { return false }
        guard BinaryLookup.isOnPath(installer.tool) else { return false }

        if let inFlightOrCompleted = attempts[spec.command] {
            return await inFlightOrCompleted.value
        }

        let runner = self.runner
        let timeout = policy.timeout
        let task = Task<Bool, Never> {
            await Self.performInstall(runner: runner, command: spec.command, installer: installer, timeout: timeout)
        }
        attempts[spec.command] = task
        return await task.value
    }

    /// Runs one installer command to completion, logging start/success/failure via `Log.lsp`.
    ///
    /// A log record holds the server command, the installer tool name, the exit code, the error
    /// code that `InstallFailureReason.code(in:)` takes out of the installer output, and the
    /// type name of an error. It never holds the installer arguments, any other text of the
    /// installer output or the description of an error, because each of them can hold content.
    /// - Parameters:
    ///   - runner: The process-running seam to invoke.
    ///   - command: The server command being installed, for logging.
    ///   - installer: The installer to run.
    ///   - timeout: How long the installer may run before it is force-terminated as failed.
    /// - Returns: `true` if the installer exited `0`; `false` for a nonzero exit or a runner
    ///   throw/timeout.
    private static func performInstall(
        runner: any InstallRunner,
        command: String,
        installer: ServerSpec.InstallSpec,
        timeout: Duration
    ) async -> Bool {
        let installMetadata: Logger.Metadata = [
            CodeContextTracing.MetadataKey.lspServer: .string(command),
            CodeContextTracing.MetadataKey.lspInstaller: .string(installer.tool),
        ]
        Log.lsp.info("the installer of the language server starts", metadata: installMetadata)
        do {
            let result = try await runner.run(tool: installer.tool, arguments: installer.arguments, timeout: timeout)
            guard result.exitCode == 0 else {
                Log.lsp.error(
                    "the installer of the language server failed",
                    metadata: installMetadata.merging(failureMetadata(of: result)) { _, failure in failure }
                )
                return false
            }
            Log.lsp.info("the installer of the language server succeeded", metadata: installMetadata)
            return true
        } catch {
            Log.lsp.error(
                "the installer of the language server did not complete",
                metadata: installMetadata.merging(Log.serverFailureMetadata(server: command, error: error)) { _, failure in failure }
            )
            return false
        }
    }

    /// Gives the metadata of the record of an installer that exited nonzero: the exit code, and
    /// the error code of the output when `InstallFailureReason.code(in:)` finds one.
    /// - Parameter result: The completed run of the installer.
    /// - Returns: The exit code and the error code metadata. It holds no other output text.
    private static func failureMetadata(of result: InstallRunResult) -> Logger.Metadata {
        var metadata: Logger.Metadata = [CodeContextTracing.MetadataKey.exitCode: .stringConvertible(result.exitCode)]
        if let reason = InstallFailureReason.code(in: result.output) {
            metadata[CodeContextTracing.MetadataKey.installFailureReason] = .string(reason)
        }
        return metadata
    }
}

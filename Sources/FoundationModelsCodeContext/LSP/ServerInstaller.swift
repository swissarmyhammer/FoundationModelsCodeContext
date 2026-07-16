import Darwin
import Foundation

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

    /// Reports whether `command` resolves to an executable file somewhere on `$PATH`.
    /// - Parameter command: The executable name to search for (no path separators).
    /// - Returns: `true` if `command` resolves to an executable file on `$PATH`; `false` otherwise.
    static func isOnPath(_ command: String) -> Bool {
        guard let pathVariable = ProcessInfo.processInfo.environment["PATH"] else { return false }
        let searchDirectories = pathVariable.split(separator: ":").map(String.init)
        for directory in searchDirectories {
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
    /// `exitCode != 0`.
    let output: String
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

/// The production `InstallRunner`: spawns `tool` as a real child process via Foundation
/// `Process`.
///
/// Spawns via `ProcessUtilities.envExecutablePath` (`/usr/bin/env <tool> <args>`), the same
/// shared constant `ProcessLanguageServerConnection` spawns through for its own `$PATH`
/// resolution. Terminates the child in both of its exit paths: a `timeout` that
/// elapses before the process exits kills it and throws `CodeContextError.timeout`, and the
/// *calling* task being cancelled (e.g. a production `shutdown()` racing a real `brew`/`npm` run)
/// kills it via `withTaskCancellationHandler` — without this, a caller wanting to shut down
/// promptly would otherwise have to wait out up to the full `timeout` before the child is reaped.
struct ProcessInstallRunner: InstallRunner {
    /// The clock the per-run timeout sleeps against. Defaults to `ContinuousClock()`; tests that
    /// need to control the timeout without waiting in real time inject a `ManualClock` — though
    /// the integration tests in `ServerInstallerTests.swift` mostly prefer real, short timeouts
    /// against real short-lived executables instead, since exercising a real `Process` spawn/kill
    /// end-to-end is the point of those cases.
    private let clock: any Clock<Duration>

    /// Creates a process-backed install runner.
    /// - Parameter clock: The clock the per-run timeout sleeps against. Defaults to
    ///   `ContinuousClock()`.
    init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    func run(tool: String, arguments: [String], timeout: Duration) async throws -> InstallRunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessUtilities.envExecutablePath)
        process.arguments = [tool] + arguments

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            throw CodeContextError.spawnFailed("\(tool): \(error.localizedDescription)")
        }

        let pid = process.processIdentifier

        let tailBuffer = BoundedTailBuffer(maxChunks: 40)
        let outputFileDescriptor = outputPipe.fileHandleForReading.fileDescriptor
        let drainTask = Task.detached {
            Self.drainOutput(fileDescriptor: outputFileDescriptor, into: tailBuffer)
        }

        return try await Self.awaitCompletion(
            process: process, pid: pid, timeout: timeout, clock: clock, drainTask: drainTask, tailBuffer: tailBuffer
        )
    }

    /// Races a spawned installer process's natural exit against `timeout` and against the calling
    /// task's own cancellation, resolving to exactly one `InstallRunResult` (or throwing).
    ///
    /// Extracted out of `run(tool:arguments:timeout:)` so that method reads as a linear
    /// spawn-then-await sequence: this is the one place the three independent completion paths —
    /// `process.terminationHandler` firing on natural exit, `timeoutTask` firing first, and
    /// `withTaskCancellationHandler`'s `onCancel` firing on cancellation — are coordinated, all
    /// synchronized through a single `ResumeOnce` so whichever path resolves first wins and the
    /// other two become no-ops. The continuation body itself only wires the two competing
    /// completion sources together — `scheduleTimeout` and `installTerminationHandler` below own
    /// the actual setup, so this function's own nesting stays at `withTaskCancellationHandler` →
    /// continuation, rather than also nesting the timeout task and the termination handler inline.
    ///
    /// Captures `pid` as a raw `Int32` rather than closing over `process` itself: `Process` is not
    /// `Sendable`, so every closure below that can run concurrently with this function's own
    /// execution (the timeout task, the cancellation handler) only ever touches `pid`, mirroring
    /// how `ProcessLanguageServerConnection`'s background loops capture a raw file descriptor
    /// rather than the `FileHandle`/`Process` itself. This does leave an accepted, narrow residual
    /// risk: `timeoutTask` and `onCancel` below both call `kill(pid, SIGKILL)` unconditionally, so
    /// if the process has already exited and the OS has recycled `pid` for an unrelated process in
    /// the brief window before either call runs, that unrelated process could be signaled instead.
    /// `ProcessLanguageServerConnection.close()` accepts the same unconditional-`kill`-by-pid risk
    /// already; both call sites judge the window (a handful of scheduler ticks between exit and
    /// the next `kill` call) an acceptable tradeoff against the complexity of a synchronized
    /// "already exited" flag.
    /// - Parameters:
    ///   - process: The already-spawned installer process, needed only to install
    ///     `terminationHandler`.
    ///   - pid: `process`'s id, captured separately since `Process` is not `Sendable`.
    ///   - timeout: How long to wait before killing `pid` and throwing `CodeContextError.timeout`.
    ///   - clock: The clock the timeout sleeps against.
    ///   - drainTask: The detached task draining `process`'s combined stdout+stderr into
    ///     `tailBuffer`; awaited before resolving so the returned result's `output` is complete.
    ///   - tailBuffer: The bounded tail buffer `drainTask` appends to.
    /// - Returns: The completed run's exit code and output tail.
    /// - Throws: `CodeContextError.timeout` if `timeout` elapses before the process exits.
    private static func awaitCompletion(
        process: Process,
        pid: Int32,
        timeout: Duration,
        clock: any Clock<Duration>,
        drainTask: Task<Void, Never>,
        tailBuffer: BoundedTailBuffer
    ) async throws -> InstallRunResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<InstallRunResult, Error>) in
                let resumeGuard = ResumeOnce(continuation: continuation)
                let timeoutTask = Self.scheduleTimeout(pid: pid, timeout: timeout, clock: clock, resumeGuard: resumeGuard)
                Self.installTerminationHandler(
                    on: process, timeoutTask: timeoutTask, drainTask: drainTask, tailBuffer: tailBuffer, resumeGuard: resumeGuard
                )
            }
        } onCancel: {
            // Kills promptly on cancellation independent of the continuation/timeout race above:
            // `pid` is already known by this point (the process is spawned before this handler is
            // installed), so this never has to coordinate with `resumeGuard` — the process dying
            // here still resolves the continuation normally, through `terminationHandler` above.
            kill(pid, SIGKILL)
        }
    }

    /// Schedules `awaitCompletion`'s timeout side of the race: after `timeout` elapses, kills
    /// `pid` and resumes `resumeGuard` with `CodeContextError.timeout`.
    ///
    /// A no-op in the common case where the installer exits before `timeout`:
    /// `installTerminationHandler` cancels the returned task as soon as the process exits
    /// naturally, which this task observes as its own `clock.sleep(for:)` throwing and simply
    /// returns from, without touching `pid` or `resumeGuard`.
    /// - Parameters:
    ///   - pid: The installer process id to kill if this task fires.
    ///   - timeout: How long to wait before firing.
    ///   - clock: The clock to sleep against.
    ///   - resumeGuard: Resumed with `CodeContextError.timeout(timeout)` if this task fires first.
    /// - Returns: The scheduled timeout task, so `installTerminationHandler` can cancel it once
    ///   the process exits naturally.
    private static func scheduleTimeout(
        pid: Int32,
        timeout: Duration,
        clock: any Clock<Duration>,
        resumeGuard: ResumeOnce<InstallRunResult>
    ) -> Task<Void, Never> {
        Task {
            do {
                try await clock.sleep(for: timeout)
            } catch {
                // Cancelled below once the process exits on its own first.
                return
            }
            kill(pid, SIGKILL)
            resumeGuard.resume(throwing: CodeContextError.timeout(timeout))
        }
    }

    /// Installs `process.terminationHandler`, `awaitCompletion`'s natural-exit side of the race:
    /// cancels `timeoutTask` (the process beat the clock), awaits `drainTask` so the returned
    /// result's `output` is complete, and resumes `resumeGuard` with the exit code.
    /// - Parameters:
    ///   - process: The process to attach the handler to.
    ///   - timeoutTask: Cancelled as soon as the handler fires, since the race is already decided.
    ///   - drainTask: Awaited before resolving so `tailBuffer`'s snapshot is complete.
    ///   - tailBuffer: Snapshotted into the resolved `InstallRunResult.output`.
    ///   - resumeGuard: Resumed with the completed `InstallRunResult` once `drainTask` finishes.
    private static func installTerminationHandler(
        on process: Process,
        timeoutTask: Task<Void, Never>,
        drainTask: Task<Void, Never>,
        tailBuffer: BoundedTailBuffer,
        resumeGuard: ResumeOnce<InstallRunResult>
    ) {
        process.terminationHandler = { finished in
            timeoutTask.cancel()
            let exitCode = finished.terminationStatus
            Task {
                await drainTask.value
                resumeGuard.resume(returning: InstallRunResult(exitCode: exitCode, output: tailBuffer.snapshot()))
            }
        }
    }

    /// Reads `fileDescriptor` until EOF, appending every chunk read to `tailBuffer`.
    ///
    /// Runs detached, outside any actor isolation. Delegates the read-decode-append loop itself
    /// to the shared `ProcessUtilities.drainChunks(from:bufferSize:onChunk:)` — the same helper
    /// `ProcessLanguageServerConnection.runStderrDrainLoop` calls — passing only what differs
    /// between the two call sites: what to do with each decoded chunk (append alone here, vs.
    /// log-then-append there).
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
        Log.lsp.info(
            "installing \(command, privacy: .public) via \(installer.tool, privacy: .public) \(installer.arguments.joined(separator: " "), privacy: .public)"
        )
        do {
            let result = try await runner.run(tool: installer.tool, arguments: installer.arguments, timeout: timeout)
            guard result.exitCode == 0 else {
                Log.lsp.error(
                    "install failed for \(command, privacy: .public) (exit \(result.exitCode)): \(result.output, privacy: .public)"
                )
                return false
            }
            Log.lsp.info("installed \(command, privacy: .public) successfully via \(installer.tool, privacy: .public)")
            return true
        } catch {
            Log.lsp.error("install errored for \(command, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

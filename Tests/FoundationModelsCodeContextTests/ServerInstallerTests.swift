import Foundation
import ScriptedLSPServerSupport
import Testing

@testable import FoundationModelsCodeContext

/// Tests for `ServerInstaller` driven entirely against a scripted `FakeInstallRunner`, so no real
/// process is ever spawned: success, nonzero exit, a throwing runner, a disabled policy, a nil
/// installer, a missing installer tool, and the at-most-once/concurrent-dedupe guarantee.
struct ServerInstallerTests {
    /// Builds a `ServerSpec` carrying an `InstallSpec` for `installerTool`/`installerArguments`.
    /// `command` should be unique per test: `ServerInstaller.attempts` is keyed by it, and the
    /// at-most-once guarantee is scoped to one `ServerInstaller` instance sharing that key.
    private static func serverSpec(
        command: String,
        installerTool: String,
        installerArguments: [String] = []
    ) -> ServerSpec {
        ServerSpec(
            command: command,
            languageIDs: ["fake"],
            installHint: "install \(command) via \(installerTool)",
            installer: ServerSpec.InstallSpec(tool: installerTool, arguments: installerArguments)
        )
    }

    // MARK: - install(spec:)

    @Test
    func successfulInstallReturnsTrueAndInvokesRunnerOnce() async {
        let runner = FakeInstallRunner()
        let installer = ServerInstaller(runner: runner)
        let spec = Self.serverSpec(command: "fake-success", installerTool: "true", installerArguments: ["--flag"])

        let succeeded = await installer.install(spec: spec)

        #expect(succeeded)
        let invocations = await runner.invocations
        #expect(invocations == [FakeInstallRunner.Invocation(tool: "true", arguments: ["--flag"], timeout: LspAutoInstall().timeout)])
    }

    @Test
    func nonzeroExitReturnsFalseAndStillInvokesRunnerOnce() async {
        let runner = FakeInstallRunner()
        await runner.updateResult(.success(InstallRunResult(exitCode: 1, output: "boom")))
        let installer = ServerInstaller(runner: runner)
        let spec = Self.serverSpec(command: "fake-nonzero", installerTool: "true")

        let succeeded = await installer.install(spec: spec)

        #expect(!succeeded)
        let invocations = await runner.invocations
        #expect(invocations.count == 1)
    }

    @Test
    func aFailedNpmInstallLogsTheNpmErrorCodeAndNoOtherOutput() async {
        _ = CapturedLogRecords.handler
        let marker = "cck-install-output-\(UUID().uuidString)"
        let output = """
            npm error code UNABLE_TO_GET_ISSUER_CERT_LOCALLY
            npm error request to https://registry.npmjs.org/ failed, reason: unable to get local issuer certificate
            npm error A complete log of this run can be found in: /Users/\(marker)/.npm/_logs/debug-0.log
            """
        let runner = FakeInstallRunner()
        await runner.updateResult(.success(InstallRunResult(exitCode: 1, output: output)))
        let command = "fake-npm-cert-failure-\(UUID().uuidString)"
        let spec = Self.serverSpec(command: command, installerTool: "true")

        let succeeded = await ServerInstaller(runner: runner).install(spec: spec)

        #expect(!succeeded)
        let failureRecords = CapturedLogRecords.entries(matching: [
            CodeContextTracing.MetadataKey.lspServer: command,
            CodeContextTracing.MetadataKey.exitCode: "1",
            CodeContextTracing.MetadataKey.installFailureReason: "UNABLE_TO_GET_ISSUER_CERT_LOCALLY",
        ])
        #expect(failureRecords.count == 1)
        #expect(CapturedLogRecords.entries(holding: marker).isEmpty)
        #expect(CapturedLogRecords.entries(holding: "registry.npmjs.org").isEmpty)
    }

    @Test
    func aFailedInstallWithNoErrorCodeLogsNoReason() async {
        _ = CapturedLogRecords.handler
        let runner = FakeInstallRunner()
        await runner.updateResult(.success(InstallRunResult(exitCode: 1, output: "Error: No available formula")))
        let command = "fake-brew-failure-\(UUID().uuidString)"
        let spec = Self.serverSpec(command: command, installerTool: "true")

        let succeeded = await ServerInstaller(runner: runner).install(spec: spec)

        #expect(!succeeded)
        let failureRecords = CapturedLogRecords.entries(matching: [
            CodeContextTracing.MetadataKey.lspServer: command,
            CodeContextTracing.MetadataKey.exitCode: "1",
        ])
        #expect(failureRecords.count == 1)
        #expect(failureRecords.allSatisfy { $0.metadata[CodeContextTracing.MetadataKey.installFailureReason] == nil })
    }

    @Test
    func throwingRunnerReturnsFalse() async {
        struct SimulatedInstallFailure: Error {}
        let runner = FakeInstallRunner()
        await runner.updateResult(.failure(SimulatedInstallFailure()))
        let installer = ServerInstaller(runner: runner)
        let spec = Self.serverSpec(command: "fake-throws", installerTool: "true")

        let succeeded = await installer.install(spec: spec)

        #expect(!succeeded)
    }

    @Test
    func disabledPolicyReturnsFalseWithoutInvokingRunner() async {
        let runner = FakeInstallRunner()
        let installer = ServerInstaller(policy: LspAutoInstall(isEnabled: false), runner: runner)
        let spec = Self.serverSpec(command: "fake-disabled", installerTool: "true")

        let succeeded = await installer.install(spec: spec)

        #expect(!succeeded)
        let invocations = await runner.invocations
        #expect(invocations.isEmpty)
    }

    @Test
    func nilInstallerReturnsFalseWithoutInvokingRunner() async {
        let runner = FakeInstallRunner()
        let installer = ServerInstaller(runner: runner)
        let spec = ServerSpec(command: "fake-nil-installer", languageIDs: ["fake"], installHint: "install it by hand")

        let succeeded = await installer.install(spec: spec)

        #expect(!succeeded)
        let invocations = await runner.invocations
        #expect(invocations.isEmpty)
    }

    @Test
    func missingInstallerToolReturnsFalseWithoutInvokingRunner() async {
        let runner = FakeInstallRunner()
        let installer = ServerInstaller(runner: runner)
        let spec = Self.serverSpec(command: "fake-missing-tool", installerTool: "definitely-not-a-real-installer-tool-xyz123")

        let succeeded = await installer.install(spec: spec)

        #expect(!succeeded)
        let invocations = await runner.invocations
        #expect(invocations.isEmpty)
    }

    // MARK: - At-most-once

    @Test
    func sameCommandInstalledTwiceSequentiallyInvokesRunnerOnce() async {
        let runner = FakeInstallRunner()
        let installer = ServerInstaller(runner: runner)
        let spec = Self.serverSpec(command: "fake-sequential", installerTool: "true")

        let first = await installer.install(spec: spec)
        let second = await installer.install(spec: spec)

        #expect(first)
        #expect(second)
        let invocations = await runner.invocations
        #expect(invocations.count == 1)
    }

    @Test
    func sameCommandInstalledConcurrentlyInvokesRunnerOnce() async throws {
        let runner = FakeInstallRunner()
        await runner.closeGate()
        let installer = ServerInstaller(runner: runner)
        let spec = Self.serverSpec(command: "fake-concurrent", installerTool: "true")

        async let first = installer.install(spec: spec)
        async let second = installer.install(spec: spec)

        try await waitUntil { await !runner.invocations.isEmpty }
        await runner.openGate()

        let firstResult = await first
        let secondResult = await second

        #expect(firstResult)
        #expect(secondResult)
        let invocations = await runner.invocations
        #expect(invocations.count == 1)
    }
}

/// Tests for `InstallFailureReason.code(in:)`: the npm error code is the only text that the
/// extractor takes out of installer output, and only when the code has the safe alphabet.
struct InstallFailureReasonTests {
    /// The longest code that the extractor gives: 64 characters of the safe alphabet.
    private static let longestCode = String(repeating: "E", count: 64)

    @Test
    func theCodeOfTheCurrentNpmErrorFormIsTheReason() {
        let output = "npm error code UNABLE_TO_GET_ISSUER_CERT_LOCALLY\nnpm error errno UNABLE_TO_GET_ISSUER_CERT_LOCALLY\n"

        #expect(InstallFailureReason.code(in: output) == "UNABLE_TO_GET_ISSUER_CERT_LOCALLY")
    }

    @Test
    func theCodeOfTheOldNpmErrorFormIsTheReason() {
        let output = "npm ERR! code E404\nnpm ERR! 404 Not Found - GET https://registry.npmjs.org/nope\n"

        #expect(InstallFailureReason.code(in: output) == "E404")
    }

    @Test
    func theCodeLineCanFollowOtherOutputAndEndInACarriageReturn() {
        let output = "added 0 packages\r\nnpm error code EACCES\r\nnpm error syscall mkdir\r\n"

        #expect(InstallFailureReason.code(in: output) == "EACCES")
    }

    @Test
    func aCodeOfTheLongestLengthIsTheReason() {
        #expect(InstallFailureReason.code(in: "npm error code \(Self.longestCode)") == Self.longestCode)
    }

    @Test(arguments: [
        "Error: No available formula with the name \"nope\"",
        "",
        "npm error 404 Not Found",
        "npm error code ",
        "npm error code \(longestCode)E",
        "npm error code eacces",
        "npm error code E404 /Users/someone/secret",
        "npm error code ../../etc/passwd",
        "some text npm error code E404",
    ])
    func outputWithNoSafeNpmErrorCodeHasNoReason(output: String) {
        #expect(InstallFailureReason.code(in: output) == nil)
    }
}

/// Tests for `BinaryLookup.resolve(command:extraSearchDirectories:)`, extended by this task to
/// search `ServerSpec.InstallSpec.extraSearchDirectories` (with `~` expansion) after `$PATH`
/// comes up empty for `command` — so a native global install landing in e.g. `~/go/bin` or
/// `~/.cargo/bin` is still found even when that directory isn't on `$PATH`.
struct BinaryLookupTests {
    @Test
    func resolveFindsCommandOnPath() {
        let location = BinaryLookup.resolve(command: "true")

        #expect(location == .onPath)
    }

    @Test
    func resolveReturnsNilWhenNotFoundAnywhere() {
        let location = BinaryLookup.resolve(
            command: "definitely-not-a-real-binary-xyz123",
            extraSearchDirectories: ["/tmp/definitely-nonexistent-dir-xyz123"]
        )

        #expect(location == nil)
    }

    @Test
    func resolveFindsCommandInExtraSearchDirectory() throws {
        let tempDirectory = TemporaryItem.makeURL(prefix: "extra-search-directory")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let binaryPath = tempDirectory.appendingPathComponent("fake-binary-in-extra-dir")
        FileManager.default.createFile(atPath: binaryPath.path, contents: nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryPath.path)

        let location = BinaryLookup.resolve(
            command: "fake-binary-in-extra-dir",
            extraSearchDirectories: [tempDirectory.path]
        )

        #expect(location == .extraSearchDirectory(absolutePath: binaryPath.path))
    }

    @Test
    func resolvePrefersPathOverExtraSearchDirectories() throws {
        // "true" is on $PATH, so it must win even when an extra search directory is also
        // supplied — $PATH is searched first, matching the documented order.
        let tempDirectory = TemporaryItem.makeURL(prefix: "extra-search-directory")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let location = BinaryLookup.resolve(command: "true", extraSearchDirectories: [tempDirectory.path])

        #expect(location == .onPath)
    }

    @Test
    func resolveExpandsTildeInExtraSearchDirectories() throws {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let relativeDirectoryName = ".foundation-models-code-context-binarylookup-test-\(UUID().uuidString)"
        let tempDirectory = homeDirectory.appendingPathComponent(relativeDirectoryName)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let binaryPath = tempDirectory.appendingPathComponent("fake-tilde-binary")
        FileManager.default.createFile(atPath: binaryPath.path, contents: nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryPath.path)

        let location = BinaryLookup.resolve(
            command: "fake-tilde-binary",
            extraSearchDirectories: ["~/\(relativeDirectoryName)"]
        )

        #expect(location == .extraSearchDirectory(absolutePath: binaryPath.path))
    }

    // MARK: - pathDiagnostics(pathVariable:)

    @Test
    func pathDiagnosticsCountEachEntryAndListEachEntryThatIsNotAbsolute() {
        let absoluteEntries = ["/usr/bin"]
        let nonAbsoluteEntries = ["~/.local/bin", "relative/bin", "$HOME/bin"]

        let diagnostics = BinaryLookup.pathDiagnostics(pathVariable: "~/.local/bin:/usr/bin:relative/bin:$HOME/bin")

        #expect(
            diagnostics
                == BinaryLookup.PathDiagnostics(
                    entryCount: absoluteEntries.count + nonAbsoluteEntries.count,
                    nonAbsoluteEntries: nonAbsoluteEntries
                )
        )
    }

    @Test
    func pathDiagnosticsCountOnlyTheEntriesThatTheLookupSearches() {
        let searchedEntries = ["/usr/bin", "/bin"]

        let diagnostics = BinaryLookup.pathDiagnostics(pathVariable: "/usr/bin::/bin:")

        #expect(diagnostics == BinaryLookup.PathDiagnostics(entryCount: searchedEntries.count, nonAbsoluteEntries: []))
    }

    @Test
    func pathDiagnosticsOfAMissingPathHaveNoEntry() {
        let diagnostics = BinaryLookup.pathDiagnostics(pathVariable: nil)

        #expect(diagnostics == BinaryLookup.PathDiagnostics(entryCount: 0, nonAbsoluteEntries: []))
    }
}

/// Integration tests for `ProcessInstallRunner` against harmless real executables (`true`,
/// `false`, `sh`, `sleep`) — no network access, so these stay CI-safe.
struct ProcessInstallRunnerTests {
    /// The run timeout of a child that ends by itself. It is far above the run time of `sh`,
    /// `true` and `false`.
    private static let selfEndingRunTimeout: Duration = .seconds(10)

    /// The run timeout that elapses before the `sleep` of the child ends.
    private static let elapsingRunTimeout: Duration = .milliseconds(200)

    /// The seconds that the `sleep` of the child runs when nothing stops it.
    private static let childSleepSeconds = 60

    /// The run timeout of the cancellation test. It is equal to the `sleep` of the child, thus
    /// only the cancellation can stop the run before the `sleep` ends.
    private static let cancelledRunTimeout: Duration = .seconds(childSleepSeconds)

    /// The longest real time from the cancellation to the end of the run.
    ///
    /// It is far below `childSleepSeconds`, thus a run that waits for the `sleep` of the child to
    /// end fails. It is far above the delay of the scheduler under load (one full run showed more
    /// than 6 seconds), thus a busy machine does not make the test fail.
    private static let cancelledRunLimit: Duration = .seconds(30)

    /// The shell script of the cancellation test. It writes the pid of its shell and a newline to
    /// the file `$1`, and then replaces the shell with `sleep $2`. `exec` keeps the pid, thus the
    /// pid in the file is the pid of the `sleep`.
    private static let writePIDThenSleepScript = #"echo $$ > "$1"; exec sleep "$2""#

    /// The run timeout of the tests whose installer starts a descendant. It is far above the
    /// time that `sh` takes to start the descendant and write its pid, and far below
    /// `childSleepSeconds`.
    private static let descendantRunTimeout: Duration = .seconds(2)

    /// The longest real time that a test waits for a killed descendant to go away. It is far
    /// above the delay of the scheduler under load, and far below `childSleepSeconds`.
    private static let descendantExitBudget: Duration = .seconds(30)

    /// The exit status of the installer of the exit status test. It is neither `0` nor `1`, thus
    /// only a decode of the real status gives it.
    private static let distinctExitStatus: Int32 = 3

    /// The shell script of an installer that starts a descendant in its own process group, as
    /// `npm` starts `node` workers and lifecycle scripts. The descendant `sleep $2` writes to the
    /// null device, thus it does not hold the output pipe. The script writes the pid of the
    /// descendant and a newline to the file `$1`, and then replaces the shell with `sleep $2`.
    /// Thus a stop of the installer pid alone closes the output pipe, and the run returns while
    /// the descendant still runs.
    private static let descendantInGroupScript = #"sleep "$2" >/dev/null 2>&1 & echo $! > "$1"; exec sleep "$2""#

    /// The shell script of an installer whose descendant leaves the process group of the
    /// installer and holds the output pipe open. `set -m` puts the background `sleep $2` in a new
    /// process group, and that `sleep` keeps the standard output and the standard error of the
    /// installer. `set +m` keeps the last `sleep $2` in the group of the installer, and `exec`
    /// gives it the pid of the shell. The script writes the pid of the descendant and a newline
    /// to the file `$1`.
    private static let descendantOutsideGroupScript =
        #"set -m; sleep "$2" & set +m; echo $! > "$1"; exec sleep "$2""#

    /// Reads the pid that the child of the cancellation test wrote.
    /// - Parameter file: The file that the child writes its pid to.
    /// - Returns: The pid, or `nil` when the file does not exist yet or does not hold a complete
    ///   line yet.
    private static func childPID(in file: URL) -> pid_t? {
        guard let text = try? String(contentsOf: file, encoding: .utf8), text.hasSuffix("\n") else {
            return nil
        }
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test
    func exitZeroReportsSuccessAndCapturesCombinedOutput() async throws {
        let runner = ProcessInstallRunner()

        let result = try await runner.run(
            tool: "sh",
            arguments: ["-c", "echo install-stdout-marker; echo install-stderr-marker 1>&2"],
            timeout: Self.selfEndingRunTimeout
        )

        #expect(result.exitCode == 0)
        #expect(result.output.contains("install-stdout-marker"))
        #expect(result.output.contains("install-stderr-marker"))
    }

    @Test
    func exitOneReportsNonzeroExitCode() async throws {
        let runner = ProcessInstallRunner()

        let result = try await runner.run(tool: "false", arguments: [], timeout: Self.selfEndingRunTimeout)

        #expect(result.exitCode != 0)
    }

    @Test
    func timeoutThrowsCodeContextErrorTimeout() async throws {
        let runner = ProcessInstallRunner()

        do {
            _ = try await runner.run(
                tool: "sleep", arguments: [String(Self.childSleepSeconds)], timeout: Self.elapsingRunTimeout
            )
            Issue.record("expected the timeout to fire before `sleep \(Self.childSleepSeconds)` exited on its own")
        } catch let error as CodeContextError {
            guard case .timeout = error else {
                Issue.record("expected CodeContextError.timeout, got \(error)")
                return
            }
        } catch {
            Issue.record("expected CodeContextError.timeout, got \(error)")
        }
    }

    /// The cancellation of the calling task stops the process group of the child with `SIGTERM`,
    /// the run reaps the child, and the run does not wait for the `sleep` of the child to end.
    ///
    /// The test does not measure the speed of the scheduler. The exit code and the pid check
    /// prove the kill. The limit `cancelledRunLimit` is far from both the scheduler delay and
    /// `childSleepSeconds`.
    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
    func cancellationKillsAndReapsTheChildBeforeItsSleepEnds() async throws {
        let directory = TemporaryItem.makeURL(prefix: "install-child-pid")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid")
        let runner = ProcessInstallRunner()
        let task = Task {
            try await runner.run(
                tool: "sh",
                arguments: ["-c", Self.writePIDThenSleepScript, "sh", pidFile.path, String(Self.childSleepSeconds)],
                timeout: Self.cancelledRunTimeout
            )
        }
        defer { task.cancel() }

        // The child writes its pid before it sleeps, thus after this wait the child runs.
        try await waitUntil { Self.childPID(in: pidFile) != nil }
        let pid = try #require(Self.childPID(in: pidFile))

        let start = ContinuousClock.now
        task.cancel()
        let result = try await task.value
        let elapsed = ContinuousClock.now - start

        #expect(result.exitCode == SIGTERM, "the child must end by the SIGTERM of the group stop, not by itself")
        #expect(!processExists(pid), "the run must reap the killed child")
        #expect(elapsed < Self.cancelledRunLimit, "the run waited \(elapsed) after the cancellation")
    }

    @Test
    func exitCodeIsTheExitStatusOfTheInstaller() async throws {
        let runner = ProcessInstallRunner()

        let result = try await runner.run(
            tool: "sh", arguments: ["-c", "exit \(Self.distinctExitStatus)"], timeout: Self.selfEndingRunTimeout
        )

        #expect(result.exitCode == Self.distinctExitStatus)
    }

    /// A timeout stops the full process group of the installer, thus a process that the
    /// installer started also stops.
    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
    func timeoutKillsADescendantOfTheInstaller() async throws {
        try await withTemporaryWorkspace { directory in
            let run = try await Self.startRun(of: Self.descendantInGroupScript, in: directory, timeout: Self.descendantRunTimeout)
            defer { Self.stop(run) }

            let outcome = await run.task.result

            #expect(Self.isTimeout(outcome), "expected CodeContextError.timeout, got \(outcome)")
            #expect(try await Self.waitUntilGone(run.descendantPID), "the descendant is alive after the timeout")
        }
    }

    /// A cancellation stops the full process group of the installer, thus a process that the
    /// installer started also stops.
    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
    func cancellationKillsADescendantOfTheInstaller() async throws {
        try await withTemporaryWorkspace { directory in
            let run = try await Self.startRun(of: Self.descendantInGroupScript, in: directory, timeout: Self.cancelledRunTimeout)
            defer { Self.stop(run) }

            run.task.cancel()
            _ = try await run.task.value

            #expect(try await Self.waitUntilGone(run.descendantPID), "the descendant is alive after the cancellation")
        }
    }

    /// A descendant that left the process group of the installer survives the group stop and
    /// holds the output pipe open. The timed-out run still returns, and does not wait for the
    /// descendant to close the pipe.
    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
    func timeoutReturnsWhileADescendantOutsideTheGroupHoldsTheOutputPipe() async throws {
        try await withTemporaryWorkspace { directory in
            let start = ContinuousClock.now
            let run = try await Self.startRun(of: Self.descendantOutsideGroupScript, in: directory, timeout: Self.descendantRunTimeout)
            defer { Self.stop(run) }

            let outcome = await run.task.result
            let elapsed = ContinuousClock.now - start

            #expect(Self.isTimeout(outcome), "expected CodeContextError.timeout, got \(outcome)")
            #expect(elapsed < Self.descendantRunTimeout + Self.cancelledRunLimit, "the run took \(elapsed)")
        }
    }

    /// A descendant that left the process group of the installer survives the group stop and
    /// holds the output pipe open. The cancelled run still returns, and does not wait for the
    /// descendant to close the pipe.
    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
    func cancellationReturnsWhileADescendantOutsideTheGroupHoldsTheOutputPipe() async throws {
        try await withTemporaryWorkspace { directory in
            let run = try await Self.startRun(of: Self.descendantOutsideGroupScript, in: directory, timeout: Self.cancelledRunTimeout)
            defer { Self.stop(run) }

            let start = ContinuousClock.now
            run.task.cancel()
            _ = try await run.task.value
            let elapsed = ContinuousClock.now - start

            #expect(elapsed < Self.cancelledRunLimit, "the run waited \(elapsed) after the cancellation")
        }
    }

    /// A run of an installer script that started a descendant, and the pid of that descendant.
    private struct DescendantRun {
        /// The task of the run.
        let task: Task<InstallRunResult, any Error>

        /// The pid of the descendant that the installer script started.
        let descendantPID: pid_t
    }

    /// Starts a run of `script` as the installer, and waits until the script wrote the pid of
    /// its descendant.
    /// - Parameters:
    ///   - script: The shell script of the installer. It writes the pid of its descendant to the
    ///     file `$1`, and its `sleep` commands run for `$2` seconds.
    ///   - directory: The directory of the pid file.
    ///   - timeout: The run timeout.
    /// - Returns: The task of the run and the pid of the descendant.
    /// - Throws: `CancellationError` when the test is cancelled, or an expectation failure when
    ///   the pid file holds no pid.
    private static func startRun(of script: String, in directory: URL, timeout: Duration) async throws -> DescendantRun {
        let pidFile = directory.appendingPathComponent("descendant.pid")
        let runner = ProcessInstallRunner()
        let task = Task {
            try await runner.run(
                tool: "sh",
                arguments: ["-c", script, "sh", pidFile.path, String(childSleepSeconds)],
                timeout: timeout
            )
        }
        try await waitUntil { childPID(in: pidFile) != nil }
        return DescendantRun(task: task, descendantPID: try #require(childPID(in: pidFile)))
    }

    /// Cancels the task of `run`, and kills the descendant of `run` when a failed test left it
    /// alive. A test that passes leaves no process in the group of the installer, and the
    /// descendant outside the group is killed here.
    /// - Parameter run: The run to stop.
    private static func stop(_ run: DescendantRun) {
        run.task.cancel()
        _ = kill(run.descendantPID, SIGKILL)
    }

    /// Polls until no process has the id `pid`, for at most `descendantExitBudget`.
    /// - Parameter pid: The process id to check.
    /// - Returns: `true` when the process goes away in the budget.
    /// - Throws: `CancellationError` when the test is cancelled.
    private static func waitUntilGone(_ pid: pid_t) async throws -> Bool {
        try await waitUntil(timeout: descendantExitBudget) { !processExists(pid) }
    }

    /// Tells if `outcome` is the failure `CodeContextError.timeout`.
    /// - Parameter outcome: The outcome of a run.
    /// - Returns: `true` for a `CodeContextError.timeout` failure.
    private static func isTimeout(_ outcome: Result<InstallRunResult, any Error>) -> Bool {
        if case .failure(CodeContextError.timeout) = outcome {
            return true
        }
        return false
    }
}

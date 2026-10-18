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

    /// The cancellation of the calling task kills the child with `SIGKILL`, the run reaps the
    /// child, and the run does not wait for the `sleep` of the child to end.
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

        #expect(result.exitCode == SIGKILL, "the child must end by SIGKILL, not by itself")
        #expect(!processExists(pid), "the run must reap the killed child")
        #expect(elapsed < Self.cancelledRunLimit, "the run waited \(elapsed) after the cancellation")
    }
}

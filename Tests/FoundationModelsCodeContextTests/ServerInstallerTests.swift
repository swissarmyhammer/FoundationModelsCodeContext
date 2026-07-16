import Foundation
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
    func sameCommandInstalledConcurrentlyInvokesRunnerOnce() async {
        let runner = FakeInstallRunner()
        await runner.closeGate()
        let installer = ServerInstaller(runner: runner)
        let spec = Self.serverSpec(command: "fake-concurrent", installerTool: "true")

        async let first = installer.install(spec: spec)
        async let second = installer.install(spec: spec)

        while await runner.invocations.count < 1 {
            try? await Task.sleep(for: .milliseconds(1))
        }
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
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
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
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
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
}

/// Integration tests for `ProcessInstallRunner` against harmless real executables (`true`,
/// `false`, `sh`, `sleep`) — no network access, so these stay CI-safe.
struct ProcessInstallRunnerTests {
    @Test
    func exitZeroReportsSuccessAndCapturesCombinedOutput() async throws {
        let runner = ProcessInstallRunner()

        let result = try await runner.run(
            tool: "sh",
            arguments: ["-c", "echo install-stdout-marker; echo install-stderr-marker 1>&2"],
            timeout: .seconds(10)
        )

        #expect(result.exitCode == 0)
        #expect(result.output.contains("install-stdout-marker"))
        #expect(result.output.contains("install-stderr-marker"))
    }

    @Test
    func exitOneReportsNonzeroExitCode() async throws {
        let runner = ProcessInstallRunner()

        let result = try await runner.run(tool: "false", arguments: [], timeout: .seconds(10))

        #expect(result.exitCode != 0)
    }

    @Test
    func timeoutThrowsCodeContextErrorTimeout() async throws {
        let runner = ProcessInstallRunner()

        do {
            _ = try await runner.run(tool: "sleep", arguments: ["60"], timeout: .milliseconds(200))
            Issue.record("expected the timeout to fire before `sleep 60` exited on its own")
        } catch let error as CodeContextError {
            guard case .timeout = error else {
                Issue.record("expected CodeContextError.timeout, got \(error)")
                return
            }
        } catch {
            Issue.record("expected CodeContextError.timeout, got \(error)")
        }
    }

    @Test
    func cancellationTerminatesTheChildPromptly() async throws {
        let runner = ProcessInstallRunner()
        let task = Task {
            try await runner.run(tool: "sleep", arguments: ["60"], timeout: .seconds(60))
        }
        // Give the child process a moment to actually spawn before cancelling, so this genuinely
        // exercises `withTaskCancellationHandler`'s kill rather than racing process creation.
        try await Task.sleep(for: .milliseconds(100))

        let start = ContinuousClock.now
        task.cancel()
        _ = try? await task.value
        let elapsed = ContinuousClock.now - start

        #expect(elapsed < .seconds(5), "expected prompt termination on cancellation, took \(elapsed)")
    }
}

import Foundation
import Testing

@testable import FoundationModelsCodeContext

/// Tests for the per-user record of failed language server installs: a failed install is not
/// run again by a second `ServerInstaller` (a second session) within the backoff window, it is
/// run again after the window, a success clears the record, and a corrupt record never stops
/// an install.
///
/// Each test keeps its record in a temporary directory of its own, never in the user caches
/// directory, and drives a scripted `FakeInstallRunner`, so no real installer runs.
struct InstallFailureRecordTests {
    /// The exit code of the scripted failed installer.
    private static let failedExitCode: Int32 = 1

    /// A fixed time for the first install of a test.
    private static let firstInstallTime = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// The number of seconds in the default backoff window: 24 hours.
    private static let defaultBackoffSeconds: Int64 = 24 * 60 * 60

    /// The number of seconds in the short backoff window of the backoff tests.
    private static let shortBackoffSeconds: Int64 = 60

    /// The short backoff window of the backoff tests.
    private static let shortBackoff = Duration.seconds(shortBackoffSeconds)

    /// The end of the short window of a failure at `firstInstallTime`: the retry time.
    private static let endOfTheShortWindow = firstInstallTime.addingTimeInterval(TimeInterval(shortBackoffSeconds))

    /// One second before `endOfTheShortWindow`.
    private static let insideTheShortWindow = endOfTheShortWindow.addingTimeInterval(-1)

    /// One second after `endOfTheShortWindow`.
    private static let afterTheShortWindow = endOfTheShortWindow.addingTimeInterval(1)

    /// The output of a failed `npm install`, with its error code line.
    private static let npmCertificateFailureOutput = """
        npm error code UNABLE_TO_GET_ISSUER_CERT_LOCALLY
        npm error request to https://registry.npmjs.org/ failed, reason: unable to get local issuer certificate
        """

    /// The npm error code of `npmCertificateFailureOutput`.
    private static let npmCertificateFailureCode = "UNABLE_TO_GET_ISSUER_CERT_LOCALLY"

    /// The text of a record file that is not JSON.
    private static let corruptRecordText = "{ not json"

    /// Builds a `ServerSpec` whose installer runs `true` (always on `$PATH`) with `arguments`.
    /// - Parameters:
    ///   - command: The server command. Unique per test, so that log records of parallel tests
    ///     do not match.
    ///   - arguments: The installer arguments.
    /// - Returns: The spec.
    private static func serverSpec(command: String, arguments: [String] = ["install", "-g", "fake-server"]) -> ServerSpec {
        ServerSpec(
            command: command,
            languageIDs: ["fake"],
            installHint: "install \(command) by hand",
            installer: ServerSpec.InstallSpec(tool: "true", arguments: arguments)
        )
    }

    /// Gives a runner whose every run exits `failedExitCode` with `output`.
    /// - Parameter output: The output of each scripted run.
    /// - Returns: The runner.
    private static func failingRunner(output: String = "boom") async -> FakeInstallRunner {
        let runner = FakeInstallRunner()
        await runner.updateResult(.success(InstallRunResult(exitCode: failedExitCode, output: output)))
        return runner
    }

    /// Gives a unique server command for one test.
    /// - Parameter name: What the test is about.
    /// - Returns: The command.
    private static func uniqueCommand(_ name: String) -> String {
        "fake-\(name)-\(UUID().uuidString)"
    }

    /// Gives the record key of the installer command of `spec`.
    /// - Parameter spec: A spec of `serverSpec(command:arguments:)`.
    /// - Returns: The key.
    /// - Throws: An expectation failure when `spec` has no installer.
    private static func recordKey(of spec: ServerSpec) throws -> InstallFailureRecord.Key {
        let installer = try #require(spec.installer)
        return InstallFailureRecord.Key(command: spec.command, tool: installer.tool, arguments: installer.arguments)
    }

    /// Writes a record file that is not JSON into `directory`.
    /// - Parameter directory: The record directory.
    /// - Throws: The error of the write.
    private static func writeCorruptRecord(in directory: URL) throws {
        try Data(corruptRecordText.utf8).write(to: directory.appendingPathComponent(InstallFailureRecord.fileName))
    }

    // MARK: - Across sessions

    @Test
    func aSecondInstallerSharingTheRecordDoesNotRunAFailedInstallerAgain() async throws {
        try await withTemporaryWorkspace { directory in
            let runner = await Self.failingRunner()
            let policy = LspAutoInstall(failureRecordDirectory: directory)
            let spec = Self.serverSpec(command: Self.uniqueCommand("second-session"))

            let first = await ServerInstaller(policy: policy, runner: runner).install(spec: spec)
            let second = await ServerInstaller(policy: policy, runner: runner).install(spec: spec)

            #expect(!first)
            #expect(!second)
            #expect(await runner.invocations.count == 1)
        }
    }

    @Test
    func aFailureOlderThanTheBackoffWindowRunsTheInstallerAgain() async throws {
        try await withTemporaryWorkspace { directory in
            let runner = await Self.failingRunner()
            let policy = LspAutoInstall(failureBackoff: Self.shortBackoff, failureRecordDirectory: directory)
            let spec = Self.serverSpec(command: Self.uniqueCommand("backoff-elapsed"))

            _ = await ServerInstaller(policy: policy, runner: runner, now: { Self.firstInstallTime }).install(spec: spec)
            _ = await ServerInstaller(policy: policy, runner: runner, now: { Self.afterTheShortWindow }).install(spec: spec)

            #expect(await runner.invocations.count == 2)
        }
    }

    @Test
    func aFailureInsideTheBackoffWindowDoesNotRunTheInstallerAgain() async throws {
        try await withTemporaryWorkspace { directory in
            let runner = await Self.failingRunner()
            let policy = LspAutoInstall(failureBackoff: Self.shortBackoff, failureRecordDirectory: directory)
            let spec = Self.serverSpec(command: Self.uniqueCommand("backoff-running"))

            _ = await ServerInstaller(policy: policy, runner: runner, now: { Self.firstInstallTime }).install(spec: spec)
            _ = await ServerInstaller(policy: policy, runner: runner, now: { Self.insideTheShortWindow }).install(spec: spec)

            #expect(await runner.invocations.count == 1)
        }
    }

    @Test
    func changedInstallerArgumentsRunTheInstallerAgain() async throws {
        try await withTemporaryWorkspace { directory in
            let runner = await Self.failingRunner()
            let policy = LspAutoInstall(failureRecordDirectory: directory)
            let command = Self.uniqueCommand("changed-arguments")

            _ = await ServerInstaller(policy: policy, runner: runner).install(spec: Self.serverSpec(command: command))
            let changed = Self.serverSpec(command: command, arguments: ["install", "-g", "fake-server@2"])
            _ = await ServerInstaller(policy: policy, runner: runner).install(spec: changed)

            #expect(await runner.invocations.count == 2)
        }
    }

    @Test
    func aSuccessClearsTheRecord() async throws {
        try await withTemporaryWorkspace { directory in
            let runner = await Self.failingRunner()
            let policy = LspAutoInstall(failureBackoff: Self.shortBackoff, failureRecordDirectory: directory)
            let spec = Self.serverSpec(command: Self.uniqueCommand("success-clears"))

            _ = await ServerInstaller(policy: policy, runner: runner, now: { Self.firstInstallTime }).install(spec: spec)
            await runner.updateResult(.success(InstallRunResult(exitCode: 0, output: "")))
            let succeeded = await ServerInstaller(policy: policy, runner: runner, now: { Self.afterTheShortWindow }).install(spec: spec)

            let key = try Self.recordKey(of: spec)
            #expect(succeeded)
            #expect(InstallFailureRecord(directory: directory).entry(for: key) == nil)
        }
    }

    // MARK: - The record file

    @Test
    func theRecordHoldsTheFailureTimeTheExitCodeAndTheNpmErrorCode() async throws {
        try await withTemporaryWorkspace { directory in
            let runner = await Self.failingRunner(output: Self.npmCertificateFailureOutput)
            let policy = LspAutoInstall(failureRecordDirectory: directory)
            let spec = Self.serverSpec(command: Self.uniqueCommand("record-content"))

            _ = await ServerInstaller(policy: policy, runner: runner, now: { Self.firstInstallTime }).install(spec: spec)

            let entry = try #require(InstallFailureRecord(directory: directory).entry(for: try Self.recordKey(of: spec)))
            #expect(entry.failedAt == Self.firstInstallTime)
            #expect(entry.exitCode == Self.failedExitCode)
            #expect(entry.reason == Self.npmCertificateFailureCode)
        }
    }

    @Test
    func aRunThatThrowsIsRecordedWithNoExitCode() async throws {
        struct SimulatedTimeout: Error {}
        try await withTemporaryWorkspace { directory in
            let runner = FakeInstallRunner()
            await runner.updateResult(.failure(SimulatedTimeout()))
            let policy = LspAutoInstall(failureRecordDirectory: directory)
            let spec = Self.serverSpec(command: Self.uniqueCommand("thrown-run"))

            _ = await ServerInstaller(policy: policy, runner: runner).install(spec: spec)
            _ = await ServerInstaller(policy: policy, runner: runner).install(spec: spec)

            let entry = try #require(InstallFailureRecord(directory: directory).entry(for: try Self.recordKey(of: spec)))
            #expect(entry.exitCode == nil)
            #expect(entry.reason == nil)
            #expect(await runner.invocations.count == 1)
        }
    }

    @Test
    func aCorruptRecordFileStillRunsTheInstaller() async throws {
        try await withTemporaryWorkspace { directory in
            try Self.writeCorruptRecord(in: directory)
            let runner = FakeInstallRunner()
            let policy = LspAutoInstall(failureRecordDirectory: directory)
            let spec = Self.serverSpec(command: Self.uniqueCommand("corrupt-record"))

            let succeeded = await ServerInstaller(policy: policy, runner: runner).install(spec: spec)

            #expect(succeeded)
            #expect(await runner.invocations.count == 1)
        }
    }

    @Test
    func aCorruptRecordFileIsLoggedAtWarning() async throws {
        _ = CapturedLogRecords.handler
        try await withTemporaryWorkspace { directory in
            try Self.writeCorruptRecord(in: directory)
            let spec = Self.serverSpec(command: Self.uniqueCommand("corrupt-log"))

            let entry = InstallFailureRecord(directory: directory).entry(for: try Self.recordKey(of: spec))

            #expect(entry == nil)
            let warnings = CapturedLogRecords.entries.filter {
                $0.message.description == "the record of failed language server installs could not be decoded"
            }
            #expect(!warnings.isEmpty)
            #expect(warnings.allSatisfy { $0.level == .warning })
        }
    }

    @Test
    func aRecordDirectoryThatCannotBeCreatedStillReportsTheFailure() async throws {
        try await withTemporaryWorkspace { directory in
            let blockingFile = directory.appendingPathComponent("not-a-directory")
            try Data().write(to: blockingFile)
            let runner = await Self.failingRunner()
            let policy = LspAutoInstall(failureRecordDirectory: blockingFile.appendingPathComponent("record"))
            let spec = Self.serverSpec(command: Self.uniqueCommand("unwritable-record"))

            let first = await ServerInstaller(policy: policy, runner: runner).install(spec: spec)
            let second = await ServerInstaller(policy: policy, runner: runner).install(spec: spec)

            #expect(!first)
            #expect(!second)
            #expect(await runner.invocations.count == 2)
        }
    }

    @Test
    func noRecordDirectoryKeepsNoRecord() async {
        let runner = await Self.failingRunner()
        let spec = Self.serverSpec(command: Self.uniqueCommand("no-record"))

        _ = await ServerInstaller(policy: .withoutFailureRecord, runner: runner).install(spec: spec)
        _ = await ServerInstaller(policy: .withoutFailureRecord, runner: runner).install(spec: spec)

        #expect(await runner.invocations.count == 2)
    }

    // MARK: - The log

    @Test
    func aSkippedInstallLogsTheReasonAndTheRetryTimeAtInfo() async throws {
        _ = CapturedLogRecords.handler
        try await withTemporaryWorkspace { directory in
            let runner = await Self.failingRunner(output: Self.npmCertificateFailureOutput)
            let policy = LspAutoInstall(failureBackoff: Self.shortBackoff, failureRecordDirectory: directory)
            let command = Self.uniqueCommand("skip-log")
            let spec = Self.serverSpec(command: command)

            _ = await ServerInstaller(policy: policy, runner: runner, now: { Self.firstInstallTime }).install(spec: spec)
            _ = await ServerInstaller(policy: policy, runner: runner, now: { Self.firstInstallTime }).install(spec: spec)

            let skipRecords = CapturedLogRecords.entries(matching: [
                CodeContextTracing.MetadataKey.lspServer: command,
                CodeContextTracing.MetadataKey.lspInstaller: "true",
                CodeContextTracing.MetadataKey.exitCode: String(Self.failedExitCode),
                CodeContextTracing.MetadataKey.installFailureReason: Self.npmCertificateFailureCode,
                CodeContextTracing.MetadataKey.installRetryTime: Self.endOfTheShortWindow.ISO8601Format(),
            ])
            #expect(skipRecords.count == 1)
            #expect(skipRecords.allSatisfy { $0.level == .info })
        }
    }

    // MARK: - The policy

    @Test
    func theDefaultBackoffWindowIsOneDay() {
        #expect(LspAutoInstall().failureBackoff == .seconds(Self.defaultBackoffSeconds))
    }

    @Test
    func theDefaultRecordDirectoryIsBelowTheUserCachesDirectory() throws {
        let caches = try #require(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
        let directory = try #require(LspAutoInstall().failureRecordDirectory)

        #expect(directory.deletingLastPathComponent().standardizedFileURL == caches.standardizedFileURL)
        #expect(directory.lastPathComponent == "FoundationModelsCodeContext")
    }
}

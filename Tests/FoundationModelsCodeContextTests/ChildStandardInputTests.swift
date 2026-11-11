import Foundation
import Testing

@testable import FoundationModelsCodeContext

/// Proves that a child process of the package does not get the standard input of the host.
///
/// A host can use its standard input for a protocol (ACP, or MCP over stdio). A child process
/// that gets the standard input of the host takes the bytes of that protocol, and the session
/// of the host stops. Each test checks the standard input of the child itself. No test
/// changes file descriptor 0 of the test process, because other tests run at the same time
/// and spawn their own child processes. The child of each test sees the same standard input
/// in each run, thus no test depends on the standard input of the test process.
struct ChildStandardInputTests {
    /// The time that the installer runner gives the child.
    private static let installTimeout: Duration = .seconds(30)

    /// The script of the child. It writes `null` when its standard input is the null device,
    /// and `other` when it is any other file.
    private static let identifyingScript = "if [ /dev/stdin -ef /dev/null ]; then echo null; else echo other; fi"

    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
    func anInstallerGetsTheNullDeviceAsStandardInput() async throws {
        let result = try await ProcessInstallRunner().run(
            tool: "sh",
            arguments: ["-c", Self.identifyingScript],
            timeout: Self.installTimeout
        )

        #expect(result.exitCode == 0)
        #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "null")
    }
}

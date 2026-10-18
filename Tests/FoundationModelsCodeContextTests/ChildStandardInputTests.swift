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

    /// The script of the child. It reads its standard input to the end and writes the number of
    /// bytes that it read.
    private static let countingScript = "wc -c"

    /// The object id that `git hash-object` gives for empty content.
    private static let emptyBlobObjectID = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"

    /// Runs `script` in a child process that `makeChildProcess` made with `standardInput`, and
    /// gives the combined output of the child.
    private static func output(of script: String, standardInput: ProcessUtilities.StandardInput) throws -> String {
        let outputPipe = Pipe()
        let process = ProcessUtilities.makeChildProcess(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            standardInput: standardInput,
            standardOutput: outputPipe,
            standardError: outputPipe
        )
        try process.run()
        try outputPipe.fileHandleForWriting.close()
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
    func aChildMadeWithTheNullDeviceReadsTheNullDevice() throws {
        let identity = try Self.output(of: Self.identifyingScript, standardInput: .nullDevice)

        #expect(identity == "null")
    }

    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
    func aChildMadeWithTheNullDeviceReadsNoByteAndReachesTheEndAtOnce() throws {
        let count = try Self.output(of: Self.countingScript, standardInput: .nullDevice)

        #expect(count == "0")
    }

    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
    func aChildMadeWithAPipeReadsThatPipeAndNotTheNullDevice() throws {
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let process = ProcessUtilities.makeChildProcess(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", Self.identifyingScript],
            standardInput: .pipe(inputPipe),
            standardOutput: outputPipe,
            standardError: outputPipe
        )
        try process.run()
        try outputPipe.fileHandleForWriting.close()
        try inputPipe.fileHandleForWriting.close()
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        #expect(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "other")
    }

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

    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
    func gitThatReadsStandardInputToTheEndGetsTheEndOfTheFileAtOnce() async throws {
        try await withTemporaryWorkspace { root in
            let objectID = try await GitShell.run(arguments: ["hash-object", "--stdin"], in: root)

            #expect(objectID.trimmingCharacters(in: .whitespacesAndNewlines) == Self.emptyBlobObjectID)
        }
    }
}

import Darwin
import Foundation
import Testing

@testable import FoundationModelsCodeContext

/// Proves that the `.workingTree` and the `.sha` scopes resolve with no `git`
/// program on the `PATH`.
///
/// A Mac with no developer tools has no `git`, and in the App Sandbox the
/// `/usr/bin/git` shim refuses. Thus the scopes must read the repository with
/// libgit2 in the process, and start no child process.
///
/// Each test runs its body in an exit test: Swift Testing runs the body in a
/// new child process of the test binary. The body sets the `PATH` of that
/// child process to an empty folder, thus no `git` program is found. The
/// `PATH` of the test process does not change, thus the tests that run at
/// the same time and start their own child processes are not affected.
struct GitScopeWithoutGitProgramTests {
    /// The name prefix of the empty folder that the `PATH` of the child
    /// process names.
    private static let emptyPathFolderPrefix = "empty-path"

    /// The `overwrite` value that makes `setenv` replace a set variable.
    private static let replacesTheVariable: Int32 = 1

    /// Sets the `PATH` of this process to one new empty folder. Call it only
    /// in the body of an exit test.
    ///
    /// - Throws: The error of `FileManager` when the folder cannot be made, or
    ///   a `POSIXError` when `setenv` fails.
    private static func removeEachProgramFromThePath() throws {
        let emptyFolder = TemporaryItem.makeURL(prefix: emptyPathFolderPrefix)
        try FileManager.default.createDirectory(at: emptyFolder, withIntermediateDirectories: true)
        guard setenv("PATH", emptyFolder.path, replacesTheVariable) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
        }
    }

    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
    func theWorkingTreeScopeResolvesWithNoGitProgramOnThePath() async {
        await #expect(processExitsWith: .success) {
            try GitScopeWithoutGitProgramTests.removeEachProgramFromThePath()
            try await withTemporaryWorkspace { root in
                try write("let a = 1\n", to: "tracked.swift", in: root)
                try GitFixture.initRepo(at: root)
                try GitFixture.commitAll(in: root, message: "initial")
                try write("let a = 2\n", to: "tracked.swift", in: root)

                let resolved = try await DiagnosticsScopeResolver.resolvePaths(scope: .workingTree, rootDirectory: root)

                try #require(resolved == ["tracked.swift"])
            }
        }
    }

    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
    func theShaScopeResolvesWithNoGitProgramOnThePath() async {
        await #expect(processExitsWith: .success) {
            try GitScopeWithoutGitProgramTests.removeEachProgramFromThePath()
            try await withTemporaryWorkspace { root in
                try write("let a = 1\n", to: "a.swift", in: root)
                try GitFixture.initRepo(at: root)
                let firstSHA = try GitFixture.commitAll(in: root, message: "first")
                try write("let b = 1\n", to: "b.swift", in: root)
                try GitFixture.commitAll(in: root, message: "second")

                let resolved = try await DiagnosticsScopeResolver.resolvePaths(scope: .sha(firstSHA), rootDirectory: root)

                try #require(resolved == ["b.swift"])
            }
        }
    }
}

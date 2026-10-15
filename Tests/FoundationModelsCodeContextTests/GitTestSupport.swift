import Foundation
import Testing

@testable import FoundationModelsCodeContext

/// The `git` helpers of the test target. They make a real git repository in a
/// temporary workspace.
///
/// `DiagnosticsTests` and `CodeSearchToolTests` use these helpers to make the
/// working-tree, file and sha scopes from real `git` output.
enum GitFixture {
    /// Runs `git` in `directory`, and records a test issue when `git` fails.
    ///
    /// This helper calls the production `GitShell.run(arguments:in:)`, and
    /// does not start its own `Process`. Thus each `git` call of a test, in
    /// the fixture setup and in the scope resolution under test, goes through
    /// the one serial dispatch queue of `GitShell` (see its doc comment).
    ///
    /// - Parameters:
    ///   - arguments: The `git` subcommand and its arguments, without `git`.
    ///   - directory: The working directory of `git`.
    /// - Returns: The standard output of `git`, or an empty string when `git`
    ///   fails.
    @discardableResult
    static func run(_ arguments: [String], in directory: URL) async throws -> String {
        do {
            return try await GitShell.run(arguments: arguments, in: directory)
        } catch {
            Issue.record("git \(arguments) failed: \(error.localizedDescription)")
            return ""
        }
    }

    /// Makes an empty git repository at `root`, with a test user name and a
    /// test email address.
    ///
    /// - Parameter root: The directory of the new repository.
    static func initRepo(at root: URL) async throws {
        try await run(["init"], in: root)
        try await run(["config", "user.email", "test@example.com"], in: root)
        try await run(["config", "user.name", "Test"], in: root)
    }

    /// Stages each change in `root`, and commits the changes.
    ///
    /// - Parameters:
    ///   - root: The directory of the repository.
    ///   - message: The commit message.
    static func commitAll(in root: URL, message: String) async throws {
        try await run(["add", "-A"], in: root)
        try await run(["commit", "-m", message], in: root)
    }
}

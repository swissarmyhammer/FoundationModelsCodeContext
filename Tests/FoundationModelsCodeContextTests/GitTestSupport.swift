import Foundation
import Testing
import libgit2

@testable import FoundationModelsCodeContext

/// The git helpers of the test target. They make a real git repository in a
/// temporary workspace.
///
/// `DiagnosticsTests`, `CodeSearchToolTests` and `GitScopeWithoutGitProgramTests`
/// use these helpers to make the working-tree, file and sha scopes from a real
/// repository. The helpers call the libgit2 C API in the process. They never
/// start the `git` program, thus a test runs on a Mac that has no `git`.
enum GitFixture {
    /// The `is_bare` value that makes `git_repository_init` write a
    /// repository with a work folder.
    private static let workFolderRepositoryFlag: UInt32 = 0

    /// The name that each commit records.
    private static let signatureName = "Test"

    /// The email that each commit records. The `.invalid` top-level domain
    /// can never be a real address.
    private static let signatureEmail = "test@example.invalid"

    /// The ref that moves to each new commit.
    private static let headReference = "HEAD"

    /// Makes an empty git repository with a work folder at `root`.
    ///
    /// - Parameter root: The directory of the new repository.
    /// - Throws: `CodeContextError.git` when libgit2 cannot make the repository.
    static func initRepo(at root: URL) throws {
        try LibGit2.start()
        let repository = try LibGit2.makeHandle { repository in
            git_repository_init(&repository, root.path, workFolderRepositoryFlag)
        }
        git_repository_free(repository)
    }

    /// Stages each change in `root`, and commits the index on the branch
    /// that HEAD names.
    ///
    /// A new file, a changed file, and a removed file each go into the
    /// commit. The commit that HEAD names becomes the parent; the first
    /// commit has no parent.
    ///
    /// - Parameters:
    ///   - root: The directory of the repository.
    ///   - message: The commit message.
    /// - Returns: The 40-hex SHA of the new commit.
    /// - Throws: `CodeContextError.git` when a libgit2 call fails.
    @discardableResult
    static func commitAll(in root: URL, message: String) throws -> String {
        try LibGit2.withRepository(at: root) { repository in
            let tree = try stageWorkFolder(of: repository)
            defer { git_tree_free(tree) }
            let parent = try headCommit(of: repository)
            defer { git_commit_free(parent) }
            var parents: [OpaquePointer?] = parent.map { [$0] } ?? []
            var signature: UnsafeMutablePointer<git_signature>?
            try LibGit2.check(git_signature_now(&signature, signatureName, signatureEmail))
            defer { git_signature_free(signature) }
            var commitID = git_oid()
            try LibGit2.check(
                git_commit_create(
                    &commitID, repository, headReference, signature, signature, nil, message, tree,
                    parents.count, &parents))
            return String(cString: git_oid_tostr_s(&commitID))
        }
    }

    /// Stages the file at `path`, and writes the index. No commit is made.
    ///
    /// - Parameters:
    ///   - path: The path of the file, relative to `root`.
    ///   - root: The directory of the repository.
    /// - Throws: `CodeContextError.git` when a libgit2 call fails.
    static func stage(_ path: String, in root: URL) throws {
        try LibGit2.withRepository(at: root) { repository in
            try withIndex(of: repository) { index in
                try LibGit2.check(git_index_add_bypath(index, path))
                try LibGit2.check(git_index_write(index))
            }
        }
    }

    /// Adds each new and changed file of the work folder to the index,
    /// removes each file that the work folder no longer holds, writes the
    /// index, and gives its tree.
    ///
    /// - Parameter repository: The open repository.
    /// - Returns: The tree of the index. The caller frees it.
    /// - Throws: `CodeContextError.git` when a libgit2 call fails.
    private static func stageWorkFolder(of repository: OpaquePointer) throws -> OpaquePointer {
        try withIndex(of: repository) { index in
            try LibGit2.check(git_index_add_all(index, nil, GIT_INDEX_ADD_DEFAULT.rawValue, nil, nil))
            try LibGit2.check(git_index_update_all(index, nil, nil, nil))
            try LibGit2.check(git_index_write(index))
            var treeID = git_oid()
            try LibGit2.check(git_index_write_tree(&treeID, index))
            return try LibGit2.makeHandle { tree in git_tree_lookup(&tree, repository, &treeID) }
        }
    }

    /// The commit that HEAD names, or `nil` when the branch of HEAD has no
    /// commit yet.
    ///
    /// - Parameter repository: The open repository.
    /// - Returns: The commit. The caller frees it.
    /// - Throws: `CodeContextError.git` when the commit cannot be read.
    private static func headCommit(of repository: OpaquePointer) throws -> OpaquePointer? {
        var headID = git_oid()
        guard git_reference_name_to_id(&headID, repository, headReference) == GIT_OK.rawValue else {
            return nil
        }
        return try LibGit2.makeHandle { commit in git_commit_lookup(&commit, repository, &headID) }
    }

    /// Opens the index of `repository`, runs `body` with it, and frees it.
    ///
    /// - Parameters:
    ///   - repository: The open repository.
    ///   - body: The work to do with the index.
    /// - Returns: The value of `body`.
    /// - Throws: `CodeContextError.git` when the index cannot be opened, or the
    ///   error of `body`.
    private static func withIndex<Value>(
        of repository: OpaquePointer, _ body: (OpaquePointer) throws -> Value
    ) throws -> Value {
        let index = try LibGit2.makeHandle { index in git_repository_index(&index, repository) }
        defer { git_index_free(index) }
        return try body(index)
    }
}
